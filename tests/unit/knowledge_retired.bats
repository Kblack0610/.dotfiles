#!/usr/bin/env bats
# knowledge-retired: the retired list comes from git history alone. A host that left the
# home-config inventory on its mainline's remote ref is retired, one still in it is not; a command
# deleted from .local/bin is retired unless it came back, is a skill now, or is a bare word. The repos are
# throwaway git checkouts in the test dir; project_repo_path is a stub that points at one.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig"
  mkdir -p "$HOME"
  git config --global user.email t@example.com
  git config --global user.name t
  git config --global init.defaultBranch main
  SCRIPT="$BATS_TEST_DIRNAME/../../.local/bin/knowledge-retired"

  HC="$T/home-config"
  git init -q --bare "$T/hc.git"
  git init -q "$HC"
  mkdir -p "$HC/ansible"
  inv() { printf 'all:\n  children:\n    pool:\n      hosts:\n' > "$HC/ansible/inventory.yml"
          for h in "$@"; do printf '        %s: {}\n' "$h" >> "$HC/ansible/inventory.yml"; done
          git -C "$HC" add -A && git -C "$HC" commit -qm "inv $*"; }
  inv mac-mini mac-studio
  inv mac-mini
  git -C "$HC" remote add origin "$T/hc.git"
  git -C "$HC" push -q -u origin main
  export HC
  project_repo_path() { printf '%s' "$HC"; }
  export -f project_repo_path

  D="$T/dots"
  git init -q "$D"
  mkdir -p "$D/.local/bin"
  for c in wave-start binks back-again night-shift; do echo x > "$D/.local/bin/$c"; done
  git -C "$D" add -A && git -C "$D" commit -qm add
  git -C "$D" rm -q .local/bin/wave-start .local/bin/binks .local/bin/back-again .local/bin/night-shift
  mkdir -p "$HOME/.claude/skills/night-shift"
  git -C "$D" commit -qm delete
  mkdir -p "$D/.local/bin" && echo x > "$D/.local/bin/back-again"
  git -C "$D" add -A && git -C "$D" commit -qm restore
  export KNOWLEDGE_RETIRED_REPOS="$D"
}

@test "a host that left the inventory and a deleted hyphenated command are retired; what stayed, came back or is a skill is not" {
  export KNOWLEDGE_RETIRED_ALIASES=/dev/null
  run "$SCRIPT"
  assert_success
  assert_output "$(printf 'host\tmac-studio\tleft the home-config inventory\ncommand\twave-start\twas deleted from %s/.local/bin' "$D")"
}

@test "an inventory that cannot be read is a failure, not an empty list" {
  git -C "$HC" branch -q --unset-upstream
  run "$SCRIPT"
  assert_failure
  assert_output --partial 'has no main or master tracking a remote'
}

@test "a hardware alias is retired with its host, and an alias of a host still in the inventory is not" {
  printf '# a comment\nmac-studio\tM3 Ultra\nmac-mini\tM4 Pro\n' > "$T/aliases.tsv"
  KNOWLEDGE_RETIRED_ALIASES="$T/aliases.tsv" run "$SCRIPT"
  assert_success
  assert_line "$(printf 'host\tM3 Ultra\tis the hardware of mac-studio, which left the home-config inventory')"
  refute_output --partial 'M4 Pro'
}
