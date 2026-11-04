#!/usr/bin/env bats
# project-map add: the one way a project enters the registry.
#
# notes, project-map-doctor and the anchor regen are stubbed; every call lands in calls.log.
# The registry is a symlink, as stow makes it, so a write that replaced the link would show.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PM="$REPO_ROOT/.local/bin/project-map"
  LOG="$SANDBOX/calls.log"
  export LOG
  : > "$LOG"

  REPO="$SANDBOX/repos/mono"
  mkdir -p "$REPO/apps/alpha" "$SANDBOX/repos/solo/sub" "$SANDBOX/private"
  git -C "$REPO" init -q -b main
  git -C "$SANDBOX/repos/solo" init -q -b main

  REAL_MAP="$SANDBOX/private/project-map.json"
  cat > "$REAL_MAP" <<EOF
{
  "paths": { "$REPO": "mono", "/elsewhere/tools": "tools" },
  "aliases": { "monorepo": "mono" },
  "trackers": {
    "_comment": "a string value",
    "mono": { "system": "none" },
    "taken": { "repo": "mono", "lab": "alpha", "type": "app" }
  }
}
EOF
  MAP="$HOME/project-map.json"
  ln -s "$REAL_MAP" "$MAP"
  export PROJECT_MAP_FILE="$MAP"

  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
echo "notes $*" >> "$LOG"
if [ "$1 $2" = "config --profiles" ]; then printf 'alpha\nbeta\n'; exit 0; fi
exit "${NOTES_NEW_RC:-0}"
EOF
  cat > "$SANDBOX/bin/project-map-doctor" <<'EOF'
#!/usr/bin/env bash
echo "doctor" >> "$LOG"
exit "${DOCTOR_RC:-0}"
EOF
  REGEN_ANCHOR="$SANDBOX/bin/regen-anchor"
  cat > "$REGEN_ANCHOR" <<'EOF'
#!/usr/bin/env bash
echo "regen $*" >> "$LOG"
EOF
  chmod +x "$SANDBOX/bin/notes" "$SANDBOX/bin/project-map-doctor" "$REGEN_ANCHOR"
  export REGEN_ANCHOR
}

entry() { jq -c --arg n "$1" '.trackers[$n]' "$REAL_MAP"; }

# refused <args...> -- the add fails and the registry is byte-identical.
refused() {
  cp "$REAL_MAP" "$SANDBOX/before.json"
  run "$PM" add "$@"
  assert_failure
  cmp -s "$REAL_MAP" "$SANDBOX/before.json"
  [ -L "$MAP" ]
  run grep -c 'projects --new' "$LOG"
  assert_output 0
}

@test "an app inside a repo: entry written, lab scaffolded, anchor and doctor run, in order" {
  run "$PM" add beta-app --type app --lab beta --repo mono --path apps/alpha/ --branch develop
  assert_success
  assert_equal "$(entry beta-app)" '{"repo":"mono","path":"apps/alpha","branch":"develop","lab":"beta","type":"app"}'
  [ -L "$MAP" ]
  run grep -v 'config --profiles' "$LOG"
  assert_output "notes --profile beta projects --new beta-app
regen beta-app
doctor"
}

@test "a whole repo: --repo-dir registers the checkout under paths with the name" {
  run "$PM" add solo --type infra --repo-dir "$SANDBOX/repos/solo"
  assert_success
  assert_equal "$(jq -r --arg p "$SANDBOX/repos/solo" '.paths[$p]' "$REAL_MAP")" solo
  assert_equal "$(entry solo)" '{"type":"infra"}'
  run grep -c 'projects --new' "$LOG"
  assert_output 0
}

@test "a repo key paths already holds gains its type and lab" {
  run "$PM" add tools --type app --lab alpha
  assert_success
  assert_equal "$(entry tools)" '{"lab":"alpha","type":"app"}'
}

@test "a failed scaffold puts the registry back byte for byte" {
  cp "$REAL_MAP" "$SANDBOX/before.json"
  NOTES_NEW_RC=1 run "$PM" add gamma --type game --lab alpha --repo mono
  assert_failure
  assert_output --partial "back as it was"
  cmp "$REAL_MAP" "$SANDBOX/before.json"
  [ -L "$MAP" ]
}

@test "a failing doctor fails the command but keeps the entry" {
  DOCTOR_RC=1 run "$PM" add delta --type infra
  assert_failure
  assert_equal "$(entry delta)" '{"type":"infra"}'
}

@test "refused: a name already in trackers" { refused taken --type app; }
@test "refused: a repo key that already has a tracker entry" { refused mono --type app; }
@test "refused: an alias" { refused monorepo --type app; }
@test "refused: a bad name" { refused Bad.Name --type app; }
@test "refused: no type" { refused epsilon; }
@test "refused: a type outside the set" { refused epsilon --type client; }
@test "refused: --path without --repo" { refused epsilon --type app --path apps/alpha; }
@test "refused: --repo that is not a registry key" { refused epsilon --type app --repo nope; }
@test "refused: --path that is not a directory in the repo" { refused epsilon --type app --repo mono --path apps/zeta; }
@test "refused: --path escaping the repo" { refused epsilon --type app --repo mono --path ../x; }
@test "refused: --lab that is not a notes profile" { refused epsilon --type app --lab gamma; }
@test "refused: --repo and --repo-dir together" { refused epsilon --type app --repo mono --repo-dir "$SANDBOX/repos/solo"; }
@test "refused: --repo-dir below a checkout root" { refused epsilon --type app --repo-dir "$SANDBOX/repos/solo/sub"; }
@test "refused: --repo-dir already registered" { refused epsilon --type app --repo-dir "$REPO"; }
@test "refused: a repo key cannot also be part of another repo" { refused tools --type app --repo mono; }
