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
    printf 'NAME=%s\nKIND=oneshot\nLANE=observe\nDESCRIPTION=\047purpose of %s\047\nEFFECT=none\nCOMMAND=true\nSCHEDULE=daily\n' "$n" "$n" \
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

@test "a KIND=call agent is listed as call and needs no COMMAND; its caller starts it, never agentctl" {
  printf 'NAME=judge\nKIND=call\nLANE=observe\nROLE=observe\nDESCRIPTION=\047a judge\047\nEFFECT=shadow\n' \
    > "$HOME/.config/agentctl/agents/judge.conf"
  run "$AGENTCTL_BIN" list
  assert_success
  assert_line --regexp '^  judge +call +- +- +a judge$'
  run "$AGENTCTL_BIN" start judge
  assert_failure
  assert_output --partial 'agentctl-run --agent judge'
}

@test "a KIND=call agent with a SCHEDULE or no ROLE is invalid (negative control)" {
  printf 'NAME=judge\nKIND=call\nLANE=observe\nROLE=observe\nSCHEDULE=daily\nDESCRIPTION=x\n' \
    > "$HOME/.config/agentctl/agents/judge.conf"
  printf 'NAME=judge2\nKIND=call\nLANE=observe\nDESCRIPTION=x\n' > "$HOME/.config/agentctl/agents/judge2.conf"
  run "$AGENTCTL_BIN" list
  assert_line --partial 'no SCHEDULE or AUTOSTART'
  assert_line --partial 'missing ROLE'
  refute_line --regexp '^  judge2? +call'
}

@test "a conf with no EFFECT, or one outside the four, is invalid (negative control)" {
  sed -i '/^EFFECT=/d' "$HOME/.config/agentctl/agents/alpha.conf"
  sed -i 's/^EFFECT=none/EFFECT=maybe/' "$HOME/.config/agentctl/agents/beta.conf"
  run "$AGENTCTL_BIN" list
  assert_success
  assert_line --regexp '^  alpha +.*missing EFFECT'
  assert_line --regexp '^  beta +invalid EFFECT=maybe'
}

@test "list --md is the catalog: one row per runner from the confs, model shown only when a model runs" {
  printf 'NAME=judge\nKIND=call\nLANE=deliver\nROLE=distill\nMODEL=m1\nDESCRIPTION=\047a | judge\047\nEFFECT=shadow\n' \
    > "$HOME/.config/agentctl/agents/judge.conf"
  printf 'NAME=writer\nKIND=oneshot\nLANE=learn\nROLE=curate\nCOMMAND=true\nSCHEDULE=daily\nENABLED=no\nDESCRIPTION=w\nEFFECT=acts\n' \
    > "$HOME/.config/agentctl/agents/writer.conf"
  run "$AGENTCTL_BIN" list --md
  assert_success
  assert_line --index 0 '| Runner | Lane | Trigger | Role | Model | Effect | Purpose |'
  assert_line --index 2 '| judge | deliver | called by its caller | distill | m1 | shadow | a \| judge |'
  assert_line '| alpha | observe | `daily` | - | - | none | purpose of alpha |'
  assert_line '| writer | learn | `daily` (disabled) | curate | not in conf | acts | w |'
}
