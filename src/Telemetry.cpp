// src/Telemetry.cpp — periodic telemetry as spec-compliant LXMF messages.
//
// Previously this emitted an ASCII "bat=...;up=..." payload as an announce
// on a custom `rlr.telemetry` aspect. Per reticulum-specifications
// SPEC.md §4.4, any non-LXMF name_hash is a "custom beacon" that
// spec-compliant clients (Sideband, MeshChat, Columba) drop from their
// UI — which is exactly why issue #1's user saw only lxmf.delivery and no
// telemetry.
//
// Telemetry in the Reticulum ecosystem is an LXMF message field, not an
// announce: FIELD_TELEMETRY (0x02) carrying a Sideband "Telemeter"
// snapshot (SPEC §5.9.1; the inner Telemeter format comes from upstream
// Sideband `sbapp/sideband/sense.py`). We build that snapshot and push it
// to a configured collector via opportunistic LXMF delivery (Lxmf.cpp).
//
//  Telemeter snapshot = msgpack map { sensor_SID: packed_value, ... }:
//   SID_TIME        0x01  int   (unix seconds; uptime here — no RTC)
//   SID_LOCATION    0x02  [lat,lon,alt,speed,bearing,accuracy,last_update]
//                         where lat/lon/alt/... are big-endian struct
//                         ints wrapped as msgpack bin (per sense.py)
//   SID_PRESSURE    0x03  [mbar]  (BME280, optional — present at boot?)
//   SID_BATTERY     0x04  [charge_percent_f64, charging_bool, temperature]
//   SID_TEMPERATURE 0x07  [celsius]  (BME280, optional)
//   SID_HUMIDITY    0x08  [percent]  (BME280, optional)
//   SID_INFORMATION 0x0F  str   (free-form repeater stats with no SID,
//                               including all 3 INA3221 channel voltage+
//                               current readings when a sensor module is
//                               attached; channels use Config labels when set)
// The whole map is msgpack-packed and embedded as the FIELD_TELEMETRY
// value (a nested msgpack `bin`), matching Sideband's Telemeter.packed().
//
//   Note on TEMPERATURE/HUMIDITY/PRESSURE encoding: Sideband's
//   upstream `sense.py` packs these as dicts like {"c": float} /
//   {"percent_relative": float} / {"mbar": float}. The hand-rolled
//   Msgpack writer in this codebase only ships uinteger-typed map
//   keys (it uses str() for values), so to stay internally consistent
//   with the SID_BATTERY / SID_LOCATION precedent — both of which
//   use flat arrays rather than dicts — we emit single-element
//   float arrays here too. A Sideband / MeshChat receiver that
//   handles missing keys gracefully (rather than requiring a
//   specific shape) will display these correctly; the unit suffix
//   in the FIELD_TELEMETRY verbose log identifies which. When the
//   project's msgpack writer grows string-typed map keys we can
//   convert these to native dicts without breaking the wire format.

#include "Telemetry.h"
#include "Lxmf.h"
#include "Msgpack.h"
#include "Sensors.h"
#include "Transport.h"
#include "Radio.h"

#include <Arduino.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include <microReticulum/Utilities/Memory.h>

namespace rlr { namespace telemetry {

// Sideband sensor IDs (sbapp/sideband/sense.py).
static constexpr uint8_t SID_TIME         = 0x01;
static constexpr uint8_t SID_LOCATION     = 0x02;
static constexpr uint8_t SID_PRESSURE     = 0x03;
static constexpr uint8_t SID_BATTERY      = 0x04;
static constexpr uint8_t SID_TEMPERATURE  = 0x07;
static constexpr uint8_t SID_HUMIDITY     = 0x08;
static constexpr uint8_t SID_INFORMATION  = 0x0F;
// LXMF field key (SPEC §5.9.1).
static constexpr uint8_t FIELD_TELEMETRY = 0x02;

static bool             s_ready    = false;
static uint32_t         s_last_ms  = 0;
static constexpr uint32_t FIRST_MS = 30000UL;   // first send 30 s after init
static constexpr int    BATT_SAMPLES = 16;

uint32_t read_battery_raw_avg() {
#if defined(PIN_BATTERY) && PIN_BATTERY >= 0
  #if defined(BATTERY_ADC_RESOLUTION)
    analogReadResolution(BATTERY_ADC_RESOLUTION);
  #else
    analogReadResolution(12);
  #endif
    uint32_t sum = 0;
    for (int i = 0; i < BATT_SAMPLES; i++) {
        sum += analogRead(PIN_BATTERY);
    }
    return sum / BATT_SAMPLES;
#else
    return 0;
#endif
}

uint16_t read_battery_mv(const Config& cfg) {
    uint32_t raw = read_battery_raw_avg();
    if (raw == 0) return 0;
    return (uint16_t)((float)raw * cfg.batt_mult);
}

bool init(const Config& cfg) {
    (void)cfg;
    s_ready = true;
    Serial.println("Telemetry: LXMF FIELD_TELEMETRY mode (push to collector)");
    return true;
}

// True if no collector has been configured (all-zero hash).
static bool collector_unset(const Config& cfg) {
    for (size_t i = 0; i < sizeof(cfg.collector_hash); i++) {
        if (cfg.collector_hash[i] != 0) return false;
    }
    return true;
}

// Approximate single-cell LiPo charge percentage from terminal voltage.
// A linear 3.30 V (0%) .. 4.20 V (100%) map — coarse but adequate for a
// telemetry indicator; documented as an estimate. Boards with different
// chemistry/cell counts can be refined later.
static float battery_percent(uint16_t mv) {
    if (mv == 0) return 0.0f;
    float pct = (float)(mv - 3300) / (4200.0f - 3300.0f) * 100.0f;
    if (pct < 0.0f)   pct = 0.0f;
    if (pct > 100.0f) pct = 100.0f;
    return roundf(pct * 10.0f) / 10.0f;   // 0.1% resolution, like Sideband
}

// Emit a big-endian struct int as a msgpack bin (sense.py wraps each
// struct.pack("!i"/"!I"/"!H", ...) result as a Python bytes → msgpack bin).
static void bin_be32(msgpack::Writer& w, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16),
                     (uint8_t)(v >> 8),  (uint8_t)v };
    w.bin(b, 4);
}
static void bin_be16(msgpack::Writer& w, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v >> 8), (uint8_t)v };
    w.bin(b, 2);
}

// Build the Sideband Telemeter snapshot (nested msgpack map).
static void build_telemeter(const Config& cfg, msgpack::Writer& tele) {
    uint32_t now_s   = millis() / 1000UL;
    uint16_t batt_mv = read_battery_mv(cfg);

    bool have_loc   = (cfg.latitude_udeg != 0 || cfg.longitude_udeg != 0);
    bool have_bat   = (batt_mv > 0);
    bool have_bme   = rlr::sensors::bme_present();
    bool have_ina   = rlr::sensors::ina_present();

    // Read environmental + power-rail sensors first (cheap I2C transactions;
    // the Sensors module probes at boot for presence so we're not making
    // any assumption about which sensors are wired).
    float bme_t_c  = 0.0f, bme_rh_pct = 0.0f, bme_p_mbar = 0.0f;
    float ina_ch1_v = 0.0f, ina_ch1_ma = 0.0f;
    float ina_ch2_v = 0.0f, ina_ch2_ma = 0.0f;
    float ina_ch3_v = 0.0f, ina_ch3_ma = 0.0f;
    if (have_bme) rlr::sensors::read_bme(bme_t_c, bme_rh_pct, bme_p_mbar);
    if (have_ina) rlr::sensors::read_ina(ina_ch1_v, ina_ch1_ma,
                                         ina_ch2_v, ina_ch2_ma,
                                         ina_ch3_v, ina_ch3_ma);

    size_t nsensors = 2;                       // TIME + INFORMATION always
    if (have_loc) nsensors++;
    if (have_bat) nsensors++;
    if (have_bme) nsensors += 3;               // temperature / humidity / pressure
    tele.map_header(nsensors);

    // SID_TIME → unix seconds. No RTC/GPS clock on this hardware, so this
    // is monotonic uptime; Sideband displays against its own receive time.
    tele.uint(SID_TIME);
    tele.uint(now_s);

    // SID_LOCATION → [lat, lon, alt, speed, bearing, accuracy, last_update]
    if (have_loc) {
        tele.uint(SID_LOCATION);
        tele.array_header(7);
        bin_be32(tele, (uint32_t)cfg.latitude_udeg);          // lat * 1e6 (== udeg)
        bin_be32(tele, (uint32_t)cfg.longitude_udeg);         // lon * 1e6
        bin_be32(tele, (uint32_t)(int32_t)(cfg.altitude_m * 100)); // alt * 1e2
        bin_be32(tele, 0);                                    // speed * 1e2
        bin_be32(tele, 0);                                    // bearing * 1e2
        bin_be16(tele, 0);                                    // accuracy * 1e2
        tele.uint(now_s);                                     // last_update
    }

    // SID_BATTERY → [charge_percent, charging, temperature]
    if (have_bat) {
        tele.uint(SID_BATTERY);
        tele.array_header(3);
        tele.float64(battery_percent(batt_mv));
        tele.boolean(false);                                  // charging unknown
        tele.nil();                                           // temperature unknown
    }

    // SID_TEMPERATURE / SID_HUMIDITY / SID_PRESSURE → [value]
    //
    // Single-element float arrays rather than the {"c": float} / {"mbar":
    // float} / {"percent_relative": float} dicts Sideband's upstream
    // sense.py uses, because this project's Msgpack writer only ships
    // uinteger map keys (it uses str() for values). Matching the
    // SID_BATTERY / SID_LOCATION precedent for inner-value shape keeps
    // the wire format internally consistent. See header comment for the
    // longer rationale.
    if (have_bme) {
        tele.uint(SID_TEMPERATURE);
        tele.array_header(1);
        tele.float64((double)bme_t_c);

        tele.uint(SID_HUMIDITY);
        tele.array_header(1);
        tele.float64((double)bme_rh_pct);

        tele.uint(SID_PRESSURE);
        tele.array_header(1);
        tele.float64((double)bme_p_mbar);
    }

    // SID_INFORMATION → free-form text carrying the repeater stats that
    // have no dedicated Sideband sensor. INA3221 voltage + current are
    // appended when the sensor is attached — Sideband has no fixed SID
    // for arbitrary power-rail monitoring, and synthesising one would
    // diverge from spec; appending to SID_INFORMATION keeps the wire
    // format spec-compliant while still surfacing the readings.
    char info[256];
    int n = snprintf(info, sizeof(info),
        "up=%lus heap=%u pin=%lu pout=%lu bat=%umV radio=%s",
        (unsigned long)now_s,
        (unsigned)RNS::Utilities::Memory::heap_available(),
        (unsigned long)rlr::transport::packets_in(),
        (unsigned long)rlr::transport::packets_out(),
        (unsigned)batt_mv,
        rlr::radio::online() ? "up" : "down");
    if (have_ina && n > 0) {
        const char* ch1_label = cfg.ina_ch1_label[0] ? cfg.ina_ch1_label : "ch1";
        const char* ch2_label = cfg.ina_ch2_label[0] ? cfg.ina_ch2_label : "ch2";
        const char* ch3_label = cfg.ina_ch3_label[0] ? cfg.ina_ch3_label : "ch3";
        size_t used = ((size_t)n < sizeof(info)) ? (size_t)n : sizeof(info) - 1;
        // Truncation-safe append: snprintf never writes past the remaining
        // buffer, and silently clips the optional sensor text if needed.
        if (used < sizeof(info)) {
            snprintf(info + used, sizeof(info) - used,
                     " %s_v=%.2fV %s_i=%.1fmA %s_v=%.2fV %s_i=%.1fmA %s_v=%.2fV %s_i=%.1fmA",
                     ch1_label, (double)ina_ch1_v, ch1_label, (double)ina_ch1_ma,
                     ch2_label, (double)ina_ch2_v, ch2_label, (double)ina_ch2_ma,
                     ch3_label, (double)ina_ch3_v, ch3_label, (double)ina_ch3_ma);
        }
    }
    tele.uint(SID_INFORMATION);
    tele.str(info);
}

bool send_now(const Config& cfg) {
    if (collector_unset(cfg)) {
        Serial.println("Telemetry: no collector configured — set 'collector' to a 32-hex destination hash");
        return false;
    }

    // Build the Telemeter snapshot, then wrap it as the FIELD_TELEMETRY
    // value inside a one-entry LXMF fields map.
    msgpack::Writer tele;
    build_telemeter(cfg, tele);

    msgpack::Writer fields;
    fields.map_header(1);
    fields.uint(FIELD_TELEMETRY);
    fields.bin(tele.data(), tele.size());     // nested Telemeter msgpack

    Serial.print("Telemetry: telemeter=");
    Serial.print((unsigned)tele.size());
    Serial.print("B fields=");
    Serial.print((unsigned)fields.size());
    Serial.println("B");

    return rlr::lxmf::send_opportunistic(
        cfg.collector_hash, /*content=*/"", fields.data(), fields.size());
}

void tick(const Config& cfg) {
    if (!s_ready) return;
    if ((cfg.flags & CONFIG_FLAG_TELEMETRY) == 0) return;
    if (!rlr::radio::online()) return;
    if (collector_unset(cfg)) return;

    uint32_t now = millis();
    bool due;
    if (s_last_ms == 0) {
        due = (now >= FIRST_MS);
    } else {
        due = ((now - s_last_ms) >= cfg.tele_interval_ms);
    }
    if (!due) return;

    s_last_ms = now;
    send_now(cfg);
}

}} // namespace rlr::telemetry
