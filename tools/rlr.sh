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
    [ -n "$dev" ]      || die "--dev is required (try --help)"
    [ -n "$firmware" ] || die "--firmware is required (try --help)"
    [ -e "$dev" ]      || die "serial port not found: $dev"
    [ -f "$firmware" ] || die "firmware file not found: $firmware"

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
        log "no response on $dev — assuming the device is already in the bootloader, skipping DFU step"
    fi

    # 2. Flash
    log "flashing $(basename "$firmware") to $dev ..."
    if ! flash_firmware "$dev" "$firmware" "$board"; then
        die "flash tool exited with error (see output above). Device may be in a half-flashed state — re-run with --dev <same-port> to retry."
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

    cat <<EOF

Flash complete!

The device reset to factory defaults for everything you didn't configure.
A freshly-flashed node boots RX-only with a placeholder display name —
set your frequency, region-legal TX power, display name, and a telemetry
collector (if you have one) before relying on it for traffic.

EOF
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

# Run the actual flash. Tries adafruit-nrfutil first (works from a
# prebuilt .zip anywhere), falls back to `pio run -t upload` from a
# repo checkout if --board <env> was given.
flash_firmware() {
    local dev="$1" firmware="$2" board="$3"

    if command -v adafruit-nrfutil >/dev/null 2>&1; then
        log "using adafruit-nrfutil"
        adafruit-nrfutil dfu serial -pkg "$firmware" -p "$dev" -b 115200
        return $?
    fi

    local pio_cmd=""
    if command -v pio >/dev/null 2>&1; then
        pio_cmd=pio
    elif command -v platformio >/dev/null 2>&1; then
        pio_cmd=platformio
    fi

    if [ -n "$pio_cmd" ]; then
        if [ -z "$board" ]; then
            die "adafruit-nrfutil not found and --board <env> was not given (the PlatformIO fallback needs it to know which env to build)"
        fi
        # Resolve repo root from this script's location; flash from there
        # so platformio.ini + .pio/ are in scope.
        local repo_root
        repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
        if [ ! -f "$repo_root/platformio.ini" ]; then
            die "PlatformIO fallback needs a checked-out reticulum-lora-repeater repo next to tools/rlr.sh (no platformio.ini found at $repo_root)"
        fi
        log "using $pio_cmd run -e $board -t upload (PlatformIO fallback)"
        ( cd "$repo_root" && "$pio_cmd" run -e "$board" -t upload --upload-port "$dev" )
        return $?
    fi

    die "no flasher found. Install one of:
    pip3 install adafruit-nrfutil    (recommended; works from a prebuilt .zip anywhere)
    pip3 install platformio           + run from inside a checked-out repo with --board <env>"
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
  rlr.sh flash --dev <port> --firmware <path> [--board <env>]
  rlr.sh configure [--dev <port>] [--<field> <value> ...]
  rlr.sh wipe [--dev <port>] [--yes]
  rlr.sh --help | -h | help

Subcommands:

  flash
    Flash firmware to a node. If the device is currently running app
    firmware, sends the DFU serial command to reboot into the CDC-
    serial DFU bootloader first; otherwise flashes directly.

    Required:
      --dev <port>       Serial port to flash through (e.g.
                         /dev/ttyACM0). If the device re-enumerates
                         after entering DFU or after flashing, the
                         script auto-detects the new port.
      --firmware <path>  Prebuilt firmware file. A DFU .zip package
                         (what `pio run -e <env>` produces at
                         .pio/build/<env>/firmware.zip) or a .uf2.

    Optional:
      --board <env>      PlatformIO env name (e.g. Faketec,
                         RAK4631, RAK3401, XIAO_nRF52840,
                         Heltec_T114, T-Echo). Only needed for the
                         PlatformIO fallback if adafruit-nrfutil
                         isn't installed.

    Flasher tool preference:
      1. adafruit-nrfutil (pip3 install adafruit-nrfutil) — works
         from a prebuilt .zip anywhere, no repo checkout needed.
      2. PlatformIO `pio run -t upload` from inside a checked-out
         copy of this repo, with --board <env>.
      If neither is available, the script prints install instructions
      and exits nonzero.

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
  rlr.sh flash   --dev /dev/ttyACM0 --firmware firmware.zip
  rlr.sh configure --dev /dev/ttyACM0       # walks through every field

  # Single-field quick change
  rlr.sh configure --dev /dev/ttyACM0 --cr 5

  # Set a region-legal freq + telemetry collector in one go (no prompts)
  rlr.sh configure --dev /dev/ttyACM0 \
      --freq 904375000 --bw 250000 --sf 10 --txp 22 --tx-enabled 1 \
      --name "Roof Site North" \
      --collector 0123456789abcdef0123456789abcdef

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
    wipe)       cmd_wipe "$@" ;;
    --help|-h|help) usage; exit 0 ;;
    *)
        printf '[rlr.sh] error: unknown subcommand: %s\n\n' "$SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac
