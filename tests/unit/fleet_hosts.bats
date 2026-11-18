#!/usr/bin/env bats
# fleet-hosts.sh: the fleet worker roster read from the home-config inventory, and the one ssh path
# to a worker. ssh is a stub that logs its arguments; nothing leaves the sandbox.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_INVENTORY="$SANDBOX/inventory.yml"
  cat > "$FLEET_INVENTORY" <<'EOF'
all:
  vars:
    ansible_user: kb
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
  assert_line --index 0 "{\"name\": \"razer-laptop\", \"dest\": \"kb@192.0.2.26\", \"port\": 22, \"max_live\": 2, \"place\": false, \"repos\": [\"$HOME/.dotfiles\", \"/abs/game\"], \"power\": \"\", \"first\": []}"
  assert_equal "$(fleet_host hp-victus | jq -r '"\(.dest) \(.port) \(.max_live) \(.place)"')" 'kb@192.0.2.30 2222 1 true'
  run fleet_host laptop
  assert_failure
}

@test "a cloud worker is reached by fleet_ssh_host, not its ansible_host instance id, and carries its fleet_power" {
  sed -i 's/^          fleet_place: true$/&\n          ansible_host: i-0123456789abcdef0\n          fleet_ssh_host: hp-victus.tail.example\n          fleet_power: governor/' "$FLEET_INVENTORY"
  assert_equal "$(fleet_host hp-victus | jq -r '"\(.dest) \(.power)"')" 'kb@hp-victus.tail.example governor'
  assert_equal "$(fleet_host razer-laptop | jq -r '"\(.dest) [\(.power)]"')" 'kb@192.0.2.26 []'
}

@test "a worker's fleet_first is the item classes it takes ahead of the dispatcher; none is an empty list" {
  sed -i 's/^          fleet_place: true$/&\n          fleet_first: [canary, night]/' "$FLEET_INVENTORY"
  assert_equal "$(fleet_host hp-victus | jq -c .first)" '["canary","night"]'
  assert_equal "$(fleet_host razer-laptop | jq -c .first)" '[]'
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

@test "a roster fetched within FLEET_ROSTER_MAX_SECS is read as it is, with no fetch" {
  home_config_fixture
  export -f project_repo_path
  roster_lists old-worker
  git -C "$HC" fetch -q forgejo
  touch "$(_fh_stamp "$HC")"
  roster_lists new-worker   # on the forge, not yet fetched
  local before; before=$(git -C "$HC" rev-parse forgejo/master)
  assert_equal "$(fleet_hosts | jq -r .name)" old-worker
  assert_equal "$(git -C "$HC" rev-parse forgejo/master)" "$before"
}

@test "a machine back from being off reads the roster the forge has now, not the one it last fetched" {
  home_config_fixture
  roster_lists old-worker
  run fleet_roster_fetch
  assert_success
  roster_lists new-worker   # merged on the forge while this machine was off
  touch -d "@$(($(date +%s) - FLEET_ROSTER_MAX_SECS - 1))" "$(_fh_stamp "$HC")"
  unset FLEET_HOSTS_JSON
  assert_equal "$(fleet_hosts | jq -r .name)" new-worker
}

@test "a reader that comes while another fetches the stale roster waits for it and reads what it fetched" {
  home_config_fixture
  roster_lists old-worker
  fleet_roster_fetch
  roster_lists new-worker
  local stamp; stamp=$(_fh_stamp "$HC")
  touch -d "@$(($(date +%s) - FLEET_ROSTER_MAX_SECS - 1))" "$stamp"
  mkfifo "$SANDBOX/held" "$SANDBOX/go" "$SANDBOX/at-lock"
  local real; real=$(command -v flock)
  # The first reader holds the lock and fetches only once the second has reached the lock.
  ( exec 9>>"$stamp.lock"; "$real" 9; echo held > "$SANDBOX/held"; read -r _ < "$SANDBOX/go"; fleet_roster_fetch ) &
  read -r _ < "$SANDBOX/held"
  stub flock "echo at-lock > '$SANDBOX/at-lock'; exec '$real' \"\$@\""
  ( unset FLEET_HOSTS_JSON; fleet_hosts | jq -r .name > "$SANDBOX/second" ) &
  local second=$!
  read -r _ < "$SANDBOX/at-lock"
  echo go > "$SANDBOX/go"
  wait "$second"
  wait
  assert_equal "$(cat "$SANDBOX/second")" new-worker
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

# roster_lists <worker>: push a roster to the fixture's forge that lists that one worker.
roster_lists() {
  printf 'all:\n  children:\n    fleet_workers:\n      hosts:\n        %s: {}\n' "$1" > "$SANDBOX/pusher/ansible/inventory.yml"
  git -C "$SANDBOX/pusher" -c user.name=t -c user.email=t@t commit -qam "roster $1"
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
