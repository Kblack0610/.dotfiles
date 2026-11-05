#!/usr/bin/env bash
# questions.sh - every question an agent is waiting on you for, answered from one screen
# (Prefix y): the list, the selected card beside it (ctrl-/ moves it under, then hides it),
# and the answer right there: a number then enter sends that option, t types an answer,
# d then enter drops it, g goes to the asking session (reopening it when it has ended). Data
# and delivery are agent-ask's (list, card, answer, cancel, target).
#
# Usage: questions.sh [verb]
#
# Verbs:
#   rows              pending questions, NUL-ended "<id><TAB><row>": this tmux session's first,
#                     then oldest
#   key <k> <id> [q]  what a key does, as fzf actions (the picker's one transform handler)
#   --help, -h        this text
#   (no verb)         open the panel

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1
# project_slug: the short project name a row has room for.
. "${SELF%/*}/../../../.config/shared-hooks/project-name.sh" || exit 1

QUESTIONS_ASK="${QUESTIONS_ASK:-$HOME/.local/bin/agent-ask}"
# The armed choice between a key and its enter: "<mode> <option> <id>". The picker makes it.
QUESTIONS_STATE="${QUESTIONS_STATE:-}"
QUESTIONS_KEYS='1-9 pick . enter send . t type . g go . d drop . pgup/pgdn scroll card . C-/ layout . esc close'

# A row is "<slug>:<agent number>  <age>  <question>" and, under the question, what the
# session is (its registry title) and "ended" once it has: short enough for the list column
# beside the card (a third of the panel). Rows are NUL-ended, so fzf shows the two lines as one
# item. The agent number is the tmux session's -agent-N. Bold and faint, not colours, so the
# selected row still reads on fzf's selection bar.
cmd_rows() {
  local list here live epochs names name slugs="" titles
  list="$("$QUESTIONS_ASK" list --all --pending)"
  [ -n "$list" ] || return 0
  here="$(panel_in_tmux && tmux display-message -p '#{session_name}' 2>/dev/null)"
  live="$("$QUESTIONS_ASK" live-sessions 2>/dev/null | tr '\n' ' ')"
  titles="$(cut -f16 <<<"$list" | sort -u | "$QUESTIONS_ASK" titles 2>/dev/null)"
  # Every created stamp to epoch seconds in one date call; on a line date cannot read, the
  # ages go blank rather than shift onto the wrong rows.
  epochs="$(cut -f12 <<<"$list" | date -f - +%s 2>/dev/null)" || epochs=""
  [ "$(grep -c . <<<"$epochs")" = "$(grep -c . <<<"$list")" ] || epochs="$(sed 's/.*//' <<<"$list")"
  # One slug per project named (a row with no project goes by its session's name).
  names="$(awk -F'\t' '{ n = $2; if (n == "") { n = $13; sub(/-agent-[0-9]+$/, "", n) } print n }' <<<"$list" | sort -u)"
  while IFS= read -r name; do slugs+="$name=$(project_slug "$name");"; done <<<"$names"
  paste <(printf '%s\n' "$list") <(printf '%s\n' "$epochs") |
    awk -F'\t' -v here="$here" -v live=" $live" -v now="$(date +%s)" -v slugs=";$slugs" \
      -v bold="$C_BOLD" -v faint="$C_FAINT" -v off="$C_OFF" '
      function age(e,   d) {
        if (e == "") return ""
        d = now - e; if (d < 0) d = 0
        if (d < 3600) return int(d / 60) "m"
        if (d < 86400) return int(d / 3600) "h"
        return int(d / 86400) "d"
      }
      function slug(n,   i, r) {
        i = index(slugs, ";" n "="); if (i == 0) return n
        r = substr(slugs, i + length(n) + 2); return substr(r, 1, index(r, ";") - 1)
      }
      # The first file is the registry titles, "<claude session>\t<title>".
      FNR == NR { T[$1] = $2; next }
      {
        n = $2; if (n == "") { n = $13; sub(/-agent-[0-9]+$/, "", n) }
        who = slug(n)
        if (match($13, /agent-[0-9]+$/)) who = who ":" substr($13, RSTART + 6)
        W[NR] = who; if (length(who) > w) w = length(who)
        L[NR] = sprintf("%d\t%s\t%s\t", ($13 == here && here != "") ? 0 : 1, $19, $1)
        A[NR] = age($19); Q[NR] = $6
        S[NR] = ($16 != "" && index(live, " " $16 " ") == 0) ? "ended" : ""
        if (T[$16] != "") S[NR] = S[NR] (S[NR] != "" ? " . " : "") faint T[$16] off
      }
      # The name column is as wide as its longest name, up to 12. The second line starts under
      # the question; \037 stands for its newline until the rows are sorted.
      END {
        if (w > 12) w = 12
        for (i in W) {
          printf "%s%s%-*.*s%s %s%3s%s  %s", L[i], bold, w, w, W[i], off, faint, A[i], off, Q[i]
          if (S[i] != "") printf "\037%*s%s", w + 6, "", S[i]
          print ""
        }
      }' <(printf '%s\n' "$titles") - |
    sort -t "$PANEL_TAB" -k1,1n -k2,2n | cut -f3- | tr '\n\037' '\000\n'
}
# rows_count: how many questions cmd_rows printed (one NUL per row).
rows_count() { tr -cd '\000' | wc -c | tr -d ' '; }

# One handler for every answer key. It prints fzf actions; the state file carries an armed
# choice to the enter that sends it, so a stray key never sends anything. Texts go inside
# ~...~, so a ~ in a question is dropped from the footer, never parsed as an action.
st_read() { [ -n "$QUESTIONS_STATE" ] && cat "$QUESTIONS_STATE" 2>/dev/null; }
st_write() { [ -n "$QUESTIONS_STATE" ] && printf '%s\n' "$*" >"$QUESTIONS_STATE"; }
tilde() { printf '%s' "${1//\~/}"; }
footer() { printf 'change-footer~%s~' "$(tilde "$(fit "$1")")"; }

# list_cols: the list column's width, from the geometry fzf exports to a transform. Side by
# side (the card under three quarters of fzf's width, panel_layout_next's rule) the header and
# footer get what the card leaves, so they fit there; stacked or hidden they get the panel.
list_cols() {
  # Outside fzf (no geometry) nothing is folded.
  local c="${FZF_COLUMNS:-0}" p="${FZF_PREVIEW_COLUMNS:-0}"
  if [ "$c" -le 0 ]; then echo 1000
  elif [ "$p" -gt 0 ] && [ $((p * 4)) -lt $((c * 3)) ]; then echo $((c - p - 5))
  else echo $((c - 4)); fi
}
# fit <text>: <text> on as many lines as the list column needs, broken between " . " parts
# first, then at spaces.
fit() {
  local w; w="$(list_cols)"
  awk -v w="$w" '{
    n = split($0, P, / [.] /); line = ""
    for (i = 1; i <= n; i++) {
      c = (line == "") ? P[i] : line " . " P[i]
      if (length(c) <= w || line == "") line = c; else { print line; line = P[i] }
    }
    print line
  }' <<<"$1" | fold -s -w "$w" | sed 's/ *$//'
}

# ask_load <id>: the ask's options, question, status and who asked, from one `agent-ask show`.
ask_load() {
  local line k project="" session=""
  A_OPTS=() A_WHO="" A_Q="" A_STATUS=""
  while IFS= read -r line; do
    k="${line%%: *}"
    case "$k" in
    status) A_STATUS="${line#*: }" ;;
    options) IFS='|' read -r -a A_OPTS <<<"${line#*: }" ;;
    question) A_Q="${line#*: }" ;;
    project) project="${line#*: }" ;;
    session) session="${line#*: }" ;;
    esac
  done < <("$QUESTIONS_ASK" show "$1" 2>/dev/null)
  # Who asked, as the rows name it: the project's slug and the session's agent number.
  A_WHO="$(project_slug "${project:-${session%-agent-*}}")"
  [[ "$session" =~ agent-([0-9]+)$ ]] && A_WHO+=":${BASH_REMATCH[1]}"
}

# after <message>: reload the rows and say what happened, with the count in the header.
after() {
  local n
  n="$(cmd_rows | rows_count)"
  st_write ""
  printf 'hide-input+change-prompt~~+reload(%s rows)+change-header~%s~+' "$(printf '%q' "$SELF")" "$(waiting "$n")"
  if [ "$n" = 0 ]; then footer "$1 . no questions waiting . esc closes"; else footer "$1"; fi
}
# The header back to the count, once typing (which names the question there) is over.
header_count() { printf 'change-header~%s~+' "$(waiting "$(cmd_rows | rows_count)")"; }
waiting() { if [ "$1" = 0 ]; then echo "no questions waiting"; else echo "$1 waiting"; fi; }

cmd_key() {
  local k="${1:-}" id="${2:-}" q="${3:-}" mode="" opt="" sid=""
  read -r mode opt sid <<<"$(st_read)"
  case "$k" in
  focus)
    # Moving to another question disarms a choice made on the last one; typing keeps going.
    # With nothing armed the keys are fitted again, to whatever layout ctrl-/ left.
    if [ -z "$mode" ]; then footer "$QUESTIONS_KEYS"
    elif [ "$mode" != typing ] && [ "$sid" != "$id" ]; then st_write ""; footer "$QUESTIONS_KEYS"; fi
    ;;
  fit)
    # start and resize: the keys sized to the list column, unless a key's message is up.
    [ -n "$mode" ] || footer "$QUESTIONS_KEYS"
    ;;
  esc)
    [ -n "$mode" ] || { printf 'abort'; return 0; }
    st_write ""
    printf 'hide-input+change-prompt~~+'
    [ "$mode" = typing ] && header_count
    footer "$QUESTIONS_KEYS"
    ;;
  g)
    if [ "$mode" = typing ]; then printf 'put(g)'; return 0; fi
    [ -n "$id" ] || return 0
    # agent-ask resolves the session (its live_row) and reopens an ended one through
    # fleet-dispatch; agent-panel owns the cross-server hop.
    local to
    if to="$("$QUESTIONS_ASK" target --reopen "$id" 2>&1)"; then
      printf 'execute-silent(agent-panel jump %s)+abort' "$(printf '%q' "$to")"
    else footer "${to:-no session to go to}"; fi
    ;;
  [1-9] | d | t)
    if [ "$mode" = typing ]; then printf 'put(%s)' "$k"; return 0; fi
    [ -n "$id" ] || return 0
    ask_load "$id"
    # A key pressed before the reload after a send lands on the row just answered: refresh.
    if [ "$A_STATUS" != pending ]; then
      printf 'reload(%s rows)+' "$(printf '%q' "$SELF")"
      footer "that question was just ${A_STATUS:-closed}; the list is refreshed"
      return 0
    fi
    case "$k" in
    t)
      # The header says what is being answered and the prompt is just the line to type on.
      # Cleared after show-input, never beside hide-input: fzf 0.74 keeps a query changed while
      # the input hides, which brought the last answer back on the next t.
      st_write typing - "$id"
      printf 'show-input+clear-query+change-prompt~answer> ~+change-header~%s~+' "$(tilde "$(fit "answering $A_WHO: $A_Q" | head -4)")"
      footer "enter sends . esc cancels"
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
  panel_fzf_layout side

  local me rows k binds=()
  me="$(printf '%q' "$SELF")"
  QUESTIONS_STATE="$(mktemp)"
  rows="$(mktemp)"
  export QUESTIONS_STATE
  trap 'rm -f "$QUESTIONS_STATE" "$rows"' EXIT
  cmd_rows >"$rows"
  for k in 1 2 3 4 5 6 7 8 9 d t g; do binds+=("--bind=$k:transform($me key $k {1} {q})"); done

  # --no-input --disabled: no search box (a handful of rows), which frees the digit keys;
  # t shows the input as the answer line. --no-wrap: a long question ends in .. on its row
  # and reads in full in the card. --read0: a row is two lines (question, then session).
  # pgup/pgdn scroll the card, a page at a time; the list is a handful of rows.
  fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" "${PANEL_FZF_LAYOUT[@]}" <"$rows" \
    --read0 --no-wrap --no-input --disabled --with-nth=2.. \
    --border-label=' questions ' --border-label-pos=3 \
    --header="$(waiting "$(rows_count <"$rows")")" \
    --footer="$QUESTIONS_KEYS" \
    --preview="AGENT_ASK_COLOR=1 COLUMNS=\$FZF_PREVIEW_COLUMNS $(printf '%q' "$QUESTIONS_ASK") card {1}" \
    "${binds[@]}" \
    --bind="enter:transform($me key enter {1} {q})" \
    --bind="esc:transform($me key esc {1})" \
    --bind="focus:transform($me key focus {1})" \
    --bind="page-up:preview-page-up,page-down:preview-page-down" \
    --bind="start,resize:transform($me key fit)" >/dev/null
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
