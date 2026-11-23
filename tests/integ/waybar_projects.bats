#!/usr/bin/env bats
# projects.sh: the waybar projects chip. The bar is the icon and the count of projects in flight;
# the hover is a Sprint block when one runs, one row per project in flight (or with a window) with
# its running work by category under it, and one line naming the rest. What these pin: the chip prints hub's numbers and computes none; a stalled
# read reads ? in amber, never blank; a name is escaped; hub's errors show amber on the hover.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/projects.sh"
  ICON=$'\uf0ae' # nf-fa-tasks, as an escape so no editor can strip it
  G="#a6e34a" Y="#ffcc2f" R="#ef5734" D="#7f7f7f"
  export FX="$BATS_TEST_TMPDIR" HUB="$SANDBOX/bin/hub"
  cat > "$HUB" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "projects --json" ] || exit 2
[ -n "${HUB_FAIL:-}" ] && { echo "notes: boom" >&2; exit 1; }
cat "$FX/projects.json"
STUB
  chmod +x "$HUB"
}

# card <name> <stage> <delivered/committed|-> <open> <running> <waiting> [state] [level] [areas]:
# "-" is no open window; the state defaults to hub's words for a window (on track) or none (flow,
# no hue), "none" is no state, "null" level is grey; areas is hub's running_areas JSON.
card() {
  jq -cn --arg n "$1" --arg s "$2" --arg w "$3" --argjson o "$4" \
    --argjson r "$5" --argjson q "$6" --arg st "${7:-}" --arg lv "${8:-}" --argjson a "${9:-[]}" \
    '(if $w == "-" then [0, 0] else $w | split("/") | map(tonumber) end) as [$d, $c]
     | {name: $n, stage: $s, progress: {open: $o},
      state: (if $st == "none" then "" elif $st != "" then $st elif $w == "-" then "flow" else "on track" end),
      state_level: (if $lv == "null" then null elif $lv != "" then $lv elif $w == "-" then null else "ok" end),
      window: (if $w == "-" then null else {delivered: $d, committed: $c} end),
      window_says: (if $w == "-" then "no window" else "\($w) due 11-22" end),
      window_share: (if $w == "-" then null else ($d * 100 / $c | floor) end),
      running: [range($r) | {slug: "x"}], running_areas: $a, waiting: $q, in_flight: ($r > 0 or $q > 0)}'
}

sp() { printf '%*s' "$1" ''; }

# feed <errors-json> <card...>: hub's answer, cards in hub's order, with the Projects card figures
# hub-core sends with them (none on a partial read, as widget_doc::figures drops a failed card's).
feed() {
  local errors="$1"
  shift
  printf '%s\n' "$@" | jq -s --argjson e "$errors" '{cards: ., unlinked: [], errors: $e}
    | .figures = (if $e == [] then {projects_in_flight: ([.cards[] | select(.in_flight)] | length),
        projects_headline: (.cards | length), projects_sprints: ([.cards[] | select(.sprint_says != null)] | length)}
      else {} end)' > "$FX/projects.json"
}

text() { jq -r .text <<< "$output"; }
class() { jq -r .class <<< "$output"; }

@test "a row per project in flight in hub's order, its areas under it; a window keeps a row and says its state in its hue; the rest are one line" {
  feed '[]' \
    "$(card web alpha 21/60 5 2 1 '' '' '[{"area":"dispatch","n":1},{"area":"no epic","n":1}]')" \
    "$(card game dev - 9 0 1)" \
    "$(card shop prod 130/250 4 0 0 late bad)" \
    "$(card zeta draft 1/10 3 0 0 parked null)" \
    "$(card done prod - 0 0 0)" \
    "$(card base dev - 2 0 0 idle warn)" \
    "$(card ship beta - 2 0 0 late bad)"
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON 2"
  assert_equal "$(class)" ok
  local want
  want="<b>Projects</b>  2 in flight, 7 total

<tt>web   <span color=\"$G\">2 running</span>  <span color=\"$Y\">1 waiting</span>  <span color=\"$G\">on track</span> 21/60 due 11-22
  dispatch 1, <span color=\"$D\">no epic 1</span>
game$(sp 13)<span color=\"$Y\">1 waiting</span>
shop$(sp 24)<span color=\"$R\">late</span> 130/250 due 11-22
zeta$(sp 24)<span color=\"$D\">parked</span> 1/10 due 11-22
ship$(sp 24)<span color=\"$R\">late</span> no window
Not running: done, base</tt>"
  assert_equal "$(jq -r .tooltip <<< "$output")" "$want"
  # NEGATIVE CONTROL: a project in flow says no state and no window; only the late one with no
  # window says it, as the cause.
  assert_equal "$(grep -o 'no window' <<< "$output" | wc -l)" 1
  refute_output --partial "flow"
}

@test "past four systems the areas line says +N more, and no epic stays last" {
  feed '[]' "$(card web alpha - 5 9 0 '' '' '[{"area":"a","n":3},{"area":"b","n":2},{"area":"c","n":1},{"area":"d","n":1},{"area":"e","n":1},{"area":"no epic","n":1}]')"
  run "$MODULE"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line "  a 3, b 2, c 1, d 1, +1 more, <span color=\"$D\">no epic 1</span></tt>"
}

@test "nothing in flight: the icon alone, no count" {
  feed '[]' "$(card shop prod 13/25 4 0 0)"
  run "$MODULE"
  assert_equal "$(text)" "$ICON"
}

@test "a project name is escaped for Pango" {
  feed '[]' "$(card 'a<b&c' alpha - 1 1 0)"
  run "$MODULE"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_output --partial "<tt>a&lt;b&amp;c  <span color=\"$G\">1 running</span>"
}

# Negative control for a chip that recounts: the numbers are hub-core's figures as sent, so
# figures that differ from the cards print as sent.
@test "the counts are the Projects card figures, never a count of the cards" {
  feed '[]' "$(card web alpha 21/60 5 2 1)" "$(card shop prod 13/25 4 0 0)"
  jq '.figures = {projects_in_flight: 7, projects_headline: 30, projects_sprints: 0}' "$FX/projects.json" > "$FX/f" && mv "$FX/f" "$FX/projects.json"
  run "$MODULE"
  assert_equal "$(text)" "$ICON 7"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line --index 0 "<b>Projects</b>  7 in flight, 30 total"
}

@test "hub's errors show amber on the hover and the chip turns warn; the counts it then has no figure for read ? and -" {
  # An unread queue states no card (hub_core::projects::build): its state cell is a grey dash.
  feed '["agent-queue list: gone"]' "$(card shop prod 13/25 4 1 0 none null | jq -c '.sprint_says = "v1 4/15" | .window = {version: "v1", delivered: 4, committed: 15}')"
  export PANGO_PALETTE="$BATS_TEST_TMPDIR/palette.css"
  echo '@define-color palette_accent #123456;' > "$PANGO_PALETTE"
  run "$MODULE"
  assert_equal "$(class)" warn
  assert_equal "$(text)" "$ICON <span color='$Y'>?</span>  <span color='#123456'>S:</span><span color='$Y'>?</span>"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line --index 0 "<b>Projects</b>  - in flight, - total"
  assert_line "  shop  v1 4/15  <span color=\"$D\">-</span>"
  assert_output --partial "<span color=\"$Y\">error: agent-queue list: gone</span>"
  assert_output --partial "shop  <span color=\"$G\">1 running</span>  <span color=\"$D\">-</span> 13/25 due 11-22"
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

# A running sprint is hub's `sprint_says` (a sprint lock holds the open window): the bar shows one
# itself after S:, its window's version and delivered/committed, an at-risk or late one first and
# amber, +N past one; the hover leads with one line each. Negative control: no card with
# sprint_says leaves no S on the bar and no sprint lines.
@test "running sprints: S: and the sprint itself on the bar, at-risk first and amber, one hover line each" {
  export PANGO_PALETTE="$BATS_TEST_TMPDIR/palette.css"
  echo '@define-color palette_accent #123456;' > "$PANGO_PALETTE"
  S="<span color='#123456'>S:</span>"
  sprint() { jq -c --arg v "$1" '.sprint_says = "\($v) 4/15 due 11-22, locked 18:05" | .window = {version: $v, delivered: 4, committed: 15}'; }
  feed '[]' "$(card game beta 4/15 9 1 0 | sprint v0.5.4)" "$(card shop prod 13/25 4 0 0)"
  run "$MODULE"
  assert_equal "$(text)" "$ICON 1  ${S}v0.5.4 4/15"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line "<b>Sprint</b>"
  assert_line "  game  v0.5.4 4/15 due 11-22, locked 18:05  <span color=\"$G\">on track</span>"
  feed '[]' "$(card game beta 4/15 9 1 0 'at risk' warn | sprint v0.5.4)"
  run "$MODULE"
  assert_equal "$(text)" "$ICON 1  ${S}<span color='$Y'>v0.5.4 4/15</span>"
  # Two sprints: the healthy one comes first in hub's order, the late one is shown, amber, +1.
  feed '[]' "$(card game beta 4/15 9 1 0 | sprint v0.5.4)" "$(card shop prod 4/15 4 0 0 late bad | sprint v2.0.0)"
  run "$MODULE"
  assert_equal "$(text)" "$ICON 1  ${S}<span color='$Y'>v2.0.0 4/15 +1</span>"
  feed '[]' "$(card game beta 4/15 9 1 0 | sprint v0.5.4)" "$(card shop prod 4/15 4 0 0 | sprint v2.0.0)"
  run "$MODULE"
  assert_equal "$(text)" "$ICON 1  ${S}v0.5.4 4/15 +1"
  # NEGATIVE CONTROL
  feed '[]' "$(card game beta 4/15 9 1 0)"
  run "$MODULE"
  assert_equal "$(text)" "$ICON 1"
  refute_output --partial "Sprint"
}
