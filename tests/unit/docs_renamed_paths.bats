#!/usr/bin/env bats
# docs-renamed-paths: a DEADPATH whose file git renamed is rewritten to the new path; a path with no
# rename on record, a doc inside a dotfiles checkout and a low-similarity "rename" are not.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  BIN="$BATS_TEST_DIRNAME/../../.local/bin/docs-renamed-paths"
  export HOME="$BATS_TEST_TMPDIR/home"
  export DOTFILES="$HOME/.dotfiles" DOTFILES_PRIVATE="$HOME/.dotfiles-private"
  mkdir -p "$DOTFILES/.local/bin" "$DOTFILES_PRIVATE" "$HOME/docs" "$HOME/.local/bin"
  git() { command git -C "$DOTFILES" -c user.email=t@t -c user.name=t "$@"; }
  git init -q
  seq 1 40 | sed 's/^/line /' > "$DOTFILES/.local/bin/old-tool"
  git add -A && git commit -qm add
  git mv .local/bin/old-tool .local/bin/new-tool && git commit -qm rename
  # Stowed: the deployed name is a file under $HOME.
  cp "$DOTFILES/.local/bin/new-tool" "$HOME/.local/bin/new-tool"
  printf 'Run ~/.local/bin/old-tool first, or $HOME/.local/bin/old-tool.\nSee ~/.local/bin/old-tool-extra too.\n' > "$HOME/docs/a.md"
  finding() { printf '{"findings":[{"type":"DEADPATH","doc":"~/docs/a.md","item":"%s","detail":"path does not exist (line 1)"}]}' "$1" > "$BATS_TEST_TMPDIR/f.json"; }
}

@test "a dry run lists the rename and writes nothing" {
  finding '~/.local/bin/old-tool'
  cp "$HOME/docs/a.md" "$BATS_TEST_TMPDIR/before.md"
  run --separate-stderr "$BIN" "$BATS_TEST_TMPDIR/f.json"
  assert_success
  assert_output $'would-fix\t~/docs/a.md\t1\t~/.local/bin/old-tool\t~/.local/bin/new-tool'
  cmp "$HOME/docs/a.md" "$BATS_TEST_TMPDIR/before.md"
}

@test "--apply rewrites the ~ and \$HOME forms, and not a longer name that starts the same" {
  finding '~/.local/bin/old-tool'
  run --separate-stderr "$BIN" --apply "$BATS_TEST_TMPDIR/f.json"
  assert_success
  assert_output --partial 'fixed'
  run cat "$HOME/docs/a.md"
  assert_line --index 0 'Run ~/.local/bin/new-tool first, or $HOME/.local/bin/new-tool.'
  assert_line --index 1 'See ~/.local/bin/old-tool-extra too.'
}

@test "a rename followed through two hops lands on the file that exists" {
  git mv .local/bin/new-tool .local/bin/newest-tool && git commit -qm again
  mv "$HOME/.local/bin/new-tool" "$HOME/.local/bin/newest-tool"
  finding '~/.local/bin/old-tool'
  run --separate-stderr "$BIN" "$BATS_TEST_TMPDIR/f.json"
  assert_output --partial $'~/.local/bin/newest-tool'
}

@test "negative control: a path with no rename on record prints nothing and the doc is untouched" {
  finding '~/.local/bin/never-existed'
  cp "$HOME/docs/a.md" "$BATS_TEST_TMPDIR/before.md"
  run --separate-stderr "$BIN" --apply "$BATS_TEST_TMPDIR/f.json"
  assert_success
  assert_output ''
  cmp "$HOME/docs/a.md" "$BATS_TEST_TMPDIR/before.md"
}

@test "a rename whose target is gone is not followed" {
  rm "$HOME/.local/bin/new-tool"
  finding '~/.local/bin/old-tool'
  run --separate-stderr "$BIN" --apply "$BATS_TEST_TMPDIR/f.json"
  assert_output ''
}

@test "a rewrite below the similarity floor is a different file, not a move" {
  seq 1 40 | sed 's/^/other /' > "$DOTFILES/.local/bin/low-old"
  git add -A && git commit -qm low
  git mv .local/bin/low-old .local/bin/low-new
  seq 1 14 | sed 's/^/line /' > "$DOTFILES/.local/bin/low-new"; seq 1 26 | sed 's/^/fresh /' >> "$DOTFILES/.local/bin/low-new"
  git add -A && git commit -qm lowmv
  cp "$DOTFILES/.local/bin/low-new" "$HOME/.local/bin/low-new"
  finding '~/.local/bin/low-old'
  run --separate-stderr "$BIN" --apply "$BATS_TEST_TMPDIR/f.json"
  assert_output ''
}

@test "a doc inside a dotfiles checkout is reported, not edited, unless --reroot names a worktree" {
  mkdir -p "$DOTFILES/docs"
  printf 'Run ~/.local/bin/old-tool.\n' > "$DOTFILES/docs/b.md"
  mkdir -p "$BATS_TEST_TMPDIR/wt/docs"; cp "$DOTFILES/docs/b.md" "$BATS_TEST_TMPDIR/wt/docs/b.md"
  printf '{"findings":[{"type":"DEADPATH","doc":"~/.dotfiles/docs/b.md","item":"~/.local/bin/old-tool","detail":"path does not exist (line 1)"}]}' > "$BATS_TEST_TMPDIR/f.json"
  run --separate-stderr "$BIN" --apply "$BATS_TEST_TMPDIR/f.json"
  assert_output --partial 'repo'
  run cat "$DOTFILES/docs/b.md"
  assert_output 'Run ~/.local/bin/old-tool.'
  run --separate-stderr "$BIN" --apply --reroot "$DOTFILES=$BATS_TEST_TMPDIR/wt" "$BATS_TEST_TMPDIR/f.json"
  assert_output --partial 'fixed'
  run cat "$BATS_TEST_TMPDIR/wt/docs/b.md"
  assert_output 'Run ~/.local/bin/new-tool.'
  run cat "$DOTFILES/docs/b.md"
  assert_output 'Run ~/.local/bin/old-tool.'
}

@test "a skills finding names the skill, and its SKILL.md is the doc" {
  mkdir -p "$HOME/.claude/skills/demo"
  printf 'Use ~/.local/bin/old-tool.\n' > "$HOME/.claude/skills/demo/SKILL.md"
  printf '{"findings":[{"type":"DEADPATH","skill":"demo","item":"~/.local/bin/old-tool","detail":"path does not exist"}]}' > "$BATS_TEST_TMPDIR/f.json"
  run --separate-stderr "$BIN" --apply "$BATS_TEST_TMPDIR/f.json"
  assert_output --partial 'fixed'
  run cat "$HOME/.claude/skills/demo/SKILL.md"
  assert_output 'Use ~/.local/bin/new-tool.'
}
