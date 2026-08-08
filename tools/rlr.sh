#!/usr/bin/env bash
# tools/rlr.sh — flash + configure an RLR (reticulum-lora-repeater)
# node from the command line. Mirrors what the project's web flasher
# does, but in a terminal. Internally shells out to
# tools/rlr_serial.py for the per-command serial round-trips (the
# line protocol with async [alive]-style log interleaving is fragile
# in pure bash, so we keep the serial plumbing in the proven Python
# helper while rlr.sh owns argument parsing, validation, the flash
# flow, and the interactive walkthrough).
#
# See:
#   - tools/rlr_serial.py   (this script's companion)
#   - tools/set-collector.py (legacy single-purpose tool, left in
#                              place for backward compat — `configure
#                              --collector` here supersedes it)
#   - src/SerialConsole.cpp (authoritative command syntax)
#   - src/Config.cpp        (authoritative field validation)

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERIAL_HELPER="$SCRIPT_DIR/rlr_serial.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# --- tiny logger / die helpers -----------------------------------

log()   { printf '[rlr.sh] %s\n' "$*" >&2; }
warn()  { printf '[rlr.sh] warning: %s\n' "$*" >&2; }
die()   { printf '[rlr.sh] error: %s\n' "$*" >&2; exit 1; }

# --- field table --------------------------------------------------
#
# Format: "key|type|prompt"
#   key    — the device-side CONFIG SET key (matches src/Config.cpp)
#   type   — int | uint | float | gt0float | bool | string |
#            inastring | collector
#   prompt — shown in the interactive walkthrough
#
# Type-specific rules live in validate_value() below; the prompt is
# the only place a human-readable label appears. Numeric ranges are
# deliberately omitted from this table — they live next to the
# validators so a future field-range change in firmware only needs to
# be made in one place (validate_value()), not two.
declare -A FIELDS=(
    [name]="display_name|string|Display name (1-31 chars, no '|')"
    [freq]="freq_hz|int|Frequency (Hz, 100000000-1100000000)"
    [bw]="bw_hz|int|Bandwidth (Hz, 7800-500000)"
    [sf]="sf|int|Spreading Factor (7-12)"
    [cr]="cr|int|Coding Rate denominator (5-8, i.e. 4/5..4/8)"
    [txp]="txp_dbm|int|TX Power (dBm, -9 to 22)"
    [tx-enabled]="tx_enabled|bool|TX enabled (fresh flash defaults to OFF; set 1 after confirming a region-legal freq)"
    [batt-mult]="batt_mult|gt0float|Battery ADC->mV calibration multiplier (>0 and <=10, must be calibrated per-board)"
    [tele-interval]="tele_interval_ms|uint|Telemetry push interval (ms)"
    [lxmf-interval]="lxmf_interval_ms|uint|LXMF presence announce interval (ms)"
    [telemetry]="telemetry|bool|Telemetry pushes enabled"
    [lxmf]="lxmf|bool|LXMF presence announces enabled"
    [heartbeat]="heartbeat|bool|Heartbeat announces enabled"
    [bt-enabled]="bt_enabled|bool|Bluetooth (BLE) enabled"
    [bt-pin]="bt_pin|int|Fixed BLE pairing PIN (0-999999, 0=disabled/no PIN)"
    [lat]="latitude|float|Latitude (degrees, -90.0 to 90.0)"
    [lon]="longitude|float|Longitude (degrees, -180.0 to 180.0)"
    [alt]="altitude|int|Altitude (meters, -100000 to 100000)"
    [log-level]="log_level|int|Log level (0=quiet, 1=normal, 2=verbose)"
    [collector]="collector|collector|Telemetry collector (32 hex chars, or 'none'/'off'/'clear' to disable)"
    [ina1-label]="ina_ch1_label|inastring|INA channel 1 label (max 7 chars, no '|', empty=unset)"
    [ina2-label]="ina_ch2_label|inastring|INA channel 2 label (max 7 chars, no '|', empty=unset)"
    [ina3-label]="ina_ch3_label|inastring|INA channel 3 label (max 7 chars, no '|', empty=unset)"
)

# The CLI flags in the order they should be prompted during the
# interactive walkthrough. Matches the order in the task spec table.
PROMPT_ORDER=(name freq bw sf cr txp tx-enabled batt-mult
              tele-interval lxmf-interval telemetry lxmf heartbeat
              bt-enabled bt-pin lat lon alt log-level collector
              ina1-label ina2-label ina3-label)


# === validate_value ===============================================
#
# Args: $1=type, $2=value, $3=flag (for error messages only)
# Returns 0 on valid, 1 on invalid. On invalid, sets VALIDATE_ERR to
# a short human-readable reason (caller decides how to surface it).
# Ranges must EXACTLY match src/Config.cpp's set_field() rules.
VALIDATE_ERR=""

validate_value() {
    local type="$1" value="$2" field="${3:-}"
    VALIDATE_ERR=""
    case "$type" in
        int)
            if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
                VALIDATE_ERR="must be an integer"; return 1
            fi
            case "$field" in
                freq)     [ "$value" -ge 100000000 ] && [ "$value" -le 1100000000 ] || { VALIDATE_ERR="must be in range 100000000-1100000000"; return 1; } ;;
                bw)       [ "$value" -ge 7800 ] && [ "$value" -le 500000 ]       || { VALIDATE_ERR="must be in range 7800-500000"; return 1; } ;;
                sf)       [ "$value" -ge 7 ] && [ "$value" -le 12 ]             || { VALIDATE_ERR="must be in range 7-12"; return 1; } ;;
                cr)       [ "$value" -ge 5 ] && [ "$value" -le 8 ]              || { VALIDATE_ERR="must be in range 5-8"; return 1; } ;;
                txp)      [ "$value" -ge -9 ] && [ "$value" -le 22 ]           || { VALIDATE_ERR="must be in range -9 to 22"; return 1; } ;;
                bt-pin)   [ "$value" -ge 0 ] && [ "$value" -le 999999 ]         || { VALIDATE_ERR="must be in range 0-999999 (0=disabled)"; return 1; } ;;
                alt)      [ "$value" -ge -100000 ] && [ "$value" -le 100000 ]   || { VALIDATE_ERR="must be in range -100000 to 100000"; return 1; } ;;
                log-level)[ "$value" -ge 0 ] && [ "$value" -le 2 ]              || { VALIDATE_ERR="must be in range 0-2"; return 1; } ;;
                *)        VALIDATE_ERR="internal: int field $field has no range"; return 1 ;;
            esac
            ;;
        uint)
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                VALIDATE_ERR="must be a non-negative integer"; return 1
            fi
            # No upper bound for tele_interval_ms / lxmf_interval_ms
            # per firmware (set_field only validates parse, not range).
            return 0
            ;;
        float)
            if ! [[ "$value" =~ ^-?[0-9]*\.?[0-9]+$ ]] && ! [[ "$value" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
                VALIDATE_ERR="must be a number"; return 1
            fi
            case "$field" in
                lat) awk -v v="$value" 'BEGIN { exit !(v+0 >= -90.0 && v+0 <= 90.0) }' \
                        || { VALIDATE_ERR="must be in range -90.0 to 90.0"; return 1; } ;;
                lon) awk -v v="$value" 'BEGIN { exit !(v+0 >= -180.0 && v+0 <= 180.0) }' \
                        || { VALIDATE_ERR="must be in range -180.0 to 180.0"; return 1; } ;;
                *)   VALIDATE_ERR="internal: float field $field has no range"; return 1 ;;
            esac
            ;;
        gt0float)
            if ! [[ "$value" =~ ^-?[0-9]*\.?[0-9]+$ ]] && ! [[ "$value" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
                VALIDATE_ERR="must be a number"; return 1
            fi
            # Firmware: > 0.0 && <= 10.0
            awk -v v="$value" 'BEGIN { exit !(v+0 > 0.0 && v+0 <= 10.0) }' \
                || { VALIDATE_ERR="must be > 0 and <= 10"; return 1; }
            ;;
        bool)
            case "${value,,}" in
                1|true|on|yes|0|false|off|no) return 0 ;;
                *) VALIDATE_ERR="must be 0/1, true/false, on/off, or yes/no"; return 1 ;;
            esac
            ;;
        string)
            local n=${#value}
            if [ "$n" -lt 1 ] || [ "$n" -gt 31 ]; then
                VALIDATE_ERR="must be 1-31 chars"; return 1
            fi
            if [[ "$value" == *"|"* ]]; then
                VALIDATE_ERR="must not contain '|'"; return 1
            fi
            ;;
        inastring)
            local n=${#value}
            if [ "$n" -gt 7 ]; then
                VALIDATE_ERR="must be at most 7 chars"; return 1
            fi
            if [ "$n" -gt 0 ] && [[ "$value" == *"|"* ]]; then
                VALIDATE_ERR="must not contain '|'"; return 1
            fi
            ;;
        collector)
            case "${value,,}" in
                none|off|clear|"") return 0 ;;
            esac
            if ! [[ "$value" =~ ^[0-9a-fA-F]{32}$ ]]; then
                VALIDATE_ERR="must be 32 hex chars or 'none'/'off'/'clear' to disable"
                return 1
            fi
            ;;
        *)
            VALIDATE_ERR="internal: unknown field type '$type'"
            return 1
            ;;
    esac
    return 0
}


# === port discovery ===============================================

# Print newline-separated list of candidate ports (sorted, unique).
# Linux only — the task spec scopes this tool to Linux.
list_candidate_ports() {
    {
        for p in /dev/ttyACM* /dev/ttyUSB*; do
            [ -e "$p" ] && echo "$p"
        done
    } | sort -u
}

# Pick a port. If 1 candidate exists, auto-select (print to stderr
# which one was chosen). If 0, die. If >1, list them numbered and
# prompt the user to pick.
#
# Used by configure when --dev isn't given.
pick_port_interactive() {
    local label="$1"
    local candidates
    candidates="$(list_candidate_ports)"
    local count
    count=$(printf '%s\n' "$candidates" | grep -c . || true)

    if [ "$count" -eq 0 ]; then
        die "no /dev/ttyACM* or /dev/ttyUSB* ports found${label:+ ($label)}. Plug in your RLR node, or pass --dev <port> explicitly."
    fi
    if [ "$count" -eq 1 ]; then
        local chosen
        chosen=$(printf '%s\n' "$candidates" | head -n1)
        log "auto-selected port: $chosen${label:+ ($label)}"
        printf '%s\n' "$chosen"
        return 0
    fi

    # Multiple candidates — prompt
    printf 'Multiple serial ports found%s:\n' "${label:+ ($label)}" >&2
    local i=1 p
    while IFS= read -r p; do
        printf '  %d) %s\n' "$i" "$p" >&2
        i=$((i+1))
    done <<< "$candidates"
    local choice
    local max="$count"
    while true; do
        read -r -p "Pick a port [1-$max]: " choice || die "input closed"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max" ]; then
            break
        fi
        echo "invalid choice: '$choice'" >&2
    done
    printf '%s\n' "$candidates" | sed -n "${choice}p"
}


# === subcommand: flash ============================================

cmd_flash() {
    local dev="" firmware="" board=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dev)      dev="$2"; shift 2 ;;
            --firmware) firmware="$2"; shift 2 ;;
            --board)    board="$2"; shift 2 ;;
            --help|-h)  usage; exit 0 ;;
            *)          die "unknown flash flag: $1 (use --help)" ;;
        esac
    done

    # --dev: auto-detect/prompt, same as configure/show/wipe.
    if [ -z "$dev" ]; then
        dev=$(pick_port_interactive "for flash") || exit 1
    fi
    [ -e "$dev" ] || die "serial port not found: $dev"

    if [ -n "$firmware" ]; then
        [ -f "$firmware" ] || die "firmware file not found: $firmware"
    else
        # No --firmware given: the primary path for this project is
        # `pio run -e <env> -t upload`, which builds AND flashes in
        # one step from a checked-out repo — there's no separate
        # prebuilt firmware.zip step in normal developer/user usage
        # (unlike some other flashing ecosystems). Resolve --board,
        # prompting interactively if it wasn't given.
        if [ -z "$board" ]; then
            board=$(pick_board_interactive) || exit 1
        fi
    fi

    require_serial_helper

    # 1. Quick probe — is the device running app firmware?
    log "probing $dev (sending STATUS, ~2s timeout)..."
    if "$PYTHON_BIN" "$SERIAL_HELPER" probe "$dev" >/dev/null 2>&1; then
        log "device responded — rebooting into the serial DFU bootloader"
        if ! "$PYTHON_BIN" "$SERIAL_HELPER" dfu "$dev" >/dev/null 2>&1; then
            warn "DFU command did not return OK; the device may already be in the bootloader or it dropped off mid-response. Continuing."
        fi
        log "waiting 3s for the bootloader to re-enumerate..."
        sleep 3
        # Re-find the port — bootloader re-enumerates on a different
        # /dev/ttyACMx index on many boards.
        dev=$(pick_port_interactive "after DFU reboot") || exit 1
    else
        # No response could mean the device is already in the bootloader
        # (fine) — but it could just as easily mean the app has crashed,
        # the board is genuinely fresh/never-flashed, or the port re-
        # enumerated already. Blindly assuming bootloader and proceeding
        # straight to a DFU upload has caused real failures ("No data
        # received on serial port... Target is not in DFU mode").
        #
        # Try a software-only "1200-baud touch" first — the standard
        # Arduino/Adafruit trick that's equivalent to a physical
        # double-tap of RESET on most nRF52 boards, useful when the
        # device is sealed/inaccessible. This does NOT guarantee success
        # (depends on the app firmware's USB stack still being alive to
        # notice the touch), so we still fall back to a manual prompt if
        # it doesn't clearly land on a bootloader-looking port.
        warn "no response on $dev — trying a 1200-baud touch to force bootloader entry (no physical access needed)..."
        warn "note: the touch only works if this device has run compatible app firmware before (it's the app's USB stack that detects the touch, not the bootloader). A board that has NEVER been flashed with this project's firmware will need one physical RESET (or double-tap) the first time — after that, the touch will work on it too."
        "$PYTHON_BIN" "$SERIAL_HELPER" touch "$dev" >/dev/null 2>&1 || true
        log "waiting 3s for the bootloader to (re-)enumerate..."
        sleep 3
        local touched_port=""
        if touched_port=$(pick_port_interactive_quiet 2>/dev/null) && [ -n "$touched_port" ]; then
            if [ "$touched_port" != "$dev" ]; then
                log "port changed after touch: $dev -> $touched_port"
            fi
            dev="$touched_port"
        else
            warn "couldn't confirm a single port after the touch attempt — continuing with $dev, but if the upload fails: this device may need a physical RESET (double-tap) if it's not sealed, or may already be fine as-is."
        fi
    fi

    # 2. Flash
    if [ -n "$firmware" ]; then
        log "flashing $(basename "$firmware") to $dev ..."
    else
        log "building + flashing env '$board' to $dev (pio run -t upload) ..."
    fi
    if ! flash_firmware "$dev" "$firmware" "$board"; then
        die "flash tool exited with error (see output above). Device may be in a half-flashed state — re-run with --dev <same-port> to retry.

If this device has NEVER been flashed with this project's firmware before, the 1200-baud touch above cannot help it — that trick only works because the APPLICATION firmware's USB stack detects the touch and jumps to the bootloader; a board with no compatible app running (bootloader-only/factory state, or third-party firmware) has nothing listening for it. A single physical RESET (or double-tap, depending on the board) is unavoidable the FIRST time on such a device. After that first successful flash, the touch will work on it going forward — this is a one-time requirement per device, not per session."
    fi

    # 3. Wait for app reboot + re-enumeration
    log "flash done — waiting 5s for the device to reboot into app firmware..."
    sleep 5

    local new_port=""
    if new_port=$(pick_port_interactive_quiet 2>/dev/null); then
        :
    else
        new_port=""
    fi

    # Sanity check: RAK4631/RAK3401 (and other boards sharing the same
    # bootloader/board target) are indistinguishable to the flash tool
    # itself - picking the wrong --board silently succeeds at the DFU
    # level but produces firmware that can't talk to the actual radio
    # wired up on that specific board (wrong SPI/control pins -> RadioLib
    # CHIP_NOT_FOUND). STATUS's radio=down after a fresh flash is the
    # first visible symptom of this - check for it here instead of
    # leaving the user to discover it later via a confusing "radio not
    # online" error on some unrelated command.
    local radio_warning=""
    if [ -n "$new_port" ]; then
        local status_out
        status_out=$("$PYTHON_BIN" "$SERIAL_HELPER" status "$new_port" 2>/dev/null) || true
        if printf '%s\n' "$status_out" | grep -q '^radio=down'; then
            radio_warning="yes"
        fi
    fi

    cat <<EOF

Flash complete!

The device reset to factory defaults for everything you didn't configure.
A freshly-flashed node boots RX-only with a placeholder display name —
set your frequency, region-legal TX power, display name, and a telemetry
collector (if you have one) before relying on it for traffic.

EOF
    if [ "$radio_warning" = "yes" ]; then
        echo "WARNING: radio=down right after flashing. This usually means the"
        echo "wrong --board was picked (e.g. flashing RAK4631 firmware onto an"
        echo "actual RAK3401, or vice versa — they use the same bootloader/DFU"
        echo "target so the flash tool can't tell them apart, but the pin"
        echo "mapping differs and RadioLib fails to find the chip). Double"
        echo "check which physical board this is, then re-flash with the"
        echo "correct --board."
        echo
    fi
    if [ -n "$new_port" ]; then
        echo "Next step:"
        echo "    $0 configure --dev $new_port"
    else
        echo "Next step:"
        echo "    ls /dev/ttyACM* /dev/ttyUSB*   # find the new port"
        echo "    $0 configure --dev <that-port>"
    fi
    echo
}

# Like pick_port_interactive but doesn't print "auto-selected" or
# prompt — used when we just want the single-candidate auto-pick and
# are OK with the call returning empty if there's nothing.
pick_port_interactive_quiet() {
    local candidates
    candidates="$(list_candidate_ports)"
    local count
    count=$(printf '%s\n' "$candidates" | grep -c . || true)
    if [ "$count" -eq 1 ]; then
        printf '%s\n' "$candidates" | head -n1
        return 0
    fi
    return 1
}

# Find the PlatformIO CLI binary, if any. Echoes "pio" or "platformio",
# or nothing (and returns 1) if neither is on PATH.
find_pio_cmd() {
    if command -v pio >/dev/null 2>&1; then
        echo pio; return 0
    elif command -v platformio >/dev/null 2>&1; then
        echo platformio; return 0
    fi
    return 1
}

# Resolve this repo's root (tools/rlr.sh's parent directory) and
# confirm platformio.ini is there. Dies if not — used only on the
# PlatformIO path, which requires a real checkout.
require_repo_root() {
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [ ! -f "$repo_root/platformio.ini" ]; then
        die "this needs a checked-out reticulum-lora-repeater repo next to tools/rlr.sh (no platformio.ini found at $repo_root)"
    fi
    printf '%s\n' "$repo_root"
}

# List the PlatformIO env names defined in platformio.ini (excluding
# the "native" test-only env), for the interactive board picker.
list_pio_envs() {
    local repo_root="$1"
    grep -oP '^\[env:\K[^\]]+' "$repo_root/platformio.ini" | grep -v '^native$'
}

# Prompt the user to pick a PlatformIO env (board) when --board
# wasn't given and --firmware wasn't either. Requires a repo checkout.
pick_board_interactive() {
    local repo_root
    repo_root=$(require_repo_root) || return 1
    local envs
    envs="$(list_pio_envs "$repo_root")"
    local count
    count=$(printf '%s\n' "$envs" | grep -c . || true)

    if [ "$count" -eq 0 ]; then
        die "no PlatformIO envs found in $repo_root/platformio.ini"
    fi

    printf 'Which board?\n' >&2
    local i=1 e
    while IFS= read -r e; do
        printf '  %d) %s\n' "$i" "$e" >&2
        i=$((i+1))
    done <<< "$envs"
    local choice
    local max="$count"
    while true; do
        read -r -p "Pick a board [1-$max]: " choice || die "input closed"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max" ]; then
            break
        fi
        echo "invalid choice: '$choice'" >&2
    done
    printf '%s\n' "$envs" | sed -n "${choice}p"
}

# Run the actual flash.
#
# Primary path (no --firmware given): `pio run -e <board> -t upload`
# from a checked-out repo — this is how this project is actually
# built and flashed day to day (builds AND flashes in one step, no
# separate firmware.zip artifact in normal use).
#
# Secondary path (--firmware <path> given): adafruit-nrfutil against
# a prebuilt DFU .zip/.uf2 — useful if you have a release artifact
# but not a repo checkout (e.g. a CI-built release download).
# Some DFU/upload failures (notably PlatformIO's nrfutil-based upload
# action) get swallowed and reported as an overall SUCCESS exit code even
# though the actual device upload clearly failed (e.g. "No data received
# on serial port", "Target is not in DFU mode", "Timed out waiting for
# acknowledgement"). Scan captured output for these signatures regardless
# of the subprocess's own exit code, since trusting that exit code alone
# has led directly to reporting "Flash complete!" on a half-flashed or
# entirely un-flashed device.
_flash_output_looks_failed() {
    grep -qiE 'No data received on serial port|Target is not in DFU mode|Timed out waiting for acknowledgement|NordicSemiException|Failed to upgrade target' "$1"
}

flash_firmware() {
    local dev="$1" firmware="$2" board="$3"
    local out_file
    out_file=$(mktemp)
    local rc

    if [ -n "$firmware" ]; then
        if command -v adafruit-nrfutil >/dev/null 2>&1; then
            log "using adafruit-nrfutil"
            adafruit-nrfutil dfu serial -pkg "$firmware" -p "$dev" -b 115200 2>&1 | tee "$out_file"
            rc=$?
        else
            rm -f "$out_file"
            die "--firmware was given but adafruit-nrfutil is not installed. Install with:
    pip3 install adafruit-nrfutil
Or drop --firmware and pass --board <env> instead to build+flash directly via PlatformIO from a repo checkout."
        fi
    else
        local pio_cmd
        pio_cmd=$(find_pio_cmd) || { rm -f "$out_file"; die "no flasher found. Install one of:
    pip3 install platformio          (recommended if you have this repo checked out; builds + flashes directly, no separate firmware.zip needed)
    pip3 install adafruit-nrfutil    + pass --firmware <path-to-prebuilt-zip> (if you only have a prebuilt release artifact, no repo checkout)"; }

        local repo_root
        repo_root=$(require_repo_root) || exit 1
        log "using $pio_cmd run -e $board -t upload"
        ( cd "$repo_root" && "$pio_cmd" run -e "$board" -t upload --upload-port "$dev" ) 2>&1 | tee "$out_file"
        rc=$?
    fi

    if [ "$rc" -eq 0 ] && _flash_output_looks_failed "$out_file"; then
        warn "the flash tool reported success, but its own output contains a known DFU-failure signature (this is a real PlatformIO/nrfutil quirk — the underlying upload error doesn't always propagate to the exit code). Treating this as a failure."
        rc=1
    fi
    rm -f "$out_file"
    return "$rc"
}


# === subcommand: configure =======================================
#
# Configure comes in two modes:
#   - Quick single-field mode: any --<field> <value> flags present,
#     apply ONLY those fields directly, no prompts, then COMMIT, then
#     print the final CONFIG GET.
#   - Interactive walkthrough: no --<field> flags, fetch current
#     CONFIG GET, prompt through every field, summarize changes,
#     confirm, then SET + COMMIT.

# Populated by parse_configure_args(). Maps CLI flag -> value.
declare -A FIELD_ARGS=()

parse_configure_args() {
    local dev=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dev)
                [ $# -ge 2 ] || die "--dev requires a value"
                dev="$2"; shift 2
                ;;
            --help|-h)
                usage; exit 0
                ;;
            --*)
                local flag="${1#--}"
                # Validate it's a known field flag
                if [ -z "${FIELDS[$flag]+set}" ]; then
                    die "unknown configure flag: --$flag (use --help)"
                fi
                [ $# -ge 2 ] || die "--$flag requires a value"
                local value="$2"
                # Parse the field spec: spec is "key|type|prompt"
                local spec="${FIELDS[$flag]}"
                local rest="${spec#*|}"        # everything after the first "|"
                local type="${rest%%|*}"       # first chunk of rest
                # Client-side validate before we ever touch the device.
                if ! validate_value "$type" "$value" "$flag"; then
                    die "invalid value for --$flag: '$value' ($VALIDATE_ERR)"
                fi
                FIELD_ARGS[$flag]="$value"
                shift 2
                ;;
            *)
                die "unexpected argument: $1 (use --help)"
                ;;
        esac
    done
    # Stash dev in a global so the dispatch functions can find it.
    CONFIGURE_DEV="$dev"
}

cmd_configure() {
    parse_configure_args "$@"

    local dev="$CONFIGURE_DEV"
    if [ -z "$dev" ]; then
        dev=$(pick_port_interactive "for configure") || exit 1
    fi
    [ -e "$dev" ] || die "serial port not found: $dev"

    require_serial_helper

    if [ "${#FIELD_ARGS[@]}" -gt 0 ]; then
        quick_configure "$dev"
    else
        interactive_configure "$dev"
    fi
}

# === quick single-field mode =====================================

quick_configure() {
    local dev="$1"
    local flag key spec type

    # 1. Send CONFIG SET for each flag. Client-side validation already
    #    ran in parse_configure_args(), so a device-side ERR here
    #    really is a problem (rare — would mean the firmware changed
    #    validation out from under us).
    log "applying ${#FIELD_ARGS[@]} change(s) to $dev ..."
    for flag in "${!FIELD_ARGS[@]}"; do
        spec="${FIELDS[$flag]}"
        key="${spec%%|*}"
        local value="${FIELD_ARGS[$flag]}"
        log "  CONFIG SET $key $value"
        if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-set "$dev" "$key" "$value" >/dev/null; then
            die "device rejected CONFIG SET $key (see error above). Nothing has been committed yet."
        fi
    done

    # 2. CONFIG COMMIT
    log "CONFIG COMMIT — persisting + rebooting..."
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-commit "$dev" >/dev/null 2>&1; then
        die "device rejected CONFIG COMMIT (see error above). Settings are staged on the device but not persisted."
    fi

    # 3. Wait for reboot + print final CONFIG GET
    log "committed — waiting 3s for the device to reboot..."
    sleep 3
    echo
    echo "Final config (after reboot):"
    echo
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-get "$dev"; then
        warn "could not read back the new config — device is likely still rebooting. Re-run '$0 configure --dev $dev' in a few seconds to verify."
        exit 3
    fi
    echo
}


# === interactive walkthrough =====================================

# Parse a multi-line "key=value\n" payload (what CONFIG GET prints)
# into an associative array CURRENT_<fieldflag>[key] = raw_value.
# Empty values (e.g. an unset collector) become "".
parse_config_get() {
    local payload="$1"
    while IFS='=' read -r key value; do
        [ -z "$key" ] && continue
        # `read` strips leading/trailing whitespace from $key but not $value
        # (when more than one field appears on a line, which doesn't happen
        # here, but be defensive). Trim CR.
        value="${value%$'\r'}"
        CONFIG_GET_VALUES["$key"]="$value"
    done <<< "$payload"
}

interactive_configure() {
    local dev="$1"

    # 1. Fetch current config
    log "fetching current config from $dev ..."
    local current_payload
    if ! current_payload=$("$PYTHON_BIN" "$SERIAL_HELPER" config-get "$dev"); then
        die "CONFIG GET failed — could not read current values from the device."
    fi

    declare -A CONFIG_GET_VALUES=()
    parse_config_get "$current_payload"

    # 2. Walk every field, prompt with default
    declare -A NEW_VALUES=()
    local flag spec key type prompt raw_current display_default input
    for flag in "${PROMPT_ORDER[@]}"; do
        spec="${FIELDS[$flag]}"
        # Split on first '|'
        key="${spec%%|*}"
        local rest="${spec#*|}"
        type="${rest%%|*}"
        prompt="${rest#*|}"
        raw_current="${CONFIG_GET_VALUES[$key]:-}"

        # Display the current value as the default; for the device's
        # two "absent means unset" string fields (collector + INA
        # labels) the device prints an empty line — surface that as
        # "(unset)" so the user knows what's actually stored.
        display_default="$raw_current"
        case "$type" in
            collector|inastring)
                if [ -z "$raw_current" ]; then
                    display_default="(unset)"
                fi
                ;;
        esac

        while true; do
            if ! read -r -p "$prompt [$display_default]: " input; then
                die "input closed"
            fi
            # Empty input → keep the current value.
            if [ -z "$input" ]; then
                input="$raw_current"
            fi
            if validate_value "$type" "$input" "$flag"; then
                NEW_VALUES[$flag]="$input"
                break
            fi
            echo "  -> invalid: $VALIDATE_ERR" >&2
        done
    done

    # 3. Compute + display the change summary
    declare -a CHANGES=()
    for flag in "${PROMPT_ORDER[@]}"; do
        spec="${FIELDS[$flag]}"
        key="${spec%%|*}"
        local current="${CONFIG_GET_VALUES[$key]:-}"
        local new="${NEW_VALUES[$flag]}"
        if [ "$current" != "$new" ]; then
            CHANGES+=("$flag|$key|$current|$new")
        fi
    done

    echo
    if [ "${#CHANGES[@]}" -eq 0 ]; then
        echo "No changes — every field matches its current value."
        exit 0
    fi

    echo "Changes to apply:"
    for change in "${CHANGES[@]}"; do
        IFS='|' read -r _f k o n <<< "$change"
        printf '  %-22s %s -> %s\n' "$k" "$(show_value "$o")" "$(show_value "$n")"
    done
    echo

    # 4. Confirm
    local confirm
    if ! read -r -p "Commit these changes? [Y/n] " confirm; then
        die "input closed"
    fi
    case "${confirm,,}" in
        ""|y|yes) : ;;
        *)
            echo "Aborted, no changes made"
            exit 0
            ;;
    esac

    # 5. Send each SET, then COMMIT
    log "applying ${#CHANGES[@]} change(s) to $dev ..."
    for change in "${CHANGES[@]}"; do
        IFS='|' read -r _f k _o n <<< "$change"
        log "  CONFIG SET $k $n"
        if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-set "$dev" "$k" "$n" >/dev/null; then
            die "device rejected CONFIG SET $k (see error above). Nothing has been committed yet."
        fi
    done

    log "CONFIG COMMIT — persisting + rebooting..."
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-commit "$dev" >/dev/null 2>&1; then
        die "device rejected CONFIG COMMIT (see error above). Settings are staged on the device but not persisted."
    fi

    log "committed — waiting 3s for the device to reboot..."
    sleep 3
    echo
    echo "Final config (after reboot):"
    echo
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-get "$dev"; then
        warn "could not read back the new config — device is likely still rebooting. Re-run '$0 configure --dev $dev' in a few seconds to verify."
        exit 3
    fi
    echo
}

# Pretty-print a value for the change-summary table. Empty → "(unset)".
show_value() {
    local v="$1"
    if [ -z "$v" ]; then
        printf '(unset)'
    else
        printf '%s' "$v"
    fi
}


# === subcommand: show =============================================
#
# Read-only: fetch CONFIG GET and print it neatly, using the same
# human-readable labels as the interactive configure walkthrough.
# No prompts, no writes to the device.

cmd_announce() {
    local dev=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dev)      dev="$2"; shift 2 ;;
            --help|-h)  usage; exit 0 ;;
            *)          die "unknown announce flag: $1 (use --help)" ;;
        esac
    done

    if [ -z "$dev" ]; then
        dev=$(pick_port_interactive "for announce") || exit 1
    fi
    [ -e "$dev" ] || die "serial port not found: $dev"

    require_serial_helper

    log "sending ANNOUNCE to $dev ..."
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" announce "$dev"; then
        die "ANNOUNCE failed (see output above)."
    fi
    echo
    echo "Note: a node can't send telemetry to its configured collector until"
    echo "it has heard an announce FROM the collector at least once (needed to"
    echo "encrypt to it) — this command announces the NODE itself outward, which"
    echo "helps others reach it, but if telemetry still isn't showing up on your"
    echo "collector's page, the collector itself may need to (re-)announce too"
    echo "(e.g. restart the collector daemon) so this node can hear it back."
}

cmd_calibrate_battery() {
    local dev="" mv=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dev)      dev="$2"; shift 2 ;;
            --help|-h)  usage; exit 0 ;;
            *)
                if [ -z "$mv" ]; then mv="$1"; shift
                else die "unknown calibrate-battery flag: $1 (use --help)"; fi
                ;;
        esac
    done

    [ -n "$mv" ] || die "usage: rlr.sh calibrate-battery [--dev <port>] <measured_mv>
  Measure the battery voltage with a multimeter first (ideally with
  USB/charge power disconnected, to rule out charge-line bias), then
  pass that reading in millivolts, e.g.:
    rlr.sh calibrate-battery 4190"

    if [ -z "$dev" ]; then
        dev=$(pick_port_interactive "for calibrate-battery") || exit 1
    fi
    [ -e "$dev" ] || die "serial port not found: $dev"

    require_serial_helper

    log "calibrating battery on $dev against measured ${mv} mV ..."
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" calibrate-battery "$dev" "$mv"; then
        die "CALIBRATE BATTERY failed (see output above)."
    fi
    echo
    echo "Calibrated + committed. The device reboots automatically after"
    echo "CONFIG COMMIT — re-run 'rlr.sh show' in a few seconds to confirm"
    echo "the new batt_mult stuck, or 'rlr.sh announce' to push a fresh"
    echo "telemetry reading to your collector."
}

cmd_refresh() {
    local dev="" confirm_flag=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dev)      dev="$2"; shift 2 ;;
            --yes)      confirm_flag="yes"; shift ;;
            --help|-h)  usage; exit 0 ;;
            *)          die "unknown refresh flag: $1 (use --help)" ;;
        esac
    done

    if [ -z "$dev" ]; then
        dev=$(pick_port_interactive "for refresh") || exit 1
    fi
    [ -e "$dev" ] || die "serial port not found: $dev"

    require_serial_helper

    echo
    echo "This regenerates the device's LXMF identity — its address WILL"
    echo "change permanently. Any collector/peer that has the OLD address"
    echo "on file will need to be told the new one. This does NOT touch"
    echo "config fields (frequency, collector, tx_enabled, etc.) — only"
    echo "the identity/address."
    echo
    if [ "$confirm_flag" != "yes" ]; then
        local confirm
        read -r -p "Type REFRESH to confirm: " confirm
        [ "$confirm" = "REFRESH" ] || { echo "Aborted, nothing changed"; exit 0; }
    fi

    log "sending IDENTITY RESET to $dev ..."
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" identity-reset "$dev"; then
        die "IDENTITY RESET failed (see output above)."
    fi

    log "waiting 3s for the device to reboot..."
    sleep 3
    echo
    echo "New address (after reboot):"
    echo
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" status "$dev" 2>/dev/null | grep '^address='; then
        warn "could not read back the new address yet — device may still be rebooting. Re-run '$0 show --dev $dev' in a few seconds."
    fi
    echo
    echo "Send ANNOUNCE now (and restart your collector if telemetry doesn't show up — see '$0 announce --help')."
}

cmd_show() {
    local dev=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dev)      dev="$2"; shift 2 ;;
            --help|-h)  usage; exit 0 ;;
            *)          die "unknown show flag: $1 (use --help)" ;;
        esac
    done

    if [ -z "$dev" ]; then
        dev=$(pick_port_interactive "for show") || exit 1
    fi
    [ -e "$dev" ] || die "serial port not found: $dev"

    require_serial_helper

    log "fetching current config from $dev ..."
    local payload
    if ! payload=$("$PYTHON_BIN" "$SERIAL_HELPER" config-get "$dev"); then
        die "CONFIG GET failed — could not read current values from the device."
    fi

    declare -A CONFIG_GET_VALUES=()
    parse_config_get "$payload"

    # The node's LXMF address (from STATUS, not CONFIG GET — it's
    # derived from the identity, not a config field). Best-effort: if
    # this fails for any reason, still show the rest of the config
    # rather than aborting.
    local status_payload address_line
    status_payload=$("$PYTHON_BIN" "$SERIAL_HELPER" status "$dev" 2>/dev/null) || true
    address_line=$(printf '%s\n' "$status_payload" | grep '^address=' | cut -d= -f2)

    echo
    echo "Current config ($dev):"
    echo
    if [ -n "$address_line" ]; then
        printf '  %-18s %s\n' "address" "$address_line"
        echo "  (this is what shows up on a telemetry collector's page — compare"
        echo "   across your nodes if you suspect two share the same address; see"
        echo "   '$0 refresh --help' to fix it)"
        echo
    fi
    local flag spec key type prompt raw display
    for flag in "${PROMPT_ORDER[@]}"; do
        spec="${FIELDS[$flag]}"
        key="${spec%%|*}"
        local rest="${spec#*|}"
        type="${rest%%|*}"
        prompt="${rest#*|}"
        raw="${CONFIG_GET_VALUES[$key]:-}"
        display="$(show_value "$raw")"
        printf '  %-18s %-40s %s\n' "$key" "$display" "($prompt)"
    done
    echo
}


# === subcommand: export ===========================================
#
# Read-only: fetch CONFIG GET and write it as JSON to a file (default
# config.json in the CWD). Meant for cloning one node's known-good
# config across multiple new nodes via `import`.

require_jq() {
    command -v jq >/dev/null 2>&1 || die "jq is required for export/import. Install it with your package manager (e.g. apt install jq / brew install jq)."
}

cmd_export() {
    local dev="" file="config.json"
    while [ $# -gt 0 ]; do
        case "$1" in
            --dev)      dev="$2"; shift 2 ;;
            --file)     file="$2"; shift 2 ;;
            --help|-h)  usage; exit 0 ;;
            *)          die "unknown export flag: $1 (use --help)" ;;
        esac
    done

    if [ -z "$dev" ]; then
        dev=$(pick_port_interactive "for export") || exit 1
    fi
    [ -e "$dev" ] || die "serial port not found: $dev"

    require_serial_helper
    require_jq

    log "fetching current config from $dev ..."
    local payload
    if ! payload=$("$PYTHON_BIN" "$SERIAL_HELPER" config-get "$dev"); then
        die "CONFIG GET failed — could not read current values from the device."
    fi

    # CONFIG GET's payload is already "key=value" lines — turn that
    # straight into a flat JSON object. Every value is kept as a JSON
    # string (even numeric fields) since CONFIG SET's wire protocol is
    # text-based anyway; round-tripping through import just sends the
    # same strings back.
    printf '%s\n' "$payload" | jq -R -n '
        [inputs | select(length > 0) | split("=") | {(.[0]): (.[1:] | join("="))}] | add
    ' > "$file" || die "failed to write $file"

    echo
    echo "Exported config from $dev to $file"
    echo
}


# === subcommand: import ============================================
#
# Read a JSON config file (as produced by `export`) and apply it to a
# device — meant for cloning a known-good node's config onto freshly
# flashed nodes. display_name is deliberately NEVER taken from the
# file (a cloned node shouldn't silently inherit another node's name)
# — it's always prompted for interactively, even in this otherwise
# non-interactive-ish flow, then applied together with everything else
# in one CONFIG SET batch + COMMIT.

# Given a device-side config key (e.g. "freq_hz"), print the matching
# FIELDS flag (e.g. "freq"), or nothing + return 1 if unknown.
flag_for_key() {
    local key="$1" flag
    for flag in "${!FIELDS[@]}"; do
        local spec="${FIELDS[$flag]}"
        if [ "${spec%%|*}" = "$key" ]; then
            printf '%s\n' "$flag"
            return 0
        fi
    done
    return 1
}

cmd_import() {
    local dev="" file="config.json"
    while [ $# -gt 0 ]; do
        case "$1" in
            --dev)      dev="$2"; shift 2 ;;
            --file)     file="$2"; shift 2 ;;
            --help|-h)  usage; exit 0 ;;
            *)          die "unknown import flag: $1 (use --help)" ;;
        esac
    done
    [ -f "$file" ] || die "import file not found: $file"

    if [ -z "$dev" ]; then
        dev=$(pick_port_interactive "for import") || exit 1
    fi
    [ -e "$dev" ] || die "serial port not found: $dev"

    require_serial_helper
    require_jq

    jq -e . "$file" >/dev/null 2>&1 || die "$file is not valid JSON"

    # 1. Fetch current device config (for the change-summary display).
    log "fetching current config from $dev ..."
    local current_payload
    if ! current_payload=$("$PYTHON_BIN" "$SERIAL_HELPER" config-get "$dev"); then
        die "CONFIG GET failed — could not read current values from the device."
    fi
    declare -A CONFIG_GET_VALUES=()
    parse_config_get "$current_payload"

    # 2. Walk every key in the import file, skip display_name, validate
    #    the rest against this device firmware's known field table.
    declare -a IMPORT_CHANGES=()
    local key value flag spec type
    while IFS=$'\t' read -r key value; do
        [ -z "$key" ] && continue
        if [ "$key" = "display_name" ]; then
            continue
        fi
        if ! flag=$(flag_for_key "$key"); then
            warn "skipping unknown field in $file: $key (not a field this firmware version recognizes)"
            continue
        fi
        spec="${FIELDS[$flag]}"
        local rest="${spec#*|}"
        type="${rest%%|*}"
        if ! validate_value "$type" "$value" "$flag"; then
            warn "skipping $key=$value from $file: $VALIDATE_ERR"
            continue
        fi
        IMPORT_CHANGES+=("$flag|$key|${CONFIG_GET_VALUES[$key]:-}|$value")
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$file")

    # 3. Always prompt for display_name — never silently cloned.
    local name_spec="${FIELDS[name]}"
    local name_rest="${name_spec#*|}"
    local name_type="${name_rest%%|*}"
    local name_prompt="${name_rest#*|}"
    local name_current="${CONFIG_GET_VALUES[display_name]:-}"
    local name_input
    while true; do
        if ! read -r -p "$name_prompt [$name_current]: " name_input; then
            die "input closed"
        fi
        [ -z "$name_input" ] && name_input="$name_current"
        if validate_value "$name_type" "$name_input" "name"; then
            break
        fi
        echo "  -> invalid: $VALIDATE_ERR" >&2
    done
    if [ "$name_input" != "$name_current" ]; then
        IMPORT_CHANGES+=("name|display_name|$name_current|$name_input")
    fi

    # 4. Summarize + confirm, same pattern as configure's interactive walkthrough.
    echo
    if [ "${#IMPORT_CHANGES[@]}" -eq 0 ]; then
        echo "No changes — device already matches $file (and name unchanged)."
        exit 0
    fi
    echo "Changes to apply (from $file):"
    for change in "${IMPORT_CHANGES[@]}"; do
        IFS='|' read -r _f k o n <<< "$change"
        printf '  %-22s %s -> %s\n' "$k" "$(show_value "$o")" "$(show_value "$n")"
    done
    echo
    local confirm
    if ! read -r -p "Commit these changes? [Y/n] " confirm; then
        die "input closed"
    fi
    case "${confirm,,}" in
        ""|y|yes) : ;;
        *) echo "Aborted, no changes made"; exit 0 ;;
    esac

    # 5. Apply + commit.
    log "applying ${#IMPORT_CHANGES[@]} change(s) to $dev ..."
    for change in "${IMPORT_CHANGES[@]}"; do
        IFS='|' read -r _f k _o n <<< "$change"
        log "  CONFIG SET $k $n"
        if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-set "$dev" "$k" "$n" >/dev/null; then
            die "device rejected CONFIG SET $k (see error above). Nothing has been committed yet."
        fi
    done

    log "CONFIG COMMIT — persisting + rebooting..."
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-commit "$dev" >/dev/null 2>&1; then
        die "device rejected CONFIG COMMIT (see error above). Settings are staged on the device but not persisted."
    fi

    log "committed — waiting 3s for the device to reboot..."
    sleep 3
    echo
    echo "Final config (after reboot):"
    echo
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-get "$dev"; then
        warn "could not read back the new config — device is likely still rebooting. Re-run '$0 show --dev $dev' in a few seconds to verify."
        exit 3
    fi
    echo

    # A cloned node can't send telemetry to its configured collector until
    # it has heard an announce FROM the collector at least once (needed to
    # encrypt to it) - this bit a real user (config looked fine, nothing
    # showed up on the collector's page). Offer to send this node's own
    # ANNOUNCE right now, which at minimum helps others path to it sooner
    # than waiting for its next internal announce interval.
    local announce_confirm
    if read -r -p "Send ANNOUNCE now so this node is reachable sooner? [Y/n] " announce_confirm; then
        case "${announce_confirm,,}" in
            ""|y|yes)
                log "sending ANNOUNCE to $dev ..."
                "$PYTHON_BIN" "$SERIAL_HELPER" announce "$dev" || warn "ANNOUNCE failed (see output above) — you can retry with: $0 announce --dev $dev"
                ;;
        esac
    fi
    echo
}


# === subcommand: wipe =============================================
#
# Resets ALL config fields to firmware factory defaults (CONFIG RESET)
# and persists it (CONFIG COMMIT). Destructive — always asks for
# confirmation unless --yes is given. This exists as an explicit,
# guarded top-level subcommand specifically so it's never reachable
# by accident from configure's flow.

cmd_wipe() {
    local dev="" yes=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dev)      dev="$2"; shift 2 ;;
            --yes)      yes=1; shift ;;
            --help|-h)  usage; exit 0 ;;
            *)          die "unknown wipe flag: $1 (use --help)" ;;
        esac
    done

    if [ -z "$dev" ]; then
        dev=$(pick_port_interactive "for wipe") || exit 1
    fi
    [ -e "$dev" ] || die "serial port not found: $dev"

    require_serial_helper

    if [ "$yes" -ne 1 ]; then
        echo "This will reset ALL config on $dev to firmware factory defaults"
        echo "(frequency, TX power, display name, collector, calibration —"
        echo "everything) and reboot the device. This cannot be undone."
        echo
        local confirm
        if ! read -r -p "Type WIPE to confirm: " confirm; then
            die "input closed"
        fi
        if [ "$confirm" != "WIPE" ]; then
            echo "Aborted, no changes made"
            exit 0
        fi
    fi

    log "CONFIG RESET — reseeding staging from firmware defaults..."
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-reset "$dev" >/dev/null 2>&1; then
        die "device rejected CONFIG RESET (see error above)."
    fi

    log "CONFIG COMMIT — persisting + rebooting..."
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-commit "$dev" >/dev/null 2>&1; then
        die "device rejected CONFIG COMMIT (see error above). Defaults are staged on the device but not persisted."
    fi

    log "committed — waiting 3s for the device to reboot..."
    sleep 3
    echo
    echo "Device wiped. Config is now factory default:"
    echo
    if ! "$PYTHON_BIN" "$SERIAL_HELPER" config-get "$dev"; then
        warn "could not read back the config — device is likely still rebooting. Re-run '$0 configure --dev $dev' in a few seconds to verify."
        exit 3
    fi
    echo
}


# === prereq check =================================================

require_serial_helper() {
    [ -f "$SERIAL_HELPER" ] || die "serial helper not found at $SERIAL_HELPER"
    command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "python3 not found in PATH (set PYTHON_BIN if it's installed somewhere unusual)"
    if ! "$PYTHON_BIN" -c "import serial" 2>/dev/null; then
        die "python3 pyserial module is missing. Install it with: pip3 install pyserial"
    fi
}


# === help =========================================================

usage() {
    cat <<'EOF'
rlr.sh — flash + configure an RLR (reticulum-lora-repeater) node from
the command line. Mirrors what the project's web flasher does, but in
a terminal. Works on Linux only (uses /dev/ttyACM* / /dev/ttyUSB*).

Usage:
  rlr.sh flash [--dev <port>] [--board <env>] [--firmware <path>]
  rlr.sh configure [--dev <port>] [--<field> <value> ...]
   rlr.sh show [--dev <port>]
   rlr.sh announce [--dev <port>]
   rlr.sh calibrate-battery [--dev <port>] <measured_mv>
   rlr.sh refresh [--dev <port>] [--yes]
   rlr.sh export [--dev <port>] [--file <path>]
  rlr.sh import [--dev <port>] [--file <path>]
  rlr.sh wipe [--dev <port>] [--yes]
  rlr.sh --help | -h | help

Subcommands:

  flash
    Flash firmware to a node. If the device is currently running app
    firmware, sends the DFU serial command to reboot into the CDC-
    serial DFU bootloader first; otherwise flashes directly.

    All flags are optional and will be prompted for interactively if
    omitted — running `rlr.sh flash` with no arguments at all walks
    you through picking a port and a board.

      --dev <port>       Serial port to flash through (e.g.
                         /dev/ttyACM0). Auto-detected if omitted and
                         exactly one candidate exists; prompted for
                         otherwise. If the device re-enumerates after
                         entering DFU or after flashing, the script
                         auto-detects the new port too.
      --board <env>      PlatformIO env name (e.g. Faketec,
                         RAK4631, RAK3401, XIAO_nRF52840,
                         Heltec_T114, T-Echo). Used with the primary
                         flash path (see below) — prompted for
                         interactively if omitted and --firmware
                         wasn't given either.
      --firmware <path>  Prebuilt DFU firmware file (.zip or .uf2) —
                         only needed if you have a release artifact
                         but NOT a checked-out copy of this repo (see
                         secondary path below). Most users building
                         from source should use --board instead, or
                         nothing at all (you'll be prompted).

    Flash path:
      1. Primary — no --firmware given: `pio run -e <board> -t upload`
         from a checked-out copy of this repo. This builds AND flashes
         in one step and is how this project is normally built/flashed
         day to day. Requires PlatformIO (`pip3 install platformio`)
         and this script to be run from inside (or next to) a repo
         checkout.
      2. Secondary — --firmware <path> given: adafruit-nrfutil against
         a prebuilt DFU package. Useful if you only have a release
         download and no repo checkout. Requires
         `pip3 install adafruit-nrfutil`.

  configure
    Edit runtime configuration via the serial console.

    Quick single-field mode (no interactive prompts):
      rlr.sh configure --dev <port> --<field> <value> ...

    Interactive walkthrough (prompts for every field, then asks
    for confirmation before applying):
      rlr.sh configure --dev <port>     # walks through everything
      rlr.sh configure                  # auto-detect port

    --dev is optional if exactly one /dev/ttyACM* or /dev/ttyUSB*
    port exists on the system at invocation. With zero or multiple
    ports, the script lists them and prompts to choose.

  show
    Read-only: print the device's current config, one field per
    line with a human-readable label, no prompts, no writes.

    Optional:
      --dev <port>  Serial port. Auto-detected if omitted and
                    exactly one candidate exists.

  announce
    Send the ANNOUNCE serial command — forces an immediate LXMF
    presence + telemetry announce instead of waiting for the
    device's next internal announce interval. Useful right after
    `configure`/`import` to make a node reachable sooner, and to
    diagnose "telemetry isn't showing up on my collector" issues:
    a node can't encrypt telemetry to its configured collector
    until it has heard an announce FROM the collector at least once
    - if that hasn't happened yet, this node-side announce alone
    won't fix it; the collector itself may need to (re-)announce
    (e.g. restart the collector daemon) so this node can hear it
    back.

    Optional:
      --dev <port>  Serial port. Auto-detected if omitted and
                    exactly one candidate exists.

  calibrate-battery <measured_mv>
    One-shot battery ADC calibration: sends CALIBRATE BATTERY <mv>
    then CONFIG COMMIT. Measure the battery with a multimeter first
    (ideally with USB/charge power disconnected, so you're reading
    the battery alone and not charge-line bias), then run this with
    that reading in millivolts, e.g.:

      rlr.sh calibrate-battery 4190

    The firmware averages a fresh raw ADC burst and derives
    batt_mult = measured_mv / raw_avg, stages it, and CONFIG COMMIT
    persists + reboots the device. Fixes the "fully charged but shows
    a low percentage on the collector page" symptom, which happens
    when a board's actual per-unit ADC divider doesn't match its
    firmware's DEFAULT_CONFIG_BATT_MULT (a first-boot guess, not a
    per-device measurement).

    Optional:
      --dev <port>  Serial port. Auto-detected if omitted and
                    exactly one candidate exists.

  refresh
    Send IDENTITY RESET — regenerates the device's LXMF identity
    (its address) and reboots. Destructive: the OLD address is gone
    for good. Does NOT touch config fields (frequency, collector,
    tx_enabled, etc.) - only the identity.

    Fixes a real firmware bug (fixed going forward, but pre-existing
    devices may still be affected): before the RNG entropy fix, two
    devices flashed from the same build with no other differing
    entropy could generate the SAME address. Symptom: `show` looks
    correct and consistent across devices, but only one grid slot
    ever updates on your telemetry collector no matter which physical
    device announces. Compare `show`'s new `address=` field across
    your nodes to check for this - if two match, run `refresh` on one
    of them.

    Requires typing REFRESH to confirm unless --yes is passed.

    Optional:
      --dev <port>  Serial port. Auto-detected if omitted and
                    exactly one candidate exists.
      --yes         Skip the confirmation prompt.

  export
    Read-only: fetch the device's current config and write it as
    JSON to a file, for cloning across multiple new nodes with
    `import`.

    Optional:
      --dev <port>   Serial port. Auto-detected if omitted and
                     exactly one candidate exists.
      --file <path>  Output file (default: config.json in the CWD).

  import
    Apply a previously-exported JSON config file to a device.
    display_name is NEVER taken from the file — a cloned node
    shouldn't silently inherit another node's name — you're always
    prompted for it interactively (defaulting to the device's
    current name), then it's applied together with everything else
    in one commit. Shows a change summary and asks for confirmation
    before applying anything, same as configure's interactive mode.

    Optional:
      --dev <port>   Serial port. Auto-detected if omitted and
                     exactly one candidate exists.
      --file <path>  Input file (default: config.json in the CWD).

    Requires `jq` (for both export and import).

  wipe
    Reset ALL config on the device to firmware factory defaults
    (frequency, TX power, display name, collector, calibration —
    everything) and persist it. Destructive, cannot be undone.

    Optional:
      --dev <port>  Serial port. Auto-detected like configure if
                    omitted and exactly one candidate exists.
      --yes         Skip the "type WIPE to confirm" prompt (for
                    scripted use — use with real care).

Configurable fields (CLI flag, device config key, type, range):

  --name             display_name          string     1-31 chars, no '|'
  --freq             freq_hz               int        100000000-1100000000
  --bw               bw_hz                 int        7800-500000
  --sf               sf                    int        7-12
  --cr               cr                    int        5-8
  --txp              txp_dbm               int        -9 to 22 (dBm)
  --tx-enabled       tx_enabled            bool       0/1, true/false, on/off, yes/no
  --batt-mult        batt_mult             float      > 0.0, <= 10.0
  --tele-interval    tele_interval_ms      uint       ms (no fixed max)
  --lxmf-interval    lxmf_interval_ms      uint       ms (no fixed max)
  --telemetry        telemetry             bool       0/1, true/false, on/off, yes/no
  --lxmf             lxmf                  bool       0/1, true/false, on/off, yes/no
  --heartbeat        heartbeat             bool       0/1, true/false, on/off, yes/no
  --bt-enabled       bt_enabled            bool       0/1, true/false, on/off, yes/no
  --bt-pin           bt_pin                int        0-999999 (0=disabled)
  --lat              latitude              float      -90.0 to 90.0 (deg)
  --lon              longitude             float      -180.0 to 180.0 (deg)
  --alt              altitude              int        -100000 to 100000 (m)
  --log-level        log_level             int        0-2 (0=quiet, 2=verbose)
  --collector        collector             string     32 hex chars or 'none'
  --ina1-label       ina_ch1_label         string     max 7 chars, no '|'
  --ina2-label       ina_ch2_label         string     max 7 chars, no '|'
  --ina3-label       ina_ch3_label         string     max 7 chars, no '|'

Examples:

  # Full from-scratch flash + configure sequence
  rlr.sh flash   --dev /dev/ttyACM0 --board RAK4631   # from a repo checkout
  rlr.sh flash                                        # or just be prompted for everything
  rlr.sh configure --dev /dev/ttyACM0       # walks through every field

  # Single-field quick change
  rlr.sh configure --dev /dev/ttyACM0 --cr 5

  # Set a region-legal freq + telemetry collector in one go (no prompts)
  rlr.sh configure --dev /dev/ttyACM0 \
      --freq 904375000 --bw 250000 --sf 10 --txp 22 --tx-enabled 1 \
      --name "Roof Site North" \
      --collector 0123456789abcdef0123456789abcdef

  # Print a node's current config, neatly, read-only
  rlr.sh show --dev /dev/ttyACM0

  # Set up one node, confirm it's good, save its config for cloning
  rlr.sh configure --dev /dev/ttyACM0
  rlr.sh show --dev /dev/ttyACM0
  rlr.sh export --dev /dev/ttyACM0 --file site-config.json

  # Flash + clone that config onto each subsequent node (prompts for
  # a new display name, applies everything else, one commit)
  rlr.sh flash --dev /dev/ttyACM0 --board RAK4631
  rlr.sh import --dev /dev/ttyACM0 --file site-config.json

  # Reset a node back to factory defaults (destructive, asks to confirm)
  rlr.sh wipe --dev /dev/ttyACM0

Notes:
  - Requires python3 + pyserial:
      pip3 install pyserial
  - tools/set-collector.py remains in place for backward compatibility;
    rlr.sh configure --collector <hash> supersedes it.
  - Exit codes: 0 success, 1 user/usage error, 3 device comms failure,
    4 flash tool missing. CONFIG GET/SET/COMMIT device-side errors
    exit 1 with the device's ERR message on stderr.

EOF
}


# === entry point ==================================================

if [ $# -eq 0 ]; then
    usage >&2
    exit 1
fi

SUBCMD="$1"
shift

case "$SUBCMD" in
    flash)      cmd_flash "$@" ;;
    configure)  cmd_configure "$@" ;;
    show)       cmd_show "$@" ;;
    announce)   cmd_announce "$@" ;;
    calibrate-battery) cmd_calibrate_battery "$@" ;;
    refresh)    cmd_refresh "$@" ;;
    export)     cmd_export "$@" ;;
    import)     cmd_import "$@" ;;
    wipe)       cmd_wipe "$@" ;;
    --help|-h|help) usage; exit 0 ;;
    *)
        printf '[rlr.sh] error: unknown subcommand: %s\n\n' "$SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac
