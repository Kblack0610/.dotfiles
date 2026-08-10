#!/usr/bin/env bats
# theme-switch writes nine files into the tracked tree. Three of them are the full
# RENDER of a tracked palette + template, and they used to be tracked themselves --
# so theme-day.timer and theme-night.timer, firing at 07:00 and 19:00, dirtied the
# repo twice a day for as long as they had existed. Every session inherited a
# working tree full of theme churn and had to decide, by hand, to hold it.
#
# The fix was to untrack the render. This file is what keeps it untracked.
#
# WHY THIS TIER, AND NOT "JUST RUN theme-switch"
# ----------------------------------------------
# The obvious test -- run theme-switch, assert `git status` is clean -- cannot be
# written honestly here. theme-switch hardcodes DOTFILES="$HOME/.dotfiles" with no
# override, so running it under the suite would write into the developer's REAL
# checkout: signals to live kitty/waybar processes, a rewritten wallpaper, and a
# mutated repo that outlives the test. That is precisely the state leak this repo
# already had to stop once. So this tier pins the INVARIANT the fix establishes
# rather than re-performing the action, and pays nothing for it.
#
# THE CANARY MATTERS MORE THAN THE THREE ASSERTIONS
# -------------------------------------------------
# Pinning today's three generated paths only defends today's bug. The failure that
# actually repeats is a TENTH write target added later, tracked by default, quietly
# restoring the loop. So the write targets are re-derived from theme-switch itself
# on every run: if that set changes at all, this file fails and forces the author to
# answer the one question that matters -- is the new target tracked, or generated?

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  THEME_SWITCH="$REPO_ROOT/.local/src/theme/theme-switch"
}

# Every path theme-switch writes under $DOTFILES, as the script itself declares them.
write_targets() {
  grep -o 'DOTFILES/[^"]*' "$THEME_SWITCH" | sed 's|^DOTFILES/||' | sort -u
}

# git's own answer, so the test cannot disagree with the tool that enforces it.
# Fails loudly rather than vacuously when git cannot answer at all: a check-ignore
# that errors looks exactly like "not ignored" to a naive `if`, and this suite has
# already been bitten once by a git call failing silently inside a container.
is_ignored() {
  cd "$REPO_ROOT" || return 2
  git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "theme_generated: not a usable git repository from $REPO_ROOT" >&2
    return 2
  }
  git check-ignore -q -- "$1"
}

# ── the three that must never be tracked again ───────────────────────────────

@test "kitty's rendered theme is ignored" {
  run is_ignored .config/kitty/current-theme.conf
  assert_success
}

@test "waybar's rendered stylesheet is ignored" {
  run is_ignored .config/waybar/style.css
  assert_success
}

@test "sketchybar's rendered colors.sh is ignored" {
  # The one with teeth beyond churn: sketchybarrc hard-`source`s this file, so it is
  # also the reason the installers must render it -- an ignored file is absent from a
  # fresh clone, and sketchybar would not start at all.
  run is_ignored .config/sketchybar/colors.sh
  assert_success
}

# ── negative control ─────────────────────────────────────────────────────────

@test "a TRACKED theme target is reported as not ignored" {
  # Without this, the three assertions above are unfalsifiable. If check-ignore were
  # broken, missing, or matching everything through some future catch-all rule, they
  # would all still pass and this file would certify a fix that had been undone.
  # starship.toml is hand-authored config that theme-switch patches in place -- it is
  # genuinely tracked, so git must say so.
  run is_ignored .config/starship.toml
  assert_failure
}

@test "a path git has never heard of is reported as not ignored" {
  run is_ignored .config/theme/definitely-not-a-real-path.conf
  assert_failure
}

# ── the canary ───────────────────────────────────────────────────────────────

@test "theme-switch's write targets are still the nine that were classified" {
  # Tracked: hand-authored config with values patched in place. These still churn on a
  # switch; converting each to its tool's native include (hyprland `source =`, lazygit
  # LG_CONFIG_FILE, an nvim palette module) is the unfinished half of the job.
  local expected
  expected="$(printf '%s\n' \
    .config/hypr/hyprland.conf \
    .config/jesseduffield/lazygit/config.yml \
    .config/kitty/current-theme.conf \
    .config/nvim/lua/kennethblack/init.lua \
    .config/nvim/lua/kennethblack/plugins/lualine.lua \
    .config/nvim/lua/kennethblack/plugins/neo-tree.lua \
    .config/sketchybar/colors.sh \
    .config/starship.toml \
    .config/waybar/style.css | sort -u)"

  run write_targets
  assert_success

  if [ "$output" != "$expected" ]; then
    echo "theme-switch's set of write targets changed." >&2
    echo "" >&2
    echo "Answer one question, then update this test:" >&2
    echo "  Is the new target GENERATED in full from the palette/template?" >&2
    echo "    yes -> add it to .gitignore, and to the generated cases above," >&2
    echo "           and to the installers' setup_theme --only list." >&2
    echo "    no  -> it is tracked config patched in place; add it to the" >&2
    echo "           expected list here and to the README's tracked column." >&2
    echo "" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$output") >&2 || true
    return 1
  fi
}
