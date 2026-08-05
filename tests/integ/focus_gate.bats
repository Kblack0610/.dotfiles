#!/usr/bin/env bats
# 86-focus-reconcile.sh: the end-of-turn half of the Focus loop. The preflight surfaces
# today's `## Focus` at turn 1; this blocks once per session when a turn changed code but
# never told the cockpit about it.
#
# The contract under test is "when does it block", and every quiet path matters as much as
# the loud one -- a gate that fires on idle turns would be trained away within a day.
# HOME is sandboxed, so the state file, the notes log and the daily note all land in the
# test tmpdir; the git repo is real but disposable.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  GATE="$REPO_ROOT/.claude/hooks/stop-post.d/86-focus-reconcile.sh"

  # The gate sources these from the sandboxed HOME, exactly as it does on a real machine.
  mkdir -p "$HOME/.config/shared-hooks" "$HOME/.local/state/notes"
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/"

  NOTE="$HOME/.notes/journal/daily/$(date +%F).md"
  NOTES_LOG="$HOME/.local/state/notes/journal.log"
  mkdir -p "$(dirname "$NOTE")"

  # The sandbox `notes` stub has no vault; point `notes path daily` at our fixture note.
  cat > "$SANDBOX/bin/notes" <<EOF
#!/usr/bin/env bash
printf 'notes %s\n' "\$*" >> "\$NOTES_FIXTURE/calls.log"
[ "\${1:-}" = "path" ] && [ "\${2:-}" = "daily" ] && echo "$NOTE" && exit 0
exit 0
EOF
  chmod +x "$SANDBOX/bin/notes"

  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q .
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo one > "$REPO/a.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm one
  export CLAUDE_PROJECT_DIR="$REPO"

  focus '- [ ] open thing (2d)'
}

# focus <lines...> -- rewrite today's note with the given Focus body.
focus() {
  { echo '# today'; echo; echo '## Focus'; printf '%s\n' "$@"; } > "$NOTE"
}

dirty()  { echo more >> "$REPO/a.txt"; }
commit() { git -C "$REPO" add -A; git -C "$REPO" commit -qm next; }

# gate <session-id> [stop_hook_active] -- run the hook, capture stdout.
gate() {
  printf '{"session_id":"%s","stop_hook_active":%s}' "$1" "${2:-false}" | bash "$GATE" 2>/dev/null
}

assert_blocks()  { [[ "$1" == *'"block"'* ]] || { echo "expected a block, got: ${1:-<empty>}" >&2; return 1; }; }
refute_blocks()  { [[ "$1" != *'"block"'* ]] || { echo "unexpected block: $1" >&2; return 1; }; }

# ── the quiet paths ──────────────────────────────────────────────────────────

@test "an idle turn -- clean tree, no new commit -- is silent" {
  refute_blocks "$(gate s1)"
}

@test "the loop guard is honoured" {
  dirty
  refute_blocks "$(gate s1 true)"
}

@test "CLAUDE_SKIP_FOCUS_GATE=1 disables it" {
  dirty
  CLAUDE_SKIP_FOCUS_GATE=1 refute_blocks "$(CLAUDE_SKIP_FOCUS_GATE=1 gate s1)"
}

@test "CLAUDE_HEADLESS=1 disables it -- a timer has nobody to answer the question" {
  # Regression: captain-watchdog fires `/captain watch` every 10 minutes. Blocked here,
  # the headless agent complied the only way it could -- `focus add` then `focus done` --
  # and 2026-08-04 accumulated 45 `captain watch pass` entries, burying the three real
  # ones. Asking "did you declare your work" only makes sense with a human to ask.
  dirty
  refute_blocks "$(CLAUDE_HEADLESS=1 gate s1)"
}

@test "the headless guard fails SAFE -- an unset marker still gates" {
  # The negative control for the test above. If the guard were inverted, or keyed on a
  # var that is always set, the gate would silently never fire again and nothing would
  # say so -- the exact silent-success failure mode this suite exists to catch.
  dirty
  assert_blocks "$(gate s1)"
}

@test "CLAUDE_HEADLESS=0 is not a disable" {
  # `[ "${CLAUDE_HEADLESS:-0}" = "1" ]` -- an explicitly-off marker must behave as unset,
  # so a runner that exports 0 does not think it opted out.
  dirty
  assert_blocks "$(CLAUDE_HEADLESS=0 gate s1)"
}

@test "an in-progress item means you already declared what you are on" {
  focus '- [/] the thing i am on (1d)' '- [ ] open thing (2d)'
  dirty
  refute_blocks "$(gate s1)"
}

@test "a focus write during this turn satisfies the gate" {
  dirty
  gate s1 >/dev/null                       # first run stamps last_run
  focus '- [ ] open thing (2d)' '- [ ] freshly added (0d)'
  sleep 1
  printf '[%s] [INFO] focus: added "freshly added"\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$NOTES_LOG"
  refute_blocks "$(gate s2)"
}

@test "a ptask write satisfies the gate -- project work need not touch the daily note" {
  # The daily note is ONE human's list. This gate used to accept only a write to it, so
  # every agent session satisfied it the only way it could and dumped its own item there:
  # 2026-08-05 opened with six Focus items, five of them agent sessions'. Project work
  # tracked on the project's `## Wave` must count, or the note keeps getting crowded out.
  dirty
  gate s1 >/dev/null                       # stamp last_run
  sleep 1
  printf '[%s] [INFO] ptask: added to /p/README.md (notes-cockpit)\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$NOTES_LOG"
  refute_blocks "$(gate s2)"
}

@test "an UNRELATED notes write does not satisfy the gate" {
  # The negative control for the test above. If the log match were loosened to any `notes`
  # line, a passing `notes today` on shell init would silently satisfy the gate forever and
  # nothing would ever be tracked again -- a gate that always passes is not a gate.
  dirty
  gate s1 >/dev/null
  sleep 1
  printf '[%s] [INFO] today: exists /p/2026-08-05.md\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$NOTES_LOG"
  assert_blocks "$(gate s2)"
}

@test "it fires at most once per session" {
  dirty
  assert_blocks "$(gate s1)"
  refute_blocks "$(gate s1)"
  refute_blocks "$(gate s1)"
}

@test "it stays silent outside a git repo" {
  export CLAUDE_PROJECT_DIR="$SANDBOX"
  refute_blocks "$(gate s1)"
}

# ── the loud paths ───────────────────────────────────────────────────────────

@test "a dirty tree with nothing tracked blocks" {
  dirty
  assert_blocks "$(gate s1)"
}

@test "a committed, clean tree still counts as work" {
  # Work that got committed and merged leaves no dirt behind. That is a shipped turn,
  # not an idle one, so HEAD movement has to count or the gate misses real deliveries.
  gate s0 >/dev/null                       # stamp last_head
  dirty
  commit
  assert_blocks "$(gate s1)"
}

@test "a new session blocks again" {
  dirty
  assert_blocks "$(gate s1)"
  refute_blocks "$(gate s1)"
  assert_blocks "$(gate s2)"
}

@test "a focus write from before the last run does not count" {
  dirty
  gate s0 >/dev/null                       # establish a last_run mark
  sleep 1
  printf '[%s] [INFO] focus: added "ancient"\n' "$(date -d '2 hours ago' +%Y-%m-%dT%H:%M:%S%z)" >> "$NOTES_LOG"
  assert_blocks "$(gate s1)"
}

@test "on a first run an old focus write does not fail the gate open" {
  # No state file means no turn window. A bare epoch 0 would make every focus write ever
  # logged look like it just happened, silently skipping the gate once per project.
  dirty
  printf '[%s] [INFO] focus: added "ancient"\n' "$(date -d '2 hours ago' +%Y-%m-%dT%H:%M:%S%z)" >> "$NOTES_LOG"
  assert_blocks "$(gate s1)"
}

@test "on a first run a focus write from seconds ago still counts" {
  dirty
  printf '[%s] [INFO] focus: added "just now"\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$NOTES_LOG"
  refute_blocks "$(gate s1)"
}

@test "a notes-today write is not a focus write" {
  # Backticks are deliberately absent from this test name: bats evaluates the name string,
  # so a quoted `notes today` in it would actually run the command.
  #
  # Only `focus:` lines count. `today:` refreshes Watches/Comms on its own schedule and
  # would otherwise satisfy the gate without anyone tracking anything.
  dirty
  sleep 1
  printf '[%s] [INFO] today: refreshed ## Comms (1 item(s))\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$NOTES_LOG"
  assert_blocks "$(gate s1)"
}

# ── the message ──────────────────────────────────────────────────────────────

@test "the block reason names the three verbs and lists what is open" {
  focus '- [ ] first open (2d)' '- [ ] second open (5d)'
  dirty
  local reason
  reason="$(gate s1 | jq -r '.reason')"
  assert [ -n "$reason" ]
  [[ "$reason" == *'notes focus start'* ]]
  [[ "$reason" == *'notes focus add'* ]]
  [[ "$reason" == *'notes focus done'* ]]
  [[ "$reason" == *'first open (2d)'* ]]
  [[ "$reason" == *'second open (5d)'* ]]
}

@test "the block reason is valid JSON on stdout, and the hook still exits 0" {
  dirty
  run bash -c "printf '{\"session_id\":\"s1\",\"stop_hook_active\":false}' | bash '$GATE'"
  assert_success                            # exit 2 would hand Claude the coordinator's stderr instead
  echo "$output" | jq -e '.decision == "block"' >/dev/null
}

@test "it copes with a day that has no open items at all" {
  focus ''
  dirty
  local reason
  reason="$(gate s1 | jq -r '.reason')"
  [[ "$reason" == *'nothing open today'* ]]
}
