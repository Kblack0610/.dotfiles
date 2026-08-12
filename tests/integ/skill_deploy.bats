#!/usr/bin/env bats
# skill-deploy's contract, exercised as a real subprocess against a fake two-repo world
# built inside the sandbox $HOME.
#
# skill-deploy is the ONLY thing that puts a skill where the agent can see it: stow now
# ignores .claude/skills in both repos (see .stow-local-ignore), because stow mirrors the
# source path and Claude Code reads personal skills one level down only, at
# ~/.claude/skills/<name>/SKILL.md. A categorised source tree therefore has to be
# FLATTENED while linking, and this file is where that is pinned.
#
# Four properties matter more than the rest:
#
#   FLATTENS            .claude/skills/<category>/<name>/ must deploy to <name>, not to
#                       <category>/<name>. Get this wrong and every skill silently
#                       disappears from the agent - no error, just an empty menu.
#   REFUSES, NOT GUESSES  a name in BOTH repos, and a real directory in the way, exit 1.
#                       Silently preferring one copy is the second-source-of-truth failure
#                       the public/private split exists to prevent.
#   ADOPTS ONLY ITS OWN MESS  --adopt replaces a stow link farm and NOTHING else. The
#                       negative control below (a hand-made real skill dir) is the whole
#                       point of the flag being narrow.
#   IDEMPOTENT          it runs from provisioning on every install; a second run must be
#                       a no-op, not a re-link.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SKILL_DEPLOY="$REPO_ROOT/.local/bin/skill-deploy"
  PUB="$HOME/.dotfiles"
  PRIV="$HOME/.dotfiles-private"
  SKILLS="$HOME/.claude/skills"
  mkdir -p "$PUB/.claude/skills" "$PRIV/.claude/skills" "$SKILLS"
  export SKILL_DEPLOY PUB PRIV SKILLS
  export CLAUDE_SKILLS="$SKILLS" DOTFILES="$PUB" DOTFILES_PRIVATE="$PRIV"
}

# ── fixture builders ─────────────────────────────────────────────────────────

# mkskill <repo> <relpath> — a skill directory with a minimal SKILL.md.
# <relpath> is either "<name>" (flat) or "<category>/<name>" (categorised).
mkskill() {
  local dir="$1/.claude/skills/$2"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: test skill\n---\n\n## When to Use\n' "$(basename "$2")" > "$dir/SKILL.md"
}

# ── flattening: the property the whole restructure depends on ────────────────

@test "a flat <name>/ skill deploys under its own name" {
  mkskill "$PUB" flat-one
  run "$SKILL_DEPLOY"
  assert_success
  assert [ -L "$SKILLS/flat-one" ]
  assert [ -f "$SKILLS/flat-one/SKILL.md" ]
}

@test "a categorised <category>/<name>/ skill deploys FLAT, not nested" {
  mkskill "$PUB" ops/nested-one
  run "$SKILL_DEPLOY"
  assert_success
  assert [ -L "$SKILLS/nested-one" ]
  assert [ -f "$SKILLS/nested-one/SKILL.md" ]
  # The failure this guards: a nested deploy the agent cannot read.
  assert [ ! -e "$SKILLS/ops" ]
}

@test "both layouts and both repos land side by side in one flat tree" {
  mkskill "$PUB"  flat-one
  mkskill "$PUB"  ops/nested-one
  mkskill "$PRIV" memory/priv-one
  run "$SKILL_DEPLOY"
  assert_success
  assert [ -L "$SKILLS/flat-one" ]
  assert [ -L "$SKILLS/nested-one" ]
  assert [ -L "$SKILLS/priv-one" ]
  # Exactly three entries: nothing else was invented.
  run bash -c "ls -1 '$SKILLS' | wc -l"
  assert_output 3
}

@test "a non-skill sibling is not mistaken for a skill" {
  mkskill "$PUB" ops/nested-one
  # Discovery is by SKILL.md, so neither of these is a skill.
  printf -- '---\nname: <skill-name>\n---\n' > "$PUB/.claude/skills/SKILL-TEMPLATE.md"
  printf 'category readme\n' > "$PUB/.claude/skills/ops/README.md"
  run "$SKILL_DEPLOY"
  assert_success
  assert [ ! -e "$SKILLS/SKILL-TEMPLATE.md" ]
  assert [ ! -e "$SKILLS/ops" ]
  run bash -c "ls -1 '$SKILLS' | wc -l"
  assert_output 1
}

# ── refuses rather than guesses ──────────────────────────────────────────────

@test "a name defined in BOTH repos is a conflict, not a silent preference" {
  mkskill "$PUB"  ops/twice
  mkskill "$PRIV" memory/twice
  run "$SKILL_DEPLOY"
  assert_failure
  assert_output --partial "CONFLICT"
  assert_output --partial "twice"
  assert [ ! -e "$SKILLS/twice" ]
}

@test "a DANGLING link pointing outside the repos is left alone" {
  mkskill "$PUB" ops/nested-one
  ln -s /nowhere/at/all "$SKILLS/nested-one"
  run "$SKILL_DEPLOY"
  assert_failure
  assert_output --partial "CONFLICT"
  assert_equal "$(readlink "$SKILLS/nested-one")" /nowhere/at/all
}

# ── stale links from a skill whose source moved ──────────────────────────────
#
# The category migration created exactly this on every machine: 29 links into
# .dotfiles-private/.claude/skills/<name>/ that no longer existed, because the
# skill was now at <category>/<name>/. skill-deploy refused all of them.

@test "a dangling link into a repo is repointed when the source moved" {
  mkskill "$PUB" ops/moved
  ln -s "$PUB/.claude/skills/moved" "$SKILLS/moved"   # the old flat path
  assert [ ! -e "$SKILLS/moved" ]                                   # dangling

  run "$SKILL_DEPLOY"
  assert_success
  assert_output --partial "RELINKED"
  assert [ -f "$SKILLS/moved/SKILL.md" ]
}

@test "relinking works across a hop from one repo to the other" {
  # A skill that was public and is now private. The old link points into $PUB.
  mkskill "$PRIV" ops/hopped
  ln -s "$PUB/.claude/skills/hopped" "$SKILLS/hopped"
  assert [ ! -e "$SKILLS/hopped" ]

  run "$SKILL_DEPLOY"
  assert_success
  assert [ -f "$SKILLS/hopped/SKILL.md" ]
  assert_equal "$(readlink -f "$SKILLS/hopped")" "$(readlink -f "$PRIV/.claude/skills/ops/hopped")"
}

# NEGATIVE CONTROL. The auto-repair is only for a link pointing at NOTHING. A
# link that still RESOLVES, but to somewhere unexpected, is two real things
# disagreeing - only a human knows which is meant, so it stays a CONFLICT.
@test "a link that RESOLVES elsewhere is still refused, not repointed" {
  mkskill "$PUB" ops/contested
  mkdir -p "$HOME/other/contested"
  printf -- '---\nname: contested\n---\n' > "$HOME/other/contested/SKILL.md"
  ln -s "$HOME/other/contested" "$SKILLS/contested"

  run "$SKILL_DEPLOY"
  assert_failure
  assert_output --partial "CONFLICT"
  assert_equal "$(readlink -f "$SKILLS/contested")" "$(readlink -f "$HOME/other/contested")"
}

@test "--dry-run reports a relink without performing it" {
  mkskill "$PUB" ops/moved
  ln -s "$PUB/.claude/skills/moved" "$SKILLS/moved"
  run "$SKILL_DEPLOY" --dry-run
  assert_success
  assert_output --partial "WOULD RELINK"
  assert [ ! -e "$SKILLS/moved" ]
}

# ── adoption, and the negative control that keeps it narrow ──────────────────

# The shape `stow --no-folding` leaves behind: a REAL directory holding a per-file
# symlink. Only SKILL.md was linked, because only SKILL.md existed at stow time.
mk_link_farm() {
  local name="$1" src="$2"
  mkdir -p "$SKILLS/$name"
  ln -s "$src/SKILL.md" "$SKILLS/$name/SKILL.md"
}

@test "a stow link farm is a conflict until --adopt is passed" {
  mkskill "$PUB" ops/nested-one
  mk_link_farm nested-one "$PUB/.claude/skills/ops/nested-one"
  run "$SKILL_DEPLOY"
  assert_failure
  assert_output --partial "rerun with --adopt"
  assert [ ! -L "$SKILLS/nested-one" ]
}

@test "--adopt replaces a link farm, which is what makes references/ reachable" {
  mkskill "$PUB" ops/nested-one
  mkdir -p "$PUB/.claude/skills/ops/nested-one/references"
  printf 'detail\n' > "$PUB/.claude/skills/ops/nested-one/references/deep.md"
  mk_link_farm nested-one "$PUB/.claude/skills/ops/nested-one"

  # The bug being fixed: the farm predates references/, so it cannot see it.
  assert [ ! -e "$SKILLS/nested-one/references/deep.md" ]

  run "$SKILL_DEPLOY" --adopt
  assert_success
  assert [ -L "$SKILLS/nested-one" ]
  assert [ -f "$SKILLS/nested-one/references/deep.md" ]
}

# NEGATIVE CONTROL. --adopt must not be a general override: a directory holding a real
# file has content of its own to lose, so it stays a CONFLICT even with the flag. If this
# test ever passes with the dir replaced, --adopt has become `rm -rf` with extra steps.
@test "--adopt REFUSES a hand-made directory holding real files" {
  mkskill "$PUB" ops/handmade
  mkdir -p "$SKILLS/handmade"
  printf 'irreplaceable\n' > "$SKILLS/handmade/SKILL.md"

  run "$SKILL_DEPLOY" --adopt
  assert_failure
  assert_output --partial "CONFLICT"
  assert [ ! -L "$SKILLS/handmade" ]
  assert_equal "$(cat "$SKILLS/handmade/SKILL.md")" irreplaceable
}

@test "--adopt REFUSES a directory whose links point outside the repos" {
  mkskill "$PUB" ops/outsider
  mkdir -p "$SKILLS/outsider" "$HOME/elsewhere"
  printf 'x\n' > "$HOME/elsewhere/SKILL.md"
  ln -s "$HOME/elsewhere/SKILL.md" "$SKILLS/outsider/SKILL.md"

  run "$SKILL_DEPLOY" --adopt
  assert_failure
  assert_output --partial "CONFLICT"
  assert [ ! -L "$SKILLS/outsider" ]
}

@test "--adopt REFUSES an empty directory, which is not provably ours" {
  mkskill "$PUB" ops/hollow
  mkdir -p "$SKILLS/hollow"
  run "$SKILL_DEPLOY" --adopt
  assert_failure
  assert_output --partial "CONFLICT"
  assert [ ! -L "$SKILLS/hollow" ]
}

# ── non-destructive default, and convergence ─────────────────────────────────

@test "--dry-run touches nothing" {
  mkskill "$PUB" ops/nested-one
  run "$SKILL_DEPLOY" --dry-run
  assert_success
  assert_output --partial "WOULD LINK"
  assert [ ! -e "$SKILLS/nested-one" ]
}

@test "a second run is a no-op, not a re-link" {
  mkskill "$PUB"  ops/nested-one
  mkskill "$PRIV" memory/priv-one
  run "$SKILL_DEPLOY"; assert_success
  before=$(readlink "$SKILLS/nested-one")

  run "$SKILL_DEPLOY"
  assert_success
  assert_output --partial "0 linked"
  assert_output --partial "2 already correct"
  assert_equal "$(readlink "$SKILLS/nested-one")" "$before"
}

@test "an unknown option is rejected rather than ignored" {
  run "$SKILL_DEPLOY" --clobber-everything
  assert_failure
  assert_output --partial "unknown option"
}

@test "a missing private overlay is fine, not fatal" {
  rm -rf "$PRIV"
  mkskill "$PUB" ops/nested-one
  run "$SKILL_DEPLOY"
  assert_success
  assert [ -L "$SKILLS/nested-one" ]
}
