#!/usr/bin/env bats
# block-root-search.sh: PreToolUse deny for a recursive search whose root holds a network
# mount. The mounts table is a fixture, so the NAS being up or down changes nothing here.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  GUARD="$BATS_TEST_DIRNAME/../../.claude/hooks/block-root-search.sh"
  export ROOT_SEARCH_MOUNTS="$BATS_TEST_TMPDIR/mounts"
  cat > "$ROOT_SEARCH_MOUNTS" <<'EOF'
/dev/nvme2n1p2 / btrfs rw 0 0
systemd-1 /mnt/nas/private autofs rw 0 0
//nas.example/private /mnt/nas/private cifs rw 0 0
gvfsd-fuse /run/user/1000/gvfs fuse.gvfsd-fuse rw 0 0
EOF
}

grep_at() { jq -nc --arg p "$1" '{tool_name:"Grep", cwd:"/home/u/wt", tool_input:{pattern:"x", path:$p}}' | bash "$GUARD"; }
glob_at() { jq -nc --arg g "$1" '{tool_name:"Glob", cwd:"/home/u/wt", tool_input:{pattern:$g}}' | bash "$GUARD"; }
bash_cmd() { jq -nc --arg c "$1" '{tool_name:"Bash", cwd:"/home/u/wt", tool_input:{command:$c}}' | bash "$GUARD"; }

@test "Grep from / and from every ancestor of the share is denied" {
  for p in / /mnt /mnt/ /mnt/nas /mnt/nas/private; do
    run grep_at "$p"
    assert_output --partial '"deny"'
    assert_output --partial '/mnt/nas/private'
  done
}

@test "Grep inside the share, in a worktree, or with no path is allowed" {
  for p in /mnt/nas/private/photos/2024 /home/u/wt /home/u ""; do
    run grep_at "$p"
    assert_success
    assert_output ""
  done
}

@test "a relative path that climbs to / is denied" {
  run grep_at ../../..
  assert_output --partial '"deny"'
}

@test "Glob with an absolute wildcard from / is denied, a scoped one is not" {
  run glob_at '/**/CutscenePlayer.cs'
  assert_output --partial '"deny"'
  run glob_at '/mnt/nas/private/photos/**/*.jpg'
  assert_output ""
  run glob_at '**/*.cs'
  assert_output ""
}

@test "the 2026-10-29 shell forms are denied" {
  run bash_cmd 'bfs -S dfs / -name CutscenePlayer.cs'
  assert_output --partial '"deny"'
  run bash_cmd 'cd x && find / -name FallLine.cs -not -path "*/Library/*" 2>/dev/null | head'
  assert_output --partial '"deny"'
  run bash_cmd 'grep -rln "class BallCarrier" /'
  assert_output --partial '"deny"'
  run bash_cmd 'rg BallCarrier /mnt'
  assert_output --partial '"deny"'
}

@test "staying on the local filesystem, non-recursive grep, and scoped roots are allowed" {
  for c in 'find / -xdev -name a' 'rg --one-file-system foo /' 'grep foo /etc/hosts' \
           'rg foo /home/u/wt' 'find . -path /mnt -prune' 'ls /' 'echo / | wc'; do
    run bash_cmd "$c"
    assert_success
    assert_output ""
  done
}

@test "no network mounts means nothing is denied" {
  echo '/dev/sda1 / ext4 rw 0 0' > "$ROOT_SEARCH_MOUNTS"
  run grep_at /
  assert_output ""
}

@test "malformed payload is ignored" {
  run bash -c "echo garbage | bash '$GUARD'"
  assert_success
  assert_output ""
}
