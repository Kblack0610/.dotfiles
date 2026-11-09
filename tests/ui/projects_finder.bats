#!/usr/bin/env bats
# Tier 3: Prefix+p through real fzf on a real tmux server, at the size the popup opens at on the
# usual client, in the side layout. Container only, like every ui test.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_shim

  # The widest row the live list can make: the longest name, a stage, three-digit open and
  # two-digit urgent counts.
  printf '%s\n' \
    $'bnb\tkenneth-black-portfolio\talpha\tv1.0.0\t123\t11\t0\t0\t0\t0\t/v/a/README.md' \
    $'bnb\tdodginballs\talpha\tv1.0.0\t51\t7\t0\t0\t0\t0\t/v/b/README.md' \
    $'bnb\ttrader\tprod\tv1.0.0\t18\t0\t0\t0\t0\t0\t/v/c/README.md' \
    >"$NOTES_FIXTURE/stats"
  printf '#!/bin/sh\necho PROJECT-CARD\n' >"$SANDBOX/bin/hub"
  chmod +x "$SANDBOX/bin/hub"
}

teardown() { ui_teardown; }

@test "at 144 columns the widest row is one line with its urgent count whole, and every key shows" {
  TM_WIDTH=144 TM_HEIGHT=31 tmux_start "$REPO_ROOT/.local/src/tmux/projects.sh"
  wait_until 'screen_has "PROJECT-CARD"'
  screen_has '123 open  !11'
  screen_lacks '↳'
  screen_has 'g repo'
  screen_has 'c claude'
  screen_has 'd drafts'
  screen_has 'q quit  !N urgent'
}
