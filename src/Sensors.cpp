// src/Sensors.cpp — see Sensors.h.
//
// I2C sensor probing and reading for the optional BME280 (temp /
// humidity / pressure) and INA3221 (bus voltage / current) chips.
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

bool init() {
#if !(defined(HAS_I2C_HEADER) && HAS_I2C_HEADER)
    Serial.println("Sensors: HAS_I2C_HEADER=0 — no sensor probing");
    return true;
#else
    // Initialise the Wire peripheral with the BSP-default SDA / SCL
    // pins (the Adafruit nRF52 variant for nrf52840_dk_adafruit
    // exposes these as Wire-defined constants; no need to pass explicit
    // pin numbers unless a board requires non-default traces).
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
    // Adafruit_INA3221::begin() with no args talks to the default
    // 0x40 address (A0=GND). Returns true on successful reset / ID
    // register read.
    s_ina_present = false;
    if (s_ina.begin()) {
        s_ina_present = true;
        Serial.print("Sensors: INA3221 found at default 0x");
        Serial.print(INA3221_ADDR_DEFAULT, HEX);
        Serial.println();
    } else {
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

bool read_ina(float& bus_voltage_v, float& current_ma) {
#if !(defined(HAS_I2C_HEADER) && HAS_I2C_HEADER)
    (void)bus_voltage_v; (void)current_ma;
    return false;
#else
    if (!s_ina_present) return false;
    // Channel 1 (chip-indexed; Adafruit's wrapper is 1-based and
    // matches the INA3221 datasheet's CH1/CH2/CH3 silkscreen on
    // most WisBlock sensor boards). Easy to bump later if a user
    // asks for per-channel telemetry; keep it as one rail for v1.
    // Adafruit_INA3221 v1.0.1 reports current in amps via
    // getCurrentAmps(); convert to mA here so downstream code
    // matches the rest of the project's mA-grain readings.
    bus_voltage_v = s_ina.getBusVoltage(1);            // V, relative to GND
    current_ma    = s_ina.getCurrentAmps(1) * 1000.0f; // A -> mA, signed
    return true;
#endif
}

}} // namespace rlr::sensors
