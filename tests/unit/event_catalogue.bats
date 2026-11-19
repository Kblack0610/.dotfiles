#!/usr/bin/env bats
# event-catalogue: the events each product sends, read from the analytics rows of the department
# catalog. The fixture is a tiny platform checkout (a types.ts with a product-scoped group and a
# group that carries a property) and a playground doc with a Usage events table.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  EC="$REPO_ROOT/.local/bin/event-catalogue"
  export PROJECT_MAP_FILE="$SANDBOX/project-map.json" DEPARTMENTS_TSV="$SANDBOX/departments.tsv"
  export EVENT_CATALOGUE_DIR="$SANDBOX/out" AGENTCTL_STATE_DIR="$SANDBOX/agentctl"
  local plat="$SANDBOX/platform" play="$SANDBOX/playground"
  mkdir -p "$plat/analytics" "$play/docs"
  cat > "$plat/analytics/types.ts" <<'TS'
export const Unrelated = { NOT_AN_EVENT: 'not_an_event' } as const;

export const AnalyticsEvents = {
  // Authentication events
  USER_SIGNED_UP: 'user_signed_up',
  USER_LOGGED_IN: 'user_logged_in',

  // Alpha specific events
  HOMECARE_VIEWED: 'homecare_viewed',

  // Mobile app install banner on the web (all carry a `platform` property)
  APP_BANNER_SHOWN: 'app_banner_shown',
} as const;

export type AnalyticsEventName = string;
TS
  cat > "$play/docs/online.md" <<'MD'
# Online

## Usage events

| Kind | When | Props |
|---|---|---|
| `session_start`, `session_end` | the app starts, quits | `seconds` on the end |
| `join_failed` | the connect panel gives up | `reason`: `unreachable`, `port` or `timeout` |

## Code

| `not_in_table` | x | y |
MD
  cat > "$PROJECT_MAP_FILE" <<EOF2
{"paths": {"$plat": "fixture-platform", "$play": "fixture-playground"}, "trackers": {}}
EOF2
  printf 'analytics\tfixture-platform:analytics/types.ts\tfile\talpha\tx\nanalytics\tfixture-platform:analytics/types.ts\tfile\tbeta\tx\nanalytics\tfixture-playground:docs/online.md\tfile\tplayground\tx\nanalytics\tperf-round\trunner\t*\tx\n' > "$DEPARTMENTS_TSV"
}

names() { jq -r '[.events[].name] | sort | join(",")' "$EVENT_CATALOGUE_DIR/$1.json"; }

@test "build writes one file per product, and a product-scoped group goes to that product only" {
  run "$EC" build
  assert_success
  assert_output --partial 'alpha: 4 events'
  assert_output --partial 'beta: 3 events'
  assert_equal "$(names alpha)" 'app_banner_shown,homecare_viewed,user_logged_in,user_signed_up'
  assert_equal "$(names beta)" 'app_banner_shown,user_logged_in,user_signed_up'
}

@test "a group heading that says its events carry a property gives them that property" {
  "$EC" build
  run jq -c '.events[] | select(.name == "app_banner_shown") | [.group, .props]' "$EVENT_CATALOGUE_DIR/beta.json"
  assert_output '["Mobile app install banner on the web",["platform"]]'
  run jq -c '.events[] | select(.name == "user_signed_up") | .props' "$EVENT_CATALOGUE_DIR/beta.json"
  assert_output '[]'
}

@test "a Usage events table row gives each of its kinds an event, props read up to the first colon" {
  "$EC" build
  assert_equal "$(names playground)" 'join_failed,session_end,session_start'
  run jq -c '.events[] | select(.name == "join_failed") | .props' "$EVENT_CATALOGUE_DIR/playground.json"
  assert_output '["reason"]'
}

@test "only the named const and table are read, and the catalogue records its sources" {
  "$EC" build
  run jq -r '[.events[].name] | index("not_an_event"), index("not_in_table")' "$EVENT_CATALOGUE_DIR/alpha.json" "$EVENT_CATALOGUE_DIR/playground.json"
  assert_output $'null\nnull\nnull\nnull'
  run jq -c '.sources' "$EVENT_CATALOGUE_DIR/playground.json"
  assert_output '["fixture-playground:docs/online.md"]'
}

@test "check passes for a product with a catalogue and fails for one without" {
  "$EC" build
  run "$EC" check alpha
  assert_success
  run "$EC" check ndt-calculator
  assert_failure
  run "$EC" show alpha
  assert_output --partial '"project":"alpha"'
}

@test "negative control: a source that cannot be read writes no file, says so, and fails the build" {
  printf 'analytics\tfixture-platform:analytics/gone.ts\tfile\tghost\tx\nanalytics\tuncloned-repo:a.ts\tfile\tghost2\tx\n' >> "$DEPARTMENTS_TSV"
  run "$EC" build
  assert_failure
  assert_output --partial 'ghost: cannot read fixture-platform:analytics/gone.ts'
  assert_output --partial 'ghost2: cannot read uncloned-repo:a.ts'
  [ ! -e "$EVENT_CATALOGUE_DIR/ghost.json" ]
  [ ! -e "$EVENT_CATALOGUE_DIR/ghost2.json" ]
  [ -f "$EVENT_CATALOGUE_DIR/alpha.json" ]
}

@test "under agentctl, build declares WORKED, or FAILED naming the product; a hand run declares nothing" {
  local out="$AGENTCTL_STATE_DIR/event-catalogue/last-outcome"
  run "$EC" build
  assert_success
  [ ! -e "$out" ]
  AGENTCTL_NAME=event-catalogue run "$EC" build
  assert_success
  [ "$(cat "$out")" = WORKED ]
  printf 'analytics\tfixture-platform:analytics/gone.ts\tfile\tghost\tx\n' >> "$DEPARTMENTS_TSV"
  AGENTCTL_NAME=event-catalogue run "$EC" build
  assert_failure
  [ "$(cat "$out")" = FAILED ]
  run grep -h 'unreadable: ghost' -r "$AGENTCTL_STATE_DIR/event-catalogue"
  assert_success
}

@test "under agentctl, a build that dies (no department catalog) declares FAILED, not STALLED" {
  rm -f "$DEPARTMENTS_TSV"
  AGENTCTL_NAME=event-catalogue run "$EC" build
  assert_failure
  [ "$(cat "$AGENTCTL_STATE_DIR/event-catalogue/last-outcome")" = FAILED ]
}

@test "a types.ts with no AnalyticsEvents const is an error, not an empty catalogue" {
  : > "$SANDBOX/platform/analytics/types.ts"
  run "$EC" build
  assert_failure
  assert_output --partial 'no events in fixture-platform:analytics/types.ts'
  [ ! -e "$EVENT_CATALOGUE_DIR/alpha.json" ]
}

@test "a missing department catalog is an error" {
  rm "$DEPARTMENTS_TSV"
  run "$EC" build
  assert_failure
  assert_output --partial 'no department catalog'
}

@test "one unreadable source of a product writes no file for it, and drops the last good one" {
  "$EC" build
  [ -f "$EVENT_CATALOGUE_DIR/beta.json" ]
  printf 'analytics\tfixture-platform:analytics/gone.ts\tfile\tbeta\tx\n' >> "$DEPARTMENTS_TSV"
  run "$EC" build
  assert_failure
  assert_output --partial 'beta: cannot read fixture-platform:analytics/gone.ts'
  [ ! -e "$EVENT_CATALOGUE_DIR/beta.json" ]
  run "$EC" check beta
  assert_failure
  [ -f "$EVENT_CATALOGUE_DIR/alpha.json" ]
}

@test "a note comment inside a group does not change the group or its scope" {
  sed -i 's|^  HOMECARE_VIEWED|  // TODO: rename this one\n  HOMECARE_VIEWED|' "$SANDBOX/platform/analytics/types.ts"
  "$EC" build
  assert_equal "$(names beta)" 'app_banner_shown,user_logged_in,user_signed_up'
  run jq -r '.events[] | select(.name == "homecare_viewed") | .group' "$EVENT_CATALOGUE_DIR/alpha.json"
  assert_output 'Alpha specific events'
}

@test "a value with a backslash and quotes stays valid JSON" {
  sed -i "s|^  USER_SIGNED_UP: 'user_signed_up',|  USER_SIGNED_UP: 'user\\\\\\\\up\"x',|" "$SANDBOX/platform/analytics/types.ts"
  grep -q 'USER_SIGNED_UP' "$SANDBOX/platform/analytics/types.ts"
  run "$EC" build
  assert_success
  run jq -r '.events[] | select(.name | startswith("user\\")) | .name' "$EVENT_CATALOGUE_DIR/alpha.json"
  assert_output 'user\\up"x'
}

@test "show and check take a project name, never a path, and help works without jq" {
  run "$EC" check ../x
  assert_failure
  assert_output --partial 'not a project name'
  run "$EC" show 'a/b'
  assert_failure
  mkdir -p "$BATS_TEST_TMPDIR/nojq"
  local t; for t in sed dirname realpath; do ln -s "$(command -v $t)" "$BATS_TEST_TMPDIR/nojq/$t"; done
  PATH="$BATS_TEST_TMPDIR/nojq" run /bin/bash "$EC" --help
  assert_success
  assert_output --partial 'write ~/.agent/event-catalogue'
}
