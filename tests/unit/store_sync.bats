#!/usr/bin/env bats
# store-sync: every machine is a peer clone of the agent store, and each write reaches origin at
# once, or backup while origin is down. The remotes here are local bare repos (file paths, so no
# network), each "machine" is a clone under the sandbox, and every sync runs in the foreground.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  BIN="$REPO_ROOT/.local/bin/store-sync"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export STORE_SYNC_SSH_KEY=/nonexistent STORE_SYNC_FG=1
  R="$SANDBOX/remotes"
  ORIGIN="$R/origin.git" BACKUP="$R/backup.git"
  mkdir -p "$R"
  git init -q --bare -b master "$ORIGIN"
  git init -q --bare -b master "$BACKUP"
  local seed="$SANDBOX/seed"
  git init -q -b master "$seed"
  mkdir -p "$seed/queue" "$seed/bench"
  printf 'state: open\n' > "$seed/queue/item.md"
  printf '{"n":0}\n' > "$seed/queue/events.jsonl"
  : > "$seed/bench/.keep"
  printf '*.jsonl merge=union\n' > "$seed/.gitattributes"
  printf '.sync/\n' > "$seed/.gitignore"
  git -C "$seed" add -A && git -C "$seed" commit -q -m seed
  git -C "$seed" push -q "$ORIGIN" master
  git -C "$seed" push -q "$BACKUP" master
  export STORE_SYNC_CONF="$SANDBOX/store.env"
  conf "$ORIGIN"
}

# conf <origin url>: the machine-wide store.env every clone reads.
conf() { printf 'STORE_PRIMARY_URL="%s"\nSTORE_BACKUP_URL="%s"\n' "$1" "$BACKUP" > "$STORE_SYNC_CONF"; }

# peer <name>: a joined clone at $SANDBOX/<name>.
peer() {
  git clone -q "$ORIGIN" "$SANDBOX/$1"
  AGENT_STORE_DIR="$SANDBOX/$1" "$BIN" join >/dev/null
}

# on <name> <args...>: run store-sync as that machine.
on() { local m="$1"; shift; AGENT_STORE_DIR="$SANDBOX/$m" "$BIN" "$@"; }

tip() { git -C "$1" rev-parse master; }
show() { git -C "$1" show "master:$2"; }

@test "a clean clone at origin's tip joins in place and its write lands on origin and backup" {
  git clone -q "$ORIGIN" "$SANDBOX/a"
  run on a join
  assert_success
  assert_output --partial "peer clone in place"
  [ -f "$SANDBOX/a/.sync/peer" ]
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  run on a
  assert_success
  assert_output --partial "COMPLETE: origin at"
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
  assert_equal "$(tip "$BACKUP")" "$(tip "$ORIGIN")"
}

@test "a clone with commits origin lacks is replaced by a fresh clone and the old one is kept" {
  git clone -q "$ORIGIN" "$SANDBOX/a"
  echo stale > "$SANDBOX/a/queue/stale.md"
  git -C "$SANDBOX/a" add -A && git -C "$SANDBOX/a" commit -q -m stale
  run on a join
  assert_success
  assert_output --partial "fresh peer clone"
  assert_output --partial "the old store is kept at $SANDBOX/a.pre-peer-"
  [ ! -e "$SANDBOX/a/queue/stale.md" ]
  ls "$SANDBOX"/a.pre-peer-*/queue/stale.md
  [ "$(tip "$ORIGIN")" = "$(git -C "$SANDBOX/a" rev-parse HEAD)" ]
}

@test "a machine with no store joins by a fresh clone" {
  run on new join
  assert_success
  assert_output --partial "fresh peer clone"
  refute_output --partial "old store"
  [ -f "$SANDBOX/new/queue/item.md" ]
  assert_equal "$(git -C "$SANDBOX/new" remote get-url backup)" "$BACKUP"
}

@test "an unjoined clone never pushes: the timer says so and the write hook stays quiet" {
  git clone -q "$ORIGIN" "$SANDBOX/a"
  local before; before=$(tip "$ORIGIN")
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  run on a
  assert_failure
  assert_output --partial "not a peer clone yet"
  run on a --now --bg
  assert_success
  assert_output ""
  assert_equal "$(tip "$ORIGIN")" "$before"
  assert_equal "$(tip "$BACKUP")" "$before"
}

@test "two machines writing in the same minute both land, merged rather than rebased" {
  peer a; peer b
  echo a > "$SANDBOX/a/queue/a.md"
  echo b > "$SANDBOX/b/queue/b.md"
  run on a --now
  assert_success
  run on b --now
  assert_success
  assert_output --partial "COMPLETE"
  assert_equal "$(show "$ORIGIN" queue/a.md)" a
  assert_equal "$(show "$ORIGIN" queue/b.md)" b
  # b merged a's commit: a merge commit, and a's commit is unchanged on origin.
  git -C "$ORIGIN" merge-base --is-ancestor "$(git -C "$SANDBOX/a" rev-parse HEAD)" master
  assert_equal "$(git -C "$ORIGIN" rev-list --merges --count master)" 1
  assert_equal "$(tip "$BACKUP")" "$(tip "$ORIGIN")"
}

@test "two machines appending the same jsonl both keep their lines" {
  peer a; peer b
  echo '{"n":"a"}' >> "$SANDBOX/a/queue/events.jsonl"
  echo '{"n":"b"}' >> "$SANDBOX/b/queue/events.jsonl"
  on a --now
  run on b --now
  assert_success
  run show "$ORIGIN" queue/events.jsonl
  assert_line '{"n":"a"}'
  assert_line '{"n":"b"}'
}

@test "a conflict keeps every local commit, takes nothing from the remote, and says where" {
  peer a; peer b
  echo 'state: a' > "$SANDBOX/a/queue/item.md"
  echo 'state: b' > "$SANDBOX/b/queue/item.md"
  on a --now
  run on b --now
  assert_failure
  assert_output --partial "conflicts in queue/item.md"
  assert_output --partial "local commits kept"
  assert_equal "$(cat "$SANDBOX/b/queue/item.md")" "state: b"
  assert_equal "$(git -C "$SANDBOX/b" show HEAD:queue/item.md)" "state: b"
  [ -z "$(git -C "$SANDBOX/b" status --porcelain --untracked-files=no)" ]
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: a"
  # The same pair is not merged again until something changes.
  run on b
  assert_failure
  assert_output --partial "the same files as last time"
}

@test "with origin down the write lands on backup, and any peer carries it to origin later" {
  peer a; peer b
  mv "$ORIGIN" "$R/origin.down"
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  run on a --now
  assert_success
  assert_output --partial "BACKUP: origin unreachable"
  assert_equal "$(show "$BACKUP" queue/item.md)" "state: done"
  mv "$R/origin.down" "$ORIGIN"
  run on b
  assert_success
  assert_output --partial "COMPLETE"
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
}

@test "with no remote reachable the write stays committed and the next sync pushes it" {
  peer a
  mv "$ORIGIN" "$R/origin.down"; mv "$BACKUP" "$R/backup.down"
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  run on a --now
  assert_success
  assert_output --partial "SKIP: no remote reachable"
  assert_output --partial "1 commit(s) kept"
  mv "$R/origin.down" "$ORIGIN"; mv "$R/backup.down" "$BACKUP"
  run on a
  assert_success
  assert_output --partial "COMPLETE"
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
}

@test "a rejected push is retried in the next round" {
  peer a
  touch "$R/reject-once"
  printf '#!/bin/sh\n[ ! -e "%s" ] || { rm -f "%s"; echo rejected >&2; exit 1; }\n' "$R/reject-once" "$R/reject-once" > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  run on a --now
  assert_success
  assert_output --partial "COMPLETE"
  [ ! -e "$R/reject-once" ]
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
}

@test "--now pushes only the coordination paths; the timer's pass takes the rest" {
  peer a
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  echo '{"x":1}' > "$SANDBOX/a/bench/progress.jsonl"
  run on a --now
  assert_success
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
  run git -C "$ORIGIN" cat-file -e master:bench/progress.jsonl
  assert_failure
  run on a
  assert_success
  assert_equal "$(show "$ORIGIN" bench/progress.jsonl)" '{"x":1}'
}

@test "the write hook does nothing when the coordination paths are clean" {
  peer a
  echo '{"x":1}' > "$SANDBOX/a/bench/progress.jsonl"
  run on a --now --bg
  assert_success
  assert_output ""
  run grep -c COMPLETE "$SANDBOX/a/.sync/sync.log"
  assert_output 0
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  run on a --now --bg
  assert_success
  assert_output ""
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
}

@test "the clone's old remote is replaced by the conf's, so a dead house ingress costs nothing" {
  peer a
  # Negative control: an https remote that cannot resolve. Were it still used, origin would be
  # down and the write would only reach backup.
  git -C "$SANDBOX/a" remote set-url origin https://git.house.invalid/x/store.git
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  run on a --now
  assert_success
  assert_output --partial "COMPLETE"
  assert_equal "$(git -C "$SANDBOX/a" remote get-url origin)" "$ORIGIN"
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
}

@test "agent-queue and agent-ask start the write hook only for the store's own state" {
  mkdir -p "$SANDBOX/bin"
  printf '#!/bin/sh\necho "$0 $*" >> "%s"\n' "$SANDBOX/hook.log" > "$SANDBOX/bin/store-sync"
  chmod +x "$SANDBOX/bin/store-sync"
  export AGENT_STATE_LOCAL=1 AGENT_STORE_DIR="$HOME/.agent"
  mkdir -p "$HOME/.agent/queue"
  PATH="$SANDBOX/bin:$PATH" "$REPO_ROOT/.local/bin/agent-queue" list >/dev/null 2>&1 || true
  PATH="$SANDBOX/bin:$PATH" "$REPO_ROOT/.local/bin/agent-ask" list >/dev/null 2>&1 || true
  run cat "$SANDBOX/hook.log"
  assert_equal "${#lines[@]}" 2
  assert_line --index 0 --partial "store-sync --now --bg"
  : > "$SANDBOX/hook.log"
  mkdir -p "$SANDBOX/elsewhere/queue"
  AGENT_QUEUE_DIR="$SANDBOX/elsewhere/queue" PATH="$SANDBOX/bin:$PATH" "$REPO_ROOT/.local/bin/agent-queue" list >/dev/null 2>&1 || true
  AGENT_ASK_ROOT="$SANDBOX/elsewhere/asks" PATH="$SANDBOX/bin:$PATH" "$REPO_ROOT/.local/bin/agent-ask" list >/dev/null 2>&1 || true
  assert_equal "$(cat "$SANDBOX/hook.log")" ""
}

@test "the deploy key goes to ssh as one word, even from a path with a space" {
  mkdir -p "$SANDBOX/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\nexit 255\n' "$SANDBOX/ssh.args" > "$SANDBOX/bin/ssh"
  chmod +x "$SANDBOX/bin/ssh"
  peer a
  touch "$SANDBOX/id key"
  conf "ssh://git@forge.invalid:2222/x/store.git"
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  STORE_SYNC_SSH_KEY="$SANDBOX/id key" PATH="$SANDBOX/bin:$PATH" run on a --now
  assert_success
  assert_output --partial "BACKUP: origin unreachable"
  run cat "$SANDBOX/ssh.args"
  assert_line "$SANDBOX/id key"
  assert_line IdentitiesOnly=yes
}
