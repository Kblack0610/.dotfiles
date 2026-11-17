#!/usr/bin/env bats
# fleet-hosts.sh: the fleet worker roster read from the home-config inventory, the one ssh path to
# a worker, and the forwarding that keeps a remote session's queue and ask writes on the state host.
# ssh is a stub that logs its arguments; nothing leaves the sandbox.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_INVENTORY="$SANDBOX/inventory.yml"
  export FLEET_HOST=state   # this machine is the fixture's fleet_state_host, state.lan; a case that is not sets its own
  cat > "$FLEET_INVENTORY" <<'EOF'
all:
  vars:
    ansible_user: kb
    fleet_state_host: state.lan
  children:
    desktops:
      hosts:
        state: {}
    laptops:
      hosts:
        razer-laptop:
          ansible_host: 192.0.2.26
        hp-victus:
          ansible_host: 192.0.2.30
          ansible_port: 2222
    fleet_workers:
      vars:
        fleet_place: false
      hosts:
        razer-laptop:
          fleet_max_live: 2
          fleet_repos:
            - dest: ~/.dotfiles
              repo: https://github.com/x/dotfiles.git
            - /abs/game
        hp-victus:
          fleet_place: true
EOF
  # ssh: log the call (with whether stdin was kept), answer from ssh.out, exit ssh.rc (default 0).
  stub ssh 'stdin=none; [ "$1" = -n ] || stdin=$(cat)
echo "ssh $* <<$stdin" >> "$NOTES_FIXTURE/calls.log"
cat "$NOTES_FIXTURE/ssh.out" 2>/dev/null
exit "$(cat "$NOTES_FIXTURE/ssh.rc" 2>/dev/null || echo 0)"'
  # shellcheck source=/dev/null
  source "$FLEET_HOSTS_LIB"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

@test "the roster is the inventory group, with group, host and all.vars merged and ansible_host from another group" {
  run fleet_hosts
  assert_success
  assert_line --index 0 "{\"name\": \"razer-laptop\", \"dest\": \"kb@192.0.2.26\", \"port\": 22, \"max_live\": 2, \"place\": false, \"repos\": [\"$HOME/.dotfiles\", \"/abs/game\"], \"state_host\": \"state.lan\", \"state_match\": \"me\", \"power\": \"\"}"
  assert_equal "$(fleet_host hp-victus | jq -r '"\(.dest) \(.port) \(.max_live) \(.place)"')" 'kb@192.0.2.30 2222 1 true'
  run fleet_host laptop
  assert_failure
}

@test "a cloud worker is reached by fleet_ssh_host, not its ansible_host instance id, and carries its fleet_power" {
  sed -i 's/^          fleet_place: true$/&\n          ansible_host: i-0123456789abcdef0\n          fleet_ssh_host: hp-victus.tail.example\n          fleet_power: governor/' "$FLEET_INVENTORY"
  assert_equal "$(fleet_host hp-victus | jq -r '"\(.dest) \(.power)"')" 'kb@hp-victus.tail.example governor'
  assert_equal "$(fleet_host razer-laptop | jq -r '"\(.dest) [\(.power)]"')" 'kb@192.0.2.26 []'
}

@test "no inventory or no group is an empty roster, not an error" {
  FLEET_INVENTORY=/nonexistent run fleet_hosts
  assert_success
  assert_output ''
  unset FLEET_HOSTS_JSON
  FLEET_HOSTS_GROUP=none run fleet_hosts
  assert_success
  assert_output ''
}

@test "fleet_host_run quotes each argument once, keeps no stdin, and passes the command's exit back" {
  echo 3 > "$NOTES_FIXTURE/ssh.rc"
  run fleet_host_run hp-victus printf '%s\n' 'a b' "it's"
  assert_failure 3
  assert_called "ssh -n -T -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p 2222 kb@192.0.2.30 PATH=\"\$HOME/.local/bin:\$PATH\" exec env printf %s\\\\n a\\ b it\\'s  <<none"
  run fleet_host_run nowhere true
  assert_failure 255
  assert_output --partial 'nowhere is not in fleet_workers'
}

@test "a host's own vars win over a group's, even one listed after it; that group's other vars still apply" {
  cat >> "$FLEET_INVENTORY" <<'EOF'
    later:
      vars:
        fleet_max_live: 9
        ansible_port: 2200
      hosts:
        razer-laptop:
EOF
  assert_equal "$(fleet_host razer-laptop | jq -r '"\(.max_live) \(.port)"')" '2 2200'
}

@test "cancel closes a worker's session on that worker, never one here; a requeue forgets the host" {
  local q="$REPO_ROOT/.local/bin/agent-queue"
  stub tmux-close-here 'echo "here $*" >> "$NOTES_FIXTURE/calls.log"'
  export TMUX_CLOSE="$SANDBOX/bin/tmux-close-here"
  "$q" add --project game --slug fix-menu "Fix the menu" >/dev/null
  "$q" set fix-menu session=lab:agent-1 origin=run host=hp-victus >/dev/null
  "$q" move fix-menu running >/dev/null
  run "$q" cancel fix-menu
  assert_success
  assert_called '-p 2222 kb@192.0.2.30 PATH="$HOME/.local/bin:$PATH" exec env tmux-close -L lab session agent-1'
  assert_not_called 'here -L'
  # negative control: the same item with no host closes here.
  "$q" add --project game --slug fix-hud "Fix the hud" >/dev/null
  "$q" set fix-hud session=lab:agent-2 origin=run >/dev/null
  "$q" move fix-hud running >/dev/null
  run "$q" cancel fix-hud
  assert_called 'here -L lab session agent-2'
  "$q" add --project game --slug fix-map "Fix the map" >/dev/null
  "$q" set fix-map session=lab:agent-3 origin=run host=hp-victus >/dev/null
  "$q" move fix-map running >/dev/null
  "$q" move fix-map queued >/dev/null
  run grep -h '^host:' "$AGENT_QUEUE_DIR"/queued/*-fix-map.md
  assert_failure
}

@test "state_forward does nothing on the fleet home without AGENT_STATE_HOST" {
  run state_forward agent-queue add list
  assert_success
  assert_not_called ssh
}

@test "agent-queue on a worker writes the state host's queue over ssh, with its item and none of its tmux" {
  export AGENT_STATE_HOST=state.lan AGENT_QUEUE_ITEM=fix-menu TMUX=/tmp/x,1,0
  echo 'set on state' > "$NOTES_FIXTURE/ssh.out"
  run "$REPO_ROOT/.local/bin/agent-queue" set fix-menu pr=12
  assert_success
  assert_output 'set on state'
  assert_called 'ssh -n -T -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 state.lan PATH="$HOME/.local/bin:$PATH" exec env -u AGENT_STATE_HOST AGENT_STATE_LOCAL=1 AGENT_QUEUE_ITEM=fix-menu agent-queue set fix-menu pr=12  <<none'
  assert_not_called TMUX
  [ ! -d "$HOME/.agent/queue" ] || fail "wrote a local queue"
  # `add` and `retask` read a task from stdin, so those verbs keep it.
  run bash -c 'echo "the task" | "$0" add --project game' "$REPO_ROOT/.local/bin/agent-queue"
  assert_success
  assert_called 'agent-queue add --project game  <<the task'
  run bash -c 'echo "the fix" | "$0" retask fix-menu' "$REPO_ROOT/.local/bin/agent-queue"
  assert_success
  assert_called 'agent-queue retask fix-menu  <<the fix'
}

@test "an unreachable state host is named, nothing is written here, and ssh's 255 comes back" {
  export AGENT_STATE_HOST=state.lan
  echo 255 > "$NOTES_FIXTURE/ssh.rc"
  run "$REPO_ROOT/.local/bin/agent-ask" list
  assert_failure 255
  assert_output --partial 'the state host state.lan did not answer over ssh; nothing was written'
  assert_called 'exec env -u AGENT_STATE_HOST AGENT_STATE_LOCAL=1 agent-ask list  <<none'
  [ -z "$(ls -A "$HOME/.agent/asks")" ] || fail "wrote local asks"
}

@test "a machine that is not the fleet home forwards to the home the roster names, with no AGENT_STATE_HOST" {
  export FLEET_HOST=old-main
  echo 'listed on state' > "$NOTES_FIXTURE/ssh.out"
  run "$REPO_ROOT/.local/bin/agent-queue" list
  assert_success
  assert_output 'listed on state'
  assert_called 'state.lan PATH="$HOME/.local/bin:$PATH" exec env -u AGENT_STATE_HOST AGENT_STATE_LOCAL=1 agent-queue list  <<none'
  [ ! -d "$HOME/.agent/queue" ] || fail "wrote a local queue"
}

@test "a forwarded run never forwards again, even where a stale roster names another home" {
  export FLEET_HOST=old-main AGENT_STATE_LOCAL=1
  run state_forward agent-queue add list
  assert_success
  assert_not_called ssh
}

@test "with no roster no machine is home, it says why, and nothing forwards" {
  export FLEET_HOST=state FLEET_INVENTORY=/nonexistent
  run fleet_is_home
  assert_failure 2
  fleet_is_home || true
  assert_equal "$FLEET_ROSTER_ERR" "/nonexistent could not be read"
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-is-home"
  assert_failure 2
  assert_equal "$stderr" "fleet-is-home: the fleet roster cannot be read (/nonexistent could not be read), so state stands down"
  run state_forward agent-queue add list
  assert_success
  assert_not_called ssh
}

@test "a roster that cannot be read stands down; only one that reads and names no fleet_state_host is one machine" {
  local real; real=$(command -v python3)
  printf 'all:\n  children:\n    laptops:\n      hosts:\n        a: {}\n' > "$FLEET_INVENTORY"
  unset FLEET_HOSTS_JSON; fleet_is_home && fail "no group read as home"
  assert_equal "$FLEET_ROSTER_ERR" "the inventory has no fleet_workers group"
  printf 'all:\n  children:\n    fleet_workers:\n      hosts: {}\n' > "$FLEET_INVENTORY"
  unset FLEET_HOSTS_JSON; fleet_is_home && fail "an empty group read as home"
  assert_equal "$FLEET_ROSTER_ERR" "the fleet_workers group lists no host"
  printf 'all:\n  children:\n    fleet_workers:\n      hosts: [\n' > "$FLEET_INVENTORY"
  unset FLEET_HOSTS_JSON; fleet_is_home 2>/dev/null && fail "bad YAML read as home"
  assert_equal "$FLEET_ROSTER_ERR" "the inventory did not parse"
  # The negative control: the same roster, readable, names no home, so this machine is the fleet of one.
  printf 'all:\n  children:\n    fleet_workers:\n      hosts:\n        a: {}\n' > "$FLEET_INVENTORY"
  unset FLEET_HOSTS_JSON; FLEET_HOST=old-main fleet_is_home || fail "a roster naming no home did not read as one machine"
  # python3 with no yaml module: the roster is unreadable, said on stderr.
  stub python3 "shift 2; exec '$real' -I -c 'import sys; sys.modules[\"yaml\"] = None; sys.argv = sys.argv[1:]; exec(sys.stdin.read())' \"\$@\""
  unset FLEET_HOSTS_JSON
  run --separate-stderr fleet_is_home
  assert_failure 2
  assert_equal "$stderr" "fleet-hosts: python3 has no yaml module (python-yaml), so the fleet roster reads as empty"
}

@test "a machine whose roster fetch fails is home while its last landed fetch is under FLEET_ROSTER_TRUST_SECS old or from since it booted" {
  home_config_fixture
  export -f project_repo_path
  roster_names state.lan   # names this machine
  fleet_roster_fetch
  git -C "$HC" remote set-url forgejo "$SANDBOX/gone.git"
  local stamp now; stamp=$(_fh_stamp "$HC") now=$(date +%s)
  export FLEET_BOOTED_AT=$((now - 2 * FLEET_ROSTER_TRUST_SECS))   # up since before every stamp below
  # A forge blip on the home: the fetch is due and fails, the last landed one is recent, so it stays home.
  touch -d "@$((now - FLEET_ROSTER_MAX_SECS - 1))" "$stamp"
  unset FLEET_HOSTS_JSON
  fleet_is_home 2>/dev/null || fail "a forge blip stood the home down"
  [ -e "$stamp.failed" ] || fail "the failed fetch left no mark"
  # A forge outage past the trust window on a home that stayed up: the roster it fetched still holds.
  touch -d "@$((now - FLEET_ROSTER_TRUST_SECS - 1))" "$stamp"
  rm -f "$stamp.failed"
  unset FLEET_HOSTS_JSON
  fleet_is_home 2>/dev/null || fail "a forge outage stood a home that stayed up down"
  # Back after a day off (booted since its last fetch), the fetch fails: the old roster may still
  # name it, so it stands down.
  export FLEET_BOOTED_AT=$((now - 60))
  rm -f "$stamp.failed"
  unset FLEET_HOSTS_JSON
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-is-home"
  assert_failure 2
  assert_equal "$stderr" "$(printf '%s\n' "fleet-hosts: fetching forgejo/master in $HC failed, so the roster is as last fetched" "fleet-is-home: the fleet roster cannot be read (no fetch of it has landed since this machine booted, and the last is over ${FLEET_ROSTER_TRUST_SECS}s old), so state stands down")"
  # A fetch that lands is trusted again and clears the mark.
  git -C "$HC" remote set-url forgejo "$SANDBOX/up.git"
  fleet_roster_fetch
  [ ! -e "$stamp.failed" ] || fail "a fetch that landed left the failed mark"
  unset FLEET_HOSTS_JSON
  fleet_is_home || fail "a fresh roster naming this machine did not read as home"
}

@test "a home written as user@host or in another case is this machine; another inventory machine is not, and no machine is rc 3" {
  sed -i 's/fleet_state_host: state.lan/fleet_state_host: kb@STATE.lan/' "$FLEET_INVENTORY"
  fleet_is_home || fail "kb@STATE.lan is not read as state"
  local other
  for other in kb@razer-laptop.lan 192.0.2.30; do   # a host's name, or another host's ansible_host
    sed -i "s/fleet_state_host: .*/fleet_state_host: $other/" "$FLEET_INVENTORY"
    unset FLEET_HOSTS_JSON
    run fleet_is_home
    assert_failure 1
  done
  # A name no inventory machine has is no machine: rc 3, which the callers say out loud.
  sed -i 's/fleet_state_host: .*/fleet_state_host: kb@typo.lan/' "$FLEET_INVENTORY"
  unset FLEET_HOSTS_JSON
  run fleet_is_home
  assert_failure 3
}

@test "a home named by a DHCP name, not the hostname, is home by its own inventory entry, with no DNS lookup" {
  export FLEET_HOST=ws-hostname
  # A DNS lookup would be logged; the LAN DNS being down must not change the answer.
  stub getent 'echo "getent $*" >> "$NOTES_FIXTURE/calls.log"; exit 2'
  sed -i 's/^    laptops:$/    workstation:\n      hosts:\n        ws-hostname:\n          ansible_connection: local\n          fleet_ssh_host: state.lan\n&/' "$FLEET_INVENTORY"
  sed -i 's/^        state: {}$/        other-box: {}/' "$FLEET_INVENTORY"
  run fleet_is_home
  assert_success
  run state_forward agent-queue add list
  assert_success
  assert_not_called ssh
  # Its ansible_host names it too: a roster that gives the home's IP.
  sed -i 's/fleet_ssh_host: state.lan/ansible_host: 192.0.2.2/; s/fleet_state_host: state.lan/fleet_state_host: 192.0.2.2/' "$FLEET_INVENTORY"
  run fleet_is_home
  assert_success
  # Another machine, whose entry names neither, is not home and forwards.
  export FLEET_HOST=razer-laptop
  run fleet_is_home
  assert_failure 1
  # A name set for every host (all.vars) is no host's own, so it makes no member the home.
  sed -i 's/^    ansible_user: kb$/&\n    fleet_ssh_host: 192.0.2.2/' "$FLEET_INVENTORY"
  run fleet_is_home
  assert_failure 1
  assert_not_called getent
}

@test "fleet-is-home passes on the home and fails elsewhere naming the home, or naming a home no machine is" {
  run "$REPO_ROOT/.local/bin/fleet-is-home"
  assert_success
  assert_output ''
  FLEET_HOST=old-main run --separate-stderr "$REPO_ROOT/.local/bin/fleet-is-home"
  assert_failure 1
  assert_equal "$stderr" "fleet-is-home: old-main is not the fleet home; the inventory's fleet_state_host is state.lan"
  sed -i 's/fleet_state_host: .*/fleet_state_host: typo.lan/' "$FLEET_INVENTORY"
  FLEET_HOST=old-main run --separate-stderr "$REPO_ROOT/.local/bin/fleet-is-home"
  assert_failure 3
  assert_equal "$stderr" "fleet-is-home: the inventory's fleet_state_host typo.lan names no machine in the inventory, so old-main stands down"
}

@test "a roster fetched within FLEET_ROSTER_MAX_SECS is read as it is, with no fetch" {
  home_config_fixture
  export -f project_repo_path
  roster_names state.lan
  git -C "$HC" fetch -q forgejo
  touch "$(_fh_stamp "$HC")"
  roster_names razer-laptop.lan   # on the forge, not yet fetched
  local before; before=$(git -C "$HC" rev-parse forgejo/master)
  run "$REPO_ROOT/.local/bin/fleet-is-home"
  assert_success
  assert_equal "$(git -C "$HC" rev-parse forgejo/master)" "$before"
}

@test "a machine back from being off, whose stale roster names it, reads the other home the forge names and forwards" {
  home_config_fixture
  export -f project_repo_path
  roster_names state.lan
  run fleet_roster_fetch
  assert_success
  local stale; stale=$(git -C "$HC" rev-parse forgejo/master)
  assert_equal "$(git -C "$HC" show "$stale:ansible/inventory.yml" | grep -c 'fleet_state_host: state.lan')" 1
  roster_names razer-laptop.lan   # merged on the forge while this machine was off
  touch -d "@$(($(date +%s) - FLEET_ROSTER_MAX_SECS - 1))" "$(_fh_stamp "$HC")"
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-is-home"
  assert_failure 1
  assert_equal "$stderr" "fleet-is-home: state is not the fleet home; the inventory's fleet_state_host is razer-laptop.lan"
  run fleet_is_home
  assert_failure
  echo 'listed on razer' > "$NOTES_FIXTURE/ssh.out"
  jq -n --arg hc "$HC" '{paths: {($hc): "home-config"}}' > "$SANDBOX/map.json"   # agent-queue resolves home-config itself
  touch -d "@$(($(date +%s) - FLEET_ROSTER_MAX_SECS - 1))" "$(_fh_stamp "$HC")"
  git -C "$HC" update-ref refs/remotes/forgejo/master "$stale"   # stale again, naming this machine
  PROJECT_MAP_FILE="$SANDBOX/map.json" run "$REPO_ROOT/.local/bin/agent-queue" list
  assert_success
  assert_output 'listed on razer'
  assert_called 'razer-laptop.lan PATH="$HOME/.local/bin:$PATH" exec env -u AGENT_STATE_HOST AGENT_STATE_LOCAL=1 agent-queue list  <<none'
  [ ! -d "$HOME/.agent/queue" ] || fail "wrote a local queue"
}

@test "a reader that comes while another fetches the stale roster waits for it and reads the home it fetched" {
  home_config_fixture
  roster_names state.lan
  fleet_roster_fetch
  roster_names razer-laptop.lan
  local stamp; stamp=$(_fh_stamp "$HC")
  touch -d "@$(($(date +%s) - FLEET_ROSTER_MAX_SECS - 1))" "$stamp"
  mkfifo "$SANDBOX/held" "$SANDBOX/go" "$SANDBOX/at-lock"
  local real; real=$(command -v flock)
  # The first reader holds the lock and fetches only once the second has reached the lock.
  ( exec 9>>"$stamp.lock"; "$real" 9; echo held > "$SANDBOX/held"; read -r _ < "$SANDBOX/go"; fleet_roster_fetch ) &
  read -r _ < "$SANDBOX/held"
  stub flock "echo at-lock > '$SANDBOX/at-lock'; exec '$real' \"\$@\""
  ( unset FLEET_HOSTS_JSON; fleet_state_addr > "$SANDBOX/second" ) &
  local second=$!
  read -r _ < "$SANDBOX/at-lock"
  echo go > "$SANDBOX/go"
  wait "$second"
  wait
  assert_equal "$(cat "$SANDBOX/second")" razer-laptop.lan
}

@test "a stale roster whose fetch fails is read as it is, and fetched again only after FLEET_ROSTER_RETRY_SECS" {
  home_config_fixture
  git -C "$HC" remote set-url forgejo "$SANDBOX/gone.git"
  run --separate-stderr fleet_hosts
  assert_success
  assert_output ''
  assert_equal "$stderr" "fleet-hosts: fetching forgejo/master in $HC failed, so the roster is as last fetched"
  run --separate-stderr fleet_hosts
  assert_success
  assert_equal "$stderr" ''
  git -C "$HC" remote set-url forgejo "$SANDBOX/up.git"
  touch -d "@$(($(date +%s) - FLEET_ROSTER_RETRY_SECS))" "$(_fh_stamp "$HC").failed"   # the retry window has passed
  assert_equal "$(fleet_host razer-laptop | jq -r .dest)" 192.0.2.26
}

@test "the singleton units carry the fleet-is-home condition, and so write the store here" {
  for u in fleet-state agent-ask-deliver; do
    grep -qx 'ExecCondition=%h/.local/bin/fleet-is-home' "$REPO_ROOT/.config/systemd/user/$u.service" ||
      fail "$u.service has no fleet-is-home ExecCondition"
    grep -qx 'Environment=AGENT_STATE_LOCAL=1' "$REPO_ROOT/.config/systemd/user/$u.service" ||
      fail "$u.service does not set AGENT_STATE_LOCAL=1"
  done
}

@test "wt new --host opens the session on the worker, detached, with the launch command, and prints its name" {
  printf 'fetching\ngame-agent-3\n' > "$NOTES_FIXTURE/ssh.out"
  WT_NEW_CMD='claude --model opus' run "$REPO_ROOT/.local/src/tmux/worktree.sh" new --host hp-victus --server lab --detach -c /abs/game
  assert_success
  assert_output 'game-agent-3'
  assert_called 'exec env WT_NEW_CMD=claude\ --model\ opus wt new --detach -c /abs/game --server lab  <<none'
  echo 255 > "$NOTES_FIXTURE/ssh.rc"
  run "$REPO_ROOT/.local/src/tmux/worktree.sh" new --host hp-victus -c /abs/game
  assert_failure
  assert_output --partial 'could not open a session on hp-victus'
}

# home_config_fixture: a forge (bare repo) whose master holds a roster with razer-laptop placed, and
# a checkout ($HC) cloned before that commit, so its tree and remote-tracking ref both lag.
home_config_fixture() {
  HC="$SANDBOX/home-config"
  local up="$SANDBOX/up.git" pusher="$SANDBOX/pusher" g=(-c user.name=t -c user.email=t@t)
  git init -q --bare -b master "$up"
  git init -q -b master "$pusher"
  git -C "$pusher" remote add forgejo "$up"
  mkdir -p "$pusher/ansible"
  printf 'all:\n  children:\n    fleet_workers:\n      hosts: {}\n' > "$pusher/ansible/inventory.yml"
  git -C "$pusher" add ansible
  git -C "$pusher" "${g[@]}" commit -qm one
  git -C "$pusher" push -q forgejo master
  git clone -q -o forgejo "$up" "$HC"
  printf 'all:\n  children:\n    fleet_workers:\n      hosts:\n        razer-laptop:\n          ansible_host: 192.0.2.26\n          fleet_place: true\n' > "$pusher/ansible/inventory.yml"
  git -C "$pusher" "${g[@]}" commit -qam two
  git -C "$pusher" push -q forgejo master
  unset FLEET_INVENTORY FLEET_HOSTS_JSON
  export HC
  project_repo_path() { printf '%s' "$HC"; }
}

# roster_names <addr>: push a roster to the fixture's forge whose fleet_state_host is <addr>.
roster_names() {
  printf 'all:\n  children:\n    fleet_workers:\n      hosts:\n        razer-laptop:\n          fleet_state_host: %s\n' "$1" > "$SANDBOX/pusher/ansible/inventory.yml"
  git -C "$SANDBOX/pusher" -c user.name=t -c user.email=t@t commit -qam "home $1"
  git -C "$SANDBOX/pusher" push -q forgejo master
}

@test "the roster is home-config's mainline as last fetched, never its working tree, whatever branch it is on" {
  home_config_fixture
  git -C "$HC" checkout -q -b feature
  touch "$(_fh_stamp "$HC")"   # fetched just now, so the read does not fetch
  run fleet_hosts
  assert_success
  assert_output ''
  run fleet_roster_fetch
  assert_success
  assert_equal "$(fleet_host razer-laptop | jq -r '"\(.dest) \(.place)"')" '192.0.2.26 true'
  assert_equal "$(fleet_inventory)" "$HC forgejo/master:ansible/inventory.yml"
  grep -q 'hosts: {}' "$HC/ansible/inventory.yml"
}

@test "a checkout with no tracked mainline, or a fetch that fails, is said on stderr; no roster comes from the tree" {
  home_config_fixture
  git -C "$HC" remote set-url forgejo "$SANDBOX/gone.git"
  run --separate-stderr fleet_roster_fetch
  assert_failure 1
  assert_equal "$stderr" "fleet-hosts: fetching forgejo/master in $HC failed, so the roster is as last fetched"
  git -C "$HC" branch -q --unset-upstream master
  run --separate-stderr fleet_hosts
  assert_success
  assert_output ''
  assert_equal "$stderr" "fleet-hosts: $HC has no main or master tracking a remote, so the fleet roster reads as empty"
}

@test "a worker's panel rows carry the worker and a host@ target; a gap (3) still prints, a down worker (255) prints none" {
  printf '%s\n' '{"target":"lab/dotfiles:1","pane":"lab/%3","session_id":"s1"}' 'not json' > "$NOTES_FIXTURE/ssh.out"
  run fleet_host_panel hp-victus
  assert_success
  assert_output '{"target":"hp-victus@lab/dotfiles:1","pane":"lab/%3","session_id":"s1","host":"hp-victus"}'
  assert_called 'kb@192.0.2.30 PATH="$HOME/.local/bin:$PATH" exec env agent-panel list --json  <<none'
  echo 3 > "$NOTES_FIXTURE/ssh.rc"
  run fleet_host_panel hp-victus
  assert_failure 3
  assert_output --partial '"host":"hp-victus"'
  echo 255 > "$NOTES_FIXTURE/ssh.rc"
  run fleet_host_panel hp-victus
  assert_failure 255
  assert_output ''
}

@test "a session's worker row is the first worker listing it; this machine is never asked, and a down worker is skipped" {
  export FLEET_HOST=razer-laptop
  # hp-victus lists s1; razer-laptop (this machine) would too, but is never asked.
  stub ssh 'echo "ssh $*" >> "$NOTES_FIXTURE/calls.log"
case "$*" in *192.0.2.30*) [ -f "$NOTES_FIXTURE/hp.down" ] && exit 255; echo "{\"target\":\"lab/d:1\",\"pane\":\"lab/%9\",\"session_id\":\"s1\"}" ;; *) echo "{\"target\":\"lab/r:1\",\"session_id\":\"s1\"}" ;; esac'
  run fleet_panel_row s1
  assert_success
  assert_output '{"target":"hp-victus@lab/d:1","pane":"lab/%9","session_id":"s1","host":"hp-victus"}'
  assert_not_called '192.0.2.26'
  run fleet_panel_row s2
  assert_success
  assert_output ''
  touch "$NOTES_FIXTURE/hp.down"
  run fleet_panel_row s1
  assert_success
  assert_output ''
  run fleet_panel_row ''
  assert_output ''
}

@test "a published snapshot answers fleet_panel_row with no ssh; this machine's rows are skipped" {
  export FLEET_HOST=razer-laptop
  printf '%s\n' '{"target":"razer-laptop@lab/r:1","pane":"lab/%1","session_id":"s1","host":"razer-laptop"}' \
    '{"target":"hp-victus@lab/d:1","pane":"lab/%9","session_id":"s1","host":"hp-victus"}' \
    '{"target":"hp-victus@lab/d:2","pane":"lab/%8","session_id":"s2","host":"hp-victus"}' | fleet_panel_publish 180
  assert_equal "$(jq -c '[.ttl, (.rows | length)]' "$(fleet_panel_file)")" '[180,3]'
  run fleet_panel_row s1
  assert_success
  assert_output '{"target":"hp-victus@lab/d:1","pane":"lab/%9","session_id":"s1","host":"hp-victus"}'
  run fleet_panel_row nobody
  assert_success
  assert_output ''
  assert_not_called 'ssh'
}

@test "a worker the snapshot names silent is asked live, so its session is not read as gone" {
  export FLEET_HOST=razer-laptop
  printf '%s\n' '{"target":"razer-laptop@lab/r:1","pane":"lab/%1","session_id":"s1","host":"razer-laptop"}' |
    fleet_panel_publish 180 hp-victus
  assert_equal "$(jq -c .silent "$(fleet_panel_file)")" '["hp-victus"]'
  stub ssh 'echo "ssh $*" >> "$NOTES_FIXTURE/calls.log"
echo "{\"target\":\"lab/d:1\",\"pane\":\"lab/%9\",\"session_id\":\"s2\"}"'
  run fleet_panel_row s2
  assert_success
  assert_output --partial '"host":"hp-victus"'
  assert_called '192.0.2.30'
  # A session the snapshot lists is answered from it; the silent worker is not asked.
  : > "$NOTES_FIXTURE/calls.log"
  export FLEET_HOST=state
  run fleet_panel_row s1
  assert_output --partial '"host":"razer-laptop"'
  assert_not_called '192.0.2.30'
}

@test "an empty snapshot is a fresh answer: no worker has the session, and none is asked" {
  : | fleet_panel_publish 180
  run fleet_panel_row s1
  assert_success
  assert_output ''
  assert_not_called 'ssh'
}

@test "with no snapshot, or one past its ttl, fleet_panel_row asks every peer, not only up to the first that has it" {
  export FLEET_HOST=razer-laptop
  stub ssh 'echo "ssh $*" >> "$NOTES_FIXTURE/calls.log"
echo "{\"target\":\"lab/d:1\",\"pane\":\"lab/%9\",\"session_id\":\"s1\"}"'
  run fleet_panel_row s1
  assert_success
  assert_output '{"target":"hp-victus@lab/d:1","pane":"lab/%9","session_id":"s1","host":"hp-victus"}'
  assert_called '192.0.2.30'
  # The snapshot is old by its own ttl: the same walk, not its rows.
  mkdir -p "$(dirname "$(fleet_panel_file)")"
  printf '{"at":%s,"ttl":60,"rows":[]}\n' "$(($(date +%s) - 61))" > "$(fleet_panel_file)"
  : > "$NOTES_FIXTURE/calls.log"
  run fleet_panel_row s1
  assert_output --partial '"host":"hp-victus"'
  assert_called '192.0.2.30'
  # Both peers answer at once, and the first in roster order wins.
  export FLEET_HOST=state
  : > "$NOTES_FIXTURE/calls.log"
  run fleet_panel_row s1
  assert_output --partial '"host":"razer-laptop"'
  assert_called '192.0.2.26'
  assert_called '192.0.2.30'
}

@test "fleet-host-run runs one command on a worker through the one ssh path and exits with its code" {
  run "$REPO_ROOT/.local/bin/fleet-host-run" hp-victus
  assert_failure 2
  assert_output --partial 'usage: fleet-host-run'
  echo hi > "$NOTES_FIXTURE/ssh.out"
  run "$REPO_ROOT/.local/bin/fleet-host-run" hp-victus agent-panel send --pane 'lab/%3' -- 'a; b'
  assert_success
  assert_output hi
  assert_called 'agent-panel send --pane lab/%3 -- a\;\ b'
  run "$REPO_ROOT/.local/bin/fleet-host-run" nobody true
  assert_failure 255
}
