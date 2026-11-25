#!/usr/bin/env bats
# .github/workflows/tests.yml's gate job, the one check branch protection requires: its `needs`
# names every job but the ones that are not gates, and its step is red on any result but success.
# Also the one-toolchain rule: every job on the &pool runner, and no step installing a tool.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  WF="$BATS_TEST_DIRNAME/../../.github/workflows/tests.yml"
  # weights gates through fast (fast needs its pick); report only draws; gate is the aggregate.
  NOT_GATES='gate report weights'
}

# jobs <wf>: every job id, one a line, sorted
jobs() { sed -nE '/^jobs:$/,$ s/^  ([A-Za-z0-9_][A-Za-z0-9_-]*):$/\1/p' "$1" | sort; }

# gate_needs <wf>: the gate job's needs, one a line, sorted
gate_needs() { sed -n '/^  gate:$/,/^  [a-z]/{s/^    needs: *\[\(.*\)\]$/\1/p}' "$1" | tr -d ' ' | tr ',' '\n' | sort; }

# missing <wf>: jobs that are neither in gate's needs nor named as not gates
missing() { comm -23 <(jobs "$1") <({ gate_needs "$1"; tr ' ' '\n' <<<"$NOT_GATES"; } | sort); }

# unknown <wf>: names in gate's needs that are not jobs (a renamed or deleted job)
unknown() { comm -13 <(jobs "$1") <(gate_needs "$1"); }

@test "the gate needs every job but the ones that are not gates" {
  [ -n "$(gate_needs "$WF")" ] || fail "no needs read from the gate job"
  run missing "$WF"
  assert_success
  assert_output ''
  # Negative control: a new job that nobody added to the gate is named.
  awk '/^  gate:$/ { print "  Newjob-2:"; print "    runs-on: ubuntu-24.04" } { print }' "$WF" >"$BATS_TEST_TMPDIR/new.yml"
  run missing "$BATS_TEST_TMPDIR/new.yml"
  assert_output 'Newjob-2'
}

@test "every job the gate needs exists" {
  run unknown "$WF"
  assert_success
  assert_output ''
  # Negative control: a renamed job leaves its old name in needs.
  sed 's/^  lint:$/  lints:/' "$WF" >"$BATS_TEST_TMPDIR/renamed.yml"
  run unknown "$BATS_TEST_TMPDIR/renamed.yml"
  assert_output 'lint'
}

@test "the gate step is green only when every needed job succeeded" {
  local check
  check=$(sed -n '/^  gate:$/,/^  [a-z]/{s/^ *\(jq -e .*\)$/\1/p}' "$WF")
  [ -n "$check" ] || fail "no jq -e line read from the gate job"
  for case in '{"a":{"result":"success"},"b":{"result":"success"}}:0' \
    '{"a":{"result":"success"},"b":{"result":"skipped"}}:1' \
    '{"a":{"result":"failure"}}:1' \
    '{"a":{"result":"cancelled"}}:1' \
    '{}:1'; do
    NEEDS=${case%:*} run bash -c "$check"
    [ "$status" -eq "${case##*:}" ] || fail "NEEDS=${case%:*}: exit $status, want ${case##*:}"
  done
}

# cargo_keys <wf>: the cargo cache key every job restores, one a line
cargo_keys() { grep -E '^ +key: cargo-target-' "$1"; }

@test "the rust and notes jobs restore the same cargo cache key" {
  run cargo_keys "$WF"
  assert_success
  [ "$(wc -l <<<"$output")" -eq 2 ] || fail "want the rust restore and the notes restore: $output"
  [ "$(sort -u <<<"$output" | wc -l)" -eq 1 ] || fail "the cargo cache keys differ: $output"
  # Negative control: a notes key that drifted is named.
  sed '/^  notes:$/,$ s/cargo-target-\${{ runner.os }}/cargo-target-x-${{ runner.os }}/' "$WF" >"$BATS_TEST_TMPDIR/drift.yml"
  run cargo_keys "$BATS_TEST_TMPDIR/drift.yml"
  [ "$(sort -u <<<"$output" | wc -l)" -gt 1 ]
}

# rust_job <wf>: the whole rust job's text, to the next job
rust_job() { sed -n '/^  rust:$/,/^  [a-z][a-z-]*:$/p' "$1"; }

@test "the Rust gate runs clippy on a pull request: nothing in the rust job sets CLIPPY" {
  run rust_job "$WF"
  assert_success
  [[ "$output" == *"tests/pick.sh rust"* ]] || fail "the rust job was not found: $output"
  [[ "$output" != *CLIPPY* ]] || fail "the rust job sets CLIPPY, so a pull request skips or forces clippy: $output"
  # Negative control: a pull-request-only CLIPPY=0 is named.
  sed "s/^          BASE: /          CLIPPY: \${{ github.event_name == 'pull_request' \&\& '0' || '1' }}\n          BASE: /" "$WF" >"$BATS_TEST_TMPDIR/skip.yml"
  run rust_job "$BATS_TEST_TMPDIR/skip.yml"
  [[ "$output" == *CLIPPY* ]]
}

# runs_on <wf>: "<job> <runs-on>" for every job; "-" for a job with none (a reusable workflow call)
runs_on() {
  awk '/^jobs:$/ { on = 1; next }
    on && /^  [A-Za-z0-9_][A-Za-z0-9_-]*:$/ { if (job) print job, (r == "" ? "-" : r); job = substr($1, 1, length($1) - 1); r = ""; next }
    on && /^    runs-on: / { sub(/^    runs-on: */, ""); r = $0 }
    END { if (job) print job, (r == "" ? "-" : r) }' "$1"
}

# off_pool <wf>: jobs whose runner is not the pool anchor, one a line (a literal label, a second
# definition of the anchor, a pasted expression)
off_pool() {
  runs_on "$1" | awk '$2 == "*pool" || $2 == "-" { next } $2 == "&pool" && !seen++ { next } { print $1 }'
}

@test "every tests.yml job runs where the one &pool anchor says" {
  run runs_on "$WF"
  assert_success
  [[ "$output" == *"&pool "* ]] || fail "no job defines the &pool anchor: $output"
  run off_pool "$WF"
  assert_success
  assert_output ''
  # Negative control: a job with a literal label is named.
  sed '/^  lint:$/,/^  [a-z]/ s/^    runs-on: \*pool$/    runs-on: ubuntu-24.04/' "$WF" >"$BATS_TEST_TMPDIR/literal.yml"
  run off_pool "$BATS_TEST_TMPDIR/literal.yml"
  assert_output 'lint'
}

@test "the skills call passes the anchor's runner choice, fork rule included" {
  local cond
  cond=$(sed -nE 's/^    runs-on: &pool \$\{\{ fromJSON\((.*) && vars\.LINUX_RUNNER_LIGHT \|\| .*$/\1/p' "$WF")
  [ -n "$cond" ] || fail "no fork condition read from the &pool anchor"
  run sed -n '/^  skills:$/,/^  [a-z]/{/^      runs-on: /p}' "$WF"
  assert_success
  [[ "$output" == *"$cond && vars.LINUX_RUNNER_LIGHT"* ]] || fail "skills runs-on is not the anchor's choice ($cond): $output"
}

# host_installs <dir>: workflow and action lines that put a tool on the runner itself, outside a
# comment. A job's tools come from tests/Dockerfile, so a runner needs only docker (~/.local/src/docs/ci.md).
host_installs() {
  # GITHUB_PATH: a download put on PATH, as the bun step did before the image carried bun.
  grep -rnE '(^|[^A-Za-z0-9_-])(apt-get|apt install|dpkg -i|rustup|npm (install|ci)|pip3? install|cargo install|go install|brew install|curl [^#]*\| *(ba)?sh|GITHUB_PATH|uses: [^ ]*setup-)([^A-Za-z0-9_-]|$)' "$1" |
    grep -vE '^[^:]+:[0-9]+: *#' || true
}

@test "no workflow or action installs a tool on the runner" {
  local gh="$BATS_TEST_DIRNAME/../../.github"
  run host_installs "$gh"
  assert_success
  assert_output ''
  # Negative control: an apt step, a rustup step and a download put on PATH in a copy are all
  # named; a comment is not.
  cp -r "$gh" "$BATS_TEST_TMPDIR/gh"
  printf '      # rustup is not here\n      - run: sudo apt-get install -y stow\n      - run: rustup toolchain install 1.99.1\n      - run: echo "$RUNNER_TEMP/bun/bin" >>"$GITHUB_PATH"\n' >>"$BATS_TEST_TMPDIR/gh/workflows/tests.yml"
  run host_installs "$BATS_TEST_TMPDIR/gh"
  [ "${#lines[@]}" -eq 3 ] || fail "want the apt, rustup and GITHUB_PATH lines named: $output"
  [[ "$output" == *apt-get* && "$output" == *"rustup toolchain"* && "$output" == *GITHUB_PATH* ]]
}

# kinds <wf>: "<job> <kind>" for every job that loads the test image, kind "-" when it names none
kinds() {
  awk '
    /^  [A-Za-z0-9_-]+:$/ { if (job != "" && uses) print job, (kind == "" ? "-" : kind); job = $1; sub(/:$/, "", job); kind = ""; uses = 0 }
    /^      TEST_IMAGE_KIND:/ { kind = $2 }
    /uses: \.\/\.github\/actions\/test-image/ { uses = 1 }
    END { if (job != "" && uses) print job, (kind == "" ? "-" : kind) }
  ' "$1" | sort
}

@test "every job that loads the test image names its stage, and the stage has what the job runs" {
  run kinds "$WF"
  assert_success
  # The cheapest stage with the tools each job runs (tests/Dockerfile): the pool's link is shared,
  # so a job that loads more than it uses can run out its timeout in the restore (ar-5632).
  assert_output "$(printf '%s\n' 'fast lean' 'lint lean' 'notes rust' 'rust full' 'ui full')"
  # Negative control: a job with no kind is named "-".
  sed '/TEST_IMAGE_KIND: lean   # shellcheck/d' "$WF" >"$BATS_TEST_TMPDIR/nokind.yml"
  run kinds "$BATS_TEST_TMPDIR/nokind.yml"
  assert_line 'lint -'
}

@test "every test-image step passes the registry address and secret, and the action hardcodes no address" {
  uses=$(grep -c "uses: .\/.github\/actions\/test-image\$" "$WF")
  [ "$uses" -ge 5 ] || fail "want every job loading the image counted, got $uses"
  run grep -c '^          registry: \${{ vars\.CI_REGISTRY }}$' "$WF"
  assert_output "$uses"
  run grep -c '^          registry-password: \${{ secrets\.CI_REGISTRY_PASSWORD }}$' "$WF"
  assert_output "$uses"
  ACT="$BATS_TEST_DIRNAME/../../.github/actions/test-image/action.yml"
  # The address is the home LAN's and this repo is public (the sensitive-token scan): it is a repo variable.
  run grep -cE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$ACT"
  assert_output "0"
  # Hosted runners cannot reach the LAN: the registry step is for self-hosted ones only.
  run grep -c "runner.environment == 'self-hosted'" "$ACT"
  assert_output "1"
}

# notes_bin_unlisted <wf> <tests dir>: a bats file with a case that skips without NOTES_BIN (the real
# notes binary) that no NOTES_BIN step of <wf> names in its FILES. The fast tier skips those cases, so
# an unlisted one runs nowhere: agent_queue.bats's end to end and credit_backfill.bats's FAIL criteria
# case never ran in CI (ar-3030).
notes_bin_unlisted() {
  comm -23 <(cd "$2" && grep -lE '\|\| skip "NOTES_BIN' -- */*.bats | sort) \
    <(grep -oE 'NOTES_BIN=[^ ]+ FILES="[^"]+"' "$1" | sed -E 's/.*FILES="//; s/"$//' | tr ' ' '\n' | sort -u)
}

@test "every bats file with a case that needs the real notes is run by a NOTES_BIN step" {
  run notes_bin_unlisted "$WF" "$BATS_TEST_DIRNAME/.."
  assert_success
  assert_output ''
  # Negative control: a NOTES_BIN file dropped from its step is named.
  sed 's# integ/agent_queue.bats##' "$WF" >"$BATS_TEST_TMPDIR/drop.yml"
  run notes_bin_unlisted "$BATS_TEST_TMPDIR/drop.yml" "$BATS_TEST_DIRNAME/.."
  assert_output 'integ/agent_queue.bats'
}
