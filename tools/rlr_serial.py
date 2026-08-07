#!/usr/bin/env python3
"""
rlr_serial.py — small line-protocol client for the RLR serial console.

Internal helper for tools/rlr.sh. Implements the same protocol that
tools/set-collector.py already uses (skip '['-prefixed async log lines,
skip the echoed command line, terminate on bare "OK" or "ERR: <msg>"),
plus a small retry policy for the occasional async-log-interleaving
race that surfaces as "ERR: unknown command" / "ERR: unknown key"
(see docs/SERIAL_PROTOCOL.md and the [alive] heartbeat lines emitted by
main.cpp).

Subcommands (exactly one required):
  probe <port>           — send STATUS with a short timeout (~2s).
                           exit 0 if any response arrived, 3 on timeout.
                           (Also prints the payload to stdout for debug.)
  dfu <port>             — send "DFU". exit 0 on OK, 2 on ERR.
  status <port>          — send "STATUS". print payload lines to stdout.
                           exit 0 on OK, 2 on ERR.
  config-get <port>      — send "CONFIG GET". print payload lines to stdout.
                           exit 0 on OK, 2 on ERR.
  config-set <port> K V  — send "CONFIG SET <K> <V>".
                           exit 0 on OK, 2 on ERR.
                           Retries on "unknown command/key" transient errors.
  config-reset <port>    — send "CONFIG RESET" (resets staging to
                           board defaults; doesn't touch flash).
                           exit 0 on OK, 2 on ERR.
  config-commit <port>   — send "CONFIG COMMIT". exit 0 on OK, 2 on ERR.

Exit codes:
  0 — OK
  1 — bad arguments / pyserial not installed
  2 — device returned ERR: <reason>
  3 — could not talk to the device at all (port open fail, or timeout)
"""
import sys
import time

try:
    import serial  # pyserial
except ImportError:
    print("error: pyserial is required (pip3 install pyserial)", file=sys.stderr)
    sys.exit(1)


DEFAULT_TIMEOUT = 5.0     # per-command read deadline
PROBE_TIMEOUT   = 2.0     # probe mode uses a shorter deadline
OPEN_DWELL      = 0.25    # seconds to wait after opening the port
READ_CHUNK_MIN  = 1       # bytes to ask pyserial for when buffer is empty

# Retry policy for transient "unknown command" / "unknown key" errors,
# which on this firmware family are almost always caused by an async
# "[alive]" heartbeat log line interleaving with the command echo on
# the RX side — the firmware then parses a mangled line. Re-sending the
# same command a moment later (after the heartbeat has flushed) is
# effectively a cure. Two retries is plenty in practice.
RETRIES         = 2
RETRY_BACKOFF_S = 0.3
RETRY_TRIGGERS  = ("unknown command", "unknown key", "unknown subcommand")


def send(ser, cmd, timeout):
    """Send one line-oriented command, collect its response.

    Mirrors tools/set-collector.py's protocol handling exactly:
    skip async '['-prefixed log noise, skip the command's own echo,
    terminate on a bare "OK" or an "ERR: <reason>" line.

    Returns (ok, payload_lines, err_msg_or_None).
    """
    ser.reset_input_buffer()
    ser.write((cmd + "\n").encode("utf-8"))
    ser.flush()

    payload = []
    saw_echo = False
    deadline = time.time() + timeout
    buf = ""

    while time.time() < deadline:
        n = ser.in_waiting or READ_CHUNK_MIN
        chunk = ser.read(n)
        if not chunk:
            continue
        buf += chunk.decode("utf-8", errors="replace")
        while "\r" in buf or "\n" in buf:
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
                # Async status/log line from main.cpp — ignore.
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


def send_with_retry(ser, cmd, timeout):
    """send() with simple retry on transient "unknown ..." ERR replies."""
    last_err = None
    last_payload = []
    for attempt in range(RETRIES + 1):
        ok, payload, err = send(ser, cmd, timeout)
        if ok:
            return True, payload, None
        last_err = err
        last_payload = payload
        if not err:
            return False, payload, err
        if not any(t in err.lower() for t in RETRY_TRIGGERS):
            # Non-transient error (bad value, validation, etc.) — don't retry.
            return False, payload, err
        if attempt < RETRIES:
            time.sleep(RETRY_BACKOFF_S)
            ser.reset_input_buffer()
    return False, last_payload, last_err


def open_port(port):
    """Open + dwell + flush. Returns the Serial or None on open failure."""
    try:
        ser = serial.Serial(port, baudrate=115200, timeout=0.2)
    except Exception as e:
        print(f"error: could not open {port}: {e}", file=sys.stderr)
        return None
    time.sleep(OPEN_DWELL)
    ser.reset_input_buffer()
    return ser


def cmd_probe(port):
    """Quick STATUS probe — is the device alive and running app firmware?"""
    ser = open_port(port)
    if ser is None:
        return 3
    with ser:
        ok, payload, err = send(ser, "STATUS", PROBE_TIMEOUT)
    if ok:
        for line in payload:
            print(line)
        return 0
    if err == "timeout waiting for response":
        # No response within the probe window — most likely the device
        # is already in the bootloader (bootloaders don't speak our
        # line protocol). Caller treats this as "skip DFU step, flash directly".
        return 3
    # We got an ERR: back — the device is alive enough to respond, just
    # not with a clean STATUS. Still "running app firmware" for our purposes.
    for line in payload:
        print(line)
    print(f"(probe got ERR: {err})", file=sys.stderr)
    return 0


def cmd_touch(port):
    """1200-baud 'touch': open the port at 1200 baud then close it. This
    is the standard software-only bootloader-entry trick for
    Arduino/Adafruit boards (equivalent to a physical double-tap of
    RESET on most nRF52 boards using the Adafruit bootloader) - useful
    when the device is sealed/inaccessible and a hard reset isn't an
    option. Does not itself detect re-enumeration; the caller
    (rlr.sh) is responsible for re-scanning for the port afterward,
    since many boards enumerate the bootloader on a different
    /dev/ttyACM* path than the app was using.
    """
    try:
        touch_port = serial.Serial(port=port, baudrate=1200, timeout=1)
    except Exception as e:
        print(f"error: could not open {port} at 1200 baud for touch: {e}", file=sys.stderr)
        return 1
    time.sleep(0.25)
    touch_port.close()
    print(f"touched {port} at 1200 baud")
    return 0


def cmd_send(port, cmd, timeout=DEFAULT_TIMEOUT, retry=False):
    """Send a command, print payload lines, return exit code (0/2/3)."""
    ser = open_port(port)
    if ser is None:
        return 3
    with ser:
        if retry:
            ok, payload, err = send_with_retry(ser, cmd, timeout)
        else:
            ok, payload, err = send(ser, cmd, timeout)
    for line in payload:
        print(line)
    if ok:
        return 0
    if err:
        print(f"error: {err}", file=sys.stderr)
    return 2


def _usage():
    print(__doc__, file=sys.stderr)


def main():
    if len(sys.argv) < 2:
        _usage()
        sys.exit(1)
    sub, args = sys.argv[1], sys.argv[2:]

    if sub == "probe":
        if len(args) != 1:
            print("usage: rlr_serial.py probe <port>", file=sys.stderr); sys.exit(1)
        sys.exit(cmd_probe(args[0]))
    if sub == "dfu":
        if len(args) != 1:
            print("usage: rlr_serial.py dfu <port>", file=sys.stderr); sys.exit(1)
        sys.exit(cmd_send(args[0], "DFU"))
    if sub == "touch":
        if len(args) != 1:
            print("usage: rlr_serial.py touch <port>", file=sys.stderr); sys.exit(1)
        sys.exit(cmd_touch(args[0]))
    if sub == "status":
        if len(args) != 1:
            print("usage: rlr_serial.py status <port>", file=sys.stderr); sys.exit(1)
        sys.exit(cmd_send(args[0], "STATUS"))
    if sub == "config-get":
        if len(args) != 1:
            print("usage: rlr_serial.py config-get <port>", file=sys.stderr); sys.exit(1)
        sys.exit(cmd_send(args[0], "CONFIG GET"))
    if sub == "config-set":
        if len(args) != 3:
            print("usage: rlr_serial.py config-set <port> <key> <value>", file=sys.stderr); sys.exit(1)
        port, key, value = args
        # split_kv in SerialConsole.cpp splits at the FIRST whitespace
        # after "CONFIG SET", so everything from the first space onward
        # is the value — including further spaces. No quoting needed.
        cmd = f"CONFIG SET {key} {value}"
        sys.exit(cmd_send(port, cmd, retry=True))
    if sub == "config-commit":
        if len(args) != 1:
            print("usage: rlr_serial.py config-commit <port>", file=sys.stderr); sys.exit(1)
        sys.exit(cmd_send(args[0], "CONFIG COMMIT"))
    if sub == "config-reset":
        if len(args) != 1:
            print("usage: rlr_serial.py config-reset <port>", file=sys.stderr); sys.exit(1)
        sys.exit(cmd_send(args[0], "CONFIG RESET"))

    print(f"unknown subcommand: {sub}", file=sys.stderr)
    _usage()
    sys.exit(1)


if __name__ == "__main__":
    main()
