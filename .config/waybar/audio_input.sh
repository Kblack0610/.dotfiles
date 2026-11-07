#!/usr/bin/env bash
# Waybar custom/audio-input: the input apps hear (PipeWire's default source), and the switch
# between the rig's inputs listed in ~/.config/audio/inputs.conf (owned by ~/dev/home/audio).
# No list (the laptop): the chip prints nothing. Why only the default moves: PIN.md "Input chip".
#
#   audio_input.sh watch       the bar: one JSON line now and on each change (no interval)
#   audio_input.sh set <key>   make that input the default (Super+A i <key>)
#   audio_input.sh next|prev   step through the list (click, right-click)
#
# watch reads `pactl subscribe`: a server event is a default change, a source event a mute or
# volume change, a client event REAPER opening or closing (a rig_ input is silent without it).
# AUDIO_INPUTS moves the list, for the tests.
set -u
here="$(dirname "$(readlink -f "$0")")"
# shellcheck source=pango.sh
. "$here/pango.sh"
conf="${AUDIO_INPUTS:-${XDG_CONFIG_HOME:-$HOME/.config}/audio/inputs.conf}"

# rows: the list, one "key|bar|label|source glob" per line.
rows() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$conf"; }

# match <source name>: the row whose glob matches it.
match() {
  local key bar label glob
  while IFS='|' read -r key bar label glob; do
    # shellcheck disable=SC2053  # the glob is the point
    [[ $1 == $glob ]] && { printf '%s|%s|%s|%s\n' "$key" "$bar" "$label" "$glob"; return 0; }
  done < <(rows)
  return 1
}

# resolve <glob>: the live source node the glob names.
resolve() {
  local name
  while read -r name; do
    # shellcheck disable=SC2053
    [[ $name == $1 ]] && { printf '%s\n' "$name"; return 0; }
  done < <(pactl list short sources | cut -f2)
  return 1
}

fail() {
  notify-send -u critical "Audio input" "$1" 2>/dev/null || true
  echo "audio_input.sh: $1" >&2
  exit 1
}

set_input() {
  local row glob name
  row="$(rows | awk -F'|' -v k="$1" '$1 == k { print; exit }')"
  [[ -n $row ]] || fail "no input with key $1 in $conf"
  glob="${row##*|}"
  name="$(resolve "$glob")" || fail "$(cut -d'|' -f3 <<<"$row") is not connected ($glob)"
  pactl set-default-source "$name" || fail "pactl could not select $name"
}

# step <+1|-1>: the input after (or before) the current one, wrapping; the first when the
# default is not in the list.
step() {
  local keys cur i n
  mapfile -t keys < <(rows | cut -d'|' -f1)
  n=${#keys[@]}
  ((n)) || fail "no inputs in $conf"
  cur="$(match "$(pactl get-default-source)" | cut -d'|' -f1)"
  for ((i = 0; i < n; i++)); do
    [[ ${keys[i]} == "$cur" ]] && { set_input "${keys[(i + $1 + n) % n]}"; return; }
  done
  set_input "${keys[0]}"
}

render() {
  local def row key bar label glob vol muted class text tip list mark
  def="$(pactl get-default-source)"
  vol="$(pactl get-source-volume "$def" 2>/dev/null | grep -o '[0-9]*%' | head -1)"
  muted="$(pactl get-source-mute "$def" 2>/dev/null)"
  if row="$(match "$def")"; then
    IFS='|' read -r key bar label glob <<<"$row"
    class=ok
    [[ $def == rig_* ]] && ! pw-link -o 2>/dev/null | grep -qx 'REAPER:out1' && class=warn
  else
    label="$(pactl -f json list sources 2>/dev/null | jq -r --arg n "$def" '.[] | select(.name == $n) | .description' | head -1)"
    label="${label:-$def}" bar="${label:0:12}" class=other
  fi
  text=" $bar"
  [[ $muted == *yes ]] && text=" $bar" class=muted
  tip="<b>$(pango_esc "$label")</b>  ${vol:-?}"
  case $class in
    muted) tip+=", muted" ;;
    warn) tip+=$'\n'"REAPER is closed, so this input is silent" ;;
    other) tip+=$'\n'"Not in the list: $(pango_esc "$conf")" ;;
  esac
  list=''
  while IFS='|' read -r key bar label glob; do
    mark='  '
    # shellcheck disable=SC2053
    [[ $def == $glob ]] && mark='> '
    list+=$'\n'"<tt>$mark$key</tt>  $(pango_esc "$label")"
  done < <(rows)
  tip+=$'\n'"$list"$'\n\n'"Click: next. Right-click: previous. Super+A i: pick by key."
  emit "$text" "$tip" "$class"
}

watch() {
  [[ -f $conf ]] || { echo '{"text":""}'; exit 0; }
  local last='' line event
  show() { line="$(render)"; [[ $line == "$last" ]] || { printf '%s\n' "$line"; last=$line; }; }
  show
  while read -r event; do
    case $event in *" on server"* | *" on source "* | *" on client "*) show ;; esac
  done < <(pactl subscribe)
}

case "${1:-}" in
  watch) watch ;;
  set) set_input "${2:?set needs an input key}" ;;
  next) step 1 ;;
  prev) step -1 ;;
  *) echo "usage: audio_input.sh {watch|set <key>|next|prev}" >&2; exit 2 ;;
esac
