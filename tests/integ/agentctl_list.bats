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
  printf 'NAME=judge\nKIND=call\nLANE=observe\nROLE=observe\nPRIORITY=low\nDESCRIPTION=\047a judge\047\nEFFECT=shadow\n' \
    > "$HOME/.config/agentctl/agents/judge.conf"
  run "$AGENTCTL_BIN" list
  assert_success
  assert_line --regexp '^  judge +call +- +- +a judge$'
  run "$AGENTCTL_BIN" start judge
  assert_failure
  assert_output --partial 'agentctl-run --agent judge'
}

@test "a conf with a ROLE and no PRIORITY, or one outside must|low|off, is invalid; a conf with no ROLE needs none" {
  printf 'NAME=judge\nKIND=call\nLANE=observe\nROLE=observe\nDESCRIPTION=j\nEFFECT=shadow\n' \
    > "$HOME/.config/agentctl/agents/judge.conf"
  run "$AGENTCTL_BIN" list
  assert_line --regexp '^  judge +.*invalid PRIORITY= on a conf with a ROLE'
  printf 'PRIORITY=high\n' >> "$HOME/.config/agentctl/agents/judge.conf"
  run "$AGENTCTL_BIN" list
  assert_line --regexp '^  judge +.*invalid PRIORITY=high'
  sed -i 's/^PRIORITY=high$/PRIORITY=must/' "$HOME/.config/agentctl/agents/judge.conf"
  run "$AGENTCTL_BIN" list
  assert_success
  assert_line --regexp '^  judge +call +- +- +j$'
}

@test "a KIND=call agent with a SCHEDULE or no ROLE is invalid (negative control)" {
  printf 'NAME=judge\nKIND=call\nLANE=observe\nROLE=observe\nPRIORITY=low\nSCHEDULE=daily\nDESCRIPTION=x\n' \
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
  printf 'NAME=judge\nKIND=call\nLANE=deliver\nROLE=distill\nPRIORITY=low\nMODEL=m1\nDESCRIPTION=\047a | judge\047\nEFFECT=shadow\n' \
    > "$HOME/.config/agentctl/agents/judge.conf"
  printf 'NAME=writer\nKIND=oneshot\nLANE=learn\nROLE=curate\nPRIORITY=low\nCOMMAND=true\nSCHEDULE=daily\nENABLED=no\nDESCRIPTION=w\nEFFECT=acts\n' \
    > "$HOME/.config/agentctl/agents/writer.conf"
  run "$AGENTCTL_BIN" list --md
  assert_success
  assert_line --index 0 '| Runner | Lane | Trigger | Role | Priority | Skill | Model | Effect | Purpose |'
  assert_line --index 2 '| judge | deliver | called by its caller | distill | low | - | m1 | shadow | a \| judge |'
  assert_line '| alpha | observe | `daily` | - | - | - | - | none | purpose of alpha |'
  assert_line '| writer | learn | `daily` (disabled) | curate | low | - | not in conf | acts | w |'
}

# SKILL names the skill or command that owns a runner's job. The roots are fixtures, so the
# test needs neither the host's skills nor a private one.
skill_fixture() {
  export AGENTCTL_SKILLS_DIR="$BATS_TEST_TMPDIR/skills" AGENTCTL_COMMANDS_DIR="$BATS_TEST_TMPDIR/commands"
  mkdir -p "$AGENTCTL_SKILLS_DIR/dream" "$AGENTCTL_COMMANDS_DIR/my"
  : > "$AGENTCTL_SKILLS_DIR/dream/SKILL.md"
  : > "$AGENTCTL_COMMANDS_DIR/my/autopilot.md"
  : > "$AGENTCTL_COMMANDS_DIR/remember.md"
}

@test "SKILL resolving to a skill dir, a command or a namespaced command shows in the Skill column" {
  skill_fixture
  sed -i '/^NAME=/a SKILL=dream' "$HOME/.config/agentctl/agents/alpha.conf"
  sed -i '/^NAME=/a SKILL=my:autopilot' "$HOME/.config/agentctl/agents/beta.conf"
  printf 'NAME=gamma\nKIND=oneshot\nLANE=learn\nCOMMAND=true\nDESCRIPTION=g\nEFFECT=none\nSKILL=remember\n' \
    > "$HOME/.config/agentctl/agents/gamma.conf"
  run "$AGENTCTL_BIN" list --md
  assert_success
  assert_line '| alpha | observe | `daily` | - | - | dream | - | none | purpose of alpha |'
  assert_line '| beta | observe | `daily` | - | - | my:autopilot | - | none | purpose of beta |'
  assert_line --regexp '^\| gamma \| learn .* \| remember \|'
  refute_output --partial 'Invalid'
}

@test "a SKILL that resolves to nothing is flagged, and the runner stays valid (negative control)" {
  skill_fixture
  sed -i '/^NAME=/a SKILL=no-such-skill' "$HOME/.config/agentctl/agents/alpha.conf"
  run "$AGENTCTL_BIN" list
  assert_success
  assert_line 'skill not found (the runner still runs)'
  assert_line --regexp '^  alpha +SKILL=no-such-skill$'
  refute_line 'invalid (reload skips these)'
  run "$AGENTCTL_BIN" list --md
  assert_success
  assert_line '| alpha | observe | `daily` | - | - | no-such-skill (not found) | - | none | purpose of alpha |'
  refute_output --partial 'Invalid'
}

@test "a SKILL that is a path, a doubled colon or an empty directory is not found, a blank or unset SKILL is not flagged" {
  skill_fixture
  mkdir -p "$AGENTCTL_SKILLS_DIR/hollow"
  sed -i '/^NAME=/a SKILL=../skills/dream' "$HOME/.config/agentctl/agents/alpha.conf"
  sed -i '/^NAME=/a SKILL=my::autopilot' "$HOME/.config/agentctl/agents/beta.conf"
  printf 'NAME=gamma\nKIND=oneshot\nLANE=learn\nCOMMAND=true\nDESCRIPTION=g\nEFFECT=none\nSKILL=hollow\n' \
    > "$HOME/.config/agentctl/agents/gamma.conf"
  printf 'NAME=delta\nKIND=oneshot\nLANE=learn\nCOMMAND=true\nDESCRIPTION=d\nEFFECT=none\nSKILL=\n' \
    > "$HOME/.config/agentctl/agents/delta.conf"
  run "$AGENTCTL_BIN" list
  assert_success
  assert_line --regexp '^  alpha +SKILL=\.\./skills/dream$'
  assert_line --regexp '^  beta +SKILL=my::autopilot$'
  assert_line --regexp '^  gamma +SKILL=hollow$'
  refute_line --regexp '^  delta +SKILL='
}

@test "a SKILL in the caller's environment is not inherited by a conf that sets none" {
  skill_fixture
  SKILL=dream run "$AGENTCTL_BIN" list --md
  assert_success
  assert_line '| alpha | observe | `daily` | - | - | - | - | none | purpose of alpha |'
}

@test "an AUTOSTART or MODEL in the caller's environment is not inherited by a conf that sets none" {
  printf 'NAME=caller\nKIND=call\nLANE=learn\nROLE=judge\nPRIORITY=low\nDESCRIPTION=c\nEFFECT=none\n' > "$HOME/.config/agentctl/agents/caller.conf"
  AUTOSTART=yes SCHEDULE=daily MODEL=leaked run "$AGENTCTL_BIN" list --md
  assert_success
  refute_output --partial 'invalid conf'
  refute_output --partial 'KIND=call is started by its caller'
  refute_output --partial 'leaked'
}

@test "agentctl skill prints the conf's SKILL, and --dangling lists the ones that resolve to nothing" {
  skill_fixture
  sed -i '/^NAME=/a SKILL=dream' "$HOME/.config/agentctl/agents/alpha.conf"
  run "$AGENTCTL_BIN" skill alpha
  assert_success
  assert_output dream
  run "$AGENTCTL_BIN" skill beta
  assert_success
  assert_output ''
  run "$AGENTCTL_BIN" skill --dangling
  assert_success
  assert_output ''
  sed -i 's/^SKILL=.*/SKILL=no-such-skill/' "$HOME/.config/agentctl/agents/alpha.conf"
  run "$AGENTCTL_BIN" skill --dangling
  assert_failure
  assert_output 'alpha SKILL=no-such-skill'
  run "$AGENTCTL_BIN" skill no-such-agent
  assert_failure
}

@test "AGENTCTL_CONF_DIR points agentctl at another conf dir" {
  mkdir -p "$BATS_TEST_TMPDIR/other"
  printf 'NAME=zed\nKIND=oneshot\nLANE=learn\nCOMMAND=true\nDESCRIPTION=z\nEFFECT=none\n' > "$BATS_TEST_TMPDIR/other/zed.conf"
  AGENTCTL_CONF_DIR="$BATS_TEST_TMPDIR/other" run "$AGENTCTL_BIN" list --md
  assert_success
  assert_line --regexp '^\| zed \|'
  refute_output --partial '| alpha |'
}

@test "list --json gives each runner its priority, route and source, and an invalid conf only its name" {
  printf 'PRIORITY=must\nHARNESS=codex\nMODEL=gpt-x\n' >> "$HOME/.config/agentctl/agents/alpha.conf"
  printf 'PRIORITY=low\nSOURCE=codex-core\n' >> "$HOME/.config/agentctl/agents/beta.conf"
  printf 'NAME=gamma\nKIND=oneshot\n' > "$HOME/.config/agentctl/agents/gamma.conf"
  run "$AGENTCTL_BIN" list --json
  assert_success
  run jq -c '.[] | [.name, .priority, .harness, .route, .source, .route_transport, .invalid]' <<< "$output"
  assert_line '["alpha","must","codex","chatgpt","codex","openai-native",null]'
  assert_line '["beta","low","claude","subscription","codex-core","anthropic-native",null]'
  assert_line '["gamma",null,null,null,null,null,true]'
}

@test "list --json takes a role's model and route pins as agentctl-run does, and names a role that does not load" {
  mkdir -p "$HOME/.config/agentctl/roles"
  printf 'ROLE_WRITE=no\nROLE_TASK=no\nROLE_BASH=no\nROLE_MCP=""\nROLE_MCP_DENY=""\nROLE_APPROVE=""\nROLE_MODEL="pinned-model"\nROLE_ROUTE=role-route\n' \
    > "$HOME/.config/agentctl/roles/pinned.role"
  printf 'ROLE=pinned\nMODEL=conf-model\nPRIORITY=must\n' >> "$HOME/.config/agentctl/agents/alpha.conf"
  # A conf's own ROUTE still beats the role's default route; the role's model pin beats the conf's.
  printf 'ROLE=pinned\nROUTE=conf-route\nPRIORITY=low\n' >> "$HOME/.config/agentctl/agents/beta.conf"
  printf 'NAME=gamma\nKIND=oneshot\nLANE=observe\nDESCRIPTION=g\nEFFECT=none\nCOMMAND=true\nSCHEDULE=daily\nROLE=broken\nMODEL=conf-model\nPRIORITY=low\n' \
    > "$HOME/.config/agentctl/agents/gamma.conf"
  printf 'ROLE_WRITE=no\nROLE_MODEL=never-used\n' > "$HOME/.config/agentctl/roles/broken.role"
  run "$AGENTCTL_BIN" list --json
  assert_success
  run jq -c '.[] | [.name, .model, .route, (.role_error != null)]' <<< "$output"
  assert_line '["alpha","pinned-model","role-route",false]'
  assert_line '["beta","pinned-model","conf-route",false]'
  # negative control: a role that does not load pins nothing, and says why
  assert_line '["gamma","conf-model","subscription",true]'
}
