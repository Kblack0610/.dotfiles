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
  assert_line --index 0 "{\"name\": \"razer-laptop\", \"dest\": \"kb@192.0.2.26\", \"port\": 22, \"max_live\": 2, \"place\": false, \"repos\": [\"$HOME/.dotfiles\", \"/abs/game\"], \"first\": [], \"harnesses\": [], \"agent_cpus\": \"\", \"local\": false}"
  assert_equal "$(fleet_host hp-victus | jq -r '"\(.dest) \(.port) \(.max_live) \(.place)"')" 'kb@192.0.2.30 2222 1 true'
  run fleet_host laptop
  assert_failure
}

@test "a cloud worker is reached by fleet_ssh_host, not its ansible_host instance id" {
  sed -i 's/^          fleet_place: true$/&\n          ansible_host: i-0123456789abcdef0\n          fleet_ssh_host: hp-victus.tail.example/' "$FLEET_INVENTORY"
  assert_equal "$(fleet_host hp-victus | jq -r .dest)" 'kb@hp-victus.tail.example'
  assert_equal "$(fleet_host razer-laptop | jq -r .dest)" 'kb@192.0.2.26'
}

@test "a worker's fleet_first is the item classes it takes ahead of the dispatcher; a single class is a one-item list" {
  sed -i 's/^          fleet_place: true$/&\n          fleet_first: [canary]/' "$FLEET_INVENTORY"
  sed -i 's/^          fleet_max_live: 2$/&\n          fleet_first: canary/' "$FLEET_INVENTORY"
  assert_equal "$(fleet_host hp-victus | jq -c .first)" '["canary"]'
  assert_equal "$(fleet_host razer-laptop | jq -c .first)" '["canary"]'
}

@test "a worker's fleet_harnesses is the headless harnesses it runs besides claude; a single one is a one-item list" {
  sed -i 's/^          fleet_place: true$/&\n          fleet_harnesses: [nim, ocfree]/' "$FLEET_INVENTORY"
  sed -i 's/^          fleet_max_live: 2$/&\n          fleet_harnesses: nim/' "$FLEET_INVENTORY"
  assert_equal "$(fleet_host hp-victus | jq -c .harnesses)" '["nim","ocfree"]'
  assert_equal "$(fleet_host razer-laptop | jq -c .harnesses)" '["nim"]'
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
  assert_called "ssh -n -T -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p 2222 kb@192.0.2.30 PATH=\"\$HOME/.local/bin:\$PATH\" LANG=\"\${LANG:-C.UTF-8}\" exec env 'printf' '%s\\n' 'a b' 'it'\\''s'  <<none"
  run fleet_host_run nowhere true
  assert_failure 255
  assert_output --partial 'nowhere is not in fleet_workers'
}

@test "a worker whose login shell is zsh, sh or bash reads every argument back literally, a leading = included" {
  # razer-laptop's login shell is zsh, where a bare =word is the path of a command: printf %q left
  # `has-session -t =<name>` bare, it exited 1 there, and reap read every session on it as gone.
  # This ssh runs the command line it was handed in $LOGIN_SH, as sshd does in the login shell.
  printf '#!/usr/bin/env bash\nexec "$LOGIN_SH" -c "${*: -1}"\n' > "$SANDBOX/bin/ssh"
  chmod +x "$SANDBOX/bin/ssh"
  local sh
  for sh in zsh bash sh; do
    command -v "$sh" >/dev/null || continue
    LOGIN_SH=$sh run fleet_host_run hp-victus printf '[%s]' '=dotfiles-agent-19' "it's" '~/x' '*' 'a b' '$HOME'
    assert_success
    assert_output "[=dotfiles-agent-19][it's][~/x][*][a b][\$HOME]"
  done
}

@test "a worker command gets a UTF-8 LANG when the worker's ssh shell set none, and keeps one it set" {
  # A tmux client with no UTF-8 locale prints a -F format's tabs as `_`: agent-panel on razer-laptop
  # then parsed no pane, and worker-panel.json listed none of its 8 sessions (2026-11-18).
  printf '#!/usr/bin/env bash\nexec env -u LANG -u LC_ALL -u LC_CTYPE ${WORKER_LANG:+LANG="$WORKER_LANG"} sh -c "${*: -2}"\n' > "$SANDBOX/bin/ssh"
  chmod +x "$SANDBOX/bin/ssh"
  run fleet_host_run hp-victus sh -c 'printf "%s\n" "$LANG"'
  assert_success
  assert_output 'C.UTF-8'
  WORKER_LANG=en_US.UTF-8 run fleet_host_run hp-victus sh -c 'printf "%s\n" "$LANG"'
  assert_output 'en_US.UTF-8'
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
  assert_called '-p 2222 kb@192.0.2.30 PATH="$HOME/.local/bin:$PATH" LANG="${LANG:-C.UTF-8}" exec env '\''tmux-close'\'' '\''-L'\'' '\''lab'\'' '\''session'\'' '\''agent-1'\'''
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
  assert_called "exec env 'WT_NEW_CMD=claude --model opus' 'wt' 'new' '--detach' '-c' '/abs/game' '--server' 'lab'  <<none"
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
  # The worker runs the workstation's fleet-worker-panel.sh, sent as text, never a copy of its own.
  assert_called 'kb@192.0.2.30 PATH="$HOME/.local/bin:$PATH" LANG="${LANG:-C.UTF-8}" exec env '\''timeout'\'' '\''45'\'' '\''bash'\'' '\''-c'\'' '\''# shellcheck shell=bash'
  assert_called "wp_main' 'fleet-worker-panel'  <<none"
  echo 3 > "$NOTES_FIXTURE/ssh.rc"
  run fleet_host_panel hp-victus
  assert_failure 3
  assert_output --partial '"host":"hp-victus"'
  echo 255 > "$NOTES_FIXTURE/ssh.rc"
  run fleet_host_panel hp-victus
  assert_failure 255
  assert_output ''
}

@test "wp_main adds each row's checkout facts where the checkout is: gone, outside git, or branch, dirty, ahead, unpushed (ar-3358)" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/agent-merge-proof.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/fleet-worker-panel.sh"
  local o="$SANDBOX/origin.git" w="$HOME/.worktrees/r-agent-1" gitc=(git -c user.email=t@t -c user.name=t)
  git init -q --bare "$o"
  git clone -q "$o" "$SANDBOX/r" 2>/dev/null
  "${gitc[@]}" -C "$SANDBOX/r" commit -q --allow-empty -m init
  git -C "$SANDBOX/r" push -q origin HEAD:main 2>/dev/null
  git -C "$SANDBOX/r" fetch -q origin
  git -C "$SANDBOX/r" remote set-head origin main
  git -C "$SANDBOX/r" worktree add -q -b feat/x "$w" origin/main 2>/dev/null
  echo a > "$w/a.txt"; git -C "$w" add a.txt; "${gitc[@]}" -C "$w" commit -q -m a
  echo b > "$w/b.txt"
  row() { printf '{"target":"lab/%s:1","cwd":"%s"}\n' "$1" "$2"; }
  stub agent-panel "cat <<'EOF'
$(row wt "$w")
$(row gone "$SANDBOX/nowhere")
$(row plain "$SANDBOX")
not json
EOF
exit \"\$(cat \"\$NOTES_FIXTURE/panel.rc\" 2>/dev/null || echo 0)\""
  run wp_main
  assert_success
  assert_line --index 0 "{\"target\":\"lab/wt:1\",\"cwd\":\"$w\",\"git\":{\"in\":1,\"main\":\"$SANDBOX/r\",\"origin\":\"$o\",\"branch\":\"feat/x\",\"head\":\"$(git -C "$w" rev-parse HEAD)\",\"upstream\":\"main\",\"unpushed\":1,\"ahead\":1,\"dirty\":[\"b.txt\"]}}"
  assert_line --index 1 "$(row gone "$SANDBOX/nowhere" | jq -c '. + {git: {in: "gone"}}')"
  assert_line --index 2 "$(row plain "$SANDBOX" | jq -c '. + {git: {in: 0}}')"
  assert_line --index 3 'not json'
  # A credential in an https remote never leaves the worker.
  git -C "$SANDBOX/r" remote set-url origin https://u:tok@example.com/o/r.git
  run wp_git "$w" ''
  assert_output --partial '"origin":"https://example.com/o/r.git"'
  git -C "$SANDBOX/r" remote set-url origin "$o"
  # A read with a gap (3) keeps its rows and its exit; any other failure prints none.
  echo 3 > "$NOTES_FIXTURE/panel.rc"
  run wp_main
  assert_failure 3
  assert_line --index 2 --partial '"git":{"in":0}'
  echo 1 > "$NOTES_FIXTURE/panel.rc"
  run wp_main
  assert_failure 1
  assert_output ''
}

@test "wp_git in a submodule: a pin behind origin/master that the superproject pins counts ahead 0 (ar-2445)" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/agent-merge-proof.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/fleet-worker-panel.sh"
  local gitc=(git -c user.email=t@t -c user.name=t -c protocol.file.allow=always)
  local sup="$HOME/.worktrees/sup"
  local sub="$sup/module"
  git init -q --bare "$SANDBOX/sub.git"
  git clone -q "$SANDBOX/sub.git" "$SANDBOX/subw" 2>/dev/null
  "${gitc[@]}" -C "$SANDBOX/subw" commit -q --allow-empty -m s0
  git -C "$SANDBOX/subw" push -q origin HEAD:master 2>/dev/null

  git init -q -b main "$sup"
  "${gitc[@]}" -C "$sup" commit -q --allow-empty -m init
  git -C "$sup" -c protocol.file.allow=always submodule -q add "$SANDBOX/sub.git" module 2>/dev/null
  "${gitc[@]}" -C "$sup" commit -q -m pin
  git -C "$sup" update-ref refs/remotes/origin/main HEAD

  # Submodule has a pin-merge commit that the superproject's main pins
  git -C "$sub" checkout -q -b pin-merge
  echo 1 > "$sub/f"; "${gitc[@]}" -C "$sub" add f; "${gitc[@]}" -C "$sub" commit -q -m pm
  git -C "$sup" add module; "${gitc[@]}" -C "$sup" commit -q -m 'pin the pin-merge'
  git -C "$sup" update-ref refs/remotes/origin/main HEAD

  # Master in the submodule moves ahead, so the pin is behind master
  "${gitc[@]}" -C "$SANDBOX/subw" commit -q --allow-empty -m s1
  git -C "$SANDBOX/subw" push -q origin HEAD:master 2>/dev/null
  git -C "$sub" fetch -q origin

  run wp_git "$sub" ''
  assert_success
  assert_equal "$(jq -r .ahead <<<"$output")" 0

  # Negative control: an extra unpinned commit counts ahead
  echo 2 > "$sub/extra"; "${gitc[@]}" -C "$sub" add extra; "${gitc[@]}" -C "$sub" commit -q -m extra
  run wp_git "$sub" ''
  assert_success
  assert_equal "$(jq -r .ahead <<<"$output")" 1
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
  assert_called "'agent-panel' 'send' '--pane' 'lab/%3' '--' 'a; b'"
  run "$REPO_ROOT/.local/bin/fleet-host-run" nobody true
  assert_failure 255
}

@test "fleet_cap_hosts: every host that sets agent_cpus, in any group, worker or not" {
  cat >> "$FLEET_INVENTORY" <<'YAML'
          agent_cpus: 1-7,9-15
    desktops2:
      hosts:
        state:
          agent_cpus: 2-15,18-31
YAML
  run fleet_cap_hosts
  assert_success
  assert_equal "$(jq -r '"\(.name) \(.agent_cpus)"' <<<"$output" | sort | paste -sd, -)" 'hp-victus 1-7,9-15,state 2-15,18-31'
  run fleet_hosts
  assert_equal "$(jq -r 'select(.name == "hp-victus") | .agent_cpus' <<<"$output")" 1-7,9-15
}

@test "fleet_cap_hosts: an inventory with no agent_cpus lists nothing" {
  run fleet_cap_hosts
  assert_success
  assert_output ''
}
