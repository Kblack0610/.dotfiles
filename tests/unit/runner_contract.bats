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
# Which runners publish is not checked here: the roster is the private overlay's confs, so
# tests/runner-outcome.bats in ~/.dotfiles-private checks that every enabled runner's COMMAND
# declares an outcome (agentctl report, proof_report, proof_outcome or proof_runner_outcome).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
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

# ── one launcher ─────────────────────────────────────────────────────────────
#
# agentctl-run is the only headless claude entry: it applies the role, the route and
# the transport scrub. A `claude -p` anywhere else skips all three, which is how
# ask-resume and `sessions compact` ran for months on no role at all.
#
# The scan is fleet-bench's, so the ledger and this test cannot disagree.
headless_launches() { "$REPO_ROOT/.local/bin/fleet-bench" ledger --launches "$@"; }

@test "nothing in the repo launches a headless claude except agentctl-run" {
  # A launch outside agentctl-run lives under .local, in a file with its row in PIPELINES.md's
  # "Model calls outside agentctl-run" table. That table is the per-file allowlist for both repos:
  # `fleet-bench ledger --check` holds CI to it (launches_unlisted), and pipelines_doc.bats runs the
  # same check over both checkouts here. This test keeps what holds with no private overlay: no
  # launch in any other tree.
  run headless_launches "$REPO_ROOT/.config"
  assert_output ''
  run headless_launches "$REPO_ROOT/.claude/hooks"
  assert_output ''
  run headless_launches "$REPO_ROOT/.claude/skills"
  assert_output ''
}

# A human start runs on the account `claude-acct run` picks, the choice `cl` makes; an unattended
# one picks through agentctl-run. A bare `exec claude` anywhere else runs on whatever account
# its caller inherited. These files are the launchers themselves.
session_launches() {
  (cd "$1" && git grep --no-index --exclude-standard -nIE \
    '\b(exec|command)[[:space:]]+"?claude"?([[:space:]]|$)|"claude -r' \
    -- . ':!*.md' ':!tests/**' ':!**/tests/**') \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//|echo )' \
    | grep -vE '^(\.ai-rc|\.local/bin/(claude-acct|claude-lazer)|\.local/src/agent-run/harnesses/claude\.sh):'
}

@test "every claude session start goes through claude-acct run or agentctl-run" {
  run session_launches "$REPO_ROOT"
  assert_output ''
}

@test "the session launcher scan catches a bare exec claude (negative control)" {
  local d="$BATS_TEST_TMPDIR/launch"
  mkdir -p "$d/.local/bin" "$d/kdl"
  printf '#!/bin/sh
# exec claude in a comment is fine
exec claude -r "$id"
exec claude-acct run -r "$id"
' > "$d/.local/bin/resume"
  printf 'pane {
    command "claude"
}
' > "$d/kdl/hub.kdl"
  printf '#!/bin/sh
exec claude "$@"
' > "$d/.local/bin/claude-acct"
  run session_launches "$d"
  assert_line --partial 'resume:3:'
  assert_line --partial 'hub.kdl:2:'
  refute_output --partial 'resume:2:'
  refute_output --partial 'resume:4:'
  refute_output --partial 'claude-acct:'
}

@test "the launcher scan catches a direct claude -p (negative control)" {
  local d="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$d"
  printf '#!/bin/sh\n# claude -p in a comment is fine\nclaude -p "do it" --max-turns 5\n' > "$d/runner"
  printf '#!/bin/sh\nprintf x | "$CLAUDE_BIN" --print\n' > "$d/piped"
  printf '#!/bin/sh\n# codex exec in a comment is fine\n"$CODEX_BIN" exec --json "do it"\n' > "$d/cx"
  printf '#!/bin/sh\n# OpenAI chat/completions in prose is fine\ncurl -s "$BASE/v1/chat/completions" -d @q\ncurl -s https://api.anthropic.com/v1/messages\n' > "$d/http"
  run headless_launches "$d"
  assert_line --partial 'runner:3:'
  assert_line --partial 'piped:2:'
  assert_line --partial 'cx:3:'
  refute_output --partial 'cx:2:'
  assert_line --partial 'http:3:'
  assert_line --partial 'http:4:'
  refute_output --partial 'runner:2:'
  refute_output --partial 'http:2:'
}

@test "only agent-run's own harnesses may call a model's HTTP API (negative control)" {
  local d="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$d/src/agent-run/harnesses" "$d/src/agent-run/lib"
  printf '#!/bin/sh\ncurl -s "${LLM_BASE_URL%%/}/chat/completions" -d @-\n' > "$d/src/agent-run/harnesses/raw.sh"
  cp "$d/src/agent-run/harnesses/raw.sh" "$d/src/agent-run/lib/sneak.sh"
  run headless_launches "$d"
  assert_line --partial 'lib/sneak.sh:2:'
  refute_output --partial 'harnesses/raw.sh'
}
