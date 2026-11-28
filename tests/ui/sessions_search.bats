#!/usr/bin/env bats
# Tier 3: the prefix R window through real fzf on a real tmux server. The list gets the
# whole width, so a title reads in full at a normal client and wraps at a narrow one; the
# session card sits below it, and ctrl-t opens the highlighted session's prompts.
# Container only, like every ui test.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_shim

  export CLAUDE_RECALL="$SANDBOX/bin/claude-recall"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CLAUDE_RECALL"; chmod +x "$CLAUDE_RECALL"
  TITLE='Waybar right-side overflow and agent chips across both monitors, wrapped'
  T="$HOME/.claude/projects/-w/aaaaaaaa-1.jsonl"
  mkdir -p "$HOME/.agent/sessions/dotfiles" "$(dirname "$T")"
  printf '%s\t' aaaaaaaa-1 dotfiles - 200 /w main "$TITLE" "$TITLE" first last f.sh - hand \
    | sed 's/\t$/\n/' > "$HOME/.agent/sessions/index.tsv"
  printf '%s\n' '{"type":"user","timestamp":"2026-11-20T09:12:00.000Z","message":{"role":"user","content":"move the agent chips left"}}' > "$T"
  jq -nc --arg t "$T" '{session_id:"aaaaaaaa-1", transcript:$t, project:"dotfiles", edits:3, updated:1}' \
    > "$HOME/.agent/sessions/dotfiles/sessions.jsonl"
}

teardown() { ui_teardown; }

@test "at a normal width a title reads whole on one row, with the session card below" {
  TM_WIDTH=130 TM_HEIGHT=24 tmux_start "$REPO_ROOT/.local/bin/sessions" search
  wait_until 'screen_has "$TITLE"'
  screen_has 'enter resume | ctrl-t prompts | ctrl-g full-text | --all shows dispatched'
  wait_until 'screen_has "EDITS 3"'
  screen_lacks '│'
}

@test "ctrl-t lists the highlighted session's prompts" {
  TM_WIDTH=130 TM_HEIGHT=24 tmux_start "$REPO_ROOT/.local/bin/sessions" search
  wait_until 'screen_has "$TITLE"'
  tmux_keys C-t
  wait_until 'screen_has "move the agent chips left"'
  screen_has 'enter jump to it in the pane | ctrl-r read from here | esc back'
}

@test "typing in the prompts window matches each word as a substring, not scattered letters" {
  # "hug my agent now, she then exits" holds every letter of "human sheet" in order, so
  # fzf's fuzzy match keeps it; matching each word as a substring drops it. The capital and
  # the reversed order hold the hit only when words match case-insensitively in any order.
  printf '%s\n' '{"type":"user","timestamp":"2026-11-20T09:13:00.000Z","message":{"role":"user","content":"put this on the human sheet"}}' \
    '{"type":"user","timestamp":"2026-11-20T09:14:00.000Z","message":{"role":"user","content":"hug my agent now, she then exits"}}' >> "$T"
  TM_WIDTH=130 TM_HEIGHT=24 tmux_start "$REPO_ROOT/.local/bin/sessions" search
  wait_until 'screen_has "$TITLE"'
  tmux_keys C-t
  wait_until 'screen_has "hug my agent now"'
  tmux_type 'Sheet human'
  wait_until 'screen_lacks "hug my agent now"'
  wait_until 'screen_has "put this on the human sheet"'
  screen_lacks 'move the agent chips left'
}

@test "at a narrow width the title wraps instead of being cut" {
  TM_WIDTH=70 TM_HEIGHT=20 tmux_start "$REPO_ROOT/.local/bin/sessions" search
  wait_until 'screen_has "Waybar"'
  screen_has 'wrapped'
}
