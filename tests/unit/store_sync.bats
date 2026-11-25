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

@test "in a service's cgroup the background sync gets its own scope, elsewhere a plain setsid (ar-4685)" {
  # In the runner's cgroup, a fork started after systemd's stop sweep (the EXIT hook of an agent-queue
  # the sweep TERMed) sat in flock -w unsignalled until the stop timeout SIGKILLed it and failed the
  # unit. The stubs log the detach and start nothing, so no sync runs behind the test.
  local det="$SANDBOX/detach.log" cg="$SANDBOX/cgroup"
  mkdir -p "$SANDBOX/bin"
  printf '#!/bin/sh\necho "systemd-run $*" >> "%s"\nexit "${STUB_RC:-0}"\n' "$det" > "$SANDBOX/bin/systemd-run"
  printf '#!/bin/sh\necho "setsid $*" >> "%s"\n' "$det" > "$SANDBOX/bin/setsid"
  chmod +x "$SANDBOX/bin/systemd-run" "$SANDBOX/bin/setsid"
  peer a
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  fork_sync() { STORE_SYNC_CGROUP="$cg" STORE_SYNC_FG=0 PATH="$SANDBOX/bin:$PATH" on a --now --bg; }

  echo '0::/user.slice/user-1000.slice/user@1000.service/app.slice/agentctl@comms.service' > "$cg"
  run fork_sync
  assert_success
  run cat "$det"
  assert_equal "${#lines[@]}" 1
  assert_line --index 0 --regexp "^systemd-run --user --scope --quiet setsid -f .*store-sync --store [a-z]+ --now$"

  # A session a unit's tmux spawned carries INVOCATION_ID but lives in its own scope.
  : > "$det"
  echo '0::/user.slice/user-1000.slice/user@1000.service/app.slice/tmux-spawn-1.scope' > "$cg"
  INVOCATION_ID=abc run fork_sync
  run cat "$det"
  assert_equal "${#lines[@]}" 1
  assert_line --index 0 --regexp "^setsid -f .*store-sync --store [a-z]+ --now$"

  # No user bus: the sync still forks, and the log says it runs in the service's cgroup.
  : > "$det"
  echo '0::/system.slice/some.service' > "$cg"
  STUB_RC=1 run fork_sync
  run cat "$det"
  assert_equal "${#lines[@]}" 2
  assert_line --index 0 --regexp "^systemd-run "
  assert_line --index 1 --regexp "^setsid -f .*store-sync --store [a-z]+ --now$"
  run grep -c "WARN: systemd-run gave the background sync no scope; it runs in /system.slice/some.service" "$SANDBOX/a/.sync/sync.log"
  assert_output 1
}

@test "a store-sync that writes the queue or the asks runs once per write, never starting itself again (ar-4241)" {
  # The loop a bats fixture's stub made (ar-4050, ar-4241): a sync that calls agent-queue started the
  # hook again, and ~300 to ~2,000 processes outlived their run. The stub calls its writer back on
  # every run; the cap of 5 turns a regression into a count of 5, not a hang.
  export AGENT_STORE_DIR="$HOME/.agent"
  mkdir -p "$HOME/.agent/queue" "$SANDBOX/bin"
  cat > "$SANDBOX/bin/store-sync" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SANDBOX/hook.log"
[ "\$(wc -l < "$SANDBOX/hook.log")" -ge 5 ] || "\$WRITER" list >/dev/null 2>&1
EOF
  chmod +x "$SANDBOX/bin/store-sync"
  for w in agent-queue agent-ask; do
    : > "$SANDBOX/hook.log"
    WRITER="$REPO_ROOT/.local/bin/$w" PATH="$SANDBOX/bin:$PATH" "$REPO_ROOT/.local/bin/$w" list >/dev/null 2>&1 || true
    run cat "$SANDBOX/hook.log"
    assert_equal "$w ${#lines[@]}" "$w 1"
    assert_line --index 0 "--now --bg"
  done
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

@test "ref locks a crash left mid-commit or mid-fetch are removed, and the write lands (ar-2940)" {
  command -v fuser >/dev/null || skip "no fuser"
  peer a
  local lk locks=("$SANDBOX/a/.git/HEAD.lock" "$SANDBOX/a/.git/refs/heads/master.lock"
    "$SANDBOX/a/.git/refs/remotes/origin/master.lock")
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  for lk in "${locks[@]}"; do
    git -C "$SANDBOX/a" rev-parse HEAD > "$lk"
    touch -d '20 minutes ago' "$lk"
  done
  run on a
  assert_success
  for lk in "${locks[@]}"; do
    assert_output --partial "WARN: removed $lk"
    [ ! -e "$lk" ]
  done
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
}

@test "a young branch ref lock stays, as a git may still be renaming it (ar-2940)" {
  peer a
  local lk="$SANDBOX/a/.git/refs/heads/master.lock"
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  git -C "$SANDBOX/a" rev-parse HEAD > "$lk"
  run on a
  assert_failure 3
  refute_output --partial "removed"
  [ -e "$lk" ]
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: open"
}

# add_shim <fails>: a git on PATH whose first <fails> `add` calls die as a file vanishing mid-walk does.
add_shim() {
  local real; real=$(command -v git)
  mkdir -p "$SANDBOX/shim"
  cat > "$SANDBOX/shim/git" <<SH
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = add ]; then
    n=\$(cat "$SANDBOX/adds" 2>/dev/null || echo 0)
    echo \$((n + 1)) > "$SANDBOX/adds"
    if [ "\$n" -lt "$1" ]; then echo "fatal: unable to stat 'queue/gone.md': No such file or directory" >&2; exit 128; fi
    break
  fi
done
exec "$real" "\$@"
SH
  chmod +x "$SANDBOX/shim/git"
}

@test "a file that vanishes while git add walks the tree costs a retry, never the unit (ar-4583)" {
  peer a
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  add_shim 2
  PATH="$SANDBOX/shim:$PATH" run on a
  assert_success
  assert_equal "$(cat "$SANDBOX/adds")" 3
  assert_equal "$(show "$ORIGIN" queue/item.md)" "state: done"
}

@test "a git add that keeps failing still fails the unit with 3 (ar-4583)" {
  peer a
  echo 'state: done' > "$SANDBOX/a/queue/item.md"
  add_shim 99
  PATH="$SANDBOX/shim:$PATH" run on a
  assert_failure 3
  assert_output --partial "ERROR: could not commit ."
  assert_equal "$(cat "$SANDBOX/adds")" 3
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

@test "two closes that are both failed, or both ok, on one item keep this side's and the other as a lost file (ar-4471)" {
  peer a; peer b
  close_item a failed
  close_item b failed
  on a --now
  run on b --now
  assert_success
  assert_output --partial COMPLETE
  run show "$ORIGIN" queue/done/2026-11-20/x.md
  assert_line 'note: closed on b'
  refute_output --partial '<<<<<<<'
  run cat "$SANDBOX/b/.sync/lost/"queue__done__2026-11-20__x.md.lost-*
  assert_line 'note: closed on a'
  run grep -c 'merge-item: queue/done/2026-11-20/x.md differs on both sides' "$SANDBOX/b/.sync/sync.log"
  assert_output 1
  # store-sync-age reads the lost file as red, and green once it is settled and deleted
  run "$REPO_ROOT/.local/bin/store-sync-age" "$SANDBOX/b/.sync/sync.log"
  assert_failure 1
  assert_output --regexp '^store sync lost a side: 1 item copy'
  rm "$SANDBOX/b/.sync/lost/"*
  run "$REPO_ROOT/.local/bin/store-sync-age" "$SANDBOX/b/.sync/sync.log"
  assert_success
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

# queue_item <machine>: a queued item $ITEM (x) long enough that git pairs each move of it as a
# rename, on origin.
queue_item() {
  local q="$SANDBOX/$1/queue/queued" i
  mkdir -p "$q"
  { printf -- '---\nslug: %s\n' "${ITEM:-x}"; for i in $(seq 1 20); do printf 'k%s: v%s\n' "$i" "$i"; done; printf -- '---\ntask\n'; } > "$q/${ITEM:-x}.md"
  on "$1" --now >/dev/null
}

# move_item <machine> <dir under queue/> <line>: what agent-queue move does to $ITEM, plus one frontmatter line.
move_item() {
  mkdir -p "$SANDBOX/$1/queue/$2"
  sed "s/^k20: v20$/k20: v20\n$3/" "$SANDBOX/$1/queue/queued/${ITEM:-x}.md" > "$SANDBOX/$1/queue/$2/${ITEM:-x}.md"
  rm "$SANDBOX/$1/queue/queued/${ITEM:-x}.md"
}

@test "an item a worker closed while another machine moved it to running keeps the close, whichever syncs first (ar-3439)" {
  peer a; queue_item a; peer b
  move_item a done/2026-11-21 'status: ok'
  move_item b running 'host: a'
  on b --now
  run on a --now
  assert_success
  assert_output --partial COMPLETE
  run show "$ORIGIN" queue/done/2026-11-21/x.md
  assert_line 'status: ok'
  refute_output --partial '<<<<<<<'
  run git -C "$ORIGIN" ls-tree -r --name-only master -- queue/queued queue/running
  assert_output ''
  assert_equal "$(git -C "$ORIGIN" log -1 --format=%s master)" "$(git -C "$SANDBOX/a" log -1 --format=%s)"
  assert_equal "$(git -C "$ORIGIN" rev-list --parents -1 master | wc -w)" 3
  [ -z "$(git -C "$SANDBOX/a" status --porcelain)" ]
  # the other order: the close pushed first, the running move merges over it
  ITEM=y
  peer c; queue_item c; peer d
  move_item c done/2026-11-21 'status: ok'
  move_item d running 'host: c'
  on c --now
  run on d --now
  assert_success
  run git -C "$ORIGIN" ls-tree -r --name-only master -- queue/queued queue/running
  assert_output ''
  run show "$ORIGIN" queue/done/2026-11-21/y.md
  assert_line 'status: ok'
  assert_equal "$(cat "$SANDBOX/d/queue/done/2026-11-21/y.md")" "$(show "$ORIGIN" queue/done/2026-11-21/y.md)"
  [ ! -e "$SANDBOX/d/queue/running/y.md" ]
}

@test "a short item closed on one machine and moved open on another keeps only the close, though git saw no rename (ar-4262)" {
  peer a
  mkdir -p "$SANDBOX/a/queue/queued"
  printf -- '---\nslug: s\n---\nt\n' > "$SANDBOX/a/queue/queued/s.md"
  on a --now >/dev/null
  peer b
  # Each side rewrites most of the short file as it moves it, so neither move reads as a rename.
  mkdir -p "$SANDBOX/a/queue/done/2026-11-21" "$SANDBOX/b/queue/running"
  printf -- '---\nslug: s\nstatus: ok\nfinished: 2026-11-21T01:00:00Z\nhost: a\nsession: s1\n---\nt\n' > "$SANDBOX/a/queue/done/2026-11-21/s.md"
  printf -- '---\nslug: s\nstarted: 2026-11-21T00:59:00Z\nhost: a\nsession: s1\nwindow: w\n---\nt\n' > "$SANDBOX/b/queue/running/s.md"
  rm "$SANDBOX/a/queue/queued/s.md" "$SANDBOX/b/queue/queued/s.md"
  on b --now >/dev/null
  run on a --now
  assert_success
  run git -C "$ORIGIN" ls-tree -r --name-only master -- queue
  assert_output 'queue/done/2026-11-21/s.md'
  [ ! -e "$SANDBOX/a/queue/running/s.md" ]
  assert_equal "$(git -C "$ORIGIN" rev-list --parents -1 master | wc -w)" 3
  # Negative control: an open item done/ does not hold is left alone by the same merge.
  printf -- '---\nslug: o\n---\nt\n' > "$SANDBOX/b/queue/running/o.md"
  on b --now >/dev/null
  printf -- '---\nslug: p\n---\nt\n' > "$SANDBOX/a/queue/queued/p.md"
  run on a --now
  assert_success
  run git -C "$ORIGIN" ls-tree -r --name-only master -- queue/running
  assert_output 'queue/running/o.md'
}

@test "an item moved to two open states, or a close beside another conflict, still conflicts" {
  peer a; queue_item a; peer b
  move_item a running 'host: a'
  move_item b waiting 'ask: 1'
  on a --now
  run on b --now
  assert_failure
  assert_output --partial 'conflicts in queue/'
  [ -e "$SANDBOX/b/queue/waiting/x.md" ]
  ITEM=y
  peer c; queue_item c; peer d
  move_item c done/2026-11-21 'status: ok'
  move_item d running 'host: c'
  echo 'state: c' > "$SANDBOX/c/queue/item.md"
  echo 'state: d' > "$SANDBOX/d/queue/item.md"
  on c --now
  run on d --now
  assert_failure
  assert_output --partial 'queue/item.md'
  [ -e "$SANDBOX/d/queue/running/y.md" ]
}

# running_item <machine>: a running item r on origin, its header as agent-queue writes it (no leading ---).
running_item() {
  mkdir -p "$SANDBOX/$1/queue/running"
  printf 'slug: r\nhost: b\npartial: yes\nopen_pr: o#1\n---\ntask\n' > "$SANDBOX/$1/queue/running/r.md"
  on "$1" --now >/dev/null
}

# set_key <machine> <key> <value>: agent-queue's header_set on item r, a new key just above the ---.
set_key() {
  local f="$SANDBOX/$1/queue/running/r.md"
  awk -v k="$2" -v v="$3" '!d && $0 == "---" {if (!s) print k ": " v; d = 1; print; next}
    !d && index($0, k ":") == 1 {print k ": " v; s = 1; next} {print}' "$f" > "$f.t" && mv "$f.t" "$f"
}

@test "two machines setting different keys on one item's adjacent header lines both keep theirs (ar-3439)" {
  peer a; running_item a; peer b
  # the fleet home records a merged partial PR while the worker's session moves on to its next PR
  set_key a pr o#1; set_key a merged abc
  set_key b open_pr o#2; set_key b branch br@1
  on a --now
  run on b --now
  assert_success
  assert_output --partial COMPLETE
  run show "$ORIGIN" queue/running/r.md
  assert_line 'open_pr: o#2'
  assert_line 'branch: br@1'
  assert_line 'pr: o#1'
  assert_line 'merged: abc'
  assert_line 'task'
  refute_output --partial '<<<<<<<'
}

@test "one key set two ways on one item, or a repeated key, keeps this side's whole and the other as a lost file (ar-4471)" {
  peer a; running_item a; peer b
  set_key a open_pr o#2; set_key a pr o#1
  set_key b open_pr o#3
  on a --now
  run on b --now
  assert_success
  run show "$ORIGIN" queue/running/r.md
  assert_line 'open_pr: o#3'
  refute_line 'pr: o#1'
  run cat "$SANDBOX/b/.sync/lost/"queue__running__r.md.lost-*
  assert_line 'open_pr: o#2'
  assert_line 'pr: o#1'
  peer c; peer d
  # each side adds its own key at one spot; only the repeat on c's side stops the key merge
  sed -i 's/^---$/note: c\nnote: c\n---/' "$SANDBOX/c/queue/running/r.md"
  set_key d branch br@2
  on c --now
  run on d --now
  assert_success
  run show "$ORIGIN" queue/running/r.md
  assert_line 'branch: br@2'
  refute_line 'note: c'
  run cat "$SANDBOX/d/.sync/lost/"queue__running__r.md.lost-*
  assert_line 'note: c'
}

# run_item <machine> <slug>: a running item with a run header, as a worker's start writes it. The body
# is load-bearing: it keeps a requeued copy above git's 50% rename similarity, so the driver sees one item.
run_item() {
  mkdir -p "$SANDBOX/$1/queue/running"
  { printf 'slug: %s\nproject: p\nagent: ocfree\nqueued: 2026-11-23T21:19:07Z\nlane: agent\n' "$2"
    printf 'session: lab:w-29\naccount: ocfree\norigin: run\nmodel: beam\nhost: b\nstarted: 2026-11-23T21:38:06Z\n'
    printf 'sessions: ses_1\nlane_run: caff\n---\nfix(x): a task title long enough to read as one item\n'
    printf 'The body of the item, so a requeue that drops the run header is still the same file to git rename detection.\n'; } > "$SANDBOX/$1/queue/running/$2.md"
  on "$1" --now >/dev/null
}

# requeue_item <machine> <slug>: what agent-queue move <slug> queued does after a run, plus the route reset.
requeue_item() {
  local f="$SANDBOX/$1/queue/running/$2.md"
  mkdir -p "$SANDBOX/$1/queue/queued"
  sed -e '/^\(session\|origin\|host\|started\|lane_run\): /d' -e 's/^agent: .*/agent: claude/' \
    -e 's/^model: .*/model: /' -e 's/^---$/routed: \nrequeued: 2026-11-23T21:40:16Z\n---/' "$f" > "$SANDBOX/$1/queue/queued/$2.md"
  rm "$f"
}

@test "a peer's new running item stays in running/ when the other side requeued the only running item: no directory-rename move (ar-4898)" {
  peer a; run_item a q1; peer b
  run_item a q3
  requeue_item b q1
  git -C "$SANDBOX/b" add queue && git -C "$SANDBOX/b" commit -qm 'requeue q1'
  git -C "$SANDBOX/b" fetch -q origin
  # NEGATIVE CONTROL: git's default (conflict) stops the merge on q3's location, and true moves q3 into queued/ beside q1
  run git -C "$SANDBOX/b" -c merge.directoryRenames=conflict merge-tree --write-tree --name-only HEAD origin/master
  assert_failure
  assert_output --partial 'CONFLICT (file location): queue/running/q3.md'
  run git -C "$SANDBOX/b" -c merge.directoryRenames=true merge-tree --write-tree --name-only HEAD origin/master
  run git -C "$SANDBOX/b" ls-tree -r --name-only "${lines[0]}"
  assert_line 'queue/queued/q3.md'
  run on b --now
  assert_success
  run show "$ORIGIN" queue/running/q3.md
  assert_success
  run show "$ORIGIN" queue/queued/q3.md
  assert_failure
  run show "$ORIGIN" queue/queued/q1.md
  assert_success
}

# route_item <machine> <slug>: the other machine records the route and a PR on the running item.
route_item() {
  sed -i 's/^---$/routed: ocfree\npr: o#5\n---/' "$SANDBOX/$1/queue/running/$2.md"
}

@test "a key set two ways on an item one side requeued takes the requeue's value and keeps the other side's other keys, whichever syncs first (ar-3439)" {
  local s
  # razer-laptop requeued ar-3010 while the fleet home set routed: on its run (2026-11-23)
  # Each pair settles before the next starts: a requeue of the only running item reads to git as a
  # running/ -> queued/ directory rename, which would move another pair's new running item with it.
  peer a; run_item a q1; peer b
  route_item a q1; requeue_item b q1
  on a --now; run on b --now
  assert_success
  peer c; run_item c q2; peer d
  route_item d q2; requeue_item c q2
  on c --now; run on d --now
  assert_success
  for s in q1 q2; do
    run show "$ORIGIN" "queue/queued/$s.md"
    assert_line 'routed: '
    assert_line 'requeued: 2026-11-23T21:40:16Z'
    assert_line 'agent: claude'
    assert_line 'pr: o#5'
    assert_line 'sessions: ses_1'
    refute_line --partial 'started:'
    refute_line --partial 'host:'
    refute_output --partial '<<<<<<<'
    run git -C "$ORIGIN" ls-tree -r --name-only master -- queue/running
    assert_output ''
  done
  [ ! -d "$SANDBOX/b/.sync/lost" ] || [ -z "$(ls -A "$SANDBOX/b/.sync/lost")" ]
  [ ! -d "$SANDBOX/d/.sync/lost" ] || [ -z "$(ls -A "$SANDBOX/d/.sync/lost")" ]
  # negative control: the same clash with no requeue on either side still keeps a lost copy
  peer e; run_item e q3; peer f
  route_item e q3; sed -i 's/^---$/routed: \n---/' "$SANDBOX/f/queue/running/q3.md"
  on e --now; run on f --now
  assert_success
  run cat "$SANDBOX/f/.sync/lost/"queue__running__q3.md.lost-*
  assert_line 'routed: ocfree'
}

# queued_item <machine> <slug>: a queued item as agent-queue writes it. The body is load-bearing: it
# keeps each moved copy above git's 50% rename similarity, so both moves read as one item.
queued_item() {
  mkdir -p "$SANDBOX/$1/queue/queued"
  { printf 'slug: %s\nproject: p\nagent: claude\nqueued: 2026-11-23T23:48:41Z\nlane: agent\naccount: agy\nmodel: \n' "$2"
    printf 'sessions: agy_1\nrequeued: 2026-11-23T23:50:01Z\n---\nfix(x): a task title long enough to read as one item\n'
    printf 'The body of the item, so a move that adds a run header is still the same file to git rename detection.\n'; } > "$SANDBOX/$1/queue/queued/$2.md"
  on "$1" --now >/dev/null
}

# start_item <machine> <slug>: the dispatcher's running move, with its own started:.
start_item() {
  mkdir -p "$SANDBOX/$1/queue/running"
  sed -e 's/^account: .*/account: claude-b/' -e 's/^model: .*/model: sonnet/' \
    -e 's/^---$/host: b\nstarted: 2026-11-24T02:05:23Z\nlane_run: ab29\n---/' \
    "$SANDBOX/$1/queue/queued/$2.md" > "$SANDBOX/$1/queue/running/$2.md"
  rm "$SANDBOX/$1/queue/queued/$2.md"
}

# close_queued <machine> <slug>: a worker's session closing the item from a queued copy the running move never reached.
close_queued() {
  mkdir -p "$SANDBOX/$1/queue/done/2026-11-23"
  sed 's/^---$/pr: o#7\nstarted: 2026-11-24T02:05:49Z\nstatus: ok\nfinished: 2026-11-24T02:05:52Z\n---/' \
    "$SANDBOX/$1/queue/queued/$2.md" > "$SANDBOX/$1/queue/done/2026-11-23/$2.md"
  rm "$SANDBOX/$1/queue/queued/$2.md"
}

@test "a close and a running move that set one key two ways keep the close and write no lost file, whichever syncs first (ar-3439)" {
  local s
  # razer-laptop's session closed ar-4219 while the fleet home's running move set its own started: (2026-11-23)
  peer a; queued_item a c1; peer b
  close_queued a c1; start_item b c1
  on b --now; run on a --now
  assert_success
  peer c; queued_item c c2; peer d
  close_queued c c2; start_item d c2
  on c --now; run on d --now
  assert_success
  for s in c1 c2; do
    run show "$ORIGIN" "queue/done/2026-11-23/$s.md"
    assert_line 'status: ok'
    assert_line 'started: 2026-11-24T02:05:49Z'
    refute_output --partial '<<<<<<<'
  done
  run git -C "$ORIGIN" ls-tree -r --name-only master -- queue/queued queue/running
  assert_output ''
  [ ! -d "$SANDBOX/a/.sync/lost" ] || [ -z "$(ls -A "$SANDBOX/a/.sync/lost")" ]
  [ ! -d "$SANDBOX/d/.sync/lost" ] || [ -z "$(ls -A "$SANDBOX/d/.sync/lost")" ]
  # a requeue still outranks a close: a stale reaper's failed close beside a requeue writes no lost file
  peer e; run_item e c3; peer f
  route_item e c3; requeue_item f c3
  mkdir -p "$SANDBOX/e/queue/done/2026-11-23"
  sed 's/^---$/status: failed\nfinished: 2026-11-24T02:06:00Z\n---/' "$SANDBOX/e/queue/running/c3.md" > "$SANDBOX/e/queue/done/2026-11-23/c3.md"
  rm "$SANDBOX/e/queue/running/c3.md"
  on f --now; run on e --now
  assert_success
  [ ! -d "$SANDBOX/e/.sync/lost" ] || [ -z "$(ls -A "$SANDBOX/e/.sync/lost")" ]
}

@test "a clone set up with the old close driver moves to the item driver" {
  peer a
  printf 'queue/done/*/*.md merge=close\n' > "$SANDBOX/a/.git/info/attributes"
  git -C "$SANDBOX/a" config merge.close.driver 'store-sync merge-close %O %A %B %P'
  echo 'state: x' > "$SANDBOX/a/queue/item.md"
  on a --now >/dev/null
  run cat "$SANDBOX/a/.git/info/attributes"
  assert_output $'queue/*/*.md merge=item\nqueue/done/*/*.md merge=item'
  run git -C "$SANDBOX/a" config --get merge.close.driver
  assert_failure
  run git -C "$SANDBOX/a" config --get merge.item.driver
  assert_output --partial 'merge-item %O %A %B %P'
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

# plan dispatch-event-wake, step 5: an add or close made in a worker's clone reaches the lease holder only
# through its pull, so the holder's sync is what wakes the kick; the holder's own writers touch .wake.
@test "a pull that brings in a queued or done item wakes a dispatch kick on the lease holder only (dispatch-event-wake)" {
  export FLEET_DISPATCH_DIR="$SANDBOX/dispatch"
  printf '#!/bin/sh\nexit "${LEASE_RC:-0}"\n' > "$SANDBOX/bin/fleet-lease"; chmod +x "$SANDBOX/bin/fleet-lease"
  peer a; peer b
  mkdir -p "$SANDBOX/b/queue/queued"
  echo 'state: queued' > "$SANDBOX/b/queue/queued/one.md"
  run on b
  assert_success
  [ ! -e "$FLEET_DISPATCH_DIR/.wake" ] || fail "the clone that wrote the item woke a kick for its own write"
  # A peer that does not hold the lease runs no kick, so it writes no wake.
  LEASE_RC=1 run on a
  assert_success
  [ -e "$SANDBOX/a/queue/queued/one.md" ] || fail "the pull did not bring the item in"
  [ ! -e "$FLEET_DISPATCH_DIR/.wake" ] || fail "a peer without the lease wrote a wake"
  # Negative control: a pull that changed nothing under queue/queued or queue/done wakes nothing.
  echo 'state: other' > "$SANDBOX/b/queue/item.md"
  run on b
  run on a
  [ ! -e "$FLEET_DISPATCH_DIR/.wake" ] || fail "a pull of another path wrote a wake"
  # The holder: the next arrival wakes it.
  mkdir -p "$SANDBOX/b/queue/done/2026-11-23"
  echo 'state: done' > "$SANDBOX/b/queue/done/2026-11-23/two.md"
  run on b
  run on a
  assert_success
  [ -s "$FLEET_DISPATCH_DIR/.wake" ] || fail "the lease holder's pull of a done item wrote no wake"
  # A close is a move of a queued file into done with its status edited: git reads that as a rename.
  rm -f "$FLEET_DISPATCH_DIR/.wake"
  mkdir -p "$SANDBOX/b/queue/done/2026-11-24"
  mv "$SANDBOX/b/queue/queued/one.md" "$SANDBOX/b/queue/done/2026-11-24/one.md"
  echo 'status: ok' >> "$SANDBOX/b/queue/done/2026-11-24/one.md"
  run on b
  run on a
  assert_success
  [ -s "$FLEET_DISPATCH_DIR/.wake" ] || fail "the lease holder's pull of a closed (moved) item wrote no wake"
}

@test "a sync keeps the machine-local dispatch files out of the shared store (dispatch-event-wake)" {
  export FLEET_DISPATCH_DIR="$SANDBOX/a/dispatch"
  peer a
  run on a
  grep -qxF 'dispatch/.wake' "$SANDBOX/a/.git/info/exclude"
  grep -qxF 'dispatch/.kick' "$SANDBOX/a/.git/info/exclude"
  mkdir -p "$SANDBOX/a/dispatch"
  echo 1 > "$SANDBOX/a/dispatch/.wake"; : > "$SANDBOX/a/dispatch/.kick"; echo 1 > "$SANDBOX/a/dispatch/log.md"
  run on a
  assert_success
  run git -C "$SANDBOX/a" ls-files dispatch
  assert_output 'dispatch/log.md'
}
