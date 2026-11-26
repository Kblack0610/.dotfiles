# shellcheck shell=bash
# The setup and fixtures tests/unit/agent_land.bats and agent_land_part2.bats both load, so CI shards can spread the two halves.

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
  # labels.json: the PR's labels, as gh pr view --json labels prints them (none when absent)
  *'--json labels '*) { cat "$NOTES_FIXTURE/labels.json" 2>/dev/null || echo '{"labels":[]}'; } | jq -r "${@: -1}" || exit 1 ;;
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
# review.json: the head's commit statuses, newest first ([] when absent); status.fail: a read or a post fails
'api repos/o/r/commits/'*'/statuses') [ ! -f "$NOTES_FIXTURE/status.fail" ] || { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
  cat "$NOTES_FIXTURE/review.json" 2>/dev/null || echo '[]' ;;
# a status post (-f state= -f context= -f description=) goes on top of review.json
'api repos/o/r/statuses/'*) [ ! -f "$NOTES_FIXTURE/status.fail" ] || { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
  st='' cx='' ds=''
  for a in "$@"; do case $a in state=*) st=${a#state=} ;; context=*) cx=${a#context=} ;; description=*) ds=${a#description=} ;; esac; done
  jq -c --arg s "$st" --arg c "$cx" --arg d "$ds" '[{state: $s, context: $c, description: $d}] + .' <<<"$(cat "$NOTES_FIXTURE/review.json" 2>/dev/null || echo '[]')" >"$NOTES_FIXTURE/review.json.new"
  mv "$NOTES_FIXTURE/review.json.new" "$NOTES_FIXTURE/review.json"
  echo '{}' ;;
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
  land_stub_tools

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

# land_stub_tools: the git, comms-lint, dotfiles-autopull, schedules-sync and shape-grow stubs on the sandbox PATH
land_stub_tools() {
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
# ci.shape: a workflow at HEAD runs shape-grow (none does by default, so agent-land runs it)
grep) [ -f "$NOTES_FIXTURE/ci.shape" ] ;;
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

  # shape-grow: logs its call, keeps its stdin (the body) in shape.body, prints shape.out and exits
  # shape.rc (0, nothing grew, by default)
  cat >"$SANDBOX/bin/shape-grow" <<'EOF'
#!/usr/bin/env bash
printf 'shape-grow %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
cat >"$NOTES_FIXTURE/shape.body"
cat "$NOTES_FIXTURE/shape.out" 2>/dev/null
exit "$(cat "$NOTES_FIXTURE/shape.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$SANDBOX/bin/shape-grow"
  export SHAPE_GROW="$SANDBOX/bin/shape-grow"
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

# gh's watch exits 0 when the only Checks is a cancelled run, while the newer run on the same head
# has no check yet; GitHub then refused the merge BLOCKED (unity-core-playground#2166).
CANCELLED='[{"name":"Checks","bucket":"cancel","workflow":"Checks"}]'
fake_sleep() {
  printf '#!/bin/sh\necho "sleep $1" >>"$NOTES_FIXTURE/calls.log"\n' >"$SANDBOX/bin/sleep"
  chmod +x "$SANDBOX/bin/sleep"
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

# The edit that adds the gate line re-runs Checks; a watch read seconds later still saw the old red,
# and unity-core-playground#2492 gave its landing slot back (2026-11-21, ar-3447).
STALE='[{"name":"Checks","bucket":"fail","workflow":"Checks","event":"pull_request","completedAt":"2026-11-21T15:05:34Z"}]'

# The Item-line edit re-ran Checks while the gate-line edit's run was still cancelling: the re-run opened
# 28s before the cancelled run's aggregate Checks failed, so only its run id says it is newer
# (unity-core-playground#3108, 2026-11-21 22:25 local, so 06:25Z on the 22nd, ar-2940).
STALE_LINKED='[{"name":"Checks","bucket":"fail","workflow":"Checks","event":"pull_request","completedAt":"2026-11-22T06:26:12Z","link":"https://github.com/o/r/actions/runs/44993658091/job/137120075783"}]'

# loose_gate: a row a phase's item filed is the plan's work (planning.md, Found work:), so the phase lands only once
# a phase line takes it. ship files ar-77 (inbox-triage, #from/ship) and ar-78 (a direct add); ar-79 is another
# item's, ar-80 a phase row of a chain, ar-81 closed and ar-82 the human's, so none of those holds it.
loose_fixture() {
  printf '%s\n' '# plan' '' '## Phases' '' '- [x] 1. first (#1)' '- [ ] 2. last' >"$PLAN"
  "$SANDBOX/bin/agent-queue" set ship "plan=$PLAN" >/dev/null
  jq -nc '{action: "filed", id: "ar-77", lane: "agent", by: "inbox-triage", to: "agent-runtime", text: "the blocker #from/ship #size/s"},
    {action: "added", id: "ar-78", lane: "agent", by: "ship", to: "agent-runtime", text: "a second blocker"},
    {action: "filed", id: "ar-79", lane: "agent", by: "inbox-triage", to: "agent-runtime", text: "not ours #from/shipper"},
    {action: "added", id: "ar-80", lane: "agent", by: "ship", to: "agent-runtime", text: "a phase row"},
    {action: "added", id: "ar-81", lane: "agent", by: "ship", to: "agent-runtime", text: "closed already"},
    {action: "added", id: "ar-82", lane: "human", by: "ship", to: "agent-runtime", text: "the human'"'"'s"},
    {action: "added", lane: "agent", by: "ship", text: "an outbox add has no id"}' >"$NOTES_FIXTURE/log.jsonl"
  jq -n '{rows: [{project: "agent-runtime", lane: "agent", id: "ar-77", state: "open"},
    {project: "agent-runtime", lane: "agent", id: "ar-78", state: "open"},
    {project: "agent-runtime", lane: "agent", id: "ar-79", state: "open"},
    {project: "agent-runtime", lane: "agent", id: "ar-80", state: "open", details: ["Phase 3 of the plan /x/other.md: three."]},
    {project: "agent-runtime", lane: "human", id: "ar-82", state: "open"}],
    done: [{project: "agent-runtime", lane: "agent", id: "ar-81", state: "done"}]}' >"$NOTES_FIXTURE/board.json"
}

# repo_map -> a registry where o/r's checkout is the project `tools` and `level` is a game inside repo `game`
repo_map() {
  export PROJECT_MAP_FILE="$SANDBOX/map.json"
  jq -n '{paths: {"/x/r": "tools", "/x/game": "game"}, trackers: {level: {repo: "game", path: "Assets/Level"}, tools: {}}}' >"$PROJECT_MAP_FILE"
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
# review_json <state> <description> -> the head's one commit status, in pr-ci.sh's REVIEW_CONTEXT
review_json() {
  jq -nc --arg s "$1" --arg d "$2" --arg c "$(sed -n 's/^export REVIEW_CONTEXT=//p' "$REPO_ROOT/.local/lib/pr-ci.sh")" \
    '[{state: $s, context: $c, description: $d}]' >"$NOTES_FIXTURE/review.json"
}
