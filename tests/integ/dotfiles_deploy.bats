#!/usr/bin/env bats
# dotfiles-deploy's `$SELF --verb` contract, exercised as a real subprocess against a fake
# two-repo world built inside the sandbox $HOME.
#
# This tier is where the blast radius is. dotfiles-deploy DELETES a file and puts a symlink
# where it stood, which by the repo's own coverage ranking is tier 1 (see the
# shell-test-harness skill: "scripts that delete things, and whatever they consult to decide
# what to spare"). Three properties matter more than the rest, and each has a test below:
#
#   NON-DESTRUCTIVE DEFAULT  a bare invocation, and --check, must leave the disk exactly as
#                            they found it. A repair tool that acts by default is one nobody
#                            can safely run to look.
#   CONVERGENCE              --apply then --check must be clean. This is the entire reason
#                            the tool exists: dotfiles-overlay-link reports success and then
#                            reports "already in sync" forever while the mirror it skipped
#                            keeps serving the wrong file.
#   REFUSES RATHER THAN GUESSES  dual ownership, an empty manifest, a repo that enumerated
#                            nothing, and a deployed copy that turns out to be tracked
#                            source, all exit 2 or skip loudly. Every failure mode in this
#                            repo's tooling has been a silent success.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DEPLOY="$REPO_ROOT/.local/bin/dotfiles-deploy"
  PUB="$HOME/.dotfiles"
  PRIV="$HOME/.dotfiles-private"
  export DEPLOY PUB PRIV
}

# ── fixture builders ─────────────────────────────────────────────────────────

# mkrepo <dir> <ignore-line>... — a git repo with an index and a .stow-local-ignore.
# `git add` is enough; nothing here reads a commit, because stow deploys the WORKING TREE
# and so does dotfiles-deploy.
mkrepo() {
  local dir="$1"; shift
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '%s\n' "$@" > "$dir/.stow-local-ignore"
  git -C "$dir" add -- .stow-local-ignore
}

# radd <repo> <path> <content> — track a file in a repo.
radd() {
  local repo="$1" path="$2" content="$3"
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add -- "$path"
}

# link <path> <repo> — deploy a path correctly, the way stow would.
link() {
  local path="$1" repo="$2"
  mkdir -p "$HOME/$(dirname "$path")"
  ln -sfn "$repo/$path" "$HOME/$path"
}

# copy <path> <repo> [content] — the BUG: a physical copy in the public tree of a path the
# private repo owns, with $HOME resolving to it. Content defaults to the tracked content,
# which is the latent case; pass a third argument for the already-drifted case.
mirror_into_public() {
  local path="$1" content="${2:-}"
  mkdir -p "$PUB/$(dirname "$path")"
  if [ -n "$content" ]; then printf '%s\n' "$content" > "$PUB/$path"
  else cp -- "$PRIV/$path" "$PUB/$path"; fi
  mkdir -p "$HOME/$(dirname "$path")"
  ln -sfn "$PUB/$path" "$HOME/$path"
}

# world — the baseline: two repos, both correctly deployed, nothing wrong.
# Both track README.md, .gitignore and .stow-local-ignore, exactly as the real pair does.
world() {
  mkrepo "$PUB"  '^/\.git$' '^/\.gitignore$' '^/README\.md$'
  mkrepo "$PRIV" '^/\.git$' '^/\.gitignore$' '^/\.stow-local-ignore$' '^/README\.md$'
  radd "$PUB"  README.md            'public readme'
  radd "$PUB"  .gitignore           'ignored-by-public'
  radd "$PUB"  .local/bin/pubtool   'public tool v1'
  radd "$PRIV" README.md            'private readme'
  radd "$PRIV" .gitignore           'ignored-by-private'
  radd "$PRIV" .local/bin/privtool  'private tool v2'
  link .local/bin/pubtool  "$PUB"
  link .local/bin/privtool "$PRIV"
}

# ── the clean baseline ───────────────────────────────────────────────────────

@test "a correctly deployed world is clean and exits 0" {
  world
  run "$DEPLOY" --check
  assert_success
  assert_output --partial 'clean'
}

@test "the clean report names a NON-ZERO deploy-path count" {
  # "nothing to check" and "everything passed" must not print the same thing. A manifest
  # that silently came back empty would otherwise render as a clean run.
  world
  run "$DEPLOY" --check
  assert_success
  refute_output --partial 'all 0 deploy path(s)'
  assert_output --regexp 'all [1-9][0-9]* deploy path\(s\)'
}

@test "the three paths tracked by BOTH repos are not deploy paths and not a conflict" {
  # README.md, .gitignore and .stow-local-ignore are tracked in both repos. None of them is
  # linked into $HOME here, so if any counted as a deploy path this run would report it
  # MISSING -- or refuse with a CONFLICT.
  world
  run "$DEPLOY" --check
  assert_success
  refute_output --partial 'README.md'
  refute_output --partial '.gitignore'
  refute_output --partial '.stow-local-ignore'
}

@test "stow's anchoring is honoured end to end: a nested README IS a deploy path" {
  # `^/README\.md$` excludes only the top-level file. Getting this wrong shrinks the
  # manifest silently, which is the one failure this tool cannot report on itself.
  world
  radd "$PUB" .local/bin/README.md 'docs for the bin dir'
  run "$DEPLOY" --check
  assert_failure
  assert_output --partial '.local/bin/README.md'
}

# ── MIRROR: the failure dotfiles-overlay-link structurally cannot fix ────────

@test "a physical copy in the public tree serving a private path is reported MIRROR" {
  world
  radd "$PRIV" .local/bin/agentctl-dream 'tracked v2'
  mirror_into_public .local/bin/agentctl-dream 'stale v1'
  run "$DEPLOY" --check
  assert_failure
  assert_output --partial 'MIRROR'
  assert_output --partial '.local/bin/agentctl-dream'
  assert_output --partial 'CONTENT DIFFERS'
}

@test "a mirror whose content still matches is reported too, as latent" {
  # dotfiles-drift only fires once the content has ALREADY diverged. On this machine that
  # is 5 of 53 paths; the other 48 are one edit away and nothing reports them.
  world
  radd "$PRIV" .local/bin/agent-notify 'same on both sides'
  mirror_into_public .local/bin/agent-notify
  run "$DEPLOY" --check
  assert_failure
  assert_output --partial 'MIRROR'
  assert_output --partial 'will drift on the next edit'
}

@test "the report shows the diff between what is tracked and what is running" {
  world
  radd "$PRIV" .local/bin/svc 'line-from-the-tracked-source'
  mirror_into_public .local/bin/svc 'line-from-the-stale-copy'
  run "$DEPLOY" --check
  assert_failure
  assert_output --partial 'tracked   private/.local/bin/svc'
  assert_output --partial 'deployed'
  assert_output --partial '-line-from-the-tracked-source'
  assert_output --partial '+line-from-the-stale-copy'
}

# ── the non-destructive default ──────────────────────────────────────────────

@test "--check does not touch the disk" {
  world
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'running'
  run "$DEPLOY" --check
  assert_failure
  [ -f "$PUB/.local/bin/svc" ] && [ ! -L "$PUB/.local/bin/svc" ] || fail 'the copy was modified by a read-only run'
  assert_equal "$(cat "$PUB/.local/bin/svc")" 'running'
}

@test "a bare invocation with no flags is --check, not --apply" {
  # The one property that decides whether this tool is safe to type. If the default ever
  # became destructive, every hook and every curious human would rewrite the tree.
  world
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'running'
  run "$DEPLOY"
  assert_failure
  [ ! -L "$PUB/.local/bin/svc" ] || fail 'a bare invocation converted a file'
  assert_equal "$(cat "$PUB/.local/bin/svc")" 'running'
}

# ── --apply: convert, and converge ───────────────────────────────────────────

@test "--apply replaces the physical copy with a symlink to the tracked source" {
  world
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'running'
  run "$DEPLOY" --apply
  assert_success
  [ -L "$PUB/.local/bin/svc" ] || fail 'the copy is still a real file'
  assert_equal "$(readlink -f "$PUB/.local/bin/svc")" "$(readlink -f "$PRIV/.local/bin/svc")"
  # and what $HOME serves is now the tracked content, which is the whole point
  assert_equal "$(cat "$HOME/.local/bin/svc")" 'tracked'
}

@test "--apply CONVERGES: a re-check straight afterwards is clean" {
  world
  radd "$PRIV" .local/bin/svc  'tracked'
  radd "$PRIV" .local/bin/svc2 'tracked too'
  mirror_into_public .local/bin/svc  'running'
  mirror_into_public .local/bin/svc2
  "$DEPLOY" --apply
  run "$DEPLOY" --check
  assert_success
  assert_output --partial 'clean'
}

@test "--apply says it converged, and says how many it repaired" {
  world
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'running'
  run "$DEPLOY" --apply
  assert_success
  assert_output --partial 'converged'
  assert_output --partial '1 path(s) repaired'
}

@test "--apply on an already-clean world does nothing and says so" {
  world
  run "$DEPLOY" --apply
  assert_success
  assert_output --partial 'nothing to do'
}

# ── backups: the running copy exists in no repo's history ────────────────────

@test "--apply backs up a copy whose content differs, before overwriting it" {
  world
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'the version that was actually running'
  run "$DEPLOY" --apply
  assert_success
  assert_output --partial 'backed up'
  run bash -c 'cat "$HOME/.local/state/dotfiles-deploy/backup"/*/.local/bin/svc'
  assert_output 'the version that was actually running'
}

@test "--apply does NOT back up a copy that matches: no litter for nothing lost" {
  world
  radd "$PRIV" .local/bin/svc 'identical'
  mirror_into_public .local/bin/svc
  run "$DEPLOY" --apply
  assert_success
  refute_output --partial 'backed up'
  [ ! -d "$HOME/.local/state/dotfiles-deploy/backup" ] || fail 'backed up a file with nothing to lose'
}

# ── MISSING: what dotfiles-overlay-link already did ──────────────────────────

@test "a tracked path with no counterpart in \$HOME is MISSING, and --apply links it" {
  world
  radd "$PRIV" .local/bin/never-stowed 'v1'
  run "$DEPLOY" --check
  assert_failure
  assert_output --partial 'MISSING'
  assert_output --partial 'never-stowed'
  run "$DEPLOY" --apply
  assert_success
  assert_equal "$(readlink -f "$HOME/.local/bin/never-stowed")" "$(readlink -f "$PRIV/.local/bin/never-stowed")"
}

@test "a dangling symlink is MISSING and says so, rather than reading as deployed" {
  world
  radd "$PRIV" AGENTS.md 'the real one'
  ln -sfn "$PUB/AGENTS.md" "$HOME/AGENTS.md"     # public no longer has it
  run "$DEPLOY" --check
  assert_failure
  assert_output --partial 'AGENTS.md'
  assert_output --partial 'dangles'
}

# ── things that must never enter the manifest ────────────────────────────────

@test "a TRACKED SYMLINK is skipped on both sides, not diffed" {
  # git stores a symlink as a mode-120000 blob holding the link target, so comparing one to
  # the resolved file on disk always reports a difference. 15 false positives came from
  # systemd .wants/ entries alone the last time someone tried; dotfiles-drift skips them
  # for the same reason.
  world
  ln -sfn "$PRIV/.local/bin/privtool" "$PUB/.local/bin/linky"
  git -C "$PUB" add -- .local/bin/linky
  assert_equal "$(git -C "$PUB" ls-files -s -- .local/bin/linky | cut -d' ' -f1)" '120000'
  run "$DEPLOY" --check
  assert_success
  refute_output --partial 'linky'
}

# ── refusals ─────────────────────────────────────────────────────────────────

@test "a path deployed by BOTH repos is a hard error, not a precedence rule" {
  world
  radd "$PUB"  .local/bin/contested 'public version'
  radd "$PRIV" .local/bin/contested 'private version'
  run "$DEPLOY" --check
  assert_equal "$status" 2
  assert_output --partial 'CONFLICT'
  assert_output --partial '.local/bin/contested'
  assert_output --partial 'public'
  assert_output --partial 'private'
}

@test "a dual-ownership refusal happens BEFORE anything is written" {
  world
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'running'
  radd "$PUB"  .local/bin/contested 'public version'
  radd "$PRIV" .local/bin/contested 'private version'
  run "$DEPLOY" --apply
  assert_equal "$status" 2
  [ ! -L "$PUB/.local/bin/svc" ] || fail 'it repaired something while refusing to run'
  assert_equal "$(cat "$PUB/.local/bin/svc")" 'running'
}

@test "a repo that enumerates ZERO tracked files is a refusal, not a clean run" {
  world
  rm -rf "$PRIV"
  mkdir -p "$PRIV"
  git -C "$PRIV" init -q
  run "$DEPLOY" --check
  assert_equal "$status" 2
  assert_output --partial 'ZERO tracked files'
}

@test "no repos at all is a refusal, not a clean run" {
  run env DOTFILES="$HOME/nope" DOTFILES_PRIVATE="$HOME/also-nope" "$DEPLOY" --check
  assert_equal "$status" 2
  assert_output --partial 'manifest is EMPTY'
}

@test "it refuses to replace a deployed copy that is itself TRACKED source" {
  # The guard on every write. Here the public repo tracks the file but stow-ignores it, so
  # it is not a public deploy path -- yet it is what $HOME resolves to for a private path.
  # Converting it would delete real source out of a real repo.
  mkrepo "$PUB"  '^/\.git$' '^/\.config/waybar$'
  mkrepo "$PRIV" '^/\.git$' '^/\.stow-local-ignore$'
  radd "$PUB"  .local/bin/pubtool          'public tool'
  radd "$PUB"  .config/waybar/style.css    'the public tracked css'
  radd "$PRIV" .config/waybar/style.css    'the private tracked css'
  link .local/bin/pubtool "$PUB"
  ln -sfn "$PUB/.config/waybar" "$HOME/.config/waybar"
  run "$DEPLOY" --apply
  assert_failure
  assert_output --partial 'TRACKED'
  assert_output --partial 'DID NOT CONVERGE'
  [ -f "$PUB/.config/waybar/style.css" ] && [ ! -L "$PUB/.config/waybar/style.css" ] \
    || fail 'it deleted tracked repo source'
  assert_equal "$(cat "$PUB/.config/waybar/style.css")" 'the public tracked css'
}

@test "an unknown argument is rejected rather than treated as data" {
  world
  run "$DEPLOY" --repair-everything
  assert_equal "$status" 2
  assert_output --partial 'unknown argument'
}

# ── the machine-readable surfaces ────────────────────────────────────────────

@test "--quiet prints nothing and signals only through the exit code" {
  world
  run "$DEPLOY" --quiet
  assert_success
  assert_output ''
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'running'
  run "$DEPLOY" --quiet
  assert_failure
  assert_output ''
}

@test "--json emits one record per finding with the documented keys" {
  world
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'running'
  run "$DEPLOY" --json
  assert_failure
  assert_output --partial '"status":"MIRROR"'
  assert_output --partial '"repo":"private"'
  assert_output --partial '"path":".local/bin/svc"'
  assert_output --partial '"deployed_from"'
  assert_output --regexp '"deploy_paths":[0-9]+'
}

@test "--help prints the header and exits 0 without reading any repo" {
  run env DOTFILES="$HOME/nope" DOTFILES_PRIVATE="$HOME/also-nope" "$DEPLOY" --help
  assert_success
  assert_output --partial 'dotfiles-deploy'
  assert_output --partial '--apply'
}
