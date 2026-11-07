#!/usr/bin/env bats
# release-state: pinned is read from the fetched remote branch, live from the cluster, and a
# failed probe says unknown. kubectl is a stub that prints $KUBE_IMAGE (or fails on
# KUBE_FAIL=1); the "remote" is a bare repo in the sandbox, so fetch is real git.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  RS="$REPO_ROOT/.local/bin/release-state"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  export GIT_RELEASE_LIB
  export RELEASE_STATE_DIR="$HOME/agent/releases"
  export WATCH_DIR="$HOME/agent/watches" WATCH_STATE_DIR="$HOME/state/watch-companion"
  mkdir -p "$WATCH_DIR" "$WATCH_STATE_DIR"

  ORIGIN="$SANDBOX/origin.git"
  CLONE="$SANDBOX/repos/infra"
  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
  git -C "$CLONE" config user.email t@t; git -C "$CLONE" config user.name t
  mkdir -p "$CLONE/apps/web"
  manifest v1.0.0
  cat > "$CLONE/apps/web/kustomization.yaml" <<'EOF'
images:
  - name: reg/other
    newTag: o-9
  - name: reg/web
    newTag: "pre-abc"
EOF
  git -C "$CLONE" add -A; git -C "$CLONE" commit -qm init; git -C "$CLONE" push -q origin main 2>/dev/null

  cat > "$SANDBOX/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
[ "${KUBE_FAIL:-0}" = 1 ] && exit 1
printf '%s' "${KUBE_IMAGE:-reg/web:v1.0.0}"
EOF
  chmod +x "$SANDBOX/bin/kubectl"

  export PROJECT_MAP_FILE="$HOME/project-map.json"
  write_map '"telemetry": []'
}

# manifest <tag> - the Flux-style pin in the working tree (not committed).
manifest() { printf 'spec:\n  values:\n    image:\n      tag: %s\n' "$1" > "$CLONE/apps/web/helmrelease.yaml"; }

# push_pin <tag> - move the pin on the remote only; the local checkout stays behind.
push_pin() {
  local tmp="$SANDBOX/pusher"
  rm -rf "$tmp"; git clone -q "$ORIGIN" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name t
  printf 'spec:\n  values:\n    image:\n      tag: %s\n' "$1" > "$tmp/apps/web/helmrelease.yaml"
  git -C "$tmp" commit -qam bump; git -C "$tmp" push -q origin main 2>/dev/null
}

write_map() {
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$CLONE": "infra" },
  "trackers": {
    "_comment": "a string value",
    "infra": { "system": "none" },
    "web": { "repo": "infra", "type": "app", "targets": [
      {"id": "web-prod", "channel": "prod", "pinned": {"repo": "infra", "branch": "main", "path": "apps/web/helmrelease.yaml"}, "live": {"k8s": {"context": "c", "namespace": "n", "deployment": "web"}}, $1},
      {"id": "web-preview", "channel": "preview", "pinned": {"repo": "infra", "path": "apps/web/kustomization.yaml", "image": "reg/web"}, "live": {"k8s": {"context": "c", "namespace": "n", "deployment": "webp"}}, "telemetry": []}
    ]},
    "lonely": { "type": "app" }
  }
}
EOF
}

row() { jq -c --arg id "$1" '.rows[] | select(.id == $id)' "$RELEASE_STATE_DIR/state.json"; }
field() { row "$1" | jq -r "$2"; }

@test "GUARD: release-state is executable" {
  [ -x "$RS" ]
}

@test "pinned comes from the fetched remote branch, not the lagging local checkout" {
  push_pin v1.1.0
  export KUBE_IMAGE=reg/web:v1.1.0
  run "$RS" refresh
  assert_success
  # Negative control: the local checkout still says v1.0.0.
  run git -C "$CLONE" show HEAD:apps/web/helmrelease.yaml
  assert_output --partial 'tag: v1.0.0'
  [ "$(field web-prod .pinned.value)" = v1.1.0 ]
  [ "$(field web-prod .status)" = ok ]
}

@test "live differing from pinned is drift, and check names it once past grace" {
  export KUBE_IMAGE=reg/web:v0.9.0
  "$RS" refresh >/dev/null
  [ "$(field web-prod .status)" = drift ]
  run "$RS" check --grace 30
  assert_success
  # Age the drift two minutes instead of waiting for it.
  jq '.rows |= map(if .drift_since then .drift_since -= 120 else . end)' "$RELEASE_STATE_DIR/state.json" > "$SANDBOX/s"
  mv "$SANDBOX/s" "$RELEASE_STATE_DIR/state.json"
  run "$RS" check --grace 1
  assert_failure
  assert_output --partial 'DRIFT web web-prod: pinned v1.0.0 live v0.9.0'
}

@test "drift_since carries across refreshes while the same drift holds" {
  export KUBE_IMAGE=reg/web:v0.9.0
  "$RS" refresh >/dev/null
  jq '.rows |= map(if .id == "web-prod" then .drift_since = 1000 else . end)' "$RELEASE_STATE_DIR/state.json" > "$SANDBOX/s"
  mv "$SANDBOX/s" "$RELEASE_STATE_DIR/state.json"
  "$RS" refresh >/dev/null
  [ "$(field web-prod .drift_since)" = 1000 ]
  # A different live value is a new drift.
  export KUBE_IMAGE=reg/web:v0.8.0
  "$RS" refresh >/dev/null
  [ "$(field web-prod .drift_since)" != 1000 ]
}

@test "a failed kubectl probe is unknown, never the last good value" {
  "$RS" refresh >/dev/null
  [ "$(field web-prod .live.value)" = v1.0.0 ]
  KUBE_FAIL=1 "$RS" refresh >/dev/null
  [ "$(field web-prod .status)" = unknown ]
  [ "$(field web-prod .live.value)" = null ]
  [ "$(field web-prod .live.error)" = 'kubectl get failed' ]
}

@test "a failed fetch is unknown even though a remote-tracking ref exists" {
  "$RS" refresh >/dev/null
  git -C "$CLONE" remote set-url origin "$SANDBOX/gone.git"
  "$RS" refresh >/dev/null
  [ "$(field web-prod .status)" = unknown ]
  [ "$(field web-prod .pinned.error)" = 'fetch failed' ]
}

@test "a kustomize images block picks the newTag of the named image" {
  export KUBE_IMAGE=reg/web:pre-abc
  "$RS" refresh >/dev/null
  [ "$(field web-preview .pinned.value)" = pre-abc ]
  [ "$(field web-preview .status)" = ok ]
}

@test "a latest image on prod is floating, and check fails on it" {
  export KUBE_IMAGE=reg/web:latest
  push_pin latest
  "$RS" refresh >/dev/null
  [ "$(field web-prod .status)" = floating ]
  run "$RS" check
  assert_failure
  assert_output --partial 'FLOATING web web-prod'
}

@test "a declared telemetry watch with no definition fails check; a green one passes" {
  write_map '"telemetry": ["web-health"]'
  "$RS" refresh >/dev/null
  [ "$(field web-prod '.telemetry[0].state')" = missing ]
  run "$RS" check
  assert_failure
  assert_output --partial 'TELEMETRY web web-prod: watch web-health is missing'
  : > "$WATCH_DIR/web-health.yaml"
  echo OK > "$WATCH_STATE_DIR/web-health.state"
  "$RS" refresh >/dev/null
  run "$RS" check
  assert_success
  assert_output 'ok'
}

@test "an app with no targets gets a release row: its tag, or unreleased" {
  "$RS" refresh >/dev/null
  [ "$(field lonely .status)" = unreleased ]
  [ "$(field lonely .channel)" = release ]
}

@test "a subset refresh replaces that project's rows and keeps the rest" {
  "$RS" refresh >/dev/null
  KUBE_FAIL=1 "$RS" refresh lonely >/dev/null
  [ "$(field web-prod .status)" = ok ]
  [ "$(jq '.rows | length' "$RELEASE_STATE_DIR/state.json")" = 3 ]
}

@test "refresh publishes its runner outcome, so agentctl never promotes PENDING to STALLED" {
  # An inherited AGENTCTL_NAME (another runner's unit) must not take the outcome.
  export AGENTCTL_STATE_DIR="$SANDBOX/agentctl-state" AGENTCTL_NAME=other-runner
  mkdir -p "$AGENTCTL_STATE_DIR/release-state"
  printf PENDING > "$AGENTCTL_STATE_DIR/release-state/last-outcome"
  run "$RS" refresh
  assert_success
  assert_output --partial '3 rows, '
  [ "$(cat "$AGENTCTL_STATE_DIR/release-state/last-outcome")" = WORKED ]
  run grep -c 'outcome=WORKED 3 rows' "$AGENTCTL_STATE_DIR/release-state/activity.log"
  assert_output 1
  [ ! -e "$AGENTCTL_STATE_DIR/other-runner" ]
  # Negative control: show and check are not passes and leave the outcome alone.
  printf PENDING > "$AGENTCTL_STATE_DIR/release-state/last-outcome"
  "$RS" show >/dev/null
  "$RS" check >/dev/null || true
  [ "$(cat "$AGENTCTL_STATE_DIR/release-state/last-outcome")" = PENDING ]
}

@test "a refresh with no registry is FAILED with its reason and keeps the last snapshot" {
  export AGENTCTL_STATE_DIR="$SANDBOX/agentctl-state"
  "$RS" refresh >/dev/null
  rm -f "$PROJECT_MAP_FILE"
  run "$RS" refresh
  assert_failure
  [ "$(cat "$AGENTCTL_STATE_DIR/release-state/last-outcome")" = FAILED ]
  run tail -1 "$AGENTCTL_STATE_DIR/release-state/activity.log"
  assert_output --partial "outcome=FAILED why: no registry at $PROJECT_MAP_FILE"
  [ "$(jq '.rows | length' "$RELEASE_STATE_DIR/state.json")" = 3 ]
}

@test "an old snapshot fails check as stale" {
  "$RS" refresh >/dev/null
  jq '.generated_epoch -= 7200' "$RELEASE_STATE_DIR/state.json" > "$SANDBOX/s" && mv "$SANDBOX/s" "$RELEASE_STATE_DIR/state.json"
  run "$RS" check
  assert_failure
  assert_output --partial 'STALE snapshot is 120m old'
}

@test "show lists drift before ok" {
  export KUBE_IMAGE=reg/web:v0.9.0
  "$RS" refresh >/dev/null
  run "$RS" show
  assert_success
  [ "$(sed -n 3p <<<"$output" | awk '{print $NF, $(NF-1)}')" = "- drift" ]
}

@test "doctor 4c names a malformed target and a duplicate id" {
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$CLONE": "infra" },
  "trackers": {
    "infra": { "system": "none" },
    "web": { "repo": "infra", "type": "app", "targets": [
      {"id": "Bad Id", "channel": "prod", "pinned": {"repo": "infra"}},
      {"id": "dup", "channel": "staging", "pinned": {"tag": true}, "live": {"k8s": {"context": "c"}}, "deps": ["ghost"]},
      {"id": "dup", "channel": "prod", "pinned": {"tag": true}}
    ]}
  }
}
EOF
  AGENT_DIR="$HOME/agent" run "$REPO_ROOT/.local/bin/project-map-doctor" "$PROJECT_MAP_FILE"
  assert_failure
  assert_output --partial 'target "Bad Id": id must be lowercase'
  assert_output --partial 'target "Bad Id": pinned needs {tag: true} or repo and path'
  assert_output --partial 'target "dup": channel "staging" is not one of'
  assert_output --partial 'target "dup": live needs k8s'
  assert_output --partial 'dep "ghost" is not a registered project'
  assert_output --partial 'deploy target id "dup" is used 2 times'
}
