#!/usr/bin/env bats
# The global git hook dispatcher (.config/git/hooks): real pushes and commits in fixture repos, with
# a throwaway global config that points core.hooksPath at the committed dispatcher. Nothing here
# touches the real ~/.gitconfig or any live repo. The fixtures' origins are never contacted: pushes go
# to a local bare repo, and `origin` is a URL that is only read.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  cp -r "$ROOT/.config/git/hooks" "$T/hooks"
  echo acme-private > "$T/hooks/owners.private"
  git config --global core.hooksPath "$T/hooks"
  git config --global user.name t
  git config --global user.email t@t
  git init -q --bare "$T/bare.git"
  git init -q -b main "$T/repo"
  cd "$T/repo"
  git commit -q --allow-empty -m init
  git remote add bare "$T/bare.git"
  RAN="$T/ran"
}

# committed_hook <name> [<body>]: a committed, executable .githooks/<name> that records it ran.
committed_hook() {
  mkdir -p "$T/repo/.githooks"
  printf '#!/usr/bin/env bash\necho "committed %s $*" >> "%s"\n%s\n' "$1" "$RAN" "${2:-}" > "$T/repo/.githooks/$1"
  chmod +x "$T/repo/.githooks/$1"
}

# repo_hook <name>: a hook in the repo's own .git/hooks, as git-lfs install writes it.
repo_hook() {
  printf '#!/usr/bin/env bash\necho "git-dir %s $*" >> "%s"\ncat > /dev/null\n' "$1" "$RAN" > "$T/repo/.git/hooks/$1"
  chmod +x "$T/repo/.git/hooks/$1"
}

push() { git -C "$T/repo" push -q bare HEAD:refs/heads/x 2>&1; }

@test ".gitconfig sets the dispatcher dir as the global hooksPath" {
  run git config -f "$ROOT/.gitconfig" --get core.hooksPath
  assert_success
  assert_output '~/.config/git/hooks'
}

@test "every hook name has an executable stub" {
  for h in pre-commit pre-push commit-msg post-checkout post-commit post-merge prepare-commit-msg pre-merge-commit pre-rebase post-rewrite; do
    [ -x "$ROOT/.config/git/hooks/$h" ]
  done
}

@test "our origin: a committed .githooks/pre-push runs, with git's args" {
  git remote add origin git@github.com:Kblack0610/x.git
  committed_hook pre-push
  run push
  assert_success
  run cat "$RAN"
  assert_output --partial "committed pre-push bare"
}

@test "our origin on a Forgejo host, over https, runs it too" {
  git remote add origin https://git.example.test/kblack0610/tilecast.git
  committed_hook pre-push
  run push
  assert_success
  run cat "$RAN"
  assert_output --partial "committed pre-push"
}

@test "an owner from owners.private matches, in any case" {
  git remote add origin git@github.com:acme-private/p.git
  committed_hook pre-push
  run push
  assert_success
  run cat "$RAN"
  assert_output --partial "committed pre-push"
}

@test "a red committed pre-push refuses the push, and its refs reach it on stdin" {
  git remote add origin git@github.com:Kblack0610/x.git
  committed_hook pre-push 'cat > "'"$T"'/stdin"; exit 1'
  run push
  assert_failure
  run cat "$T/stdin"
  assert_output --partial "refs/heads/x"
  ! git -C "$T/bare.git" rev-parse -q --verify refs/heads/x
}

@test "a third-party origin does not run its .githooks" {
  git remote add origin git@github.com:someone-else/x.git
  committed_hook pre-push
  committed_hook pre-commit
  run push
  assert_success
  git commit -q --allow-empty -m two
  [ ! -e "$RAN" ]
}

@test "a repo with no origin does not run its .githooks" {
  committed_hook pre-push
  run push
  assert_success
  [ ! -e "$RAN" ]
}

@test "a non-executable .githooks file is not run" {
  git remote add origin git@github.com:Kblack0610/x.git
  committed_hook pre-push
  chmod -x "$T/repo/.githooks/pre-push"
  run push
  assert_success
  [ ! -e "$RAN" ]
}

@test "a repo with only git-lfs style hooks still gets its pre-push, for any origin" {
  git remote add origin git@github.com:someone-else/x.git
  repo_hook pre-push
  run push
  assert_success
  run cat "$RAN"
  assert_output --partial "git-dir pre-push bare"
}

@test "our committed hook wins over the git dir's, so lfs does not run twice" {
  git remote add origin git@github.com:Kblack0610/x.git
  committed_hook pre-push
  repo_hook pre-push
  run push
  assert_success
  run cat "$RAN"
  assert_output --partial "committed pre-push"
  refute_output --partial "git-dir"
}

@test "a worktree runs the main clone's committed hook from its own checkout" {
  git remote add origin git@github.com:Kblack0610/x.git
  committed_hook pre-push
  git add .githooks && git commit -q -m hook
  git worktree add -q "$T/wt" -b wt
  run git -C "$T/wt" push -q bare HEAD:refs/heads/y
  assert_success
  run cat "$RAN"
  assert_output --partial "committed pre-push"
}

@test "a repo-local core.hooksPath wins over the global dispatcher" {
  git remote add origin git@github.com:Kblack0610/x.git
  committed_hook pre-push
  mkdir -p "$T/own"
  printf '#!/usr/bin/env bash\necho own >> "%s"\n' "$RAN" > "$T/own/pre-push"
  chmod +x "$T/own/pre-push"
  git config core.hooksPath "$T/own"
  run push
  assert_success
  run cat "$RAN"
  assert_output 'own'
}

@test "commit-msg and pre-commit are dispatched the same way" {
  git remote add origin git@github.com:Kblack0610/x.git
  committed_hook pre-commit
  committed_hook commit-msg
  git commit -q --allow-empty -m two
  run cat "$RAN"
  assert_output --partial "committed pre-commit"
  assert_output --partial "committed commit-msg"
}

@test "a hook dir that is this one does not loop" {
  git remote add origin git@github.com:someone-else/x.git
  rm -rf "$T/repo/.git/hooks"
  ln -s "$T/hooks" "$T/repo/.git/hooks"
  run timeout 10 git -C "$T/repo" push -q bare HEAD:refs/heads/x
  assert_success
}

@test "-c core.hooksPath=/dev/null still skips every hook" {
  git remote add origin git@github.com:Kblack0610/x.git
  committed_hook pre-push
  run git -C "$T/repo" -c core.hooksPath=/dev/null push -q bare HEAD:refs/heads/x
  assert_success
  [ ! -e "$RAN" ]
}

# fake_lfs: a git-lfs on PATH that records `git lfs <args>`, as the binary git finds for `git lfs`.
fake_lfs() {
  mkdir -p "$T/bin"
  printf '#!/usr/bin/env bash\necho "lfs $*" >> "%s"\ncat > /dev/null\n' "$RAN" > "$T/bin/git-lfs"
  chmod +x "$T/bin/git-lfs"
  PATH="$T/bin:$PATH"
}

@test "an lfs repo with no hook of its own gets git lfs pre-push, whoever owns it" {
  fake_lfs
  git remote add origin git@github.com:someone-else/x.git
  echo '*.bin filter=lfs diff=lfs merge=lfs -text' > "$T/repo/.gitattributes"
  run push
  assert_success
  run cat "$RAN"
  assert_output --partial "lfs pre-push bare"
}

@test "a repo that does not use lfs never calls it" {
  fake_lfs
  git remote add origin git@github.com:someone-else/x.git
  run push
  assert_success
  [ ! -e "$RAN" ]
}

@test "a worktree falls back to the main clone's .git/hooks" {
  git remote add origin git@github.com:someone-else/x.git
  repo_hook pre-push
  git worktree add -q "$T/wt" -b wt
  run git -C "$T/wt" push -q bare HEAD:refs/heads/y
  assert_success
  run cat "$RAN"
  assert_output --partial "git-dir pre-push"
}

@test "an origin with no owner segment is never ours, even if the repo is named like an owner" {
  git remote add origin gitbox:kblack0610.git
  committed_hook pre-push
  run push
  assert_success
  [ ! -e "$RAN" ]
}

@test "an owner from owners.private matches in another case" {
  git remote add origin git@github.com:ACME-Private/x.git
  committed_hook pre-push
  run push
  assert_success
  run cat "$RAN"
  assert_output --partial "committed pre-push"
}

@test "prepare-commit-msg, pre-rebase, pre-merge-commit and post-rewrite fall back to the git dir" {
  git remote add origin git@github.com:someone-else/x.git
  for h in prepare-commit-msg pre-merge-commit pre-rebase post-rewrite; do
    [ -x "$ROOT/.config/git/hooks/$h" ]
  done
  repo_hook prepare-commit-msg
  git commit -q --allow-empty -m two
  run cat "$RAN"
  assert_output --partial "git-dir prepare-commit-msg"
}
