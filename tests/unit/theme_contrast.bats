#!/usr/bin/env bats
# Every dim label in tmux, the panels and the hub is ANSI 8 (bright black), and
# the rest of the chrome is ANSI 1-15. Upstream kitty themes put bright black at
# 1.9 to 3.3:1 on their background, under WCAG AA's 4.5:1 for text, so the
# palettes lift those colours by lightness only. This file keeps them lifted,
# and keeps kitty reading them from the palette rather than a second copy.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  THEME="$REPO/.local/src/theme"
  NAMES=(BLACK RED GREEN YELLOW BLUE MAGENTA CYAN WHITE
    BRIGHT_BLACK BRIGHT_RED BRIGHT_GREEN BRIGHT_YELLOW
    BRIGHT_BLUE BRIGHT_MAGENTA BRIGHT_CYAN BRIGHT_WHITE)
}

# Prints "<name> <ratio>" for each of ANSI 1-15 under 4.5:1 on THEME_BG, and
# "BRIGHT_BLACK>=FG" when the dim colour is not dimmer than the text colour.
contrast_failures() {
  python3 -I - "$1" <<'PY'
import re, sys
vals = dict(re.findall(r'^THEME_([A-Z_]+)="(#[0-9a-fA-F]{6})"', open(sys.argv[1]).read(), re.M))
def lum(h):
    c = [int(h[i:i+2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)
names = ["RED", "GREEN", "YELLOW", "BLUE", "MAGENTA", "CYAN", "WHITE", "BRIGHT_BLACK",
         "BRIGHT_RED", "BRIGHT_GREEN", "BRIGHT_YELLOW", "BRIGHT_BLUE", "BRIGHT_MAGENTA",
         "BRIGHT_CYAN", "BRIGHT_WHITE"]
for n in names:
    if n not in vals:
        print(n, "missing"); continue
    r = ratio(vals[n], vals["BG"])
    if r < 4.5:
        print(n, "%.2f" % r)
if ratio(vals["BRIGHT_BLACK"], vals["BG"]) >= ratio(vals["FG"], vals["BG"]):
    print("BRIGHT_BLACK>=FG")
PY
}

@test "every palette's ANSI 1-15 reads at 4.5:1 on its background, bright black under FG" {
  local p out bad=""
  for p in "$THEME"/palettes/*.sh; do
    out=$(contrast_failures "$p")
    [ -z "$out" ] || bad+="$(basename "$p"): ${out//$'\n'/, }"$'\n'
  done
  [ -z "$bad" ] || fail "under 4.5:1 or bright black not dim: $bad"
}

@test "negative control: a palette with upstream Batman's blue fails the check" {
  local p="$BATS_TEST_TMPDIR/low.sh"
  sed 's/^THEME_BLUE=.*/THEME_BLUE="#737074"/' "$THEME/palettes/batman.sh" > "$p"
  run contrast_failures "$p"
  assert_output --partial "BLUE 3."
}

@test "kitty templates carry no ANSI, background or foreground: the palette is their one source" {
  run grep -lE '^(background|foreground|color([0-9]|1[0-5]))[[:space:]]' "$THEME"/templates/kitty/*.conf
  assert_failure 1
  assert_output ""
}

@test "theme-switch renders kitty's 16 ANSI colours from the palette" {
  local fn i var want
  fn=$(sed -n '/^apply_kitty() {/,/^}/p' "$THEME/theme-switch")
  [ -n "$fn" ] || fail "apply_kitty not found in theme-switch"
  mkdir -p "$BATS_TEST_TMPDIR/.config/kitty"
  # shellcheck source=/dev/null
  source "$THEME/palettes/batman.sh"
  DRY_RUN=false DOTFILES="$BATS_TEST_TMPDIR" SCRIPT_DIR="$THEME"
  info() { :; }; warn() { echo "$*"; }; pgrep() { return 1; }
  eval "$fn"
  apply_kitty
  local out="$BATS_TEST_TMPDIR/.config/kitty/current-theme.conf"
  for i in "${!NAMES[@]}"; do
    var="THEME_${NAMES[$i]}"; want="${!var}"
    grep -qE "^color$i[[:space:]]+$want\$" "$out" || fail "color$i is not $want in: $(cat "$out")"
  done
  grep -qE "^background[[:space:]]+$THEME_BG\$" "$out" || fail "background is not $THEME_BG"
  grep -qE "^cursor[[:space:]]" "$out" || fail "the template's cursor line is missing"
}
