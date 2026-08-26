#!/bin/bash
# Stop-hook coordinator. Single Stop hook entrypoint, three phases:
#
#   pre-d   sequential, non-blocking, runs ALWAYS (incl. no-changes)
#           - session snapshots, anything that should fire even on Q&A turns
#   checks  parallel, exit-code aggregated, may BLOCK (exit 2)
#           - lint / typecheck / etc.; runs only when there are local changes
#   post-d  sequential, stdout/stderr passed through verbatim, may BLOCK
#           - eval-gate (emits JSON {decision:block,...} on stdout)
#
# Per-check exit codes (checks + post): 0 pass, 1 warn, 2 block, * block.
# Pre-checks: 0 ok, anything else = warn (non-blocking).
#
# Contract preserved with stop-post.d/90-eval-gate.sh:
#   Writes status=PASS|FAIL|SKIPPED and note=... to $CI_RESULT_FILE.
#
# Output policy - why this script is almost entirely silent:
#   A Stop hook's stderr is not a log. Per the hook contract, stderr from a hook that
#   exits 0 goes to the debug log and is never shown; but on exit 2 Claude Code turns the
#   ACCUMULATED stderr into the blocking message the model reads. So every unconditional
#   line printed on the success path is invisible right up until something blocks, and
#   then it becomes padding wrapped around the one instruction that mattered.
#   Hence two channels, and nothing is ever lost:
#     note   -> $LOG only (plus stderr when CLAUDE_STOP_VERBOSE=1)
#     emit   -> $LOG and stderr; reserved for what a human or the model must act on
#   $LOG always receives the full firehose, including every check's complete output.

set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-.}"

PAYLOAD=$(cat 2>/dev/null || echo '{}')

# --- CI result file (consumed by stop-post.d/90-eval-gate.sh) + the full-firehose log ---
. "$HOME/.config/shared-hooks/project-name.sh"
PROJ=$(resolve_project_name "${CLAUDE_PROJECT_DIR:-$PWD}")
DATE=$(date +%Y-%m-%d)
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook"
CI_RESULT_FILE="$CACHE_DIR/ci-result-${PROJ}-${DATE}.txt"
LOG="$CACHE_DIR/last-stop-${PROJ}.log"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

VERBOSE="${CLAUDE_STOP_VERBOSE:-0}"
# Lines of a failing check's output to replay inline. The tail, not the head: bats, cargo
# and the linters all put their summary last. The rest stays one `cat "$LOG"` away.
REPLAY_LINES="${CLAUDE_STOP_REPLAY_LINES:-40}"

note() {
  printf '%s\n' "$*" >>"$LOG" 2>/dev/null || true
  [ "$VERBOSE" = "1" ] && printf '%s\n' "$*" >&2
  return 0
}

emit() {
  printf '%s\n' "$*" >>"$LOG" 2>/dev/null || true
  printf '%s\n' "$*" >&2
}

# --- Phase 0: loop guard (before the log is truncated, so the blocking run's log survives) ---
if command -v jq >/dev/null 2>&1 \
   && [ "$(echo "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  note "pre-stop-checks: loop guard - already blocked once this turn, exiting clean"
  exit 0
fi

: >"$LOG" 2>/dev/null || true
note "=== stop-hook $(date -Is) proj=$PROJ cwd=$PWD ==="

write_result() {
  { echo "status=$1"; echo "note=$2"; echo "ts=$(date +%s)"; } > "$CI_RESULT_FILE" 2>/dev/null || true
}

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
HOOK_DIR="$(dirname "$SELF")"
PRE_DIR="$HOOK_DIR/stop-pre.d"
CHECKS_DIR="$HOOK_DIR/stop-checks.d"
POST_DIR="$HOOK_DIR/stop-post.d"

# --- run_post: sequential, stdout/stderr passed through. Returns max exit code. ---
run_post() {
  local dir="$1" worst=0 rc
  [ -d "$dir" ] || return 0
  for s in "$dir"/*.sh; do
    [ -x "$s" ] || continue
    # Forward original stdin (the JSON payload) so post-checks can see stop_hook_active
    bash "$s" < <(printf '%s' "$PAYLOAD")
    rc=$?
    [ "$rc" -gt "$worst" ] && worst=$rc
  done
  return "$worst"
}

# --- run_pre: sequential, never blocks. Just logs warnings. ---
run_pre() {
  local dir="$1" rc
  [ -d "$dir" ] || return 0
  for s in "$dir"/*.sh; do
    [ -x "$s" ] || continue
    bash "$s" < <(printf '%s' "$PAYLOAD") || {
      rc=$?
      note "[pre-warn] $(basename "$s" .sh) exit=$rc"
    }
  done
  return 0
}

# --- Phase 1: pre-d (always runs) ---
run_pre "$PRE_DIR"

# --- Phase 2: no-changes early-exit (still run post phase so eval-gate can skip cleanly) ---
if git rev-parse --git-dir >/dev/null 2>&1 \
   && git diff --quiet HEAD 2>/dev/null \
   && git diff --cached --quiet 2>/dev/null; then
  write_result "SKIPPED" "no local changes"
  run_post "$POST_DIR"
  exit $?
fi

# --- Informational: uncommitted/untracked state. Gates nothing, so it is log-only.
# "Uncommitted changes" is tautological here anyway: the clean-tree early-exit above is
# the only way past this point, so reaching it already means the tree is dirty. ---
if git rev-parse --git-dir >/dev/null 2>&1; then
  note "worktree: dirty (may be pre-existing)"
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | head -5)
  [ -n "$UNTRACKED" ] && note "untracked:" && note "$UNTRACKED"
fi

# --- Phase 3: parallel content checks ---
note "=== Running stop-hook checks in parallel ==="

OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

# Assigned empty, not merely declared: under `set -u` this bash throws "unbound variable"
# on ${#pids[@]} for a declared-but-unassigned array, so an empty stop-checks.d killed the
# hook on line 1 of the tally instead of reaching its "no executable checks" branch.
declare -a pids=() names=()
if [ -d "$CHECKS_DIR" ]; then
  for s in "$CHECKS_DIR"/*.sh; do
    [ -x "$s" ] || continue
    name=$(basename "$s" .sh)
    bash "$s" >"$OUT_DIR/$name.out" 2>"$OUT_DIR/$name.err" &
    pids+=("$!")
    names+=("$name")
  done
fi

CONTENT_BLOCKED=0
WARNED=0
declare -a notes=()

# replay <name> <sink>
# Full output always lands in $LOG. `sink` decides what reaches stderr: the last
# $REPLAY_LINES lines, with a pointer to $LOG when there was more than that.
replay() {
  local name="$1" sink="$2" combined total
  combined=$(cat "$OUT_DIR/$name.out" "$OUT_DIR/$name.err" 2>/dev/null)
  [ -n "$combined" ] || return 0
  printf '%s\n' "$combined" >>"$LOG" 2>/dev/null || true
  [ "$sink" = "note" ] && return 0
  total=$(printf '%s\n' "$combined" | wc -l)
  if [ "$total" -gt "$REPLAY_LINES" ]; then
    printf '%s\n' "$combined" | tail -n "$REPLAY_LINES" >&2
    printf '... %s earlier lines: %s\n' "$((total - REPLAY_LINES))" "$LOG" >&2
  else
    printf '%s\n' "$combined" >&2
  fi
}

if [ "${#pids[@]}" -eq 0 ]; then
  write_result "SKIPPED" "no executable checks"
else
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}"
    rc=$?
    name="${names[$i]}"
    case $rc in
      0) ;;
      # A warn does not block, so its stderr would be discarded by the hook contract
      # anyway -- until some LATER check blocks, at which point it joins the blocking
      # message as padding. Log-only is what it already effectively was.
      1)
        WARNED=1
        note "[WARN] $name"
        replay "$name" note
        notes+=("$name=warn")
        ;;
      *)
        CONTENT_BLOCKED=1
        emit "[FAIL] $name (exit $rc)"
        replay "$name" emit
        notes+=("$name=fail")
        ;;
    esac
  done

  # No closing banner on any path: [FAIL] already said it, and on the two quiet paths
  # a banner is the whole problem this policy exists to remove.
  if [ $CONTENT_BLOCKED -eq 1 ]; then
    note "=== Stop-hook checks FAILED ==="
    write_result "FAIL" "$(IFS=,; echo "${notes[*]}")"
  elif [ $WARNED -eq 1 ]; then
    write_result "PASS" "advisory: $(IFS=,; echo "${notes[*]}")"
    note "=== All stop-hook checks passed (with warnings) ==="
  else
    write_result "PASS" "all checks passed"
    note "=== All stop-hook checks passed ==="
  fi
fi

# --- Phase 4: post-d (eval-gate, etc.) - runs after PASS or FAIL ---
run_post "$POST_DIR"
POST_RC=$?

# --- Phase 5: aggregated exit ---
if [ $CONTENT_BLOCKED -eq 1 ]; then exit 2; fi
[ "$POST_RC" -gt 1 ] && exit "$POST_RC"
exit 0
