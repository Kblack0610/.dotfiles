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
#                            the tool exists: a repair that only reports what it attached can
#                            say "in sync" forever while a mirror keeps serving the wrong file.
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
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/stow-link.sh"
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

# mkrepo_worktree <dir> <ignore-line>... — the same thing, but <dir> is a git WORKTREE.
#
# Worktrees are the working convention in these repos, so the tool has to accept one: a
# worktree is exactly where you point it to preview a change before landing it. In a
# worktree `.git` is a regular FILE holding `gitdir: <main>/.git/worktrees/<name>`, so any
# `[ -d "$dir/.git" ]` test is false and the repo silently drops out of the run.
#
# The base repo lives beside the worktree INSIDE $BATS_TEST_TMPDIR, so nothing is registered
# against the real checkout and there is nothing to prune in teardown - bats deletes the
# whole thing. Never build this fixture off $REPO_ROOT.
WT_N=0
mkrepo_worktree() {
  local dir="$1"; shift
  local base="$dir.base"
  WT_N=$((WT_N + 1))
  mkdir -p "$base"
  git -C "$base" init -q
  printf '%s\n' "$@" > "$base/.stow-local-ignore"
  git -C "$base" add -- .stow-local-ignore
  git -C "$base" -c user.email=t@example.com -c user.name=tester commit -qm base
  git -C "$base" worktree add -q "$dir" -b "wt$WT_N"
  # The fixture must actually BE a worktree, or every assertion below passes for the wrong
  # reason. A plain checkout would satisfy them all.
  [ -f "$dir/.git" ] || fail "fixture is not a worktree: $dir/.git is not a regular file"
  [ ! -d "$dir/.git" ] || fail "fixture is not a worktree: $dir/.git is a directory"
}

# radd <repo> <path> <content> — track a file in a repo.
radd() {
  local repo="$1" path="$2" content="$3"
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add -- "$path"
}

# link <path> <repo> - deploy a path correctly, the way stow would: a RELATIVE link.
link() {
  local path="$1" repo="$2"
  mkdir -p "$HOME/$(dirname "$path")"
  stow_link "$HOME/$path" "$repo/$path"
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
  stow_link "$HOME/$path" "$PUB/$path"
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

# fold_local_src - ~/.local/src is one folded link into the public tree.
fold_local_src() {
  radd "$PUB" .local/src/pubthing/a 'a'
  mkdir -p "$HOME/.local"
  stow_link "$HOME/.local/src" "$PUB/.local/src"
}

# track_symlink <repo> <path> <target> - a mode-120000 entry in that repo's index.
track_symlink() {
  ln -sfn "$3" "$1/$2"
  git -C "$1" add -- "$2"
}

# world_wt_private — the same world, but the PRIVATE repo is a git worktree.
world_wt_private() {
  mkrepo          "$PUB"  '^/\.git$' '^/\.gitignore$' '^/README\.md$'
  mkrepo_worktree "$PRIV" '^/\.git$' '^/\.gitignore$' '^/\.stow-local-ignore$' '^/README\.md$'
  radd "$PUB"  README.md            'public readme'
  radd "$PUB"  .local/bin/pubtool   'public tool v1'
  radd "$PRIV" README.md            'private readme'
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

# -- MIRROR: a physical copy serving a tracked path --

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

# -- MISSING: nothing resolves at the path --

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

@test "--apply writes the RELATIVE link stow writes, not an absolute one" {
  world
  radd "$PUB" .local/bin/never-stowed 'v1'
  run "$DEPLOY" --apply
  assert_success
  assert_equal "$(readlink "$HOME/.local/bin/never-stowed")" '../../.dotfiles/.local/bin/never-stowed'
}

# -- ABSLINK: the right file, by a link stow does not own --

@test "an absolute link to the tracked source is ABSLINK, and --apply rewrites it relative" {
  world
  ln -sfn "$PUB/.local/bin/pubtool" "$HOME/.local/bin/pubtool"
  run "$DEPLOY" --check
  assert_failure
  assert_output --partial 'ABSLINK'
  assert_output --partial '.local/bin/pubtool'
  run "$DEPLOY" --apply
  assert_success
  assert_equal "$(readlink "$HOME/.local/bin/pubtool")" '../../.dotfiles/.local/bin/pubtool'
  run "$DEPLOY" --check
  assert_success
}

@test "an absolute FOLDED directory link is one ABSLINK, not one per file" {
  world
  radd "$PUB" .config/tool/a 'a'
  radd "$PUB" .config/tool/b 'b'
  ln -sfn "$PUB/.config/tool" "$HOME/.config/tool"
  run "$DEPLOY" --check
  assert_failure
  assert_equal "$(grep -c 'ABSLINK' <<< "$output")" 2   # the finding plus the legend line
  run "$DEPLOY" --apply
  assert_success
  assert_equal "$(readlink "$HOME/.config/tool")" '../.dotfiles/.config/tool'
}

@test "an absolute link to some OTHER file is not ABSLINK: only a link to the same path is rewritten" {
  world
  radd "$PRIV" .local/bin/shared 'private copy'
  mkdir -p "$HOME/elsewhere"; cp "$PRIV/.local/bin/shared" "$HOME/elsewhere/shared"
  ln -sfn "$HOME/elsewhere/shared" "$HOME/.local/bin/shared"
  run "$DEPLOY" --check
  assert_failure
  assert_output --partial 'MIRROR'
  refute_output --regexp 'ABSLINK +private'
}

# The ground truth is stow itself. Before --apply an absolute link aborts the whole run, so a
# new file never deploys; after it, stow owns every link and the next new file deploys.
@test "after --apply, stow no longer aborts and a new file deploys" {
  command -v stow >/dev/null || skip 'stow not installed'
  world
  ln -sfn "$PUB/.local/bin/pubtool" "$HOME/.local/bin/pubtool"
  run stow -d "$PUB" -t "$HOME" --no-folding -n -v .
  assert_failure
  assert_output --partial 'not owned by stow'
  run "$DEPLOY" --apply
  assert_success
  radd "$PUB" .local/bin/brand-new 'v1'
  run stow -d "$PUB" -t "$HOME" --no-folding -v .
  assert_success
  assert_equal "$(readlink -f "$HOME/.local/bin/brand-new")" "$(readlink -f "$PUB/.local/bin/brand-new")"
}

@test "--missing: --check sees only MISSING, --apply links it and leaves a physical copy alone" {
  world
  radd "$PUB"  .local/bin/new-tool 'v1'
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'running'
  run "$DEPLOY" --check --missing
  assert_failure
  assert_output --partial 'new-tool'
  refute_output --partial '.local/bin/svc'
  run "$DEPLOY" --apply --missing
  assert_success
  assert_output --partial '1 path(s) linked, none missing now (copies not checked'
  assert_equal "$(readlink -f "$HOME/.local/bin/new-tool")" "$(readlink -f "$PUB/.local/bin/new-tool")"
  [ ! -L "$PUB/.local/bin/svc" ] || fail '--missing converted a physical copy'
  assert_equal "$(cat "$PUB/.local/bin/svc")" 'running'
  run "$DEPLOY" --check --missing
  assert_success
  assert_output --partial 'none of'
  run "$DEPLOY" --check
  assert_failure
  assert_output --regexp 'MIRROR +private +\.local/bin/svc'
}

@test "--missing --apply with nothing missing does nothing and says so" {
  world
  run "$DEPLOY" --apply --missing
  assert_success
  assert_output --partial 'nothing to attach'
}

# -- --missing: one directory link where a link per file would land in the other repo's tree --

@test "a new private directory under a folded public dir gets one dir link, not links inside the public tree" {
  world
  fold_local_src
  radd "$PRIV" .local/src/newtool/run 'run'
  radd "$PRIV" .local/src/newtool/lib/util 'util'
  track_symlink "$PRIV" .local/src/newtool/run-link run
  run "$DEPLOY" --check --missing
  assert_failure
  assert_output --partial '1 of 6 deploy path(s)'
  assert_output --regexp 'MISSING +private +\.local/src/newtool +directory'
  run "$DEPLOY" --apply --missing
  assert_success
  assert_output --partial '1 path(s) linked'
  [ -L "$PUB/.local/src/newtool" ] || fail 'the public tree got a physical directory'
  assert_equal "$(readlink "$PUB/.local/src/newtool")" '../../../.dotfiles-private/.local/src/newtool'
  assert_equal "$(cat "$HOME/.local/src/newtool/lib/util")" 'util'
  run "$DEPLOY" --check
  assert_success
}

@test "a new private file in a directory the public tree already has is one file link" {
  world
  fold_local_src
  radd "$PRIV" .local/src/pubthing/b 'b'
  run "$DEPLOY" --apply --missing
  assert_success
  [ ! -L "$PUB/.local/src/pubthing" ] || fail 'the public directory was replaced'
  assert_equal "$(readlink "$PUB/.local/src/pubthing/b")" '../../../../.dotfiles-private/.local/src/pubthing/b'
}

@test "a new directory under a real \$HOME directory stays per file, as stow --no-folding writes it" {
  world
  radd "$PRIV" .config/newapp/a 'a'
  radd "$PRIV" .config/newapp/sub/b 'b'
  run "$DEPLOY" --apply --missing
  assert_success
  assert_output --partial '2 path(s) linked'
  [ -d "$HOME/.config/newapp" ] && [ ! -L "$HOME/.config/newapp" ] || fail 'a real parent got a directory link'
  assert_equal "$(readlink "$HOME/.config/newapp/sub/b")" '../../../.dotfiles-private/.config/newapp/sub/b'
}

@test "a dangling directory link left by a move to the overlay is repointed at the overlay" {
  world
  mkdir -p "$HOME/.config"; ln -s ../.dotfiles/.config/moved "$HOME/.config/moved"
  radd "$PRIV" .config/moved/a 'a'
  radd "$PRIV" .config/moved/b 'b'
  run "$DEPLOY" --apply --missing
  assert_success
  assert_output --partial '1 path(s) linked'
  assert_equal "$(readlink "$HOME/.config/moved")" '../.dotfiles-private/.config/moved'
  assert_equal "$(cat "$HOME/.config/moved/b")" 'b'
}

@test "a directory holding a stow-ignored path keeps per-file links: a dir link would deploy that path" {
  world
  printf '%s\n' '^/\.local/src/newtool/secret$' >> "$PRIV/.stow-local-ignore"
  fold_local_src
  radd "$PRIV" .local/src/newtool/run 'run'
  radd "$PRIV" .local/src/newtool/secret 'not deployed'
  run "$DEPLOY" --apply --missing
  assert_success
  [ ! -L "$PUB/.local/src/newtool" ] || fail 'the dir link deploys a path stow ignores'
  [ ! -e "$HOME/.local/src/newtool/secret" ] || fail 'the ignored path deployed'
  assert_equal "$(cat "$HOME/.local/src/newtool/run")" 'run'
}

# ── things that must never enter the manifest ────────────────────────────────

@test "a deployed TRACKED SYMLINK is not diffed" {
  # git stores a symlink as a mode-120000 blob holding the link target, so comparing one to
  # the resolved file on disk always reports a difference. 15 false positives came from
  # systemd .wants/ entries alone the last time someone tried; dotfiles-drift skips them
  # for the same reason.
  world
  track_symlink "$PRIV" .local/bin/linky privtool
  assert_equal "$(git -C "$PRIV" ls-files -s -- .local/bin/linky | cut -d' ' -f1)" '120000'
  link .local/bin/linky "$PRIV"
  run "$DEPLOY" --check
  assert_success
  refute_output --partial 'linky'
  assert_output --partial 'all 3 deploy path(s)'
}

@test "a TRACKED SYMLINK with nothing in \$HOME is MISSING, and --missing links it" {
  world
  track_symlink "$PRIV" .local/bin/linky privtool
  run "$DEPLOY" --check
  assert_failure
  assert_output --regexp 'MISSING +private +\.local/bin/linky'
  run "$DEPLOY" --apply --missing
  assert_success
  assert_equal "$(readlink "$HOME/.local/bin/linky")" '../../.dotfiles-private/.local/bin/linky'
  assert_equal "$(cat "$HOME/.local/bin/linky")" 'private tool v2'
}

@test "a TRACKED SYMLINK that dangles in its repo, or stow ignores, is not a finding" {
  world
  track_symlink "$PRIV" .local/bin/dead not-checked-out
  printf '%s\n' '^/\.local/bin/skipped$' >> "$PRIV/.stow-local-ignore"
  track_symlink "$PRIV" .local/bin/skipped privtool
  run "$DEPLOY" --check
  assert_success
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

# ── git WORKTREES ────────────────────────────────────────────────────────────
# The repo-detection test used to be `[ -d "$dir/.git" ]`, which is false for a worktree
# because there `.git` is a regular FILE holding a `gitdir:` pointer. Since worktrees are
# the working convention here, the tool could not be pointed at one - which is exactly when
# you want it, to preview a change before landing it. Observed before the fix:
#
#   dotfiles-deploy: NOT CHECKED - private repo at .../wt-priv is absent or not a git repo
#   dotfiles-deploy: clean - all 1 deploy path(s) resolve to their tracked source
#
# Exit 0, the word "clean", and half the world never looked at. That is the house failure
# mode again, and the reason these tests assert on the deploy-path COUNT and on the absence
# of "NOT CHECKED" rather than only on the exit code.

@test "a PRIVATE repo that is a git worktree is examined, not skipped" {
  world_wt_private
  run "$DEPLOY" --check
  assert_success
  refute_output --partial 'NOT CHECKED'
  # 2, not 1: pubtool AND privtool. The old code dropped the whole private side and still
  # printed "clean", so the count is the assertion that can actually tell them apart.
  assert_output --partial 'all 2 deploy path(s)'
}

@test "a PUBLIC repo that is a git worktree is examined, not skipped" {
  mkrepo_worktree "$PUB"  '^/\.git$' '^/\.stow-local-ignore$' '^/README\.md$'
  mkrepo          "$PRIV" '^/\.git$' '^/\.stow-local-ignore$' '^/README\.md$'
  radd "$PUB"  .local/bin/pubtool   'public tool v1'
  radd "$PRIV" .local/bin/privtool  'private tool v2'
  link .local/bin/pubtool  "$PUB"
  link .local/bin/privtool "$PRIV"
  run "$DEPLOY" --check
  assert_success
  refute_output --partial 'NOT CHECKED'
  assert_output --partial 'all 2 deploy path(s)'
}

@test "a MIRROR is still detected when the owning repo is a worktree" {
  # The finding this tool exists for, over the fixture that used to be invisible.
  world_wt_private
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'running'
  run "$DEPLOY" --check
  assert_failure
  assert_output --partial 'MIRROR'
  assert_output --partial '.local/bin/svc'
  assert_output --partial 'CONTENT DIFFERS'
}

@test "--apply CONVERGES against a worktree, and serves the tracked content" {
  world_wt_private
  radd "$PRIV" .local/bin/svc 'tracked'
  mirror_into_public .local/bin/svc 'running'
  run "$DEPLOY" --apply
  assert_success
  assert_output --partial 'converged'
  assert_equal "$(cat "$HOME/.local/bin/svc")" 'tracked'
  run "$DEPLOY" --check
  assert_success
  assert_output --partial 'clean'
}

@test "the refuse-to-delete-tracked-source guard holds when the repo is a worktree" {
  # The blast-radius case, and the reason the fix had to reach tracked_somewhere() too and
  # not just the manifest builder. That guard also asked `[ -d "$repo/.git" ]`, so with a
  # worktree it saw no repo, answered "not tracked", and the write went ahead - deleting a
  # real file out of a real repo, which is the worst thing this tool can do.
  #
  # Here the public repo TRACKS .config/waybar/style.css but stow-ignores it, so it is not a
  # public deploy path, yet it is what $HOME resolves to for the private path of the same
  # name. Converting it would destroy public source.
  mkrepo_worktree "$PUB"  '^/\.git$' '^/\.config/waybar$'
  mkrepo          "$PRIV" '^/\.git$' '^/\.stow-local-ignore$'
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
    || fail 'it deleted tracked repo source out of a worktree'
  assert_equal "$(cat "$PUB/.config/waybar/style.css")" 'the public tracked css'
}

@test "a SUBDIRECTORY of a repo is still not a repo, worktree or not" {
  # The strictness the old `-d "$dir/.git"` test bought, which must survive the fix. A
  # mistyped DOTFILES_PRIVATE pointing inside some unrelated checkout must be rejected, not
  # silently adopted as a dotfiles repo - `rev-parse --git-dir` alone would accept it.
  world_wt_private
  run env DOTFILES_PRIVATE="$PRIV/.local" "$DEPLOY" --check
  assert_success
  assert_output --partial 'NOT CHECKED'
  assert_output --partial 'private'
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
