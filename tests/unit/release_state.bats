#!/usr/bin/env bats
# release-state: pinned is read from the fetched remote branch, live from the cluster, and a
# failed probe says unknown. kubectl is a stub that prints $KUBE_IMAGE (or fails on
# KUBE_FAIL=1); gh is a stub that prints $GH_REPLY (or fails on GH_FAIL=1); the "remote" is a bare
# repo in the sandbox, so fetch is real git.

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

  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/gh.calls"
[ "${GH_FAIL:-0}" = 1 ] && exit 1
empty='{"data":{"repository":{"deployments":{"nodes":[]}}}}'
printf '%s' "${GH_REPLY:-$empty}"
EOF
  chmod +x "$SANDBOX/bin/gh"
  export SANDBOX

  # Never fetched: only its origin URL is read, to name the repo the history lives in.
  CODE="$SANDBOX/repos/code"
  git init -q -b main "$CODE"
  git -C "$CODE" remote add origin git@github.com:acme/code.git

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
  "paths": { "$CLONE": "infra", "$CODE": "code" },
  "trackers": {
    "_comment": "a string value",
    "infra": { "system": "none" },
    "web": { "repo": "infra", "type": "app", "targets": [
      {"id": "web-prod", "channel": "prod", "pinned": {"repo": "infra", "branch": "main", "path": "apps/web/helmrelease.yaml"}, "live": {"k8s": {"context": "c", "namespace": "n", "deployment": "web"}}, $1},
      {"id": "web-preview", "channel": "preview", "pinned": {"repo": "infra", "path": "apps/web/kustomization.yaml", "image": "reg/web"}, "live": {"k8s": {"context": "c", "namespace": "n", "deployment": "webp"}}, "telemetry": []}
    ]},
    "lonely": { "type": "app" },
    "shop": { "repo": "code", "targets": [
      {"id": "shop-prod", "channel": "prod", "pinned": {"repo": "infra", "branch": "main", "path": "apps/web/helmrelease.yaml"}}
    ]}
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
  [ "$(jq '.rows | length' "$RELEASE_STATE_DIR/state.json")" = 4 ]
}

@test "refresh publishes its runner outcome, so agentctl never promotes PENDING to STALLED" {
  # An inherited AGENTCTL_NAME (another runner's unit) must not take the outcome.
  export AGENTCTL_STATE_DIR="$SANDBOX/agentctl-state" AGENTCTL_NAME=other-runner
  mkdir -p "$AGENTCTL_STATE_DIR/release-state"
  printf PENDING > "$AGENTCTL_STATE_DIR/release-state/last-outcome"
  run "$RS" refresh
  assert_success
  assert_output --partial '4 rows, '
  [ "$(cat "$AGENTCTL_STATE_DIR/release-state/last-outcome")" = WORKED ]
  run grep -c 'outcome=WORKED 4 rows' "$AGENTCTL_STATE_DIR/release-state/activity.log"
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
  [ "$(jq '.rows | length' "$RELEASE_STATE_DIR/state.json")" = 4 ]
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
  [ "$(sed -n 3p <<<"$output" | awk '{print $NF, $(NF-3)}')" = "- drift" ]
}

@test "doctor 4c names a malformed target and a duplicate id" {
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$CLONE": "infra", "$CODE": "code" },
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
  assert_output --partial 'target "Bad Id": pinned needs {tag: true}, {deployed: true} or repo and path'
  assert_output --partial 'target "dup": channel "staging" is not one of'
  assert_output --partial 'target "dup": live needs k8s'
  assert_output --partial 'dep "ghost" is not a registered project'
  assert_output --partial 'deploy target id "dup" is used 2 times'
}

# node <version> <state> <at> - one Deployment as the GraphQL answer carries it.
node() {
  printf '{"createdAt":"%s","description":"%s","commitOid":"abcdef1234","ref":{"name":"main"},"latestStatus":{"state":"%s","logUrl":"https://example.test/run/%s","createdAt":"%s"}}' "$3" "$1" "$2" "$1" "$3"
}
reply() { local IFS=,; GH_REPLY="{\"data\":{\"repository\":{\"deployments\":{\"nodes\":[$*]}}}}"; export GH_REPLY; }

@test "doctor 4c accepts the store kinds and names one missing a field" {
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$CODE": "code" },
  "trackers": {
    "game": { "repo": "code", "targets": [
      {"id": "a-steam-beta", "channel": "beta", "pinned": {"deployed": true}, "live": {"steam": {"app": "1", "branch": "beta"}}},
      {"id": "a-play-internal", "channel": "internal", "pinned": {"deployed": true}, "live": {"play": {"package": "p", "track": "internal"}}},
      {"id": "a-testflight", "channel": "beta", "pinned": {"deployed": true}, "live": {"testflight": {"app": "2"}}},
      {"id": "b-steam-beta", "channel": "beta", "pinned": {"deployed": true}, "live": {"steam": {"app": "1"}}}
    ]}
  }
}
EOF
  AGENT_DIR="$HOME/agent" run "$REPO_ROOT/.local/bin/project-map-doctor" "$PROJECT_MAP_FILE"
  assert_output --partial 'target "b-steam-beta": live needs'
  refute_output --partial 'target "a-'
}

@test "deploys: the target id names the environment in the project's github repo" {
  run "$RS" refresh shop
  assert_success
  run grep -c '^api graphql' "$SANDBOX/gh.calls"
  assert_output 1
  run cat "$SANDBOX/gh.calls"
  assert_output --partial "-f owner=acme -f name=code -f env=shop-prod -F n=10"
  assert_equal "$(row shop-prod | jq -c '.deploys | [.source, .history, .prev, .last, .error]')" '["acme/code",[],null,null,null]'
}

@test "deploys: last is the newest finished, prev the version before the newest success" {
  reply "$(node v4 PENDING 2026-11-05T10:00:00Z)" "$(node v3 FAILURE 2026-11-04T10:00:00Z)" \
    "$(node v2 SUCCESS 2026-11-03T10:00:00Z)" "$(node v2 SUCCESS 2026-11-02T10:00:00Z)" "$(node v1 SUCCESS 2026-11-01T10:00:00Z)"
  "$RS" refresh shop
  local d; d="$(row shop-prod | jq -c .deploys)"
  assert_equal "$(jq -r '.last.version + " " + .last.state' <<<"$d")" "v3 fail"
  assert_equal "$(jq -r '.prev' <<<"$d")" "v1"
  assert_equal "$(jq -r '.history | length' <<<"$d")" 5
  assert_equal "$(jq -r '.history[0].state' <<<"$d")" "pending"
  assert_equal "$(jq -r '.last.url' <<<"$d")" "https://example.test/run/v3"
}

@test "deploys: a rollback's prev is the version it replaced" {
  reply "$(node v1 SUCCESS 2026-11-03T10:00:00Z)" "$(node v2 SUCCESS 2026-11-02T10:00:00Z)" "$(node v1 SUCCESS 2026-11-01T10:00:00Z)"
  "$RS" refresh shop
  assert_equal "$(row shop-prod | jq -r .deploys.prev)" "v2"
}

@test "deploys: a deployment with no description falls back to its ref" {
  reply '{"createdAt":"2026-11-01T10:00:00Z","description":"","commitOid":"abcdef1234","ref":{"name":"release-1"},"latestStatus":{"state":"SUCCESS","logUrl":"","createdAt":"2026-11-01T10:00:00Z"}}'
  "$RS" refresh shop
  assert_equal "$(row shop-prod | jq -c '.deploys.last | [.version, .url]')" '["release-1",null]'
}

@test "deploys: a failed call says so and keeps no earlier history" {
  reply "$(node v2 SUCCESS 2026-11-02T10:00:00Z)"
  "$RS" refresh shop
  GH_FAIL=1 run "$RS" refresh shop
  assert_success
  assert_equal "$(row shop-prod | jq -c '.deploys | [.error, .history, .prev, .last]')" '["gh api failed",[],null,null]'
  run "$RS" show shop
  assert_line --regexp '^shop .*\?'
}

@test "deploys: an unreadable answer is an error, not an empty history" {
  GH_REPLY='{"errors":"no data"}' "$RS" refresh shop
  assert_equal "$(row shop-prod | jq -r .deploys.error)" "unreadable answer"
}

@test "deploys: a repo not on github and an implicit row make no call" {
  run "$RS" refresh web lonely
  assert_success
  [ ! -e "$SANDBOX/gh.calls" ]
  assert_equal "$(row web-prod | jq -r .deploys.source)" "none"
  assert_equal "$(row lonely | jq -r .deploys.source)" "none"
}

@test "deploys: show prints PREV and LAST DEPLOY" {
  reply "$(node v2 FAILURE 2026-11-03T10:00:00Z)" "$(node v2 SUCCESS 2026-11-02T10:00:00Z)" "$(node v1 SUCCESS 2026-11-01T10:00:00Z)"
  "$RS" refresh shop
  run env TZ=UTC "$RS" show shop
  assert_success
  assert_line --index 1 --partial "PREV"
  assert_line --index 1 --partial "LAST DEPLOY"
  assert_line --regexp '^shop .* v1 +11-03 10:00 fail'
}

# --- store channels. rbw and curl are stubs; the curl stub logs its argv and its stdin config apart,
# so a test can prove a credential reached curl only on stdin.

store_setup() {
  mkdir -p "$SANDBOX/rbw"
  cat > "$SANDBOX/bin/rbw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/rbw.calls"
case "$1" in
  unlocked) [ "${RBW_LOCKED:-0}" != 1 ] ;;
  get) cat "$SANDBOX/rbw/$2" 2>/dev/null ;;
  *) exit 1 ;;
esac
STUB
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/curl.argv"
cfg="$(cat)"
printf '%s\n' "$cfg" >> "$SANDBOX/curl.config"
[ "${CURL_FAIL:-0}" = 1 ] && exit 22
case "$cfg" in
  *GetAppBetas*) printf '%s' "${STEAM_BETAS:-}" ;;
  *GetAppBuilds*) printf '%s' "${STEAM_BUILDS_REPLY:-}" ;;
  *oauth2.googleapis.com/token*) printf '%s' '{"access_token":"play-token"}' ;;
  */tracks/*/releases*) printf '%s' "${PLAY_REPLY:-}" ;;
  *appstoreconnect*) printf '%s' "${ASC_REPLY:-}" ;;
esac
STUB
  chmod +x "$SANDBOX/bin/rbw" "$SANDBOX/bin/curl"
  printf 'steam-secret-key\n' > "$SANDBOX/rbw/release_state_steam"
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$CODE": "code", "$CLONE": "infra" },
  "trackers": {
    "infra": { "system": "none" },
    "web": { "repo": "infra", "type": "app", "targets": [
      {"id": "web-prod", "channel": "prod", "pinned": {"repo": "infra", "branch": "main", "path": "apps/web/helmrelease.yaml"}, "live": {"k8s": {"context": "c", "namespace": "n", "deployment": "web"}}}
    ]},
    "game": { "repo": "code", "targets": [
      {"id": "game-steam-beta", "channel": "beta", "pinned": {"deployed": true}, "live": {"steam": {"app": "111", "branch": "beta"}}},
      {"id": "game-play-internal", "channel": "internal", "pinned": {"deployed": true}, "live": {"play": {"package": "com.acme.game", "track": "internal"}}},
      {"id": "game-testflight", "channel": "beta", "pinned": {"deployed": true}, "live": {"testflight": {"app": "222"}}}
    ]}
  }
}
EOF
  export STEAM_BETAS='{"response":{"result":1,"betas":{"beta":{"BuildID":4230881,"Description":"","ReqPassword":false}}}}'
  export STEAM_BUILDS_REPLY='{"response":{"result":1,"builds":{"4230881":{"BuildID":4230881,"Description":"game v0.5.0-g1 abcdef123456"}}}}'
  export PLAY_REPLY='{"releases":[
    {"releaseName":"v0.4.0-g9","track":"internal","activeArtifacts":[{"versionCode":90}],"releaseLifecycleState":"RELEASE_LIFECYCLE_STATE_PUBLISHED"},
    {"releaseName":"v0.5.0-g1","track":"internal","activeArtifacts":[{"versionCode":101}],"releaseLifecycleState":"RELEASE_LIFECYCLE_STATE_PUBLISHED"},
    {"releaseName":"v0.6.0-draft","track":"internal","activeArtifacts":[{"versionCode":200}],"releaseLifecycleState":"RELEASE_LIFECYCLE_STATE_DRAFT"}]}'
  export ASC_REPLY='{"data":[{"type":"builds","id":"b1","attributes":{"version":"4321"}}],"included":[{"type":"preReleaseVersions","id":"p1","attributes":{"version":"0.5.0"}}]}'
  reply "$(node v0.5.0-g1 SUCCESS 2026-11-02T10:00:00Z)"
}

play_key() {
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$SANDBOX/play.pem" 2>/dev/null
  jq -nc --rawfile k "$SANDBOX/play.pem" '{client_email: "reader@acme.iam", private_key: $k}' > "$SANDBOX/rbw/release_state_play"
}

asc_key() {
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$SANDBOX/asc.pem" 2>/dev/null
  jq -nc --arg p "$(base64 -w0 < "$SANDBOX/asc.pem")" '{key_id: "KID1", issuer_id: "ISS1", p8: $p}' > "$SANDBOX/rbw/release_state_asc"
}

# unb64url <text> -> the decoded bytes of one JWT segment.
unb64url() { local s="${1//-/+}"; s="${s//_//}"; while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done; printf '%s' "$s" | base64 -d; }

@test "steam: live is the tag in the branch's build description, and it matches the recorded upload" {
  store_setup
  run "$RS" refresh game
  assert_success
  assert_equal "$(row game-steam-beta | jq -c '[.pinned.value, .live.value, .live.build, .status]')" '["v0.5.0-g1","v0.5.0-g1","4230881","ok"]'
}

@test "steam: a branch on another build than the last upload is drift" {
  store_setup
  reply "$(node v0.6.0-g2 SUCCESS 2026-11-03T10:00:00Z)" "$(node v0.5.0-g1 SUCCESS 2026-11-02T10:00:00Z)"
  "$RS" refresh game
  assert_equal "$(row game-steam-beta | jq -c '[.pinned.value, .live.value, .status]')" '["v0.6.0-g2","v0.5.0-g1","drift"]'
}

@test "steam: a failed upload does not move the pin" {
  store_setup
  reply "$(node v0.6.0-g2 FAILURE 2026-11-03T10:00:00Z)" "$(node v0.5.0-g1 SUCCESS 2026-11-02T10:00:00Z)"
  "$RS" refresh game
  assert_equal "$(row game-steam-beta | jq -r .status)" ok
}

@test "steam: a build with no tag in its description shows its BuildID" {
  store_setup
  export STEAM_BUILDS_REPLY='{"response":{"builds":{"4230881":{"Description":"manual upload"}}}}'
  "$RS" refresh game
  assert_equal "$(row game-steam-beta | jq -r .live.value)" 4230881
}

@test "steam: a branch the app does not have says so" {
  store_setup
  export STEAM_BETAS='{"response":{"betas":{}}}'
  "$RS" refresh game
  assert_equal "$(row game-steam-beta | jq -c '[.live.error, .status]')" '["no branch beta on the app","unknown"]'
}

@test "store: a channel with no recorded upload is released, with live shown and the pin a dash" {
  store_setup
  unset GH_REPLY
  "$RS" refresh game
  assert_equal "$(row game-steam-beta | jq -c '[.pinned.value, .live.value, .status]')" '[null,"v0.5.0-g1","released"]'
  run "$RS" show game
  assert_line --regexp '^game +beta game-steam-beta +- +v0\.5\.0-g1 +released'
}

@test "store: unreadable deploy history is unknown, never the store's value called matching" {
  store_setup
  GH_FAIL=1 "$RS" refresh game
  assert_equal "$(row game-steam-beta | jq -c '[.pinned.error, .status]')" '["deploy history unreadable","unknown"]'
}

@test "store: a credential reaches curl on stdin and never on its command line" {
  store_setup
  play_key
  "$RS" refresh game
  grep -q 'steam-secret-key' "$SANDBOX/curl.config"
  grep -q 'Bearer play-token' "$SANDBOX/curl.config"
  run grep -E 'steam-secret-key|play-token|assertion' "$SANDBOX/curl.argv"
  assert_failure
  run grep -E 'steam-secret-key|play-token|PRIVATE KEY' "$RELEASE_STATE_DIR/state.json"
  assert_failure
}

@test "store: a locked vault never calls rbw get, and each row says why" {
  store_setup
  RBW_LOCKED=1 run "$RS" refresh game
  assert_success
  run grep -c '^get' "$SANDBOX/rbw.calls"
  assert_output 0
  assert_equal "$(row game-steam-beta | jq -c '[.live.error, .status]')" '["rbw is locked","unknown"]'
  assert_equal "$(row game-testflight | jq -r .live.error)" "rbw is locked"
}

@test "store: a missing entry is unknown and names the entry, the other stores still read" {
  store_setup
  play_key
  "$RS" refresh game
  assert_equal "$(row game-testflight | jq -c '[.live.error, .status]')" '["no rbw entry release_state_asc","unknown"]'
  assert_equal "$(row game-play-internal | jq -r .status)" ok
}

@test "store: a refresh with no store target never touches rbw" {
  store_setup
  export KUBE_IMAGE=reg/web:v1.0.0
  run "$RS" refresh web
  assert_success
  [ ! -e "$SANDBOX/rbw.calls" ]
}

@test "store: an api failure is unknown" {
  store_setup
  play_key
  asc_key
  CURL_FAIL=1 "$RS" refresh game
  assert_equal "$(row game-steam-beta | jq -r .live.error)" "steam GetAppBetas failed"
  assert_equal "$(row game-play-internal | jq -r .live.error)" "google token request failed"
  assert_equal "$(row game-testflight | jq -r .live.error)" "app store connect request failed"
}

@test "play: live is the highest published release, a draft does not count" {
  store_setup
  play_key
  "$RS" refresh game
  assert_equal "$(row game-play-internal | jq -c '[.live.value, .live.build, .status]')" '["v0.5.0-g1","101","ok"]'
}

@test "play: reads the edit-free release list, and opens no edit" {
  store_setup
  play_key
  "$RS" refresh game
  grep -q '/applications/com.acme.game/tracks/internal/releases"' "$SANDBOX/curl.config"
  run grep '/edits' "$SANDBOX/curl.config"
  assert_failure
}

@test "play: the token request is a service-account JWT that verifies against the key" {
  store_setup
  play_key
  "$RS" refresh game
  local jwt h c s
  jwt="$(grep -o 'assertion=[^"]*' "$SANDBOX/curl.config" | cut -d= -f2)"
  IFS=. read -r h c s <<<"$jwt"
  assert_equal "$(unb64url "$c" | jq -c '[.iss, .scope]')" '["reader@acme.iam","https://www.googleapis.com/auth/androidpublisher"]'
  openssl pkey -in "$SANDBOX/play.pem" -pubout -out "$SANDBOX/play.pub" 2>/dev/null
  unb64url "$s" > "$SANDBOX/play.sig"
  printf '%s.%s' "$h" "$c" | openssl dgst -sha256 -verify "$SANDBOX/play.pub" -signature "$SANDBOX/play.sig"
}

@test "testflight: compares the marketing version, with the build number shown" {
  store_setup
  asc_key
  "$RS" refresh game
  assert_equal "$(row game-testflight | jq -c '[.pinned.value, .live.value, .status]')" '["v0.5.0-g1","0.5.0 (4321)","ok"]'
}

@test "testflight: another marketing version is drift" {
  store_setup
  asc_key
  reply "$(node v0.6.0-g1 SUCCESS 2026-11-03T10:00:00Z)"
  "$RS" refresh game
  assert_equal "$(row game-testflight | jq -r .status)" drift
}

@test "testflight: the JWT names the key and carries a 64-byte ES256 signature" {
  store_setup
  asc_key
  "$RS" refresh game
  local jwt h c s
  jwt="$(grep -o 'Bearer [^"]*' "$SANDBOX/curl.config" | tail -1 | cut -d' ' -f2)"
  IFS=. read -r h c s <<<"$jwt"
  assert_equal "$(unb64url "$h" | jq -c '[.alg, .kid]')" '["ES256","KID1"]'
  assert_equal "$(unb64url "$c" | jq -c '[.iss, .aud]')" '["ISS1","appstoreconnect-v1"]'
  assert_equal "$(unb64url "$s" | wc -c)" 64
}
