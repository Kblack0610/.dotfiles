#!/usr/bin/env bats
# agent-propose: nothing runs without an accept, a rejected idea is not asked again, and the store stays bounded.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  export AGENT_PROPOSE_DIR="$BATS_TEST_TMPDIR/proposals"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for c in agent-queue notes; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n[ -z "${STUB_FAIL:-}" ] || { echo boom; exit 1; }\necho done\n' "$c" > "$BATS_TEST_TMPDIR/bin/$c"
    chmod +x "$BATS_TEST_TMPDIR/bin/$c"
  done
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  AP="$BATS_TEST_DIRNAME/../../.local/bin/agent-propose"
}

add_queue() { "$AP" add --stream usage-cleanup --project dotfiles --verb queue --arg "fix it" "${1:-Cap gh polling}"; }

@test "accept runs the queue verb once and records who decided" {
  id="$(add_queue)"
  run "$AP" accept "$id"
  assert_success
  assert_equal "$(cat "$CALLS")" "agent-queue add --project dotfiles -- fix it"
  assert_equal "$(jq -r '.status + " " + .decided_by' "$AGENT_PROPOSE_DIR/$id.json")" "accepted human"
  run "$AP" accept "$id"
  assert_failure
  assert_equal "$(wc -l < "$CALLS")" 1
}

@test "row verb files on the agent board" {
  id="$("$AP" add --stream ci-failures --project agent-runtime --verb row --arg "fix(ci): x #size/s" "Own it")"
  "$AP" accept "$id"
  assert_equal "$(cat "$CALLS")" "notes ptask agent-runtime --agent add fix(ci): x #size/s"
}

@test "reject never runs the verb" {
  id="$(add_queue)"
  run "$AP" reject "$id"
  assert_success
  [ ! -e "$CALLS" ]
  assert_equal "$(jq -r .status "$AGENT_PROPOSE_DIR/$id.json")" rejected
}

@test "a failed verb stays open with the reason" {
  id="$(add_queue)"
  STUB_FAIL=1 run "$AP" accept "$id"
  assert_failure
  assert_equal "$(jq -r '.status + " " + .error' "$AGENT_PROPOSE_DIR/$id.json")" "open boom"
}

@test "a repeat returns the open record, and a rejected one is not asked again" {
  id="$(add_queue)"
  assert_equal "$(add_queue)" "$id"
  assert_equal "$("$AP" count)" 1
  "$AP" reject "$id"
  assert_equal "$(add_queue)" "$id"
  assert_equal "$("$AP" count)" 0
}

@test "an expired proposal may come back, and a past-due one stops counting against the cap" {
  export AGENT_PROPOSE_MAX=1
  id="$(add_queue)"
  jq -c '.expires = "2020-01-01T00:00:00Z"' "$AGENT_PROPOSE_DIR/$id.json" > "$BATS_TEST_TMPDIR/r" && cp "$BATS_TEST_TMPDIR/r" "$AGENT_PROPOSE_DIR/$id.json"
  run add_queue other
  assert_success
  "$AP" reject "$output"
  run add_queue
  assert_success
  assert_equal "$(jq -r .status "$AGENT_PROPOSE_DIR/$id.json")" open
}

@test "a title that reads as a flag stays the title, and optional flags may be empty" {
  id="$("$AP" add --stream s --project p --verb queue --arg "--running x" --why "" --evidence "" title)"
  "$AP" accept "$id"
  assert_equal "$(cat "$CALLS")" "agent-queue add --project p -- --running x"
}

@test "a missing id or an unknown status says so" {
  run "$AP" accept deadbeef
  assert_failure
  assert_output "agent-propose: no proposal deadbeef"
  run "$AP" list --status opn
  assert_failure
}

@test "the cap refuses loudly, per stream and project" {
  export AGENT_PROPOSE_MAX=1
  add_queue one
  run add_queue two
  assert_failure
  assert_output --partial "decide those first"
  run "$AP" add --stream dream --project dotfiles --verb none "other stream"
  assert_success
}

@test "an unknown verb or a bad id is refused" {
  run "$AP" add --stream s --project p --verb bash --arg "rm -rf /" t
  assert_failure
  run "$AP" accept '../../etc/passwd'
  assert_failure
  assert_output --partial "bad id"
}

@test "expire closes what is past due and prunes old decisions" {
  id="$(add_queue)"
  old="$("$AP" add --stream s --project p --verb none old)"
  jq -c '.expires = "2020-01-01T00:00:00Z"' "$AGENT_PROPOSE_DIR/$id.json" > "$BATS_TEST_TMPDIR/r" && cp "$BATS_TEST_TMPDIR/r" "$AGENT_PROPOSE_DIR/$id.json"
  "$AP" reject "$old"
  jq -c '.decided_at = "2020-01-01T00:00:00Z"' "$AGENT_PROPOSE_DIR/$old.json" > "$BATS_TEST_TMPDIR/r" && cp "$BATS_TEST_TMPDIR/r" "$AGENT_PROPOSE_DIR/$old.json"
  run "$AP" expire
  assert_output "1 expired"
  assert_equal "$(jq -r .status "$AGENT_PROPOSE_DIR/$id.json")" expired
  [ ! -e "$AGENT_PROPOSE_DIR/$old.json" ]
}

@test "list filters by status and stream, oldest first" {
  a="$(add_queue a)"; b="$("$AP" add --stream dream --project p --verb none b)"
  "$AP" reject "$a"
  assert_equal "$("$AP" list --json | jq -r '.[].id')" "$b"
  assert_equal "$("$AP" list --json --status all --stream dream | jq length)" 1
}

@test "list --json says what an accept will run, for each verb" {
  add_queue >/dev/null
  "$AP" add --stream s --project dotfiles --verb row --arg "a row" "second"  >/dev/null
  "$AP" add --stream s --project dotfiles --verb none "third" >/dev/null
  run bash -c "\"$AP\" list --json | jq -r 'sort_by(.verb) | .[].does'"
  assert_success
  assert_line --index 0 "nothing runs: the decision is recorded"
  assert_line --index 1 "agent-queue add --project dotfiles -- fix it"
  assert_line --index 2 "notes ptask dotfiles --agent add a row"
}

@test "accept passes the arg as one argument, spaces and newlines intact" {
  cat > "$BATS_TEST_TMPDIR/bin/agent-queue" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$#" "${!#}" > "$CALLS"
STUB
  id="$("$AP" add --stream s --project p --verb queue --arg $'two  words\nand a line' "Keep it whole")"
  "$AP" accept "$id"
  assert_equal "$(sed -n 1p "$CALLS")" 5
  assert_equal "$(sed -n '2,$p' "$CALLS")" $'two  words\nand a line'
}

# mem0: sops and curl stubbed. The curl stub keeps its stdin (the -K config) and its argv apart, so a
# test can tell where the key went.
mem0_stubs() {
  export AGENT_PROPOSE_MEM0_LIB="$BATS_TEST_DIRNAME/../../.local/lib/mem0.sh"
  export AGENT_PROPOSE_MEM0_ENV="$BATS_TEST_TMPDIR/mem0.env"
  printf 'MEM0_BASE_URL=https://mem0.test\nMEM0_USER_ID=me\nMEM0_SECRET=%s/secret.yaml\n' "$BATS_TEST_TMPDIR" > "$AGENT_PROPOSE_MEM0_ENV"
  printf '#!/usr/bin/env bash\necho "sops $*" >> "$CALLS"\necho "MEM0_API_KEY: \\"m0sk_sekrit\\""\n' > "$BATS_TEST_TMPDIR/bin/sops"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'C'
#!/usr/bin/env bash
cat > "$CALLS.curl-stdin"
printf '%s\n' "$@" > "$CALLS.curl-argv"
echo "curl" >> "$CALLS"
ok='{"results":[{"id":"m1","memory":"x","event":"ADD"}]}'
echo "${CURL_OUT:-$ok}"
C
  chmod +x "$BATS_TEST_TMPDIR/bin/sops" "$BATS_TEST_TMPDIR/bin/curl"
}

add_mem0() { "$AP" add --stream dream --project dotfiles --verb mem0 --arg "Prefers plain tables" --key dream/b1 "Keep: prefers plain tables"; }

@test "mem0 accept posts the fact verbatim, and the key goes to curl on stdin only" {
  mem0_stubs
  id="$(add_mem0)"
  assert_equal "$("$AP" list --json | jq -r '.[0].does')" "post to mem0, verbatim: Prefers plain tables"
  run "$AP" accept "$id"
  assert_success
  assert_equal "$(jq -r '.status + " " + .result' "$AGENT_PROPOSE_DIR/$id.json")" "accepted mem0 m1"
  assert_equal "$(cat "$CALLS.curl-stdin")" 'header = "X-API-Key: m0sk_sekrit"'
  run grep -c m0sk_ "$CALLS.curl-argv" "$AGENT_PROPOSE_DIR/$id.json"
  assert_output --partial "curl-argv:0"
  assert_output --partial "$id.json:0"
  assert_equal "$(grep -x -A1 -- --data-binary "$CALLS.curl-argv" | tail -1 | jq -c .)" \
    '{"messages":[{"role":"user","content":"Prefers plain tables"}],"user_id":"me","infer":false}'
  grep -qx 'https://mem0.test/memories' "$CALLS.curl-argv"
}

@test "mem0 reject reads no key and posts nothing" {
  mem0_stubs
  id="$(add_mem0)"
  run "$AP" reject "$id"
  assert_success
  [ ! -e "$CALLS" ]
}

@test "mem0 that stores nothing, or has no config or key, stays open with the reason" {
  mem0_stubs
  id="$(add_mem0)"
  CURL_OUT='{"results":[]}' run "$AP" accept "$id"
  assert_failure
  assert_equal "$(jq -r '.status' "$AGENT_PROPOSE_DIR/$id.json")" open
  assert_output --partial "mem0 stored nothing"
  printf '#!/bin/sh\necho "MEM0_API_KEY: "\n' > "$BATS_TEST_TMPDIR/bin/sops"
  run "$AP" accept "$id"
  assert_output --partial "no mem0 key could be read"
  AGENT_PROPOSE_MEM0_ENV="$BATS_TEST_TMPDIR/none" run "$AP" accept "$id"
  assert_output --partial "no mem0 config"
  assert_equal "$(jq -r '.status' "$AGENT_PROPOSE_DIR/$id.json")" open
  grep -c curl "$CALLS" | grep -qx 1
}
