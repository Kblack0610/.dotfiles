#!/usr/bin/env bats
# QUEUE.md (private overlay, ~/.config/agentctl/) defines five rows of ARCHITECTURE.md's Flows
# table: Work intake, Queue states, Admission, Dispatch and the Fleet lease. Each test here reads
# one section's enumerable facts (a state, a source, a verb, a default, a lane) and the code that
# implements it, from the files as text, so the section cannot drift from agent-queue,
# fleet-dispatch or fleet-lease unseen. Change the code and its section together.
# Skipped where the private overlay is absent (public CI); it runs in the Stop fast tier.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PRIV="${QUEUE_DOC_PRIVATE_REPO:-${ACCOUNT_HOME:-/nonexistent}/.dotfiles-private}"
  DOC="$PRIV/.config/agentctl/QUEUE.md"
  [ -f "$DOC" ] || skip "no private overlay at $PRIV"
  AQ="$PUB/.local/bin/agent-queue"
  FD="$PUB/.local/bin/fleet-dispatch"
  FL="$PUB/.local/bin/fleet-lease"
}

# section <heading>: the body of `## <heading>` up to the next level-2 heading.
section() {
  awk -v h="## $1" '$0 == h {f=1; next} f && /^## / {exit} f' "$DOC"
}

# default_of <file> <var>: N from `VAR="${ENV:-N}"` or `: "${VAR:=N}"`.
default_of() {
  sed -nE "s/^$2=\"\\\$\{[A-Z_]+:-([0-9]+)\}\".*/\1/p; s/^: \"\\\$\{$2:=([0-9]+)\}\".*/\1/p" "$1" | head -n 1
}

# The States table's first column, as bare names (`done/<date>/` is done).
doc_states() {
  section States | grep -oE '^\| `[a-z]+/' | sed 's/^| `//; s#/$##' | sort
}

@test "Queue states: the States table is agent-queue's live states plus done" {
  local active
  active=$(sed -nE 's/^ACTIVE="([a-z ]+)"$/\1/p' "$AQ")
  [ -n "$active" ]
  run diff <(doc_states) <(printf '%s\n' $active done | sort)
  assert_success
}

@test "Work intake: the flow diagram walks the same queue states as the States table" {
  local line
  line=$(section 'The flow: inbox to ledger' | grep -m1 'queue item:')
  [ -n "$line" ]
  run diff <(sed -E 's/.*queue item: //; s/ \([^)]*\)//g; s#/<date>/##; s/ (->|or) /\n/g' <<<"$line" | sort) <(doc_states)
  assert_success
}

@test "Admission: every add source the cap never holds is named in the section" {
  local srcs s body
  srcs=$(sed -nE 's/^ *case "\$from" in ([a-z: |]+)\) capped=.*/\1/p' "$AQ" | tr -d ' ' | tr '|' '\n')
  [ -n "$srcs" ]
  body=$(section Admission)
  for s in $srcs; do
    grep -qF "\`$s\`" <<<"$body" || { echo "not in QUEUE.md Admission: \`$s\`"; return 1; }
  done
}

@test "Admission: the AGENT_QUEUE_PULL values the section names are the ones fleet-dispatch sets" {
  local code
  code=$({
    grep -oE 'AGENT_QUEUE_PULL="?\$?\{?(PULL:-)?[a-z]+' "$FD" | grep -oE '[a-z]+$'
    sed -nE 's/^start_pull\(\) \{.*&& echo ([a-z]+) \|\| echo ([a-z]+);.*/\1\n\2/p' "$FD"
  } | sort -u)
  [ -n "$code" ]
  run diff <(section Admission | grep -oE 'AGENT_QUEUE_PULL=[a-z]+' | sed 's/.*=//' | sort -u) <(echo "$code")
  assert_success
}

@test "Admission: the board-only exit and the cap default are agent-queue's" {
  local body
  body=$(section Admission)
  [ "$(grep -oE 'exit [0-9]+, `why: board-only`' <<<"$body" | grep -oE '[0-9]+')" = "$(sed -nE 's/^AQ_EX_HELD=([0-9]+)$/\1/p' "$AQ")" ]
  [ "$(grep -oE '`AGENT_QUEUE_CAP` \(default [0-9]+\)' <<<"$body" | grep -oE '[0-9]+')" = "$(default_of "$AQ" AQ_CAP)" ]
}

@test "Dispatch: each verb the section leads a bullet with is a fleet-dispatch verb, and the low water is its default" {
  local verbs v body
  body=$(section 'The dispatcher: `fleet-dispatch`')
  verbs=$(grep -oE '^- `[a-z-]+[ `]' <<<"$body" | sed -E 's/^- `//; s/[ `]$//')
  [ -n "$verbs" ]
  for v in $verbs; do
    grep -qE "^    $v\) " "$FD" || { echo "fleet-dispatch has no verb: $v"; return 1; }
  done
  [ "$(grep -oE 'DISPATCH_LOW_WATER` \([0-9]+\)' <<<"$body" | grep -oE '[0-9]+')" = "$(default_of "$FD" DISPATCH_LOW_WATER)" ]
}

@test "Fleet lease: the fleet-dispatch verbs it names are the ones lease_guard covers" {
  local code
  code=$(awk '/^main\(\) \{/ {f=1} f && /lease_guard "\$1"/ {print} f && /^  esac/ {exit}' "$FD" |
    sed -E 's/^ *//; s/\).*//' | tr -d ' ' | tr '|' '\n' | sort)
  [ -n "$code" ]
  run diff <(section 'The fleet lease' | grep -m1 -oE '`fleet-dispatch run`[^(]*check the same lease' |
    grep -oE '`[a-z -]+`' | tr -d '`' | sed 's/^fleet-dispatch //' | sort) <(echo "$code")
  assert_success
}

@test "Fleet lease: the TTL and the no-network margin are fleet-lease's" {
  local body
  body=$(section 'The fleet lease')
  [ "$(grep -oE 'TTL [0-9]+ s' <<<"$body" | grep -oE '[0-9]+')" = "$(default_of "$FL" TTL_S)" ]
  [ "$(grep -oE 'more than [0-9]+ s from expiry' <<<"$body" | grep -oE '[0-9]+')" = "$(sed -nE 's/^MARGIN_S=([0-9]+)$/\1/p' "$FL")" ]
}

@test "Fleet lease: the lanes with no conf are the units gated on fleet-lease by name" {
  local units
  units=$(for r in "$PUB" "$PRIV"; do
    git -C "$r" ls-files -z '.config/systemd/user/*.service' | (cd "$r" && xargs -0 cat)
  done | sed -nE 's#^ExecCondition=%h/\.local/bin/fleet-lease ([a-z0-9-]+)$#\1#p' | sort -u)
  [ -n "$units" ]
  run diff <(section 'The fleet lease' | grep -m1 -oE 'A lane with no conf \([^)]*\)' |
    sed -E 's/.*\(//; s/\)$//' | tr ',' '\n' | tr -d ' ' | sort) <(echo "$units")
  assert_success
}

@test "Fleet lease: the persistent singletons it names are fleet-lease's UNITS plus the persistent singleton confs" {
  local code
  code=$({
    sed -nE 's/^UNITS="\$\{FLEET_LEASE_UNITS:-([^}]*)\}"$/\1/p' "$FL" | tr ' ' '\n' | sed 's/\.service$//'
    for f in "$PRIV"/.config/agentctl/agents/*.conf; do
      grep -qE '^KIND=["'\'']?persistent' "$f" && ! grep -qE '^SCOPE=["'\'']?every-node' "$f" && basename "$f" .conf
    done
  } | grep -v '^$' | sort -u)
  [ -n "$code" ]
  run diff <(section 'The fleet lease' | grep -m1 -oE 'the persistent singletons \([^)]*\)' |
    sed -E 's/.*\(//; s/\)$//' | tr ',' '\n' | tr -d ' ' | sort) <(echo "$code")
  assert_success
}
