#!/usr/bin/env bats
# .github/workflows/tests.yml's gate job, the one check branch protection requires: its `needs`
# names every job but the ones that are not gates, and its step is red on any result but success.
# Also the one-toolchain rule: every job on the &pool runner (or &job-pod, which falls back to it), and
# no step installing a tool.

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

# off_pool <wf>: jobs whose runner is not the pool or job-pod anchor, one a line (a literal label, a
# second definition of an anchor, a pasted expression)
off_pool() {
  runs_on "$1" | awk '$2 == "*pool" || $2 == "*job-pod" || $2 == "-" { next }
    $2 == "&pool" && !p++ { next } $2 == "&job-pod" && !j++ { next } { print $1 }'
}

@test "every tests.yml job runs where the one &pool or &job-pod anchor says" {
  run runs_on "$WF"
  assert_success
  [[ "$output" == *"&pool "* ]] || fail "no job defines the &pool anchor: $output"
  [[ "$output" == *"&job-pod "* ]] || fail "no job defines the &job-pod anchor: $output"
  run off_pool "$WF"
  assert_success
  assert_output ''
  # Negative control: a job with a literal label is named.
  sed '/^  ui:$/,/^  [a-z]/ s/^    runs-on: \*pool$/    runs-on: ubuntu-24.04/' "$WF" >"$BATS_TEST_TMPDIR/literal.yml"
  run off_pool "$BATS_TEST_TMPDIR/literal.yml"
  assert_output 'ui'
  # Negative control: a job pasting the job-pod expression is named.
  jp=$(sed -nE 's/^    runs-on: &job-pod (.*)$/\1/p' "$WF")
  awk -v jp="$jp" '/^  lint:$/ { l = 1 } l && /^    runs-on: \*job-pod$/ { print "    runs-on: " jp; l = 0; next } { print }' "$WF" >"$BATS_TEST_TMPDIR/pasted.yml"
  run off_pool "$BATS_TEST_TMPDIR/pasted.yml"
  assert_output 'lint'
}

@test "the &job-pod anchor is the pool the image job names with its image, else the &pool choice" {
  local pool want
  pool=$(sed -nE 's/^    runs-on: &pool \$\{\{ fromJSON\((.*)\) \}\}$/\1/p' "$WF")
  [ -n "$pool" ] || fail "no expression read from the &pool anchor"
  want="    runs-on: &job-pod \${{ fromJSON(needs.image.outputs.job-pod != '' && needs.image.outputs.job-pod || ($pool)) }}"
  run grep -cxF -- "$want" "$WF"
  assert_output 1
  # The image job names the pool only beside its image, so a --failed rerun reusing both agrees.
  run grep -cxF -- "      job-pod: \${{ vars.LINUX_RUNNER_JOB_POD != '' && steps.lean.outputs.ref != '' && vars.LINUX_RUNNER_JOB_POD || '' }}" "$WF"
  assert_output 1
  # Negative control: a fallback that drifted from the &pool choice is not the anchor's.
  sed "/^    runs-on: &job-pod /s/ubuntu-24.04/ubuntu-22.04/" "$WF" >"$BATS_TEST_TMPDIR/drift.yml"
  run grep -cxF -- "$want" "$BATS_TEST_TMPDIR/drift.yml"
  assert_output 0
}

# job_pod_faults <wf>: "<job>: <fault>" for a job on the job-pod anchor with no job image, no need
# on the image job, or a test-image step that also runs inside the image
job_pod_faults() {
  awk -v q="'" '
    function done() { if (jp) { if (!img) print job ": no container *job-image"; if (!waits) print job ": does not need the image job" } }
    /^  [A-Za-z0-9_-]+:$/ { done(); job = $1; sub(/:$/, "", job); jp = 0; img = 0; waits = 0; next }
    /^    runs-on: [&*]job-pod( |$)/ { jp = 1 }
    /^    container: [&*]job-image$/ { img = 1 }
    /^    needs:.*(\[|[ ,])image([],]|$)/ { waits = 1 }
    /^      - / { cond = "" }
    /^(      - |        )if: / { cond = $0 }
    jp && /uses: \.\/\.github\/actions\/test-image$/ && !index(cond, "needs.image.outputs.job-image == " q q) { print job ": loads the test image inside it" }
    END { done() }
  ' "$1"
}

@test "a job on the job pod runs in the image job's image and loads it only when there is none" {
  run runs_on "$WF"
  run awk '$2 ~ /^[&*]job-pod$/ { print $1 }' <<<"$output"
  assert_output "$(printf '%s\n' fast lint)"
  run job_pod_faults "$WF"
  assert_success
  assert_output ''
  # Negative controls: lint without its container, and with a test-image step that always runs.
  sed '/^  lint:$/,/^  [a-z]/{/^    container: \*job-image$/d}' "$WF" >"$BATS_TEST_TMPDIR/nocontainer.yml"
  run job_pod_faults "$BATS_TEST_TMPDIR/nocontainer.yml"
  assert_output 'lint: no container *job-image'
  sed "/^  lint:\$/,/^  [a-z]/ s/^      - if: needs.image.outputs.job-image == ''\$/      - if: always()/" "$WF" >"$BATS_TEST_TMPDIR/unguarded.yml"
  run job_pod_faults "$BATS_TEST_TMPDIR/unguarded.yml"
  assert_output 'lint: loads the test image inside it'
}

# shard_step <wf>: the Fast tier shard step's run script
shard_step() { awk '/^      - name: Fast tier shard$/ { s = 1 } s && /^        run: \|$/ { r = 1; next } r && !/^          / { exit } r { sub(/^          /, ""); print }' "$1"; }

@test "a run step gets the pool runner's bash in a container job too, and a shard that reads no files it was given fails" {
  # A container job falls back to sh for a run step with no shell; dash reads $(<file) as empty (ar-6186).
  run sed -n '/^defaults:$/,/^[a-z]/p' "$WF"
  assert_line --index 1 '  run:'
  assert_line --index 2 '    shell: bash -e {0}'
  run grep -nE '^ +shell: (/bin/|/usr/bin/)?(sh|dash)( |$)' "$WF"
  assert_failure
  run grep -n '^    defaults:' "$WF"
  assert_failure
  shard_step "$WF" >"$BATS_TEST_TMPDIR/shard.sh"
  grep -q 'files=\$(<"\$RUNNER_TEMP/files")' "$BATS_TEST_TMPDIR/shard.sh" || fail "no shard script: $(cat "$BATS_TEST_TMPDIR/shard.sh")"
  # The whole step parses: an apostrophe in a quoted ${x:-word} once unbalanced it, and every shard with files exited 2.
  run bash -n "$BATS_TEST_TMPDIR/shard.sh"
  assert_success
  : >"$BATS_TEST_TMPDIR/files"
  RUNNER_TEMP=$BATS_TEST_TMPDIR TAG='unit 1/24' PICKED_FILES=true run bash -e "$BATS_TEST_TMPDIR/shard.sh"
  assert_failure 1
  assert_output --partial '::error::the split gave unit 1/24 files'
  # The split gave none: the one empty shard of a tier that picked nothing passes.
  RUNNER_TEMP=$BATS_TEST_TMPDIR TAG='unit 1/24' PICKED_FILES='' run bash -e "$BATS_TEST_TMPDIR/shard.sh"
  assert_success
  assert_output 'nothing picked for unit 1/24'
  # Negative control: under dash the same script reads a non-empty list as empty, so the guard trips.
  command -v dash >/dev/null || skip 'no dash to show the sh fallback'
  echo unit/a.bats >"$BATS_TEST_TMPDIR/files"
  RUNNER_TEMP=$BATS_TEST_TMPDIR TAG='unit 1/24' PICKED_FILES=true run dash -e "$BATS_TEST_TMPDIR/shard.sh"
  assert_failure 1
  assert_output --partial "(shell: not bash)"
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
# A job names its stage in its env (6 spaces); the image job, which seeds every stage and the sweep's tmux versions, names one in each
# step's env (10 spaces), in the order they run.
kinds() {
  awk '
    /^  [A-Za-z0-9_-]+:$/ { if (job != "" && uses) print job, (kind == "" ? "-" : kind); job = $1; sub(/:$/, "", job); kind = ""; uses = 0 }
    /^( {6}| {10})TEST_IMAGE_KIND:/ { kind = (kind == "" ? $2 : kind "," $2) }
    /uses: \.\/\.github\/actions\/test-image/ { uses = 1 }
    END { if (job != "" && uses) print job, (kind == "" ? "-" : kind) }
  ' "$1" | sort
}

@test "every job that loads the test image names its stage, and the stage has what the job runs" {
  run kinds "$WF"
  assert_success
  # The cheapest stage with the tools each job runs (tests/Dockerfile): the pool's link is shared,
  # so a job that loads more than it uses can run out its timeout in the restore (ar-5632).
  assert_output "$(printf '%s\n' 'fast lean' 'image lean,rust,full,full,full,full,full' 'lint lean' 'notes rust' 'rust full' 'ui full')"
  # Negative control: a job with no kind is named "-".
  sed '/TEST_IMAGE_KIND: lean   # shellcheck/d' "$WF" >"$BATS_TEST_TMPDIR/nokind.yml"
  run kinds "$BATS_TEST_TMPDIR/nokind.yml"
  assert_line 'lint -'
}

@test "every test-image step passes the registry address and secret, and the action hardcodes no address" {
  uses=$(grep -c "uses: .\/.github\/actions\/test-image\$" "$WF")
  [ "$uses" -ge 8 ] || fail "want every job loading the image counted, got $uses"
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

# waits_for_image <wf>: jobs that load the test image without needing the image job (the image job itself excluded)
waits_for_image() {
  awk '
    /^  [A-Za-z0-9_-]+:$/ { if (job != "" && job != "image" && uses && !waits) print job; job = $1; sub(/:$/, "", job); uses = 0; waits = 0 }
    /^    needs:.*(\[|[ ,])image([],]|$)/ { waits = 1 }
    /uses: \.\/\.github\/actions\/test-image/ { uses = 1 }
    END { if (job != "" && job != "image" && uses && !waits) print job }
  ' "$1" | sort
}

@test "every job that loads the test image waits for the image job, so no pool pod builds it" {
  run waits_for_image "$WF"
  assert_success
  assert_output ''
  # Negative control: a lint job that dropped its needs is named.
  sed '/^  lint:$/,/^  [a-z]/{/^    needs: image$/d}' "$WF" >"$BATS_TEST_TMPDIR/nowait.yml"
  run waits_for_image "$BATS_TEST_TMPDIR/nowait.yml"
  assert_output 'lint'
}

@test "only a seed run of the test-image action pushes" {
  ACT="$BATS_TEST_DIRNAME/../../.github/actions/test-image/action.yml"
  push=$(sed -n '/^    - id: push$/,/^    # /p' "$ACT")
  [[ "$push" == *"inputs.seed == 'true'"* ]] || fail "the push step is not seed-only: $push"
  # Negative control: a push that loses the seed condition is not seed-only.
  sed "/^    - id: push\$/,/^      shell/ s/inputs.seed == 'true' && //" "$ACT" >"$BATS_TEST_TMPDIR/push.yml"
  run sed -n '/^    - id: push$/,/^    # /p' "$BATS_TEST_TMPDIR/push.yml"
  [[ "$output" != *"inputs.seed == 'true'"* ]]
}

# unseeded <wf>: tmux versions of the ui sweep matrix, bar docker.sh's default (the image job's own
# steps), with no seed step in the image job
unseeded() {
  local v dflt
  dflt=$(sed -nE 's/^TMUX_REF="\$\{TMUX_REF:-([^}]*)\}"$/\1/p' "$BATS_TEST_DIRNAME/../docker.sh")
  [ -n "$dflt" ] || fail "no default TMUX_REF read from docker.sh"
  for v in $(grep -E "^ +tmux: .*schedule" "$1" | grep -oE '"3\.[0-9a-z]+"' | tr -d '"' | sort -u); do
    [ "$v" = "$dflt" ] || grep -qF "          tmux: '$v'" "$1" || echo "$v"
  done
}

@test "the image job seeds every tmux version the weekly ui sweep loads" {
  run unseeded "$WF"
  assert_success
  assert_output ''
  # Negative control: a sweep version with no seed step is named.
  sed "/tmux: '3.6a'/d" "$WF" >"$BATS_TEST_TMPDIR/unseeded.yml"
  run unseeded "$BATS_TEST_TMPDIR/unseeded.yml"
  assert_output '3.6a'
}
