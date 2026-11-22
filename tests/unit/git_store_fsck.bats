#!/usr/bin/env bats
# git-store-fsck: after an unclean boot, every git store and main checkout is checked for a
# zero-byte object (the 2026-11-20 ~/.notes break) and by git fsck --connectivity-only. The stores
# are fixture repos named by AGENT_STORE_DIR, NOTES_DIR and a fixture project-map.json; the boot
# record is a fixture boot-cause jsonl.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  BIN="$REPO/.local/bin/git-store-fsck"
  T="$BATS_TEST_TMPDIR"
  mkrepo "$T/agent"
  mkrepo "$T/notes"
  mkrepo "$T/proj"
  printf '{"paths": {"%s": "proj", "%s": "notes", "%s": "gone"}}\n' "$T/proj" "$T/notes" "$T/not-on-this-machine" > "$T/map.json"
  export AGENT_STORE_DIR="$T/agent" NOTES_DIR="$T/notes" PROJECT_MAP_FILE="$T/map.json"
  export BOOT_CAUSE_DIR="$T/boots" BOOT_CAUSE_HOST=fixture BOOT_CAUSE_BOOT_ID=boot-now
  mkdir -p "$BOOT_CAUSE_DIR"
}

mkrepo() {
  git init -q "$1"
  mkdir -p "$1/s"
  echo a > "$1/a"
  echo b > "$1/s/b"
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm c
}

# zero <repo> <rev>: truncate that object's loose file, as an unclean shutdown does.
zero() {
  local o f
  o="$(git -C "$1" rev-parse "$2")"
  f="$1/.git/objects/${o:0:2}/${o:2}"
  chmod u+w "$f"
  : > "$f"
}

# boot <shutdown> [boot id]: the boot-cause record for this boot.
boot() {
  printf '{"host":"fixture","boot_id":"%s","previous":{"shutdown":"%s"},"cause":"x","confidence":"x","evidence":[],"gaps":[]}\n' \
    "${2:-boot-now}" "$1" >> "$BOOT_CAUSE_DIR/fixture.jsonl"
}

@test "intact stores pass, a project-map path not on this machine is skipped (negative control)" {
  run "$BIN"
  assert_success
  assert_output "git-store-fsck: 3 git stores intact"
}

@test "a zero-byte blob fails, though git fsck --connectivity-only alone passes it" {
  zero "$T/notes" HEAD:a
  run git -C "$T/notes" fsck --connectivity-only
  assert_success
  run "$BIN"
  assert_failure 1
  assert_line --index 0 --regexp "^$T/notes: zero-byte object file: "
  assert_line --index 1 --partial "1 of 3 git stores damaged"
}

@test "a zero-byte commit fails and names the repo" {
  zero "$T/agent" HEAD
  run "$BIN"
  assert_failure 1
  assert_output --partial "$T/agent: "
}

@test "a missing tree fails the connectivity check" {
  local o
  o="$(git -C "$T/proj" rev-parse HEAD:s)"
  rm -f "$T/proj/.git/objects/${o:0:2}/${o:2}"
  run "$BIN" "$T/proj"
  assert_failure 1
  assert_output --partial "$T/proj: git fsck --connectivity-only exit"
}

@test "an empty .promisor file is a partial clone's marker, not damage" {
  mkdir -p "$T/proj/.git/objects/pack"
  : > "$T/proj/.git/objects/pack/pack-0000.promisor"
  run "$BIN" "$T/proj"
  assert_success
}

@test "a zero-byte HEAD cannot be opened and fails, never skipped" {
  : > "$T/proj/.git/HEAD"
  run "$BIN"
  assert_failure 1
  assert_output --partial "$T/proj: git cannot open it"
}

@test "boot: after a clean shutdown nothing is checked, even a damaged store" {
  zero "$T/notes" HEAD:a
  boot clean
  run "$BIN" boot
  assert_success
  assert_output --partial "shut down cleanly"
}

@test "boot: after an unclean shutdown every store is checked and a damaged one fails the unit" {
  zero "$T/notes" HEAD:a
  boot unclean
  run "$BIN" boot
  assert_failure 1
  assert_output --partial "$T/notes: zero-byte object file"
}

@test "boot: a record from another boot is no record, so the stores are checked" {
  zero "$T/notes" HEAD:a
  boot clean boot-before
  run "$BIN" boot
  assert_failure 1
}

@test "the unit runs boot after boot-cause-record and is wanted by default.target" {
  U="$REPO/.config/systemd/user"
  grep -qx 'ExecStart=%h/.local/bin/git-store-fsck boot' "$U/git-store-fsck.service"
  grep -qx 'After=boot-cause-record.service' "$U/git-store-fsck.service"
  [ -L "$U/default.target.wants/git-store-fsck.service" ]
}
