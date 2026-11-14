#!/usr/bin/env bash
# questions.sh - every question an agent is waiting on you for, answered from one screen
# (Prefix y): the list, the selected card beside it (ctrl-/ moves it under, then hides it),
# and the answer right there: a number then enter sends that option, t types an answer,
# d then enter drops it, p then enter parks it until its revisit date (or puts a parked one back),
# g goes to the asking session (reopening it when it has ended), P shows or hides the parked
# asks (hidden when the panel opens: the human does not want them in view). Data and delivery are
# agent-ask's (list, card, answer, cancel, park, target).
#
# Below the asks, one row per session the fleet state document has in NEEDS for a dialog open
# in its own terminal (a plan to approve, an AskUserQuestion, a permission): agent-ask never
# sees those, yet the status bar counts them in its !N. A plan or question row is answered
# here too: its card and options come from `agent-panel dialog`, which reads the live pane, and
# a number then enter presses that option there through `agent-panel answer`, which refuses
# when the dialog changed since the card was drawn. A dialog the parser does not know (a
# permission prompt) shows the bottom of its pane and is answered in the session (g).
#
# Usage: questions.sh [verb]
#
# Verbs:
#   rows              pending questions, NUL-ended "<id><TAB><row>": this tmux session's first,
#                     then the live asks oldest first, then the sessions with a dialog open
#                     (id @<target>), then the dead asks oldest first, then the parked asks
#                     soonest back first; in the panel the parked ones only after P
#   saved             the rows as the panel last built them (after an answer, P), not built again
#   count             how many rows rows prints less the parked ones, one number: the pending asks
#                     plus the open dialogs. The agents status bar's !N, so the bar and this panel
#                     never disagree
#   key <k> <id> [q]  what a key does, as fzf actions (the picker's one transform handler).
#                     The panel's enter is `key submit`: it puts "sending ..." on screen and runs
#                     `key enter`, the send itself, in the background
#   card <id>         the card for one row (agent-ask card, or agent-panel dialog)
#   --help, -h        this text
#   (no verb)         open the panel

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1
# project_slug: the short project name a row has room for.
. "${SELF%/*}/../../../.config/shared-hooks/project-name.sh" || exit 1
# now_utc: the clock a parked card's date is read against.
. "${SELF%/*}/../../lib/fmt.sh" || exit 1

QUESTIONS_ASK="${QUESTIONS_ASK:-$HOME/.local/bin/agent-ask}"
# fleet-sessions' state document: a worker host's sessions, which no local read can see.
FLEET_STATE_FILE="${FLEET_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet/state.json}"
# The armed choice between a key and its enter: "<mode> <option> <id> [<option text>]", or "said"
# while a result (a send, a refusal, P's toggle) is in the footer. The picker makes it.
QUESTIONS_STATE="${QUESTIONS_STATE:-}"
# The panel's parked toggle: a file reading "show" once P shows the parked asks. Unset (outside the
# panel) rows lists them all; the picker makes it empty, so they start hidden.
QUESTIONS_PARKED="${QUESTIONS_PARKED:-}"
QUESTIONS_KEYS='1-9 pick . enter send . t type . g go . d drop . p park . P parked . C-d/C-u pgup/pgdn scroll card . C-/ layout . esc close'

# A row is "LIVE|none|dead <slug>:<agent number>  <age>  <question>" and, under the question, what the
# session is (its registry title): short enough for the list column beside the card (a third of
# the panel). LIVE is a running session waiting (agent-ask live-sessions, or an open dialog), dead an
# ask whose session has ended, none an ask no session filed (intake, headless), as its card says
# "no session is waiting" (human, 2026-11-10). none sorts with LIVE, since its answer still acts.
# park is an ask parked until a revisit date (agent-ask park), shown last with that date in the
# age column, so it is in reach but not in the count. Where an answer goes is on the card
# (agent-ask answer_route), not the row: the row has no room for it
# (human, 2026-11-10). Rows are NUL-ended, so fzf shows the two lines as one
# item. The agent number is the tmux session's -agent-N. Bold and faint, not colours, so the
# selected row still reads on fzf's selection bar.
# prompt_rows: the sessions with a dialog open now, and prompt_list those rows with the project added:
# "<target>\t<project>\t<idle min>\t<doing>\t<topic>", the project resolved from the session's
# directory the way an ask's is. Live from agent-panel, so a plan shows as soon as it waits and
# goes when it is answered; QUESTIONS_ANSWERED is the one just answered, whose status file can
# trail its pane by a moment. A worker's sessions come from the state document, a pass behind.
prompt_rows() {
  {
    agent-panel list --json 2>/dev/null | jq -r --argjson now "$(date +%s)" --arg done "${QUESTIONS_ANSWERED:-}" '
      select(.status == "waiting" and .target != $done)
      | [.target, (.cwd // ""), ((($now - (.idle_since // $now)) / 60 | floor | if . < 0 then 0 else . end)),
         (.doing // "" | gsub("[\t\n]"; " ")), (.summary // "" | gsub("[\t\n]"; " "))] | @tsv' 2>/dev/null
    [ -r "$FLEET_STATE_FILE" ] && jq -r --arg done "${QUESTIONS_ANSWERED:-}" '.sessions[]? | select((.target | contains("@")) and .activity == "waiting" and .target != $done)
      | [.target, (.cwd // ""), (.idle_min // 0),
         (.doing // "" | gsub("[\t\n]"; " ")), (.topic // "" | gsub("[\t\n]"; " "))] | @tsv' \
      "$FLEET_STATE_FILE" 2>/dev/null
  } | awk -F'\t' '$1 != ""'
}
prompt_list() {
  local t cwd rest
  prompt_rows |
    while IFS=$'\t' read -r t cwd rest; do
      printf '%s\t%s\t%s\n' "$t" "$( [ -n "$cwd" ] && resolve_project_name "$cwd" 2>/dev/null)" "$rest"
    done
}

cmd_rows() {
  local list prompts here live epochs names name slugs="" titles
  list="$("$QUESTIONS_ASK" list --all --open)"
  prompts="$(prompt_list)"
  [ -n "$list$prompts" ] || return 0
  here="$(panel_in_tmux && tmux display-message -p '#{session_name}' 2>/dev/null)"
  live="$("$QUESTIONS_ASK" live-sessions 2>/dev/null | tr '\n' ' ')"
  titles="$(cut -f16 <<<"$list" | sort -u | "$QUESTIONS_ASK" titles 2>/dev/null)"
  # Every created stamp to epoch seconds in one date call; on a line date cannot read, the
  # ages go blank rather than shift onto the wrong rows.
  epochs="$(cut -f12 <<<"$list" | date -f - +%s 2>/dev/null)" || epochs=""
  [ "$(grep -c . <<<"$epochs")" = "$(grep -c . <<<"$list")" ] || epochs="$(sed 's/.*//' <<<"$list")"
  # The same for parked_until (filled only on a parked ask), so a parked row sorts and reads in
  # seconds like the rest. An unparked row reads @0, so every row keeps its line.
  backs="$(awk -F'\t' '{ print $27 == "" ? "@0" : $27 }' <<<"$list" | date -f - +%s 2>/dev/null)" || backs=""
  [ "$(grep -c . <<<"$backs")" = "$(grep -c . <<<"$list")" ] || backs="$(sed 's/.*//' <<<"$list")"
  # One slug per project named (a row with no project goes by its session's name; a prompt
  # row always does).
  names="$({ awk -F'\t' 'NF { n = $2; if (n == "") { n = $13; sub(/-agent-[0-9]+$/, "", n) } print n }' <<<"$list"
    awk -F'\t' 'NF { n = $2; if (n == "") { n = $1; sub(/^[^\/]*\//, "", n); sub(/(-agent-[0-9]+)?:[0-9]+$/, "", n) } print n }' <<<"$prompts"; } | sort -u)"
  while IFS= read -r name; do [ -n "$name" ] && slugs+="$name=$(project_slug "$name");"; done <<<"$names"
  { [ -n "$list" ] && paste <(printf '%s\n' "$list") <(printf '%s\n' "$epochs") <(printf '%s\n' "$backs"); } |
    awk -F'\t' -v here="$here" -v live=" $live" -v now="$(date +%s)" -v slugs=";$slugs" \
      -v bold="$C_BOLD" -v faint="$C_FAINT" -v off="$C_OFF" '
      function span(d) {
        if (d < 0) d = 0
        if (d < 3600) return int(d / 60) "m"
        if (d < 86400) return int(d / 3600) "h"
        return int(d / 86400) "d"
      }
      function age(e) { return e == "" ? "" : span(now - e) }
      function slug(n,   i, r) {
        i = index(slugs, ";" n "="); if (i == 0) return n
        r = substr(slugs, i + length(n) + 2); return substr(r, 1, index(r, ";") - 1)
      }
      # The files are the registry titles, "<claude session>\t<title>", then the prompts
      # (prompt_list), then the asks on stdin.
      FNR == 1 { part++ }
      part == 1 { T[$1] = $2; next }
      part == 2 {
        if ($1 == "") next
        s = $1; sub(/^[^\/]*\//, "", s); sub(/:[0-9]+$/, "", s)
        n = $2; if (n == "") { n = s; sub(/-agent-[0-9]+$/, "", n) }
        who = slug(n)
        # The agent number, or on a hub session the window, since a hub session holds several.
        if (match(s, /agent-[0-9]+$/)) who = who ":" substr(s, RSTART + 6)
        else if (match($1, /:[0-9]+$/)) who = who substr($1, RSTART)
        k = "p" FNR; W[k] = who; if (length(who) > w) w = length(who)
        e = now - $3 * 60
        L[k] = sprintf("2\t%d\t@%s\t", e, $1); A[k] = age(e); M[k] = 2
        tool = $4; sub(/:.*/, "", tool)
        if (tool == "ExitPlanMode") Q[k] = "plan waiting for approval"
        else if (tool == "AskUserQuestion") Q[k] = "question waiting for an answer"
        else Q[k] = "prompt waiting in its terminal" ($4 != "" ? ": " $4 : "")
        S[k] = ($5 != "") ? faint $5 off : ""
        next
      }
      {
        n = $2; if (n == "") { n = $13; sub(/-agent-[0-9]+$/, "", n) }
        who = slug(n)
        if (match($13, /agent-[0-9]+$/)) who = who ":" substr($13, RSTART + 6)
        W[NR] = who; if (length(who) > w) w = length(who)
        M[NR] = ($16 == "") ? 1 : (index(live, " " $16 " ") > 0) ? 2 : 0
        # The last two fields are the created and the parked_until epochs pasted on above.
        L[NR] = sprintf("%d\t%s\t%s\t", ($13 == here && here != "") ? 0 : M[NR] ? 1 : 3, $(NF - 1), $1)
        A[NR] = age($(NF - 1)); Q[NR] = $6
        # $27 is parked_until, filled only while the ask is parked: it sorts last, soonest back
        # first, and its age column says how long until it comes back.
        if ($27 != "" && $NF != "") { M[NR] = 3; L[NR] = sprintf("4\t%s\t%s\t", $NF, $1); A[NR] = span($NF - now) }
        S[NR] = (T[$16] != "") ? faint T[$16] off : ""
      }
      # The name column is as wide as its longest name, up to 12. The second line starts under
      # the question; \037 stands for its newline until the rows are sorted.
      END {
        if (w > 12) w = 12
        for (i in W) {
          printf "%s%s %s%-*.*s%s %s%3s%s  %s", L[i], M[i] == 2 ? bold "LIVE" off : M[i] == 1 ? faint "none" off : M[i] == 3 ? faint "park" off : faint "dead" off,
            bold, w, w, W[i], off, faint, A[i], off, Q[i]
          if (S[i] != "") printf "\037%*s%s", w + 11, "", S[i]
          print ""
        }
      }' <(printf '%s\n' "$titles") <(printf '%s\n' "$prompts") - |
    sort -t "$PANEL_TAB" -k1,1n -k2,2n | cut -f3- | tr '\n\037' '\000\n'
}
# parked_shown: true outside the panel, and in it once P showed the parked asks.
parked_shown() { [ -z "$QUESTIONS_PARKED" ] || [ "$(cat "$QUESTIONS_PARKED" 2>/dev/null)" = show ]; }
# PARK_ROW: the awk rule that sets park=1 on a parked ask's row, one row per record with its lines
# joined by \037 (an ask row, not an @ dialog, whose first line's tag is park). parked_filter and
# rows_count both read it, so the hidden rows and the header's parked count cannot disagree.
PARK_ROW='{ t = $0; sub(/\037.*/, "", t); gsub(/\033\[[0-9;]*m/, "", t); park = !/^@/ && t ~ /^[^\t]*\tpark / }'
# parked_filter: the rows on stdin less the parked asks while the panel hides them.
parked_filter() {
  if parked_shown; then cat; return 0; fi
  tr '\n\000' '\037\n' | awk "$PARK_ROW"' park { next } { print }' | tr '\n\037' '\000\n'
}
# cmd_count: the number of rows cmd_rows would print: the same ask list, and the same dialogs read
# without the transcripts (agent-panel's `!` glyph is its `waiting` status, which prompt_rows
# selects; tests/integ/questions_panel.bats holds the two equal). A status bar ticks every 3 s,
# so it gets no titles, routes or project names.
cmd_count() {
  local asks prompts
  asks="$("$QUESTIONS_ASK" list --all --pending | grep -c .)" || true
  prompts="$({
    agent-panel list 2>/dev/null | awk -F'\t' -v done="${QUESTIONS_ANSWERED:-}" '$2 == "!" && $1 != done { print $1 }'
    [ -r "$FLEET_STATE_FILE" ] && jq -r --arg done "${QUESTIONS_ANSWERED:-}" '.sessions[]? | select((.target | contains("@")) and .activity == "waiting" and .target != $done) | .target' "$FLEET_STATE_FILE" 2>/dev/null
  } | grep -c .)" || true
  echo $((${asks:-0} + ${prompts:-0}))
}
# rows_count: "<asks> <plans> <questions> <prompts> <parked>" in what cmd_rows printed (a row is
# NUL-ended; a dialog's id starts with @ and its first line names its kind; a parked ask's tag is park).
rows_count() {
  tr '\n\000' '\037\n' | awk "$PARK_ROW"'{ split($0, L, "\037") }
    park { k++; next }
    !/^@/ { a++; next } L[1] ~ /plan waiting for approval/ { p++; next }
    L[1] ~ /question waiting for an answer/ { q++; next } { o++ }
    END { print a + 0, p + 0, q + 0, o + 0, k + 0 }'
}

# One handler for every answer key. It prints fzf actions; the state file carries an armed
# choice to the enter that sends it, so a stray key never sends anything. Texts go inside
# ~...~, so a ~ in a question is dropped from the footer, never parsed as an action.
st_read() { [ -n "$QUESTIONS_STATE" ] && cat "$QUESTIONS_STATE" 2>/dev/null; }
st_write() { [ -n "$QUESTIONS_STATE" ] && printf '%s\n' "$*" >"$QUESTIONS_STATE"; }
# The busy marker beside the state: while a send is on its way it holds what is being sent, the
# card shows it, and every key says so instead of acting, so a second enter sends nothing.
# submit writes it; enter, the send, removes it when it is through.
busy_read() { [ -n "$QUESTIONS_STATE" ] && cat "$QUESTIONS_STATE.busy" 2>/dev/null; }
busy_write() { [ -n "$QUESTIONS_STATE" ] && printf '%s\n' "$*" >"$QUESTIONS_STATE.busy"; }
busy_clear() { [ -n "$QUESTIONS_STATE" ] && rm -f "$QUESTIONS_STATE.busy"; }
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
  A_OPTS=() A_WHO="" A_Q="" A_STATUS="" A_PARKED=""
  while IFS= read -r line; do
    k="${line%%: *}"
    case "$k" in
    status) A_STATUS="${line#*: }" ;;
    parked_until) [[ "${line#*: }" > "$(now_utc)" ]] && A_PARKED="${line#*: }" ;;
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

# The rows as last built, before the parked filter, in "$QUESTIONS_STATE.rows": the reload and the
# header's count both read the one build (after built the rows twice per answer, a second each, on
# 2026-11-13). rows_build writes it, whole or not at all (a reload reading it mid-build would show
# a blank list); rows_saved reads it, building it first when there is none. Outside the panel
# (no QUESTIONS_STATE) there is no file: saved builds the rows each time.
rows_build() { [ -z "$QUESTIONS_STATE" ] || { cmd_rows >"$QUESTIONS_STATE.rows.$$" && mv -f "$QUESTIONS_STATE.rows.$$" "$QUESTIONS_STATE.rows"; }; }
rows_saved() {
  [ -n "$QUESTIONS_STATE" ] || { cmd_rows; return 0; }
  [ -e "$QUESTIONS_STATE.rows" ] || rows_build
  cat "$QUESTIONS_STATE.rows"
}

# after <message>: reload the rows and say what happened, with the count in the header.
after() {
  local n
  rows_build
  n="$(rows_saved | rows_count)"
  # The reload may fire focus (the answered row went) or not; "said" keeps the result either way.
  st_write said
  printf 'hide-input+change-prompt~~+reload(%q saved)+change-header~%s~+' "$SELF" "$(waiting $n)"
  if [ "${n% *}" = "0 0 0 0" ]; then footer "$1 . no questions waiting . esc closes"; else footer "$1"; fi
}
# The header back to the count, once typing (which names the question there) is over.
header_count() { printf 'change-header~%s~+' "$(waiting $(rows_saved | rows_count))"; }
# waiting <asks> <plans> <questions> <prompts> [<parked>]: the header, "3 asks . 11 plans . 2
# questions waiting . 5 parked", a kind with none left out.
waiting() {
  local n i out="" kinds=(ask plan question prompt) counts=("${1:-0}" "${2:-0}" "${3:-0}" "${4:-0}")
  for i in 0 1 2 3; do
    n="${counts[i]}"
    ((n > 0)) && out+="${out:+ . }$n ${kinds[i]}$( ((n == 1)) || echo s)"
  done
  local hint=""
  [ -n "$QUESTIONS_PARKED" ] && { parked_shown && hint=" (P hides)" || hint=" (P shows)"; }
  echo "${out:-no questions} waiting$( ((${5:-0} > 0)) && echo " . $5 parked$hint")"
}

# prompt_card <target>: the card for a dialog agent-panel cannot read (a permission prompt):
# the session from the state document and the bottom of its pane, where the dialog is drawn.
prompt_card() {
  local t="$1" world local_t
  world="${t%%/*}" local_t="${t#*/}"
  jq -r --arg t "$t" '.sessions[]? | select(.target == $t)
    | "\(.target)  \(.reason)", "topic  \(.topic // "-")", "doing  \(.doing // "-")",
      "said   \(.said // "-")"' "$FLEET_STATE_FILE" 2>/dev/null
  printf '\n'
  tmux -L "$world" capture-pane -p -J -t "$local_t" 2>/dev/null | sed -e 's/[[:space:]]*$//' | awk 'NF { last = NR } { l[NR] = $0 } END { for (i = (last > 30 ? last - 29 : 1); i <= last; i++) print l[i] }'
}
cmd_card() {
  case "${1:-}" in
  @*) agent-panel dialog "${1#@}" 2>/dev/null || prompt_card "${1#@}" ;;
  *) "$QUESTIONS_ASK" card "$@" ;;
  esac
}

# dlg_load <target>: the open dialog's options as its pane numbers them, into D_KEYS, D_FREE
# (1: the option takes typed text) and D_TEXT; false when no dialog agent-panel can read is open.
dlg_load() {
  local k f t
  D_KEYS=() D_FREE=() D_TEXT=()
  while IFS=$'\t' read -r k f t; do D_KEYS+=("$k") D_FREE+=("$f") D_TEXT+=("$t"); done \
    < <(agent-panel dialog "$1" --options 2>/dev/null)
  ((${#D_KEYS[@]} > 0))
}
# dialog_key <k> <target>: a number arms that option (one that takes text opens the answer
# line instead), t opens the line for the option that takes text. The option's text goes in the
# state, so the answer can refuse when the pane no longer shows it.
dialog_key() {
  local k="$1" t="$2" i at=-1
  [ "$k" = d ] && { footer "a dialog is answered, not dropped . g goes there"; return 0; }
  [ "$k" = p ] && { footer "a dialog is answered, not parked . g goes there"; return 0; }
  dlg_load "$t" || { footer "no dialog to answer here . g goes there"; return 0; }
  for i in "${!D_KEYS[@]}"; do
    if [ "$k" = t ]; then [ "${D_FREE[i]}" = 1 ] && { at=$i; break; }
    elif [ "${D_KEYS[i]}" = "$k" ]; then at=$i; break; fi
  done
  if ((at < 0)); then
    if [ "$k" = t ]; then footer "this one takes no typed answer . pick a number"
    else footer "no option $k here . pick one the card shows"; fi
    return 0
  fi
  if [ "${D_FREE[at]}" = 1 ]; then
    st_write typing "${D_KEYS[at]}" "@$t" "${D_TEXT[at]}"
    printf 'show-input+clear-query+change-prompt~answer> ~+change-header~%s~+' "$(tilde "$(fit "answering $t: ${D_TEXT[at]}" | head -4)")"
    footer "enter sends . esc cancels"
  else
    st_write armed "${D_KEYS[at]}" "@$t" "${D_TEXT[at]}"
    footer "send ${D_KEYS[at]} \"${D_TEXT[at]}\" to $t? enter sends . esc cancels"
  fi
}
# dialog_send <k> <@target> <option text> [typed]: press the option in the pane. Whatever came
# of it the list reloads, since the card may be stale.
dialog_send() {
  local k="$1" t="${2#@}" seen="$3" err rc=0
  err="$(agent-panel answer "$t" "$k" --expect "$seen" -- ${4:+"$4"} 2>&1 >/dev/null)" || rc=$?
  case "$rc" in
  0) QUESTIONS_ANSWERED="$t" after "sent $k \"$seen\" to $t" ;;
  3) after "not taken: $t did not move on . g goes there" ;;
  4) after "not sent: ${err:-the dialog changed or closed}" ;;
  *) after "not sent: ${err:-agent-panel answer failed}" ;;
  esac
}

cmd_key() {
  local k="${1:-}" id="${2:-}" q="${3:-}" mode="" opt="" sid="" seen="" busy
  read -r mode opt sid seen <<<"$(st_read)"
  busy="$(busy_read)"
  if [ -n "$busy" ] && [ "$k" != enter ]; then
    case "$k" in focus | fit) ;; *) footer "$busy . wait for it . ctrl-c closes" ;; esac
    return 0
  fi
  case "$k" in
  focus)
    # Moving to another question disarms a choice made on the last one; typing keeps going.
    # With nothing armed the keys are fitted again, to whatever layout ctrl-/ left.
    # A result stays until a key replaces it, so the focus a reload may fire cannot clear it.
    case "$mode" in
    "") footer "$QUESTIONS_KEYS" ;;
    said | typing) ;;
    *) [ "$sid" = "$id" ] || { st_write ""; footer "$QUESTIONS_KEYS"; } ;;
    esac
    ;;
  fit)
    # start and resize: the keys sized to the list column, unless a key's message is up.
    [ -n "$mode" ] || footer "$QUESTIONS_KEYS"
    ;;
  esc)
    case "$mode" in "" | said) printf 'abort'; return 0 ;; esac
    st_write ""
    printf 'hide-input+change-prompt~~+'
    [ "$mode" = typing ] && header_count
    footer "$QUESTIONS_KEYS"
    ;;
  g)
    if [ "$mode" = typing ]; then printf 'put(g)'; return 0; fi
    [ -n "$id" ] || return 0
    # A prompt row names its session already; agent-panel owns the hop.
    if [[ "$id" == @* ]]; then printf 'execute-silent(agent-panel jump %s)+abort' "$(printf '%q' "${id#@}")"; return 0; fi
    # agent-ask resolves the session (its live_row) and reopens an ended one through
    # fleet-dispatch; agent-panel owns the cross-server hop.
    local to
    if to="$("$QUESTIONS_ASK" target --reopen "$id" 2>&1)"; then
      printf 'execute-silent(agent-panel jump %s)+abort' "$(printf '%q' "$to")"
    else footer "${to:-no session to go to}"; fi
    ;;
  P)
    if [ "$mode" = typing ]; then printf 'put(P)'; return 0; fi
    [ -n "$QUESTIONS_PARKED" ] || return 0
    # A choice armed on a row P is about to hide must not ride a later enter; the toggle's
    # result outlasts the reload's focus.
    st_write said
    if parked_shown; then : >"$QUESTIONS_PARKED"; else echo show >"$QUESTIONS_PARKED"; fi
    # P is also the refresh: asks that came or went since the last build show now.
    rows_build
    printf 'reload(%s saved)+' "$(printf '%q' "$SELF")"
    header_count
    if parked_shown; then footer "parked asks shown . P hides them"; else footer "parked asks hidden . P shows them"; fi
    ;;
  [1-9] | d | p | t)
    if [ "$mode" = typing ]; then printf 'put(%s)' "$k"; return 0; fi
    [ -n "$id" ] || return 0
    if [[ "$id" == @* ]]; then dialog_key "$k" "${id#@}"; return 0; fi
    ask_load "$id"
    # A key pressed before the reload after a send lands on the row just answered: refresh.
    if [ "$A_STATUS" != pending ]; then
      after "that question was just ${A_STATUS:-closed}; the list is refreshed"
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
    p)
      if [ -n "$A_PARKED" ]; then
        st_write unpark - "$id"
        footer "put $id back on the list now? enter unparks . esc cancels"
      else
        st_write park - "$id"
        footer "park $id until its revisit date (by its item's priority)? enter parks . esc cancels"
      fi
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
  submit)
    # The panel's enter: say what is being sent, in the footer and the card, at once, and send it
    # in the background (bg-transform), so fzf stays responsive and the busy marker refuses a
    # second enter. Nothing armed, or nothing typed, is enter's own message, sent at once.
    local what=""
    case "$mode" in
    armed)
      if [[ "$sid" == @* ]]; then what="sending $opt \"$seen\" to ${sid#@}"
      else ask_load "$sid"; what="sending \"${A_OPTS[opt - 1]}\" to $A_WHO"; fi
      ;;
    typing) [ -z "$q" ] || what="sending your answer" ;;
    drop) what="dropping $sid" ;;
    park) what="parking $sid" ;;
    unpark) what="unparking $sid" ;;
    esac
    [ -n "$what" ] || { key_enter; return 0; }
    busy_write "$what ..."
    footer "$what ..."
    printf '+preview(cat %q)+bg-transform(%q key enter {1} {q})' "$QUESTIONS_STATE.busy" "$SELF"
    ;;
  enter)
    # The send. From submit the card still says sending, so it is drawn again.
    [ -z "$busy" ] || printf 'refresh-preview+'
    key_enter
    busy_clear
    ;;
  *) panel_die "unknown key: $k" ;;
  esac
}

# key_enter: send the armed choice. It reads cmd_key's mode, opt, sid, seen and q.
key_enter() {
  local err
  case "$mode" in
  armed)
    if [[ "$sid" == @* ]]; then dialog_send "$opt" "$sid" "$seen"; return 0; fi
    ask_load "$sid"
    if err="$("$QUESTIONS_ASK" answer "$sid" "${A_OPTS[opt - 1]}" 2>&1 >/dev/null)"; then
      after "sent \"${A_OPTS[opt - 1]}\" to $A_WHO"
    else st_write ""; footer "not sent: ${err:-agent-ask answer failed}"; fi
    ;;
  typing)
    [ -n "$q" ] || { footer "type an answer first . esc cancels"; return 0; }
    if [[ "$sid" == @* ]]; then dialog_send "$opt" "$sid" "$seen" "$q"; return 0; fi
    if err="$("$QUESTIONS_ASK" answer "$sid" "$q" 2>&1 >/dev/null)"; then after "sent your answer"
    else footer "not sent: ${err:-agent-ask answer failed}"; fi
    ;;
  drop)
    if err="$("$QUESTIONS_ASK" cancel "$sid" dropped by the human 2>&1 >/dev/null)"; then after "dropped $sid"
    else st_write ""; footer "not dropped: ${err:-agent-ask cancel failed}"; fi
    ;;
  park | unpark)
    if err="$("$QUESTIONS_ASK" "$mode" "$sid" 2>&1)"; then after "${err:-${mode}ed $sid}"
    else st_write ""; footer "not ${mode}ed: ${err:-agent-ask $mode failed}"; fi
    ;;
  *) footer "press a number, t, d or p first . $QUESTIONS_KEYS" ;;
  esac
}

cmd_pick() {
  panel_need fzf
  panel_fzf_opts
  panel_fzf_table
  panel_fzf_layout side

  local me k binds=()
  me="$(printf '%q' "$SELF")"
  QUESTIONS_STATE="$(mktemp)"
  QUESTIONS_PARKED="$(mktemp)"
  export QUESTIONS_STATE QUESTIONS_PARKED
  trap 'rm -f "$QUESTIONS_STATE" "$QUESTIONS_STATE.busy" "$QUESTIONS_STATE.rows" "$QUESTIONS_PARKED"' EXIT
  rows_build
  for k in 1 2 3 4 5 6 7 8 9 d p P t g; do binds+=("--bind=$k:transform($me key $k {1} {q})"); done

  # --no-input --disabled: no search box (a handful of rows), which frees the digit keys;
  # t shows the input as the answer line. --no-wrap: a long question ends in .. on its row
  # and reads in full in the card. --read0: a row is two lines (question, then session).
  # The card scrolls on panel_fzf_layout's keys (C-d/C-u, pgup/pgdn), the same in every panel.
  parked_filter <"$QUESTIONS_STATE.rows" |
  fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" "${PANEL_FZF_LAYOUT[@]}" \
    --read0 --no-wrap --no-input --disabled --with-nth=2.. \
    --border-label=' questions ' --border-label-pos=3 \
    --header="$(waiting $(rows_count <"$QUESTIONS_STATE.rows"))" \
    --footer="$QUESTIONS_KEYS" \
    --preview="AGENT_ASK_COLOR=1 COLUMNS=\$FZF_PREVIEW_COLUMNS $me card {1}" \
    "${binds[@]}" \
    --bind="enter:transform($me key submit {1} {q})" \
    --bind="esc:transform($me key esc {1})" \
    --bind="focus:transform($me key focus {1})" \
    --bind="start,resize:transform($me key fit)" >/dev/null
  return 0
}

# The test seam: sourced by the bats tests, stop before dispatch.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

case "${1:-}" in
rows) rows_build; rows_saved | parked_filter ;;
saved) rows_saved | parked_filter ;;
count) cmd_count ;;
key) shift; cmd_key "$@" ;;
card) shift; cmd_card "$@" ;;
'') cmd_pick ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: $1 (try --help)" ;;
esac
