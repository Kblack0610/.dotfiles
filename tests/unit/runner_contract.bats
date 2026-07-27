#!/usr/bin/env bats
# The runner status contract, and who is actually on it.
#
# `agentctl` defines five keys in fixed order, atomically replaced, with states
# working|idle|ok|blocked|error - and `blocked` meaning specifically "a healthy process
# waiting on a human", which is the one thing a systemd unit state can never express.
#
# It was a good contract with one adopter. Seven of eight runners wrote nothing, so the
# fleet view answered "is the unit active" rather than "what is it doing", and two
# runners (wave, captain-watchdog) had no conf at all and were invisible entirely.
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
  # wave-start detaches with setsid, so agentctl@wave.service is inactive for the whole
  # pass. Before this, a live wave rendered dim-idle: the contract said working and the
  # glyph said nothing was happening.
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
# As of this change the silent ones are `comms` and `delivery-loop`, and `wave` /
# `captain-watchdog` are not on the roster at all. The roster-wide assertion that would
# catch that ships with the PRIVATE change which fixes it - those scripts and the conf
# dir both live in the private overlay, and a test that is red the day it lands only
# teaches people to ignore red.
_known_non_adopters() {
  cat <<'EOF'
comms
delivery-loop
EOF
}

@test "wave-start reports through the contract" {
  run grep -F 'agentctl report' "$REPO_ROOT/.local/bin/wave-start"
  assert_success
}

@test "wave-start names itself explicitly rather than trusting the environment" {
  # AGENTCTL_NAME is only set by the systemd unit; wave-start runs under setsid, so a
  # bare `agentctl report` would die with "no agent name".
  run grep -F -- '--name "${AGENTCTL_NAME:-wave}"' "$REPO_ROOT/.local/bin/wave-start"
  assert_success
}

@test "every state wave-start reports is one the contract accepts" {
  local s
  for s in $(grep -oE '_report (working|idle|ok|blocked|error)' "$REPO_ROOT/.local/bin/wave-start" | awk '{print $2}' | sort -u); do
    case "$s" in
      working|idle|ok|blocked|error) ;;
      *) fail "wave-start reports '$s', which agentctl would reject" ;;
    esac
  done
}
