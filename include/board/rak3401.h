#pragma once
// =====================================================================
//  include/board/rak3401.h
//  ------------------------------------------------------------------
//  RAK3401 1-Watt — WisBlock module with nRF52840 + SX1262 + 1W PA
//
//  Pin values from Meshtastic firmware variant
//  variants/nrf52840/rak3401_1watt (commit 9322bcdb).
//  The variant.cpp uses direct 1:1 pin mapping (Arduino pin N =
//  nRF52840 P0.N / P1.(N-32)), same as pca10056.
//
//  Key differences from RAK4631:
//    * Different control pin assignments (CS=26, DIO1=10, BUSY=9,
//      RESET=4 vs RAK4631's 42/47/46/38)
//    * Same SPI1 pins as RAK4631 (29/30/3) — both WisBlock modules
//      wire the SX1262 to the same nRF52840 SPI pins
//    * POWER_EN on pin 21 (radio 3V3 gate)
//    * 3V3_EN on pin 34 (general 3V3 rail)
//    * 1-Watt external PA — RADIO_MAX_DBM stays at 22 (SX1262 core
//      max); the external PA adds gain but is not software-controlled
// =====================================================================

// ---- Board identity ------------------------------------------------
#define BOARD_NAME              "RAK3401 1W"
#define BOARD_MANUFACTURER      "RAKwireless"
#define BOARD_RAK3401           0x55
#define PRODUCT_RAK3401         0x21
#define MODEL_RAK3401           0x21

// ---- Capability flags ----------------------------------------------
#define HAS_TCXO                1
#define HAS_RF_SWITCH_RX_TX     1      // DIO2 handles TX/RX switching
#define HAS_BUSY                1
#define HAS_LED                 1
#define HAS_BUTTON              0
#define HAS_BATTERY_SENSE       1
#define HAS_VEXT_RAIL           1      // POWER_EN on pin 21
#define HAS_DISPLAY             0
#define HAS_BLE                 1
#define HAS_PMU                 0

// ---- MCU / SRAM budget --------------------------------------------
#define BOARD_MCU               "nRF52840"
#define BOARD_SRAM_BYTES        262144
#define BOARD_FLASH_BYTES       1048576

// ---- Radio module --------------------------------------------------
#define RADIO_CHIP              "SX1262"
#define RADIO_MODULE            "RAK3401 integrated + 1W PA"
#define RADIO_TCXO_VOLTAGE_MV   1800
#define RADIO_SPI_OVERRIDE_PINS 1
#define RADIO_DIO2_AS_RF_SWITCH 1
#define RADIO_MAX_DBM           22     // SX1262 core max; ext PA adds gain

// Optional register 0x8B5 patch (undocumented SX126x register) - MeshCore's
// CustomSX1262.h applies this for "improved RX" on boards with an external
// FEM (RAK3401/RAK13302, Heltec V4). Not required for basic RX to work (the
// real root cause of this board's initial RX-dead symptom was a spreading
// factor mismatch against the mesh, not this register) - kept here purely
// for parity with the proven-working reference and any sensitivity gain it
// provides.
#define RADIO_SX126X_REGISTER_PATCH 1

// TX current limit matching MeshCore's rak3401 env (SX126X_CURRENT_LIMIT=140
// in their platformio.ini) - the 1W external PA draws more current than the
// SX1262 core's own default OCP threshold expects.
#define RADIO_CURRENT_LIMIT_MA  140

// ---- Pin numbers (pca10056 convention, 1:1 mapping) ----------------
//
// LoRa SPI uses the same physical pins as RAK4631's SPI1:
//   MISO=29 (P0.29), MOSI=30 (P0.30), SCK=3 (P0.03)
// Control pins differ from RAK4631.
//
#define PIN_LORA_NSS            26    // P0.26
#define PIN_LORA_SCK            3     // P0.03
#define PIN_LORA_MOSI           30    // P0.30
#define PIN_LORA_MISO           29    // P0.29
#define PIN_LORA_RESET          4     // P0.04
#define PIN_LORA_BUSY           9     // P0.09
#define PIN_LORA_DIO1           10    // P0.10
#define PIN_LORA_RXEN           -1    // no external LNA — DIO2 handles everything
#define PIN_LORA_TXEN           -1

// Power
#define PIN_VEXT_EN             21    // P0.21 — SX126X_POWER_EN (radio 3V3 gate)
#define VEXT_SETTLE_MS          10
//
// PIN_3V3_EN / WB_IO2 (34, P1.02) — NOT just a generic "assumed on" rail.
// Per RAK13302's actual FEM design (SKY66122-11): this pin gates the 5V
// boost regulator (U5) that powers the PA/LNA front-end module itself.
// SX126X_POWER_EN (21, above) only enables the FEM's CSD/CPS control
// lines; WITHOUT this separate 5V rail also enabled, the FEM has no
// supply at all. Symptom if left unmanaged: TX still radiates (weakly,
// via whatever passive/leakage path exists without the PA's LNA/gain
// stage powered), but RX is completely dead (zero packets received,
// ever) since the LNA needed to receive anything has no power. This
// was NOT understood when this board profile was first written — the
// original assumption that "it's assumed to be on by the bootloader"
// was wrong and left RX totally non-functional. Confirmed via MeshCore's
// own RAK3401Board.cpp (the only public reference with correct RAK13302
// FEM control), cross-referenced against Meshtastic's rak3401_1watt
// variant (which drives this same pin high in its own main.cpp init).
#define PIN_WB_IO2               34    // P1.02 — 5V boost enable for the RAK13302 FEM
#define WB_IO2_SETTLE_MS         10

// Battery — PIN_A0 = pin 5 (P0.05) via voltage divider
#define PIN_BATTERY             5     // P0.05
#define BATTERY_ADC_RESOLUTION  12

// LED — PIN_LED1 = 35 (P1.03), same as RAK4631
#define PIN_LED                 35    // P1.03
#define LED_ACTIVE_HIGH         1

// ---- Default config values for first boot -------------------------
#define DEFAULT_CONFIG_FREQ_HZ          915000000UL
#define DEFAULT_CONFIG_BW_HZ            125000UL
// SF7 to match the rest of this mesh's convention (RAK4631/femtofox/local
// reference RNode all run SF7). This board's default was originally SF10
// (a reasonable-looking but untested guess) - confirmed via live hardware
// bring-up that a mismatched SF here causes a 100% RX-dead symptom (freq/
// bandwidth/sync word all matching is NOT sufficient; SF must match too).
#define DEFAULT_CONFIG_SF               7
#define DEFAULT_CONFIG_CR               5
#define DEFAULT_CONFIG_TXP_DBM          22     // 1W PA, higher default
// Previously 2.198f on the (wrong) assumption that this board uses "the
// same divider as RAK4631" (RAK4631's own default was 1.26709f — note
// even that comparison was internally inconsistent). Empirically
// calibrated on real RAK3401 hardware via the serial console's
// CALIBRATE BATTERY workflow (multimeter-measured 4190 mV vs.
// battery_raw=2782, with USB disconnected to rule out charge-line
// bias): batt_mult = 4190 / 2782 = 1.506111. An independently-
// calibrated RAK4631 unit landed at 1.509084 (see rak4631.h) —
// near-identical, so the "same divider as RAK4631" assumption turned
// out to be true after all, just not at the old 2.198/1.26709
// constants. Rounded to a shared 1.5f default for both boards; still
// just two samples — per-board CALIBRATE BATTERY remains the source
// of truth (see tools/rlr.sh calibrate-battery).
#define DEFAULT_CONFIG_BATT_MULT        1.5f
#define DEFAULT_CONFIG_DISPLAY_NAME     "RAK3401 Repeater"
