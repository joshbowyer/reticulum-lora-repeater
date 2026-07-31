# Status

Quick snapshot for anyone picking this up cold. User-facing docs live
in `README.md` and `docs/`; this file just tracks current build/feature
state at a glance.

## Current state

Shipping firmware — tagged releases (`v0.5.x`) published to GitHub
Releases and the web flasher (`docs/firmware/`). All six board envs
(`Faketec`, `RAK4631`, `XIAO_nRF52840`, `Heltec_T114`, `RAK3401`,
`T-Echo`) build from a single source tree; `native` runs the host test
suite.

- **Radio / transport** — RadioLib-driven SX1262, full Reticulum
  transport node: announce rebroadcast, DATA/PROOF forwarding, RNode
  split-packet reassembly. Forwarding for transit packets is added by
  the one remaining microReticulum patch in `scripts/pre_build.py`.
- **Config** — schema **v3**, persisted to internal flash via
  microStore. v1/v2 records auto-migrate forward. Editable over USB
  serial, BLE, and the web console. See `docs/CONFIG_FORMAT.md`.
- **Telemetry** — spec-compliant LXMF `FIELD_TELEMETRY` pushed to a
  configured collector (Sideband Telemeter format), replacing the old
  ASCII `rlr.telemetry` beacon. Gated on a configured `collector` hash.
  When the board defines `HAS_I2C_HEADER 1` (currently RAK4631 only),
  a BME280 / INA3221 sensor module on the I2C bus is auto-detected at
  boot and its readings are merged in: temp / humidity / pressure get
  their own Sideband sensor IDs, INA3221 power-rail data appends to
  the free-form `SID_INFORMATION` text (no dedicated Sideband SID for
  arbitrary rail monitoring).
- **LXMF presence** — announces on `lxmf.delivery` so MeshChat /
  Sideband show the node by name.
- **BLE / web flasher / serial console** — all live; see `README.md`.

## Dependencies

`microReticulum` and `microStore` are **pinned to specific commits** in
`platformio.ini` for reproducible builds. Bump the pins deliberately to
take upstream changes.

Reticulum 0.7+ **ratchet announce validation is native in the pinned
microReticulum** — the local ratchet patch this firmware used to carry
was removed as redundant. Background in `docs/RATCHET_PROTOCOL.md`.

## Open items / caveats

- **Hardware validation of telemetry.** The Sideband Telemeter byte
  layout and the opportunistic LXMF send path build and link, but a
  live round-trip against a real Sideband instance is still the
  authoritative check.
- **Hardware validation of I2C sensor telemetry.** BME280 +
  INA3221 support is brand new and has never been tested against a
  physical WisBlock sensor module on the bench. The auto-detect
  probes, the SID encoding, and the lib_deps additions are
  unverified on real hardware. Treat readings as best-effort until a
  side-by-side multimeter / known-good sensor confirms calibration.
  SID_TEMPERATURE / SID_HUMIDITY / SID_PRESSURE are packed as
  single-element float arrays (matching the SID_BATTERY /
  SID_LOCATION precedent in `src/Telemetry.cpp`), not as the
  string-keyed dicts upstream `sense.py` emits natively — see the
  header of `Telemetry.cpp` for why and what a future msgpack-writer
  extension would have to do to flip this.
- **No RTC.** Telemetry/LXMF timestamps are monotonic uptime, not
  wall-clock; receivers display against their own receive clock.
- **No packet fragmentation** beyond RNode split-packet (≤508 B).
- **No CSMA / airtime tracking** — TX is synchronous through the driver.
