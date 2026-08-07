#!/usr/bin/env python3
"""
.rlr_serial_test_stub.py — dry-run stub for tools/rlr_serial.py.

Mimics the line interface (same subcommands, same exit codes) but
NEVER opens a real serial port. Instead:

  - All commands are logged to a per-test log file (--log <path>).
  - config-get / probe / status print a canned CONFIG GET-style
    payload to stdout (defaults to a freshly-reset device).
  - config-set appends a line "SET key value" to the log and exits 0.
  - config-commit appends "COMMIT" to the log and exits 0.
  - config-reset appends "RESET" to the log and exits 0.
  - probe exits 0 (device is "alive").
  - dfu exits 0 (device is "alive").

This lets tools/rlr.sh's interactive flow run end-to-end against a
fake device so we can verify prompts, validation, change-summary
formatting, and the CONFIG SET/COMMIT sequence without real hardware.

NOT shipped — kept in tools/ as a hidden file for local testing only.
"""
import sys
import time


CANNED_CONFIG_GET = """\
display_name=Rptr-DEADBEEF1234
freq_hz=915000000
bw_hz=125000
sf=10
cr=5
txp_dbm=22
tx_enabled=0
batt_mult=1.2671
tele_interval_ms=10800000
lxmf_interval_ms=1800000
telemetry=1
lxmf=1
heartbeat=1
bt_enabled=0
bt_pin=0
latitude=0.000000
longitude=0.000000
altitude=0
log_level=1
collector=
ina_ch1_label=
ina_ch2_label=
ina_ch3_label=
"""

# A second canned payload with non-default values, for testing the
# "no changes" branch + the change-summary display.
CANNED_CONFIG_GET_NONDEFAULT = """\
display_name=Solar Site North
freq_hz=904375000
bw_hz=250000
sf=11
cr=8
txp_dbm=17
tx_enabled=1
batt_mult=1.2840
tele_interval_ms=600000
lxmf_interval_ms=900000
telemetry=0
lxmf=1
heartbeat=0
bt_enabled=1
bt_pin=123456
latitude=40.712800
longitude=-74.006000
altitude=15
log_level=2
collector=0123456789abcdef0123456789abcdef
ina_ch1_label=solar
ina_ch2_label=batt
ina_ch3_label=load
"""


def log_line(log_path, line):
    if log_path:
        with open(log_path, "a") as f:
            f.write(line + "\n")


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    args = sys.argv[1:]

    # Args layout: [--log <path>] [--payload <name>] <subcommand> [args...]
    # Also reads RLR_STUB_LOG and RLR_STUB_PAYLOAD from env so the
    # stub can be used as a drop-in for tools/rlr_serial.py in tests
    # without needing to change how rlr.sh invokes it.
    import os
    log_path = os.environ.get("RLR_STUB_LOG")
    payload_name = os.environ.get("RLR_STUB_PAYLOAD", "default")
    while args and args[0].startswith("--"):
        if args[0] == "--log":
            log_path = args[1]
            args = args[2:]
        elif args[0] == "--payload":
            payload_name = args[1]
            args = args[2:]
        else:
            print(f"unknown flag: {args[0]}", file=sys.stderr)
            sys.exit(1)

    if not args:
        print("usage: rlr_serial_test_stub.py [--log PATH] [--payload NAME] <subcommand> [args...]", file=sys.stderr)
        sys.exit(1)

    sub = args[0]
    sub_args = args[1:]

    if sub == "probe":
        log_line(log_path, "PROBE")
        # Print a tiny "alive" payload so callers see what they'd see
        print("uptime_s=1")
        print("radio=up")
        print("tx=disabled")
        sys.exit(0)
    if sub == "dfu":
        log_line(log_path, "DFU")
        sys.exit(0)
    if sub == "status":
        log_line(log_path, "STATUS")
        print("uptime_s=1")
        print("radio=up")
        sys.exit(0)
    if sub == "config-get":
        log_line(log_path, "CONFIG_GET")
        if payload_name == "nondefault":
            print(CANNED_CONFIG_GET_NONDEFAULT, end="")
        else:
            print(CANNED_CONFIG_GET, end="")
        sys.exit(0)
    if sub == "config-set":
        if len(sub_args) != 3:
            print("usage: stub config-set <port> <key> <value>", file=sys.stderr); sys.exit(1)
        _, key, value = sub_args
        log_line(log_path, f"SET {key} {value}")
        sys.exit(0)
    if sub == "config-reset":
        log_line(log_path, "RESET")
        sys.exit(0)
    if sub == "config-commit":
        log_line(log_path, "COMMIT")
        # Pretend reboot delay
        time.sleep(0.05)
        sys.exit(0)

    print(f"unknown subcommand: {sub}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
