#!/usr/bin/env python3
"""
set-collector.py — point an RLR repeater's telemetry at a new collector.

Wraps the existing serial provisioning console (see docs/SERIAL_PROTOCOL.md /
docs/console.js) to set + commit the `collector` config key in one step,
with hash validation so a typo doesn't silently brick telemetry delivery
until the next manual check.

Usage:
    python3 set-collector.py /dev/ttyACM0 <32-hex-char-destination-hash>
    python3 set-collector.py /dev/ttyACM0 --clear
    python3 set-collector.py /dev/ttyACM0 --show

Examples:
    python3 set-collector.py /dev/ttyACM0 da424e0f47657d7575df58a2b83b111b
    python3 set-collector.py /dev/ttyACM0 --show

Exit codes: 0 success, 1 bad arguments/invalid hash, 2 device rejected the
command (see printed error), 3 could not talk to the device at all.
"""
import argparse
import re
import sys
import time

try:
    import serial
except ImportError:
    print("error: pyserial is required (pip install pyserial)", file=sys.stderr)
    sys.exit(3)

HASH_RE = re.compile(r"^[0-9a-fA-F]{32}$")


def send(ser: "serial.Serial", cmd: str, timeout: float = 5.0):
    """Send one line-oriented console command, collect its response.

    Mirrors rlr_console.py's protocol handling exactly: skip async '['-
    prefixed log noise, skip the command's own echo, terminate on a bare
    'OK' or an 'ERR: <reason>' line.
    """
    ser.reset_input_buffer()
    ser.write((cmd + "\n").encode("utf-8"))
    ser.flush()

    payload = []
    saw_echo = False
    deadline = time.time() + timeout
    buf = ""

    while time.time() < deadline:
        chunk = ser.read(ser.in_waiting or 1)
        if not chunk:
            continue
        buf += chunk.decode("utf-8", errors="replace")
        while "\n" in buf or "\r" in buf:
            idx_r = buf.find("\r")
            idx_n = buf.find("\n")
            candidates = [i for i in (idx_r, idx_n) if i >= 0]
            if not candidates:
                break
            idx = min(candidates)
            line = buf[:idx]
            skip = 2 if buf[idx:idx + 2] == "\r\n" else 1
            buf = buf[idx + skip:]
            if line == "":
                continue
            if line.startswith("["):
                continue
            if not saw_echo and line.strip() == cmd.strip():
                saw_echo = True
                continue
            if line == "OK":
                return True, payload, None
            if line.startswith("ERR:"):
                return False, payload, line[4:].strip()
            payload.append(line)
    return False, payload, "timeout waiting for response"


def get_current_collector(ser) -> str:
    ok, payload, err = send(ser, "CONFIG GET")
    if not ok:
        raise RuntimeError("CONFIG GET failed: " + str(err))
    for line in payload:
        if line.strip().startswith("collector="):
            return line.split("=", 1)[1].strip()
    return "(not set)"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", help="serial port, e.g. /dev/ttyACM0")
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("collector_hash", nargs="?", default=None,
                        help="32 hex char LXMF/RNS destination hash to set as the collector")
    group.add_argument("--clear", action="store_true",
                        help="clear the collector (sets it to all-zeros, disabling telemetry delivery)")
    group.add_argument("--show", action="store_true",
                        help="just print the currently configured collector hash and exit, no changes")
    args = ap.parse_args()

    if args.collector_hash and not args.show and not args.clear:
        if not HASH_RE.match(args.collector_hash):
            print(f"error: '{args.collector_hash}' is not a valid 32-character hex hash "
                  f"(got {len(args.collector_hash)} chars)", file=sys.stderr)
            sys.exit(1)

    try:
        ser = serial.Serial(args.port, baudrate=115200, timeout=0.2)
    except Exception as e:
        print(f"error: could not open {args.port}: {e}", file=sys.stderr)
        sys.exit(3)

    with ser:
        time.sleep(0.3)
        ser.reset_input_buffer()

        if args.show:
            try:
                current = get_current_collector(ser)
            except RuntimeError as e:
                print(f"error: {e}", file=sys.stderr)
                sys.exit(2)
            print(f"collector = {current}")
            sys.exit(0)

        try:
            before = get_current_collector(ser)
        except RuntimeError:
            before = "(unknown)"

        new_hash = "0" * 32 if args.clear else args.collector_hash
        action = "clearing" if args.clear else f"setting to {new_hash}"
        print(f"current collector: {before}")
        print(f"{action}...")

        ok, payload, err = send(ser, f"CONFIG SET collector {new_hash}")
        if not ok:
            print(f"error: CONFIG SET rejected: {err}", file=sys.stderr)
            for line in payload:
                print("  " + line, file=sys.stderr)
            sys.exit(2)

        ok, payload, err = send(ser, "CONFIG COMMIT")
        if not ok:
            print(f"error: CONFIG COMMIT failed: {err}", file=sys.stderr)
            sys.exit(2)
        for line in payload:
            print(line)
        print("committed - device is rebooting, allow a few seconds before the next command")

    sys.exit(0)


if __name__ == "__main__":
    main()
