#!/usr/bin/env bats
# fleet-dispatch.md (.local/src/docs/) leads each behaviour bullet with the verb it describes. Each
# verb it names must be one fleet-dispatch dispatches, so a renamed verb fails here. Public: runs
# in CI without the private overlay (the low-water check against the agentctl conf is in
# queue_doc.bats, which needs it).

setup() {
  load "../vendor/bats-support/load"
  load "../vendor/bats-assert/load"
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOC="$PUB/.local/src/docs/fleet-dispatch.md"
  FD="$PUB/.local/bin/fleet-dispatch"
}

@test "fleet-dispatch.md: each verb a bullet leads with is a fleet-dispatch verb" {
  local verbs v
  verbs=$(grep -oE '^- `[a-z-]+[ `]' "$DOC" | sed -E 's/^- `//; s/[ `]$//')
  [ -n "$verbs" ]
  for v in $verbs; do
    grep -qE "^    $v\) " "$FD" || { echo "fleet-dispatch has no verb: $v"; return 1; }
  done
}

@test "fleet-dispatch.md negative control: a verb that is not dispatched fails the same match" {
  run grep -qE "^    not-a-verb\) " "$FD"
  assert_failure
}
