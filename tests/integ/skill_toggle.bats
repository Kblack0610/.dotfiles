#!/usr/bin/env bats
# The skill-usage toggle: claude-recall stats counts the four use kinds beyond Skill calls and
# typed commands (body, read, script, mention), skill-drift --overrides turns the six into the
# skillOverrides to hide and restore, and agentctl-skill-toggle stops before landing anything
# when there is no change or on --dry-run. Fixture transcripts, skills and settings only.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  RECALL="$REPO_ROOT/.local/bin/claude-recall"
  DRIFT="$REPO_ROOT/.local/bin/skill-drift"
  TOGGLE="$REPO_ROOT/.local/bin/agentctl-skill-toggle"
  export CLAUDE_SKILLS="$SANDBOX/skills" CLAUDE_MD="$SANDBOX/CLAUDE.md" TZ=UTC
  export DOTFILES="$SANDBOX/pub" DOTFILES_PRIVATE="$SANDBOX/priv"
  mkdir -p "$DOTFILES" "$DOTFILES_PRIVATE"
  echo '# rules' > "$CLAUDE_MD"
  for s in alpha beta gamma delta eps zeta; do
    mkdir -p "$CLAUDE_SKILLS/$s"
    printf -- '---\nname: %s\ndescription: d\n---\nbody\n' "$s" > "$CLAUDE_SKILLS/$s/SKILL.md"
  done
}

# A fixture transcript tree: one interactive session and one subagent.
transcripts() {
  local T="$SANDBOX/projects" ts='"timestamp":"2026-10-20T10:00:00Z"' cli='"entrypoint":"cli"' cwd='"cwd":"/home/u/proj"'
  local P="$T/-home-u-proj"
  mkdir -p "$P/s1/subagents"
  export CLAUDE_TRANSCRIPTS="$T"
  # alpha's body loads; beta's SKILL.md is read; gamma's script runs; delta runs as a CLI;
  # a call naming eps only as an argument is not a mention; a grep over three skills is corpus
  # work and counts for none of them.
  cat > "$P/s1.jsonl" <<EOF
{"type":"user","isMeta":true,$cli,$cwd,$ts,"message":{"role":"user","content":"Base directory for this skill: /home/u/.claude/skills/alpha\n\n# alpha"}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/home/u/.claude/skills/beta/SKILL.md"}}]}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"~/.claude/skills/gamma/scripts/run.sh --x"}}]}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"FOO=1 delta --list | head"}}]}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo eps"}}]}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep -l x ~/.claude/skills/zeta/SKILL.md ~/.claude/skills/alpha/SKILL.md ~/.claude/skills/eps/SKILL.md"}}]}}
EOF
  # A subagent's skill body counts; its dispatch prompt is not typed.
  cat > "$P/s1/subagents/agent-a.jsonl" <<EOF
{"type":"user",$cli,$cwd,$ts,"message":{"role":"user","content":"Base directory for this skill: /home/u/.claude/skills/zeta"}}
EOF
}

kinds() { "$RECALL" stats --since 2026-10-01 --json --top 0 --kind body,read,script,mention \
            | jq -r '.rows[] | "\(.kind) \(.key)"' | sort; }

@test "stats counts body loads, SKILL.md reads, script runs and CLI runs per skill" {
  transcripts
  run kinds
  assert_success
  assert_output "$(printf '%s\n' 'body alpha' 'body zeta' 'mention delta' 'read beta' 'script gamma')"
}

@test "the default stats kinds leave the four use kinds out" {
  transcripts
  run bash -c "'$RECALL' stats --since 2026-10-01 --json --top 0 | jq -r '.rows[].kind' | sort -u"
  assert_success
  refute_output --regexp 'body|read|script|mention'
}

# skill-drift --overrides against a stub claude-recall that reports $FIXTURE_USED as used.
overrides() {
  printf '#!/usr/bin/env bash\njq -n --arg u "$FIXTURE_USED" %s\n' \
    "'{rows: (\$u | split(\" \") | map(select(length > 0) | {kind: \"skill\", key: .}))}'" > "$SANDBOX/recall"
  chmod +x "$SANDBOX/recall"
  CLAUDE_RECALL="$SANDBOX/recall" SKILL_SETTINGS="$SANDBOX/settings.json" "$DRIFT" --overrides --json
}

@test "overrides hide the unused, restore the used and keep other override values" {
  echo '{"model":"x","skillOverrides":{"beta":"name-only","gamma":"name-only","eps":"off"}}' > "$SANDBOX/settings.json"
  FIXTURE_USED="alpha beta" run overrides
  assert_success
  run jq -c '[.hide, .restore, .skillOverrides]' <<<"$output"
  assert_output '[["delta","zeta"],["beta"],{"delta":"name-only","eps":"off","gamma":"name-only","zeta":"name-only"}]'
}

@test "a skill another skill or CLAUDE.md routes to is never hidden, but a used one is restored" {
  echo 'Use the delta skill for this.' > "$CLAUDE_MD"
  printf -- '---\nname: alpha\ndescription: d\n---\nThen run zeta.\n' > "$CLAUDE_SKILLS/alpha/SKILL.md"
  echo '{"skillOverrides":{"delta":"name-only"}}' > "$SANDBOX/settings.json"
  FIXTURE_USED="alpha delta" run overrides
  assert_success
  run jq -c '[.hide, .restore]' <<<"$output"
  assert_output '[["beta","eps","gamma"],["delta"]]'
}

@test "a paths-scoped or model-disabled skill is left alone" {
  printf -- '---\nname: beta\npaths:\n  - "x/**"\n---\n' > "$CLAUDE_SKILLS/beta/SKILL.md"
  printf -- '---\nname: gamma\ndisable-model-invocation: true\n---\n' > "$CLAUDE_SKILLS/gamma/SKILL.md"
  echo '{"skillOverrides":{}}' > "$SANDBOX/settings.json"
  FIXTURE_USED="alpha" run overrides
  assert_success
  run jq -c '.hide' <<<"$output"
  assert_output '["delta","eps","zeta"]'
}

@test "no use counted at all refuses to hide everything" {
  echo '{"skillOverrides":{}}' > "$SANDBOX/settings.json"
  FIXTURE_USED="" run overrides
  assert_failure 2
  assert_output --partial 'no use counted'
}

# agentctl-skill-toggle reads origin/main of a fixture repo; the stub recall stands in for use.
toggle_repo() {
  git init -q -b main "$SANDBOX/origin.git" --bare
  git init -q -b main "$DOTFILES"
  mkdir -p "$DOTFILES/.claude"
  echo "$1" > "$DOTFILES/.claude/settings.json"
  git -C "$DOTFILES" add .claude/settings.json
  git -C "$DOTFILES" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$DOTFILES" remote add origin "$SANDBOX/origin.git"
  git -C "$DOTFILES" push -q origin main
  printf '#!/usr/bin/env bash\njq -n %s\n' "'{rows: [\"alpha\",\"beta\",\"gamma\",\"delta\",\"eps\"] | map({kind: \"skill\", key: .})}'" > "$SANDBOX/recall"
  chmod +x "$SANDBOX/recall"
  export CLAUDE_RECALL="$SANDBOX/recall"
}

@test "the toggle reports NOOP and lands nothing when origin/main already matches use" {
  toggle_repo '{"skillOverrides":{"zeta":"name-only"}}'
  run "$TOGGLE"
  assert_success
  assert_output --partial 'no change over 30d'
  run git -C "$DOTFILES" worktree list
  assert_equal "$(wc -l <<<"$output")" 1
}

@test "the toggle dry run names the change and lands nothing" {
  toggle_repo '{"skillOverrides":{"beta":"name-only"}}'
  run "$TOGGLE" --dry-run
  assert_success
  assert_output --partial 'would land'
  assert_output --partial 'hide 1 (zeta), restore 1 (beta)'
  run git -C "$DOTFILES" worktree list
  assert_equal "$(wc -l <<<"$output")" 1
}

@test "a restore-only change keeps the hide list empty" {
  toggle_repo '{"skillOverrides":{"beta":"name-only","zeta":"name-only"}}'
  run "$TOGGLE" --dry-run
  assert_success
  assert_output --partial 'hide 0, restore 1 (beta)'
}
