#!/usr/bin/env bats
# The skill-usage toggle: claude-recall stats counts the four use kinds beyond Skill calls and
# typed commands (body, read, script, mention), skill-drift --overrides turns the six into the
# skillOverrides to hide and restore, and agentctl-skill-toggle stops before making anything
# when there is no change or on --dry-run, and otherwise stops at the open PR. Fixture transcripts, skills and settings only.

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
  # alpha's body loads; beta's SKILL.md is read; gamma's script runs; delta runs as a CLI.
  # None of these is use of eps: naming it as an argument or inside a heredoc, reading its
  # SKILL.md in the source tree (authoring), or a grep over three skills (corpus work). zeta
  # has no CLI on PATH, so a command line that opens with its name is a word, not a run.
  mkdir -p "$SANDBOX/bin"
  printf '#!/bin/sh\n' > "$SANDBOX/bin/delta"; cp "$SANDBOX/bin/delta" "$SANDBOX/bin/eps"
  chmod +x "$SANDBOX/bin/delta" "$SANDBOX/bin/eps"
  export PATH="$SANDBOX/bin:$PATH"
  cat > "$P/s1.jsonl" <<EOF
{"type":"user","isMeta":true,$cli,$cwd,$ts,"message":{"role":"user","content":"Base directory for this skill: /home/u/.claude/skills/alpha\n\n# alpha"}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/home/u/.claude/skills/beta/SKILL.md"}}]}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"~/.claude/skills/gamma/scripts/run.sh --x"}}]}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"FOO=1 delta --list | head"}}]}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo eps"}}]}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -F - <<'X'\neps is done\nX\nzeta and more"}}]}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m \"title\neps in the body\" && ls"}}]}}
{"type":"assistant",$cli,$cwd,$ts,"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/home/u/.dotfiles/.claude/skills/ops/eps/SKILL.md"}}]}}
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

@test "skill_sessions counts a session once per skill, however many kinds it used it by" {
  transcripts
  # s1 also calls alpha by the Skill tool: two kinds, one session.
  printf '%s\n' '{"type":"assistant","entrypoint":"cli","cwd":"/home/u/proj","timestamp":"2026-10-20T10:00:00Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"alpha"}}]}}' >> "$CLAUDE_TRANSCRIPTS/-home-u-proj/s1.jsonl"
  run bash -c "'$RECALL' stats --since 2026-10-01 --json --top 0 --kind skill,body,read,script,mention | jq -c '[([.rows[] | select(.key == \"alpha\")] | length), .skill_sessions]'"
  assert_success
  assert_output '[2,{"alpha":1,"beta":1,"delta":1,"gamma":1,"zeta":1}]'
}

@test "the default stats kinds leave the four use kinds out" {
  transcripts
  run bash -c "'$RECALL' stats --since 2026-10-01 --json --top 0 | jq -r '.rows[].kind' | sort -u"
  assert_success
  refute_output --regexp 'body|read|script|mention'
}

# skill-drift --overrides against a stub claude-recall that reports $FIXTURE_USED as used:
# "name" is a use in 11 sessions, past the default listing bar of 10; "name:N" is N sessions.
overrides() {
  printf '#!/usr/bin/env bash\njq -n --arg u "$FIXTURE_USED" %s\n' \
    "'{rows: [], skill_sessions: (\$u | split(\" \") | map(select(length > 0) | split(\":\") | {(.[0]): ((.[1] // \"11\") | tonumber)}) | add // {})}'" > "$SANDBOX/recall"
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

@test "a skill a global doc or a runner conf routes to is never hidden" {
  mkdir -p "$HOME/.local/src/docs" "$HOME/.config/agentctl/agents"
  echo '| Shell | skills `beta` |' > "$HOME/.local/src/docs/planning.md"
  echo 'SKILL=gamma' > "$HOME/.config/agentctl/agents/r.conf"
  # Lessons are history: a skill named in one is still hidden.
  mkdir -p "$HOME/.agent/lessons"
  echo 'The delta skill was stale once.' > "$HOME/.agent/lessons/p.md"
  echo '{"skillOverrides":{}}' > "$SANDBOX/settings.json"
  FIXTURE_USED="alpha" run overrides
  assert_success
  run jq -c '.hide' <<<"$output"
  assert_output '["delta","eps","zeta"]'
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

@test "a listed skill used in 5 or fewer sessions goes name-only, a name-only one is listed past 10, and between the two neither moves" {
  echo '{"skillOverrides":{"alpha":"name-only","beta":"name-only","gamma":"name-only"}}' > "$SANDBOX/settings.json"
  # name-only: alpha 5, beta 7 (in the band), gamma 11. listed: delta 2, eps 7 (in the band), zeta 11.
  FIXTURE_USED="alpha:5 beta:7 gamma:11 delta:2 eps:7 zeta" run overrides
  assert_success
  run jq -c '[.max, .hide, .restore]' <<<"$output"
  assert_output '[5,["delta"],["gamma"]]'
  # The bar is SKILL_TOGGLE_MAX_SESSIONS; at 0 any use lists a skill.
  SKILL_TOGGLE_MAX_SESSIONS=0 FIXTURE_USED="alpha:5 beta:7 gamma:11 delta:2 eps:7 zeta" run overrides
  run jq -c '[.hide, .restore]' <<<"$output"
  assert_output '[[],["alpha","beta","gamma"]]'
}

@test "no use counted at all refuses to hide everything" {
  echo '{"skillOverrides":{}}' > "$SANDBOX/settings.json"
  FIXTURE_USED="" run overrides
  assert_failure 2
  assert_output --partial 'no use counted'
}

# agentctl-skill-toggle reads origin/main of a fixture repo; the stub recall stands in for use.
# The settings file is written in jq's format unless $2 is raw.
toggle_repo() {
  git init -q -b main "$SANDBOX/origin.git" --bare
  git init -q -b main "$DOTFILES"
  mkdir -p "$DOTFILES/.claude"
  if [ "${2:-}" = raw ]; then echo "$1"; else jq . <<<"$1"; fi > "$DOTFILES/.claude/settings.json"
  git -C "$DOTFILES" add .claude/settings.json
  git -C "$DOTFILES" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$DOTFILES" remote add origin "$SANDBOX/origin.git"
  git -C "$DOTFILES" push -q origin main
  printf '#!/usr/bin/env bash\njq -n %s\n' "'{rows: [], skill_sessions: ([\"alpha\",\"beta\",\"gamma\",\"delta\",\"eps\"] | map({(.): 11}) | add)}'" > "$SANDBOX/recall"
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
  assert_output --partial 'would open a PR'
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

@test "a toggle PR from an earlier night still open is BLOCKED, not FAILED" {
  toggle_repo '{"skillOverrides":{"beta":"name-only"}}'
  printf '#!/usr/bin/env bash\necho 77\n' > "$SANDBOX/bin-gh"; mkdir -p "$SANDBOX/ghbin"
  mv "$SANDBOX/bin-gh" "$SANDBOX/ghbin/gh"; chmod +x "$SANDBOX/ghbin/gh"
  # rm first: the sandbox links this file to the repo copy, and a write would go through it.
  rm -f "$HOME/.local/lib/agent-proof.sh"
  printf 'proof_outcome() { echo "verdict $2"; }\n' > "$HOME/.local/lib/agent-proof.sh"
  PATH="$SANDBOX/ghbin:$PATH" run "$TOGGLE"
  assert_success
  assert_output --partial 'verdict BLOCKED'
  assert_output --partial 'PR #77 is still open'
}

@test "a new change stops at its open PR: BLOCKED, the worktree gone, the item queued for a session, agent-land never called" {
  toggle_repo '{"skillOverrides":{"beta":"name-only"}}'
  mkdir -p "$SANDBOX/ghbin"
  printf '#!/usr/bin/env bash\ncase "$*" in "pr create"*) echo https://github.com/o/r/pull/88 ;; esac\n' > "$SANDBOX/ghbin/gh"
  printf '#!/usr/bin/env bash\necho "agent-queue $*" >> %q\n' "$SANDBOX/aq.log" > "$SANDBOX/ghbin/agent-queue"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$SANDBOX/landed" > "$SANDBOX/ghbin/agent-land"
  chmod +x "$SANDBOX"/ghbin/*
  rm -f "$HOME/.local/lib/agent-proof.sh" "$HOME/.local/bin/agent-queue" "$HOME/.local/bin/agent-land"
  printf 'proof_outcome() { echo "verdict $2"; }\n' > "$HOME/.local/lib/agent-proof.sh"
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t PATH="$SANDBOX/ghbin:$PATH" run "$TOGGLE"
  assert_success
  assert_output --partial 'verdict BLOCKED'
  assert_output --partial 'opened #88 for review'
  [ ! -e "$SANDBOX/landed" ]
  # the item goes back to queued so dispatch gives it a session to review and land it
  # with the PR recorded first, so that session's brief names it
  run tail -2 "$SANDBOX/aq.log"
  assert_line --index 0 --regexp "^agent-queue set skill-toggle-$(date +%F) pr=.*/origin#88$"
  assert_line --index 1 "agent-queue move skill-toggle-$(date +%F) queued"
  run git -C "$DOTFILES" worktree list
  assert_equal "$(wc -l <<<"$output")" 1
}

@test "a settings file jq would reformat stops the toggle before it makes anything" {
  toggle_repo '{"skillOverrides": {"beta": "name-only"}}' raw
  run "$TOGGLE" --dry-run
  assert_failure
  assert_output --partial "not in jq's format"
}
