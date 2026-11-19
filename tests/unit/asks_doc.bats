#!/usr/bin/env bats
# An ask's lifecycle has one home, the LIFECYCLE line of agent-ask's header; ARCHITECTURE.md's
# Asks section (private overlay) points at it. This checks that the line names exactly the
# statuses agent-ask writes, and that the Asks section names each of them, from the files as text.
# The section check skips where the private overlay is absent (public CI).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PRIV="${ASKS_DOC_PRIVATE_REPO:-${ACCOUNT_HOME:-/nonexistent}/.dotfiles-private}"
  ASK="$PUB/.local/bin/agent-ask"
}

# The statuses on the header's `# LIFECYCLE: a -> b | c.` line.
lifecycle_states() {
  sed -nE 's/^# LIFECYCLE: ([a-z |>-]+)\..*/\1/p' "$ASK" | tr -s ' |>-' '\n' | grep -v '^$' | sort -u
}

@test "the LIFECYCLE line names exactly the statuses agent-ask writes" {
  local written
  written=$({
    grep -oE "printf 'status: [a-z]+" "$ASK" | sed 's/.* //'
    grep -oE 'write_fields "\$[a-z]+" status [a-z]+' "$ASK" | sed 's/.* //'
    grep -oE 'close_ask [a-z]+ ' "$ASK" | sed 's/close_ask //; s/ $//'
  } | sort -u)
  [ -n "$written" ]
  run diff <(lifecycle_states) <(echo "$written")
  assert_success
}

@test "ARCHITECTURE.md's Asks section names every lifecycle status and points at the header" {
  local doc="$PRIV/.config/agentctl/ARCHITECTURE.md" body s
  [ -f "$doc" ] || skip "no private overlay at $PRIV"
  body=$(awk '$0 == "## Asks" {f=1; next} f && /^## / {exit} f' "$doc")
  [ -n "$body" ]
  for s in $(lifecycle_states); do
    grep -qw "$s" <<<"$body" || { echo "Asks section does not name: $s"; return 1; }
  done
  grep -qF 'agent-ask' <<<"$body"
}
