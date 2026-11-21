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
  export STORE_SYNC_SSH_KEY=/nonexistent
  R="$SANDBOX/remotes"
  ORIGIN="$R/origin.git" BACKUP="$R/backup.git"
  mkdir -p "$R"
  git init -q --bare -b master "$ORIGIN"
  git init -q --bare -b master "$BACKUP"
  local seed="$SANDBOX/seed"
  git init -q -b master "$seed"
  mkdir -p "$seed/queue" "$seed/bench" "$seed/daylog" "$seed/anchors"
  printf 'state: open\n' > "$seed/queue/item.md"
  printf '{"n":0}\n' > "$seed/queue/events.jsonl"
  : > "$seed/bench/.keep"
  printf '{\n "head": 0,\n "x": 1,\n "y": 1,\n "z": 1,\n "w": 1,\n "tail": 0\n}\n' > "$seed/daylog/d.json"
  printf '# p\n\n## Decisions\n- d1\n\n## Notes\nhand\n<!-- AUTO:START -->\ngen 0\n<!-- AUTO:END -->\n' > "$seed/anchors/p.md"
  printf '*.jsonl merge=union\ndaylog/*.json merge=derived\nanchors/*.md merge=derived\n' > "$seed/.gitattributes"
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

@test "two machines regenerating the same snapshot both sync, and the merging machine's copy wins whole" {
  peer a; peer b
  # Lines far apart would merge hunk by hunk as text; a snapshot must never mix two passes.
  sed -i 's/"head": 0/"head": "a"/' "$SANDBOX/a/daylog/d.json"
  sed -i 's/"tail": 0/"tail": "b"/' "$SANDBOX/b/daylog/d.json"
  on a
  run on b
  assert_success
  assert_output --partial "COMPLETE"
  run show "$ORIGIN" daylog/d.json
  assert_line ' "head": 0,'
  assert_line ' "tail": "b"'
  [ ! -e "$SANDBOX/b/.sync/conflict" ]
}

@test "a derived anchor keeps the other machine's hand edits, even beside the auto block both rewrote" {
  peer a; peer b
  sed -i -e 's/^- d1$/- d1\n- d2/' -e 's/^hand$/hand\nhand a/' -e 's/^gen 0$/gen a/' "$SANDBOX/a/anchors/p.md"
  sed -i 's/^gen 0$/gen b/' "$SANDBOX/b/anchors/p.md"
  on a
  run on b
  assert_success
  run show "$ORIGIN" anchors/p.md
  assert_line -- '- d2'
  assert_line 'hand a'
  assert_line 'gen b'
  refute_line 'gen a'
  refute_output --partial '<<<<<<<'
  assert_equal "$(grep -c 'AUTO:' <<<"$output")" 2
}

@test "two machines' clashing hand edits to a derived anchor still conflict" {
  peer a; peer b
  sed -i 's/^hand$/hand a/' "$SANDBOX/a/anchors/p.md"
  sed -i 's/^hand$/hand b/' "$SANDBOX/b/anchors/p.md"
  on a
  run on b
  assert_failure
  assert_output --partial "conflicts in anchors/p.md"
  assert_equal "$(git -C "$SANDBOX/b" show HEAD:anchors/p.md | grep '^hand')" "hand b"
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

@test "a conflict never starts a merge in the working tree, so a queue write mid-sync cannot strand one" {
  peer a; peer b
  echo 'state: a' > "$SANDBOX/a/queue/item.md"
  echo 'state: new' > "$SANDBOX/a/queue/new.md"
  echo 'state: b' > "$SANDBOX/b/queue/item.md"
  on a --now
  # A git whose working-tree merge is followed at once by a queue write to the file it brought in,
  # as agent-queue did on razer-laptop between store-sync's merge and its abort (ar-3439).
  local real; real=$(command -v git)
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/git" <<EOF
#!/usr/bin/env bash
"$real" "\$@"; rc=\$?
for a in "\$@"; do case "\$a" in merge) [ -f "$SANDBOX/b/queue/new.md" ] && echo 'state: written' >> "$SANDBOX/b/queue/new.md"; break ;; merge-tree|merge-base|--abort) break ;; esac; done
exit \$rc
EOF
  chmod +x "$SANDBOX/bin/git"
  PATH="$SANDBOX/bin:$PATH" run on b --now
  assert_failure
  assert_output --partial "conflicts in queue/item.md"
  run git -C "$SANDBOX/b" rev-parse -q --verify MERGE_HEAD
  assert_failure
  [ ! -e "$SANDBOX/b/queue/new.md" ]
  # Once origin moves on, the next sync tries again instead of reading a stranded merge as hand work.
  echo 'state: b2' > "$SANDBOX/b/queue/item.md"
  git -C "$SANDBOX/b" commit -q -am b2
  echo 'state: b2' > "$SANDBOX/a/queue/item.md"
  on a --now
  PATH="$SANDBOX/bin:$PATH" run on b
  assert_success
  assert_output --partial "COMPLETE: origin at"
}

@test "an origin with unrelated history stops the sync like a conflict, never a silent retry" {
  peer b
  local other="$SANDBOX/other"
  git init -q -b master "$other"
  echo x > "$other/x.md"
  git -C "$other" add -A && git -C "$other" commit -q -m other
  git init -q --bare -b master "$R/other.git"
  git -C "$other" push -q "$R/other.git" master
  conf "$R/other.git"
  echo 'state: b' > "$SANDBOX/b/queue/item.md"
  run on b
  assert_failure
  assert_output --partial "merging origin conflicts in (git merge-tree exit"
  [ -f "$SANDBOX/b/.sync/conflict" ]
}

@test "a merge being resolved by hand is left alone: no sync stages its conflicted files" {
  peer a; peer b
  echo 'state: a' > "$SANDBOX/a/queue/item.md"
  echo 'state: b' > "$SANDBOX/b/queue/item.md"
  on a --now
  run on b --now
  assert_failure
  run git -C "$SANDBOX/b" merge origin/master
  assert_failure
  echo 'state: new' > "$SANDBOX/b/queue/other.md"
  run on b --now
  assert_failure
  assert_output --partial "a merge is in progress"
  assert_equal "$(git -C "$SANDBOX/b" diff --name-only --diff-filter=U)" "queue/item.md"
  git -C "$SANDBOX/b" rev-parse -q --verify MERGE_HEAD
  grep -q '^<<<<<<<' "$SANDBOX/b/queue/item.md"
  echo 'state: ab' > "$SANDBOX/b/queue/item.md"
  git -C "$SANDBOX/b" add queue/item.md && git -C "$SANDBOX/b" commit -q --no-edit
  run on b
  assert_success
  assert_output --partial "COMPLETE: origin at"
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: ab"
  assert_equal "$(show "$ORIGIN" queue/other.md)" "state: new"
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
  export AGENT_STORE_DIR="$HOME/.agent"
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
  # Run under the hook's own sync (AGENT_STORE_HOOK), neither starts another one (ar-4050).
  AGENT_STORE_HOOK=1 PATH="$SANDBOX/bin:$PATH" "$REPO_ROOT/.local/bin/agent-queue" list >/dev/null 2>&1 || true
  AGENT_STORE_HOOK=1 PATH="$SANDBOX/bin:$PATH" "$REPO_ROOT/.local/bin/agent-ask" list >/dev/null 2>&1 || true
  assert_equal "$(cat "$SANDBOX/hook.log")" ""
}

@test "the background sync drops its caller's descriptors, so it holds no caller's lock" {
  # The fork waits up to LOCK_WAIT_S on the sync lock: an inherited agent-queue fd 8 held every queue
  # write behind it (2026-11-18, agent-land's record refused while a long sync ran).
  peer a
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  mkdir -p "$SANDBOX/a/.sync"
  exec 7>"$SANDBOX/a/.sync/lock"
  flock 7
  ( flock 8 && STORE_SYNC_FG=0 on a --now --bg ) 8>"$SANDBOX/caller.lock"
  run flock -n "$SANDBOX/caller.lock" true
  # Leave the fork nothing to push, so it exits once it has the lock.
  git -C "$SANDBOX/a" checkout -q -- queue/item.md
  exec 7>&-
  assert_success
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

@test "an origin that refuses every push still leaves the write on backup, and says so" {
  peer a
  printf '#!/bin/sh\necho "read-only key" >&2\nexit 1\n' > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  run on a --now
  assert_failure
  assert_output --partial "ERROR: origin did not take"
  assert_output --partial "backup at"
  assert_equal "$(show "$BACKUP" queue/item.md)" "state: done"
}

@test "a conflict with backup skips backup but still lands the write on origin" {
  peer a; peer b
  mv "$ORIGIN" "$R/origin.down"
  echo 'state: a' > "$SANDBOX/a/queue/item.md"
  on a --now
  mv "$R/origin.down" "$ORIGIN"
  echo 'state: b' > "$SANDBOX/b/queue/item.md"
  run on b --now
  assert_failure
  assert_output --partial "COMPLETE: origin at"
  assert_output --partial "merging backup conflicts in queue/item.md"
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: b"
  assert_equal "$(show "$BACKUP" queue/item.md)" "state: a"
}

@test "a machine with no store joins from backup while origin is unreachable, then pushes to origin" {
  mv "$ORIGIN" "$R/origin.down"
  run on new join
  assert_success
  assert_output --partial "cloned backup"
  assert_equal "$(git -C "$SANDBOX/new" remote get-url origin)" "$ORIGIN"
  mv "$R/origin.down" "$ORIGIN"
  echo 'state: done' > "$SANDBOX/new/queue/item.md"
  run on new --now
  assert_success
  assert_output --partial "COMPLETE"
}

# notes_clone <name>: a ~/.notes clone with both remotes, as notes-sync-bootstrap.sh leaves it.
notes_clone() {
  git clone -q "$ORIGIN" "$SANDBOX/$1"
  git -C "$SANDBOX/$1" remote add backup "$BACKUP"
}

# notes_on <name> <args...>: run the notes store's sync as that machine, with its own state dir.
notes_on() { local m="$1"; shift; HOME="$SANDBOX/home-$m" NOTES_DIR="$SANDBOX/$m" "$BIN" --store notes "$@"; }

pages() { grep -c '^agent-notify' "$NOTES_FIXTURE/calls.log" 2>/dev/null || true; }

@test "the notes store syncs with no join and logs where notes doctor reads it" {
  notes_clone n
  echo 'a note' > "$SANDBOX/n/today.md"
  run notes_on n
  assert_success
  assert_output --partial "COMPLETE: origin at"
  assert_equal "$(show "$ORIGIN" today.md)" "a note"
  assert_equal "$(tip "$BACKUP")" "$(tip "$ORIGIN")"
  grep -q COMPLETE "$SANDBOX/home-n/.local/state/notes-sync/sync.log"
  [ ! -e "$SANDBOX/n/.sync" ]
  run notes_on n join
  assert_failure
  assert_output --partial "has no join"
}

@test "a notes conflict keeps the local commit and pages once, not on every retry" {
  notes_clone a; notes_clone b
  echo 'from a' > "$SANDBOX/a/today.md"
  echo 'from b' > "$SANDBOX/b/today.md"
  notes_on a >/dev/null
  run notes_on b
  assert_failure
  assert_output --partial "conflicts in today.md"
  assert_equal "$(git -C "$SANDBOX/b" show HEAD:today.md)" "from b"
  assert_equal "$(show "$ORIGIN" today.md)" "from a"
  assert_equal "$(pages)" 1
  run notes_on b
  assert_failure
  assert_equal "$(pages)" 1
}

@test "a dead backup pages once after an hour, not while offline, and once on recovery" {
  notes_clone n
  local fails="$SANDBOX/home-n/.local/state/notes-sync/backup-failures"
  printf '#!/bin/sh\nexit 1\n' > "$BACKUP/hooks/pre-receive"
  chmod +x "$BACKUP/hooks/pre-receive"
  echo 1 > "$SANDBOX/n/today.md"; notes_on n >/dev/null
  [ -s "$fails" ]
  # Just inside the hour: no page however many syncs run.
  echo "$(( $(date +%s) - 3500 ))" > "$fails"
  echo 2 > "$SANDBOX/n/today.md"; notes_on n >/dev/null
  echo 3 > "$SANDBOX/n/today.md"; notes_on n >/dev/null
  assert_equal "$(pages)" 0
  # Negative control: offline, origin and backup both unreachable, so the streak is not judged.
  echo "$(( $(date +%s) - 3700 ))" > "$fails"
  mv "$ORIGIN" "$R/origin.down"; mv "$BACKUP" "$R/backup.down"
  notes_on n >/dev/null
  mv "$R/origin.down" "$ORIGIN"; mv "$R/backup.down" "$BACKUP"
  assert_equal "$(pages)" 0
  notes_on n >/dev/null
  echo 4 > "$SANDBOX/n/today.md"; notes_on n >/dev/null
  assert_equal "$(pages)" 1
  grep -q 'agent-notify.*-p high.*has not taken a write.*for 6[0-9] minutes' "$NOTES_FIXTURE/calls.log"
  rm "$BACKUP/hooks/pre-receive"
  run notes_on n
  assert_output --partial "backup at"
  assert_equal "$(pages)" 2
  grep -q 'agent-notify.*-p normal.*took HEAD again' "$NOTES_FIXTURE/calls.log"
  [ ! -e "$fails" ]
}

@test "a backup conflict pages once while origin keeps syncing" {
  notes_clone a; notes_clone b
  mv "$ORIGIN" "$R/origin.down"
  echo 'from a' > "$SANDBOX/a/today.md"
  notes_on a >/dev/null
  mv "$R/origin.down" "$ORIGIN"
  echo 'from b' > "$SANDBOX/b/today.md"
  run notes_on b
  assert_failure
  assert_output --partial "COMPLETE: origin at"
  assert_output --partial "merging backup conflicts in today.md"
  echo 'more from b' > "$SANDBOX/b/other.md"
  run notes_on b
  assert_output --partial "COMPLETE: origin at"
  assert_equal "$(show "$ORIGIN" other.md)" "more from b"
  assert_equal "$(pages)" 1
  grep -q 'agent-notify.*stopped syncing with backup' "$NOTES_FIXTURE/calls.log"
}

@test "a clone on another branch syncs nothing" {
  notes_clone n
  git -C "$SANDBOX/n" checkout -q -b side
  echo 'on side' > "$SANDBOX/n/today.md"
  run notes_on n
  assert_failure
  assert_output --partial "is on side, not master; nothing synced"
  run git -C "$ORIGIN" show master:today.md
  assert_failure
}

@test "an index.lock a killed git left over 10 minutes ago is removed, and the write lands" {
  command -v fuser >/dev/null || skip "no fuser"
  peer a
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  : > "$SANDBOX/a/.git/index.lock"
  touch -d '20 minutes ago' "$SANDBOX/a/.git/index.lock"
  run on a
  assert_success
  assert_output --partial "WARN: removed $SANDBOX/a/.git/index.lock"
  assert_output --partial "COMPLETE: origin at"
  [ ! -e "$SANDBOX/a/.git/index.lock" ]
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
}

@test "a held or young index.lock stays, and the commit it blocks fails the unit with 3" {
  peer a
  local lk="$SANDBOX/a/.git/index.lock" fd
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  # Negative control: an old lock a live process holds open is that process's, never removed.
  exec {fd}>"$lk"
  touch -d '20 minutes ago' "$lk"
  run on a
  exec {fd}>&-
  assert_failure 3
  assert_output --partial "ERROR: could not commit ."
  refute_output --partial "removed"
  [ -e "$lk" ]
  # A young lock is a git still at work.
  touch "$lk"
  run on a
  assert_failure 3
  refute_output --partial "removed"
  [ -e "$lk" ]
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: open"
}

@test "rotating the log keeps the newest COMPLETE line, so a flood of errors still reads stale" {
  peer a
  local log="$SANDBOX/a/.sync/sync.log" pad
  pad=$(printf '%01000d' 0)
  { echo "[2026-01-01 00:00:00] [h] COMPLETE: origin at abc1234 (backup at abc1234)"
    for _ in $(seq 1100); do echo "[2026-01-01 00:00:01] [h] ERROR: could not commit . $pad"; done; } > "$log"
  : > "$SANDBOX/a/.git/index.lock"
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  run on a
  assert_failure 3
  assert_equal "$(grep -c '\] COMPLETE:' "$log")" 1
  assert_equal "$(wc -l < "$log")" 1001
  run env AGENT_SYNC_LOG="$log" "$REPO_ROOT/.local/bin/store-sync-age"
  assert_failure
  assert_output --partial "store sync stale"
}

# close_item <machine> <status> -- the machine closes queue item x: queue/done/<day>/x.md, as agent-queue
# writes it, with a merged: line for an ok close that had a PR.
close_item() {
  local d="$SANDBOX/$1/queue/done/2026-11-20"
  mkdir -p "$d"
  { printf 'slug: x\nstatus: %s\n' "$2"
    [ "$2" != ok ] || printf 'merged: abc123\n'
    printf 'note: closed on %s\n---\ntask\n' "$1"; } > "$d/x.md"
}

@test "an item closed ok with a merge on one machine and failed on another keeps the ok close, whichever syncs first (ar-4091)" {
  peer a; peer b
  close_item a ok
  close_item b failed
  on a --now
  run on b --now
  assert_success
  run show "$ORIGIN" queue/done/2026-11-20/x.md
  assert_line 'status: ok'
  assert_line 'merged: abc123'
  refute_line 'status: failed'
  refute_output --partial '<<<<<<<'
  # the other order: the failed close pushed first, the ok close merges over it
  peer c; peer d
  rm -rf "$SANDBOX/c/queue/done" "$SANDBOX/d/queue/done"
  mkdir -p "$SANDBOX/c/queue/done/2026-11-22" "$SANDBOX/d/queue/done/2026-11-22"
  printf 'slug: y\nstatus: failed\nnote: c\n---\n' > "$SANDBOX/c/queue/done/2026-11-22/y.md"
  printf 'slug: y\nstatus: ok\nnote: d\n---\n' > "$SANDBOX/d/queue/done/2026-11-22/y.md"
  on c --now
  run on d --now
  assert_success
  run show "$ORIGIN" queue/done/2026-11-22/y.md
  assert_line 'status: ok'
}

@test "two closes that are both failed, or both ok, on one item still conflict" {
  peer a; peer b
  close_item a failed
  close_item b failed
  on a --now
  run on b --now
  assert_failure
  assert_output --partial "conflicts in queue/done/2026-11-20/x.md"
}

@test "a close cancelled on one machine and failed by a stale reaper on another keeps the cancel (ar-3439)" {
  peer a; peer b
  close_item a cancelled
  close_item b failed
  on a --now
  run on b --now
  assert_success
  run show "$ORIGIN" queue/done/2026-11-20/x.md
  assert_line 'status: cancelled'
  refute_line 'status: failed'
}

# lose_head_tree <machine>: what a crash did to the fleet home (ar-3439): HEAD stays, its loose tree is gone.
lose_head_tree() {
  local t
  t=$(git -C "$SANDBOX/$1" rev-parse 'HEAD^{tree}')
  rm "$SANDBOX/$1/.git/objects/${t:0:2}/${t:2}"
  run git -C "$SANDBOX/$1" ls-tree HEAD
  assert_failure
}

@test "a HEAD whose tree an unclean shutdown lost is refetched from the remote that took it, and the write lands (ar-3439)" {
  peer a
  echo 'state: running' > "$SANDBOX/a/queue/item.md"
  on a >/dev/null
  lose_head_tree a
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  run on a
  assert_success
  assert_output --partial "WARN: HEAD"
  assert_output --partial "refetched them from origin"
  assert_output --partial "COMPLETE: origin at"
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
}

@test "a lost HEAD tree no remote holds stops the sync with 3 and names it, never a bare commit error (ar-3439)" {
  peer a
  echo 'state: running' > "$SANDBOX/a/queue/item.md"
  git -C "$SANDBOX/a" commit -q -am local
  lose_head_tree a
  # Offline first: no remote answered, so it says so and leaves the refetch to the next sync.
  conf "$SANDBOX/nowhere.git"; mv "$BACKUP" "$BACKUP.off"
  run on a
  assert_failure 3
  assert_output --partial "no remote answered to refetch them"
  conf "$ORIGIN"; mv "$BACKUP.off" "$BACKUP"
  run on a
  assert_failure 3
  assert_output --partial "names trees missing here and no remote has them"
  refute_output --partial "could not commit"
  # The refetch that reached a remote is not repeated for this HEAD: an unreachable origin now
  # changes nothing, since no fetch runs.
  conf "$SANDBOX/nowhere.git"
  run on a
  assert_failure 3
  assert_output --partial "no remote has them"
  refute_output --partial "no remote answered"
}

@test "a store with no commit yet makes its first one, with no refetch (ar-3439)" {
  git init -q -b master "$SANDBOX/a"
  git -C "$SANDBOX/a" remote add origin "$ORIGIN"
  mkdir -p "$SANDBOX/a/.sync"; : > "$SANDBOX/a/.sync/peer"
  printf '.sync/\n' > "$SANDBOX/a/.gitignore"
  echo 'state: new' > "$SANDBOX/a/new.md"
  run on a
  refute_output --partial "trees missing"
  git -C "$SANDBOX/a" cat-file -e 'HEAD:new.md'
}
