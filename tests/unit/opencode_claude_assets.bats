#!/usr/bin/env bats
# sync-opencode-claude-assets.sh mirrors Claude agents and commands into opencode. Its default
# source is the deployed ~/.claude, where stow merges the public and private trees as links.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUBJECT="$PUB/.config/codex/sync-opencode-claude-assets.sh"
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" OPENCODE_HOME="$T/home/.config/opencode"
  unset CLAUDE_SRC
  mkdir -p "$T/pub/agents" "$T/priv/agents" "$T/priv/commands" "$HOME/.claude/agents" "$HOME/.claude/commands"
  printf -- '---\nname: pub\ndescription: Public one\ntools: Read\n---\nbody pub\n' > "$T/pub/agents/pub.md"
  printf -- '---\ndescription: Private one\n---\nbody priv\n' > "$T/priv/agents/priv.md"
  printf -- '---\ndescription: Remember\n---\nremember body\n' > "$T/priv/commands/remember.md"
  ln -s "$T/pub/agents/pub.md" "$HOME/.claude/agents/pub.md"
  ln -s "$T/priv/agents/priv.md" "$HOME/.claude/agents/priv.md"
  ln -s "$T/priv/commands/remember.md" "$HOME/.claude/commands/remember.md"
}

@test "the default source is the deployed ~/.claude: public and private agents and commands both land" {
  run "$SUBJECT"
  assert_success
  assert_output --partial "2 agents, 1 commands"
  run cat "$OPENCODE_HOME/agents/priv.md"
  assert_output "$(printf -- '---\ndescription: Private one\nmode: subagent\n---\n\nbody priv')"
  [ -f "$OPENCODE_HOME/agents/pub.md" ]
  [ -f "$OPENCODE_HOME/commands/remember.md" ]
}

@test "a command dir stow folded into a dir link is mirrored, its path kept" {
  mkdir -p "$T/pub/commands/ns"
  printf -- '---\ndescription: Foo\n---\nfoo body\n' > "$T/pub/commands/ns/foo.md"
  ln -s "$T/pub/commands/ns" "$HOME/.claude/commands/ns"
  run "$SUBJECT"
  assert_success
  [ -f "$OPENCODE_HOME/commands/ns/foo.md" ]
}

@test "a source with no agents or commands fails and leaves the mirror as it was" {
  run "$SUBJECT"
  assert_success
  rm "$HOME"/.claude/agents/* "$HOME"/.claude/commands/*
  run "$SUBJECT"
  assert_failure
  assert_output --partial "has stow run?"
  [ -f "$OPENCODE_HOME/agents/priv.md" ]
}

@test "a broken link fails before anything is deleted" {
  run "$SUBJECT"
  assert_success
  rm "$T/priv/agents/priv.md"
  run "$SUBJECT"
  assert_failure
  assert_output --partial "Broken links"
  [ -f "$OPENCODE_HOME/agents/priv.md" ]
}

@test "a re-run drops the copy of a removed source" {
  run "$SUBJECT"
  assert_success
  rm "$HOME/.claude/agents/pub.md"
  run "$SUBJECT"
  assert_success
  [ ! -e "$OPENCODE_HOME/agents/pub.md" ]
}
