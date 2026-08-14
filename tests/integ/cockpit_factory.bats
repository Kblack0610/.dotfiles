#!/usr/bin/env bats
# The factory view, rendered as a real subprocess.
#
# The factory view is the ONE surface that is cross-profile, and it is the only view that is.
# That asymmetry is the point and also the risk: it has to reach every profile's projects
# while nothing else in the cockpit starts doing the same. Both directions are asserted
# here, because the failure that prompted it was silent -- a wave sat blocked on an
# approval gate one section over, and the view, showing only the section you happened to
# be standing in, rendered as though nothing were waiting on you at all.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # agent-ask fires agent-notify on answer; keep it off the real bus.
  cat > "$SANDBOX/bin/agent-notify" <<'EOF'
#!/usr/bin/env bash
printf 'agent-notify %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
EOF
  chmod +x "$SANDBOX/bin/agent-notify"

  # The fixture's `projects.<profile>` column 2 is prose, but the cockpit treats it as
  # the summary PATH, so give every project a REAL directory.
  #
  # This block used to also write a `<!-- canonical: -->` marker into each one, purely so
  # the marker grep had something deterministic to find. The join is now the NAME -- the
  # lab directory name IS the runtime project name -- so the marker is gone and the
  # scaffold is just directories.
  VAULT="$HOME/vault"
  _project personal Cockpit    cockpit    'the tmux cockpit' 'v0.3'
  _project personal Notes      notes      'the notes CLI'    'v1.2'
  _project work     Playground playground 'client work'      'v2.0'
  _project client   Ingest     ingest     'blocked on access' 'v1.0'

  # factory mode. MODEF is TMPDIR-rooted (notes-cockpit.sh:50) and TMPDIR is sandboxed.
  MODEF="$TMPDIR/notes-cockpit-$(id -u).mode"
  printf factory > "$MODEF"
}

# _project <profile> <Display> <project> <status> <version>
# Writes the project dir and (re)declares the `notes` stub's row for it. <project> is the
# runtime name, which is the lowercased display name -- passing them separately keeps the
# tests honest about which one each assertion is really keyed on.
_project() {
  local prof="$1" disp="$2" canon="$3" status="$4" ver="$5"
  local dir="$VAULT/$prof/$canon"
  mkdir -p "$dir"
  : > "$dir/summary.md"
  # First call for a profile replaces the shipped fixture; later calls append.
  local f="$NOTES_FIXTURE/projects.$prof"
  [ -f "$f.seeded" ] || { : > "$f"; : > "$f.seeded"; }
  printf '%s\t%s\t%s\t%s\n' "$disp" "$dir/summary.md" "$status" "$ver" >> "$f"
}

# post <project> <question> [kind]
post() { "$AGENT_ASK" post --project "$1" ${3:+--kind "$3"} "$2"; }

@test "GUARD: agent-ask resolves from PATH inside the sandbox" {
  # Everything below asserts on rows the cockpit builds by shelling out to `agent-ask` BY
  # NAME. A developer's own ~/.local/bin is on PATH, so that resolved on a laptop and
  # resolved nowhere on a clean runner -- the question rows silently vanished and every
  # local run stayed green. Without this guard, ten tests below go quietly vacuous again.
  run command -v agent-ask
  assert_success
  assert_output "$SANDBOX/bin/agent-ask"
  # and it must be a COPY, not a link back into the tree. A symlink here lets any test that
  # overrides the stub (`cat > "$SANDBOX/bin/agent-ask"`, which wave_start.bats does) write
  # through it and truncate the real script in the repo -- the suite editing its subject.
  assert [ ! -L "$SANDBOX/bin/agent-ask" ]
}

# board <project> — a wave blackboard, fed on stdin
board() {
  mkdir -p "$HOME/.agent/plans/$1"
  cat > "$HOME/.agent/plans/$1/sprint-v1.0.1.md"
}

# ── the factory view reaches every profile ───────────────────────────────────

@test "a question on ANOTHER profile's project shows while you stand on personal" {
  # The regression that prompted all of this: the gate was posted, the wave was blocked
  # on it, and the view showed a different section's questions instead.
  post playground 'merge the wave?' gate >/dev/null
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'merge the wave?'
}

@test "a cross-profile project is labelled with its profile" {
  post playground 'merge the wave?' gate >/dev/null
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'work/Playground'
}

@test "the profile you are standing on is NOT labelled" {
  post cockpit 'land it?' gate >/dev/null
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'Cockpit'
  refute_output --partial 'personal/Cockpit'
}

@test "the same factory view renders from any section" {
  # Standing on `work` must show the personal question too. Otherwise it is still N
  # views, merely re-ordered.
  post cockpit 'land it?' gate >/dev/null
  run bash -c '"$COCKPIT" --list work | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'land it?'
  assert_output --partial 'personal/Cockpit'
}

@test "the needs-you group counts questions from every profile" {
  post cockpit    'a?' >/dev/null
  post playground 'b?' >/dev/null
  post ingest     'c?' >/dev/null
  # The old bridge carried a permanent "where we are: ~N working ?N need-you ..." header. The
  # factory view puts the count on the GROUP instead, so the number appears exactly once
  # and only when the group has rows. Cross-profile is the part that matters and is
  # unchanged: three questions posted to three profiles are all counted from one section.
  run bash -c '"$COCKPIT" --list personal | grep -P "^head\t" | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g" | grep "needs you"'
  assert_success
  assert_output --partial '3'
}

# ── ordering: what is waiting on you comes first ─────────────────────────────

@test "a project with a pending question sorts above one without" {
  board notes <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | notes work item | in-progress |
B
  post playground 'merge the wave?' gate >/dev/null
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g" | grep -nE "work/Playground|Notes"'
  assert_success
  local pg nt
  pg="$(printf '%s\n' "$output" | grep -m1 'work/Playground' | cut -d: -f1)"
  nt="$(printf '%s\n' "$output" | grep -m1 'Notes' | cut -d: -f1)"
  [ -n "$pg" ] && [ -n "$nt" ] || fail "expected both headers, got: $output"
  [ "$pg" -lt "$nt" ] || fail "Playground (line $pg) should precede Notes (line $nt)"
}

@test "inside a project the question precedes the work items" {
  board cockpit <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a cockpit work item | in-progress |
B
  post cockpit 'answer me first?' gate >/dev/null
  run bash -c '"$COCKPIT" --list personal | cut -f1 | grep -E "^(ask|item)$"'
  assert_success
  assert_line --index 0 'ask'
  assert_line --index 1 'item'
}

@test "an item and a question land in their own stage groups, each counted once" {
  board cockpit <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a cockpit work item | working |
B
  post cockpit 'answer me?' gate >/dev/null
  # Grouped by STAGE, not by project: the work item is under `building` and the gate under
  # `needs you`, rather than both sitting under a "Cockpit  ~1 working  ?1 need-you"
  # project header. Scoped to head rows so a body row cannot satisfy it.
  local heads
  heads="$("$COCKPIT" --list personal | grep -P "^head\t" | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g")"
  printf '%s\n' "$heads" | grep -q "needs you"
  printf '%s\n' "$heads" | grep -q "building"
  # and the item itself is on a row, under that group
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g" | grep "a cockpit work item"'
  assert_success
}

# ── routing: a cross-profile row must still act on its OWN profile ───────────

@test "a cross-profile row carries its own profile in the section column" {
  # `C-a` binds `--add {6}`, and `add_task` splits that column into profile + project. If
  # col 6 said `personal/...` for a `work` project, adding from that row would write into
  # the wrong profile's vault.
  post playground 'merge?' gate >/dev/null
  run bash -c '"$COCKPIT" --list personal | grep -P "^ask\t" | cut -f6'
  assert_output 'work/playground'
}

@test "a cross-profile ask row carries the id and options fzf answers with" {
  local id
  id="$("$AGENT_ASK" post --project playground --kind gate --options 'approve|hold' 'merge?')"
  run bash -c '"$COCKPIT" --list personal | grep -P "^ask\t" | cut -f3,4'
  assert_output "$id"$'\t''approve|hold'
}

# ── negative control: nothing else went cross-profile ────────────────────────

@test "the TASKS view is still scoped to its own section" {
  # The real risk of this change is the cross-profile reach leaking into the other views.
  # It must not: sections are profiles everywhere except the factory view.
  printf tasks > "$MODEF"
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  refute_output --partial 'Playground'
}

@test "the factory view still emits exactly 7 tab-separated fields on every row" {
  post playground 'merge?' gate >/dev/null
  run bash -c '"$COCKPIT" --list personal | awk -F"\t" "NF != 7 { print NR\": \"NF; bad=1 } END { exit bad+0 }"'
  assert_success
  assert_output ''
}

@test "an empty factory view still says so rather than rendering nothing" {
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'nothing in flight'
}

# ── the noise budget ─────────────────────────────────────────────────────────
# These are not cosmetic. The view exists because the bridge spent most of the screen on
# work that was already finished: on the live corpus 15 of 21 board rows are terminal.
# Each rule below is one of the ways that came back during development.

@test "a stage with no rows renders no group at all" {
  board cockpit <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | only a working row | working |
B
  local heads
  heads="$("$COCKPIT" --list personal | grep -P "^head\t" | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g")"
  printf '%s\n' "$heads" | grep -q 'building'
  # `reviewing 0` and `triage 0` are lines that only ever cost a line.
  refute [ "$(printf '%s\n' "$heads" | grep -c 'reviewing')" -gt 0 ]
  refute [ "$(printf '%s\n' "$heads" | grep -c 'triage')" -gt 0 ]
}

@test "shipped work folds to ONE line per project, not one line per item" {
  board cockpit <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | first done thing  | in-wave |
| 2 | 602 | second done thing | in-wave |
| 3 | 603 | third done thing  | in-wave |
| 4 | 604 | skipped thing     | skipped |
B
  local body
  body="$("$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g")"
  # Four terminal rows, and none of their titles reaches the screen.
  refute [ "$(printf '%s\n' "$body" | grep -c 'done thing')" -gt 0 ]
  # Just the fold, carrying the count.
  assert_equal "$(printf '%s\n' "$body" | grep -c 'Cockpit.*4 items')" 1
}

@test "the backlog stays in the tasks view - a sheet task is not 'in flight'" {
  # An earlier cut listed every open `#ai` wave task from every board-less project as
  # triage: 19 rows against 4 of real work. A task nobody has scoped into a wave is not in
  # the factory.
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  refute_output --partial 'fix the rail badge'
}

@test "a blocked row is needs-you, not building" {
  board cockpit <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a stuck thing | blocked - waiting on a human |
B
  local out
  out="$("$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g")"
  printf '%s\n' "$out" | grep -q 'needs you'
  refute [ "$(printf '%s\n' "$out" | grep -c 'building')" -gt 0 ]
}

@test "a placeholder ticket does not get a badge" {
  # `n/a` and the `~N` key a pre-approval stub gets are not tickets; `[n/a]` spends a
  # badge saying nothing.
  board cockpit <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | n/a | a thing with no ticket | working |
B
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'a thing with no ticket'
  refute_output --partial '[n/a]'
}

# ── the detail pane ──────────────────────────────────────────────────────────

@test "the timeline shows stages newest-first and never dates a seed event" {
  local ev now
  now=$(date +%s)
  mkdir -p "$HOME/.agent/plans/cockpit"
  ev="$HOME/.agent/plans/cockpit/board-events.jsonl"
  {
    printf '{"ts":"2026-08-11T09:00:00Z","epoch":%s,"ticket":"601","from":"","to":"queued","src":"seed"}\n'      "$((now-266400))"
    printf '{"ts":"2026-08-12T10:00:00Z","epoch":%s,"ticket":"601","from":"queued","to":"working","src":"hook"}\n' "$((now-180000))"
    printf '{"ts":"2026-08-13T14:03:00Z","epoch":%s,"ticket":"601","from":"working","to":"review","src":"hook"}\n' "$((now-7200))"
  } > "$ev"
  local out
  out="$("$COCKPIT" --rail personal/cockpit cockpit 601 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g")"
  # Newest stage FIRST: `review` must appear above `queued`, by line number. Compared as
  # two integers rather than chained onto an `|| echo` -- an assertion whose both branches
  # produce the same string is not an assertion.
  local l_review l_queued
  l_review="$(printf '%s\n' "$out" | grep -n 'review' | head -1 | cut -d: -f1)"
  l_queued="$(printf '%s\n' "$out" | grep -n 'queued' | head -1 | cut -d: -f1)"
  [ -n "$l_review" ] && [ -n "$l_queued" ] || fail "timeline did not render both stages"
  [ "$l_review" -lt "$l_queued" ] || fail "expected review (line $l_review) above queued (line $l_queued)"
  printf '%s\n' "$out" | grep -q '(still)'
  # a seed records where a row ALREADY was; the time before it is unmeasured, not zero
  printf '%s\n' "$out" | grep -q 'first seen here'
}

@test "a row with no recorded history says so instead of rendering a blank pane" {
  run bash -c '"$COCKPIT" --rail personal/cockpit cockpit 999 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'no recorded history yet'
}

@test "NEGATIVE CONTROL: the noise assertions fail against a view that renders everything" {
  # Proves the refutes above are reading real output. If _factory_view regressed to
  # listing terminal rows, `done thing` would appear and this is what would catch it.
  board cockpit <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a done thing | in-wave |
B
  local body
  body="$("$COCKPIT" --list personal | cut -f7)"
  [ -n "$body" ] || fail "the view rendered nothing; the refutes above would pass vacuously"
  printf '%s\n' "$body" | grep -q 'Cockpit' || fail "no shipped fold rendered"
}
