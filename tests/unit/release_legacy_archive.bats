#!/usr/bin/env bats
# release-legacy-archive: the ledger lists what release-state's provenance reads legacy, across a
# repo and its games, and each legacy run's log zip is copied once. The checkout is a real git repo
# with annotated tags; gh is a stub that answers each endpoint from a fixture under $SANDBOX/gh and
# applies the caller's --jq, so the tool's own filters run.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  ARC="$REPO_ROOT/.local/bin/release-legacy-archive"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  export GIT_RELEASE_LIB
  export RELEASE_ARCHIVE_DIR="$SANDBOX/nas"
  # The tag fetch must not dial out: the checkout's origin is a GitHub ssh URL.
  export GIT_SSH_COMMAND=false

  CODE="$SANDBOX/repos/game"
  git init -q -b main "$CODE"
  git -C "$CODE" remote add origin git@github.com:acme/game.git
  git -C "$CODE" config user.email t@t; git -C "$CODE" config user.name t
  tag v0.9.0 Kenneth 2026-11-01T10:00:00Z
  tag v0.9.0-kart1 Kenneth 2026-11-02T10:00:00Z
  tag v1.0.0 Kenneth 2026-11-10T10:00:00Z
  tag v1.0.0-kart1 Kenneth 2026-11-10T11:00:00Z
  tag v1.1.0 cut.yml 2026-11-12T10:00:00Z
  tag v1.1.0-puzzle1 cut.yml 2026-11-12T11:00:00Z
  tag other-v2.0.0 Kenneth 2026-11-12T12:00:00Z

  export PROJECT_MAP_FILE="$HOME/project-map.json"
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$CODE": "game" },
  "trackers": {
    "game": { "lab": "bnb", "type": "game", "tagGlob": "v*", "releaseFrom": "v1.0.0",
      "buildWorkflows": [".github/workflows/release.yml"],
      "deployWorkflows": {".github/workflows/steam.yml": ["kart-steam-beta"], ".github/workflows/shots.yml": ["game-gallery"],
                          ".github/workflows/record.yml": "the recorder; deploys nothing"},
      "targets": [{"id": "game-gallery", "channel": "preview", "pinned": {"repo": "infra", "path": "k.yaml", "image": "reg/g"}}]},
    "kart": { "repo": "game", "lab": "bnb", "type": "game", "buildTags": ["v*-kart*"], "releaseFrom": "v1.0.0",
      "targets": [{"id": "kart-steam-beta", "channel": "beta", "pinned": {"deployed": true}}]},
    "puzzle": { "repo": "game", "lab": "bnb", "type": "game", "buildTags": ["v*-puzzle*"] }
  }
}
EOF
  export RELEASE_CUT_CONF="$HOME/release-cut.json"
  printf '{"game": {"cut_workflow": "cut.yml"}}' > "$RELEASE_CUT_CONF"

  LAB="$SANDBOX/lab/projects/current"
  mkdir -p "$LAB/game/versions"
  cat > "$SANDBOX/bin/notes" <<EOF
#!/usr/bin/env bash
[ "\$*" = "--profile bnb path projects" ] && echo "$LAB"
EOF
  chmod +x "$SANDBOX/bin/notes"

  mkdir -p "$SANDBOX/gh"
  runs release.yml \
    "$(wfrun 11 v0.9.0 2026-11-01T11:00:00Z)" "$(wfrun 12 v1.1.0 2026-11-12T11:00:00Z)" \
    "$(wfrun 13 main 2026-11-05T10:00:00Z)" "$(wfrun 14 main 2026-11-11T10:00:00Z)" \
    "$(wfrun 15 other-v2.0.0 2026-11-12T13:00:00Z)" "$(wfrun 16 v1.1.0-puzzle1 2026-11-12T12:00:00Z)"
  runs steam.yml "$(wfrun 21 v0.9.0-kart1 2026-11-02T11:00:00Z)" "$(wfrun 22 v1.0.0-kart1 2026-11-10T12:00:00Z)"
  printf '%s' "[$(dep 31 kart-steam-beta v0.9.0-kart1 Kblack0610 '{"build":"777"}'),$(dep 32 kart-steam-beta v1.0.0-kart1 'github-actions[bot]' '{}'),$(dep 33 steam v1.1.0-puzzle1 Kblack0610 '"{\"build\": 88}"'),$(dep 34 steam v0.9.0 Kenneth '[1]')]" \
    > "$SANDBOX/gh/deployments.json"
  printf '[{"state":"success"}]' > "$SANDBOX/gh/statuses.json"
  # Run 13's log GitHub no longer keeps; LOG_FAIL names a run whose download breaks.
  gh_script <<'EOF'
printf '%s\n' "$*" >> "$SANDBOX/gh.calls"
ep="" q="."
while [ $# -gt 0 ]; do
  case "$1" in
    api|--paginate) ;;
    --jq) q="$2"; shift ;;
    *) ep="$1" ;;
  esac
  shift
done
case "$ep" in
  */actions/workflows/*/runs*) f="$SANDBOX/gh/runs-$(sed -E 's#.*/workflows/([^/]+)/runs.*#\1#' <<<"$ep").json" ;;
  */actions/runs/*/logs)
    id="$(sed -E 's#.*/runs/([0-9]+)/logs#\1#' <<<"$ep")"
    [ "$id" = 13 ] && { echo 'gh: Not Found (HTTP 410)' >&2; exit 1; }
    [ "$id" = "${LOG_FAIL:-}" ] && { echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1; }
    printf 'PKzip-of-%s' "$id"; exit 0 ;;
  */deployments/*/statuses*) [ -n "${STATUS_FAIL:-}" ] && exit 1; f="$SANDBOX/gh/statuses.json" ;;
  */deployments*) f="$SANDBOX/gh/deployments.json" ;;
  *) exit 1 ;;
esac
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -rc "$q" "$f"
EOF
  export SANDBOX
}

# tag <name> <tagger> <date> - a commit and an annotated tag on it by that tagger at that time.
tag() {
  GIT_COMMITTER_DATE="$3" git -C "$CODE" commit -q --allow-empty -m "$1"
  GIT_COMMITTER_DATE="$3" git -C "$CODE" -c user.name="$2" tag -a -m "$1" "$1"
}
wfrun() { printf '{"id":%s,"head_branch":"%s","event":"push","status":"completed","conclusion":"success","created_at":"%s","html_url":"https://x/%s"}' "$1" "$2" "$3" "$1"; }
runs() { local wf="$1"; shift; local IFS=,; printf '{"workflow_runs":[%s]}' "$*" > "$SANDBOX/gh/runs-$wf.json"; }
dep() { printf '{"id":%s,"environment":"%s","ref":"%s","description":"%s","creator":{"login":"%s"},"created_at":"2026-11-0%sT10:00:00Z","payload":%s}' "$1" "$2" "$3" "$3" "$4" "${1: -1}" "$5"; }

ledger() { cat "$LAB/game/versions/legacy.md"; }
section() { sed -n "/^## $1/,/^## /p" "$LAB/game/versions/legacy.md" | grep '^| [^-T]' | grep -v '^| Run \|^| Environment '; }

@test "ledger: legacy tags across the repo and its games, never a flow tag or another product's" {
  run "$ARC" unity-none 2>/dev/null
  assert_failure 2
  # A game shares the repo's checkout and its ledger: the repo project is the one to run.
  run "$ARC" kart
  assert_failure 2
  assert_output --partial 'run it for game'
  run "$ARC" game
  assert_success
  assert_output --partial 'tags 3 legacy of 6, runs 4'
  # The remote's tags are fetched first; one that cannot be reached is named, never silent.
  assert_output --partial 'game: tags not fetched'
  # The start of a line is flow (v1.0.0, its build), so is the cut workflow's tag; a game with
  # no line is legacy, its cut tag too; other-v2.0.0 belongs to no project here.
  assert_equal "$(section Tags | cut -d'|' -f2 | tr -d ' ' | sort | paste -sd,)" 'v0.9.0,v0.9.0-kart1,v1.1.0-puzzle1'
}

@test "ledger: release runs of a legacy tag or with no tag before the line, Deployments held to their owner" {
  run "$ARC" game
  assert_success
  # 11 (legacy tag), 13 (no tag, before v1.0.0), 16 (puzzle has no line), 21 (pre-line kart build).
  # 12 and 22 are flow, 14 started after the line, 15 is another product's tag.
  assert_equal "$(section 'Release runs' | sed -E 's/^\| \[([0-9]+)\].*/\1/' | sort | paste -sd,)" '11,13,16,21'
  assert_output --partial 'deployments 3, statuses not read 0'
  # A hand back-fill of a pre-line build with its store build; a job environment no target names is
  # held to the project owning its tag (puzzle: legacy), its payload's build decoded from a string;
  # a payload that is no object keeps its row, with no build.
  assert_equal "$(section Deployments | cut -d'|' -f2,3,4,7 | tr -d ' ' | sort | paste -sd,)" \
    'kart-steam-beta|v0.9.0-kart1|Kblack0610|777,steam|v0.9.0|Kenneth|-,steam|v1.1.0-puzzle1|Kblack0610|88'
  # Only release workflows are read: never the gallery's or a recorder.
  run grep -c 'workflows/shots.yml\|workflows/record.yml' "$SANDBOX/gh.calls"
  assert_output 0
  # A status that cannot be read is named and fails the run, so a rerun reads it.
  STATUS_FAIL=1 run "$ARC" game
  assert_failure 1
  assert_output --partial 'statuses not read 3'
}

@test "logs: each legacy run's zip is copied once, an expired one is named, a failed one fails the run" {
  export LOG_FAIL=16
  run "$ARC" game
  assert_failure 1
  assert_output --partial 'logs copied 2, already archived 0, expired 1, failed 1'
  assert_equal "$(cat "$RELEASE_ARCHIVE_DIR/game/11.zip")" 'PKzip-of-11'
  [ ! -e "$RELEASE_ARCHIVE_DIR/game/16.zip" ] && [ ! -e "$RELEASE_ARCHIVE_DIR/game/16.zip.part" ]
  assert_equal "$(section 'Release runs' | grep '\[13\]' | awk -F'|' '{print $8}' | tr -d ' ')" 'expired'
  # A rerun copies only what is missing.
  unset LOG_FAIL
  : > "$SANDBOX/gh.calls"
  run "$ARC" game
  assert_success
  assert_output --partial 'logs copied 1, already archived 2, expired 1, failed 0'
  run grep -c 'runs/11/logs' "$SANDBOX/gh.calls"
  assert_output 0
}

@test "dry run: prints the ledger and writes nothing" {
  run "$ARC" --dry-run game
  assert_success
  assert_output --partial '# Legacy releases: game'
  assert_output --partial 'game starts its line at v1.0.0; kart starts its line at v1.0.0; puzzle has no line yet'
  [ ! -e "$LAB/game/versions/legacy.md" ]
  [ ! -e "$RELEASE_ARCHIVE_DIR" ]
  # Negative control: --no-logs writes the ledger and still copies nothing.
  run "$ARC" --no-logs game
  assert_success
  [ -f "$LAB/game/versions/legacy.md" ]
  [ ! -e "$RELEASE_ARCHIVE_DIR" ]
}
