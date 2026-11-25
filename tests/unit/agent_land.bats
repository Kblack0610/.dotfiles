#!/usr/bin/env bats
# agent-land: the delivery tail after a green gate, one command. A wrong order here merges a
# stale head or closes a board row for a PR that never merged, so each stop gets a case.
# gh, git and notes are stubbed; every call lands in calls.log in order.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  LAND="$REPO_ROOT/.local/bin/agent-land"
  LOG="$NOTES_FIXTURE/calls.log"
  # No first-run wait before a "none reported" refusal; the cases for that wait set it themselves.
  export AGENT_LAND_CHECKS_FIRST_RUN_TRIES=0

  # gh: `pr view` answers from fixture files, `pr merge` flips the state to merged.state.
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  printf 'MERGED\n' >"$NOTES_FIXTURE/merged.state"
  gh_script <<'EOF'
printf 'gh %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
# hint: every call also writes gh 2.105's success hint to stderr
[ ! -f "$NOTES_FIXTURE/hint" ] || printf 'hint: if you need to wait for this pull request, use this instead of polling:\n    gh event listen --resource x\n' >&2
case "$1 $2" in
'pr view')
  case "$*" in
  # pr41.state: the state of #41, an earlier PR an item records as open (OPEN by default)
  'pr view 41 --json state '*) cat "$NOTES_FIXTURE/pr41.state" 2>/dev/null || echo OPEN ;;
  # head.oid / head.ref / head.cross: the PR's head commit, branch and fork-ness (this checkout's HEAD, branch pr-42, same repo, by default)
  # The caller's real -q runs through jq on the JSON gh would return, so a query gh rejects fails here too.
  # prior.json: an earlier PR the item records, asked for its state and merge commit (open by default)
  *state,mergeCommit*) { cat "$NOTES_FIXTURE/prior.json" 2>/dev/null || echo '{"state":"OPEN","mergeCommit":null}'; } | jq -r "${@: -1}" || exit 1 ;;
  # url: the PR's URL (o/r #42 by default)
  *baseRefName*) printf '{"state":"%s","baseRefName":"main","url":"%s","headRefOid":"%s","isCrossRepository":%s,"headRefName":"%s"}' "$(cat "$NOTES_FIXTURE/state")" \
    "$(cat "$NOTES_FIXTURE/url" 2>/dev/null || echo https://github.com/o/r/pull/42)" \
    "$(cat "$NOTES_FIXTURE/head.oid" 2>/dev/null || echo 0123456789abcdef)" "$(cat "$NOTES_FIXTURE/head.cross" 2>/dev/null || echo false)" "$(cat "$NOTES_FIXTURE/head.ref" 2>/dev/null || echo pr-42)" |
    jq -r "${@: -1}" || exit 1 ;;
  *mergeable*)
    # mergeable.seq: one answer per call, popped as read; then this head, mergeable
    q="$NOTES_FIXTURE/mergeable.seq"
    if [ -s "$q" ]; then head -1 "$q"; sed -i 1d "$q"; else echo '0123456789abcdef MERGEABLE'; fi ;;
  # the base...head pair pr_files diffs when GitHub cannot render the diff
  *baseRefOid,headRefOid*) printf '{"baseRefOid":"5eedbase5eedbase","headRefOid":"0123456789abcdef"}' | jq -r "${@: -1}" || exit 1 ;;
  # sup.json: the PR --supersedes names, its state, head, body and open time (closed, its body naming ship, by default)
  *state,headRefOid,body,createdAt*) { cat "$NOTES_FIXTURE/sup.json" 2>/dev/null || echo '{"state":"CLOSED","headRefOid":"5eed","body":"Item: ship","createdAt":"2026-11-11T03:00:00Z"}'; } | jq -r "${@: -1}" || exit 1 ;;
  # merged.at: when the PR merged
  *'--json mergedAt '*) cat "$NOTES_FIXTURE/merged.at" 2>/dev/null || echo 2026-11-11T08:39:08Z ;;
  *headRefOid*)
    # head.seq: the PR's head on each poll after a fresh push, popped as read; then head.oid. head.fail: the call fails
    [ ! -f "$NOTES_FIXTURE/head.fail" ] || { echo 'gh: API rate limit exceeded (HTTP 403)' >&2; exit 1; }
    q="$NOTES_FIXTURE/head.seq"
    if [ -s "$q" ]; then h=$(head -1 "$q"); sed -i 1d "$q"; else h=$(cat "$NOTES_FIXTURE/head.oid" 2>/dev/null || echo 0123456789abcdef); fi
    printf '{"headRefOid":"%s"}' "$h" | jq -r "${@: -1}" || exit 1 ;;
  *body*) cat "$NOTES_FIXTURE/body" ;;
  # merge.oid: the PR's merge commit
  *mergeCommit*) cat "$NOTES_FIXTURE/merge.oid" 2>/dev/null || echo fedcba9876543210fedcba9876543210fedcba98 ;;
  # checks.rollup: statusCheckRollup JSON for conclusion-based check evaluation after watch timeout
  *statusCheckRollup*) cat "$NOTES_FIXTURE/checks.rollup" 2>/dev/null || echo '{"statusCheckRollup":[]}' ;;
  *) cat "$NOTES_FIXTURE/state" ;;
  esac ;;
# rules.json: the base's rulesets ([] when absent); rules.fail: the call fails
'api repos/o/r/rules/branches/'*) [ ! -f "$NOTES_FIXTURE/rules.fail" ] || { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
  cat "$NOTES_FIXTURE/rules.json" 2>/dev/null || echo '[]' ;;
# protection.json: the base's branch protection; protection.err: the call fails with it; neither: a 404
'api repos/o/r/branches/'*'/protection')
  [ ! -f "$NOTES_FIXTURE/protection.err" ] || { cat "$NOTES_FIXTURE/protection.err" >&2; exit 1; }
  [ -f "$NOTES_FIXTURE/protection.json" ] || { echo '{"message":"Branch not protected","status":"404"}'; echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1; }
  cat "$NOTES_FIXTURE/protection.json" ;;
# files: the PR's changed paths, one a line (none when absent); files.fail: the call fails;
# files.toobig: GitHub cannot render the diff (422 not_available, its body on stdout)
'api '*) [ ! -f "$NOTES_FIXTURE/files.fail" ] || { echo 'HTTP 502'; exit 1; }
  [ ! -f "$NOTES_FIXTURE/files.toobig" ] || { echo '{"message":"Server Error: Sorry, this diff is taking too long to generate.","errors":[{"resource":"PullRequest","field":"diff","code":"not_available"}],"status":"422"}'; echo 'gh: Server Error (HTTP 422)' >&2; exit 1; }
  cat "$NOTES_FIXTURE/files" 2>/dev/null || true ;;
# merge.fail: gh pr merge errors and merges nothing
'pr merge') [ ! -f "$NOTES_FIXTURE/merge.fail" ] || { echo 'GraphQL: Pull request is not mergeable' >&2; exit 1; }
  cp "$NOTES_FIXTURE/merged.state" "$NOTES_FIXTURE/state" ;;
# search.json: the open PRs a body search finds, as gh search prs --json prints them ([] when absent); search.fail: the call fails
'search prs') [ ! -f "$NOTES_FIXTURE/search.fail" ] || { echo 'gh: API rate limit exceeded (HTTP 403)' >&2; exit 1; }
  cat "$NOTES_FIXTURE/search.json" 2>/dev/null || echo '[]' ;;
# pr edit --body-file -: the new body becomes the body
'pr edit') cat >"$NOTES_FIXTURE/body" ;;
'run list')
  case "$*" in
  # runs.open: the head's runs as JSON, one answer per read, popped as read; [] once empty.
  # A line "ERR <text>": that read fails with <text>
  *workflowName*) q="$NOTES_FIXTURE/runs.open" r='[]'
    if [ -s "$q" ]; then r=$(head -1 "$q"); sed -i 1d "$q"; fi
    case "$r" in 'ERR '*) echo "${r#ERR }" >&2; exit 1 ;; esac
    echo "$r" ;;
  # runs.queued: one count per poll, popped as read; 0 once empty. A line "ERR <text>": that read fails with <text>
  *) q="$NOTES_FIXTURE/runs.queued" r=0
    if [ -s "$q" ]; then r=$(head -1 "$q"); sed -i 1d "$q"; fi
    case "$r" in 'ERR '*) echo "${r#ERR }" >&2; exit 1 ;; esac
    echo "$r" ;;
  esac ;;
'pr checks')
  case "$*" in
  # checks.failed: the failed or cancelled names after a failed watch
  *'"fail" or'*) cat "$NOTES_FIXTURE/checks.failed" ;;
  # checks.stale: the failed checks as JSON after a failed watch ([] when absent)
  *'"fail"))'*) cat "$NOTES_FIXTURE/checks.stale" 2>/dev/null || echo '[]' ;;
  # checks.skipping: whether all checks on the PR are in the skipping bucket (false when absent)
  *'"skipping"'*) cat "$NOTES_FIXTURE/checks.skipping" 2>/dev/null || echo false ;;
  # checks.cancelled: the cancelled checks as JSON after a green watch, one answer per read,
  # popped as read; [] once empty. A line "ERR <text>": that read fails with <text>
  *--json*) q="$NOTES_FIXTURE/checks.cancelled" r='[]'
    if [ -s "$q" ]; then r=$(head -1 "$q"); sed -i 1d "$q"; fi
    case "$r" in 'ERR '*) echo "${r#ERR }" >&2; exit 1 ;; esac
    echo "$r" ;;
  # checks.seq: one watch result per call (green, or the output of a failed watch), popped as read; then checks.out
  *) q="$NOTES_FIXTURE/checks.seq"
    if [ -s "$q" ]; then r=$(head -1 "$q"); sed -i 1d "$q"; [ "$r" = green ] || { echo "$r"; exit 1; }; exit 0; fi
    [ ! -f "$NOTES_FIXTURE/checks.out" ] || { cat "$NOTES_FIXTURE/checks.out"; exit 1; } ;;
  esac ;;
esac
EOF
  printf '0\n' >"$NOTES_FIXTURE/behind"
  cat >"$SANDBOX/bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
[ "$1" != -C ] || shift 2
case "$1" in
rev-list)
  # behind.seq: one count per call, popped as read; then behind
  q="$NOTES_FIXTURE/behind.seq"
  if [ -s "$q" ]; then head -1 "$q"; sed -i 1d "$q"; else cat "$NOTES_FIXTURE/behind"; fi ;;
# no.checkout: run outside a checkout, where rev-parse --show-toplevel fails
rev-parse) case "$2" in --show-toplevel) [ ! -f "$NOTES_FIXTURE/no.checkout" ] || { echo 'fatal: not a git repository' >&2; exit 128; }
  cat "$NOTES_FIXTURE/toplevel" 2>/dev/null || echo /nowhere ;; *) echo 0123456789abcdef ;; esac ;;
# remotes: what `git remote` lists (origin by default); <name>.url: that remote's URL, and
# origin.url this checkout's origin (o/r over ssh by default)
remote) case "$2" in
  '') cat "$NOTES_FIXTURE/remotes" 2>/dev/null || echo origin ;;
  *) cat "$NOTES_FIXTURE/${*: -1}.url" 2>/dev/null || cat "$NOTES_FIXTURE/origin.url" 2>/dev/null || echo git@github.com:o/r.git ;;
  esac ;;
# remote.tip: origin's tip of the asked branch, as `git ls-remote` prints it (nothing when absent)
# remote.fail: the call fails (no network); a decoy ref that only tail-matches comes first
ls-remote) [ ! -f "$NOTES_FIXTURE/remote.fail" ] || { echo 'fatal: unable to access' >&2; exit 128; }
  [ ! -f "$NOTES_FIXTURE/remote.tip" ] || printf 'ffffffffffffffff\trefs/heads/x/%s\n%s\t%s\n' "$3" "$(cat "$NOTES_FIXTURE/remote.tip")" "$3" ;;
# worktree.list: what `git worktree list --porcelain` prints (nothing when absent)
worktree) cat "$NOTES_FIXTURE/worktree.list" 2>/dev/null || true ;;
# not.ancestor: the merge commit is not on the base branch (merge_proof refuses)
# head.foreign: the PR's head commit is not in this checkout's HEAD
# merge-base A B: prints a fixed base; --is-ancestor X HEAD fails on head.foreign, X <base> on not.ancestor
merge-base) if [ "$2" != --is-ancestor ]; then echo 5eedbase5eedbase; elif [ "${*: -1}" = HEAD ]; then [ ! -f "$NOTES_FIXTURE/head.foreign" ]; else [ ! -f "$NOTES_FIXTURE/not.ancestor" ]; fi ;;
merge) [ "$2" = --abort ] || [ ! -f "$NOTES_FIXTURE/merge.conflicts" ] || { echo 'CONFLICT (content)'; exit 1; } ;;
# tree.conflicts: a trial merge of the base (merge-tree) conflicts, and the real merge does too from then on
merge-tree) [ ! -f "$NOTES_FIXTURE/tree.conflicts" ] || { : >"$NOTES_FIXTURE/merge.conflicts"; exit 1; } ;;
# diff.status: what `git diff --name-status` prints (nothing when absent)
diff) cat "$NOTES_FIXTURE/diff.status" 2>/dev/null || true ;;
# no.workflows: the head has no Actions workflow dir (it has .github/workflows by default)
ls-tree) [ -f "$NOTES_FIXTURE/no.workflows" ] || echo .github/workflows ;;
esac
EOF
  # comms-lint: keeps what it was given in linted.txt, prints lint.out and exits lint.rc (0 by default)
  printf 'The change and why.\n' >"$NOTES_FIXTURE/body"
  cat >"$SANDBOX/bin/comms-lint" <<'EOF'
#!/usr/bin/env bash
printf 'comms-lint %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
cat >"$NOTES_FIXTURE/linted.txt"
[ ! -f "$NOTES_FIXTURE/lint.out" ] || cat "$NOTES_FIXTURE/lint.out"
exit "$(cat "$NOTES_FIXTURE/lint.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$SANDBOX/bin/git" "$SANDBOX/bin/comms-lint"

  # dotfiles-autopull: logs its call, prints autopull.out, exits autopull.rc (0 by default)
  cat >"$SANDBOX/bin/dotfiles-autopull" <<'EOF'
#!/usr/bin/env bash
printf 'dotfiles-autopull %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
cat "$NOTES_FIXTURE/autopull.out" 2>/dev/null
exit "$(cat "$NOTES_FIXTURE/autopull.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$SANDBOX/bin/dotfiles-autopull"
  export DOTFILES_AUTOPULL="$SANDBOX/bin/dotfiles-autopull"
  # The Forgejo hosts agent-land may send the token to: none, so a GitHub origin stays on gh.
  export SO_FORGEJO_HOSTS=''

  # schedules-sync: logs its call, exits ss.rc (0 by default) with ss.err on stderr
  cat >"$SANDBOX/bin/schedules-sync" <<'EOF'
#!/usr/bin/env bash
printf 'schedules-sync %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
cat "$NOTES_FIXTURE/ss.err" >&2 2>/dev/null
exit "$(cat "$NOTES_FIXTURE/ss.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$SANDBOX/bin/schedules-sync"
  export SCHEDULES_SYNC="$SANDBOX/bin/schedules-sync"

  # shape-grow: logs its call, prints shape.out and exits shape.rc (0, nothing grew, by default)
  cat >"$SANDBOX/bin/shape-grow" <<'EOF'
#!/usr/bin/env bash
printf 'shape-grow %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
cat "$NOTES_FIXTURE/shape.out" 2>/dev/null
exit "$(cat "$NOTES_FIXTURE/shape.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$SANDBOX/bin/shape-grow"
  export SHAPE_GROW="$SANDBOX/bin/shape-grow"

  # The real agent-queue, on a sandbox store: the item steps are its verbs.
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  # An ok close pulls the rows after it (pull_after), even under START=0: a silent stub, never the PATH one.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/fleet-dispatch"; chmod +x "$SANDBOX/bin/fleet-dispatch"
  export AGENT_QUEUE_DIR="$SANDBOX/queue" AGENT_QUEUE_START=0
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  # validate_gate reads the repo's ask policy and a sandbox ask store (judge_work_level).
  export AGENT_ASK_PROMPT="$REPO_ROOT/.config/agent-ask/policy.md" AGENT_ASK_ROOT="$SANDBOX/asks"
  unset CLAUDE_CODE_SESSION_ID

  # The item most cases land: an agent-lane board row's. Every landing needs one.
  item ship 'board:dotfiles:ship it' agent

  PLAN="$SANDBOX/plan.md"
  printf '%s\n' '## Phases' '' '- [x] 1. done already (#1)' '- [ ] 6. agent-land' '- [ ] 7. gate-then-land' '- [ ] 6b. not this one' >"$PLAN"
}

# board_calls -> the notes calls that write a board, leaving out the chain's ingest record lines
board_calls() { grep '^notes' "$LOG" | grep -v -e '^notes ingest record ' -e '^notes board --json$' || true; }
# ran -> the call log without the read that picks the forge (fj_detect), which runs before any step
ran() { grep -v -x -E 'git( -C [^ ]+)? rev-parse --show-toplevel' "$LOG" || true; }
# not_recorded -> the call log without the chain's record lines, which a stopped landing writes too
not_recorded() { grep -v '^notes ingest record ' "$LOG" || true; }

# item <slug> [from] [lane] [profile] -> a running queue item, on project $ITEM_PROJECT (dotfiles)
item() {
  mkdir -p "$AGENT_QUEUE_DIR/running"
  {
    printf 'slug: %s\nproject: %s\nmode: oneshot\npriority: high\nfrom: %s\nagent: claude\n' "$1" "${ITEM_PROJECT:-dotfiles}" "${2:-human}"
    printf 'queued: 2026-11-03T10:00:00Z\nstarted: 2026-11-03T10:00:00Z\n'
    [ -z "${3:-}" ] || printf 'lane: %s\n' "$3"
    [ -z "${4:-}" ] || printf 'profile: %s\n' "$4"
    printf -- '---\n%s\n' "$1"
  } >"$AGENT_QUEUE_DIR/running/20261103-100000-$1.md"
}

@test "run from a checkout that is not the PR's head: stops before the body or anything else, names the PR's worktree" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf 'pr-42\n' >"$NOTES_FIXTURE/head.ref"
  printf '%s\n' 'worktree /srv/main' 'HEAD 0123456789abcdef' 'branch refs/heads/main' '' \
    'worktree /srv/wt/r-pr-42' 'HEAD aaaaaaaabbbbbbbb' 'branch refs/heads/pr-42' '' \
    'worktree /srv/wt/r-pr-420' 'HEAD cccccccc' 'branch refs/heads/pr-420' >"$NOTES_FIXTURE/worktree.list"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "head failed: HEAD 01234567 is not the PR's head aaaaaaaa: run from the PR's checkout: /srv/wt/r-pr-42"
  run grep -c -- '--action land-failed' "$LOG"
  assert_output 0
  run grep -c 'git fetch\|pr edit\|pr checks\|pr merge\|^notes' <(not_recorded)
  assert_output 0
}

@test "head differs in the PR's own checkout (unpushed or unpulled): says push or pull, not run from here" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf '%s\n' 'worktree /srv/here' 'HEAD 0123456789abcdef' 'branch refs/heads/pr-42' >"$NOTES_FIXTURE/worktree.list"
  printf '/srv/here\n' >"$NOTES_FIXTURE/toplevel"
  # origin's tip is the PR's head, not HEAD: unpushed, so no wait on the PR
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/remote.tip"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'though this checkout has pr-42: push your commits, or pull the branch'
  refute_output --partial "run from the PR's checkout"
  run grep -c "headRefOid -q" "$LOG"
  assert_output 0
}

@test "a fresh push the PR has not read yet: waits until it reads HEAD, then lands that head" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf '0123456789abcdef\n' >"$NOTES_FIXTURE/remote.tip"
  printf '%s\n' aaaaaaaabbbbbbbb 0123456789abcdef >"$NOTES_FIXTURE/head.seq"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_line 'head: the PR read the pushed head 01234567 after 2 polls'
  assert_line 'landed #42'
  run grep -c '^git ls-remote origin refs/heads/pr-42$' "$LOG"
  assert_output 1
  run grep -c 'pr view 42 --json headRefOid -q .headRefOid' "$LOG"
  assert_output 2
  # The wait comes before the body is touched, and the merge pins the pushed head.
  [ "$(grep -n 'headRefOid -q' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'pr edit' "$LOG" | cut -d: -f1)" ]
  run grep -c 'pr merge 42 --squash --match-head-commit 0123456789abcdef' "$LOG"
  assert_output 1
}

@test "a fresh push the PR never reads within the bound: stops at head, nothing edited or merged" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf '0123456789abcdef\n' >"$NOTES_FIXTURE/remote.tip"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=3 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "head failed: HEAD 01234567 is origin's pr-42, but the PR still reads aaaaaaaa after 3 polls"
  run grep -c 'pr view 42 --json headRefOid -q .headRefOid' "$LOG"
  assert_output 3
  run grep -c 'pr edit\|pr checks\|pr merge\|^notes' <(not_recorded)
  assert_output 0
}

@test "a fresh push and gh cannot read the PR: names the gh error, not an empty head" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf '0123456789abcdef\n' >"$NOTES_FIXTURE/remote.tip"
  touch "$NOTES_FIXTURE/head.fail"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'but the PR still reads nothing (gh: gh: API rate limit exceeded (HTTP 403)) after 2 polls'
}

@test "head differs and ls-remote fails: the old diagnostics run, no wait and no silent exit" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  touch "$NOTES_FIXTURE/remote.fail"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "no checkout of pr-42 is listed"
  run grep -c "headRefOid -q" "$LOG"
  assert_output 0
}

@test "head differs and the PR's head is on a fork: points at gh pr checkout, never at a same-named local branch" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf 'true\n' >"$NOTES_FIXTURE/head.cross"
  printf 'main\n' >"$NOTES_FIXTURE/head.ref"
  printf '%s\n' 'worktree /srv/main' 'HEAD 0123456789abcdef' 'branch refs/heads/main' >"$NOTES_FIXTURE/worktree.list"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'on a fork: gh pr checkout 42'
  refute_output --partial '/srv/main'
}

@test "head differs and no worktree has the PR's branch: says so instead of naming a path" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "no checkout of pr-42 is listed"
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "an already MERGED PR is recorded from a checkout whose HEAD has its head: the head check is skipped" {
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
}

@test "behind main before the checks: merged in and pushed, then the gate runs on that head" {
  printf '2\n0\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'fetch: merged origin/main (2 behind) into the head and pushed it'
  assert_line 'landed #42'
  [ "$(grep -n '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'pr checks' "$LOG" | head -1 | cut -d: -f1)" ]
}

@test "behind main before the checks and the merge conflicts: exit 3, no checks, no merge" {
  printf '2\n' >"$NOTES_FIXTURE/behind"
  touch "$NOTES_FIXTURE/merge.conflicts"
  run "$LAND" 42 --item ship
  assert_failure 3
  assert_output --partial 'merging it conflicts'
  run grep -c 'pr checks\|pr merge' "$LOG"
  assert_output 0
}

# second_wait: the catch-up push was followed by a second checks wait, before the merge
second_wait() {
  assert_success
  assert_line 'checks: waiting on them for the pushed head'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  [ "$(grep -n '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'pr checks' "$LOG" | tail -1 | cut -d: -f1)" ]
  [ "$(grep -n 'pr checks' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'gh pr merge 42' "$LOG" | cut -d: -f1)" ]
}

# moved_again <pushes> <checks>: the base moved on again during the merged-up head's checks; a strict
# base merges up and waits again (2 pushes, 3 waits), any other lands the green head (1 push, 2 waits)
moved_again() {
  assert_success
  assert_line 'landed #42'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output "$1"
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output "$2"
}

@test "behind after a green gate, base with no protection or rulesets: merged in, pushed, and that head lands only once its own checks pass" {
  printf '0\n1\n0\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship
  assert_line 'fetch: merged origin/main (1 behind) into the head and pushed it'
  second_wait
  run grep -c '^gh api repos/o/r/rules/branches/main$\|^gh api repos/o/r/branches/main/protection$' "$LOG"
  assert_output 0
  # The merge, then submodule_follow from the pre-merge head (rev-parse's stub answer), then the push.
  local m d p
  m=$(grep -n '^git merge -q --no-edit origin/main$' "$LOG" | cut -d: -f1)
  d=$(grep -n '^git -C /nowhere diff --raw -z --no-abbrev --no-renames --diff-filter=M 0123456789abcdef HEAD$' "$LOG" | cut -d: -f1)
  p=$(grep -n '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG" | cut -d: -f1)
  [ "$m" -lt "$d" ] && [ "$d" -lt "$p" ]
  run grep -A1 '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_line --index 1 'git rev-parse HEAD'
  run grep -c 'pr merge 42 --squash --match-head-commit 0123456789abcdef' "$LOG"
  assert_output 1
}

@test "a watch that loses its API connection watches again and merges on green (binks #1531)" {
  printf '%s\n' 'Post "https://api.github.com/graphql": read tcp 10.0.0.1:1->10.0.0.2:443: read: connection reset by peer' green >"$NOTES_FIXTURE/checks.seq"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'checks: lost the connection to the API (1 of 5 retries), reading again'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep -c 'pr merge 42' "$LOG"
  assert_output 1
}

@test "a watch that keeps losing its API connection stops at checks and never merges" {
  for _ in 1 2 3 4 5 6; do echo 'Post "https://api.github.com/graphql": read: connection reset by peer'; done >"$NOTES_FIXTURE/checks.seq"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'lost the connection to the API 6 times'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a red watch whose table names a check after a transport error stops at checks, not retried" {
  printf '%s\n' 'retry on HTTP 503	fail	1m' >"$NOTES_FIXTURE/checks.seq"
  echo 'retry on HTTP 503' >"$NOTES_FIXTURE/checks.failed"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: retry on HTTP 503'
  refute_output --partial 'lost the connection'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a merged-up head whose own checks go red is never merged (dotfiles #1504)" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf '%s\n' green 'Checks	fail	1m' >"$NOTES_FIXTURE/checks.seq"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'fetch: merged origin/main (1 behind) into the head and pushed it'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "no strict checks and the base moves on again during the merged-up head's checks: that green head lands behind it, no second merge-up" {
  printf '0\n1\n3\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship
  assert_line 'fetch: origin/main moved on by 3 during the checks on the merged-up head; landing that green head behind it (no strict checks on main)'
  second_wait
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

@test "a pushed head that reports no checks, after the gate's head ran green, is never merged" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf 'green\n' >"$NOTES_FIXTURE/checks.seq"
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "though the gate's head ran green"
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "the base moves on again into a conflict: no green head behind it, the merge-up conflicts and exits 3" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  : >"$NOTES_FIXTURE/tree.conflicts"
  run "$LAND" 42 --item ship
  assert_failure 3
  refute_output --partial 'landing that green head behind it'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "merged up before the gate, then the base moves on twice: one merge-up after the gate, then the green head lands behind it" {
  printf '2\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship
  assert_output --partial 'landing that green head behind it'
  moved_again 2 2
}

@test "--merge-commit lands a train with a merge commit, never a squash, so its member heads stay reachable" {
  run "$LAND" 42 --item ship --merge-commit
  assert_success
  assert_line 'landed #42'
  run grep -c 'pr merge 42 --merge --match-head-commit 0123456789abcdef' "$LOG"
  assert_output 1
  run grep -c 'pr merge 42 --squash' "$LOG"
  assert_output 0
}

@test "--admin passes gh's --admin to the merge, after the checks" {
  run "$LAND" 42 --item ship --admin
  assert_success
  assert_line 'landed #42'
  run grep -c 'pr merge 42 --squash --admin --match-head-commit 0123456789abcdef' "$LOG"
  assert_output 1
  [ "$(grep -n 'pr checks' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'gh pr merge 42' "$LOG" | cut -d: -f1)" ]
}

@test "without --admin the merge carries no --admin" {
  run "$LAND" 42 --item ship
  assert_success
  run grep -c -- '--admin' "$LOG"
  assert_output 0
}

@test "--merge-commit --dry-run names the merge-commit method" {
  run "$LAND" 42 --item ship --merge-commit --dry-run
  assert_success
  assert_output --partial 'gh pr merge 42 --merge --match-head-commit'
}

@test "the base moves on again, branch protection with strict checks: merged up again, and that head lands once its checks pass" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo '{"required_status_checks":{"strict":true,"contexts":["Checks"]}}' >"$NOTES_FIXTURE/protection.json"
  run "$LAND" 42 --item ship
  moved_again 2 3
}

@test "the base moves on again, a ruleset with a strict checks policy: merged up again, and that head lands once its checks pass" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo '[{"type":"deletion"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true}}]' >"$NOTES_FIXTURE/rules.json"
  run "$LAND" 42 --item ship
  moved_again 2 3
  # a strict ruleset is enough: protection is not read
  run grep -c 'branches/main/protection' "$LOG"
  assert_output 0
}

@test "the base moves on again, required checks that are not strict: the green merged-up head lands behind it" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false}}]' >"$NOTES_FIXTURE/rules.json"
  echo '{"required_status_checks":{"strict":false,"contexts":["Checks"]}}' >"$NOTES_FIXTURE/protection.json"
  run "$LAND" 42 --item ship
  assert_output --partial 'landing that green head behind it'
  moved_again 1 2
}

@test "the base moves on again, protection that cannot be read (not a 404): counted strict, merged up again" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo 'gh: Must have admin rights to Repository. (HTTP 403)' >"$NOTES_FIXTURE/protection.err"
  run "$LAND" 42 --item ship
  moved_again 2 3
}

@test "the base moves on again, rulesets that cannot be read: counted strict, merged up again" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  touch "$NOTES_FIXTURE/rules.fail"
  run "$LAND" 42 --item ship
  moved_again 2 3
}

@test "strictness is read once per landing, however many catch-up pushes it takes" {
  printf '0\n1\n1\n0\n' >"$NOTES_FIXTURE/behind.seq"
  echo '{"required_status_checks":{"strict":true}}' >"$NOTES_FIXTURE/protection.json"
  run "$LAND" 42 --item ship
  assert_success
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 2
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 3
  run grep -c 'branches/main/protection' "$LOG"
  assert_output 1
}

@test "a pushed catch-up head is merged only once GitHub reads that head with a known mergeable" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf '%s\n' 'fedcba9876543210 MERGEABLE' '0123456789abcdef UNKNOWN' >"$NOTES_FIXTURE/mergeable.seq"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  run grep -c 'pr view 42 --json headRefOid,mergeable' "$LOG"
  assert_output 3
  # the merge comes after the last poll
  [ "$(grep -n 'headRefOid,mergeable' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'gh pr merge 42' "$LOG" | cut -d: -f1)" ]
}

@test "behind after a green gate: the catch-up pushes to the PR's head branch, whatever the local branch tracks" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf 'feat/x\n' >"$NOTES_FIXTURE/head.ref"
  printf '%s\n' 'worktree /srv/here' 'HEAD 0123456789abcdef' 'branch refs/heads/agent-11' >"$NOTES_FIXTURE/worktree.list"
  run "$LAND" 42 --item ship
  assert_success
  run grep '^git push' "$LOG"
  assert_output 'git push -q origin HEAD:refs/heads/feat/x'
}

@test "behind after a green gate with a fork head: names the push to run, nothing pushed or merged" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf 'true\n' >"$NOTES_FIXTURE/head.cross"
  run "$LAND" 42 --item ship
  assert_failure
  assert_output --partial 'on a fork'
  run grep -c '^git push\|pr merge' "$LOG"
  assert_output 0
}

@test "behind after a green gate with a conflicting merge: aborted, exit 3, nothing pushed or merged" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  : >"$NOTES_FIXTURE/merge.conflicts"
  run "$LAND" 42 --item ship
  assert_failure 3
  assert_output --partial 'behind origin/main by 1 and merging it conflicts'
  run grep -c '^git merge --abort$' "$LOG"
  assert_output 1
  run grep -c 'git push\|pr merge\|^notes' <(not_recorded)
  assert_output 0
}

@test "a --partial merge that fails leaves no partial marker (ar-2904)" {
  touch "$NOTES_FIXTURE/merge.fail"
  run "$LAND" 42 --item ship --partial
  assert_failure 1
  assert_output --partial 'merge failed: GraphQL: Pull request is not mergeable'
  run agent-queue show ship --json
  assert_equal "$(jq -r '.partial // ""' <<<"$output")" ''
}

@test "a merge that does not read MERGED stops before the board step" {
  printf 'OPEN\n' >"$NOTES_FIXTURE/merged.state"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'merge failed: #42 reads OPEN, not MERGED'
  run grep -c '^notes' <(not_recorded)
  assert_output 0
}

@test "happy path: each step once, in order, one line each" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "6. agent-land"
  assert_success
  assert_output - <<'EOF'
item-line: added "Item: ship" to the body
shape: clean
checks: green
fetch: current with origin/main
validate: repo work, no second agent needed
merge: #42 MERGED at 01234567
body: passes comms-lint --channel pr-body
proof: evidence commit 0123456789abcdef is an ancestor of origin/main
item: ship done with pr:o/r#42
board: closed "ship it" with pr:o/r#42 commit:fedcba987654
plan: ticked "6. agent-land"
landed #42
EOF
  run cat "$LOG"
  assert_output - <<'EOF'
git rev-parse --show-toplevel
git -C . rev-parse --show-toplevel
gh pr view 42 --json state,baseRefName,url,headRefOid,isCrossRepository,headRefName -q .state + " " + .baseRefName + " " + .url + " " + .headRefOid + " " + (.isCrossRepository | tostring) + " " + .headRefName
git -C . remote get-url origin
gh search prs --owner o --state open --match body --limit 100 --json number,repository,body -- Item: ship
git rev-parse HEAD
gh pr view 42 --json body -q .body
gh pr edit 42 --body-file -
notes ingest record --stage queue --action item-set --from dotfiles --item ship --id ship it --pr  --sha  --why open_pr=o/r#42 -- ship
git fetch -q origin
git rev-list --count HEAD..origin/main
git merge-base HEAD origin/main
shape-grow 5eedbase5eedbase HEAD
gh pr checks 42 --watch --fail-fast -i 30
gh pr checks 42 --json name,bucket,workflow -q map(select(.bucket == "cancel"))
git fetch -q origin
git rev-list --count HEAD..origin/main
git rev-parse HEAD
gh api repos/o/r/pulls/42/files --paginate --jq .[] | .filename, (.previous_filename // empty)
gh pr merge 42 --squash --match-head-commit 0123456789abcdef
gh pr view 42 --json state -q .state
gh pr view 42 --json body -q .body
comms-lint --channel pr-body -
gh pr view 42 --json mergeCommit -q .mergeCommit.oid
git -C . rev-parse --git-dir
git -C . fetch -q origin +refs/heads/main:refs/remotes/origin/main
git -C . rev-parse --verify --quiet refs/remotes/origin/main
git -C . rev-parse --verify --quiet fedcba9876543210fedcba9876543210fedcba98^{commit}
git -C . merge-base --is-ancestor fedcba9876543210fedcba9876543210fedcba98 origin/main
git -C . rev-parse --short fedcba9876543210fedcba9876543210fedcba98
dotfiles-autopull --now . --bg
schedules-sync sync-prs o/r
notes ingest record --stage land --action merged --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 -- ship
notes ingest record --stage queue --action item-set --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 --why pr=o/r#42 merged=fedcba9876543210fedcba9876543210fedcba98 partial= open_pr= closing_pr=o/r#42 -- ship
notes ingest record --stage queue --action item-moved --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 --to done --why running -> done (ok) -- ship
notes ptask dotfiles --agent done ship it --proof pr:o/r#42 commit:fedcba987654
EOF
}

@test "a body with findings is scored after the merge and the landing still finishes" {
  printf '  lead-too-long: 170 chars before the first sentence ends, budget 140\n\n1 finding(s) for channel pr-body.\n' >"$NOTES_FIXTURE/lint.out"
  echo 1 >"$NOTES_FIXTURE/lint.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'body: 1 finding(s) for channel pr-body. First: lead-too-long: 170 chars before the first sentence ends, budget 140'
  assert_line 'landed #42'
  run cat "$NOTES_FIXTURE/linted.txt"
  assert_output - <<'EOF'
The change and why.

Item: ship
EOF
}

@test "the scratch copy of the merged body in ~/.cache is deleted; other files stay" {
  mkdir -p "$HOME/.cache/tool"
  long=$(printf 'The change and why, at the length a real body has. %.0s' 1 2 3 4)
  printf '%s\n' "$long" >"$NOTES_FIXTURE/body"
  # the file gh pr create was given: no Item line (item-line added it), CRLF, a trailing blank
  printf '%s\r\n\n' "$long" >"$HOME/.cache/ship-pr.md"
  printf '%s\nItem: stale\n' "$long" >"$HOME/.cache/ship-pr.txt"
  printf '%s Edited later.\n' "$long" >"$HOME/.cache/other-pr.md"
  printf '%s\n' "$long" >"$HOME/.cache/ship.log"
  printf '%s\n' "$long" >"$HOME/.cache/tool/ship-pr.md"
  run "$LAND" 42 --item ship
  assert_success
  assert_line "scratch: deleted $HOME/.cache/ship-pr.md, a copy of the merged body"
  assert_line "scratch: deleted $HOME/.cache/ship-pr.txt, a copy of the merged body"
  assert_line 'landed #42'
  run bash -c 'find "$HOME/.cache" -type f \( -name "*ship*" -o -name "other*" \) | sort'
  assert_output - < <(printf '%s\n' "$HOME/.cache/other-pr.md" "$HOME/.cache/ship.log" "$HOME/.cache/tool/ship-pr.md" | sort)
}

@test "a short merged body deletes no scratch file (negative control)" {
  # a short generic body ("Fix typo.") may be another session's unsent draft too
  mkdir -p "$HOME/.cache"
  printf 'The change and why.\n' >"$HOME/.cache/short.md"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'scratch:'
  assert [ -f "$HOME/.cache/short.md" ]
}

@test "a body of only its Item line deletes no blank scratch file (negative control)" {
  printf 'Item: ship\n' >"$NOTES_FIXTURE/body"
  mkdir -p "$HOME/.cache"
  printf '\n\n' >"$HOME/.cache/blank.md"
  printf 'Item: ship\n' >"$HOME/.cache/item-only.md"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
  refute_output --partial 'scratch:'
  assert [ -f "$HOME/.cache/blank.md" ]
  assert [ -f "$HOME/.cache/item-only.md" ]
}

@test "item-line: a body that names the item is not edited" {
  printf 'The change.\n\nItem: ship\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  assert_line --index 0 'item-line: present'
  run grep -c 'pr edit' "$LOG"
  assert_output 0
}

@test "item-line: a stale Item line is rewritten in place, not added twice" {
  printf 'The change.\nItem: old-slug\nTask: ar-1\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  run cat "$NOTES_FIXTURE/body"
  assert_output - <<'EOF'
The change.
Item: ship
Task: ar-1
EOF
}

@test "item-line: a MERGED PR's Item line naming another item is left alone (ar-4252)" {
  # NEGATIVE CONTROL: before ar-4252 this rewrote #42's "Item: old-slug" to "Item: ship", cutting old-slug's link.
  item old-slug 'board:dotfiles:the first item'
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  printf 'The change.\nItem: old-slug\nTask: ar-1\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_output --partial 'item-line: merged body names another item (old-slug), left as is'
  run grep -c 'pr edit' "$LOG"
  assert_output 0
  run cat "$NOTES_FIXTURE/body"
  assert_output - <<'EOF2'
The change.
Item: old-slug
Task: ar-1
EOF2
}

@test "item-line: a MERGED PR's placeholder or unknown Item line is still rewritten (ar-4252)" {
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  printf 'The change.\nItem: <slug>\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  refute_output --partial 'left as is'
  run grep -cx 'Item: ship' "$NOTES_FIXTURE/body"
  assert_output 1
  printf 'The change.\nItem: no-such-item\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  run grep -cx 'Item: ship' "$NOTES_FIXTURE/body"
  assert_output 1
}

@test "item-line: a body that cannot be edited stops before the checks and the merge" {
  cp "$NOTES_FIXTURE/gh.script" "$NOTES_FIXTURE/gh.real"
  gh_script <<'EOF'
[ "$1 $2" != 'pr edit' ] || { printf 'gh %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"; echo 'HTTP 403' >&2; exit 1; }
. "$NOTES_FIXTURE/gh.real"
EOF
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'item-line failed: gh pr edit: HTTP 403'
  run grep -c 'pr checks\|pr merge\|^notes' <(not_recorded)
  assert_output 0
}

@test "a body that cannot be scored says why and does not fail the landing" {
  printf 'comms-lint: prose checker not found: nope.py (set COMMS_PROSE_CHECK)\n' >"$NOTES_FIXTURE/lint.out"
  echo 2 >"$NOTES_FIXTURE/lint.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'body: not scored (comms-lint: prose checker not found: nope.py (set COMMS_PROSE_CHECK))'
  assert_line 'landed #42'
}

@test "a failing check never reaches the body score (negative control)" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --item ship
  assert_failure 1
  run grep -c 'comms-lint' "$LOG"
  assert_output 0
}

@test "a stopped landing is on the record with its step and cause; a refusal and a dry run are not" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --item ship
  assert_failure 1
  run grep -- '--action land-failed' "$LOG"
  assert_success
  assert_output --partial '--item ship --pr o/r#42 --why checks: Checks'
  : >"$LOG"
  run "$LAND" 42 --item ship --dry-run --no-such-flag
  assert_failure 2
  run "$LAND" 42 --item ship --dry-run
  run grep -c -- '--action land-failed' "$LOG"
  assert_output 0
}

@test "a failing PR check stops before the second fetch and the merge, naming the check" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  run grep -c 'pr merge\|^notes' <(not_recorded)
  assert_output 0
  run grep -c '^git fetch' "$LOG"
  assert_output 1
}

@test "no checks reported: polled a bounded number of times, then it lands" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  # A land that lands on the local gate does not take the first-run wait.
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=3 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=5 run "$LAND" 42 --item ship
  assert_success
  assert_line --index 2 'checks: none reported'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 3
}

# ar-1375: #1710's first run came 213s after gh pr create, past the CHECKS_TRIES reads, and a tier-3
# land refused "none reported" for a run that did not exist yet.
@test "no checks reported yet on a land that would refuse: it waits for the head's first run, then lands on its green" {
  for _ in 1 2 3 4; do printf "no checks reported on the 'x' branch\n"; done >"$NOTES_FIXTURE/checks.seq"
  echo green >>"$NOTES_FIXTURE/checks.seq"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_QUEUED_POLL=7 AGENT_LAND_CHECKS_TRIES=2 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=5 run "$LAND" 42 --item ship --ran-checks
  assert_success
  assert_line 'checks: none reported yet, which this land would refuse; waiting up to 5 x 7s for the head'"'"'s first run'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 5
  # One CHECKS_POLL sleep inside CHECKS_TRIES, then the queued cadence.
  run grep '^sleep' "$LOG"
  assert_output "$(printf 'sleep 0\nsleep 7\nsleep 7\nsleep 7')"
}

@test "no first run within the first-run wait: stops at checks after CHECKS_TRIES plus that many reads" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_QUEUED_POLL=7 AGENT_LAND_CHECKS_TRIES=2 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=3 run "$LAND" 42 --item ship --ran-checks
  assert_failure 1
  assert_output --partial 'checks failed: none reported, and --ran-checks lands only on checks that ran green'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 5
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "the #1710 case: a tier-3 land whose PR's first run registers late waits for it and lands on its green" {
  ITEM_PROJECT=agent-runtime item prune 'human'
  printf 'The change.\n\nReview: /code-review high, 2 findings fixed\n' >"$NOTES_FIXTURE/body"
  for _ in 1 2 3; do printf "no checks reported on the 'x' branch\n"; done >"$NOTES_FIXTURE/checks.seq"
  echo green >>"$NOTES_FIXTURE/checks.seq"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_QUEUED_POLL=7 AGENT_LAND_CHECKS_TRIES=2 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=5 run "$LAND" 42 --item prune
  assert_success
  assert_line --partial 'checks: none reported yet, which this land would refuse'
  assert_line 'landed #42'
}

@test "a head with no workflow files gets no first-run wait: a land that refuses none refuses after CHECKS_TRIES" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  touch "$NOTES_FIXTURE/no.workflows"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_QUEUED_POLL=7 AGENT_LAND_CHECKS_TRIES=2 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=5 run "$LAND" 42 --item ship --ran-checks
  assert_failure 1
  assert_output --partial 'checks failed: none reported, and --ran-checks lands only on checks that ran green'
  refute_output --partial 'none reported yet'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
}

@test "Forgejo: a land that would refuse none waits for the head's first status, then stops at checks" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo '{"state":"","statuses":[]}' >"$NOTES_FIXTURE/fj.status"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_QUEUED_POLL=7 AGENT_LAND_CHECKS_TRIES=2 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=2 run "$LAND" 42 --item ship --ran-checks
  assert_failure 1
  assert_output --partial 'checks: none reported yet, which this land would refuse'
  assert_output --partial 'checks failed: none reported, and --ran-checks lands only on checks that ran green'
  run grep -c '^curl GET commits/.*/status' "$LOG"
  assert_output 4
  run grep '^sleep' "$LOG"
  assert_output "$(printf 'sleep 0\nsleep 7\nsleep 7')"
}

@test "no checks reported with --ran-checks (a direct run's landing, which no review backs): stops at checks, as tier 3 does" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship --ran-checks
  assert_failure 1
  assert_output --partial 'checks failed: none reported, and --ran-checks lands only on checks that ran green'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "no checks reported on a base whose protection requires checks: stops at checks, never tries the merge" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  echo '{"required_status_checks":{"strict":false,"contexts":["Checks"]}}' >"$NOTES_FIXTURE/protection.json"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: none reported on the head, and origin/main requires checks'
  run grep -c '^gh pr merge' "$LOG"
  assert_output 0
}

@test "no checks reported on a base whose ruleset requires checks: stops at checks without reading protection" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  echo '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"Checks"}]}}]' >"$NOTES_FIXTURE/rules.json"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'origin/main requires checks, so GitHub would refuse the merge'
  run grep -c 'branches/main/protection\|^gh pr merge' "$LOG"
  assert_output 0
}

@test "no checks reported on a base that requires up-to-date branches but names no check: it lands" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  echo '{"required_status_checks":{"strict":true,"contexts":[],"checks":[]}}' >"$NOTES_FIXTURE/protection.json"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_success
  assert_line --index 2 'checks: none reported'
}

# The tier-3 gate rides on the item, not on how it was queued: a session's `agent-queue add` on a
# harness project skips the judge, so its untiered item still needs review and checks that ran.
@test "tier 3: a hand-added cleanup item on agent-runtime needs a Review: line and green checks to merge" {
  ITEM_PROJECT=agent-runtime item prune 'human'
  run "$LAND" 42 --item prune
  assert_failure 1
  assert_output --partial 'review failed: tier-3 item prune: no "Review: /code-review <level>, <what it found and what you did>" line in the PR body'
  run grep -c 'pr checks\|pr merge' "$LOG"
  assert_output 0

  # A Review: line that names no /code-review pass, or says n/a, is no review.
  for line in 'Review: n/a' 'Review: /code-review high, n/a' 'Review: /code-review high,' 'Review: looked at it'; do
    printf 'The change.\n\n%s\n' "$line" >"$NOTES_FIXTURE/body"
    run "$LAND" 42 --item prune
    assert_failure 1
    assert_output --partial "review failed: tier-3 item prune: no \"Review: /code-review <level>"
    assert_output --partial "(found: $line)"
  done
  run grep -c 'pr merge' "$LOG"
  assert_output 0

  # A Review: line, but no checks ever ran: the local gate is not enough for tier 3.
  printf 'The change.\n\nReview: /code-review high, 2 findings fixed\n' >"$NOTES_FIXTURE/body"
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  : >"$LOG"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item prune
  assert_failure 1
  assert_output --partial 'review: present (tier 3)'
  assert_output --partial 'checks failed: none reported, and a tier-3 item lands only on checks that ran green'
  run grep -c 'pr merge' "$LOG"
  assert_output 0

  # Review plus green checks: it lands.
  rm "$NOTES_FIXTURE/checks.out"
  run "$LAND" 42 --item prune
  assert_success
  assert_output --partial 'checks: green'
  assert_output --partial 'merge: #42 MERGED'
}

@test "shape: a clean change prints shape: clean and measures from the merge-base" {
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'shape: clean'
  run grep -c "^shape-grow 5eedbase5eedbase HEAD$" "$LOG"
  assert_output 1
}

@test "shape: a long function that got longer stops the landing before the checks, naming it" {
  printf 'a.py:10 decide 247->269\nb.sh:3 run 0->151\n' >"$NOTES_FIXTURE/shape.out"
  printf '1\n' >"$NOTES_FIXTURE/shape.rc"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: long functions got longer: a.py:10 decide 247->269; b.sh:3 run 0->151. Extract the new logic as a pure function (inputs in, result out)'
  run grep -c 'pr checks\|pr merge' "$LOG"
  assert_output 0
  # A Split: line naming no row id is not one.
  printf 'The change.\n\nSplit: later\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed:'
}

@test "shape: a Split: line naming an open row that names each function lets it land" {
  printf 'a.py:10 Gov.decide 247->269\nb.rs:4 handle#2 160->170\n' >"$NOTES_FIXTURE/shape.out"
  printf '1\n' >"$NOTES_FIXTURE/shape.rc"
  mkdir -p "$HOME/.notes/lab/projects/current/x"
  printf -- '- [ ] refactor(gov): split decide and handle #of/hc-1 <!-- id:hc-1204 filed:2026-11-18 tier:backlog -->\n' >"$HOME/.notes/lab/projects/current/x/README.md"
  printf 'The change.\n\nSplit: hc-1204\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'shape: grows, split owed by hc-1204: a.py:10 Gov.decide 247->269; b.rs:4 handle#2 160->170'
  assert_output --partial 'merge: #42 MERGED'
}

@test "shape: a Split: id that is no row, a done row, or a row missing a function is refused" {
  printf 'a.py:10 decide 247->269\nb.sh:3 run 0->151\n' >"$NOTES_FIXTURE/shape.out"
  printf '1\n' >"$NOTES_FIXTURE/shape.rc"
  mkdir -p "$HOME/.notes/lab/projects/current/x"
  printf -- '- [x] refactor: split decide and run <!-- id:hc-7 -->\n- [ ] refactor: split decide, rerun later <!-- id:hc-8 -->\n- [ ] refactor: split decide and run <!-- id:ar-10 -->\n' >"$HOME/.notes/lab/projects/current/x/README.md"
  printf 'The change.\n\nSplit: ar-1\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: Split: ar-1 is not an open row on any sheet under ~/.notes/lab'
  printf 'The change.\n\nSplit: hc-7\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: Split: hc-7 is not an open row'
  printf 'The change.\n\nSplit: hc-8\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: Split: hc-8 does not name run:'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "shape: a shape-grow error stops the landing instead of passing it" {
  printf 'shape-grow: git diff origin/main HEAD: bad revision\n' >"$NOTES_FIXTURE/shape.out"
  printf '2\n' >"$NOTES_FIXTURE/shape.rc"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: shape-grow 5eedbase5eedbase HEAD: shape-grow: git diff origin/main HEAD: bad revision'
}

@test "tier 3: a playground fix(ci) item the tier-3 gate queued is refused without a Review: line, and lands with one and green checks" {
  ITEM_PROJECT=unity-core-playground item fix-ci-probe 'human'
  agent-queue set fix-ci-probe tags=tier3 >/dev/null
  run "$LAND" 42 --item fix-ci-probe
  assert_failure 1
  assert_output --partial 'review failed: tier-3 item fix-ci-probe: no "Review: /code-review <level>'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
  printf 'fix(ci): retry the flaky runner probe\n\nReview: /code-review high, 1 finding fixed\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item fix-ci-probe
  assert_success
  assert_output --partial 'review: present (tier 3)'
  assert_output --partial 'checks: green'
  assert_output --partial 'merge: #42 MERGED'
}

@test "tier 3: an item tagged tier1 on agent-runtime, or an untiered one elsewhere, lands without a Review: line" {
  ITEM_PROJECT=agent-runtime item small 'human'
  agent-queue set small tags=tier1 >/dev/null
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item small
  assert_success
  refute_output --partial 'review:'
  assert_output --partial 'checks: none reported'
}

@test "tier 3: item-tier reads the dispatcher's conf, so a DISPATCH_CLEANUP_PROJECTS override there moves the gate" {
  dispatch_conf 'DISPATCH_CLEANUP_PROJECTS="dotfiles"'
  item mine 'human'
  run "$LAND" 42 --item mine
  assert_failure 1
  assert_output --partial 'review failed: tier-3 item mine'
  ITEM_PROJECT=agent-runtime item theirs 'human'
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item theirs
  assert_success
  refute_output --partial 'review:'
}

@test "no checks reported while an Actions run is queued: it keeps waiting past the bound" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  printf '1\n1\n1\n' >"$NOTES_FIXTURE/runs.queued"
  printf '#!/bin/sh\necho "sleep $1" >>"$NOTES_FIXTURE/calls.log"\n' >"$SANDBOX/bin/sleep"
  chmod +x "$SANDBOX/bin/sleep"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_success
  # 3 polls see a queued run (the bound never counts), then 2 more see none
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 5
  # a queued run is re-read a minute apart, not at the no-checks cadence (ar-1345)
  run grep '^sleep' "$LOG"
  assert_output $'sleep 60\nsleep 60\nsleep 60\nsleep 0'
}

# gh's watch exits 0 when the only Checks is a cancelled run, while the newer run on the same head
# has no check yet; GitHub then refused the merge BLOCKED (unity-core-playground#2166).
CANCELLED='[{"name":"Checks","bucket":"cancel","workflow":"Checks"}]'
fake_sleep() {
  printf '#!/bin/sh\necho "sleep $1" >>"$NOTES_FIXTURE/calls.log"\n' >"$SANDBOX/bin/sleep"
  chmod +x "$SANDBOX/bin/sleep"
}

@test "a cancelled check while a newer run of its workflow goes on: it waits, then lands on that run's green" {
  printf '%s\n' "$CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  printf '%s\n' '[{"status":"in_progress","workflowName":"Checks"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: cancelled: Checks; waiting on the newer run of its workflow on the head'
  assert_line 'checks: green'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep '^sleep' "$LOG"
  assert_output 'sleep 60'
}

@test "a cancelled check with no run of its workflow left: read a bounded number of times, then stops at checks, never merges" {
  printf '%s\n' "$CANCELLED" "$CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  # an open run of another workflow is not the cancelled check's replacement
  printf '%s\n' '[{"status":"queued","workflowName":"Deploy"}]' '[{"status":"queued","workflowName":"Deploy"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: cancelled: Checks, and no run of its workflow is left on the head to replace it'
  refute_line 'checks: green'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a cancelled check whose replacement registers during the bounded reads: it lands on that run's green" {
  printf '%s\n' "$CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=3 run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
  run grep '^sleep' "$LOG"
  assert_output 'sleep 0'
}

# A PR opened and pushed to in the same second got two pull_request runs on one head; concurrency
# cancelled the older, whose gate failed on its cancelled needs and whose matrix job, cancelled before
# it expanded, kept its template name, so gh still listed it after the newer run went green
# (dotfiles#2437 runs 44346646978 and 44346649779, 2026-11-18, ar-3095).
TWIN_CANCELLED='[{"name":"fast tier (${{ matrix.tier }} ${{ matrix.shard }})","bucket":"cancel","workflow":"shell tests"}]'
twin_entry() { printf '{"name":"%s","workflowName":"%s","status":"COMPLETED","conclusion":"%s","detailsUrl":"https://github.com/o/r/actions/runs/%s/job/%s"}' "$@"; }   # <name> <workflow> <conclusion> <run> <job>
twin_rollup() { printf '{"statusCheckRollup":[%s]}\n' "$(IFS=,; echo "$*")" >"$NOTES_FIXTURE/checks.rollup"; }
TWIN_TEMPLATE=$(twin_entry 'fast tier (${{ matrix.tier }} ${{ matrix.shard }})' 'shell tests' CANCELLED 100 7)
TWIN_OLD_GATE=$(twin_entry gate 'shell tests' FAILURE 100 8)
TWIN_NEW_GATE=$(twin_entry gate 'shell tests' SUCCESS 101 9)
TWIN_NEW_FAST=$(twin_entry 'fast tier (unit 1)' 'shell tests' SUCCESS 101 10)
@test "a cancelled check of an older run of its workflow on the head is no verdict: it lands on the newer run's green (ar-3095)" {
  printf '%s\n' "$TWIN_CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  twin_rollup "$TWIN_TEMPLATE" "$TWIN_OLD_GATE" "$TWIN_NEW_GATE" "$TWIN_NEW_FAST"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: green (cancelled: fast tier (${{ matrix.tier }} ${{ matrix.shard }}), a matrix job of an older run of its workflow on the head)'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 1
  run grep -c '^sleep' "$LOG"
  assert_output 0
}

@test "a cancelled check of its workflow's newest run on the head stays the verdict, whatever another workflow's newer run did (ar-3095)" {
  printf '%s\n' "$TWIN_CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  twin_rollup "$TWIN_TEMPLATE" "$(twin_entry 'fast tier (unit 1)' 'shell tests' SUCCESS 100 11)" "$(twin_entry deploy Deploy SUCCESS 101 12)"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: cancelled: fast tier (${{ matrix.tier }} ${{ matrix.shard }}), and no run of its workflow is left on the head to replace it'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a cancelled matrix job of an older run whose newer run has no job matching its template stays the verdict (ar-3095)" {
  printf '%s\n' "$TWIN_CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  # the newer run is another event's, with only its gate: nothing in it replaced the matrix job
  twin_rollup "$TWIN_TEMPLATE" "$TWIN_NEW_GATE" "$(twin_entry 'fast tierX' 'shell tests' SUCCESS 101 13)"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: cancelled: fast tier (${{ matrix.tier }} ${{ matrix.shard }}), and no run of its workflow is left on the head'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a cancelled check the rollup does not list is never green on the rollup (ar-3095)" {
  printf '%s\n' '[{"name":"lint","bucket":"cancel","workflow":"shell tests"}]' >"$NOTES_FIXTURE/checks.cancelled"
  twin_rollup "$TWIN_NEW_GATE" "$TWIN_NEW_FAST"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: cancelled: lint, and no run of its workflow is left on the head'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "after a watch timeout, the older twin run's cancelled jobs and failed gate are no verdict (ar-3095)" {
  twin_rollup "$TWIN_TEMPLATE" "$TWIN_OLD_GATE" "$TWIN_NEW_GATE" "$TWIN_NEW_FAST"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: green'
  assert_line 'landed #42'
}

@test "after a watch timeout, a failed check of an older run that no newer entry shares a name with stays red (ar-3095)" {
  twin_rollup "$(twin_entry 'only in the old run' 'shell tests' FAILURE 100 7)" "$TWIN_NEW_GATE" "$TWIN_NEW_FAST"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: only in the old run'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

# The edit that adds the gate line re-runs Checks; a watch read seconds later still saw the old red,
# and unity-core-playground#2492 gave its landing slot back (2026-11-21, ar-3447).
STALE='[{"name":"Checks","bucket":"fail","workflow":"Checks","event":"pull_request","completedAt":"2026-11-21T15:05:34Z"}]'
@test "a failed check with a run of its workflow and event created after it (startedAt still zero): it waits, then lands on that run's green" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.seq"
  echo green >>"$NOTES_FIXTURE/checks.seq"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' "$STALE" >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' '[{"status":"queued","workflowName":"Checks","event":"pull_request","createdAt":"2026-11-21T15:32:03Z","startedAt":"0001-01-01T00:00:00Z"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: failed: Checks; waiting on the newer run of its workflow on the head'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep '^sleep' "$LOG"
  assert_output 'sleep 60'
}

# The Item-line edit re-ran Checks while the gate-line edit's run was still cancelling: the re-run opened
# 28s before the cancelled run's aggregate Checks failed, so only its run id says it is newer
# (unity-core-playground#3108, 2026-11-21 22:25 local, so 06:25Z on the 22nd, ar-2940).
STALE_LINKED='[{"name":"Checks","bucket":"fail","workflow":"Checks","event":"pull_request","completedAt":"2026-11-22T06:26:12Z","link":"https://github.com/o/r/actions/runs/44993658091/job/137120075783"}]'
@test "a failed check with a newer run of its workflow and event opened before it failed: the higher run id waits, then lands on that run's green" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.seq"
  echo green >>"$NOTES_FIXTURE/checks.seq"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' "$STALE_LINKED" >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' '[{"databaseId":44993676563,"status":"in_progress","workflowName":"Checks","event":"pull_request","createdAt":"2026-11-22T06:25:44Z","startedAt":"2026-11-22T06:25:44Z"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: failed: Checks; waiting on the newer run of its workflow on the head'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
}

@test "a failed check whose only open run is the one its link names: the run id is no newer run, it stops at checks" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' "$STALE_LINKED" >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' '[{"databaseId":44993658091,"status":"in_progress","workflowName":"Checks","event":"pull_request","createdAt":"2026-11-22T06:25:30Z","startedAt":"2026-11-22T06:25:30Z"},{"databaseId":44993700000,"status":"queued","workflowName":"Checks","event":"schedule","createdAt":"2026-11-22T06:25:50Z","startedAt":"2026-11-22T06:25:50Z"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  refute_output --partial 'waiting on the newer run'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a failed check with no Actions run in its link: a higher-id open run created before it is no newer run, it stops at checks" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' '[{"name":"Checks","bucket":"fail","workflow":"Checks","event":"pull_request","completedAt":"2026-11-22T06:26:12Z","link":""}]' >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' '[{"databaseId":44993676563,"status":"in_progress","workflowName":"Checks","event":"pull_request","createdAt":"2026-11-22T06:25:44Z","startedAt":"2026-11-22T06:25:44Z"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  refute_output --partial 'waiting on the newer run'
}

@test "a failed check whose open runs are the one it failed in, another event's or another workflow's: it stops at checks, never merges" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' "$STALE" >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' '[{"status":"in_progress","workflowName":"Checks","event":"pull_request","createdAt":"2026-11-21T15:02:38Z","startedAt":"2026-11-21T15:02:38Z"},{"status":"queued","workflowName":"Checks","event":"schedule","createdAt":"2026-11-21T15:10:00Z","startedAt":"2026-11-21T15:10:00Z"},{"status":"queued","workflowName":"Tests","event":"pull_request","createdAt":"2026-11-21T15:32:03Z","startedAt":"2026-11-21T15:32:03Z"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  refute_output --partial 'waiting on the newer run'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 1
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a failed read of the head's runs behind a failed check: a lost connection reads again, any other error stops at checks" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.seq"
  echo green >>"$NOTES_FIXTURE/checks.seq"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' "$STALE" >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' 'ERR gh: Server Error (HTTP 502)' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: lost the connection to the API (1 of 5 retries), reading again'
  assert_line 'landed #42'
  : >"$LOG"
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf '%s\n' 'ERR gh: API rate limit exceeded (HTTP 403)' >"$NOTES_FIXTURE/runs.open"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks (reading the runs on the head: gh: API rate limit exceeded (HTTP 403))'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a failed read of the cancelled checks is never green: a lost connection reads again, any other error stops at checks" {
  printf '%s\n' 'ERR gh: Server Error (HTTP 502)' >"$NOTES_FIXTURE/checks.cancelled"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: lost the connection to the API (1 of 5 retries), reading again'
  assert_line 'landed #42'
  : >"$LOG"
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  printf '%s\n' 'ERR gh: API rate limit exceeded (HTTP 403)' >"$NOTES_FIXTURE/checks.cancelled"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: reading the cancelled checks: gh: API rate limit exceeded (HTTP 403)'
  refute_line 'checks: green'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "--plan ticks exactly the named phase" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "6. agent-land"
  assert_success
  run cat "$PLAN"
  assert_output - <<'EOF'
## Phases

- [x] 1. done already (#1)
- [x] 6. agent-land (#42)
- [ ] 7. gate-then-land
- [ ] 6b. not this one
EOF
}

@test "the plan's rows: close with the PR's proof on its last phase only, each on its own board and lane" {
  printf '%s\n' '# plan' 'epic: ar-1' 'rows: ucp-134, AR-9 zz-77' '' '## Phases' '' '- [ ] 1. first' '- [ ] 2. last' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"},
    {profile: "personal", project: "agent-runtime", lane: "agent", id: "ar-9", state: "doing"},
    {profile: "personal", project: "dotfiles", lane: "agent", id: "ar-1", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item one 'board:dotfiles:first' agent
  run "$LAND" 42 --item one --plan "$PLAN" --phase "1. first"
  assert_success
  refute_output --partial 'rows:'
  run grep -c 'done ucp-134\|done ar-9' "$LOG"
  assert_output 0
  item two 'board:dotfiles:last' agent
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  : >"$LOG"
  run "$LAND" 42 --item two --plan "$PLAN" --phase "2. last"
  assert_success
  assert_line 'rows: closed ar-9 on agent-runtime'
  assert_line 'rows: closed ucp-134 on game'
  assert_line 'rows: zz-77 is not one open row on any board, left as is'
  assert_line --index -1 'landed #42'
  run grep -E 'done (ucp-134|ar-9|ar-1)' "$LOG"
  assert_output - <<'EOF2'
notes --profile personal ptask agent-runtime --agent done ar-9 --proof pr:o/r#42 commit:fedcba987654
notes --profile bnb ptask game done ucp-134 --proof pr:o/r#42 commit:fedcba987654
EOF2
}

@test "a phase that takes a row closes it with its own PR, not the plan's last phase; dry-run names it" {
  printf '%s\n' '# plan' '' '## Phases' '' '- [ ] 1. first (independent), takes board row ucp-134' '- [ ] 2. last' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "1. first" --dry-run
  assert_line 'rows: close ucp-134 with pr:42, the rows the phase takes'
  # NEGATIVE CONTROL: the phase that takes nothing closes nothing.
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last" --dry-run
  refute_output --partial 'rows:'
  item one 'board:dotfiles:first' agent
  run "$LAND" 42 --item one --plan "$PLAN" --phase "1. first"
  assert_success
  assert_line 'rows: closed ucp-134 on game'
  run grep -E 'done ucp-134' "$LOG"
  assert_output 'notes --profile bnb ptask game done ucp-134 --proof pr:o/r#42 commit:fedcba987654'
  # A real landing of a phase with no marker still ticks it (phase_takes must not fail on no match).
  item two 'board:dotfiles:last' agent
  run "$LAND" 43 --item two --plan "$PLAN" --phase "2. last"
  assert_success
  assert_line 'plan: ticked "2. last"'
  assert_line --index -1 'landed #43'
}

@test "a row another open item still works stays open for that item's landing (ar-1793)" {
  item twin 'board:dotfiles:ship it' agent
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'board: left "ship it" open, twin still works it (its landing closes it; if it is dropped: notes ptask dotfiles --agent done ship it --proof pr:o/r#42 commit:fedcba987654)'
  assert_line --index -1 'landed #42'
  run board_calls
  assert_output ''
  # NEGATIVE CONTROL: the last item on the row to land closes it.
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item twin
  assert_success
  assert_line 'board: closed "ship it" with pr:o/r#42 commit:fedcba987654'
  run board_calls
  assert_output 'notes ptask dotfiles --agent done ship it --proof pr:o/r#42 commit:fedcba987654'
}

@test "a plan or phase row another open item still works stays open; the rest close (ar-1793)" {
  printf '%s\n' '# plan' 'rows: ucp-134 ar-9' '' '## Phases' '' '- [ ] 1. only' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"},
    {profile: "personal", project: "agent-runtime", lane: "agent", id: "ar-9", state: "doing"}]}' >"$NOTES_FIXTURE/board.json"
  item fixer 'board:game:UCP-134' human bnb
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "1. only"
  assert_success
  assert_line 'rows: ucp-134 left open, fixer still works it (if it is dropped: notes --profile bnb ptask game done ucp-134 --proof pr:o/r#42)'
  assert_line 'rows: closed ar-9 on agent-runtime'
  run grep -E 'done (ucp-134|ar-9)' "$LOG"
  assert_output 'notes --profile personal ptask agent-runtime --agent done ar-9 --proof pr:o/r#42 commit:fedcba987654'
}

@test "a queue that cannot be read past the merge leaves the rows open with the command, and the plan still ticks (ar-1793)" {
  printf '%s\n' '# plan' 'rows: ar-9' '' '## Phases' '' '- [ ] 1. only' >"$PLAN"
  jq -n '{rows: [{profile: "personal", project: "agent-runtime", lane: "agent", id: "ar-9", state: "doing"}]}' >"$NOTES_FIXTURE/board.json"
  mv "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/agent-queue.real"
  printf '%s\n' '#!/usr/bin/env bash' '[ "$1" != list ] || exit 1' 'exec "${0%/*}/agent-queue.real" "$@"' >"$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-queue"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "1. only"
  assert_success
  assert_line 'board: agent-queue list failed, so "ship it" is not known free of another open item; close by hand: notes ptask dotfiles --agent done ship it --proof pr:o/r#42 commit:fedcba987654'
  assert_line 'plan: ticked "1. only"'
  assert_line 'rows: agent-queue list failed, so no row is known free of another open item; close by hand: ar-9'
  assert_line --index -1 'landed #42'
  run grep -c ' done ' <(board_calls)
  assert_output 0
}

@test "the plan's rows: a deferred phase leaves them open; --dry-run names them only on the last phase" {
  printf '%s\n' 'rows: ucp-134' '## Phases' '- [ ] 1. first' '- [ ] 2. last' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "1. first" --dry-run
  refute_output --partial 'rows:'
  sed -i 's/^- \[ \] 1. first/- [x] 1. first (#41)/' "$PLAN"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last" --dry-run
  assert_line 'rows: close ucp-134 with pr:42, the plan'"'"'s last phase'
  sed -i 's/^- \[x\] 1. first (#41)/- [-] 1. first: deferred, ar-2/' "$PLAN"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last"
  assert_success
  assert_line 'rows: left open, the plan deferred a phase: ucp-134'
  run grep -c 'done ucp-134' "$LOG"
  assert_output 0
}

@test "the plan's rows: a superseded plan's last phase does not close them, its other phases are another plan's (ar-3466)" {
  printf '%s\n' '# Plan' '' 'Superseded by #7' 'rows: ucp-134' '## Phases' '- [ ] 1. first' '- [ ] 2. last' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last" --dry-run
  refute_output --partial 'rows: close ucp-134'
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last"
  assert_success
  assert_line 'rows: left open, the plan is superseded: ucp-134'
}

@test "the plan's rows: a board step that fails is a line with the command, and the landing still finishes" {
  printf '%s\n' 'rows: ucp-134' '## Phases' '- [ ] 6. agent-land' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  cat >"$SANDBOX/bin/notes" <<EOF2
#!/usr/bin/env bash
case "\$*" in *'done ucp-134'*) echo 'no open row ucp-134' >&2; exit 1 ;; esac
exec bash "$REPO_ROOT/tests/helpers/stubs/notes" "\$@"
EOF2
  chmod +x "$SANDBOX/bin/notes"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "6. agent-land"
  assert_success
  assert_line 'rows: ucp-134 not closed (no open row ucp-134): notes --profile bnb ptask game done ucp-134 --proof pr:o/r#42'
  assert_line --index -1 'landed #42'
}

@test "a phase that matches no unchecked line is refused before anything runs" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "9. missing"
  assert_failure 2
  assert_output --partial '0 unchecked lines'
  run ran
  assert_output ''
}

@test "--dry-run prints every step and runs nothing" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "6. agent-land" --dry-run
  assert_success
  assert_line --index 0 --partial 'item-line: gh pr view 42 --json body, then gh pr edit 42 --body-file -'
  assert_line --index 1 --partial 'head: git rev-parse HEAD must equal the PR'
  assert_line --index 2 --partial 'review: fleet-dispatch item-tier ship'
  assert_line --index 3 --partial 'shape: shape-grow $(git merge-base HEAD origin/<base>) HEAD'
  assert_line --index 4 --partial 'checks: gh pr checks 42 --watch'
  assert_line --index 5 --partial 'fetch: git fetch origin'
  assert_line --index 6 --partial 'validate: gh api repos/<owner>/<repo>/pulls/42/files | judge_work_level'
  assert_line --index 7 --partial 'merge: gh pr merge 42 --squash --match-head-commit'
  assert_line --index 8 --partial 'body: gh pr view 42 --json body | comms-lint --channel pr-body -'
  assert_line --index 9 --partial 'proof: gh pr view 42 --json mergeCommit'
  assert_line --index 10 --partial 'live: dotfiles-autopull --now .'
  assert_line --index 11 --partial 'prs: schedules-sync sync-prs <owner>/<repo>'
  assert_line --index 12 --partial 'split: gh search prs --owner <owner> --state open --match body -- "Item: ship"'
  assert_line --index 13 'item: agent-queue set ship pr=42 merged=<sha> partial= beside earlier PRs && gh api repos/<owner>/<repo>/pulls/42/files | agent-queue attribute ship && agent-queue move ship done --status ok'
  assert_line --index 14 'board: notes ptask dotfiles --agent done ship it --proof pr:42'
  assert_line --index 15 --partial 'plan: tick'
  run ran
  assert_output ''
  run grep -c '^- \[x\] 6' "$PLAN"
  assert_output 0
}

@test "an already merged PR is recorded without a second merge" {
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item ship
  assert_success
  assert_line --index 1 'merge: #42 already MERGED, recording it'
  run grep -c 'pr merge\|pr checks\|rev-list\|^git merge \|^git push' "$LOG"
  assert_output 0
}

@test "--item: the item gets the PR and moves to done; an item with no row closes none" {
  item tidy-loader
  CLAUDE_CODE_SESSION_ID=sid-l run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line --index 8 'item: tidy-loader done with pr:o/r#42'
  assert_line --index 9 'landed #42'
  run board_calls
  assert_output ''
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr) \(.sessions)"' <<<"$output")" 'done ok o/r#42 sid-l'
}

@test "an item with no row links the row its PR body's Task: line names and closes it on landing" {
  item tidy-loader
  printf 'The change.\nTask: ar-1\n' >"$NOTES_FIXTURE/body"
  jq -n '{rows: [{profile: "personal", project: "dotfiles", lane: "agent", id: "ar-1", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line 'board: closed "ar-1" with pr:o/r#42 commit:fedcba987654'
  assert_line 'landed #42'
  run board_calls
  assert_output --partial 'notes --profile personal ptask dotfiles --agent done ar-1 --proof pr:o/r#42 commit:fedcba987654'
  run jq -r .row <<<"$(agent-queue show tidy-loader --json)"
  assert_output 'dotfiles:ar-1'
}

@test "an item with no row links the row on another project named by Task: in its PR body" {
  item foamy-nyg-p16
  printf 'The change.\nTask: ar-4306\n' >"$NOTES_FIXTURE/body"
  jq -n '{rows: [{profile: "personal", project: "agent-runtime", lane: "agent", id: "ar-4306", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item foamy-nyg-p16
  assert_success
  assert_line 'board: closed "ar-4306" with pr:o/r#42 commit:fedcba987654'
  assert_line 'landed #42'
  run board_calls
  assert_output --partial 'notes --profile personal ptask agent-runtime --agent done ar-4306 --proof pr:o/r#42 commit:fedcba987654'
  run jq -r .row <<<"$(agent-queue show foamy-nyg-p16 --json)"
  assert_output 'agent-runtime:ar-4306'
}

@test "an item with no row whose Task: names no open row lands with nothing linked (ar-4231)" {
  item tidy-loader
  printf 'The change.\nTask: ar-77\n' >"$NOTES_FIXTURE/body"
  jq -n '{rows: [{profile: "personal", project: "dotfiles", lane: "agent", id: "ar-1", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line 'item-row: Task: ar-77 is not one open row on any board, left unlinked'
  assert_line 'landed #42'
  run board_calls
  refute_output --partial ' done '
  run jq -r '.row // ""' <<<"$(agent-queue show tidy-loader --json)"
  assert_output ''
}

@test "a done item with no row links no Task: row on its second PR, since its board step leaves rows to the closing PR (ar-4231)" {
  item tidy-loader
  run "$LAND" 42 --item tidy-loader
  assert_success
  printf 'The change.\nTask: ar-1\n' >"$NOTES_FIXTURE/body"
  jq -n '{rows: [{profile: "personal", project: "dotfiles", lane: "agent", id: "ar-1", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  : >"$LOG"
  echo https://github.com/o/p/pull/552 >"$NOTES_FIXTURE/url"
  echo https://github.com/o/p.git >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 552 --item tidy-loader
  assert_success
  assert_line 'landed #552'
  refute_output --partial 'item-row:'
  run jq -r '.row // ""' <<<"$(agent-queue show tidy-loader --json)"
  assert_output ''
}

@test "an item that already has a row does not link a different row from Task: in the body" {
  printf 'The change.\nTask: ar-1\n' >"$NOTES_FIXTURE/body"
  jq -n '{rows: [{profile: "personal", project: "dotfiles", lane: "agent", id: "ar-1", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'board: closed "ship it" with pr:o/r#42 commit:fedcba987654'
  run jq -r .row <<<"$(agent-queue show ship --json)"
  assert_output 'dotfiles:ship it'
}

@test "a PR URL that names no repo lands with no landed_by, since agent-queue refuses a bare #N there (ar-2779)" {
  item tidy-loader
  echo https://example.test/merge-request/42 >"$NOTES_FIXTURE/url"
  CLAUDE_CODE_SESSION_ID=sid-l run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line 'landed #42'
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.status) \(.landed_by // "none")"' <<<"$output")" 'done ok none'
}

@test "a human item closes the story row agent-queue add filed for it, like a board item" {
  # NEGATIVE CONTROL: before P2 agent-land closed only `from: board:` rows, so this row stayed open.
  item menus human agent bnb
  agent-queue set menus row=db:db-12
  run "$LAND" 42 --item menus
  assert_success
  assert_line --index 9 'board: closed "db-12" with pr:o/r#42 commit:fedcba987654'
  run board_calls
  assert_output 'notes --profile bnb ptask db --agent done db-12 --proof pr:o/r#42 commit:fedcba987654'
}

@test "a row moved to another project's board closes where it sits by id, and the item follows it (ar-2751)" {
  # NEGATIVE CONTROL: agent-land closed on the recorded board only, so ucp-1594, moved to shape-city
  # after its promotion, failed the landing with "no open task matches" (#2836).
  # A closed copy of the id on the old board and a longer id beside it do not count.
  jq -n '{rows: [{profile: "personal", project: "shape-city", lane: "agent", id: "ucp-1594", state: "doing"},
    {profile: "personal", project: "unity-core-playground", lane: "agent", id: "ucp-1594", state: "done"},
    {profile: "personal", project: "unity-core-playground", lane: "agent", id: "ucp-15940", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item cyl 'board:unity-core-playground:ucp-1594'
  run "$LAND" 42 --item cyl
  assert_success
  assert_line 'board: closed "ucp-1594" with pr:o/r#42 commit:fedcba987654, on shape-city, agent lane (recorded on unity-core-playground, agent lane)'
  assert_line 'item: cyl row: shape-city:ucp-1594'
  assert_line --index -1 'landed #42'
  run board_calls
  assert_output 'notes --profile personal ptask shape-city --agent done ucp-1594 --proof pr:o/r#42 commit:fedcba987654'
  run agent-queue show cyl --json
  assert_equal "$(jq -r '"\(.state) \(.row) \(.lane) \(.profile)"' <<<"$output")" 'done shape-city:ucp-1594 agent personal'
}

@test "a row on its recorded board, or on none, closes as recorded and leaves the item's row alone (ar-2751)" {
  jq -n '{rows: [{profile: "bnb", project: "db", lane: "agent", id: "db-12", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item menus human agent bnb
  agent-queue set menus row=db:db-12
  run "$LAND" 42 --item menus
  assert_success
  assert_line 'board: closed "db-12" with pr:o/r#42 commit:fedcba987654'
  refute_output --partial 'row:'
  # No one open row carries the id (two boards do): the recorded board answers, as before.
  jq -n '{rows: [{profile: "bnb", project: "a", lane: "agent", id: "db-13", state: "open"}, {profile: "bnb", project: "b", lane: "agent", id: "db-13", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item soup human agent bnb
  agent-queue set soup row=db:db-13
  : >"$LOG"
  run "$LAND" 42 --item soup
  assert_success
  refute_output --partial 'row:'
  run board_calls
  assert_output 'notes --profile bnb ptask db --agent done db-13 --proof pr:o/r#42 commit:fedcba987654'
  # A row on a lane with no ptask flag of its own (playtest) is not followed: the recorded board answers.
  jq -n '{rows: [{profile: "bnb", project: "db", lane: "playtest", id: "db-15", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item stock human agent bnb
  agent-queue set stock row=db:db-15
  : >"$LOG"
  run "$LAND" 42 --item stock
  assert_success
  refute_output --partial 'row:'
  run board_calls
  assert_output 'notes --profile bnb ptask db --agent done db-15 --proof pr:o/r#42 commit:fedcba987654'
}

@test "a row moved to the human lane of its own board closes there, and the item takes the lane (ar-2751)" {
  jq -n '{rows: [{profile: "bnb", project: "db", lane: "human", id: "db-14", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item stew human agent bnb
  agent-queue set stew row=db:db-14
  run "$LAND" 42 --item stew
  assert_success
  assert_line 'board: closed "db-14" with pr:o/r#42 commit:fedcba987654, on db, human lane (recorded on db, agent lane, profile bnb)'
  run board_calls
  assert_output 'notes --profile bnb ptask db done db-14 --proof pr:o/r#42 commit:fedcba987654'
  run agent-queue show stew --json
  assert_equal "$(jq -r '"\(.row) \(.lane)"' <<<"$output")" 'db:db-14 human'
}

@test "a hand-started session's own item is the record: no --item needed" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item by-hand
  agent-queue set by-hand session=default:dotfiles-agent-9
  printf 'The change.\n\nItem: by-hand\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42
  assert_success
  assert_line --index 8 'item: by-hand done with pr:o/r#42'
  run agent-queue show by-hand --json
  assert_equal "$(jq -r '"\(.state) \(.pr)"' <<<"$output")" 'done o/r#42'
}

@test "two items recording this session are refused before the merge" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item one
  item two
  agent-queue set one session=default:dotfiles-agent-9
  agent-queue set two session=default:dotfiles-agent-9
  rm "$AGENT_QUEUE_DIR"/running/*-ship.md
  run "$LAND" 42
  assert_failure
  assert_output --partial 'pass --item'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "AGENT_QUEUE_ITEM is the default item; a board item closes its own row with lane and profile" {
  item fix-crash 'board:game:fix crash: on load' human bnb
  printf 'The change.\n\nItem: fix-crash\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=fix-crash run "$LAND" 42
  assert_success
  assert_line --index 9 'board: closed "fix crash: on load" with pr:o/r#42 commit:fedcba987654'
  run board_calls
  assert_output 'notes --profile bnb ptask game done fix crash: on load --proof pr:o/r#42 commit:fedcba987654'
}

# repo_map -> a registry where o/r's checkout is the project `tools` and `level` is a game inside repo `game`
repo_map() {
  export PROJECT_MAP_FILE="$SANDBOX/map.json"
  jq -n '{paths: {"/x/r": "tools", "/x/game": "game"}, trackers: {level: {repo: "game", path: "Assets/Level"}, tools: {}}}' >"$PROJECT_MAP_FILE"
}

@test "an item taken from the session refuses a PR in another repo, before anything is touched" {
  repo_map
  ITEM_PROJECT=level item store 'board:level:store page' agent
  AGENT_QUEUE_ITEM=store run "$LAND" 42
  assert_failure 2
  assert_output --partial '#42 is in o/r (tools), and store, taken from $AGENT_QUEUE_ITEM, is a level item in game'
  assert_output --partial 'Pass --item store if this PR is that item'
  run grep -c 'pr edit\|pr checks\|pr merge\|^notes' <(not_recorded)
  assert_output 0
  run agent-queue show store --json
  assert_equal "$(jq -r '.state + " " + (.pr // "")' <<<"$output")" 'running '
}

@test "the same PR lands on that item when --item names it, and an item in the PR's repo needs no --item" {
  repo_map
  ITEM_PROJECT=level item store 'board:level:store page' agent
  AGENT_QUEUE_ITEM=other run "$LAND" 42 --item store
  assert_success
  assert_output --partial 'item: store done with pr:o/r#42'
  ITEM_PROJECT=tools item tool 'board:tools:tool fix' agent
  printf 'https://github.com/o/r/pull/43\n' >"$NOTES_FIXTURE/url"
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  # #43 is another PR, with its own body: #42's carries "Item: store" now.
  printf 'The change and why.\n\nItem: tool\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=tool run "$LAND" 43
  assert_success
  assert_output --partial 'item: tool done with pr:o/r#43'
}

# untouched <slug> -> asserts nothing past the refusal ran: no body edit, check, merge or board write, and the item has no PR
untouched() {
  run grep -c 'pr edit\|pr checks\|pr merge' "$LOG"
  assert_output 0
  run board_calls
  assert_output ''
  run agent-queue show "$1" --json
  assert_equal "$(jq -r '.state + " " + (.pr // "")' <<<"$output")" 'running '
  run grep -c '^Item:' "$NOTES_FIXTURE/body"
  assert_output 0
}

@test "a sibling subagent's item that agent-queue mine returns refuses this PR, which its body does not name (ar-3047)" {
  # home-config #1195, 2026-11-18: two subagents of one coordinator share its session id; one added
  # its item and started agent-land on its PR, and the other's bare agent-land took that item.
  item qualify
  agent-queue claim qualify --sid sid-coord >/dev/null
  agent-queue set qualify open_pr=o/r#41 >/dev/null
  CLAUDE_CODE_SESSION_ID=sid-coord run "$LAND" 42
  assert_failure 2
  assert_output --partial "#42 (o/r#42) may be a side fix, not qualify's work, taken from agent-queue mine: its body has no \"Item: qualify\" line and qualify does not record it."
  untouched qualify
  # NEGATIVE CONTROL: named by --item, the same PR lands on it.
  CLAUDE_CODE_SESSION_ID=sid-coord run "$LAND" 42 --item qualify --partial
  assert_success
}

@test "an item taken from the session refuses a PR whose body names another item, and takes one that names it (ar-3047)" {
  item fix-crash
  item other-item
  printf 'The change.\n\nItem: other-item\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=fix-crash run "$LAND" 42
  assert_failure 2
  assert_output --partial 'its body names its item, other-item. Pass --item other-item for the item #42 is the work of'
  run grep -c 'pr edit\|pr checks\|pr merge\|^notes' <(not_recorded)
  assert_output 0
  # NEGATIVE CONTROL: a body that names this item lands, though its open_pr names an earlier PR.
  agent-queue set fix-crash open_pr=o/r#41 >/dev/null
  printf 'The change.\n\nItem: fix-crash\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=fix-crash run "$LAND" 42
  assert_success
  assert_output --partial 'item: fix-crash done with pr:o/r#42'
}

@test "a side fix in the item's own repo, its body naming no item, does not close the session's item (ar-3970)" {
  # unity-core-playground#2985, 2026-11-20: a coordinator's bare agent-land on an iOS side fix took
  # its overnight release watch from agent-queue mine, stamped "Item:" on the body and closed it.
  item watch-beta 'board:dotfiles:watch the beta cut'
  agent-queue claim watch-beta --sid sid-coord >/dev/null
  printf 'The iOS export fix.\n' >"$NOTES_FIXTURE/body"
  CLAUDE_CODE_SESSION_ID=sid-coord run "$LAND" 42
  assert_failure 2
  assert_output --partial "#42 (o/r#42) may be a side fix, not watch-beta's work, taken from agent-queue mine: its body has no \"Item: watch-beta\" line"
  assert_output --partial 'add that line to the body or pass --item watch-beta; else give it its own item'
  untouched watch-beta
  # A placeholder names no item either.
  printf 'The iOS export fix.\n\nItem: <slug>\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=watch-beta run "$LAND" 42
  assert_failure 2
  assert_output --partial 'taken from $AGENT_QUEUE_ITEM: its body has no "Item: watch-beta" line'
  # NEGATIVE CONTROL: the side fix's own item, named by --item, takes it and the placeholder is rewritten.
  item ios-export
  AGENT_QUEUE_ITEM=watch-beta run "$LAND" 42 --item ios-export
  assert_success
  assert_output --partial 'item: ios-export done with pr:o/r#42'
  run grep -cx 'Item: ios-export' "$NOTES_FIXTURE/body"
  assert_output 1
  run agent-queue show watch-beta --json
  assert_equal "$(jq -r '.state + " " + (.pr // "")' <<<"$output")" 'running '
}

@test "a re-run on the PR the item records as open lands with no Item: line (ar-3047)" {
  item fix-crash
  agent-queue set fix-crash open_pr=o/r#42 >/dev/null
  AGENT_QUEUE_ITEM=fix-crash run "$LAND" 42
  assert_success
  assert_output --partial 'item: fix-crash done with pr:o/r#42'
}

@test "an agent-lane board item closes its row with --agent" {
  item tidy 'board:dotfiles:tidy it' agent
  run "$LAND" 42 --item tidy --dry-run
  assert_success
  assert_line --index 13 'item: agent-queue set tidy pr=42 merged=<sha> partial= beside earlier PRs && gh api repos/<owner>/<repo>/pulls/42/files | agent-queue attribute tidy && agent-queue move tidy done --status ok'
  assert_line --index 14 'board: notes ptask dotfiles --agent done tidy it --proof pr:42'
  run agent-queue show tidy --json
  assert_equal "$(jq -r .state <<<"$output")" running
}

@test "an unknown or finished item is refused before the merge" {
  run "$LAND" 42 --item nope
  assert_failure 2
  assert_output --partial 'no queue item nope'
  item old
  agent-queue move old done --status ok
  run "$LAND" 42 --item old
  assert_failure 2
  assert_output --partial 'queue item old is done ok, not open'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
  run board_calls
  assert_output ''
}

@test "a re-run after a failed board step finds the item done with this PR and closes the row" {
  item fix 'board:game:fix it' human
  mv "$SANDBOX/bin/notes" "$SANDBOX/notes.ok"
  printf '#!/usr/bin/env bash\necho "board locked" >&2; exit 1\n' >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$LAND" 42 --item fix
  assert_failure 1
  assert_output --partial 'board failed: board locked'
  mv "$SANDBOX/notes.ok" "$SANDBOX/bin/notes"
  run "$LAND" 42 --item fix
  assert_success
  assert_line --index 1 'merge: #42 already MERGED, recording it'
  assert_line --index 5 'board: closed "fix it" with pr:o/r#42 commit:fedcba987654'
  echo https://github.com/o/r/pull/43 >"$NOTES_FIXTURE/url"
  run "$LAND" 43 --item fix
  assert_failure 2
  assert_output --partial 'queue item fix is done and already carries o/r#42, and an item carries one PR per repo'
}

@test "a task across two repos lands its second PR on its done item: one PR per repo, row closed once" {
  # NEGATIVE CONTROL: before ar-790 the second landing was refused as "done ok, not open".
  item split 'board:game:split it' human
  CLAUDE_CODE_SESSION_ID=sid-first run "$LAND" 42 --item split
  assert_success
  : >"$LOG"
  echo https://github.com/o/p/pull/552 >"$NOTES_FIXTURE/url"
  echo https://github.com/o/p.git >"$NOTES_FIXTURE/origin.url"
  printf 'abcdef0123456789abcdef0123456789abcdef01\n' >"$NOTES_FIXTURE/merge.oid"
  CLAUDE_CODE_SESSION_ID=sid-second run "$LAND" 552 --item split
  assert_success
  refute_output --partial 'could not record this session'
  assert_line 'item: split done with pr:o/p#552, beside o/r#42'
  assert_line 'board: left to its closing PR, o/r#42 (agent-land on that one closes the row if its board step failed)'
  assert_line 'landed #552'
  run board_calls
  assert_output ''
  run agent-queue show split --json
  assert_equal "$(jq -r .sessions <<<"$output")" 'sid-first sid-second'
  # Which session landed which PR, for the outcomes credit (ar-2779).
  assert_equal "$(jq -r .landed_by <<<"$output")" 'sid-first=o/r#42 sid-second=o/p#552'
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr) \(.merged)"' <<<"$output")" \
    'done ok o/r#42 o/p#552 fedcba9876543210fedcba9876543210fedcba98 abcdef0123456789abcdef0123456789abcdef01'
  # A re-run of either PR records nothing twice; a second PR in a repo the item carries is refused.
  run "$LAND" 552 --item split
  assert_success
  assert_line 'board: left to its closing PR, o/r#42 (agent-land on that one closes the row if its board step failed)'
  run agent-queue show split --json
  assert_equal "$(jq -r .pr <<<"$output")" 'o/r#42 o/p#552'
  echo https://github.com/o/p/pull/553 >"$NOTES_FIXTURE/url"
  run "$LAND" 553 --item split
  assert_failure 2
  assert_output --partial 'queue item split is done and already carries o/p#552, and an item carries one PR per repo'
}

@test "a done item with a bare pr: re-runs on its number and takes no PR from another repo" {
  item legacy
  agent-queue set legacy pr=42 merged=fedcba9876543210fedcba9876543210fedcba98 >/dev/null
  agent-queue move legacy done --status ok >/dev/null
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  touch "$NOTES_FIXTURE/head.foreign"
  run "$LAND" 42 --item legacy
  assert_success
  echo https://github.com/o/p/pull/552 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 552 --item legacy
  assert_failure 2
  assert_output --partial 'done and already carries a bare pr:42, which names no repo'
  run agent-queue show legacy --json
  assert_equal "$(jq -r .pr <<<"$output")" 42
}

@test "a bare number read against the wrong repo: a MERGED PR that is not the item's is refused, nothing recorded or edited" {
  # NEGATIVE CONTROL: before ar-886 this recorded an unrelated o/r#595 on the item (2026-11-07).
  item p3 'board:game:fill the names' human
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  echo https://github.com/o/r/pull/595 >"$NOTES_FIXTURE/url"
  printf 'agent-7\n' >"$NOTES_FIXTURE/head.ref"
  touch "$NOTES_FIXTURE/head.foreign"
  printf 'Item: some-other-item\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 595 --item p3
  assert_failure 1
  assert_output --partial 'match failed: #595 (o/r#595, from agent-7) is merged, and nothing ties it to p3'
  assert_output --partial 'with --repo <owner>/<repo>'
  refute_output --partial 'only its record is left'
  run grep -c '^gh pr edit\|^notes\|^dotfiles-autopull' <(not_recorded)
  assert_output 0
  run agent-queue show p3 --json
  assert_equal "$(jq -r '"\(.state) \(.pr // "-")"' <<<"$output")" 'running -'
}

@test "--supersedes: another session's merged PR lands the item whose own PR it replaced, which leaves pr: (bk-3)" {
  # 2026-11-11 unity-core-playground agent-17 closed #2271 for agent-5's merged #2276, whose body named agent-5's item.
  item other 'board:dotfiles:the other item'
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  touch "$NOTES_FIXTURE/head.foreign"
  printf 'The change.\nItem: other\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'If #42 replaced ship'"'"'s own PR and you closed that one: --supersedes <its number>'
  run "$LAND" 42 --item ship --supersedes 41
  assert_success
  assert_line 'supersedes: #41 closed, replaced by #42'
  assert_line 'landed #42'
  run agent-queue show ship --json
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr)"' <<<"$output")" 'done ok o/r#42'
  run grep -c 'pr edit' "$LOG"
  assert_output 0
  # an item that records its closed PR (a --pr-only run) drops it, so settle_prior does not refuse it
  item ship2 'board:dotfiles:ship it too' agent
  agent-queue set ship2 pr=o/r#41 >/dev/null
  printf '{"state":"CLOSED","headRefOid":"5eed","body":"no item line","createdAt":"2026-11-11T03:00:00Z"}\n' >"$NOTES_FIXTURE/sup.json"
  run "$LAND" 42 --item ship2 --supersedes 41
  assert_success
  run agent-queue show ship2 --json
  assert_equal "$(jq -r '"\(.state) \(.pr) \(.merged | length)"' <<<"$output")" 'done o/r#42 40'
}

@test "--supersedes refuses an open PR to land, and a superseded PR that is open, merged, not the item's or newer than the merge, touching nothing (bk-3)" {
  # NEGATIVE CONTROL: each would record #42 on ship with no tie between them.
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  touch "$NOTES_FIXTURE/head.foreign"
  printf 'Item: other\n' >"$NOTES_FIXTURE/body"
  local args
  for args in 'OPEN|Item: ship|#41 in o/r is OPEN, not closed' 'MERGED|Item: ship|#41 merged, so nothing replaced it' \
              'CLOSED|Item: other|nothing ties #41 to ship' 'CLOSED|Item: ship|#42 merged before #41 was opened|2026-11-12T00:00:00Z'; do
    IFS='|' read -r st b want at <<<"$args"
    jq -nc --arg s "$st" --arg b "$b" --arg at "${at:-2026-11-11T03:00:00Z}" '{state: $s, headRefOid: "5eed", body: $b, createdAt: $at}' >"$NOTES_FIXTURE/sup.json"
    run "$LAND" 42 --item ship --supersedes 41
    assert_failure
    assert_output --partial "$want"
  done
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  rm "$NOTES_FIXTURE/sup.json"
  run "$LAND" 42 --item ship --supersedes 41
  assert_failure
  assert_output --partial '--supersedes takes a merged PR, and #42 is OPEN'
  run grep -c 'pr merge\|pr edit\|^notes' "$LOG"
  assert_output 0
  run agent-queue show ship --json
  assert_equal "$(jq -r '"\(.state) \(.pr // "-")"' <<<"$output")" 'running -'
}

@test "a MERGED PR whose head is not in HEAD is the item's when its body names the item, CRLF or not" {
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  touch "$NOTES_FIXTURE/head.foreign"
  printf 'The change.\r\n\r\nItem: ship\r\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
}

@test "--repo: every gh pr and run call names the repo, and a checkout of another repo is refused before anything is touched" {
  echo https://github.com/o/p/pull/42 >"$NOTES_FIXTURE/url"
  run "$LAND" 42 --repo o/p --item ship
  assert_failure 1
  assert_output --partial 'repo failed: #42 is o/p#42 (--repo), but this checkout'"'"'s origin is o/r: run from a checkout of o/p, or pass --repo o/r for o/r#42'
  run grep -c '^gh pr edit\|^git fetch' "$LOG"
  assert_output 0
  : >"$LOG"
  echo https://github.com/O/P/ >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 42 --repo o/p --item ship
  assert_success
  assert_line 'item: ship done with pr:o/p#42'
  run grep -E '^gh (pr|run) ' "$LOG"
  refute_output --regexp '^gh (pr [a-z]+ 42|run list) (--[a-z]|$)'
  assert_output --partial 'gh pr merge 42 -R o/p --squash'
}

@test "--repo outside a checkout is refused before any gh call or merge (ar-2371)" {
  touch "$NOTES_FIXTURE/no.checkout"
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --repo o/r --item ship
  assert_failure 2
  assert_output --partial 'is not a usable git checkout (fatal: not a git repository)'
  assert_output --partial 'Run it from a checkout of o/r'
  # only the guard's own probe ran: no gh call, no other git call
  run cat "$LOG"
  assert_output 'git rev-parse --show-toplevel'
  # the repo comes from the item's own pr: when --repo is absent
  : >"$LOG"
  agent-queue set ship pr=o/p#42 >/dev/null
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'Run it from a checkout of o/p'
  # a dry run reads no checkout, so it still prints its steps
  run "$LAND" 42 --repo o/r --item ship --dry-run
  assert_success
}

@test "--repo takes <owner>/<repo> only" {
  run "$LAND" 42 --repo o --item ship
  assert_failure 2
  assert_output --partial '--repo takes <owner>/<repo>, not o'
  run cat "$LOG"
  assert_output ''
}

@test "the item's own pr:<owner>/<repo>#N names the repo for a bare number, and makes a MERGED PR its own" {
  item wait1
  agent-queue set wait1 pr=o/p#42 >/dev/null
  agent-queue move wait1 waiting >/dev/null
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/42 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  touch "$NOTES_FIXTURE/head.foreign"
  run "$LAND" 42 --item wait1
  assert_success
  assert_line 'item: wait1 done with pr:o/p#42'
  run grep -c '^gh pr view 42 -R o/p ' "$LOG"
  refute_output 0
  # From a checkout of the other repo, the item's ref still wins and the run is refused there.
  item wait2
  agent-queue set wait2 pr=o/p#43 >/dev/null
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/r.git >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 43 --item wait2
  assert_failure 1
  assert_output --partial "#43 is o/p#43 (the item's pr:), but this checkout's origin is o/r"
}

@test "an item recording the number in two repos needs --repo" {
  item two
  agent-queue set two 'pr=o/r#42 o/p#42' >/dev/null
  run "$LAND" 42 --item two
  assert_failure 2
  assert_output --partial 'queue item two records #42 in o/p o/r: pass --repo <owner>/<repo>'
}

@test "a --partial landing whose proof fails after the merge keeps the partial marker (ar-2904)" {
  touch "$NOTES_FIXTURE/not.ancestor"
  run "$LAND" 42 --item ship --partial
  assert_failure 1
  assert_output --partial 'proof failed: merge_proof: REFUSING'
  run agent-queue show ship --json
  assert_equal "$(jq -r '.partial // ""' <<<"$output")" yes
}

@test "a merge commit not on origin/<base> is refused: the item stays open and no row closes" {
  item fix 'board:game:fix it' human
  touch "$NOTES_FIXTURE/not.ancestor"
  run "$LAND" 42 --item fix
  assert_failure 1
  assert_output --partial 'proof failed: merge_proof: REFUSING'
  run grep -- '--action land-failed' "$LOG"
  assert_output --partial '--why merged, but proof: merge_proof: REFUSING'
  run grep -c '^notes' <(not_recorded)
  assert_output 0
  run agent-queue show fix --json
  assert_equal "$(jq -r '"\(.state) \(.merged // "-")"' <<<"$output")" 'running -'
}

@test "the item records the proven merge commit" {
  CLAUDE_CODE_SESSION_ID=sid-m run "$LAND" 42 --item ship
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '"\(.state) \(.merged)"' <<<"$output")" 'done fedcba9876543210fedcba9876543210fedcba98'
}

@test "no queue item: refused before any gh or git call, naming how to add one" {
  rm "$AGENT_QUEUE_DIR"/running/*-ship.md
  run "$LAND" 42
  assert_failure 2
  assert_output --partial 'no queue item for this session: agent-queue add --running'
  run cat "$LOG"
  assert_output ''
}

@test "--project and --title are gone: the item is the record" {
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_failure 2
  assert_output --partial '--project is gone'
  run cat "$LOG"
  assert_output ''
}

@test "--sheet is gone" {
  run "$LAND" 42 --item ship --sheet
  assert_failure 2
  assert_output --partial 'unknown flag: --sheet'
}

# The real notes against a sandbox vault, because the stubs on both sides of the join would agree
# on a text key too. The CI rust job builds it and sets NOTES_BIN; a stale binary left in target/
# must not fail the Stop tier, so nothing here looks for one.
@test "end to end: a promoted row closes by id after its text was edited" {
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  sheet="$HOME/.notes/lab/projects/current/game/README.md"
  mkdir -p "${sheet%/*}" "$HOME/.config/notes"
  : >"${sheet%/*}/summary.md"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' >"$HOME/.config/notes/config.toml"
  printf '%s\n' '# game' '' 'Version: v1.0.0 #beta' '' '## Inbox' '' '## Tasks' '' '- [ ] fix the crash on load #low' '- [ ] fix the crash on save' >"$sheet"
  export PROJECT_MAP_FILE="$SANDBOX/map.json" NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  unset NOTES_PROFILE
  echo '{"paths": {"/x/game": "game"}, "trackers": {"game": {"code": "gm"}}}' >"$PROJECT_MAP_FILE"

  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --raw '- [ ] fix the crash on load #low'
  assert_success
  assert_output --partial 'queued game: gm-1'
  run agent-queue show gm-1 --json
  assert_equal "$(jq -r '"\(.state) \(.priority) \(.from)"' <<<"$output")" 'queued low board:game:gm-1'
  grep -qF -- '- [/] fix the crash on load #low' "$sheet" || fail "row not started"

  agent-queue move gm-1 running
  sed -i 's/fix the crash on load/stop the load crash/' "$sheet"
  run "$LAND" 42 --item gm-1
  assert_success
  assert_output --partial 'board: closed "gm-1" with pr:o/r#42'
  run agent-queue show gm-1 --json
  assert_equal "$(jq -r .state <<<"$output")" done
  run notes ptask game list
  assert_output --partial 'fix the crash on save'
  refute_output --partial 'stop the load crash'
  grep -qE -- '- \[x\] stop the load crash .*id:gm-1' "$sheet" || fail "the edited row did not close: $(cat "$sheet")"
}

# real_notes_board -- the built notes, and a game project with one epic (gm-1): sets $dir. Skips with no NOTES_BIN.
real_notes_board() {
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  dir="$HOME/.notes/lab/projects/current/game"
  mkdir -p "$dir" "$HOME/.config/notes"
  : >"$dir/summary.md"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' >"$HOME/.config/notes/config.toml"
  printf '%s\n' '# game' '' 'Version: v1.0.0 #beta' '' '## Inbox' '' '## Tasks' '' '- [ ] epic(menu): live menus #size/xl <!-- id:gm-1 -->' >"$dir/README.md"
  export PROJECT_MAP_FILE="$SANDBOX/map.json" NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  export AGENT_QUEUE_PROJECT_MAP="$PROJECT_MAP_FILE"
  unset NOTES_PROFILE
  jq -n '{paths: {"/x/game": "game"}, trackers: {game: {code: "gm", lab: "personal"}}}' >"$PROJECT_MAP_FILE"
}

@test "end to end: a hand item's story is filed started under its epic by add and closed by agent-land" {
  real_notes_board

  run agent-queue add --running --project game --epic gm-1 --slug title "feat(menu): the title screen"
  assert_success
  assert_line 'story gm-2 on the game agent board, under gm-1'
  grep -qE -- '^- \[/\] feat\(menu\): the title screen #of/gm-1 .*id:gm-2' "$dir/agent/README.md" ||
    fail "no started story: $(cat "$dir/agent/README.md")"

  run "$LAND" 42 --item title
  assert_success
  assert_output --partial 'board: closed "gm-2" with pr:o/r#42'
  grep -qE -- '^- \[x\] feat\(menu\): the title screen .*gm-2' "$dir/agent/README.md" ||
    fail "the story did not close: $(cat "$dir/agent/README.md")"
}

@test "end to end: --row links a filed row, files no second one, and agent-land closes it" {
  real_notes_board
  notes --profile personal ptask game --agent add -- 'fix(menu): the back button #size/s' >/dev/null
  run agent-queue add --running --project game --row gm-2 --slug back "work the filed row"
  assert_success
  grep -qE -- '^- \[/\] fix\(menu\): the back button .*id:gm-2' "$dir/agent/README.md" ||
    fail "the row was not started: $(cat "$dir/agent/README.md")"
  run "$LAND" 42 --item back
  assert_success
  assert_output --partial 'board: closed "gm-2" with pr:o/r#42'
  grep -qE -- '^- \[x\] fix\(menu\): the back button .*gm-2' "$dir/agent/README.md" ||
    fail "the linked row did not close: $(cat "$dir/agent/README.md")"
  [ "$(grep -c 'back button' "$dir/agent/README.md")" = 1 ] || fail "a second row was filed"

  # NEGATIVE CONTROL: the row is closed now, so the real notes refuses it and nothing is written.
  run agent-queue add --running --project game --row gm-2 --slug again "work it twice"
  assert_failure
  assert_output --partial '--row gm-2: not an open row on the game agent board'
  run agent-queue show again --json
  assert_failure
}

@test "end to end: a title naming a filed row works it, and the plan's rows: close with the last phase" {
  real_notes_board
  notes --profile personal ptask game --agent add -- 'fix(menu): the back button #size/s' >/dev/null
  printf '%s\n' '- [ ] feat(menu): a settings page the human asked for #size/s <!-- id:gm-9 -->' >>"$dir/README.md"
  run agent-queue add --running --project game --slug back "gm-2: fix the back button"
  assert_success
  assert_output --partial 'back works row gm-2, which its title names'
  [ "$(grep -c 'back button' "$dir/agent/README.md")" = 1 ] || fail "a second row was filed: $(cat "$dir/agent/README.md")"
  printf '%s\n' '# plan' 'rows: gm-9' '' '## Phases' '' '- [ ] 1. the back button' >"$PLAN"
  run "$LAND" 42 --item back --plan "$PLAN" --phase "1. the back button"
  assert_success
  assert_output --partial 'board: closed "gm-2" with pr:o/r#42'
  assert_line 'rows: closed gm-9 on game'
  grep -qE -- '^- \[x\] feat\(menu\): a settings page .*gm-9' "$dir/README.md" ||
    fail "the plan's row did not close: $(cat "$dir/README.md")"
  grep -qE -- '^- \[ \] epic\(menu\): live menus' "$dir/README.md" || fail "the epic closed: $(cat "$dir/README.md")"
}

@test "the PR's changed files credit the item to the game whose path owns the most" {
  export AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  jq -n '{paths: {"/x/game": "game"}, trackers: {"arena": {repo: "game", path: "Assets/Arena"},
    "level": {repo: "game", path: "Assets/Level"}}}' >"$AGENT_QUEUE_PROJECT_MAP"
  item played
  sed -i 's/^project: dotfiles$/project: game/' "$AGENT_QUEUE_DIR/running/20261103-100000-played.md"
  printf '%s\n' Assets/Arena/A.cs Assets/Arena/B.cs Assets/Level/L.cs Assets/Shared/S.cs >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item played
  assert_success
  assert_line 'item: played done with pr:o/r#42, credited to arena (touches arena level)'
  run agent-queue show played --json
  assert_equal "$(jq -r '"\(.state) \(.project) \(.touches)"' <<<"$output")" 'done arena arena level'
}

@test "a hint gh writes to stderr on success reads into no PR field and no attributed file" {
  # gh 2.105 prints an "event listen" hint on every successful pr view and api call; read with the
  # PR's fields it put "hint:" where the state was and stopped the landing at head (2026-11-19).
  touch "$NOTES_FIXTURE/hint"
  export AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  jq -n '{paths: {"/x/game": "game"}, trackers: {"arena": {repo: "game", path: "Assets/Arena"}}}' >"$AGENT_QUEUE_PROJECT_MAP"
  item hinted
  sed -i 's/^project: dotfiles$/project: game/' "$AGENT_QUEUE_DIR/running/20261103-100000-hinted.md"
  printf '%s\n' Assets/Arena/A.cs >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item hinted
  assert_success
  assert_line 'item: hinted done with pr:o/r#42, credited to arena (touches arena)'
  assert_line 'landed #42'
  refute_output --partial 'hint:'
}

@test "a diff too big for GitHub to list is read from git (playground #3231)" {
  export AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  jq -n '{paths: {"/x/game": "game"}, trackers: {"arena": {repo: "game", path: "Assets/Arena"}}}' >"$AGENT_QUEUE_PROJECT_MAP"
  item huge
  sed -i 's/^project: dotfiles$/project: game/' "$AGENT_QUEUE_DIR/running/20261103-100000-huge.md"
  touch "$NOTES_FIXTURE/files.toobig"
  printf 'M\tAssets/Arena/Big.unity\nR087\tdocs/old.md\tdocs/new.md\n' >"$NOTES_FIXTURE/diff.status"
  run "$LAND" 42 --item huge
  assert_success
  assert_line 'item: huge done with pr:o/r#42, credited to arena (touches arena)'
  assert_line 'landed #42'
  run grep -c '^git fetch -q origin 5eedbase5eedbase 0123456789abcdef$' "$LOG"
  assert_output 1
  run grep -c '^git diff --name-status -M 5eedbase5eedbase...0123456789abcdef$' "$LOG"
  assert_output 1
}

@test "files that cannot be read leave the item's project and never fail the landing" {
  item unread
  touch "$NOTES_FIXTURE/files.fail"
  # Already merged: on an open PR unreadable files refuse the merge (validate_gate, its own case).
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item unread
  assert_success
  assert_line 'item: unread done with pr:o/r#42, not credited (gh api: HTTP 502)'
  assert_line 'landed #42'
  run agent-queue show unread --json
  assert_equal "$(jq -r '"\(.state) \(.project)"' <<<"$output")" 'done dotfiles'
}

@test "live: after the merge proof, the stowed checkout of this repo is fast-forwarded in the background and said" {
  printf '~: the pass runs in the background; its result is logged to ~/.cache/dotfiles-autopull/autopull.log\n' >"$NOTES_FIXTURE/autopull.out"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'live: ~: the pass runs in the background; its result is logged to ~/.cache/dotfiles-autopull/autopull.log'
  printf '%s\n' '~/.dotfiles: fast-forwarded main 01234567..fedcba98' '~: rebuilt agent-web (cargo build --release)' >"$NOTES_FIXTURE/autopull.out"
  run "$LAND" 42 --item ship
  assert_line 'live: ~: rebuilt agent-web (cargo build --release)'
  run grep 'pr merge 42\|^dotfiles-autopull' "$LOG"
  assert_line --index 0 --partial 'pr merge 42'
  assert_line --index 1 'dotfiles-autopull --now . --bg'
}

@test "live: a repo that is not a stowed checkout gets no line" {
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'live:'
  assert_line 'landed #42'
}

@test "live: a failing autopull never fails the landing" {
  printf '1\n' >"$NOTES_FIXTURE/autopull.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
  DOTFILES_AUTOPULL="$SANDBOX/no-such-autopull" run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
}

@test "prs: after the merge the PR store refreshes that repo; a failed refresh is said and never fails the landing, an unlisted repo is said and filed once" {
  run "$LAND" 42 --item ship
  assert_success
  run grep '^schedules-sync' "$LOG"
  assert_output 'schedules-sync sync-prs o/r'
  printf '1\n' >"$NOTES_FIXTURE/ss.rc"; echo 'o/r: HTTP 502' >"$NOTES_FIXTURE/ss.err"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'prs: o/r not refreshed (o/r: HTTP 502); its next poll reads the merge'
  assert_line 'landed #42'
  printf '3\n' >"$NOTES_FIXTURE/ss.rc"
  : >"$LOG"
  run "$LAND" 42 --item ship
  assert_success
  assert_line --partial 'prs: o/r is in no schedules-sync repos list'
  assert_line 'prs: filed on the agent-runtime outbox'
  assert_line 'landed #42'
  run grep -c '^notes ptask agent-runtime --agent add --why runtime-fault fix(ledger): o/r is in no schedules-sync repos list' "$LOG"
  assert_output 1
  printf '3\n' >"$NOTES_FIXTURE/ptask.agent.add.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'prs: a like row is already open on agent-runtime'
  printf '5\n' >"$NOTES_FIXTURE/ptask.agent.add.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line --partial 'prs: not filed, notes wants its shortlist read first: notes ptask agent-runtime --agent add --why runtime-fault --checked <ids>'
  printf '1\n' >"$NOTES_FIXTURE/ptask.agent.add.rc"; echo 'board locked' >"$NOTES_FIXTURE/ptask.agent.added"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'prs: could not file it on agent-runtime (board locked)'
  assert_line 'landed #42'
}

@test "partial landing holds after items and the board until the other repo lands" {
  legacy next "after: ship" --project dotfiles 'next phase'
  : >"$LOG"
  run "$LAND" 42 --item ship --partial
  assert_success
  assert_line 'board: left open until the final landing'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .merged] | join(" ")' <<<"$output")" 'running yes o/r#42 fedcba9876543210fedcba9876543210fedcba98'
  run agent-queue show next --json
  assert_equal "$(jq -r .hold <<<"$output")" 'after ship'
  run agent-queue next --json
  refute_output --partial '"slug":"next"'
  [ -z "$(board_calls)" ] || fail 'partial landing closed the row'
  # Repeating the first landing keeps one PR and never releases its dependents.
  run "$LAND" 42 --item ship --partial
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r .pr <<<"$output")" o/r#42
  # The final PR comes from another checkout/repo and closes the one item.
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$NOTES_FIXTURE/merge.oid"
  run "$LAND" 43 --item ship --plan "$PLAN" --phase '6. agent-land'
  assert_success
  assert_line 'plan: ticked "6. agent-land"'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .merged] | join("|")' <<<"$output")" 'done||o/r#42 o/p#43|fedcba9876543210fedcba9876543210fedcba98 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  run agent-queue show next --json
  assert_equal "$(jq -r '.hold // ""' <<<"$output")" ''
  run board_calls
  assert_output --partial 'done ship it --proof pr:o/p#43'
}

@test "an earlier PR recorded with no merge takes its merge commit from gh, so this PR is recorded beside it" {
  # NEGATIVE CONTROL: before ar-781 this merged #42, then failed "no merge recorded for o/p#1794"
  # and left #42 off the item (private #762, 2026-11-11).
  agent-queue set ship pr=o/p#1794 >/dev/null
  echo '{"state":"MERGED","mergeCommit":{"oid":"abcdef0123456789abcdef0123456789abcdef01"}}' >"$NOTES_FIXTURE/prior.json"
  run "$LAND" 42 --item ship --partial
  assert_success
  assert_line 'item: ship partial with pr:o/r#42, left open for the final landing'
  run grep -c '^gh pr view 1794 -R o/p --json state,mergeCommit -q .mergeCommit.oid // .state$' "$LOG"
  assert_output 1
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .merged] | join("|")' <<<"$output")" \
    'running|yes|o/p#1794 o/r#42|abcdef0123456789abcdef0123456789abcdef01 fedcba9876543210fedcba9876543210fedcba98'
}

@test "an earlier PR that is not merged refuses a final landing before the merge, leaving the PR and item untouched" {
  agent-queue set ship pr=o/p#1794 >/dev/null
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'queue item ship records o/p#1794, which is OPEN: land it first (agent-land 1794 --repo o/p --item ship --partial), then #42'
  run grep -e '^gh pr merge' -e '^gh pr edit' "$LOG"
  assert_failure
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .pr, (.merged // ""), (.partial // "")] | join("|")' <<<"$output")" 'running|o/p#1794||'
}

@test "an open PR in another repo whose body names the item refuses a full landing before the merge; --partial lands" {
  # NEGATIVE CONTROL: before ar-2665 this merged #42 and closed ship while o/p#43, naming it, was still open,
  # so every item held after: ship started early (ar-2653: .dotfiles#2278 and .dotfiles-private#949, 2026-11-17).
  legacy next "after: ship" --project dotfiles 'next phase'
  printf '%s' '[{"number":43,"repository":{"nameWithOwner":"o/p"},"body":"Work.\r\nItem: ship\r\n"},{"number":42,"repository":{"nameWithOwner":"o/r"},"body":"Item: ship"}]' >"$NOTES_FIXTURE/search.json"
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'o/p#43 is open and names ship, which a full landing would close: land #42 --partial (agent-land 42 --item ship --partial), then o/p#43 with the full flags (agent-land 43 --repo o/p --item ship)'
  run grep -e '^gh pr merge' -e '^gh pr edit' "$LOG"
  assert_failure
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, (.pr // ""), (.partial // "")] | join("|")' <<<"$output")" 'running||'
  # --partial is the split's first landing: it does not search, and leaves ship open, holding next.
  run "$LAND" 42 --item ship --partial
  assert_success
  assert_line 'item: ship partial with pr:o/r#42, left open for the final landing'
  run grep -c '^gh search prs' "$LOG"
  assert_output 1
  run agent-queue show next --json
  assert_equal "$(jq -r .hold <<<"$output")" 'after ship'
}

@test "the split search counts only an open PR whose first Item: line is this item, never this PR itself" {
  # A slug that only starts with ship, an Item: line after another, a body with none, and #42 itself.
  printf '%s' '[{"number":7,"repository":{"nameWithOwner":"o/p"},"body":"Item: ship-two"},{"number":8,"repository":{"nameWithOwner":"o/p"},"body":"Item: other\nItem: ship"},{"number":9,"repository":{"nameWithOwner":"o/p"},"body":null},{"number":42,"repository":{"nameWithOwner":"O/R"},"body":"Item: ship"}]' >"$NOTES_FIXTURE/search.json"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'item: ship done with pr:o/r#42'
}

@test "a failed split search refuses the full landing with nothing touched" {
  touch "$NOTES_FIXTURE/search.fail"
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'split: gh search prs for open PRs naming ship failed, nothing touched: gh: API rate limit exceeded (HTTP 403); re-run'
  run grep -e '^gh pr merge' -e '^gh pr edit' "$LOG"
  assert_failure
}

@test "an item whose pr: lists two open PRs lands one --partial, then the other closes it with both merges" {
  # NEGATIVE CONTROL: before ar-1267 the --partial landing refused "o/p#43, which is OPEN: land it first
  # (... --partial)", and so did the other, so neither could land (ar-314, 2026-11-09).
  agent-queue set ship 'pr=o/r#42 o/p#43' >/dev/null
  run "$LAND" 42 --item ship --partial
  assert_success
  assert_line --partial 'item: ship partial with pr:o/r#42'
  assert_line --partial '; merged: waits for o/p#43, still open, left open for the final landing'
  # merged: cannot list #42 beside an open #43 and stay in step, so it waits empty for the final landing.
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, (.merged // "")] | join("|")' <<<"$output")" 'running|yes|o/r#42 o/p#43|'
  [ -z "$(board_calls)" ] || fail 'partial landing closed the row'
  # A re-run of the partial landing (now MERGED) leaves the same record.
  run "$LAND" 42 --item ship --partial
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, (.merged // "")] | join("|")' <<<"$output")" 'running|yes|o/r#42 o/p#43|'
  # The final landing reads #42's merge from gh and records both, in step.
  echo '{"state":"MERGED","mergeCommit":{"oid":"abcdef0123456789abcdef0123456789abcdef01"}}' >"$NOTES_FIXTURE/prior.json"
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$NOTES_FIXTURE/merge.oid"
  run "$LAND" 43 --item ship
  assert_success
  assert_line 'landed #43'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, (.partial // ""), .pr, .merged, .closing_pr] | join("|")' <<<"$output")" \
    'done||o/r#42 o/p#43|abcdef0123456789abcdef0123456789abcdef01 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|o/p#43'
  run board_calls
  assert_output --partial 'done ship it --proof pr:o/p#43'
}

@test "an earlier PR closed unmerged, or lists out of step, refuse before the merge with the way out" {
  agent-queue set ship pr=o/p#1794 >/dev/null
  echo '{"state":"CLOSED","mergeCommit":null}' >"$NOTES_FIXTURE/prior.json"
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'queue item ship records o/p#1794, closed unmerged: drop it from'
  agent-queue set ship 'pr=o/p#1794 o/q#7' merged=abcdef0123456789abcdef0123456789abcdef01 >/dev/null
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'out of step'
  run grep -e '^gh pr merge' -e '^gh pr edit' "$LOG"
  assert_failure
}

@test "partial protects an already merged PR and refuses a finished item or plan phase" {
  echo MERGED >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item ship --partial
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '.state + " " + .partial' <<<"$output")" 'running yes'
  run "$LAND" 42 --item ship --partial --plan "$PLAN" --phase '6. agent-land'
  assert_failure 2
  run "$LAND" 42 --item ship
  assert_success
  run "$LAND" 42 --item ship --partial
  assert_failure 2
  assert_output --partial 'already done'
}

@test "partial dry run describes keeping the item and row open" {
  run "$LAND" 42 --item ship --partial --dry-run
  assert_success
  assert_output --partial 'partial=yes once #42 is merged'
  assert_output --partial 'board: left open until the final landing'
  refute_output --partial 'move ship done'
  refute_output --partial 'board: notes'
  refute_output --partial 'split:'
}

@test "the final second PR retries a failed board step after a partial first landing" {
  run "$LAND" 42 --item ship --partial
  assert_success
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  cp "$SANDBOX/bin/notes" "$SANDBOX/bin/notes-working"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$SANDBOX/bin/notes"
  run "$LAND" 43 --item ship
  assert_failure 1
  assert_output --partial 'board failed:'
  run agent-queue show ship --json
  assert_equal "$(jq -r '.state + " " + .closing_pr' <<<"$output")" 'done o/p#43'
  cp "$SANDBOX/bin/notes-working" "$SANDBOX/bin/notes"
  run "$LAND" 43 --item ship
  assert_success
  assert_output --partial 'board: closed "ship it" with pr:o/p#43'
}

@test "a brief with two PRs in one repo lands both on its one item: the first --partial, the second closes it" {
  # NEGATIVE CONTROL: before ar-2044 the second PR was refused as "an item carries one PR per repo",
  # so release-windows-only filed ucp-1987 for #2397 (2026-11-12).
  run "$LAND" 42 --item ship --partial
  assert_success
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/r/pull/43 >"$NOTES_FIXTURE/url"
  echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$NOTES_FIXTURE/merge.oid"
  run "$LAND" 43 --item ship
  assert_success
  assert_line 'landed #43'
  assert_output --partial 'board: closed "ship it" with pr:o/r#43'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .merged, .closing_pr] | join("|")' <<<"$output")" \
    'done||o/r#42 o/r#43|fedcba9876543210fedcba9876543210fedcba98 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|o/r#43'
  # Once done, the rule holds again: a third PR in o/r is a second task.
  echo https://github.com/o/r/pull/44 >"$NOTES_FIXTURE/url"
  run "$LAND" 44 --item ship
  assert_failure 2
  assert_output --partial 'an item carries one PR per repo'
}

@test "an open item not marked partial still refuses a second PR in a repo it carries" {
  agent-queue set ship pr=o/r#42 merged=fedcba9876543210fedcba9876543210fedcba98 >/dev/null
  echo https://github.com/o/r/pull/43 >"$NOTES_FIXTURE/url"
  run "$LAND" 43 --item ship
  assert_failure 2
  assert_output --partial 'an item carries one PR per repo'
  assert_output --partial 'queue item ship is open and already carries o/r#42'
  assert_output --partial 'agent-queue set ship partial=yes and re-run'
  run grep -e '^gh pr merge' -e '^gh pr edit' "$LOG"
  assert_failure
  # The way out the refusal names lands it beside #42 and closes the item.
  agent-queue set ship partial=yes >/dev/null
  run "$LAND" 43 --item ship
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .pr] | join("|")' <<<"$output")" 'done|o/r#42 o/r#43'
}

@test "--dry-run refuses a second PR in one repo on an open or done item like the real run" {
  agent-queue set ship pr=o/r#42 merged=fedcba9876543210fedcba9876543210fedcba98 >/dev/null
  run "$LAND" 43 --item ship --dry-run
  assert_failure 2
  assert_output --partial 'queue item ship is open and already carries o/r#42, and an item carries one PR per repo'
  assert_output --partial 'agent-queue set ship partial=yes and re-run'
  run grep -c '^gh ' "$LOG"
  assert_output 0

  # --partial, partial=yes, or another repo (--repo o/p) passes --dry-run.
  run "$LAND" 43 --item ship --partial --dry-run
  assert_success
  run "$LAND" 43 --item ship --repo o/p --dry-run
  assert_success
  agent-queue set ship partial=yes >/dev/null
  run "$LAND" 43 --item ship --dry-run
  assert_success
  agent-queue set ship partial= >/dev/null

  # A done item also refuses a second PR in the same repo on --dry-run.
  agent-queue move ship done --status ok >/dev/null
  run "$LAND" 43 --item ship --dry-run
  assert_failure 2
  assert_output --partial 'queue item ship is done and already carries o/r#42, and an item carries one PR per repo'
}

# A Forgejo PR: curl answers the Forgejo API for o/r from the same fixtures gh reads (state, body,
# head.oid, merge.oid); fj.status is the head's combined status (one green check by default) and
# fj.files the changed files. Each call logs as "curl METHOD <path under repos/o/r/> [data]".
forgejo() {
  export SO_FORGEJO_HOSTS=forgejo.example SO_RBW="$SANDBOX/bin/rbw"
  printf '#!/usr/bin/env bash\necho tok\n' >"$SANDBOX/bin/rbw"
  cat >"$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
F=$NOTES_FIXTURE
grep -q 'Authorization: token tok' || { echo 'curl: no token on stdin' >&2; exit 2; }
url=${*: -1} method=GET data=''
while [ $# -gt 1 ]; do
  case "$1" in -X) method=$2 && shift ;; --data-binary) data=$2 && shift ;; esac
  shift
done
path=${url#https://forgejo.example/api/v1/repos/o/r/}
printf 'curl %s %s%s\n' "$method" "$path" "${data:+ $data}" >>"$F/calls.log"
case "$method $path" in
'GET pulls/42')
  jq -n --arg st "$(cat "$F/state")" --arg body "$(cat "$F/body")" --arg h "$(cat "$F/head.oid" 2>/dev/null || echo 0123456789abcdef)" \
    --arg m "$(cat "$F/merge.oid" 2>/dev/null || echo fedcba9876543210fedcba9876543210fedcba98)" \
    '{number: 42, state: (if $st == "OPEN" then "open" else "closed" end), merged: ($st == "MERGED"), body: $body,
      base: {ref: "main", repo: {full_name: "o/r"}}, head: {sha: $h, ref: "pr-42", repo: {full_name: "o/r"}},
      html_url: "https://forgejo.example/o/r/pulls/42", mergeable: true,
      merge_commit_sha: (if $st == "MERGED" then $m else null end)}' ;;
# fj.gate: the next N body edits are refused by the CrowdSec bouncer in front of Forgejo, a plain
# "Forbidden" with --fail-with-body's exit 22, before Forgejo sees them
'PATCH pulls/42') n=$(cat "$F/fj.gate" 2>/dev/null || echo 0)
  [ "$n" -eq 0 ] || { echo $((n - 1)) >"$F/fj.gate"; echo Forbidden; echo 'curl: (22) The requested URL returned error: 403' >&2; exit 22; }
  jq -j .body <<<"$data" >"$F/body" && echo '{}' ;;
# fj.status.gate: the next N status reads are refused by the bouncer, a plain "Forbidden"
# fj.status.reset: the next status read loses its connection, once
'GET commits/'*'/status') n=$(cat "$F/fj.status.gate" 2>/dev/null || echo 0)
  [ "$n" -eq 0 ] || { echo $((n - 1)) >"$F/fj.status.gate"; echo Forbidden; echo 'curl: (22) The requested URL returned error: 403' >&2; exit 22; }
  [ ! -f "$F/fj.status.reset" ] || { rm "$F/fj.status.reset"; echo 'curl: (56) Recv failure: Connection reset by peer' >&2; exit 56; }
  cat "$F/fj.status" 2>/dev/null || echo '{"state":"success","statuses":[{"status":"success","context":"checks / test"}]}' ;;
# fj.refuse: the merge is refused, its JSON reason on stdout as --fail-with-body prints it
'POST pulls/42/merge') [ ! -f "$F/fj.refuse" ] || { cat "$F/fj.refuse"; echo 'curl: (22) The requested URL returned error: 405' >&2; exit 22; }
  cp "$F/merged.state" "$F/state" ;;
'GET branch_protections') cat "$F/fj.protections" 2>/dev/null || echo '[]' ;;
'GET pulls/42/files'*) cat "$F/fj.files" 2>/dev/null || echo '[{"filename":"a.sh"}]' ;;
*) echo "curl: (22) The requested URL returned error: 404" >&2 && exit 22 ;;
esac
EOF
  chmod +x "$SANDBOX/bin/rbw" "$SANDBOX/bin/curl"
}

@test "a PR on a Forgejo origin (bnb-game-servers): merged through the API pinned to HEAD, recorded on the item, no gh" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'item-line: added "Item: ship" to the body'
  assert_line 'checks: green'
  assert_line 'merge: #42 MERGED at 01234567'
  assert_line 'item: ship done with pr:o/r#42'
  assert_line --index -1 'landed #42'
  run grep -c '^gh ' "$LOG"
  assert_output 0
  run grep -c '^curl POST pulls/42/merge {"Do":"squash","head_commit_id":"0123456789abcdef"}$' "$LOG"
  assert_output 1
  run grep -c '^git -C . fetch -q origin +refs/heads/main:refs/remotes/origin/main$' "$LOG"
  assert_output 1
  run grep -c '^curl GET pulls/42/files?limit=50&page=1$' "$LOG"
  assert_output 1
  run agent-queue show ship --json
  assert_output --partial '"pr":"o/r#42"'
  assert_output --partial '"merged":"fedcba9876543210fedcba9876543210fedcba98"'
  assert_output --partial '"state":"done"'
}

@test "prs: a Forgejo PR's store is named by the project map's forges.forgejo host, not the html_url host (ar-4530)" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  printf '{"forges":{"forgejo":"store.example"}}\n' >"$SANDBOX/map.json"
  SO_PROJECT_MAP="$SANDBOX/map.json" run "$LAND" 42 --item ship
  assert_success
  run grep '^schedules-sync' "$LOG"
  assert_output 'schedules-sync sync-prs store.example/o/r'
}

@test "prs: a Forgejo PR with no readable project map keeps the html_url host (ar-4530)" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  printf 'not json\n' >"$SANDBOX/map.json"
  SO_PROJECT_MAP="$SANDBOX/map.json" run "$LAND" 42 --item ship
  assert_success
  run grep '^schedules-sync' "$LOG"
  assert_output 'schedules-sync sync-prs forgejo.example/o/r'
  : >"$LOG"
  SO_PROJECT_MAP="$SANDBOX/none.json" run "$LAND" 42 --item ship
  run grep '^schedules-sync' "$LOG"
  assert_output 'schedules-sync sync-prs forgejo.example/o/r'
}

@test "a Forgejo-canonical checkout (home-config): its forgejo remote, not the GitHub origin, carries every git step" {
  forgejo
  mkdir -p "$SANDBOX/hc/.forgejo/workflows"
  : >"$SANDBOX/hc/.forgejo/workflows/mirror-to-github.yaml"
  printf '%s\n' "$SANDBOX/hc" >"$NOTES_FIXTURE/toplevel"
  printf 'forgejo\norigin\n' >"$NOTES_FIXTURE/remotes"
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/forgejo.url"
  printf '1\n0\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship --merge-commit
  assert_success
  assert_line 'fetch: merged forgejo/main (1 behind) into the head and pushed it'
  assert_line 'proof: evidence commit 0123456789abcdef is an ancestor of forgejo/main'
  run grep -c '^gh \|origin' "$LOG"
  assert_output 0
  run grep -c '^git push -q forgejo HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
  run grep -c '"Do":"merge"' "$LOG"
  assert_output 1
}

@test "a Forgejo check that failed stops at checks, naming it; nothing merged" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo '{"statuses":[{"status":"success","context":"lint"},{"status":"failure","context":"checks / test"}]}' >"$NOTES_FIXTURE/fj.status"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: checks / test'
  run grep -c 'pulls/42/merge' "$LOG"
  assert_output 0
}

@test "a Forgejo status read that loses its connection reads again and lands" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  : >"$NOTES_FIXTURE/fj.status.reset"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'checks: lost the connection to the API (1 of 5 retries), reading again'
  run grep -c 'POST pulls/42/merge' "$LOG"
  assert_output 1
}

@test "a Forgejo status read the bouncer refuses (a plain Forbidden) is sent again, and again after its tries run out, then lands" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo 6 >"$NOTES_FIXTURE/fj.status.gate"
  SO_FORGEJO_GATE_WAIT=0 AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'checks: lost the connection to the API (1 of 5 retries), reading again'
  assert_line 'checks: green'
  run grep -c 'POST pulls/42/merge' "$LOG"
  assert_output 1
}

@test "a Forgejo status read the bouncer refuses every time stops at checks naming the proxy; nothing merged" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo 999 >"$NOTES_FIXTURE/fj.status.gate"
  SO_FORGEJO_GATE_WAIT=0 AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'lost the connection to the API 6 times: forgejo.example: the proxy in front of Forgejo refused'
  run grep -c 'pulls/42/merge' "$LOG"
  assert_output 0
}

@test "a Forgejo base whose protection rule requires statuses refuses a head with none; with no rule it lands" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo '{"statuses":[]}' >"$NOTES_FIXTURE/fj.status"
  export AGENT_LAND_CHECKS_TRIES=1 AGENT_LAND_CHECKS_POLL=0
  echo '[{"rule_name":"main","enable_status_check":true,"block_on_outdated_branch":false}]' >"$NOTES_FIXTURE/fj.protections"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'origin/main requires checks, so Forgejo would refuse the merge'
  run grep -c 'pulls/42/merge' "$LOG"
  assert_output 0
  echo '[{"rule_name":"release","enable_status_check":true}]' >"$NOTES_FIXTURE/fj.protections"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: none reported'
}

@test "a Forgejo merge refusal ends with Forgejo's reason, not only curl's status line" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo '{"message":"Please try again later","url":"https://forgejo.example/api/swagger"}' >"$NOTES_FIXTURE/fj.refuse"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'Forgejo: Please try again later'
}

@test "a body edit the proxy's bouncer refuses (a plain Forbidden, not Forgejo's) is sent again and lands" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo 2 >"$NOTES_FIXTURE/fj.gate"
  SO_FORGEJO_GATE_WAIT=0 run "$LAND" 42 --item ship
  assert_success
  assert_line 'item-line: added "Item: ship" to the body'
  assert_line --index -1 'landed #42'
  run grep -c '^curl PATCH pulls/42 ' "$LOG"
  assert_output 3
}

@test "a body edit the bouncer refuses every time fails at item-line naming the proxy, not Forgejo; nothing merged" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo 9 >"$NOTES_FIXTURE/fj.gate"
  SO_FORGEJO_GATE_WAIT=0 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'item-line failed: Forgejo pr edit: forgejo.example: the proxy in front of Forgejo refused pulls/42 4 times with a plain-text 403 "Forbidden", not Forgejo'"'"'s'
  refute_output --partial 'curl: (22)'
  refute_output --partial 'Forgejo: Forbidden'
  run grep -c '^curl PATCH pulls/42 ' "$LOG"
  assert_output 4
  run grep -c 'pulls/42/merge' "$LOG"
  assert_output 0
}

@test "a Forgejo dry run reads no token and calls nothing" {
  forgejo
  printf '#!/usr/bin/env bash\nexit 1\n' >"$SANDBOX/bin/rbw"
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 42 --item ship --dry-run
  assert_success
  assert_line --partial 'forge: Forgejo forgejo.example/o/r on remote origin'
  run grep -c '^curl ' "$LOG"
  assert_output 0
}

@test "a Forgejo-canonical checkout with no remote on a listed host stops before anything, never falling back to gh" {
  forgejo
  export SO_FORGEJO_HOSTS=elsewhere.example
  mkdir -p "$SANDBOX/hc/.forgejo/workflows"
  : >"$SANDBOX/hc/.forgejo/workflows/mirror-to-github.yaml"
  printf '%s\n' "$SANDBOX/hc" >"$NOTES_FIXTURE/toplevel"
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'is Forgejo-canonical, but none of its remotes is on a host SO_FORGEJO_HOSTS lists'
  run grep -c '^gh \|^curl ' "$LOG"
  assert_output 0
}

# sub_fixture: real git, no stubs. A superproject on branch pr pins sub at c1 with its checkout there,
# then merges a main that pins c2, a commit pushed to sub's origin only after sub was cloned, so the
# move has to fetch it, as a merge of a busy base does. PRE is the head before that merge. c1 brings
# a.txt, so a test can dirty the checkout.
sub_fixture() {
  export PATH="${PATH#"$SANDBOX/bin:"}"
  # file:// submodules are refused by default since git 2.38.1; this sandbox is all local.
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  local w="$SANDBOX/subwork"
  git init -q --bare -b main "$SANDBOX/sub.git"
  git clone -q "$SANDBOX/sub.git" "$w" 2>/dev/null
  echo one >"$w/a.txt" && git -C "$w" add a.txt && git -C "$w" commit -q -m c1
  C1=$(git -C "$w" rev-parse HEAD)
  git -C "$w" push -q origin main
  SUP="$SANDBOX/super"
  git init -q -b main "$SUP"
  cd "$SUP"
  git submodule add -q "$SANDBOX/sub.git" sub
  # Detached, as `git submodule update --init` (wt new) leaves every agent worktree's checkout.
  git -C sub checkout -q --detach
  git commit -q -m 'sub at c1'
  git -C "$w" commit -q --allow-empty -m c2
  C2=$(git -C "$w" rev-parse HEAD)
  git -C "$w" push -q origin main
  git checkout -q -b pr
  git commit -q --allow-empty -m 'pr work'
  PRE=$(git rev-parse HEAD)
  git update-index --cacheinfo "160000,$C2,sub"
  git commit -q -m 'sub at c2'
  git branch -q -f main HEAD
  git reset -q --hard "$PRE"
  [ "$(git -C sub rev-parse HEAD)" = "$C1" ]
  export C1 C2 PRE SUP
}

follow() { git merge -q --no-edit main && . "$REPO_ROOT/.local/lib/submodule-follow.sh" && submodule_follow "$PRE"; }

@test "submodule: a clean checkout on the old pin moves to the merged pin, fetching it (ucp-671 #2506)" {
  sub_fixture
  run follow
  assert_success
  assert_output "submodule: moved sub from ${C1:0:8} to the new pin ${C2:0:8}"
  [ "$(git -C sub rev-parse HEAD)" = "$C2" ]
  run git status --porcelain
  assert_output ''
}

@test "submodule: a checkout with uncommitted changes stays on the old pin and says so" {
  sub_fixture
  echo two >sub/a.txt
  run follow
  assert_success
  assert_output --partial "submodule: left sub on the old pin ${C1:0:8}: it has uncommitted changes"
  [ "$(git -C sub rev-parse HEAD)" = "$C1" ]
  [ "$(cat sub/a.txt)" = two ]
}

@test "submodule: a checkout on a commit of its own stays there and says so" {
  sub_fixture
  git -C sub commit -q --allow-empty -m local-only
  local mine
  mine=$(git -C sub rev-parse HEAD)
  run follow
  assert_success
  assert_output --partial "submodule: left sub on ${mine:0:8}, neither the old pin ${C1:0:8} nor the new ${C2:0:8}"
  [ "$(git -C sub rev-parse HEAD)" = "$mine" ]
}

@test "submodule: an uninitialized submodule and an unchanged pin print nothing" {
  sub_fixture
  git submodule deinit -q -f sub
  run follow
  assert_success
  assert_output ''
  [ ! -e sub/.git ]
}

@test "submodule: a checkout already on the new pin is left alone, silently" {
  sub_fixture
  git -C sub fetch -q origin && git -C sub checkout -q "$C2"
  run follow
  assert_success
  assert_output ''
}

@test "submodule: run from a subdirectory, the paths are read from the toplevel and the checkout still moves" {
  sub_fixture
  mkdir deep && git merge -q --no-edit main && cd deep
  . "$REPO_ROOT/.local/lib/submodule-follow.sh"
  run submodule_follow "$PRE"
  assert_success
  assert_output "submodule: moved sub from ${C1:0:8} to the new pin ${C2:0:8}"
  [ "$(git -C ../sub rev-parse HEAD)" = "$C2" ]
}

@test "submodule: a checkout on a branch at the old pin stays on that branch and says so" {
  sub_fixture
  git -C sub checkout -q -b wip
  run follow
  assert_success
  assert_output "submodule: left sub on branch wip at the old pin ${C1:0:8}: move it by hand to the new pin ${C2:0:8}"
  [ "$(git -C sub symbolic-ref --short HEAD)" = wip ]
}

@test "submodule: an old rev that is not a commit says nothing was compared" {
  sub_fixture
  . "$REPO_ROOT/.local/lib/submodule-follow.sh"
  run submodule_follow deadbeef
  assert_success
  assert_output --partial 'submodule: no pins compared, deadbeef is not a commit'
}

# lock_busy <verb> <n>: the sandbox agent-queue answers its next <n> <verb> calls with exit 75, what
# the real one exits when its lock wait runs out, then runs for real.
lock_busy() {
  mv "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/agent-queue.real"
  cat >"$SANDBOX/bin/agent-queue" <<EOS
#!/usr/bin/env bash
if [ "\$1" = "$1" ]; then
  n=\$(cat "$SANDBOX/busy.n" 2>/dev/null || echo $2)
  if [ "\$n" -gt 0 ]; then
    echo \$((n - 1)) >"$SANDBOX/busy.n"
    echo "agent-queue: the queue is locked by another writer" >&2
    exit 75
  fi
fi
exec "$SANDBOX/bin/agent-queue.real" "\$@"
EOS
  chmod +x "$SANDBOX/bin/agent-queue"
}

@test "a lock timeout on the item step is retried: the item still gets the PR and moves to done" {
  item tidy-loader
  lock_busy set 2
  run "$LAND" 42 --item tidy-loader
  assert_success
  assert_output --partial 'item: tidy-loader done with pr:o/r#42'
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.pr)"' <<<"$output")" 'done o/r#42'
}

@test "a lock that stays busy past every try fails the item step, naming the lock" {
  item tidy-loader
  lock_busy set 9
  AGENT_LAND_QUEUE_TRIES=3 run "$LAND" 42 --item tidy-loader
  assert_failure 1
  assert_output --partial 'item failed: agent-queue: the queue is locked by another writer'
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r .state <<<"$output")" running
}

@test "a busy lock on the move to done after the merge names the re-run, and the re-run closes the item (ar-3089)" {
  item tidy-loader
  lock_busy move 9
  AGENT_LAND_QUEUE_TRIES=3 run "$LAND" 42 --item tidy-loader
  assert_failure 1
  assert_output --partial 'item failed: agent-queue: the queue is locked by another writer; #42 is merged and only its record is left: re-run agent-land 42 --item tidy-loader to finish it'
  run grep -c -- '--why merged, but item: .*only its record is left' "$LOG"
  assert_output 1
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.closing_pr)"' <<<"$output")" 'running o/r#42'
  echo 0 >"$SANDBOX/busy.n"
  run "$LAND" 42 --item tidy-loader
  assert_success
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r .state <<<"$output")" done
}

@test "a failure before the merge names no re-run of a merged PR (negative control)" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --item ship
  assert_failure 1
  refute_output --partial 'only its record is left'
}

@test "a lock timeout on the pre-merge item read is retried" {
  item tidy-loader
  lock_busy show 2
  run "$LAND" 42 --item tidy-loader
  assert_success
  assert_output --partial 'item: tidy-loader done with pr:o/r#42'
}

@test "a pre-merge item read whose lock never clears says so, and nothing merges" {
  item second
  lock_busy show 9
  run "$LAND" 42 --item second
  assert_failure 2
  assert_output --partial 'the queue is locked by another writer: nothing merged'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}


@test "--plan on a pointer stub ticks the canonical plan, and the stub's own line beside it (ar-2513)" {
  printf '%s\n' '## Phases' '' '- [x] 1. first (#1)' '- [ ] 2. gate-then-land' '- [ ] 3. last' >"$SANDBOX/canon.md"
  printf '%s\n' "Phase 2 of $SANDBOX/canon.md" '' '## Phases' '' '- [ ] 2. gate-then-land' >"$SANDBOX/stub.md"
  run "$LAND" 42 --item ship --plan "$SANDBOX/stub.md" --phase "2. gate-then-land"
  assert_success
  assert_line "plan: $SANDBOX/stub.md is a pointer stub; its phases are in $SANDBOX/canon.md"
  run cat "$SANDBOX/canon.md"
  assert_output - <<'EOF2'
## Phases

- [x] 1. first (#1)
- [x] 2. gate-then-land (#42)
- [ ] 3. last
EOF2
  run grep -c '^- \[x\] 2. gate-then-land (#42)$' "$SANDBOX/stub.md"
  assert_output 1
  # negative control: a phase the canonical plan lacks is refused, whatever the stub says
  printf '%s\n' "Phase 2 of $SANDBOX/canon.md" '' '## Phases' '' '- [ ] 9. nope' >"$SANDBOX/stub.md"
  run "$LAND" 42 --item ship --plan "$SANDBOX/stub.md" --phase "9. nope"
  assert_failure
  assert_output --partial "plan: 0 unchecked lines"
}

@test "an item stacked on a dependency that has not closed ok is refused with exit 4: nothing merged, the open PR recorded on it (ar-3852)" {
  item base
  item tidy-loader
  agent-queue set tidy-loader after=base
  CLAUDE_CODE_SESSION_ID=sid-l run "$LAND" 42 --item tidy-loader
  assert_failure 4
  assert_output --partial 'is stacked on base'
  run grep -c 'pr merge\|pr checks' "$LOG"
  assert_output 0
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.open_pr)"' <<<"$output")" 'running o/r#42'
  # NEGATIVE CONTROL: once the dependency closed ok the same landing goes through and clears open_pr.
  agent-queue move base done --status ok
  CLAUDE_CODE_SESSION_ID=sid-l run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line 'landed #42'
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr) \(.open_pr // "")"' <<<"$output")" 'done ok o/r#42 '
}

@test "an item stacked on a dependency that closed unmerged is refused too, never merged" {
  item base
  item tidy-loader
  agent-queue set tidy-loader after=base
  agent-queue move base done --status failed
  run "$LAND" 42 --item tidy-loader
  assert_failure 4
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a --partial landing keeps the item's open_pr: its other PRs are still open (ar-3852)" {
  item tidy-loader
  agent-queue set tidy-loader open_pr=o/r#9
  run "$LAND" 42 --item tidy-loader --partial
  assert_success
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '.open_pr // "gone"' <<<"$output")" 'o/r#42'
}

@test "a partial landing on an item another session owns records the PR without claiming the item (ar-3368)" {
  item ship
  agent-queue claim ship --sid sid-owner >/dev/null
  run agent-queue show ship --json
  assert_equal "$(jq -r .sessions <<<"$output")" 'sid-owner'

  # A partial landing from a different session records the PR but does not claim the item.
  CLAUDE_CODE_SESSION_ID=sid-lander run "$LAND" 42 --item ship --partial
  assert_success
  assert_line --partial 'item: ship partial with pr:o/r#42'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .sessions] | join("|")' <<<"$output")" 'running|yes|o/r#42|sid-owner'
  # It still landed #42, so landed_by names it (ar-2779).
  assert_equal "$(jq -r .landed_by <<<"$output")" 'sid-lander=o/r#42'

  # Negative control: landing without --partial claims the item on its final landing.
  echo '{"state":"MERGED","mergeCommit":{"oid":"abcdef0123456789abcdef0123456789abcdef01"}}' >"$NOTES_FIXTURE/prior.json"
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  CLAUDE_CODE_SESSION_ID=sid-lander run "$LAND" 43 --item ship
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .sessions, .landed_by] | join("|")' <<<"$output")" 'done|sid-owner sid-lander|sid-lander=o/r#42 sid-lander=o/p#43'
}

@test "a partial landing on an item owned via tmux session does not claim the item (ar-3368)" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item foreign
  agent-queue set foreign session=lab:foreign-sess >/dev/null
  agent-queue claim foreign --sid sid-old >/dev/null
  CLAUDE_CODE_SESSION_ID=sid-lander run "$LAND" 42 --item foreign --partial
  assert_success
  assert_line --partial 'item: foreign partial with pr:o/r#42'
  run agent-queue show foreign --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .sessions] | join("|")' <<<"$output")" 'running|yes|o/r#42|sid-old'
}

@test "a partial landing from the item's own tmux session under a new id claims it, as does one with no tmux to compare (ar-3368)" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item resumed
  agent-queue set resumed session=default:dotfiles-agent-9 >/dev/null
  agent-queue claim resumed --sid sid-old >/dev/null
  CLAUDE_CODE_SESSION_ID=sid-new run "$LAND" 42 --item resumed --partial
  assert_success
  run agent-queue show resumed --json
  assert_equal "$(jq -r .sessions <<<"$output")" 'sid-old sid-new'

  unset TMUX
  item headless
  agent-queue set headless session=lab:somewhere >/dev/null
  echo https://github.com/o/r/pull/43 >"$NOTES_FIXTURE/url"
  CLAUDE_CODE_SESSION_ID=sid-new run "$LAND" 43 --item headless --partial
  assert_success
  run agent-queue show headless --json
  assert_equal "$(jq -r .sessions <<<"$output")" 'sid-new'
}

@test "a red watch item cannot close ok while its watch's probe still trips; re-running once it clears closes it (ar-1605)" {
  cat >"$SANDBOX/bin/watch-companion-loop" <<'EOF'
#!/usr/bin/env bash
printf 'watch-companion-loop %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
rc=$(cat "$NOTES_FIXTURE/watch.rc" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] || echo "TRIP: spend still over limit"
exit "$rc"
EOF
  chmod +x "$SANDBOX/bin/watch-companion-loop"

  cat >"$AGENT_QUEUE_DIR/running/20261103-100000-red-spend.md" <<'EOF'
slug: red-spend
project: dotfiles
mode: oneshot
priority: urgent
from: fleet-bench
agent: claude
tags: red watch cause:ab12
row: dotfiles:ship red
queued: 2026-11-03T10:00:00Z
started: 2026-11-03T10:00:00Z
---
check(watch): spend tripped since 2026-11-20, expected: spend under cap
EOF

  printf '1\n' >"$NOTES_FIXTURE/watch.rc"
  run "$LAND" 42 --item red-spend
  assert_failure 1
  assert_output --partial "item failed: watch spend did not read OK on resolve (exit 1): TRIP: spend still over limit; #42 is merged and only its record is left: re-run agent-land 42 --item red-spend to finish it"
  # The PR merged and was recorded on the item, but the item and its board row stayed open.
  run agent-queue show red-spend --json
  assert_equal "$(jq -r '[.state, .pr, .merged] | join("|")' <<<"$output")" 'running|o/r#42|fedcba9876543210fedcba9876543210fedcba98'
  [ "$(grep -c '^notes.*done' "$LOG")" -eq 0 ]
  # The probe ran after autopull.
  [ "$(grep -n 'dotfiles-autopull' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'watch-companion-loop resolve spend --pr o/r#42' "$LOG" | cut -d: -f1)" ]

  # Once the probe clears, re-running agent-land finishes closing the item and its board row.
  printf '0\n' >"$NOTES_FIXTURE/watch.rc"
  run "$LAND" 42 --item red-spend
  assert_success
  assert_line 'watch: spend OK'
  assert_line --partial 'board: closed "ship red"'
  assert_line 'landed #42'
  run agent-queue show red-spend --json
  assert_equal "$(jq -r '[.state, .status] | join("|")' <<<"$output")" 'done|ok'
}

@test "a red watch item with --partial skips the probe check, and a non-red item with check(watch) in its task skips it too (ar-1605)" {
  cat >"$SANDBOX/bin/watch-companion-loop" <<'EOF'
#!/usr/bin/env bash
printf 'watch-companion-loop %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
exit 1
EOF
  chmod +x "$SANDBOX/bin/watch-companion-loop"

  cat >"$AGENT_QUEUE_DIR/running/20261103-100000-red-spend.md" <<'EOF'
slug: red-spend
project: dotfiles
mode: oneshot
priority: urgent
from: fleet-bench
agent: claude
tags: red watch cause:ab12
queued: 2026-11-03T10:00:00Z
started: 2026-11-03T10:00:00Z
---
check(watch): spend tripped since 2026-11-20
EOF

  run "$LAND" 42 --item red-spend --partial
  assert_success
  [ "$(grep -c 'watch-companion-loop' "$LOG")" -eq 0 ]

  cat >"$AGENT_QUEUE_DIR/running/20261103-100001-non-red.md" <<'EOF'
slug: non-red
project: dotfiles
mode: oneshot
priority: low
from: human
agent: claude
tags: reddish
queued: 2026-11-03T10:00:01Z
started: 2026-11-03T10:00:01Z
---
check(watch): spend tripped since 2026-11-20
EOF

  run "$LAND" 42 --item non-red
  assert_success
  [ "$(grep -c 'watch-companion-loop' "$LOG")" -eq 0 ]
}

@test "a red watch item whose watch is unknown (exit 2) closes ok, while lock busy (exit 75) or a usage error (exit 2) refuses (ar-1605)" {
  cat >"$SANDBOX/bin/watch-companion-loop" <<'EOF'
#!/usr/bin/env bash
printf 'watch-companion-loop %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
cat "$NOTES_FIXTURE/watch.err" >&2 2>/dev/null
exit "$(cat "$NOTES_FIXTURE/watch.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$SANDBOX/bin/watch-companion-loop"

  cat >"$AGENT_QUEUE_DIR/running/20261103-100000-red-lock.md" <<'EOF'
slug: red-lock
project: dotfiles
mode: oneshot
priority: urgent
from: fleet-bench
agent: claude
tags: red watch
queued: 2026-11-03T10:00:00Z
started: 2026-11-03T10:00:00Z
---
check(watch): spend tripped
EOF

  printf '75\n' >"$NOTES_FIXTURE/watch.rc"
  run "$LAND" 42 --item red-lock
  assert_failure 1
  assert_output --partial 'resolve spend could not take the lock (exit 75)'
  run agent-queue show red-lock --json
  assert_equal "$(jq -r .state <<<"$output")" 'running'

  printf '2\n' >"$NOTES_FIXTURE/watch.rc"
  printf 'usage: watch-companion-loop {run|recheck NAME...}\n' >"$NOTES_FIXTURE/watch.err"
  run "$LAND" 42 --item red-lock
  assert_failure 1
  assert_output --partial 'watch-companion-loop resolve spend: usage: watch-companion-loop {run|recheck NAME...}'
  run agent-queue show red-lock --json
  assert_equal "$(jq -r .state <<<"$output")" 'running'

  printf 'watch-companion-loop: no watch named spend\n' >"$NOTES_FIXTURE/watch.err"
  run "$LAND" 42 --item red-lock
  assert_success
  assert_line 'watch: spend not known here (exit 2), skipping probe check'
  run agent-queue show red-lock --json
  assert_equal "$(jq -r '[.state, .status] | join("|")' <<<"$output")" 'done|ok'
}

@test "a failed read of the head's queued runs is not 0 queued: a lost connection reads again, any other error stops at checks (ar-2235)" {
  printf '%s\n' 'no checks reported on the pr-42 branch' >"$NOTES_FIXTURE/checks.out"
  printf '%s\n' 'ERR gh: Server Error (HTTP 502)' >"$NOTES_FIXTURE/runs.queued"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship --ran-checks
  assert_failure 1
  assert_line 'checks: lost the connection to the API (1 of 5 retries), reading again'
  refute_output --partial 'reading the runs on the head'
  : >"$LOG"
  printf '%s\n' 'ERR gh: API rate limit exceeded (HTTP 403)' >"$NOTES_FIXTURE/runs.queued"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: reading the runs on the head: gh: API rate limit exceeded (HTTP 403)'
  refute_output --partial 'checks: none reported'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a watch that dies on a 403 with no check named stops as a read error, not a red check (ar-2235)" {
  printf '%s\n' 'gh: API rate limit exceeded (HTTP 403)' >"$NOTES_FIXTURE/checks.seq"
  : >"$NOTES_FIXTURE/checks.failed"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: the watch ended with no failed check to name: gh: API rate limit exceeded (HTTP 403)'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a PR whose only checks read skipping at that moment keeps waiting while a run is queued, then lands on green (ar-2485)" {
  printf '%s\n' $'Run Checks\tthe slot refused\tskipping' green >"$NOTES_FIXTURE/checks.seq"
  : >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' true >"$NOTES_FIXTURE/checks.skipping"
  printf '%s\n' 1 >"$NOTES_FIXTURE/runs.queued"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: only skipping reported; waiting'
  assert_line 'checks: green'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep '^sleep' "$LOG"
  assert_output 'sleep 60'
}

@test "a queued-runs answer that is not a count is a failed read, never 0 queued (ar-2235)" {
  printf '%s\n' 'no checks reported on the pr-42 branch' >"$NOTES_FIXTURE/checks.out"
  printf '%s\n' 'A new release of gh is available' >"$NOTES_FIXTURE/runs.queued"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: reading the runs on the head: not a count: A new release of gh is available'
  refute_output --partial 'checks: none reported'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "board step on a row already ticked still lands and ticks --plan (ar-4189)" {
  item fix 'board:game:gm-1' human
  jq -n '{rows: [], done: [{project: "game", lane: "human", id: "gm-1", state: "done"}]}' >"$NOTES_FIXTURE/board.json"
  mv "$SANDBOX/bin/notes" "$SANDBOX/notes.ok"
  printf '#!/usr/bin/env bash\ncase " $* " in *" done "*) echo "no open task matches '\''gm-1'\'' in game" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$SANDBOX/notes.ok" >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$LAND" 42 --item fix --plan "$PLAN" --phase "6. agent-land"
  mv "$SANDBOX/notes.ok" "$SANDBOX/bin/notes"
  assert_success
  assert_line 'board: "gm-1" was already closed, left as is'
  assert_line 'plan: ticked "6. agent-land"'
  assert_line --index -1 'landed #42'
}

@test "board step on a row no board lists as done on its project, or one dropped, still fails (ar-4189)" {
  item fix 'board:game:gm-1' human
  jq -n '{rows: [], done: [{project: "other", lane: "human", id: "gm-1", state: "done", marker: "id:gm-1 done:2026-11-01"},
    {project: "game", lane: "human", id: "gm-1", state: "done", marker: "id:gm-1 dropped:2026-11-02"}]}' >"$NOTES_FIXTURE/board.json"
  mv "$SANDBOX/bin/notes" "$SANDBOX/notes.ok"
  printf '#!/usr/bin/env bash\ncase " $* " in *" done "*) echo "no open task matches '\''gm-1'\'' in game" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$SANDBOX/notes.ok" >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$LAND" 42 --item fix
  mv "$SANDBOX/notes.ok" "$SANDBOX/bin/notes"
  assert_failure
  assert_output --partial "agent-land: board failed: no open task matches 'gm-1' in game"
}

@test "a watch that times out with a check left IN_PROGRESS and conclusion SUCCESS lands on its conclusion (ar-4595)" {
  printf '%s\n' '{"statusCheckRollup":[{"name":"Checks (docs)","workflowName":"Checks","status":"IN_PROGRESS","completedAt":"2026-11-22T10:00:00Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/1/job/137130856490"}]}' >"$NOTES_FIXTURE/checks.rollup"
  printf '#!/usr/bin/env bash\nprintf "timeout %%s\\n" "$1" >>"$NOTES_FIXTURE/calls.log"\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  AGENT_LAND_CHECKS_WATCH_TIMEOUT=45 run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: green'
  assert_line 'landed #42'
  run grep '^timeout ' "$LOG"
  assert_output 'timeout 45'
  run grep -c 'pr view 42 --json statusCheckRollup' "$LOG"
  assert_output 1
}

@test "a watch that times out with a check left IN_PROGRESS and conclusion FAILURE stops at checks, naming the check (ar-4595)" {
  printf '%s\n' '{"statusCheckRollup":[{"name":"Checks (docs)","workflowName":"Checks","status":"IN_PROGRESS","completedAt":"2026-11-22T10:00:00Z","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/1/job/137130856490"}]}' >"$NOTES_FIXTURE/checks.rollup"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks (docs)'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a watch that times out with checks still pending stops at the overall wait bound (ar-4595)" {
  printf '%s\n' '{"statusCheckRollup":[{"name":"Checks (docs)","workflowName":"Checks","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"https://github.com/o/r/actions/runs/1/job/137130856490"}]}' >"$NOTES_FIXTURE/checks.rollup"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  AGENT_LAND_CHECKS_WAIT_TIMEOUT=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'the watch timed out with checks still pending; continuing'
  assert_output --partial 'checks failed: timed out waiting for checks after 1s'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a cancelled check whose open run on HEAD already has a conclusion is not waited on as a newer run (ar-4595)" {
  printf '%s\n' "$CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  printf '%s\n' '[{"status":"in_progress","conclusion":"success","workflowName":"Checks"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: cancelled: Checks, and no run of its workflow is left on the head to replace it'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a red read after a watch timeout waits on a newer run of its workflow on the head, then stops at checks once none is left (ar-4595)" {
  printf '%s\n' '{"statusCheckRollup":[{"name":"Checks (docs)","workflowName":"Checks","status":"COMPLETED","conclusion":"CANCELLED","detailsUrl":"https://github.com/o/r/actions/runs/1/job/2"}]}' >"$NOTES_FIXTURE/checks.rollup"
  printf '%s\n' '[{"status":"in_progress","workflowName":"Checks"}]' >"$NOTES_FIXTURE/runs.open"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks: red: Checks (docs); waiting on the newer run of its workflow on the head'
  assert_output --partial 'checks failed: Checks (docs)'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a rollup with no readable verdict after a watch timeout stops at checks, never reads as green (ar-4595)" {
  printf '%s\n' 'not json' >"$NOTES_FIXTURE/checks.rollup"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'the rollup gave no verdict'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

# --- validate_gate: critical work merges only on a second agent's pass (ar-1689) ---

# fm <slug> <key: value>... -> those header lines added to the queue item's file
fm() {
  local f; f=$(ls "$AGENT_QUEUE_DIR"/*/*-"$1".md); shift
  for kv in "$@"; do sed -i "0,/^---\$/s//$kv\n---/" "$f"; done
}
# vitem <slug> <author> [key: value]... -> a running validate item for <author>
vitem() {
  local s=$1 a=$2; shift 2
  mkdir -p "$AGENT_QUEUE_DIR/running"
  printf 'slug: %s\nproject: dotfiles\nmode: oneshot\npriority: high\nfrom: auto:validate\nagent: claude\ntags: validate\nafter: %s\nqueued: 2026-11-03T10:00:00Z\nstarted: 2026-11-03T10:00:00Z\n---\nreview\n' "$s" "$a" >"$AGENT_QUEUE_DIR/running/20261103-100000-$s.md"
  [ $# -eq 0 ] || fm "$s" "$@"
}
merges() { grep -c 'pr merge' "$LOG" || true; }

@test "validate: a diff touching a Judge authority name does not merge; it queues one validate item and exits 5, and a re-run waits on it" {
  item crit
  printf '%s\n' README.md .local/lib/judge.sh >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_failure 5
  assert_output --partial 'is critical (the diff touches .local/lib/judge.sh, a Judge authority name in'
  assert_output --partial 'queued validate-crit-01234567'
  assert_equal "$(merges)" 0
  run agent-queue show validate-crit-01234567 --json
  assert_success
  assert_equal "$(jq -r '"\(.state) \(.tags) \(.after) \(.from) \(.priority)"' <<<"$output")" 'queued validate crit auto:validate high'
  assert_equal "$(jq -r .task <<<"$output" | grep -c 'agent-land 42 --repo o/r --item crit')" 1
  run agent-queue show crit --json
  assert_equal "$(jq -r '"\(.state) \(.validate)"' <<<"$output")" 'running validate-crit-01234567'

  run "$LAND" 42 --item crit
  assert_failure 5
  assert_output --partial 'so it waits on validate-crit-01234567'
  assert_equal "$(merges)" 0
  assert_equal "$(ls "$AGENT_QUEUE_DIR"/*/*-validate-crit-* | wc -l)" 1
}

@test "validate: an item carrying out an ask the judge flagged human-only is critical whatever its diff" {
  item ext ask:a1
  mkdir -p "$AGENT_ASK_ROOT/dotfiles"
  printf 'id: a1\njudge_human_only: true\njudge_human_only_evidence: it sends mail to a customer\n' >"$AGENT_ASK_ROOT/dotfiles/a1.md"
  printf 'README.md\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item ext
  assert_failure 5
  assert_output --partial 'it carries out ask a1, which the judge flagged human-only: it sends mail to a customer'
  assert_equal "$(merges)" 0
  run agent-queue show validate-ext-01234567 --json
  assert_equal "$(jq -r .state <<<"$output")" queued
}

@test "validate: repo- and fleet-level work merges as before, with no validate item" {
  printf 'README.md\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'validate: repo work, no second agent needed'
  assert_line 'landed #42'
  item rules
  printf 'CLAUDE.md\n' >"$NOTES_FIXTURE/files"
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item rules
  assert_success
  assert_line 'validate: fleet work, no second agent needed'
  run bash -c "ls '$AGENT_QUEUE_DIR'/*/*-validate-* 2>/dev/null | wc -l"
  assert_output 0
}

@test "validate: a pass verdict on this head from another agent's session merges" {
  item crit
  fm crit 'sessions: s-author' 'validate: validate-crit-01234567'
  vitem validate-crit-01234567 crit 'verdict: pass' 'verdict_head: 0123456789abcdef' 'sessions: s-validator' 'note: read the diff, tests green'
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_success
  assert_line --partial 'validate: pass from validate-crit-01234567 on 01234567 (critical: the diff touches .local/lib/judge.sh'
  assert_line 'landed #42'
  assert_equal "$(merges)" 1
}

@test "validate: a fail verdict leaves the PR open and sends the author item back to the queue with the findings" {
  item crit
  fm crit 'sessions: s-author' 'validate: validate-crit-01234567'
  vitem validate-crit-01234567 crit 'verdict: fail' 'verdict_head: 0123456789abcdef' 'sessions: s-validator' 'note: judge_conf drops an empty override'
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_failure 1
  assert_output --partial 'validate failed: validate-crit-01234567 failed #42 on 01234567; #42 stays open and crit is back in the queue'
  assert_equal "$(merges)" 0
  run agent-queue show crit --json
  assert_equal "$(jq -r .state <<<"$output")" queued
  assert_equal "$(jq -r .note <<<"$output")" 'validation failed on #42 at 01234567 (validate-crit-01234567): judge_conf drops an empty override'
}

@test "validate: a missing verdict, one from the author's own session or one no session gave fails closed" {
  item crit
  fm crit 'sessions: s-author' 'validate: validate-crit-01234567'
  vitem validate-crit-01234567 crit
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_failure 5
  assert_output --partial 'waits on validate-crit-01234567'
  fm validate-crit-01234567 'verdict: pass' 'verdict_head: 0123456789abcdef' 'sessions: s-author'
  run "$LAND" 42 --item crit
  assert_failure 1
  assert_output --partial 'was worked by session s-author, which also worked crit: the verdict must come from another agent'
  sed -i '/^sessions: s-author$/d' "$AGENT_QUEUE_DIR"/running/*-validate-crit-01234567.md
  run "$LAND" 42 --item crit
  assert_failure 1
  assert_output --partial 'records a pass verdict, but no session worked it'
  assert_equal "$(merges)" 0
}

@test "validate: a pass on an older head does not count; the new head gets its own validate item" {
  item crit
  fm crit 'sessions: s-author' 'validate: validate-crit-aaaaaaaa'
  vitem validate-crit-aaaaaaaa crit 'verdict: pass' 'verdict_head: aaaaaaaabbbbbbbb' 'sessions: s-validator'
  touch "$NOTES_FIXTURE/head.foreign"
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_failure 5
  assert_output --partial 'queued validate-crit-01234567'
  assert_equal "$(merges)" 0
  run agent-queue show crit --json
  assert_equal "$(jq -r .validate <<<"$output")" validate-crit-01234567
}

@test "validate: files that cannot be read on an open PR refuse the merge" {
  touch "$NOTES_FIXTURE/files.fail"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "validate failed: could not read #42's changed files"
  assert_equal "$(merges)" 0
}

@test "validate: a validate item closed with no verdict (its session died) is filed again, not waited on" {
  item crit
  fm crit 'sessions: s-author' 'validate: validate-crit-01234567'
  vitem validate-crit-01234567 crit
  mkdir -p "$AGENT_QUEUE_DIR/done"
  mv "$AGENT_QUEUE_DIR"/running/*-validate-crit-01234567.md "$AGENT_QUEUE_DIR/done/"
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_failure 5
  assert_output --partial 'queued validate-crit-01234567'
  run agent-queue show validate-crit-01234567 --json
  assert_equal "$(jq -r .state <<<"$output")" queued
  assert_equal "$(merges)" 0
}

@test "validate: the landing session is put on the author item first, so its own pass on the validate item never counts" {
  item crit
  fm crit 'validate: validate-crit-01234567'
  vitem validate-crit-01234567 crit 'verdict: pass' 'verdict_head: 0123456789abcdef' 'sessions: s-hand'
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  CLAUDE_CODE_SESSION_ID=s-hand AGENT_QUEUE_ITEM=crit run "$LAND" 42 --item crit
  assert_failure 1
  assert_output --partial 'was worked by session s-hand, which also worked crit'
  assert_equal "$(merges)" 0
}
