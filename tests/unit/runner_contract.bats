#!/usr/bin/env bats
# The runner status contract, and who is actually on it.
#
# `agentctl` defines five keys in fixed order, atomically replaced, with states
# working|idle|ok|blocked|error - and `blocked` meaning specifically "a healthy process
# waiting on a human", which is the one thing a systemd unit state can never express.
#
# A runner that writes nothing leaves the fleet view answering "is the unit active"
# rather than "what is it doing".
#
# The conformance test below is the part that matters long-term: it is what stops the
# fleet drifting back to one adopter.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  # The real HOME, captured BEFORE the sandbox redirects it. The conformance test below
  # deliberately inspects the machine's actual roster - a fixture roster could only ever
  # confirm the fixture.
  REAL_HOME="$HOME"
  load '../helpers/sandbox'
  sandbox_init basic
  export REAL_HOME
}

# ── the glyph precedence ─────────────────────────────────────────────────────

# render_runner <reported-state> <systemd-ActiveState> -> the glyph fleet.sh would pick
#
# Lifted from fleet.sh's precedence chain rather than driving the whole function, which
# would need a systemd. The assertion is about which source WINS, not about formatting.
_glyph_for() {
  local r_state="$1" state="$2"
  local G_ATTN='!' G_BUSY='~' G_IDLE='.' rc=0
  if [ "$r_state" = blocked ] || [ "$r_state" = error ]; then echo "$G_ATTN"
  elif [ "$r_state" = working ]; then echo "$G_BUSY"
  elif [ "$state" = active ]; then echo "$G_BUSY"
  elif [ -n "$rc" ] && [ "$rc" != 0 ]; then echo "$G_ATTN"
  else echo "$G_IDLE"
  fi
}

@test "a runner reporting working shows busy even when its unit is inactive" {
  # A runner that detaches with setsid leaves its unit inactive for the whole pass. The
  # contract says working, so the glyph must too, not dim-idle.
  assert_equal "$(_glyph_for working inactive)" '~'
}

@test "blocked and error still outrank the unit state" {
  assert_equal "$(_glyph_for blocked active)" '!'
  assert_equal "$(_glyph_for error active)" '!'
}

@test "a runner that reports nothing still falls back to the unit state" {
  # Adoption is per-runner, never a flag day - a non-adopter must keep working.
  assert_equal "$(_glyph_for '' active)" '~'
  assert_equal "$(_glyph_for '' inactive)" '.'
}

@test "fleet.sh actually contains the working branch" {
  # The helper above is a model of the real chain; this pins the real chain to it.
  run grep -F 'r_state" = working' "$FLEET"
  assert_success
}

# ── conformance: is the fleet still on the contract? ─────────────────────────

# There are TWO publishing mechanisms and they are complementary, not rivals:
#
#   agentctl report -> <state-dir>/<name>/status
#       state|project|item|detail|updated. Answers "what is this doing RIGHT NOW", and is
#       the only way to say `blocked` - a healthy process waiting on a human.
#
#   proof_report    -> <state-dir>/<name>/{last-outcome,activity.log}
#       WORKED|NOOP|STALLED. Answers "did the last run accomplish anything", which is the
#       anti-stall question systemd cannot answer either (a plan-mode run exits 0 having
#       done nothing). fleet.sh already tails activity.log when `item` is empty.
#
# A runner is conformant if it publishes through EITHER. Requiring `agentctl report`
# specifically would flag four runners that adopted the newer proof contract, which would
# be a false positive - the point of this test is drift, not uniformity for its own sake.
_publishes() { # <script path>
  grep -qE 'agentctl report|proof_report' "$1" 2>/dev/null
}

# Runners that publish through neither. Each needs a reason; an empty list is the goal.
#
# The silent one is `comms`. The roster-wide assertion that would catch it ships with the
# PRIVATE change which fixes it - that script and the conf dir both live in the private
# overlay, and a test that is red the day it lands only teaches people to ignore red.
_known_non_adopters() {
  cat <<'EOF'
comms
EOF
}

# ── one launcher ─────────────────────────────────────────────────────────────
#
# agentctl-run is the only headless claude entry: it applies the role, the route and
# the transport scrub. A `claude -p` anywhere else skips all three, which is how
# ask-resume and `sessions compact` ran for months on no role at all.
#
# The scan is fleet-bench's, so the ledger and this test cannot disagree.
headless_launches() { "$REPO_ROOT/.local/bin/fleet-bench" ledger --launches "$@"; }

@test "nothing in the repo launches a headless claude except agentctl-run" {
  run headless_launches "$REPO_ROOT/.local"
  assert_output ''
  run headless_launches "$REPO_ROOT/.config"
  assert_output ''
  run headless_launches "$REPO_ROOT/.claude/hooks"
  assert_output ''
}

@test "the launcher scan catches a direct claude -p (negative control)" {
  local d="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$d"
  printf '#!/bin/sh\n# claude -p in a comment is fine\nclaude -p "do it" --max-turns 5\n' > "$d/runner"
  printf '#!/bin/sh\nprintf x | "$CLAUDE_BIN" --print\n' > "$d/piped"
  run headless_launches "$d"
  assert_line --partial 'runner:3:'
  assert_line --partial 'piped:2:'
  refute_output --partial 'runner:2:'
}
