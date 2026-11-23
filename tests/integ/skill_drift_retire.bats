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
  export DOTFILES="$SANDBOX/pub" DOTFILES_PRIVATE="$SANDBOX/priv"
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

# PROMOTE: a `status: draft` skill used past the toggle's bar (more than 5 sessions in 30 days).
# The fake recall answers every window the same, so only the reading of skill_sessions is tested.
promote_recall() {
  printf '#!/bin/sh\ncat <<'"'"'J'"'"'\n{"skill_sessions":%s,"rows":[]}\nJ\n' "$1" > "$CLAUDE_RECALL"
  chmod +x "$CLAUDE_RECALL"
}
promote_findings() { "$DRIFT" 2>&1 | grep -E '^ *PROMOTE +[a-z]' || true; }

@test "PROMOTE: a draft used in more than 5 sessions is reported, a listed skill and a quiet draft are not" {
  mkdir -p "$CLAUDE_SKILLS/drafty" "$CLAUDE_SKILLS/quiet"
  printf -- '---\nname: drafty\ndescription: d\nstatus: draft\ndisable-model-invocation: true\n---\nbody\n' > "$CLAUDE_SKILLS/drafty/SKILL.md"
  printf -- '---\nname: quiet\ndescription: d\nstatus: draft\ndisable-model-invocation: true\n---\nbody\n' > "$CLAUDE_SKILLS/quiet/SKILL.md"
  promote_recall '{"drafty":6,"quiet":5,"plain":9}'
  run promote_findings
  assert_line --regexp 'PROMOTE +drafty .*6 sessions'
  refute_line --regexp 'PROMOTE +quiet'
  refute_line --regexp 'PROMOTE +plain'
}

@test "PROMOTE: no counted use at all is not read as a draft with none" {
  mkdir -p "$CLAUDE_SKILLS/drafty"
  printf -- '---\nname: drafty\ndescription: d\nstatus: draft\n---\nbody\n' > "$CLAUDE_SKILLS/drafty/SKILL.md"
  promote_recall '{}'
  run promote_findings
  refute_output --partial 'PROMOTE'
}
