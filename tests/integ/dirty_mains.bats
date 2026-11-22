#!/usr/bin/env bats
# dirty-mains: the probe behind the Sentinel watch of the same name. It must trip on a main
# checkout holding old changes or an old stash, stay quiet on fresh edits (someone mid-edit),
# and clear once the checkout is cleaned.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DIRTY="$REPO_ROOT/.local/bin/dirty-mains"
  REPO="$HOME/src/proj"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo one > "$REPO/a.txt"
  echo 'ignored/' > "$REPO/.gitignore"
  git -C "$REPO" add a.txt .gitignore
  git -C "$REPO" commit -qm init
  MAP="$HOME/map.json"
  # Two names for one clone (the subdirectory is reported once, at the clone) and one path
  # that is not a checkout at all.
  mkdir -p "$REPO/sub"
  printf '{"paths": {"%s": "proj", "%s": "proj", "%s": "gone"}}\n' "$REPO" "$REPO/sub" "$HOME/nope" > "$MAP"
  export DIRTY_MAINS_MAP="$MAP"
}

@test "a clean checkout reports nothing and exits 0" {
  run "$DIRTY"
  assert_success
  assert_output ''
}

@test "an old tracked change trips it, a fresh one does not, and cleaning clears it" {
  echo two > "$REPO/a.txt"
  run "$DIRTY"
  assert_success
  touch -d '2 hours ago' "$REPO/a.txt"
  run "$DIRTY"
  assert_failure 1
  assert_output --regexp '^~/src/proj \(main\): tracked changes older than 60m: 1 \(a\.txt\)$'
  git -C "$REPO" checkout -q -- a.txt
  run "$DIRTY"
  assert_success
}

@test "a deleted tracked file counts, since it has no age to check" {
  rm "$REPO/a.txt"
  run "$DIRTY"
  assert_failure 1
  assert_output --partial 'tracked changes older than 60m: 1 (a.txt)'
}

@test "an old untracked file trips it; ignored files and empty-after-ignore dirs do not" {
  mkdir -p "$REPO/ignored" "$REPO/cache"
  echo x > "$REPO/ignored/blob"
  echo 'cache/*.log' >> "$REPO/.git/info/exclude"
  echo x > "$REPO/cache/run.log"
  touch -d '2 hours ago' "$REPO/ignored/blob" "$REPO/cache/run.log" "$REPO/cache"
  run "$DIRTY"
  assert_success
  echo wip > "$REPO/notes.md"
  touch -d '2 hours ago' "$REPO/notes.md"
  run "$DIRTY"
  assert_failure 1
  assert_output --partial 'untracked older than 60m: 1 (notes.md)'
  rm "$REPO/notes.md"
  run "$DIRTY"
  assert_success
}

@test "an untracked directory counts as young while anything under it is" {
  mkdir -p "$REPO/draft/deep"
  echo x > "$REPO/draft/old.md"
  echo y > "$REPO/draft/deep/new.md"
  touch -d '2 hours ago' "$REPO/draft/old.md" "$REPO/draft" "$REPO/draft/deep"
  run "$DIRTY"
  assert_success
  touch -d '2 hours ago' "$REPO/draft/deep/new.md"
  run "$DIRTY"
  assert_failure 1
  assert_output --partial 'untracked older than 60m: 1 (draft)'
}

@test "a stash older than the limit trips it, a recent one does not" {
  echo two > "$REPO/a.txt"
  git -C "$REPO" stash push -q -m recent
  run "$DIRTY"
  assert_success
  echo three > "$REPO/a.txt"
  GIT_COMMITTER_DATE="$(date -d '40 days ago' '+%s +0000')" git -C "$REPO" stash push -q -m old
  run "$DIRTY"
  assert_failure 1
  assert_output --partial '1 stash(es) older than 30d'
  git -C "$REPO" stash clear
  run "$DIRTY"
  assert_success
}

@test "--quiet reports through the exit code only" {
  rm "$REPO/a.txt"
  run "$DIRTY" --quiet
  assert_failure 1
  assert_output ''
}

@test "an unreadable map exits 2, and so does an unknown argument" {
  DIRTY_MAINS_MAP="$HOME/missing.json" run "$DIRTY"
  assert_failure 2
  assert_output --partial 'cannot read the paths'
  run "$DIRTY" --bogus
  assert_failure 2
}
