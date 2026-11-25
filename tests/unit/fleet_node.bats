#!/usr/bin/env bats
# fleet-node signin / ready / ready claude: the list of what only the human can do on a node, the
# lease check that says what a peer lacks to run every singleton lane, and the sign-in check
# fleet-dispatch's kit runs over ssh. A node that reads ready while it lacks one gets sessions that
# sit at the login prompt, or a lease it cannot serve, so both directions are pinned.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  FLEET_NODE="$REPO_ROOT/.local/bin/fleet-node"
  unset GH_CONFIG_DIR KUBECONFIG CODEX_HOME RBW_PROFILE
  export CLAUDE_ACCT_CONFIG="$REPO_ROOT/.config/claude-acct/accounts"
  export CLAUDE_ACCT_TOKEN_DIR="$SANDBOX/tokens"
  # rbw is locked here, so claude-acct reads the copy `token push` leaves in the token dir.
  printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/bin/rbw" && chmod +x "$SANDBOX/bin/rbw"
  export DOTFILES_DIR="$HOME/.dotfiles" DOTFILES_PRIVATE="$HOME/.dotfiles-private" DOTFILES_AUTOPULL_LOCK_SECS=0
  export STORE_SYNC_CONF="$SANDBOX/store.env" FLEET_KUBECONFIG_SCOPED="$SANDBOX/scoped-kubeconfig"
  # No roster unless a test writes one, so this node reads as the workstation, never a fleet worker.
  export FLEET_INVENTORY="$SANDBOX/inventory.yml" FLEET_HOST=node1
}

# sign_in_all -> a token for every account, gh, the overlay and codex present.
sign_in_all() {
  local name dir
  mkdir -p "$CLAUDE_ACCT_TOKEN_DIR"
  while read -r name dir; do
    case "$name" in '' | '#'*) continue ;; esac
    printf 'sk-ant-oat01-%s' "$name" >"$CLAUDE_ACCT_TOKEN_DIR/$name"
  done <"$CLAUDE_ACCT_CONFIG"
  mkdir -p "$HOME/.config/gh" "$HOME/.dotfiles-private/.git" "$HOME/.codex"
  echo 'github.com: {}' >"$HOME/.config/gh/hosts.yml"
  echo '{}' >"$HOME/.codex/auth.json"
}

# lease_ready_all -> signed in, both store remotes reachable (local bare repos), a scoped kubeconfig
# whose every can-i is yes (unless its args match a word in $SANDBOX/can-i-no), and agent-web with its
# files. kubectl logs each call.
lease_ready_all() {
  sign_in_all
  git init -q --bare "$SANDBOX/origin.git"
  git init -q --bare "$SANDBOX/backup.git"
  printf 'STORE_PRIMARY_URL=%q\nSTORE_BACKUP_URL=%q\n' "$SANDBOX/origin.git" "$SANDBOX/backup.git" >"$STORE_SYNC_CONF"
  echo 'apiVersion: v1' >"$FLEET_KUBECONFIG_SCOPED"
  cat >"$SANDBOX/bin/kubectl" <<EOF
#!/usr/bin/env bash
echo "KUBECONFIG=\$KUBECONFIG \$*" >>"$SANDBOX/kubectl.log"
[ -e "$SANDBOX/kube-down" ] && { echo 'error: the server is unreachable' >&2; exit 1; }
[ -e "$SANDBOX/kube-silent" ] && exit 7
case "\$*" in *"list nodes"*) echo "Warning: resource 'nodes' is not namespace scoped" >&2 ;; esac
for no in \$(cat "$SANDBOX/can-i-no" 2>/dev/null); do case "\$*" in *"\$no"*) echo no; exit 1 ;; esac; done
echo yes
EOF
  mkdir -p "$HOME/.local/bin" "$HOME/.config/agent-web" "$HOME/.config/systemd/user"
  # One can-i per KUBE_NEEDS entry, counted from fleet-node itself.
  N_NEEDS=$(sed -n '/^KUBE_NEEDS=(/,/^)/p' "$FLEET_NODE" | grep -c '^  "')
  printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/agent-web"
  chmod +x "$SANDBOX/bin/kubectl" "$HOME/.local/bin/agent-web"
  echo '{}' >"$HOME/.config/agent-web/oauth.json"
  : >"$HOME/.config/agent-web/env"
  : >"$HOME/.config/systemd/user/agent-web.service"
}

@test "a fresh node lists every sign-in, and both ready checks fail" {
  # An FQDN nodename, so the hint is seen to name the node by its short name.
  printf '#!/bin/sh\n[ "$1" = -n ] && echo node1.example.lan || exec /usr/bin/uname "$@"\n' >"$SANDBOX/bin/uname" && chmod +x "$SANDBOX/bin/uname"
  run "$FLEET_NODE" signin
  assert_failure 1
  assert_output --partial "sign in account main: from a machine with rbw unlocked, claude-acct token push node1"
  refute_output --partial 'node1.example'
  assert_output --partial 'sign in account alt:'
  assert_output --partial 'sign in to GitHub: gh auth login'
  assert_output --partial 'clone the private overlay'
  assert_output --partial 'sign in to codex: codex login'
  # rbw stays on the workstation, so neither check asks a node for it.
  refute_output --partial 'rbw login'
  run "$FLEET_NODE" ready claude
  assert_failure
  assert_output ''
  run "$FLEET_NODE" ready
  assert_failure 1
  assert_output --partial 'sign in account main:'
  refute_output --partial 'rbw login'
  assert_output --partial 'no store remotes in'
  assert_output --partial 'agent-web is not installed'
}

@test "a node with every need prints nothing and is ready" {
  lease_ready_all
  run "$FLEET_NODE" signin
  assert_success
  assert_output ''
  run "$FLEET_NODE" ready claude
  assert_success
  run "$FLEET_NODE" ready
  assert_success
  assert_output ''
  # Every can-i went to home-k3s through the scoped kubeconfig, never kubectl's own.
  run grep -c "^KUBECONFIG=$FLEET_KUBECONFIG_SCOPED --context home-k3s .*auth can-i" "$SANDBOX/kubectl.log"
  assert_output "$N_NEEDS"
}

@test "one account with no token is enough to fail ready claude" {
  sign_in_all
  rm "$CLAUDE_ACCT_TOKEN_DIR/alt"
  run "$FLEET_NODE" signin
  assert_failure 1
  assert_output --partial 'sign in account alt:'
  refute_output --partial 'account main'
  run "$FLEET_NODE" ready claude
  assert_failure
}

@test "a token file that is not a token does not count as signed in" {
  sign_in_all
  echo junk >"$CLAUDE_ACCT_TOKEN_DIR/bnb"
  run "$FLEET_NODE" ready claude
  assert_failure
}

@test "ready claude asks only for the accounts; ready asks for every sign-in" {
  lease_ready_all
  rm -rf "$HOME/.config/gh" "$HOME/.codex"
  run "$FLEET_NODE" ready claude
  assert_success
  run "$FLEET_NODE" signin
  assert_failure 1
  run "$FLEET_NODE" ready
  assert_failure 1
  assert_output --partial 'sign in to GitHub: gh auth login'
  assert_output --partial 'sign in to codex: codex login'
}

@test "codex is read from CODEX_HOME when it is set" {
  lease_ready_all
  mv "$HOME/.codex" "$HOME/codexhome"
  CODEX_HOME="$HOME/codexhome" run "$FLEET_NODE" signin
  assert_success
}

@test "a fleet worker is asked for codex only when its fleet_harnesses names it" {
  sign_in_all
  rm -r "$HOME/.codex"
  printf 'all:\n  children:\n    fleet_workers:\n      hosts:\n        node1:\n          ansible_host: 192.0.2.5\n          fleet_harnesses: [nim]\n' >"$FLEET_INVENTORY"
  run "$FLEET_NODE" signin
  assert_success
  sed -i 's/\[nim\]/[nim, codex]/' "$FLEET_INVENTORY"
  run "$FLEET_NODE" signin
  assert_failure 1
  assert_output 'sign in to codex: codex login'
}

@test "gh is read from GH_CONFIG_DIR when it is set" {
  sign_in_all
  rm "$HOME/.config/gh/hosts.yml"
  mkdir -p "$HOME/ghc" && echo 'github.com: {}' >"$HOME/ghc/hosts.yml"
  GH_CONFIG_DIR="$HOME/ghc" run "$FLEET_NODE" signin
  assert_success
}

@test "a missing accounts file is not ready" {
  sign_in_all
  CLAUDE_ACCT_CONFIG="$SANDBOX/none" run "$FLEET_NODE" ready claude
  assert_failure
}

@test "a dotfiles checkout behind origin/main is not ready, and names its pull" {
  lease_ready_all
  git init -q --bare "$SANDBOX/dot.git"
  git clone -q "$SANDBOX/dot.git" "$SANDBOX/work" 2>/dev/null
  git -C "$SANDBOX/work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
  git -C "$SANDBOX/work" push -q origin HEAD:main
  git clone -q -b main "$SANDBOX/dot.git" "$DOTFILES_DIR"
  GIT_COMMITTER_DATE='2026-01-01T00:00:00' git -C "$SANDBOX/work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
  git -C "$SANDBOX/work" push -q origin HEAD:main
  run "$FLEET_NODE" ready
  assert_failure 1
  # ready fetched first, so the commit pushed after the clone counts.
  assert_output --partial "$DOTFILES_DIR is behind origin/main (1 commit(s)"
  assert_output --partial "dotfiles-autopull --now $DOTFILES_DIR"
  git -C "$DOTFILES_DIR" merge -q --ff-only origin/main
  run "$FLEET_NODE" ready
  assert_success
}

@test "a store remote it cannot reach is not ready, the other still counts" {
  lease_ready_all
  printf 'STORE_PRIMARY_URL=%q\nSTORE_BACKUP_URL=%q\n' "$SANDBOX/origin.git" "$SANDBOX/gone.git" >"$STORE_SYNC_CONF"
  run "$FLEET_NODE" ready
  assert_failure 1
  assert_output --partial "cannot reach the backup store remote ($SANDBOX/gone.git)"
  refute_output --partial 'origin store remote'
}

@test "a home-k3s call the kubeconfig may not make is named with its lane" {
  lease_ready_all
  echo 'deployments' >"$SANDBOX/can-i-no"
  run "$FLEET_NODE" ready
  assert_failure 1
  assert_output --partial "may not get deployments -n binks-api: release-state reads what is deployed"
  refute_output --partial 'list nodes'
  refute_output --partial 'Warning'
}

@test "a cluster it cannot ask is one line, not one per call" {
  lease_ready_all
  touch "$SANDBOX/kube-down"
  run "$FLEET_NODE" ready
  assert_failure 1
  assert_output "cannot ask home-k3s with the kubeconfig at $FLEET_KUBECONFIG_SCOPED: error: the server is unreachable"
}

@test "a kubectl that answers nothing says so with its exit code" {
  lease_ready_all
  touch "$SANDBOX/kube-silent"
  run "$FLEET_NODE" ready
  assert_failure 1
  assert_output "cannot ask home-k3s with the kubeconfig at $FLEET_KUBECONFIG_SCOPED: no answer (kubectl exit 7)"
}

@test "with no scoped kubeconfig it asks with kubectl's own" {
  lease_ready_all
  rm "$FLEET_KUBECONFIG_SCOPED"
  mkdir -p "$HOME/.kube" && echo 'apiVersion: v1' >"$HOME/.kube/config"
  run "$FLEET_NODE" ready
  assert_success
  run grep -c "^KUBECONFIG=$HOME/.kube/config --context home-k3s" "$SANDBOX/kubectl.log"
  assert_output "$N_NEEDS"
}

@test "agent-web's missing pieces are each named" {
  lease_ready_all
  rm "$HOME/.local/bin/agent-web" "$HOME/.config/agent-web/oauth.json" "$HOME/.config/agent-web/env"
  run "$FLEET_NODE" ready
  assert_failure 1
  assert_output --partial 'agent-web is not installed'
  assert_output --partial 'oauth.json'
  assert_output --partial "agent-web's unit and env file are not stowed"
}

@test "ready with an unknown argument is a usage error, not a full check" {
  run "$FLEET_NODE" ready bogus
  assert_failure 2
  assert_output --partial 'usage: fleet-node ready [claude]'
}

@test "an unknown verb is a usage error" {
  run "$FLEET_NODE" bogus
  assert_failure 2
  assert_output --partial 'usage: fleet-node'
}

@test "fleet-dispatch's kit runs fleet-node ready claude from its own checkout, so no restow is needed" {
  run grep -c '"\$HERE/fleet-node" ready claude' "$REPO_ROOT/.local/bin/fleet-dispatch"
  assert_output 1
}
