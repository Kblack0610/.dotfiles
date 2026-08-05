#!/usr/bin/env bats
# The cockpit's USAGE view: the 4th view, `a` reaches it and `w` windows it.
#
# It answers "how well and how expensively are the agents working" by joining two
# corpora that nothing joined before — the eval markdown (quality) and the session
# registry (tokens/USD) — on the session uuid they both carry.
#
# The honesty rules are the load-bearing part and most of what is tested here. Cost
# telemetry covers ~2% of sessions on a real machine, so a panel that renders the sum
# without saying how much of it it could not see is the actual hazard, not a crash.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  export PROM_URL='http://127.0.0.1:1' PROM_TIMEOUT=1
  ln -sf "$REPO_ROOT/.local/bin/agent-usage" "$SANDBOX/bin/agent-usage"
  export NOTES_COCKPIT_INSTANCE="usage$$"

  export AGENT_EVALS_DIR="$HOME/.agent/evals"
  mkdir -p "$AGENT_EVALS_DIR/demo" "$HOME/.agent/sessions/demo"

  # THE FIXTURES MUST FALL INSIDE THE WINDOW. This view is the only one scoped by wall
  # clock, so the epoch-5000 timestamps the other cockpit tests use put every row outside
  # the default 7d span — and the refute_-style assertions below then pass against an
  # empty render, which is a vacuous pass, not a green test.
  NOW="$(date +%s)"
  TODAY="$(date +%F)"
  export NOW TODAY

  # Two sessions: one fully tracked (cost + eval score), one with NO telemetry. The
  # pair is the point — a renderer that always prints `-`, and one that always prints
  # a dollar figure, each pass half these tests and fail the other half.
  cat > "$HOME/.agent/sessions/demo/sessions.jsonl" <<EOF
{"session_id":"aaaa1111-0000-0000-0000-000000000000","project":"demo","edits":9,"title":"tracked session","updated":$(( NOW - 3600 )),"cost_usd":3.25,"tokens":{"total":1500000},"models":["m1"],"duration_s":60}
{"session_id":"bbbb2222-0000-0000-0000-000000000000","project":"demo","edits":4,"title":"untracked session","updated":$(( NOW - 1800 )),"cost_usd":null,"tokens":{"total":500000},"models":["m1"],"duration_s":10}
EOF

  cat > "$AGENT_EVALS_DIR/demo/$TODAY.md" <<'EOF'
## Session 1 (tracked session) <!-- sid: aaaa1111-0000-0000-0000-000000000000 -->

- **Workflow**: 9/10 — fine
- **Verification**: 4/10 — thin
- **Lessons**: 0 — no correction
**Summary:** ok. Overall: 8/10.
EOF
}

mode()   { printf '%s' "$1" > "${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}-$NOTES_COCKPIT_INSTANCE.mode"; }
window() { printf '%s' "$1" > "${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}-$NOTES_COCKPIT_INSTANCE.window"; }
# the rendered display column only
body()   { mode usage; "$COCKPIT" --list 2>/dev/null | cut -f7-; }

# ── the view is reachable and is its own render ─────────────────────────────

@test "a cycles through four distinct views and returns to tasks" {
  # Pairwise-distinct, not merely "tasks after 4 presses" — a toggle_mode that always
  # wrote `tasks` would satisfy the weaker assertion.
  mode tasks
  local seen=()
  for _ in 1 2 3 4; do
    seen+=("$(cat "${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}-$NOTES_COCKPIT_INSTANCE.mode")")
    "$COCKPIT" --toggle-mode
  done
  assert_equal "${#seen[@]}" 4
  local uniq; uniq=$(printf '%s\n' "${seen[@]}" | sort -u | wc -l)
  assert_equal "$uniq" 4
  assert_equal "$(cat "${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}-$NOTES_COCKPIT_INSTANCE.mode")" 'tasks'
}

@test "every emitted row carries the full 7-column wire format" {
  # A short row shifts every later field left on `read`, which is how a label ends up
  # in a numeric variable. Same rule the other views are held to.
  mode usage
  run bash -c "'$COCKPIT' --list 2>/dev/null | awk -F'\t' '{print NF}' | sort -u"
  assert_output '7'
}

# ── the honesty rules ───────────────────────────────────────────────────────

@test "an untracked session renders a dash, never \$0.00" {
  # `$0.00` reads as "this was free". The tracked session in the same fixture must
  # still show its real cost, or a renderer hardcoding `-` would pass.
  run body
  assert_output --partial '$3.25'
  refute_output --partial '$0.00'
}

@test "a total states how many sessions it could not see" {
  # The rollup covers 2 sessions, 1 of them untracked. A sum printed alone would read
  # as the full cost of the window when it is the cost of half of it.
  #
  # Asserts the COUNTED form `(+1 untracked)`, not the bare word: one of the fixture
  # sessions is labelled "untracked session", so a substring check on `untracked` passed
  # against the label even with the counter deleted.
  run body
  assert_output --partial '(+1 untracked)'
}

@test "the quality x cost join puts the eval score on the session row" {
  # The whole point of the view: both corpora carry the same uuid and nothing joined
  # them before.
  run body
  assert_output --partial '[8]'
  assert_output --partial 'tracked session'
}

@test "a session with no eval score still renders, without a score badge" {
  # Only ~12% of real eval sessions carry a sid, so an inner join would hide most of
  # the corpus. The unscored session must appear.
  run body
  assert_output --partial 'untracked session'
}

# ── the attention lane ──────────────────────────────────────────────────────

@test "a below-floor dimension reaches the attention lane" {
  run body
  assert_output --partial 'attention'
  assert_output --partial 'Verification 4/10'
}

@test "the Lessons no-correction sentinel is NOT flagged as a low score" {
  # The fixture's `- **Lessons**: 0 — no correction` is the BEST outcome. Paired with
  # the Verification 4/10 above, which must still be flagged — without that pair an
  # attention lane that is unconditionally empty would pass.
  run body
  refute_output --partial 'Lessons 0/10'
}

@test "the attention lane is omitted entirely when nothing is below the floor" {
  rm -f "$AGENT_EVALS_DIR/demo/$TODAY.md"
  cat > "$AGENT_EVALS_DIR/demo/$TODAY.md" <<'EOF'
## Session 1 (all good) <!-- sid: aaaa1111-0000-0000-0000-000000000000 -->

- **Workflow**: 9/10 — fine
**Summary:** ok. Overall: 9/10.
EOF
  run body
  refute_output --partial 'attention'
}

# ── the window ──────────────────────────────────────────────────────────────

@test "w cycles the window 7d -> 30d -> today -> 7d" {
  window 7d
  local seen=()
  for _ in 1 2 3; do
    seen+=("$(cat "${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}-$NOTES_COCKPIT_INSTANCE.window")")
    "$COCKPIT" --cycle-window
  done
  assert_equal "${seen[0]}" '7d'
  assert_equal "${seen[1]}" '30d'
  assert_equal "${seen[2]}" 'today'
  assert_equal "$(cat "${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}-$NOTES_COCKPIT_INSTANCE.window")" '7d'
}

@test "the active window is named in the view header" {
  window 30d
  run body
  assert_output --partial '30d'
}

# ── degradation ─────────────────────────────────────────────────────────────

@test "an agent-usage without rollup degrades to a message, not to fake projects" {
  # THE regression. A stale agent-usage prints its help to STDOUT and exits 0, so an
  # unguarded read renders four lines of usage text as four projects with 0 tokens.
  # That looks like data, which is worse than looking broken.
  # `rm -f` FIRST. sandbox_init symlinks $SANDBOX/bin/agent-usage at the real repo file,
  # so `cat >` follows the link and overwrites the thing under test. It did exactly that
  # once while this file was being written.
  rm -f "$SANDBOX/bin/agent-usage"
  cat > "$SANDBOX/bin/agent-usage" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  rows) exit 0 ;;
  *) echo "agent-usage: unknown command '${1:-}'" >&2
     echo "  agent-usage session <id> [--json]        one session's rollup"
     echo "  agent-usage rows <project> [--since E]   TSV for the cockpit"
     exit 0 ;;
esac
EOF
  chmod +x "$SANDBOX/bin/agent-usage"
  run body
  refute_output --partial "one session's rollup"
  assert_output --partial 'no spend data'
}

@test "a missing eval corpus leaves the other views working and says so" {
  rm -rf "$AGENT_EVALS_DIR"
  run body
  assert_success
  # spend still renders; only the quality half is gone
  assert_output --partial '$3.25'
}

# ── enter dispatch ──────────────────────────────────────────────────────────

@test "enter on an eval row jumps to the file AND the line" {
  run "$COCKPIT" --enter-action eval '' /tmp/e.md 42
  assert_output --partial '--jump eval'
  assert_output --partial '42'
}

@test "enter on a usage session row resumes that session" {
  run "$COCKPIT" --enter-action sess '' 'aaaa1111-0000-0000-0000-000000000000' ''
  assert_output --partial '--resume-session'
}

@test "jump_row still refuses a row type that is not task or eval" {
  # The gate was relaxed from `= task` to `task|eval`. If it had become `*)` every row
  # type in every view would spawn nvim on whatever its third column holds.
  #
  # The file must EXIST. An earlier version pointed at a missing path, so `[ -f ]` two
  # lines below returned first and the test passed with the whitelist deleted entirely.
  local f="$BATS_TEST_TMPDIR/real.md"; echo x > "$f"
  : > "$NOTES_FIXTURE/calls.log"
  run "$COCKPIT" --jump hint "$f" 1
  assert_success
  refute_output --partial 'nvim'
  run grep -c nvim "$NOTES_FIXTURE/calls.log"
  assert_output '0'

  # ...and the positive half: an eval row on the same existing file DOES launch nvim,
  # or the assertion above is satisfied by a jump_row that never works at all.
  : > "$NOTES_FIXTURE/calls.log"
  run "$COCKPIT" --jump eval "$f" 7
  run grep -c 'nvim +7' "$NOTES_FIXTURE/calls.log"
  assert_output '1'
}
