#!/usr/bin/env bats
# fleet-lease: exactly one machine runs the singleton lanes. The store's remotes are local bare
# repos, each "machine" is a peer clone under the sandbox with its own FLEET_HOST, and the clock is
# FLEET_LEASE_NOW, so expiry needs no wait.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  BIN="$REPO_ROOT/.local/bin/fleet-lease"
  export STORE_SYNC_SSH_KEY=/nonexistent
  R="$SANDBOX/remotes" ORIGIN="$SANDBOX/remotes/origin.git" BACKUP="$SANDBOX/remotes/backup.git"
  mkdir -p "$R"
  git init -q --bare -b master "$ORIGIN"
  git init -q --bare -b master "$BACKUP"
  export STORE_SYNC_CONF="$SANDBOX/store.env"
  conf "$ORIGIN"
  export AGENTCTL_CONF_DIR="$SANDBOX/agents"
  mkdir -p "$AGENTCTL_CONF_DIR"
  printf 'KIND=oneshot\nSCOPE=singleton\n' > "$AGENTCTL_CONF_DIR/fleet-dispatch.conf"
  printf 'KIND=oneshot\nSCOPE=every-node\n' > "$AGENTCTL_CONF_DIR/tmp-gc.conf"
  printf 'KIND=persistent\nSCOPE=singleton\n' > "$AGENTCTL_CONF_DIR/sentinel.conf"
  printf 'KIND=persistent\nSCOPE=every-node\n' > "$AGENTCTL_CONF_DIR/local-watch.conf"
  T0=1800000000
  export FLEET_LEASE_NOW=$T0
  peer a; peer b
}

# conf <origin url>: the machine-wide store.env.
conf() { printf 'STORE_PRIMARY_URL="%s"\nSTORE_BACKUP_URL="%s"\n' "$1" "$BACKUP" > "$STORE_SYNC_CONF"; }

# peer <name>: a joined store at $SANDBOX/<name>.
peer() { mkdir -p "$SANDBOX/$1/.sync"; echo joined > "$SANDBOX/$1/.sync/peer"; }

# on <name> <args...>: fleet-lease as that machine.
on() { local m="$1"; shift; AGENT_STORE_DIR="$SANDBOX/$m" FLEET_HOST="$m" "$BIN" "$@"; }

# holder <bare repo> -> the holder its lease branch names.
holder() { git -C "$1" show lease/fleet:lease | sed -n 's/^holder=//p'; }

@test "a free lease goes to the first machine that asks, and the other skips every singleton" {
  run on a fleet-dispatch
  assert_success
  assert_output --partial "a took the fleet lease on origin"
  assert_equal "$(holder "$ORIGIN")" a
  assert_equal "$(holder "$BACKUP")" a
  run -1 on b fleet-dispatch
  assert_output --partial "fleet-dispatch is a singleton and a holds the fleet lease"
  # A lane with no conf (fleet-state, agent-web) is a singleton too.
  run -1 on b fleet-state
  # The negative control: an every-node lane runs on both.
  run on b tmp-gc
  assert_success
  assert_output ""
}

@test "two machines that take a free lease at once: exactly one runs, every round" {
  local round rc_a rc_b
  for round in 1 2 3 4 5; do
    export FLEET_LEASE_NOW=$((T0 + round * 1000))   # every earlier lease has lapsed
    rm -f "$SANDBOX"/[ab]/.sync/lease-fleet
    on a fleet-dispatch 2>/dev/null & local pa=$!
    on b fleet-dispatch 2>/dev/null & local pb=$!
    rc_a=0; wait "$pa" || rc_a=$?
    rc_b=0; wait "$pb" || rc_b=$?
    [ $(( (rc_a == 0) + (rc_b == 0) )) = 1 ] || fail "round $round: a exited $rc_a and b $rc_b"
  done
}

@test "a take that read a stale tip is refused by the remote, and the loser reads the winner" {
  on a fleet-dispatch 2>/dev/null
  # b's first lease fetch does nothing, so it reads an older tip than origin's: no lease at all.
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" --depth=1 "* ]] && [ -e "$SANDBOX/stale-once" ]; then rm -f "$SANDBOX/stale-once"; exit 0; fi
exec $(command -v git) "\$@"
EOF
  chmod +x "$SANDBOX/bin/git"
  touch "$SANDBOX/stale-once"
  PATH="$SANDBOX/bin:$PATH" run -1 on b fleet-dispatch
  assert_output --partial "a holds the fleet lease"
  [ ! -e "$SANDBOX/stale-once" ] || fail "the stale fetch never ran"
  assert_equal "$(holder "$ORIGIN")" a
}

@test "a holder that stops renewing loses the lease when it lapses, to the next machine that asks" {
  on a fleet-dispatch 2>/dev/null
  run -1 on b fleet-dispatch
  export FLEET_LEASE_NOW=$((T0 + 301))
  run on b fleet-dispatch
  assert_success
  assert_output --partial "b took the fleet lease"
  assert_equal "$(holder "$ORIGIN")" b
  run -1 on a fleet-dispatch
  assert_output --partial "b holds the fleet lease"
}

@test "the holder passes the gate with no remote at all until its lease nears expiry" {
  on a fleet-dispatch 2>/dev/null
  conf "$SANDBOX/remotes/gone.git"
  printf 'STORE_PRIMARY_URL="%s"\nSTORE_BACKUP_URL="%s"\n' "$R/gone.git" "$R/gone2.git" > "$STORE_SYNC_CONF"
  run on a fleet-dispatch
  assert_success
  run -2 on b fleet-dispatch
  assert_output --partial "no remote of the store answered, so b cannot tell"
  # Inside the margin the holder must reach a remote, so it stops too.
  export FLEET_LEASE_NOW=$((T0 + 250))
  run -2 on a fleet-dispatch
}

@test "while origin is unreachable backup decides, and origin's holder takes backup back" {
  conf "$R/gone.git"
  run on a fleet-dispatch
  assert_success
  assert_output --partial "a took the fleet lease on backup"
  run -1 on b fleet-dispatch
  # origin answers again, a's lease lapses there unwritten: b takes origin and writes over backup.
  conf "$ORIGIN"
  export FLEET_LEASE_NOW=$((T0 + 301))
  run on b fleet-dispatch
  assert_success
  assert_output --partial "on origin"
  assert_equal "$(holder "$BACKUP")" b
  run -1 on a fleet-dispatch
}

@test "a machine that is not a peer of the store never takes the lease" {
  rm "$SANDBOX/b/.sync/peer"
  run -2 on b fleet-dispatch
  assert_output --partial "not a peer clone"
  run git -C "$ORIGIN" rev-parse -q --verify lease/fleet
  assert_failure
}

@test "renew keeps the holder's lease live, starts its persistent singletons, and stops them on a machine that lost it" {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$FLEET_HOST \$*" >> "$SANDBOX/systemctl.log"
case "\$2" in
  is-enabled) exit 0 ;;
  is-active) [ -e "$SANDBOX/active.\$FLEET_HOST.\${@: -1}" ] ;;
esac
EOF
  chmod +x "$SANDBOX/bin/systemctl"
  export PATH="$SANDBOX/bin:$PATH"
  run on a renew
  assert_success
  assert_line "fleet-lease: started agent-web.service"
  assert_line "fleet-lease: started agentctl@sentinel.service"
  refute_output --partial local-watch
  # Half the TTL on, renew writes a new expiry, so b still cannot take it past the first one.
  export FLEET_LEASE_NOW=$((T0 + 200))
  touch "$SANDBOX/active.a.agent-web.service" "$SANDBOX/active.a.agentctl@sentinel.service"
  run on a renew
  assert_success
  assert_output ""
  export FLEET_LEASE_NOW=$((T0 + 320))
  run -1 on b fleet-dispatch
  # a goes quiet; once its renewed lease lapses b takes it, and a's next renew stops its units.
  export FLEET_LEASE_NOW=$((T0 + 600))
  on b renew >/dev/null
  assert_equal "$(holder "$ORIGIN")" b
  run on a renew
  assert_line "fleet-lease: stopped agent-web.service: a does not hold the fleet lease"
  assert_line "fleet-lease: stopped agentctl@sentinel.service: a does not hold the fleet lease"
}

# systemctl_stub: logs each call, every unit enabled, active when $SANDBOX/active.<host>.<unit> exists.
systemctl_stub() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/systemctl" <<EOS
#!/usr/bin/env bash
echo "\$FLEET_HOST \$*" >> "$SANDBOX/systemctl.log"
case "\$2" in
  is-enabled) exit 0 ;;
  is-active) [ -e "$SANDBOX/active.\$FLEET_HOST.\${@: -1}" ] ;;
esac
EOS
  chmod +x "$SANDBOX/bin/systemctl"
  export PATH="$SANDBOX/bin:$PATH"
}

@test "held reads only the local record: 0 on the holder, 1 elsewhere, 2 with no live holder known" {
  run -2 on a held
  assert_output --partial "no machine is known to hold the fleet lease"
  on a fleet-dispatch 2>/dev/null
  on b fleet-dispatch 2>/dev/null || :
  # No remote at all: held never dials one.
  printf 'STORE_PRIMARY_URL="%s"\nSTORE_BACKUP_URL="%s"\n' "$R/gone.git" "$R/gone2.git" > "$STORE_SYNC_CONF"
  run on a held
  assert_success
  run -1 on b held
  assert_output --partial "a holds the fleet lease until"
  export FLEET_LEASE_NOW=$((T0 + 301))
  run -2 on b held
  assert_output --partial "the last one read lapsed"
  rm "$SANDBOX/b/.sync/peer"
  run -2 on b held
  assert_output --partial "not a peer clone"
}

@test "a machine marked no-lease skips every singleton, never takes the lease, and its renew stops the holder's units" {
  : > "$SANDBOX/b/.sync/no-lease"
  run -1 on b fleet-dispatch
  assert_output --partial "never holds the fleet lease"
  run git -C "$ORIGIN" rev-parse -q --verify lease/fleet
  assert_failure
  # Its every-node lanes still run.
  run on b tmp-gc
  assert_success
  run -1 on b held
  systemctl_stub
  touch "$SANDBOX/active.b.agent-web.service"
  run on b renew
  assert_success
  assert_line "fleet-lease: stopped agent-web.service: b does not hold the fleet lease"
  run git -C "$ORIGIN" rev-parse -q --verify lease/fleet
  assert_failure
  run on b status --json
  assert_equal "$(jq -r .candidate <<<"$output")" false
}

@test "renew on a machine that is not a peer stops the holder's units it still runs" {
  rm "$SANDBOX/b/.sync/peer"
  systemctl_stub
  touch "$SANDBOX/active.b.agentctl@sentinel.service"
  run on b renew
  assert_success
  assert_line "fleet-lease: stopped agentctl@sentinel.service: b does not hold the fleet lease"
  refute_output --partial started
}

@test "renew removes the singletons' textfiles on a machine another holds the lease from; the holder and one that cannot tell keep theirs" {
  # razer held the lease until 2026-11-19 and its fleet_bench.prom stayed a second, frozen
  # agent_bench_vital reading for two days after (ar-4358).
  systemctl_stub
  export FLEET_LEASE_TEXTFILES="fleet_bench.prom fleet_sessions.prom"
  local d="$PROM_TEXTFILE_DIR"
  mkdir -p "$d"
  echo 'agent_bench_vital 1' > "$d/fleet_bench.prom"
  echo 'fleet_local 1' > "$d/fleet_local.prom"
  run on a renew
  assert_success
  refute_output --partial removed
  [ -e "$d/fleet_bench.prom" ]
  run on b renew
  assert_success
  assert_line "fleet-lease: removed fleet_bench.prom: b does not hold the fleet lease"
  refute_output --partial fleet_sessions
  [ ! -e "$d/fleet_bench.prom" ]
  # An every-node file stays.
  [ -e "$d/fleet_local.prom" ]
  # No remote answers and a's lease has lapsed: b cannot tell, so it keeps the copy.
  echo 'agent_bench_vital 1' > "$d/fleet_bench.prom"
  printf 'STORE_PRIMARY_URL="%s"\nSTORE_BACKUP_URL="%s"\n' "$R/gone.git" "$R/gone2.git" > "$STORE_SYNC_CONF"
  export FLEET_LEASE_NOW=$((T0 + 600))
  run on b renew
  assert_success
  refute_output --partial removed
  [ -e "$d/fleet_bench.prom" ]
  # A machine that never holds it, marked no-lease or not a peer, removes its copy with no remote.
  : > "$SANDBOX/b/.sync/no-lease"
  run on b renew
  assert_success
  assert_line "fleet-lease: removed fleet_bench.prom: b does not hold the fleet lease"
  echo 'agent_bench_vital 1' > "$d/fleet_bench.prom"
  rm "$SANDBOX/b/.sync/no-lease" "$SANDBOX/b/.sync/peer"
  run on b renew
  assert_success
  assert_line "fleet-lease: removed fleet_bench.prom: b does not hold the fleet lease"
}

@test "every textfile a tool here publishes is a singleton's, which renew removes off the holder, or every node's" {
  # A new writer left out of both would leave a frozen copy behind on each lease handover.
  local every_node=" " singletons f
  singletons=" $(sed -n 's/^TEXTFILES="${FLEET_LEASE_TEXTFILES:-\(.*\)}"$/\1/p' "$BIN") "
  [ "$singletons" != "  " ] || fail "no TEXTFILES default in fleet-lease"
  for f in $(grep -ohE 'prom_textfile [a-z_]+\.prom' "$REPO_ROOT"/.local/bin/* | awk '{print $2}' | sort -u); do
    [[ "$singletons$every_node" == *" $f "* ]] || fail "$f is in neither fleet-lease TEXTFILES nor this test's every-node list"
  done
}

@test "status names the holder on each remote" {
  on a fleet-dispatch 2>/dev/null
  run on b status
  assert_success
  assert_line --index 0 "this machine (b) does not hold the fleet lease"
  assert_line --partial "origin: a holds it until"
  run on a status --json
  assert_success
  assert_equal "$(jq -r '[.held, .remotes[0].holder, .remotes[0].live] | @tsv' <<<"$output")" "$(printf 'true\ta\ttrue')"
}

@test "each singleton unit outside agentctl is gated on the lease under its own lane name" {
  local u
  for u in fleet-state agent-ask-deliver schedules-sync; do
    grep -qx "ExecCondition=%h/.local/bin/fleet-lease $u" "$REPO_ROOT/.config/systemd/user/$u.service" ||
      fail "$u.service has no fleet-lease ExecCondition"
  done
  run grep -rlE 'fleet-is-home|AGENT_STATE_LOCAL|AGENT_STATE_HOST' "$REPO_ROOT/.config/systemd/user"
  assert_output ''
}
