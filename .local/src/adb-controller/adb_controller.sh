#!/usr/bin/env bash
# adb-ctrl - Interactive TUI controller for ADB devices
# Usage: adb-ctrl [--serial <id>] [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SUITE_DIR="${SCRIPT_DIR}/../android-suite"

# Source base functions from android-suite
if [[ -f "${SUITE_DIR}/base_functions.sh" ]]; then
    source "${SUITE_DIR}/base_functions.sh"
else
    echo "Error: android-suite/base_functions.sh not found at ${SUITE_DIR}" >&2
    echo "Expected at: ${SUITE_DIR}/base_functions.sh" >&2
    exit 1
fi

# =============================================================================
# Device Selection
# =============================================================================

# Emit tab-delimited fzf entry: <serial>\t<display_label>
emit_entry() {
    printf '%s\t%s\n' "$1" "$2"
}

select_device_interactive() {
    if ! check_adb; then
        return 1
    fi

    # If serial already set via --serial, verify it
    if [[ -n "${DEVICE_SERIAL:-}" ]]; then
        local devices
        devices=$(adb devices 2>/dev/null | grep -E "device$" | awk '{print $1}')
        if echo "$devices" | grep -q "^${DEVICE_SERIAL}$"; then
            return 0
        else
            log_error "Specified device not found: $DEVICE_SERIAL"
            return 1
        fi
    fi

    local serials
    serials=$(adb devices 2>/dev/null | grep -E "device$" | awk '{print $1}')

    if [[ -z "$serials" ]]; then
        log_error "No authorized ADB devices connected"
        log_info "Connect a device via USB and enable USB debugging"
        return 1
    fi

    local count
    count=$(echo "$serials" | wc -l)

    if [[ "$count" -eq 1 ]]; then
        DEVICE_SERIAL="$serials"
        local model
        model=$(adb -s "$DEVICE_SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
        log_info "Auto-selected: $model ($DEVICE_SERIAL)"
        export DEVICE_SERIAL
        return 0
    fi

    # Multiple devices - use fzf picker
    local fzf_input=""
    local serial model version label
    for serial in $serials; do
        model=$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "unknown")
        version=$(adb -s "$serial" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || echo "?")
        label="${model} (Android ${version}) [${serial}]"
        fzf_input+="$(emit_entry "$serial" "$label")"$'\n'
    done

    local selected
    selected=$(echo -n "$fzf_input" | fzf \
        --reverse --border --cycle \
        --prompt='Select device > ' \
        --height=40% \
        --delimiter=$'\t' \
        --with-nth=2 \
        --header='Select an ADB device') || return 1

    DEVICE_SERIAL="$(echo "$selected" | cut -f1)"
    export DEVICE_SERIAL
    log_info "Selected: $(echo "$selected" | cut -f2)"
}

# =============================================================================
# Screenshot Display
# =============================================================================

display_image() {
    local file="$1"

    if [[ -n "${KITTY_WINDOW_ID:-}" ]] && command -v kitten &>/dev/null; then
        kitten icat --clear
        kitten icat "$file"
    elif command -v chafa &>/dev/null; then
        chafa --size=80x40 "$file"
    elif command -v feh &>/dev/null; then
        feh "$file" &
    else
        log_info "Screenshot saved: $file"
    fi
}

cmd_screenshot() {
    local tmpfile
    tmpfile=$(mktemp /tmp/adb-screenshot-XXXXXX.png)

    log_info "Capturing screenshot..."
    adb_cmd exec-out screencap -p > "$tmpfile"

    if [[ ! -s "$tmpfile" ]]; then
        log_error "Screenshot capture failed"
        rm -f "$tmpfile"
        return 1
    fi

    display_image "$tmpfile"
    log_info "Saved: $tmpfile"
}

# =============================================================================
# Tap
# =============================================================================

cmd_tap() {
    # Show screenshot for reference
    local tmpfile
    tmpfile=$(mktemp /tmp/adb-screenshot-XXXXXX.png)
    adb_cmd exec-out screencap -p > "$tmpfile"
    if [[ -s "$tmpfile" ]]; then
        display_image "$tmpfile"
    fi

    echo ""
    read -rp "Enter tap coordinates (x y): " coords
    if [[ -z "$coords" ]]; then
        log_warning "No coordinates entered"
        return 0
    fi

    local x y
    x=$(echo "$coords" | awk '{print $1}')
    y=$(echo "$coords" | awk '{print $2}')

    if [[ -z "$x" || -z "$y" ]]; then
        log_error "Invalid coordinates. Use: x y (e.g., 540 960)"
        return 1
    fi

    adb_cmd shell input tap "$x" "$y"
    log_success "Tapped ($x, $y)"
    rm -f "$tmpfile"
}

# =============================================================================
# Swipe
# =============================================================================

get_screen_size() {
    local size
    size=$(adb_cmd shell wm size 2>/dev/null | grep -oP '\d+x\d+' | tail -1)
    echo "$size"
}

cmd_swipe() {
    local size
    size=$(get_screen_size)
    local w h
    w=$(echo "$size" | cut -dx -f1)
    h=$(echo "$size" | cut -dx -f2)

    local cx=$((w / 2))
    local cy=$((h / 2))
    local margin_x=$((w / 5))
    local margin_y=$((h / 5))

    local options=(
        "up	Swipe Up"
        "down	Swipe Down"
        "left	Swipe Left"
        "right	Swipe Right"
        "back	Swipe Back (edge gesture)"
        "custom	Custom coordinates"
    )

    local fzf_input=""
    for opt in "${options[@]}"; do
        fzf_input+="${opt}"$'\n'
    done

    local selected
    selected=$(echo -n "$fzf_input" | fzf \
        --reverse --border --cycle \
        --prompt='Swipe direction > ' \
        --height=40% \
        --delimiter=$'\t' \
        --with-nth=2 \
        --header='Select swipe direction') || return 0

    local choice
    choice=$(echo "$selected" | cut -f1)

    local x1 y1 x2 y2 duration=300
    case "$choice" in
        up)    x1=$cx; y1=$((cy + margin_y)); x2=$cx; y2=$((cy - margin_y)) ;;
        down)  x1=$cx; y1=$((cy - margin_y)); x2=$cx; y2=$((cy + margin_y)) ;;
        left)  x1=$((cx + margin_x)); y1=$cy; x2=$((cx - margin_x)); y2=$cy ;;
        right) x1=$((cx - margin_x)); y1=$cy; x2=$((cx + margin_x)); y2=$cy ;;
        back)  x1=10; y1=$cy; x2=$((w / 3)); y2=$cy; duration=150 ;;
        custom)
            read -rp "Enter swipe coords (x1 y1 x2 y2 [duration_ms]): " input
            x1=$(echo "$input" | awk '{print $1}')
            y1=$(echo "$input" | awk '{print $2}')
            x2=$(echo "$input" | awk '{print $3}')
            y2=$(echo "$input" | awk '{print $4}')
            duration=$(echo "$input" | awk '{print ($5 != "" ? $5 : 300)}')
            if [[ -z "$x1" || -z "$y1" || -z "$x2" || -z "$y2" ]]; then
                log_error "Invalid coordinates"
                return 1
            fi
            ;;
    esac

    adb_cmd shell input swipe "$x1" "$y1" "$x2" "$y2" "$duration"
    log_success "Swiped $choice ($x1,$y1 -> $x2,$y2)"
}

# =============================================================================
# Type Text
# =============================================================================

cmd_type() {
    read -rp "Enter text to type: " text
    if [[ -z "$text" ]]; then
        log_warning "No text entered"
        return 0
    fi

    # Escape special characters for ADB input
    local escaped
    escaped=$(echo "$text" | sed 's/[&<>|;$`\\\"'"'"']/\\&/g; s/ /%s/g')

    adb_cmd shell input text "$escaped"
    log_success "Typed: $text"
}

# =============================================================================
# Key Events
# =============================================================================

cmd_key() {
    local keys=(
        "KEYCODE_HOME	Home"
        "KEYCODE_BACK	Back"
        "KEYCODE_ENTER	Enter"
        "KEYCODE_VOLUME_UP	Volume Up"
        "KEYCODE_VOLUME_DOWN	Volume Down"
        "KEYCODE_POWER	Power"
        "KEYCODE_APP_SWITCH	App Switch (Recents)"
        "KEYCODE_MENU	Menu"
        "KEYCODE_DEL	Delete (Backspace)"
        "KEYCODE_TAB	Tab"
        "KEYCODE_ESCAPE	Escape"
        "KEYCODE_MEDIA_PLAY_PAUSE	Play/Pause"
    )

    local fzf_input=""
    for k in "${keys[@]}"; do
        fzf_input+="${k}"$'\n'
    done

    local selected
    selected=$(echo -n "$fzf_input" | fzf \
        --reverse --border --cycle \
        --prompt='Key event > ' \
        --height=50% \
        --delimiter=$'\t' \
        --with-nth=2 \
        --header='Select key to send') || return 0

    local keycode
    keycode=$(echo "$selected" | cut -f1)

    adb_cmd shell input keyevent "$keycode"
    log_success "Sent: $(echo "$selected" | cut -f2)"
}

# =============================================================================
# Show Activity
# =============================================================================

cmd_show_activity() {
    log_section "Current Activity"

    local focused
    focused=$(adb_cmd shell "dumpsys activity activities | grep -E 'topResumedActivity|mResumedActivity|mFocusedActivity' | head -1" 2>/dev/null \
        | tr -d '\r' | sed 's/.*{[^ ]* [^ ]* \([^ ]*\).*/\1/')

    if [[ -n "$focused" ]]; then
        local package activity
        package=$(echo "$focused" | cut -d/ -f1)
        activity=$(echo "$focused" | cut -d/ -f2)
        echo "  Package:  $package"
        echo "  Activity: $activity"
    else
        log_warning "Could not determine current activity"
    fi
    echo ""
}

# =============================================================================
# Shell Commands
# =============================================================================

cmd_shell() {
    local commands=(
        "pm list packages -3	List installed 3rd-party apps"
        "dumpsys battery	Battery status"
        "df -h /data	Storage usage"
        "getprop ro.build.display.id	Build ID"
        "logcat -d -s ActivityManager:I	Recent activity log"
        "settings list system	System settings"
        "ip addr show wlan0	WiFi IP address"
        "top -n 1 -b | head -20	Top processes"
        "custom	Run custom command"
    )

    local fzf_input=""
    for c in "${commands[@]}"; do
        fzf_input+="${c}"$'\n'
    done

    local selected
    selected=$(echo -n "$fzf_input" | fzf \
        --reverse --border --cycle \
        --prompt='Shell command > ' \
        --height=50% \
        --delimiter=$'\t' \
        --with-nth=2 \
        --header='Select command to run') || return 0

    local cmd
    cmd=$(echo "$selected" | cut -f1)

    if [[ "$cmd" == "custom" ]]; then
        read -rp "Enter shell command: " cmd
        if [[ -z "$cmd" ]]; then
            return 0
        fi
    fi

    log_section "Output: $cmd"
    adb_cmd shell "$cmd"
    echo ""
}

# =============================================================================
# Device Info
# =============================================================================

cmd_device_info() {
    log_section "Device Information"

    local prop
    prop() { adb_cmd shell getprop "$1" 2>/dev/null | tr -d '\r'; }

    echo "  Model:      $(prop ro.product.model)"
    echo "  Brand:      $(prop ro.product.brand)"
    echo "  Android:    $(prop ro.build.version.release) (SDK $(prop ro.build.version.sdk))"
    echo "  Build:      $(prop ro.build.display.id)"
    echo "  Serial:     ${DEVICE_SERIAL:-unknown}"
    echo ""

    echo "  Battery:"
    adb_cmd shell "dumpsys battery | head -20" 2>/dev/null | grep -E "level|status|powered|temperature" | head -6 | sed 's/^/  /'
    echo ""

    echo "  Storage:"
    adb_cmd shell df -h /data 2>/dev/null | sed 's/^/    /'
    echo ""

    local ip
    ip=$(get_device_ip)
    if [[ -n "$ip" ]]; then
        echo "  WiFi IP:    $ip"
    fi
    echo ""
}

# =============================================================================
# Wireless ADB
# =============================================================================

cmd_wireless_adb() {
    log_info "Enabling wireless ADB..."
    enable_wireless_adb
}

# =============================================================================
# Main Menu
# =============================================================================

main_menu() {
    local actions=(
        "screenshot	Screenshot - Capture and display"
        "tap	Tap - Tap at coordinates"
        "swipe	Swipe - Directional swipe"
        "type	Type - Input text"
        "keys	Keys - Send key events"
        "activity	Activity - Show current foreground app"
        "shell	Shell - Run shell commands"
        "info	Device Info - Model, battery, storage"
        "wireless	Wireless ADB - Enable WiFi debugging"
        "reselect	Reselect - Pick different device"
        "quit	Quit"
    )

    while true; do
        local fzf_input=""
        for a in "${actions[@]}"; do
            fzf_input+="${a}"$'\n'
        done

        local model
        model=$(adb_cmd shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "$DEVICE_SERIAL")

        local selected
        selected=$(echo -n "$fzf_input" | fzf \
            --reverse --border --cycle \
            --prompt="adb-ctrl ($model) > " \
            --height=50% \
            --delimiter=$'\t' \
            --with-nth=2 \
            --header="Device: $model [$DEVICE_SERIAL] | ESC to quit") || break

        local action
        action=$(echo "$selected" | cut -f1)

        case "$action" in
            screenshot)  cmd_screenshot ;;
            tap)         cmd_tap ;;
            swipe)       cmd_swipe ;;
            type)        cmd_type ;;
            keys)        cmd_key ;;
            activity)    cmd_show_activity ;;
            shell)       cmd_shell ;;
            info)        cmd_device_info ;;
            wireless)    cmd_wireless_adb ;;
            reselect)
                DEVICE_SERIAL=""
                select_device_interactive || return 1
                ;;
            quit)        break ;;
        esac

        # Pause before returning to menu (except quit/reselect)
        if [[ "$action" != "quit" && "$action" != "reselect" ]]; then
            echo ""
            read -rp "Press Enter to continue..." _
        fi
    done
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
    cat <<EOF
adb-ctrl - Interactive ADB device controller

Usage: adb-ctrl [options]

Options:
  --serial <id>   Use specific device (skip picker)
  --help, -h      Show this help

Menu Actions:
  Screenshot      Capture screen (kitty icat, chafa, feh)
  Tap             Tap at x,y coordinates
  Swipe           Preset directions or custom
  Type            Input text to focused field
  Keys            Send key events (Home, Back, etc.)
  Activity        Show current foreground app
  Shell           Preset + custom shell commands
  Device Info     Model, battery, storage details
  Wireless ADB    Enable WiFi debugging
  Reselect        Pick different device

Dependencies: adb, fzf
Optional: kitty, chafa, feh (for screenshot display)
EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --serial)
                DEVICE_SERIAL="${2:?--serial requires a device ID}"
                export DEVICE_SERIAL
                shift 2
                ;;
            -h|--help)
                cmd_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                cmd_help
                exit 1
                ;;
        esac
    done

    # Check dependencies
    if ! command -v fzf &>/dev/null; then
        log_error "fzf is required but not found"
        log_info "  Arch: sudo pacman -S fzf"
        log_info "  Debian: sudo apt install fzf"
        exit 1
    fi

    check_adb || exit 1

    # Select device
    select_device_interactive || exit 1

    # Run menu loop
    main_menu
    log_info "Goodbye!"
}

main "$@"
