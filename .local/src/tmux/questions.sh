#!/usr/bin/env bash
# questions.sh - every question an agent is waiting on you for, answered from one screen
# (Prefix y): the list, the selected card below it (ctrl-/ moves it beside, then hides it),
# and the answer right there: a number then enter sends that option, t types an answer,
# d then enter drops it. Data and delivery are agent-ask's (list, card, answer, cancel).
#
# Usage: questions.sh [verb]
#
# Verbs:
#   rows              pending questions as TSV (id, row): this tmux session's first, then oldest
#   key <k> <id> [q]  what a key does, as fzf actions (the picker's one transform handler)
#   --help, -h        this text
#   (no verb)         open the panel

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

QUESTIONS_ASK="${QUESTIONS_ASK:-$HOME/.local/bin/agent-ask}"
# The armed choice between a key and its enter: "<mode> <option> <id>". The picker makes it.
QUESTIONS_STATE="${QUESTIONS_STATE:-}"
QUESTIONS_KEYS='1-9 pick . enter send . t type . d drop . ctrl-/ layout . esc close'

cmd_rows() {
  local list here live epochs
  list="$("$QUESTIONS_ASK" list --all --pending)"
  [ -n "$list" ] || return 0
  here="$(panel_in_tmux && tmux display-message -p '#{session_name}' 2>/dev/null)"
  live="$("$QUESTIONS_ASK" live-sessions 2>/dev/null | tr '\n' ' ')"
  # Every created stamp to epoch seconds in one date call; on a line date cannot read, the
  # ages go blank rather than shift onto the wrong rows.
  epochs="$(cut -f12 <<<"$list" | date -f - +%s 2>/dev/null)" || epochs=""
  [ "$(grep -c . <<<"$epochs")" = "$(grep -c . <<<"$list")" ] || epochs="$(sed 's/.*//' <<<"$list")"
  paste <(printf '%s\n' "$list") <(printf '%s\n' "$epochs") |
    awk -F'\t' -v here="$here" -v live=" $live" -v now="$(date +%s)" \
      -v proj="$C_PROJ" -v dim="$C_DIM" -v off="$C_OFF" '
      function age(e,   d) {
        if (e == "") return ""
        d = now - e; if (d < 0) d = 0
        if (d < 3600) return int(d / 60) "m"
        if (d < 86400) return int(d / 3600) "h"
        return int(d / 86400) "d"
      }
      {
        gone = ($16 != "" && index(live, " " $16 " ") == 0) ? "  " dim "gone" off : ""
        printf "%d\t%s\t%s\t%s%-14.14s%s %s%4s%s  %s%s\n", ($13 == here && here != "") ? 0 : 1, $19, $1,
          proj, $2, off, dim, age($19), off, $6, gone
      }' |
    sort -t "$PANEL_TAB" -k1,1n -k2,2n | cut -f3-
}

# One handler for every answer key. It prints fzf actions; the state file carries an armed
# choice to the enter that sends it, so a stray key never sends anything. Texts go inside
# ~...~, so a ~ in a question is dropped from the footer, never parsed as an action.
st_read() { [ -n "$QUESTIONS_STATE" ] && cat "$QUESTIONS_STATE" 2>/dev/null; }
st_write() { [ -n "$QUESTIONS_STATE" ] && printf '%s\n' "$*" >"$QUESTIONS_STATE"; }
tilde() { printf '%s' "${1//\~/}"; }
footer() { printf 'change-footer~%s~' "$(tilde "$1")"; }

# ask_load <id>: the ask's options and who asked, from one `agent-ask show`.
ask_load() {
  local line k project="" session=""
  A_OPTS=() A_WHO=""
  while IFS= read -r line; do
    k="${line%%: *}"
    case "$k" in
    options) IFS='|' read -r -a A_OPTS <<<"${line#*: }" ;;
    project) project="${line#*: }" ;;
    session) session="${line#*: }" ;;
    esac
  done < <("$QUESTIONS_ASK" show "$1" 2>/dev/null)
  A_WHO="${session:-$project}"
}

# after <message>: reload the rows and say what happened, with the count in the header.
after() {
  local n
  n="$(cmd_rows | grep -c . || true)"
  st_write ""
  printf 'hide-input+clear-query+change-prompt~~+reload(%s rows)+change-header~%s~+' "$(printf '%q' "$SELF")" "$(waiting "$n")"
  if [ "$n" = 0 ]; then footer "$1 . no questions waiting . esc closes"; else footer "$1"; fi
}
waiting() { if [ "$1" = 0 ]; then echo "no questions waiting"; else echo "$1 waiting"; fi; }

cmd_key() {
  local k="${1:-}" id="${2:-}" q="${3:-}" mode="" opt="" sid=""
  read -r mode opt sid <<<"$(st_read)"
  case "$k" in
  focus)
    # Moving to another question disarms a choice made on the last one; typing keeps going.
    [ -n "$mode" ] && [ "$mode" != typing ] && [ "$sid" != "$id" ] && { st_write ""; footer "$QUESTIONS_KEYS"; }
    ;;
  esc)
    if [ -n "$mode" ]; then st_write ""; printf 'hide-input+clear-query+change-prompt~~+'; footer "$QUESTIONS_KEYS"; else printf 'abort'; fi
    ;;
  [1-9] | d | t)
    if [ "$mode" = typing ]; then printf 'put(%s)' "$k"; return 0; fi
    [ -n "$id" ] || return 0
    ask_load "$id"
    case "$k" in
    t)
      st_write typing - "$id"
      printf 'clear-query+show-input+change-prompt~answer %s> ~+' "$(tilde "$id")"
      footer "type the answer for $A_WHO . enter sends . esc cancels"
      ;;
    d)
      st_write drop - "$id"
      footer "drop $id (nobody gets an answer)? enter drops . esc cancels"
      ;;
    *)
      if [ "$k" -gt "${#A_OPTS[@]}" ]; then
        footer "no option $k here . t types an answer"
      else
        st_write armed "$k" "$id"
        footer "send $k \"${A_OPTS[k - 1]}\" to $A_WHO? enter sends . esc cancels"
      fi
      ;;
    esac
    ;;
  enter)
    local err
    case "$mode" in
    armed)
      ask_load "$sid"
      if err="$("$QUESTIONS_ASK" answer "$sid" "${A_OPTS[opt - 1]}" 2>&1 >/dev/null)"; then
        after "sent \"${A_OPTS[opt - 1]}\" to $A_WHO"
      else st_write ""; footer "not sent: ${err:-agent-ask answer failed}"; fi
      ;;
    typing)
      [ -n "$q" ] || { footer "type an answer first . esc cancels"; return 0; }
      if err="$("$QUESTIONS_ASK" answer "$sid" "$q" 2>&1 >/dev/null)"; then after "sent your answer"
      else footer "not sent: ${err:-agent-ask answer failed}"; fi
      ;;
    drop)
      if err="$("$QUESTIONS_ASK" cancel "$sid" dropped by the human 2>&1 >/dev/null)"; then after "dropped $sid"
      else st_write ""; footer "not dropped: ${err:-agent-ask cancel failed}"; fi
      ;;
    *) footer "press a number, t or d first . $QUESTIONS_KEYS" ;;
    esac
    ;;
  *) panel_die "unknown key: $k" ;;
  esac
}

cmd_pick() {
  panel_need fzf
  panel_fzf_opts
  panel_fzf_table
  panel_fzf_layout

  local me rows k binds=()
  me="$(printf '%q' "$SELF")"
  QUESTIONS_STATE="$(mktemp)"
  export QUESTIONS_STATE
  trap 'rm -f "$QUESTIONS_STATE"' EXIT
  rows="$(cmd_rows)"
  for k in 1 2 3 4 5 6 7 8 9 d t; do binds+=("--bind=$k:transform($me key $k {1} {q})"); done

  # --no-input --disabled: no search box (a handful of rows), which frees the digit keys;
  # t shows the input as the answer line. --no-wrap: a long question ends in .. on its row
  # and reads in full in the card.
  printf '%s' "$rows" | fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" "${PANEL_FZF_LAYOUT[@]}" \
    --no-wrap --no-input --disabled --with-nth=2.. \
    --border-label=' questions ' --border-label-pos=3 \
    --header="$(waiting "$(grep -c . <<<"$rows")")" \
    --footer="$QUESTIONS_KEYS" \
    --preview="AGENT_ASK_COLOR=1 COLUMNS=\$FZF_PREVIEW_COLUMNS $(printf '%q' "$QUESTIONS_ASK") card {1}" \
    "${binds[@]}" \
    --bind="enter:transform($me key enter {1} {q})" \
    --bind="esc:transform($me key esc {1})" \
    --bind="focus:transform($me key focus {1})" >/dev/null
  return 0
}

# The test seam: sourced by the bats tests, stop before dispatch.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

case "${1:-}" in
rows) cmd_rows ;;
key) shift; cmd_key "$@" ;;
'') cmd_pick ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: $1 (try --help)" ;;
esac
