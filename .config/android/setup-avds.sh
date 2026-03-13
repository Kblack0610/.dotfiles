#!/usr/bin/env bash
# Apply shared hardware defaults to all AVD config.ini files.
# Re-run after creating new AVDs to apply defaults.
#
# Usage: setup-avds.sh [avd-defaults.properties]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="${1:-${SCRIPT_DIR}/avd-defaults.properties}"

# Locate AVD directory — check common locations
if [[ -n "${ANDROID_AVD_HOME:-}" ]]; then
    AVD_HOME="$ANDROID_AVD_HOME"
elif [[ -d "${HOME}/.config/.android/avd" ]]; then
    AVD_HOME="${HOME}/.config/.android/avd"
elif [[ -d "${ANDROID_EMULATOR_HOME:-${HOME}/.android}/avd" ]]; then
    AVD_HOME="${ANDROID_EMULATOR_HOME:-${HOME}/.android}/avd"
else
    echo "No AVD directory found. Checked:"
    echo "  ~/.config/.android/avd"
    echo "  ~/.android/avd"
    exit 1
fi

if [[ ! -f "$DEFAULTS_FILE" ]]; then
    echo "Defaults file not found: $DEFAULTS_FILE"
    exit 1
fi

patched=0
skipped=0

for avd_dir in "$AVD_HOME"/*.avd; do
    [[ -d "$avd_dir" ]] || continue
    config="${avd_dir}/config.ini"
    [[ -f "$config" ]] || continue

    avd_name="$(basename "$avd_dir" .avd)"
    changed=false

    while IFS='=' read -r key value; do
        # Skip comments and blank lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | xargs)"

        # Check current value (handle both "key = value" and "key=value" formats)
        current="$(grep -E "^${key}\s*=" "$config" 2>/dev/null | head -1 | sed 's/^[^=]*=\s*//' | xargs)" || true

        if [[ "$current" == "$value" ]]; then
            continue
        fi

        if grep -qE "^${key}\s*=" "$config" 2>/dev/null; then
            sed -i "s|^${key}\s*=.*|${key} = ${value}|" "$config"
        else
            echo "${key} = ${value}" >> "$config"
        fi
        changed=true
    done < "$DEFAULTS_FILE"

    if $changed; then
        echo "  patched: $avd_name"
        patched=$((patched + 1))
    else
        echo "  ok:      $avd_name"
        skipped=$((skipped + 1))
    fi
done

echo ""
echo "Done. $patched patched, $skipped already up to date."
