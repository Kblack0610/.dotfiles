#!/usr/bin/env bats
# Tier 3: `agent-panel send`, the one way anything types into a Claude pane, against a real tmux
# pane running a reader that behaves like Claude Code's input box: bracketed paste on, and an
# Enter that lands within READER_DEAF_MS of a paste is dropped, leaving the text in the box.
# 2026-11-05: answers from the questions panel sat unsent in the session because agent-ask
# pasted and pressed Enter at once. Container only; needs the agent-panel binary (CI builds it).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_shim
  BIN="$REPO_ROOT/.local/src/agent-panel/target/debug/agent-panel"
  if [ ! -x "$BIN" ]; then
    [ -n "${CI:-}" ] && { echo "agent-panel is not built at $BIN" >&2; return 1; }
    skip "build agent-panel first (cargo build in .local/src/agent-panel)"
  fi
  LOG="$SANDBOX/submitted.log"
  READER="$SANDBOX/reader.sh"
  # The reader draws its input box as `> <text>` and appends each submitted line to $LOG.
  cat > "$READER" <<'SH'
#!/usr/bin/env bash
log="$1" deaf_us=$(( ${READER_DEAF_MS:-300} * 1000 ))
stty -icanon -echo
printf '\e[?2004h'
buf="" pasting=0 pasted_at=0 seq=""
draw() { printf '\r\e[K> %s' "$buf"; }
now_us() { local t="${EPOCHREALTIME/./}"; printf '%s' "$t"; }
draw
while IFS= read -r -s -n1 -d '' c; do
  if [ -n "$seq" ] || [ "$c" = $'\e' ]; then
    seq+="$c"
    case "$seq" in
      $'\e[200~') pasting=1; seq="" ;;
      $'\e[201~') pasting=0; pasted_at="$(now_us)"; seq=""; draw ;;
      $'\e'|$'\e['|$'\e[2'|$'\e[20'|$'\e[200'|$'\e[201') ;;
      *) seq="" ;;
    esac
    continue
  fi
  if [ "$pasting" = 1 ]; then buf+="$c"; continue; fi
  case "$c" in
    $'\r'|$'\n')
      [ $(( $(now_us) - pasted_at )) -lt "$deaf_us" ] && continue
      printf '%s\n' "$buf" >> "$log"; buf=""; printf '\r\e[Ksent\n'; draw ;;
    *) buf+="$c"; draw ;;
  esac
done
SH
  chmod +x "$READER"
  tmux_start "$READER" "$LOG"
  PANE="x/$TM_TARGET"
  wait_until 'screen_has ">"'
}

teardown() { ui_teardown; }

@test "send waits for the paste to be drawn, so the Enter is taken and the box is empty" {
  run "$BIN" send --pane "$PANE" 'Answer to ask AbC123: yes'
  assert_success
  wait_until '[ -s "$LOG" ]'
  run cat "$LOG"
  assert_output 'Answer to ask AbC123: yes'
  wait_until 'screen | tail -1 | grep -qx "> *"'
}

@test "negative control: paste then an immediate Enter leaves the text unsent in the box" {
  printf 'Answer to ask AbC123: yes' | _tm load-buffer -b t -
  _tm paste-buffer -p -d -b t -t "$TM_TARGET"
  _tm send-keys -t "$TM_TARGET" Enter
  wait_until 'screen_has "> Answer to ask AbC123: yes"'
  [ ! -s "$LOG" ]
}

@test "a pane that never takes the Enter is reported, not passed as sent" {
  tmux_stop
  READER_DEAF_MS=600000 tmux_start env READER_DEAF_MS=600000 "$READER" "$LOG"
  PANE="x/$TM_TARGET"
  wait_until 'screen_has ">"'
  run "$BIN" send --pane "$PANE" 'never'
  assert_failure 3
  assert_output --partial 'did not take the Enter'
  [ ! -s "$LOG" ]
}

@test "--no-submit types only" {
  run "$BIN" send --pane "$PANE" --no-submit 'draft'
  assert_success
  wait_until 'screen_has "> draft"'
  [ ! -s "$LOG" ]
}
