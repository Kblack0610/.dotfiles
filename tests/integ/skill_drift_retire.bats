#!/usr/bin/env bats
# skill-drift's usage findings for a skill that declares metadata.replaces: RETIRE when nobody
# does its work at all, UNUSED when the guard denied its hand form (demand it redirected), and
# BYPASSED when sessions typed the form without the skill. claude-recall is a fake that prints
# the stats JSON, so only skill-drift's reading of it is under test.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DRIFT="$REPO_ROOT/.local/bin/skill-drift"
  export CLAUDE_SKILLS="$SANDBOX/skills" CLAUDE_MD="$SANDBOX/CLAUDE.md" XDG_CACHE_HOME="$SANDBOX/cache"
  export DOTFILES="$SANDBOX/pub" DOTFILES_PRIVATE="$SANDBOX/priv" SKILL_DRIFT_BASELINE="$SANDBOX/baseline"
  mkdir -p "$DOTFILES" "$DOTFILES_PRIVATE"
  echo '# rules' > "$CLAUDE_MD"
  for s in owner plain used; do
    mkdir -p "$CLAUDE_SKILLS/$s"
    printf -- '---\nname: %s\ndescription: d\n---\nbody\n' "$s" > "$CLAUDE_SKILLS/$s/SKILL.md"
  done
  printf -- '---\nname: owner\ndescription: d\nmetadata:\n  replaces:\n    - match: zzhand\n      use: owner-cli\n---\nbody\n' > "$CLAUDE_SKILLS/owner/SKILL.md"
  export CLAUDE_RECALL="$SANDBOX/recall"
}

# recall <rows json>: a fake claude-recall whose stats has one used skill plus the given rows.
recall() {
  printf '#!/bin/sh\ncat <<'"'"'J'"'"'\n{"skill_sessions":{"used":3},"rows":%s}\nJ\n' "$1" > "$CLAUDE_RECALL"
  chmod +x "$CLAUDE_RECALL"
}

# Finding rows only: the legend under them names every code too.
findings() { "$DRIFT" 2>&1 | grep -E '^ *(RETIRE|UNUSED|BYPASSED) +[a-z]' || true; }

@test "a replaces skill nobody uses or types by hand is RETIRE; one without replaces is UNUSED" {
  recall '[]'
  run findings
  assert_line --regexp 'RETIRE.*owner'
  assert_line --regexp 'UNUSED.*plain'
  refute_line --regexp 'UNUSED.*owner'
  refute_line --partial 'used '
}

@test "a hand form the guard denied is demand, so the skill is UNUSED, never RETIRE" {
  recall '[{"kind":"denied","key":"owner","calls":4,"sessions":2}]'
  run findings
  assert_line --regexp 'UNUSED.*owner'
  refute_line --regexp 'RETIRE.*owner'
}

@test "sessions that typed the form without the skill are BYPASSED, covered ones are not" {
  recall '[{"kind":"bypass","key":"owner","calls":5,"sessions":3,"covered_sessions":1}]'
  run findings
  assert_line --regexp 'BYPASSED.*owner.*2 of 3 sessions'
  refute_line --regexp 'RETIRE.*owner'
  recall '[{"kind":"bypass","key":"owner","calls":5,"sessions":3,"covered_sessions":3}]'
  run findings
  refute_line --partial 'BYPASSED'
}
