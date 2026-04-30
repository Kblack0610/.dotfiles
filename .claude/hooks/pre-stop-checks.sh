#!/bin/bash
# Stop-hook coordinator. Single Stop hook entrypoint, three phases:
#
#   pre-d   sequential, non-blocking, runs ALWAYS (incl. no-changes)
#           — session snapshots, anything that should fire even on Q&A turns
#   checks  parallel, exit-code aggregated, may BLOCK (exit 2)
#           — lint / typecheck / etc.; runs only when there are local changes
#   post-d  sequential, stdout/stderr passed through verbatim, may BLOCK
#           — eval-gate (emits JSON {decision:block,...} on stdout)
#
# Per-check exit codes (checks + post): 0 pass, 1 warn, 2 block, * block.
# Pre-checks: 0 ok, anything else = warn (non-blocking).
#
# Contract preserved with stop-post.d/90-eval-gate.sh:
#   Writes status=PASS|FAIL|SKIPPED and note=... to $CI_RESULT_FILE.

set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-.}"

# --- Phase 0: loop guard ---
PAYLOAD=$(cat 2>/dev/null || echo '{}')
if command -v jq >/dev/null 2>&1 \
   && [ "$(echo "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  echo "pre-stop-checks: loop guard — already blocked once this turn, exiting clean" >&2
  exit 0
fi

# --- CI result file (consumed by stop-post.d/90-eval-gate.sh) ---
PROJ=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
DATE=$(date +%Y-%m-%d)
CI_RESULT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook/ci-result-${PROJ}-${DATE}.txt"
mkdir -p "$(dirname "$CI_RESULT_FILE")" 2>/dev/null || true

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
      echo "[pre-warn] $(basename "$s" .sh) exit=$rc" >&2
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

# --- Informational: warn about uncommitted/untracked state (does not gate) ---
if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "WARNING: Uncommitted changes in worktree (may be pre-existing)" >&2
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | head -5)
  if [ -n "$UNTRACKED" ]; then
    echo "WARNING: Untracked files found (may need to be committed):" >&2
    echo "$UNTRACKED" >&2
  fi
fi

# --- Phase 3: parallel content checks ---
echo "=== Running stop-hook checks in parallel ===" >&2

OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

declare -a pids names
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
declare -a notes

if [ "${#pids[@]}" -eq 0 ]; then
  write_result "SKIPPED" "no executable checks"
else
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}"
    rc=$?
    name="${names[$i]}"
    case $rc in
      0) ;;
      1)
        WARNED=1
        echo "[WARN] $name" >&2
        [ -s "$OUT_DIR/$name.out" ] && cat "$OUT_DIR/$name.out" >&2
        [ -s "$OUT_DIR/$name.err" ] && cat "$OUT_DIR/$name.err" >&2
        notes+=("$name=warn")
        ;;
      *)
        CONTENT_BLOCKED=1
        echo "[FAIL] $name (exit $rc)" >&2
        [ -s "$OUT_DIR/$name.out" ] && cat "$OUT_DIR/$name.out" >&2
        [ -s "$OUT_DIR/$name.err" ] && cat "$OUT_DIR/$name.err" >&2
        notes+=("$name=fail")
        ;;
    esac
  done

  if [ $CONTENT_BLOCKED -eq 1 ]; then
    echo "=== Stop-hook checks FAILED ===" >&2
    write_result "FAIL" "$(IFS=,; echo "${notes[*]}")"
  elif [ $WARNED -eq 1 ]; then
    write_result "PASS" "advisory: $(IFS=,; echo "${notes[*]}")"
    echo "=== All stop-hook checks passed (with warnings) ===" >&2
  else
    write_result "PASS" "all checks passed"
    echo "=== All stop-hook checks passed ===" >&2
  fi
fi

# --- Phase 4: post-d (eval-gate, etc.) — runs after PASS or FAIL ---
run_post "$POST_DIR"
POST_RC=$?

# --- Phase 5: aggregated exit ---
if [ $CONTENT_BLOCKED -eq 1 ]; then exit 2; fi
[ "$POST_RC" -gt 1 ] && exit "$POST_RC"
exit 0
