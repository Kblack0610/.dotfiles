#!/usr/bin/env bats
# fleet-hosts.sh: the fleet worker roster read from the home-config inventory, the one ssh path to
# a worker, and the forwarding that keeps a remote session's queue and ask writes on the state host.
# ssh is a stub that logs its arguments; nothing leaves the sandbox.

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
    fleet_state_host: state.lan
  children:
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
  assert_line --index 0 "{\"name\": \"razer-laptop\", \"dest\": \"kb@192.0.2.26\", \"port\": 22, \"max_live\": 2, \"place\": false, \"repos\": [\"$HOME/.dotfiles\", \"/abs/game\"], \"state_host\": \"state.lan\"}"
  assert_equal "$(fleet_host hp-victus | jq -r '"\(.dest) \(.port) \(.max_live) \(.place)"')" 'kb@192.0.2.30 2222 1 true'
  run fleet_host laptop
  assert_failure
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
  assert_called "ssh -n -o BatchMode=yes -o ConnectTimeout=5 -p 2222 kb@192.0.2.30 PATH=\"\$HOME/.local/bin:\$PATH\" exec env printf %s\\\\n a\\ b it\\'s  <<none"
  run fleet_host_run nowhere true
  assert_failure 255
  assert_output --partial 'nowhere is not in fleet_workers'
}

@test "state_forward does nothing without AGENT_STATE_HOST" {
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
  assert_called 'ssh -n -o BatchMode=yes -o ConnectTimeout=5 state.lan PATH="$HOME/.local/bin:$PATH" exec env -u AGENT_STATE_HOST AGENT_QUEUE_ITEM=fix-menu agent-queue set fix-menu pr=12  <<none'
  assert_not_called TMUX
  [ ! -d "$HOME/.agent/queue" ] || fail "wrote a local queue"
  # `add` reads its task from stdin, so that verb keeps it.
  run bash -c 'echo "the task" | "$0" add --project game' "$REPO_ROOT/.local/bin/agent-queue"
  assert_success
  assert_called 'agent-queue add --project game  <<the task'
}

@test "an unreachable state host is named, nothing is written here, and ssh's 255 comes back" {
  export AGENT_STATE_HOST=state.lan
  echo 255 > "$NOTES_FIXTURE/ssh.rc"
  run "$REPO_ROOT/.local/bin/agent-ask" list
  assert_failure 255
  assert_output --partial 'the state host state.lan did not answer over ssh; nothing was written'
  assert_called 'exec env -u AGENT_STATE_HOST agent-ask list  <<none'
  [ -z "$(ls -A "$HOME/.agent/asks")" ] || fail "wrote local asks"
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
