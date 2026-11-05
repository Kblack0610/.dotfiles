#!/usr/bin/env bats
# Tier 3: the prefix R window through real fzf on a real tmux server. The list gets the
# whole width, so a title reads in full at a normal client and wraps at a narrow one.
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
  mkdir -p "$HOME/.agent/sessions"
  printf '%s\t' aaaaaaaa-1 dotfiles - 200 /w main "$TITLE" "$TITLE" first last f.sh - \
    | sed 's/\t$/\n/' > "$HOME/.agent/sessions/index.tsv"
}

teardown() { ui_teardown; }

@test "at a normal width a title reads whole on one row, with no preview pane" {
  TM_WIDTH=130 TM_HEIGHT=20 tmux_start "$REPO_ROOT/.local/bin/sessions" search
  wait_until 'screen_has "$TITLE"'
  screen_has 'enter resume | ctrl-g full-text'
  screen_lacks '? preview'
  screen_lacks '│'
}

@test "at a narrow width the title wraps instead of being cut" {
  TM_WIDTH=70 TM_HEIGHT=20 tmux_start "$REPO_ROOT/.local/bin/sessions" search
  wait_until 'screen_has "Waybar"'
  screen_has 'wrapped'
}
