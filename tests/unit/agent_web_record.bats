#!/usr/bin/env bats
# agent-web-record: the lease holder points the agents/agents Endpoints at itself. kubectl and ip
# are stubs; kubectl logs each call and answers the record's current address from a file.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  BIN="$REPO_ROOT/.local/bin/agent-web-record"
  export AGENT_WEB_KUBECONFIG="$SANDBOX/kubeconfig"
  echo 'apiVersion: v1' > "$AGENT_WEB_KUBECONFIG"
  echo 10.0.0.9 > "$SANDBOX/record"
  cat > "$SANDBOX/bin/kubectl" <<EOF
#!/usr/bin/env bash
echo "KUBECONFIG=\$KUBECONFIG \$*" >> "$SANDBOX/kubectl.log"
case "\$*" in
  *"config view"*) echo https://10.20.0.10:6443 ;;
  *"get endpoints"*) cat "$SANDBOX/record" ;;
  *"patch endpoints"*) [ ! -e "$SANDBOX/refuse" ] ;;
esac
EOF
  cat > "$SANDBOX/bin/ip" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SANDBOX/ip.log"
echo "10.20.0.10 dev eth0 src 10.20.0.7 uid 1000"
EOF
  chmod +x "$SANDBOX/bin/kubectl" "$SANDBOX/bin/ip"
}

@test "the holder patches the record to its address on the route to the API server" {
  run "$BIN"
  assert_success
  assert_output --partial "the agents Endpoints now reach agent-web at 10.20.0.7:8790 (was 10.0.0.9)"
  grep -q 'route get 10.20.0.10' "$SANDBOX/ip.log"
  grep -qF -- '-n agents patch endpoints agents --type=merge -p {"subsets":[{"addresses":[{"ip":"10.20.0.7"}],"ports":[{"name":"http","port":8790}]}]}' "$SANDBOX/kubectl.log"
}

@test "a record that already names this machine is not patched" {
  echo 10.20.0.7 > "$SANDBOX/record"
  run "$BIN"
  assert_success
  assert_output ""
  run grep -c patch "$SANDBOX/kubectl.log"
  assert_output 0
}

@test "a refused patch fails the step and says so" {
  touch "$SANDBOX/refuse"
  run -1 "$BIN"
  assert_output --partial "the patch of endpoints agents/agents to 10.20.0.7 was refused"
}

@test "with no override it reads with the schedules-sync kubeconfig, else kubectl's own" {
  unset AGENT_WEB_KUBECONFIG
  mkdir -p "$HOME/.config/schedules-sync"
  echo 'apiVersion: v1' > "$HOME/.config/schedules-sync/kubeconfig"
  export KUBECONFIG="$SANDBOX/admin"
  echo 'apiVersion: v1' > "$KUBECONFIG"
  run "$BIN"
  assert_success
  grep -q "KUBECONFIG=$HOME/.config/schedules-sync/kubeconfig .*patch endpoints" "$SANDBOX/kubectl.log"
  # The workstation has no schedules-sync kubeconfig: it moves the record with its own.
  rm "$HOME/.config/schedules-sync/kubeconfig" "$SANDBOX/kubectl.log"
  run "$BIN"
  assert_success
  grep -q "KUBECONFIG=$SANDBOX/admin .*patch endpoints" "$SANDBOX/kubectl.log"
}

@test "a machine with no kubeconfig at all fails the step and leaves the record" {
  rm "$AGENT_WEB_KUBECONFIG"
  run -1 "$BIN"
  assert_output --partial "no kubeconfig at $AGENT_WEB_KUBECONFIG, so the agents Endpoints still name where they did"
  [ ! -e "$SANDBOX/kubectl.log" ]
}
