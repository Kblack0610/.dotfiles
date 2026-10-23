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
    printf 'NAME=%s\nKIND=oneshot\nCOMMAND=true\nSCHEDULE=daily\n' "$n" \
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
  assert_line --regexp '^alpha +oneshot .* Fri 01:00:00$'
  assert_line --regexp '^beta +oneshot .* Fri 02:00:00$'
}
