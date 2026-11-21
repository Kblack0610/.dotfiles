#!/usr/bin/env bats
# PIPELINES.md (private overlay, ~/.config/agentctl/) is the one list of what runs outside
# agentctl's confs: tracked systemd timers and path units, and model calls that skip
# agentctl-run. Nothing made it change when one was added, so both directions are checked
# here, from the files as text. The confs themselves are checked by `agentctl list --md`.
# Skipped where the private overlay is absent (public CI); it runs in the Stop fast tier.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PRIV="${PIPELINES_PRIVATE_REPO:-${ACCOUNT_HOME:-/nonexistent}/.dotfiles-private}"
  DOC="$PRIV/.config/agentctl/PIPELINES.md"
  [ -f "$DOC" ] || skip "no private overlay at $PRIV"
}

# Tracked timers and path units in both repos, by unit name. timers.target.wants/ holds links.
tracked_units() {
  for r in "$PUB" "$PRIV"; do
    git -C "$r" ls-files '.config/systemd/user/*.timer' '.config/systemd/user/*.path'
  done | grep -v '/timers.target.wants/' | xargs -n1 basename | sort -u
}

# Units the doc names, as `name.timer` or `name.path` in a table's first column.
doc_units() {
  grep -oE '^\| `[a-z0-9@.-]+\.(timer|path)`' "$DOC" | grep -oE '[a-z0-9@.-]+\.(timer|path)' | sort -u
}

@test "every tracked timer and path unit has a row in PIPELINES.md" {
  run comm -23 <(tracked_units) <(doc_units)
  assert_success
  assert_output ''
}

@test "every unit PIPELINES.md lists is still tracked" {
  run comm -13 <(tracked_units) <(doc_units)
  assert_success
  assert_output ''
}

# Out-of-band model call sites, through the one scan and allowlist `fleet-bench ledger --check`
# holds CI to (launches_unlisted), over both repos.
@test "every model call outside agentctl-run has a row, and every row is still one" {
  local d=() r
  for r in "$PUB" "$PRIV"; do d+=("$r/.local" "$r/.claude" "$r/.config"); done
  LEDGER_PIPELINES="$DOC" LEDGER_SRC="$(IFS=:; echo "${d[*]}")" run "$PUB/.local/bin/fleet-bench" ledger --unlisted
  assert_success
  assert_output ''
}

@test "the confs are all valid, so the catalog (agentctl list --md) has every runner" {
  [ -d "$PRIV/.config/agentctl/agents" ] || skip "no confs"
  local h; h=$(mktemp -d)
  mkdir -p "$h/.config/agentctl"
  ln -s "$PRIV/.config/agentctl/agents" "$h/.config/agentctl/agents"
  HOME="$h" AGENTCTL_STATE_DIR="$h/state" run "$PUB/.local/bin/agentctl" list --md
  rm -rf "$h"
  assert_success
  refute_output --partial 'Invalid'
  # The exact columns are integ/agentctl_list.bats's to pin; here the first line is the header.
  assert_line --index 0 --regexp '^\| Runner \| .* \| Purpose \|$'
}

# How they chain (the Delivery chain row of ARCHITECTURE.md Flows): each runner the section tags
# `name` (Opus|Sonnet|Haiku|no model[, acts|draft|none]) has a conf whose MODEL and EFFECT say the same.
@test "every runner the delivery chain tags with a model has a conf with that model and effect" {
  local tags name model effect conf ce bad=''
  tags=$(awk '/^## How they chain/{f=1; next} /^## /{f=0} f' "$DOC" |
    grep -oE '`[a-z0-9-]+` \((Opus|Sonnet|Haiku|no model)(, (acts|draft|none)\b)?' | sort -u)
  [ -n "$tags" ]
  while IFS= read -r t; do
    name=$(sed -E 's/^`([^`]+)`.*/\1/' <<<"$t")
    model=$(sed -E 's/.*\(([A-Za-z ]+).*/\1/' <<<"$t")
    effect=$(grep -oE ', [a-z]+$' <<<"$t" | sed 's/, //' || true)
    conf="$PRIV/.config/agentctl/agents/$name.conf"
    [ -f "$conf" ] || { bad+="$name: no conf"$'\n'; continue; }
    if [ "$model" = "no model" ]; then
      ! grep -qE '^MODEL=' "$conf" || bad+="$name: doc says no model, conf sets MODEL"$'\n'
    else
      grep -qiE "^MODEL=[\"']?claude-${model,,}" "$conf" || bad+="$name: doc says $model, conf $(grep -E '^MODEL=' "$conf")"$'\n'
    fi
    # No EFFECT line reads as none, agentctl's default.
    if [ -n "$effect" ]; then
      ce=$(sed -nE "s/^EFFECT=[\"']?([a-z]+).*/\1/p" "$conf" | tail -n 1)
      [ "${ce:-none}" = "$effect" ] || bad+="$name: doc says $effect, conf EFFECT=${ce:-(unset)}"$'\n'
    fi
  done <<<"$tags"
  [ -z "$bad" ] || { printf '%s' "$bad"; return 1; }
}
