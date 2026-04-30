#!/bin/bash
# Stop-hook coordinator: fans out checks in `stop-checks.d/` in parallel,
# waits for all to finish, aggregates exit codes into a single verdict.
#
# Per-check exit-code convention:
#   0 = pass (or check not applicable)
#   1 = warn / advisory (printed to stderr; does not block)
#   2 = block            (coordinator exits 2; Claude is gated)
#   *  = treated as block (defensive)
#
# Contract preserved with rules-compliance-check.sh:
#   Writes status=PASS|FAIL|SKIPPED and note=... to $CI_RESULT_FILE.

set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-.}"

# --- Loop guard: Claude Code sets stop_hook_active=true on stdin after we ---
# --- block once this turn. Blocking again traps the agent. ---
PAYLOAD=$(cat 2>/dev/null || echo '{}')
if command -v jq >/dev/null 2>&1 \
   && [ "$(echo "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  echo "pre-stop-checks: loop guard — already blocked once this turn, exiting clean" >&2
  exit 0
fi

# --- CI result file (read by rules-compliance-check.sh for eval scoring) ---
PROJ=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
DATE=$(date +%Y-%m-%d)
CI_RESULT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook/ci-result-${PROJ}-${DATE}.txt"
mkdir -p "$(dirname "$CI_RESULT_FILE")" 2>/dev/null || true

write_result() {
  { echo "status=$1"; echo "note=$2"; echo "ts=$(date +%s)"; } > "$CI_RESULT_FILE" 2>/dev/null || true
}

# --- Whole-tree early exit: nothing to lint/typecheck if no changes ---
# --- (Per-check tree-hash caching is a deferred follow-up.) ---
if git rev-parse --git-dir >/dev/null 2>&1 \
   && git diff --quiet HEAD 2>/dev/null \
   && git diff --cached --quiet 2>/dev/null; then
  write_result "SKIPPED" "no local changes"
  exit 0
fi

# --- Discover checks ---
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
CHECKS_DIR="$(dirname "$SELF")/stop-checks.d"
if [ ! -d "$CHECKS_DIR" ]; then
  write_result "SKIPPED" "no stop-checks.d directory"
  exit 0
fi

# --- Warn unconditionally about uncommitted/untracked state (informational) ---
if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "WARNING: Uncommitted changes in worktree (may be pre-existing)" >&2
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | head -5)
  if [ -n "$UNTRACKED" ]; then
    echo "WARNING: Untracked files found (may need to be committed):" >&2
    echo "$UNTRACKED" >&2
  fi
fi

echo "=== Running stop-hook checks in parallel ===" >&2

# --- Fan out: each *.sh in stop-checks.d/ runs in its own subshell ---
OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

declare -a pids names
for s in "$CHECKS_DIR"/*.sh; do
  [ -x "$s" ] || continue
  name=$(basename "$s" .sh)
  bash "$s" >"$OUT_DIR/$name.out" 2>"$OUT_DIR/$name.err" &
  pids+=("$!")
  names+=("$name")
done

if [ "${#pids[@]}" -eq 0 ]; then
  write_result "SKIPPED" "no executable checks in stop-checks.d"
  exit 0
fi

# --- Wait + aggregate ---
BLOCKED=0
WARNED=0
declare -a notes
for i in "${!pids[@]}"; do
  wait "${pids[$i]}"
  rc=$?
  name="${names[$i]}"
  case $rc in
    0)
      ;;
    1)
      WARNED=1
      echo "[WARN] $name" >&2
      [ -s "$OUT_DIR/$name.out" ] && cat "$OUT_DIR/$name.out" >&2
      [ -s "$OUT_DIR/$name.err" ] && cat "$OUT_DIR/$name.err" >&2
      notes+=("$name=warn")
      ;;
    *)
      BLOCKED=1
      echo "[FAIL] $name (exit $rc)" >&2
      [ -s "$OUT_DIR/$name.out" ] && cat "$OUT_DIR/$name.out" >&2
      [ -s "$OUT_DIR/$name.err" ] && cat "$OUT_DIR/$name.err" >&2
      notes+=("$name=fail")
      ;;
  esac
done

# --- Verdict ---
if [ $BLOCKED -eq 1 ]; then
  echo "=== Stop-hook checks FAILED — fix issues before completing ===" >&2
  write_result "FAIL" "$(IFS=,; echo "${notes[*]}")"
  exit 2
fi

if [ $WARNED -eq 1 ]; then
  write_result "PASS" "advisory: $(IFS=,; echo "${notes[*]}")"
else
  write_result "PASS" "all checks passed"
fi
echo "=== All stop-hook checks passed ===" >&2
exit 0
