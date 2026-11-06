#!/usr/bin/env bats
# projects.sh: the waybar projects chip. The bar is the icon and the count of projects in flight;
# the hover is one row per project with open work, in flight first, then by stage, and one fold
# line for the rest. What these pin: the chip prints hub's numbers and computes none; a stalled
# read reads ? in amber, never blank; a name is escaped; hub's errors show amber on the hover.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/projects.sh"
  ICON=$'\uf0ae' # nf-fa-tasks, as an escape so no editor can strip it
  G="#a6e34a" Y="#ffcc2f"
  export FX="$BATS_TEST_TMPDIR" HUB="$SANDBOX/bin/hub"
  cat > "$HUB" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "projects --json" ] || exit 2
[ -n "${HUB_FAIL:-}" ] && { echo "notes: boom" >&2; exit 1; }
cat "$FX/projects.json"
STUB
  chmod +x "$HUB"
}

# card <name> <stage> <percent|null> <eta|null> <open> <running> <waiting>
card() {
  jq -cn --arg n "$1" --arg s "$2" --argjson p "$3" --argjson e "$4" --argjson o "$5" \
    --argjson r "$6" --argjson w "$7" \
    '{name: $n, stage: $s, percent: $p, eta_days: $e, progress: {open: $o},
      running: [range($r) | {slug: "x"}], waiting: $w, in_flight: ($r > 0 or $w > 0)}'
}

# feed <errors-json> <card...>: hub's answer, cards in hub's order.
feed() {
  local errors="$1"
  shift
  printf '%s\n' "$@" | jq -s --argjson e "$errors" '{cards: ., unlinked: [], errors: $e}' > "$FX/projects.json"
}

text() { jq -r .text <<< "$output"; }
class() { jq -r .class <<< "$output"; }

@test "in flight first in hub's order, then open work by stage, the rest folded" {
  feed '[]' \
    "$(card zeta draft 10 null 3 0 0)" \
    "$(card web alpha 35 69 5 2 1)" \
    "$(card done prod 100 0 0 0 0)" \
    "$(card shop prod 52 54 4 0 0)" \
    "$(card game dev 2 null 9 0 1)"
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON 2"
  assert_equal "$(class)" ok
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line --index 0 "<b>Projects</b>  2 in flight, 5 total"
  assert_line --index 1 "<tt>web   alpha  [###.......]   35%  ETA 69d    <span color=\"$G\">2 running</span>, <span color=\"$Y\">1 waiting</span>"
  assert_line --index 2 "game  dev    [..........]    2%  no ETA     <span color=\"$Y\">1 waiting</span>"
  assert_line --index 3 "shop  prod   [#####.....]   52%  ETA 54d"
  assert_line --index 4 "zeta  draft  [#.........]   10%  no ETA"
  assert_line --index 5 "+1 more with nothing open</tt>"
}

@test "nothing in flight: the icon alone, no count" {
  feed '[]' "$(card shop prod 52 54 4 0 0)"
  run "$MODULE"
  assert_equal "$(text)" "$ICON"
}

@test "a project name is escaped for Pango" {
  feed '[]' "$(card 'a<b&c' alpha 0 null 1 1 0)"
  run "$MODULE"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_output --partial "<tt>a&lt;b&amp;c  alpha"
}

@test "hub's errors show amber on the hover and the chip turns warn" {
  feed '["agent-queue list: gone"]' "$(card shop prod 52 54 4 0 0)"
  run "$MODULE"
  assert_equal "$(class)" warn
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_output --partial "<span color=\"$Y\">error: agent-queue list: gone</span>"
}

@test "hub failing reads ? in amber with its error, never blank" {
  feed '[]'
  HUB_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(text)" "<span color='$Y'>$ICON ?</span>"
  assert_equal "$(class)" warn
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_output --partial "hub projects failed: notes: boom"
}

@test "hub answering garbage reads ?, not green" {
  printf 'not json\n' > "$FX/projects.json"
  run "$MODULE"
  assert_equal "$(text)" "<span color='$Y'>$ICON ?</span>"
}
