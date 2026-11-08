#!/usr/bin/env bash
# PreToolUse(Bash): before a `git push` or `gh pr create`, run the Stop hook's picked fast-tier
# check (stop-checks.d/60-shell-tests.sh, which scopes itself to the dotfiles repo) and deny on
# red. The Stop hook checks only a dirty tree, so work committed and pushed in one turn reached CI
# unchecked: from 2026-10-24 to 11-07, 85 of 109 failed CI jobs were the fast tier, and 56 of the
# 77 on PRs failed in a file the Stop hook's picker would have run.
# A pass is remembered per tree state, so the push and the PR that follows it run once.
set -uo pipefail
PAYLOAD=$(cat)
CMD=$(jq -r '.tool_input.command // empty' <<<"$PAYLOAD")
# A clause start: line start or a separator, then any VAR=value prefixes.
ENV='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
START="(^|[;&|(]|\\\$\\()[[:space:]]*${ENV}"
path_re="('[^']*'|\"[^\"]*\"|[^[:space:];&|]+)"
PUSH="git([[:space:]]+-C[[:space:]]+${path_re})?[[:space:]]+push"
grep -qE "${START}(${PUSH}|gh[[:space:]]+pr[[:space:]]+create)([[:space:]]|$)" <<<"$CMD" || exit 0
# A push that only deletes a remote branch sends no code.
grep -qE "${START}gh[[:space:]]+pr[[:space:]]+create" <<<"$CMD" \
  || ! grep -qE "${START}${PUSH}([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+(--delete|-d|:[^;&|[:space:]]+)([[:space:];&|]|$)" <<<"$CMD" || exit 0

CHECK="${PRE_PR_CHECK:-$(dirname "$(realpath "${BASH_SOURCE[0]}")")/stop-checks.d/60-shell-tests.sh}"
STATE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook"
LOG="$STATE/pre-pr.log"
mkdir -p "$STATE"

deny() { jq -nc --arg r "pre-pr-verify: $1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'; exit 0; }

# The tree the command pushes: a `cd DIR` clause, else `git -C DIR`, else the session's cwd.
dir=$(jq -r '.cwd // empty' <<<"$PAYLOAD"); dir=${dir:-$PWD}
cd_re="(^|[;&|(])[[:space:]]*cd[[:space:]]+${path_re}[[:space:]]*(&&|;)"
c_re="()git[[:space:]]+-C[[:space:]]+${path_re}[[:space:]]+push"
if [[ $CMD =~ $cd_re ]] || [[ $CMD =~ $c_re ]]; then
  d=${BASH_REMATCH[2]//[\"\']/}; d=${d/#\~/$HOME}
  [[ $d == *[\$\`]* ]] && deny "cannot tell which tree this pushes from \`$d\`. Name the directory literally, or cd into it first."
  [[ $d == /* ]] || d="$dir/$d"
  dir=$d
fi
# Only this repo has the fast tier; 60-shell-tests.sh would exit 0 anywhere else, so do not
# run, log or remember a pass there.
own=${PRE_PR_REPO:-$(git -C "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)}
[ "$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$own" ] || exit 0
head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || exit 0

log() { printf '%s %s %s %s\n' "$(date -Is)" "$1" "$dir" "${head:0:12}" >> "$LOG"; }

# A test that is red on origin/main too is not this change's: the caller says so, and it is logged.
if grep -qE "${START}PRE_PR_VERIFY=main-red[[:space:]]+${ENV}(git|gh)[[:space:]]" <<<"$CMD"; then log main-red; exit 0; fi

PASS="$STATE/pre-pr-pass"
fp=$( { echo "$dir $head"; git -C "$dir" diff HEAD; git -C "$dir" ls-files --others --exclude-standard; } 2>/dev/null | sha256sum | cut -c1-32)
if grep -qxF "$fp" "$PASS" 2>/dev/null; then log cached; exit 0; fi

out=$(CLAUDE_PROJECT_DIR="$dir" timeout "${PRE_PR_TIMEOUT:-540}" bash "$CHECK" 2>&1)
rc=$?
case $rc in
  0)
    log pass
    { tail -n 199 "$PASS" 2>/dev/null; echo "$fp"; } > "$PASS.tmp" && mv "$PASS.tmp" "$PASS"
    ;;
  2)
    log fail
    deny "the fast-tier tests this change picks fail on this tree, so CI would go red. Fix them and run the command again. If the same test also fails on origin/main, it is not yours: put PRE_PR_VERIFY=main-red in front of the command.
$(fails=$(grep -A25 '^not ok' <<<"$out" | head -n 80); echo "${fails:-$(tail -n 30 <<<"$out")}")"
    ;;
  # A timeout or a warn (bats not vendored) cannot say red; CI still runs the whole tier.
  *) log "rc$rc" ;;
esac
exit 0
