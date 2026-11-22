#!/usr/bin/env bats
# dirty-park: the clean-up step for what dirty-mains names. It must move old stashes and
# named dirty paths under refs/parked/ so dirty-mains reads clean, lose nothing (each entry
# restores), and leave recent stashes and unnamed paths alone.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  PARK="$REPO_ROOT/.local/bin/dirty-park"
  DIRTY="$REPO_ROOT/.local/bin/dirty-mains"
  REPO="$HOME/src/proj"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo one > "$REPO/a.txt"
  echo keep > "$REPO/b.txt"
  echo 'ignored/' > "$REPO/.gitignore"
  git -C "$REPO" add a.txt b.txt .gitignore
  git -C "$REPO" commit -qm init
  printf '{"paths": {"%s": "proj"}}\n' "$REPO" > "$HOME/map.json"
  export DIRTY_MAINS_MAP="$HOME/map.json"
}

old_stash() {
  echo "$1" > "$REPO/a.txt"
  GIT_COMMITTER_DATE="$(date -d '40 days ago' '+%s +0000')" git -C "$REPO" stash push -q -m "$1"
}

@test "old stashes are parked and dropped, a recent one stays, and each restores" {
  old_stash first
  old_stash second
  echo recent > "$REPO/a.txt"
  git -C "$REPO" stash push -q -m recent
  run "$DIRTY"
  assert_failure 1
  run "$PARK" stashes "$REPO"
  assert_success
  assert_line --regexp '^refs/parked/stash/[0-9-]+-[0-9a-f]{7}  On main: first$'
  assert_line --regexp '^refs/parked/stash/[0-9-]+-[0-9a-f]{7}  On main: second$'
  run git -C "$REPO" stash list --format=%gs
  assert_output 'On main: recent'
  run "$DIRTY"
  assert_success
  ref="$(git -C "$REPO" for-each-ref --format='%(refname) %(subject)' 'refs/parked/stash/' | awk '$NF == "first" { print $1 }')"
  git -C "$REPO" stash store -m restored "$ref"
  git -C "$REPO" checkout -q -- a.txt
  git -C "$REPO" stash apply -q stash@{0}
  run cat "$REPO/a.txt"
  assert_output first
}

@test "a stash with untracked files keeps them once parked" {
  echo wip > "$REPO/new.md"
  GIT_COMMITTER_DATE="$(date -d '40 days ago' '+%s +0000')" git -C "$REPO" stash push -q -u -m withnew
  "$PARK" stashes "$REPO"
  ref="$(git -C "$REPO" for-each-ref --format='%(refname)' 'refs/parked/stash/')"
  git -C "$REPO" stash store -m restored "$ref"
  git -C "$REPO" stash apply -q stash@{0}
  run cat "$REPO/new.md"
  assert_output wip
}

@test "paths parks a staged new file and removes it from the index" {
  echo staged > "$REPO/c.txt"
  git -C "$REPO" add c.txt
  run "$PARK" paths "$REPO" c.txt
  assert_success
  run git -C "$REPO" status --porcelain
  assert_output ''
  ref="$(git -C "$REPO" for-each-ref --format='%(refname)' 'refs/parked/tree/')"
  run git -C "$REPO" show "$ref:c.txt"
  assert_output staged
}

@test "paths reads a glob as a literal name, so it never parks what it does not restore" {
  echo changed > "$REPO/a.txt"
  run "$PARK" paths "$REPO" '*.txt'
  assert_failure 1
  run cat "$REPO/a.txt"
  assert_output changed
  assert_equal "$(git -C "$REPO" for-each-ref refs/parked/)" ''
}

@test "paths on ignored-only or missing paths is nothing to park, exit 1" {
  mkdir -p "$REPO/ignored"
  echo blob > "$REPO/ignored/blob"
  run "$PARK" paths "$REPO" ignored
  assert_failure 1
  run "$PARK" paths "$REPO" nothing-here
  assert_failure 1
}

@test "paths refuses a nested git checkout and leaves it in place" {
  git init -q "$REPO/vendor"
  echo x > "$REPO/vendor/f"
  git -C "$REPO/vendor" add f
  git -C "$REPO/vendor" -c user.email=t@example.com -c user.name=t commit -qm v
  run "$PARK" paths "$REPO" vendor
  assert_failure 2
  assert_output --partial 'nested git checkout'
  assert [ -f "$REPO/vendor/f" ]
  assert_equal "$(git -C "$REPO" for-each-ref refs/parked/)" ''
}

@test "stashes with none old enough exits 1 and changes nothing" {
  echo recent > "$REPO/a.txt"
  git -C "$REPO" stash push -q -m recent
  run "$PARK" stashes "$REPO"
  assert_failure 1
  assert_output --partial 'no stash older than 30d'
  run git -C "$REPO" stash list --format=%gs
  assert_output 'On main: recent'
}

@test "paths parks tracked changes, deletions and untracked files, then the tree is clean" {
  echo changed > "$REPO/a.txt"
  rm "$REPO/b.txt"
  mkdir -p "$REPO/draft" "$REPO/ignored"
  echo wip > "$REPO/draft/notes.md"
  echo blob > "$REPO/ignored/blob"
  touch -d '2 hours ago' "$REPO/a.txt" "$REPO/draft/notes.md" "$REPO/draft"
  run "$DIRTY"
  assert_failure 1
  run "$PARK" paths "$REPO" a.txt b.txt draft
  assert_success
  assert_output --regexp '^refs/parked/tree/[0-9-]+-[0-9a-f]{7}  a\.txt b\.txt draft$'
  run git -C "$REPO" status --porcelain
  assert_output ''
  run cat "$REPO/a.txt" "$REPO/b.txt"
  assert_output $'one\nkeep'
  assert [ -f "$REPO/ignored/blob" ]
  run "$DIRTY"
  assert_success
  ref="$(git -C "$REPO" for-each-ref --format='%(refname)' 'refs/parked/tree/')"
  run git -C "$REPO" show "$ref:a.txt"
  assert_output changed
  run git -C "$REPO" show "$ref:draft/notes.md"
  assert_output wip
  run git -C "$REPO" cat-file -e "$ref:b.txt"
  assert_failure
}

@test "paths leaves an unnamed path alone and exits 1 when the named one is clean" {
  echo changed > "$REPO/a.txt"
  run "$PARK" paths "$REPO" b.txt
  assert_failure 1
  assert_output --partial 'holds no change under b.txt'
  run cat "$REPO/a.txt"
  assert_output changed
  assert_equal "$(git -C "$REPO" for-each-ref refs/parked/)" ''
}

@test "list names each parked ref with its subject" {
  old_stash first
  "$PARK" stashes "$REPO"
  run "$PARK" list "$REPO"
  assert_success
  assert_output --regexp '^refs/parked/stash/[0-9-]+-[0-9a-f]{7}  [0-9-]{10}  On main: first$'
}

@test "a bad command, a missing repo or a bad --days exits 2" {
  run "$PARK" bogus "$REPO"
  assert_failure 2
  run "$PARK" stashes "$HOME/nope"
  assert_failure 2
  assert_output --partial 'not a git checkout'
  run "$PARK" stashes "$REPO" --days x
  assert_failure 2
  run "$PARK" paths "$REPO"
  assert_failure 2
}
