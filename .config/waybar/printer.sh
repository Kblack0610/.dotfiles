#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted jq programs and bash -c script expand on their own
# Waybar module: the 3D printers, read as `Neptune 43%  A1 on`. The Neptune's state comes from
# Moonraker at CC_NEPTUNE_URL, the address the slicer sends prints to, so `Neptune off` also means
# the slicer cannot reach it. The A1 is a connect to its LAN port (CC_A1_ADDR, host:port): on or
# off, since its print state lives only in Home Assistant. Both off reads a dim `printers off`.
# The hover has the Neptune's file, elapsed time, time left and temperatures. A printer whose
# address is unset is left out; with neither set the chip is hidden.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=pango.sh
. "$here/pango.sh"
# Endpoints stay out of this public repo, beside the Prometheus ones (.local/lib/prom.sh).
# shellcheck source=/dev/null
[ -r "$HOME/.config/command-center/env" ] && . "$HOME/.config/command-center/env"

NEPTUNE_URL="${CC_NEPTUNE_URL:-}"
A1_ADDR="${CC_A1_ADDR:-}"
# A bar module must not stall the bar on a printer that is off.
PRINTER_TIMEOUT=2
OFF_ALPHA="alpha='50%'"

dim() { printf "<span %s>%s</span>" "$OFF_ALPHA" "$1"; }
hm() { printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60)); }

parts=() tips=() class=""
add() { parts+=("$1"); tips+=("$2"); }

if [ -n "$NEPTUNE_URL" ]; then
  q="$NEPTUNE_URL/printer/objects/query?print_stats&virtual_sdcard&extruder&heater_bed"
  if ! body="$(curl -s -m "$PRINTER_TIMEOUT" "$q")" || [ -z "$body" ]; then
    add "$(dim 'Neptune off')" "Neptune: no answer at $NEPTUNE_URL (off or off Wi-Fi), so the slicer cannot send to it"
  elif ! jq -e . <<< "$body" >/dev/null 2>&1; then
    add "$(paint "$C_YEL" 'Neptune ?')" "Neptune: $NEPTUNE_URL answers, but not as Moonraker (wrong address?)"
    class=warn
  elif ! jq -e '.result.status.print_stats' <<< "$body" >/dev/null 2>&1; then
    why="$(jq -r '.error.message // "no printer state"' <<< "$body")"
    add "$(paint "$C_YEL" 'Neptune not ready')" "Neptune: Moonraker answers but Klipper is not ready: $(pango_esc "$why")"
    class=warn
  else
    # US, not tab: tab is IFS whitespace, so an empty field (an idle printer has no file) would
    # collapse and shift the rest.
    IFS=$'\x1f' read -r state file elapsed pct left temps < <(jq -r '.result.status as $s
      | ($s.virtual_sdcard.progress // 0) as $p | ($s.print_stats.print_duration // 0) as $d
      | [$s.print_stats.state, ($s.print_stats.filename // ""), ($d | floor), ($p * 100 + 1e-6 | floor),
         (if $p > 0.01 then ($d / $p - $d | floor) else -1 end),
         "nozzle \($s.extruder.temperature // 0 | round)/\($s.extruder.target // 0 | round)C, bed \($s.heater_bed.temperature // 0 | round)/\($s.heater_bed.target // 0 | round)C"]
      | map(tostring) | join("\u001f")' <<< "$body")
    tip="Neptune: $state"
    [ -n "$file" ] && tip+=$'\n'"$(pango_esc "$file")"
    case "$state" in
      printing)
        if [ "$elapsed" -eq 0 ]; then
          text="Neptune heating"
        else
          text="Neptune $pct%"
          tip+=$'\n'"$pct%, $(hm "$elapsed") in"
          # The slicer's estimate beats file progress, which runs far off early in a print.
          est="$(curl -s -m "$PRINTER_TIMEOUT" -G "$NEPTUNE_URL/server/files/metadata" --data-urlencode "filename=$file" \
            | jq -r '.result.estimated_time // 0 | select(. > 0) | floor' 2>/dev/null)"
          [ -n "$est" ] && left=$((est > elapsed ? est - elapsed : 0))
          [ "$left" -ge 0 ] && tip+=", about $(hm "$left") left"
        fi ;;
      paused) text="$(paint "$C_YEL" "Neptune paused $pct%")"; class=warn ;;
      error) text="$(paint "$C_RED" 'Neptune error')"; class=critical ;;
      complete) text="$(paint "$C_GRN" 'Neptune done')" ;;
      *) text="Neptune idle" ;;
    esac
    add "$text" "$tip"$'\n'"$temps"
  fi
fi

if [ -n "$A1_ADDR" ]; then
  if timeout "$PRINTER_TIMEOUT" bash -c ': < "/dev/tcp/${1%:*}/${1##*:}"' _ "$A1_ADDR" 2>/dev/null; then
    add "A1 on" "A1: on the LAN at $A1_ADDR (print state is in Home Assistant)"
  else
    add "$(dim 'A1 off')" "A1: no answer at $A1_ADDR"
  fi
fi

[ ${#parts[@]} -eq 0 ] && { emit "" "" ""; exit 0; }
# Both off is one dim word, not two.
if [ ${#parts[@]} -gt 1 ] && ! printf '%s\n' "${parts[@]}" | grep -qvF "$OFF_ALPHA"; then
  parts=("$(dim 'printers off')")
fi
text="$(printf '%s  ' "${parts[@]}")"
tooltip="$(printf '%s\n\n' "${tips[@]}")"
emit "${text%  }" "${tooltip%$'\n\n'}" "$class"
