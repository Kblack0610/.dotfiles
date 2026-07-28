#!/usr/bin/env bats
# The bridge view, rendered as a real subprocess.
#
# The bridge is the ONE surface that is cross-profile, and it is the only view that is.
# That asymmetry is the point and also the risk: it has to reach every profile's projects
# while nothing else in the cockpit starts doing the same. Both directions are asserted
# here, because the failure that prompted it was silent -- a wave sat blocked on an
# approval gate one section over, and the bridge, showing only the section you happened to
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

  # The fixture's `projects.<profile>` column 2 is prose, but the cockpit treats it as the
  # summary PATH -- `canonical_of` takes its dirname and greps there for a
  # `<!-- canonical: -->` marker. Give every project a REAL directory, so canonical
  # resolution is deterministic and the recursive grep cannot wander out of the sandbox.
  VAULT="$HOME/vault"
  _project personal Cockpit    cockpit    'the tmux cockpit' 'v0.3'
  _project personal Notes      notes      'the notes CLI'    'v1.2'
  _project work     Playground playground 'client work'      'v2.0'
  _project client   Ingest     ingest     'blocked on access' 'v1.0'

  # bridge mode. MODEF is TMPDIR-rooted (notes-cockpit.sh:50) and TMPDIR is sandboxed.
  MODEF="$TMPDIR/notes-cockpit-$(id -u).mode"
  printf bridge > "$MODEF"
}

# _project <profile> <Display> <canonical> <status> <version>
# Writes the project dir + canonical marker and (re)declares the `notes` stub's row for it.
_project() {
  local prof="$1" disp="$2" canon="$3" status="$4" ver="$5"
  local dir="$VAULT/$prof/$canon"
  mkdir -p "$dir"
  printf '<!-- canonical: %s -->\n' "$canon" > "$dir/summary.md"
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

# board <canonical> — a wave blackboard, fed on stdin
board() {
  mkdir -p "$HOME/.agent/plans/$1"
  cat > "$HOME/.agent/plans/$1/sprint-v1.0.1.md"
}

# ── the bridge reaches every profile ─────────────────────────────────────────

@test "a question on ANOTHER profile's project shows while you stand on personal" {
  # The regression that prompted all of this: the gate was posted, the wave was blocked
  # on it, and the bridge showed a different section's questions instead.
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

@test "the same bridge renders from any section" {
  # Standing on `work` must show the personal question too. Otherwise it is still N
  # bridges, merely re-ordered.
  post cockpit 'land it?' gate >/dev/null
  run bash -c '"$COCKPIT" --list work | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'land it?'
  assert_output --partial 'personal/Cockpit'
}

@test "the where-we-are header counts questions from every profile" {
  post cockpit    'a?' >/dev/null
  post playground 'b?' >/dev/null
  post ingest     'c?' >/dev/null
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g" | grep "where we are"'
  assert_output --partial '?3 need-you'
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

@test "the project header carries a per-project tally" {
  board cockpit <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a cockpit work item | working |
B
  post cockpit 'answer me?' gate >/dev/null
  # Scoped to the PROJECT header, not any head row. The always-on "where we are" line uses
  # the same `~N working` / `?N need-you` vocabulary on purpose, so an unscoped match here
  # passes with or without the per-project tally -- a gate that cannot fail.
  run bash -c '"$COCKPIT" --list personal | grep -P "^head\t" | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g" | grep Cockpit'
  assert_success
  assert_output --partial '~1 working'
  assert_output --partial '?1 need-you'
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
  # It must not: sections are profiles everywhere except the bridge.
  printf tasks > "$MODEF"
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  refute_output --partial 'Playground'
}

@test "the bridge still emits exactly 7 tab-separated fields on every row" {
  post playground 'merge?' gate >/dev/null
  run bash -c '"$COCKPIT" --list personal | awk -F"\t" "NF != 7 { print NR\": \"NF; bad=1 } END { exit bad+0 }"'
  assert_success
  assert_output ''
}

@test "an empty bridge still says so rather than rendering nothing" {
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'nothing in flight'
}
