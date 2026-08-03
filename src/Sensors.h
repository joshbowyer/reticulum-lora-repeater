#pragma once
#include <Print.h>
// =====================================================================
//  src/Sensors.h — optional I2C sensor telemetry (BME280 + INA3221).
//
//  Auto-detects supported environmental/power sensors on the I2C bus
//  at boot. Probing failure is NOT an error — boards with no sensors
//  attached just report nothing. Zero required configuration.
//
//  Gate is the per-board capability flag `HAS_I2C_HEADER` (defined in
//  include/board/<name>.h). When undefined or set to 0, init() no-ops
//  and both _present() accessors return false; no I2C / Wire / sensor
//  library code is compiled into the firmware.
//
//  Library choice: Adafruit_BME280 and Adafruit_INA3221, both with
//  Adafruit_BusIO under them — using one vendor's ecosystem keeps
//  I2C transaction semantics consistent. RobTillaart/INA3221 was the
//  alternative (single-header, no deps) but mixing in a second
//  Arduino driver ecosystem for one chip didn't seem worth it.
//
//  Behaviour contract:
//    init()                       — safe to call once at boot. Returns
//                                   true unconditionally (sensor
//                                   absent is a valid outcome).
//    bme_present() / ina_present() — static after init; safe to poll
//                                    from any thread.
//    read_bme(...) / read_ina(...) — returns false (leaves out args
//                                    untouched) if the sensor is not
//                                    present; returns true with
//                                    populated out args on success.
//                                    Never throws, never busy-waits
//                                    more than a couple of ms.
// =====================================================================

namespace rlr { namespace sensors {

// One-time init. Calls Wire.begin() (default-variant pins — Wire's
// SDA/SCL on the Adafruit nRF52 BSP default to the board's PCB
// traces for the WisBlock IO header on RAK4631), then probes the
// bus for a BME280 (addresses 0x76 then 0x77) and an INA3221
// (default address 0x40). Always returns true — a "no sensors
// attached" outcome is a successful boot.
bool init();

// True if a BME280 (temp / humidity / pressure) was detected at init.
// When false, read_bme() always returns false.
bool bme_present();

// True if an INA3221 (3-channel bus voltage / current monitor) was
// detected at init. When false, read_ina() always returns false.
bool ina_present();

// Read BME280 environmental data. On success populates temp_c
// (degrees Celsius), humidity_pct (% RH), pressure_mbar (hPa ≡ mbar)
// and returns true. Returns false (out args untouched) if no BME280
// is present.
bool read_bme(float& temp_c, float& humidity_pct, float& pressure_mbar);

// Read all 3 INA3221 channels: bus voltage (V) and current (mA, signed).
// Channel semantics (which one is solar/battery/etc.) are wiring-defined
// by the operator; see Config.ina_ch*_label.
// Returns false (all out args untouched) if no INA3221 is present.
bool read_ina(float& ch1_v, float& ch1_ma,
              float& ch2_v, float& ch2_ma,
              float& ch3_v, float& ch3_ma);

// Diagnostic: scan the I2C bus (addresses 0x03-0x77) and print every
// address that ACKs to `out`, one per line as "0x<hex>". Prints
// "(no devices found)" if nothing responds. No-ops (prints nothing,
// returns immediately) when HAS_I2C_HEADER is unset. Safe to call at
// any time after init() — does not disturb sensor presence state.
void scan_bus(Print& out);

}} // namespace rlr::sensors
