// src/Sensors.cpp — see Sensors.h.
//
// I2C sensor power sequencing, probing, and reading for the optional
// BME280 (temp / humidity / pressure) and INA3221 (bus voltage / current)
// chips. Boards that define PIN_WB_IO2 enable and settle the switched
// WisBlock IO-slot rail before Wire starts and sensor probing begins.
// All I2C / Adafruit_BusIO code is gated on HAS_I2C_HEADER so boards
// without an exposed I2C header don't pay the flash or RAM cost —
// mirroring the `#if defined(PIN_BATTERY) && PIN_BATTERY >= 0` guard
// pattern already used in Telemetry.cpp for the battery divider.

#include "Sensors.h"

#include <Arduino.h>

#if defined(HAS_I2C_HEADER) && HAS_I2C_HEADER
  #include <Wire.h>
  #include <Adafruit_BME280.h>
  #include <Adafruit_INA3221.h>
#endif

namespace rlr { namespace sensors {

// ---- Per-sensor state. Heap objects only allocated when the board
// ---- actually has HAS_I2C_HEADER — keeps the rest of the firmware
// ---- footprint identical to before this module existed.
#if defined(HAS_I2C_HEADER) && HAS_I2C_HEADER
static Adafruit_BME280  s_bme;
static Adafruit_INA3221 s_ina;
#endif

// Sticky "did we find one at init time" flags. Once true, never goes
// back to false within a boot — we don't try to re-probe mid-run.
static bool s_bme_present = false;
static bool s_ina_present = false;

// ---- Default I2C addresses --------------------------------------
// BME280 ships at 0x76 (SDO tied to GND) or 0x77 (SDO tied to V+).
// INA3221 default is 0x40 with A0=GND; other A0 strapping gives 0x41
// / 0x42 / 0x43 — we probe only the GND-strapped default for now
// (matches the off-the-shelf RAK WisBlock sensor modules).
static constexpr uint8_t BME280_ADDR_PRIMARY   = 0x76;
static constexpr uint8_t BME280_ADDR_SECONDARY = 0x77;
static constexpr uint8_t INA3221_ADDR_DEFAULT  = 0x40;
// INA3221 A0 pin strapping selects one of 4 addresses (datasheet
// Table: A0=GND->0x40, A0=VCC->0x41, A0=SDA->0x42, A0=SCL->0x43).
// Off-the-shelf WisBlock/RAK sensor boards have been observed at
// 0x42 (A0 tied to SDA), so probe all 4 rather than assuming GND
// strapping — same rationale as the BME280 primary/secondary probe
// just above.
static constexpr uint8_t INA3221_ADDR_CANDIDATES[] = { 0x40, 0x41, 0x42, 0x43 };

// Power any board-specific switched sensor rail before starting Wire,
// then probe each supported sensor at its default I2C address.
bool init() {
#if !(defined(HAS_I2C_HEADER) && HAS_I2C_HEADER)
    Serial.println("Sensors: HAS_I2C_HEADER=0 — no sensor probing");
    return true;
#else
#if defined(PIN_WB_IO2) && PIN_WB_IO2 >= 0
    pinMode(PIN_WB_IO2, OUTPUT);
    digitalWrite(PIN_WB_IO2, HIGH);
    #if defined(WB_IO2_SETTLE_MS)
        delay(WB_IO2_SETTLE_MS);
    #else
        delay(10);
    #endif
    Serial.println("Sensors: WisBlock IO slot power (WB_IO2) enabled");
#endif

    // Boards whose I2C traces don't match the BSP's default Wire pins
    // (e.g. RAK4631: the generic pca10056 BSP defaults to P0.26/P0.27,
    // but the WisBlock I2C1 bus actually used is P0.13/P0.14) must
    // override via Wire.setPins() BEFORE Wire.begin() — begin() reads
    // the pin selection immediately and setPins() after begin() has no
    // effect. Confirmed via hardware testing: without this override,
    // Wire.begin() succeeds silently but every address NAKs because
    // nothing is physically wired to P0.26/P0.27.
#if defined(PIN_I2C_SDA) && defined(PIN_I2C_SCL)
    Wire.setPins(PIN_I2C_SDA, PIN_I2C_SCL);
#endif
    Wire.begin();

    // ---- BME280 probe ----
    // Try the primary (SDO=GND) address first since that's the most
    // common off-the-shelf wiring; fall back to the secondary
    // (SDO=VDD) address only if the primary NAKs.
    s_bme_present = false;
    if (s_bme.begin(BME280_ADDR_PRIMARY)) {
        s_bme_present = true;
        Serial.print("Sensors: BME280 found at 0x");
        Serial.print(BME280_ADDR_PRIMARY, HEX);
        Serial.println();
    } else if (s_bme.begin(BME280_ADDR_SECONDARY)) {
        s_bme_present = true;
        Serial.print("Sensors: BME280 found at 0x");
        Serial.print(BME280_ADDR_SECONDARY, HEX);
        Serial.println();
    }

    if (!s_bme_present) {
        Serial.println("Sensors: no BME280 detected on I2C");
    }

    // ---- INA3221 probe ----
    // Try each of the 4 A0-strap addresses in turn (see
    // INA3221_ADDR_CANDIDATES comment above) — off-the-shelf WisBlock
    // sensor boards have been observed at 0x42, not the 0x40 GND-strap
    // default, so don't assume GND strapping.
    s_ina_present = false;
    for (uint8_t addr : INA3221_ADDR_CANDIDATES) {
        if (s_ina.begin(addr)) {
            s_ina_present = true;
            Serial.print("Sensors: INA3221 found at 0x");
            Serial.print(addr, HEX);
            Serial.println();
            break;
        }
    }
    if (!s_ina_present) {
        Serial.println("Sensors: no INA3221 detected on I2C");
    }

    return true;
#endif
}

bool bme_present() { return s_bme_present; }
bool ina_present() { return s_ina_present; }

bool read_bme(float& temp_c, float& humidity_pct, float& pressure_mbar) {
#if !(defined(HAS_I2C_HEADER) && HAS_I2C_HEADER)
    (void)temp_c; (void)humidity_pct; (void)pressure_mbar;
    return false;
#else
    if (!s_bme_present) return false;
    temp_c         = s_bme.readTemperature();     // °C
    humidity_pct   = s_bme.readHumidity();        // % RH
    // Adafruit BME280 reports pressure in Pa. Sideband / common
    // weather APIs use hPa (numerically equal to mbar). Convert
    // once at the read site so downstream code doesn't have to.
    pressure_mbar  = s_bme.readPressure() / 100.0f;
    return true;
#endif
}

bool read_ina(float& ch1_v, float& ch1_ma,
              float& ch2_v, float& ch2_ma,
              float& ch3_v, float& ch3_ma) {
#if !(defined(HAS_I2C_HEADER) && HAS_I2C_HEADER)
    (void)ch1_v; (void)ch1_ma;
    (void)ch2_v; (void)ch2_ma;
    (void)ch3_v; (void)ch3_ma;
    return false;
#else
    if (!s_ina_present) return false;
    // IMPORTANT: Adafruit_INA3221's getBusVoltage()/getCurrentAmps() take
    // a 0-BASED channel index (0/1/2 -> physical CH1/CH2/CH3 registers;
    // the library explicitly returns NaN for channel >= 3). A previous
    // version of this code passed 1/2/3, which silently read CH2/CH3/
    // (invalid->NaN) instead of CH1/CH2/CH3 — confirmed via hardware
    // testing (ch3 read back as NaN, exactly matching the library's
    // invalid-channel guard). Current is reported in amps; convert to
    // mA so downstream code matches the rest of the project's mA-grain
    // readings.
    ch1_v  = s_ina.getBusVoltage(0);            // V, relative to GND (physical CH1)
    ch1_ma = s_ina.getCurrentAmps(0) * 1000.0f; // A -> mA, signed
    ch2_v  = s_ina.getBusVoltage(1);            // physical CH2
    ch2_ma = s_ina.getCurrentAmps(1) * 1000.0f;
    ch3_v  = s_ina.getBusVoltage(2);            // physical CH3
    ch3_ma = s_ina.getCurrentAmps(2) * 1000.0f;
    return true;
#endif
}

void scan_bus(Print& out) {
#if !(defined(HAS_I2C_HEADER) && HAS_I2C_HEADER)
    (void)out;
    return;
#else
    int found = 0;
    for (uint8_t addr = 0x03; addr <= 0x77; addr++) {
        Wire.beginTransmission(addr);
        uint8_t err = Wire.endTransmission();
        if (err == 0) {
            found++;
            out.print("0x");
            if (addr < 0x10) out.print('0');
            out.println(addr, HEX);
        }
    }
    if (found == 0) out.println("(no devices found)");
#endif
}

}} // namespace rlr::sensors
