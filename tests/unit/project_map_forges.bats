#!/usr/bin/env bats
# project-map forges: which forge each registered checkout lands on, by agent-land's own rule
# (so_forge_remote), read from the checkouts so the list cannot drift from them.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PM="$REPO_ROOT/.local/bin/project-map"
  export SO_FORGEJO_HOSTS="git.example.lan"
  R="$SANDBOX/repos"
  for n in canon broken fjorigin gh ghplus; do git init -q -b main "$R/$n"; done
  mkdir -p "$R/canon/.forgejo/workflows" "$R/broken/.forgejo/workflows"
  : > "$R/canon/.forgejo/workflows/mirror-to-github.yaml"
  : > "$R/broken/.forgejo/workflows/mirror-to-github.yml"
  git -C "$R/canon" remote add origin git@github.com:o/canon.git
  git -C "$R/canon" remote add forgejo https://git.example.lan/o/canon.git
  git -C "$R/broken" remote add origin https://github.com/o/broken.git
  git -C "$R/fjorigin" remote add origin ssh://git@git.example.lan:2222/o/fjorigin.git
  git -C "$R/gh" remote add origin https://github.com/o/gh.git
  git -C "$R/ghplus" remote add origin https://github.com/o/ghplus.git
  git -C "$R/ghplus" remote add forgejo https://git.example.lan/o/ghplus.git

  export PROJECT_MAP_FILE="$SANDBOX/project-map.json"
  jq -n --arg r "$R" '{paths: {
      ($r+"/canon"): "canon", ($r+"/broken"): "broken", ($r+"/fjorigin"): "fjorigin",
      ($r+"/gh"): "gh", ($r+"/ghplus"): "ghplus", ($r+"/gone"): "gone"}, trackers: {}}' > "$PROJECT_MAP_FILE"
}

row() { grep -E "^$1 " <<<"$output" | tr -s ' '; }

@test "forges: one row per checkout, sorted, by agent-land's forge rule" {
  run "$PM" forges
  assert_success
  assert_line --index 0 --regexp '^PROJECT +FORGE +REPO +MIRROR +REMOTES$'
  [ "$(row canon)" = "canon forgejo git.example.lan/o/canon github forgejo=git.example.lan origin=github.com" ]
  [ "$(row fjorigin)" = "fjorigin forgejo git.example.lan/o/fjorigin - origin=git.example.lan" ]
  [ "$(row gh)" = "gh github github.com/o/gh - origin=github.com" ]
  [ "$(row gone)" = "gone absent $R/gone - -" ]
  [ "$(sed -n '2p' <<<"$output" | cut -d' ' -f1)" = broken ]
}

@test "forges: a Forgejo remote that is not origin, with no mirror marker, still lands on GitHub" {
  run "$PM" forges
  assert_success
  [ "$(row ghplus)" = "ghplus github github.com/o/ghplus - forgejo=git.example.lan origin=github.com" ]
}

@test "forges: a mirror marker with no remote on a Forgejo host is named broken, never github" {
  run "$PM" forges
  assert_success
  [[ "$(row broken)" == "broken broken mirror marker but no remote on git.example.lan "* ]]
}

@test "forges: takes no arguments" {
  run "$PM" forges extra
  assert_failure 2
}
