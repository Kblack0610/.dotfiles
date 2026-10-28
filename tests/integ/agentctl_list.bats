#!/usr/bin/env bats
# `agentctl list` must print every configured runner, whatever systemd prints.
#
# unit_next_run piped `systemctl list-timers` into an awk that exited on its first match.
# Once list-timers output outgrew the pipe buffer, systemctl took SIGPIPE, pipefail failed
# the pipeline, and set -e killed `list` after the first row - silently, rc 141.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  mkdir -p "$HOME/.config/agentctl/agents"
  for n in alpha beta; do
    printf 'NAME=%s\nKIND=oneshot\nLANE=observe\nDESCRIPTION=\047purpose of %s\047\nCOMMAND=true\nSCHEDULE=daily\n' "$n" "$n" \
      > "$HOME/.config/agentctl/agents/$n.conf"
  done
  # The matches come first, then far more than a pipe buffer of other timers.
  {
    echo 'Fri 2026-10-23 01:00:00 PDT 5h - - agentctl-alpha.timer agentctl@alpha.service'
    echo 'Fri 2026-10-23 02:00:00 PDT 6h - - agentctl-beta.timer agentctl@beta.service'
    for i in $(seq 1 4000); do
      echo "Fri 2026-10-23 03:00:00 PDT 7h - - filler-$i-padding-padding-padding.timer filler-$i.service"
    done
  } > "$NOTES_FIXTURE/systemctl.list-timers"
}

@test "list survives a large list-timers output and shows every runner with its next run" {
  run "$AGENTCTL_BIN" list
  assert_success
  assert_line --regexp '^  alpha +idle +- +Fri 01:00:00 +purpose of alpha$'
  assert_line --regexp '^  beta +idle +- +Fri 02:00:00 +purpose of beta$'
}

@test "list groups runners under their lane, in lane order, with the last verdict" {
  sed -i 's/^LANE=observe/LANE=deliver/' "$HOME/.config/agentctl/agents/beta.conf"
  mkdir -p "$AGENTCTL_STATE_DIR/alpha"
  printf WORKED > "$AGENTCTL_STATE_DIR/alpha/last-outcome"
  run "$AGENTCTL_BIN" list
  assert_success
  assert_line --index 1 'deliver'
  assert_line --index 2 --regexp '^  beta '
  assert_line --index 3 'observe'
  assert_line --index 4 --regexp '^  alpha +idle +WORKED [0-9]+s +Fri 01:00:00 '
  refute_line 'learn'
}

@test "a conf with no LANE, or one outside the four, is listed as invalid with the reason (negative control)" {
  sed -i '/^LANE=/d' "$HOME/.config/agentctl/agents/alpha.conf"
  sed -i 's/^LANE=observe/LANE=misc/' "$HOME/.config/agentctl/agents/beta.conf"
  run "$AGENTCTL_BIN" list
  assert_success
  assert_line 'invalid (reload skips these)'
  assert_line --regexp '^  alpha +.*missing LANE'
  assert_line --regexp '^  beta +invalid LANE=misc'
}

@test "a conf with no DESCRIPTION is invalid (negative control)" {
  sed -i '/^DESCRIPTION=/d' "$HOME/.config/agentctl/agents/alpha.conf"
  run "$AGENTCTL_BIN" list
  assert_line --regexp '^  alpha +.*missing DESCRIPTION'
}
