#!/usr/bin/env bats
# theme-switch writes eleven files into the tracked tree. Three of them are the full
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

@test "dunst's rendered color drop-in is ignored" {
  run is_ignored .config/dunst/dunstrc.d/50-theme.conf
  assert_success
}

@test "hyprland's rendered theme.lua is ignored" {
  # Hyprland requires it (conf/look-and-feel.lua), so like sketchybar's colors.sh it is
  # also why the installers and the post-merge hook render it.
  run is_ignored .config/hypr/conf/theme.lua
  assert_success
}

@test "dunst's hand-authored dunstrc is tracked, not swept up with its drop-in" {
  # The drop-in sits under the same .config/dunst/ directory as the layout file it
  # overrides; an ignore rule one level too wide would untrack the layout too.
  run is_ignored .config/dunst/dunstrc
  assert_failure
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

@test "theme-switch's write targets are still the eleven that were classified" {
  # Tracked: hand-authored config with values patched in place. These still churn on a
  # switch; converting each to its tool's native include (lazygit LG_CONFIG_FILE, an nvim
  # palette module) is the unfinished half of the job.
  #
  # .termux/colors.properties is the exception to the binary below: it is generated in
  # full, yet must stay TRACKED. The phone never runs the switcher, so a desktop
  # generates the file and commits it and the phone picks it up on `git pull` --
  # git is the transport, and an ignored file would never arrive. It is the one
  # target that pays the twice-daily churn on purpose.
  local expected
  expected="$(printf '%s\n' \
    .config/dunst/dunstrc.d/50-theme.conf \
    .config/hypr/conf/theme.lua \
    .config/jesseduffield/lazygit/config.yml \
    .config/kitty/current-theme.conf \
    .config/nvim/lua/kennethblack/init.lua \
    .config/nvim/lua/kennethblack/plugins/lualine.lua \
    .config/nvim/lua/kennethblack/plugins/neo-tree.lua \
    .config/sketchybar/colors.sh \
    .config/starship.toml \
    .config/waybar/style.css \
    .termux/colors.properties | sort -u)"

  run write_targets
  assert_success

  if [ "$output" != "$expected" ]; then
    echo "theme-switch's set of write targets changed." >&2
    echo "" >&2
    echo "Answer two questions, then update this test:" >&2
    echo "  1. Is the new target GENERATED in full from the palette/template?" >&2
    echo "     no  -> it is tracked config patched in place; add it to the" >&2
    echo "            expected list here and to the README's tracked column." >&2
    echo "  2. If generated: does anything read it that CANNOT run theme-switch," >&2
    echo "     reaching it over git rather than off this disk?" >&2
    echo "     no  -> add it to .gitignore, and to the generated cases above," >&2
    echo "            and to the installers' setup_theme --only list." >&2
    echo "     yes -> it must stay tracked or it never reaches that consumer" >&2
    echo "            (this is .termux/colors.properties and the phone). Add it" >&2
    echo "            to the expected list here and to the README, and say in" >&2
    echo "            both WHY it is tracked despite being generated." >&2
    echo "" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$output") >&2 || true
    return 1
  fi
}

# --- the generated module and its reader agree ------------------------------

# The keys apply_hyprland writes into conf/theme.lua, read out of the function itself.
hypr_written_keys() {
  sed -n '/^apply_hyprland()/,/^}/p' "$THEME_SWITCH" | grep -oE '^ +[a-z0-9]+ += "\$\{THEME_' \
    | awk '{ print $1 }' | sort -u
}

# The theme.<key> fields conf/look-and-feel.lua reads (not the file name conf/theme.lua).
hypr_read_keys() {
  grep -oE '(^|[^/.a-z_])theme\.[a-z0-9]+' "$REPO_ROOT/.config/hypr/conf/look-and-feel.lua" | sed 's/^.*theme\.//' | sort -u
}

@test "hyprland's look-and-feel reads exactly the colors theme-switch writes" {
  # The Lua config requires the generated module, so a key renamed on one side only
  # is a nil color at load, not a silent no-op like the old sed patch was.
  grep -q 'require, "conf.theme")' "$REPO_ROOT/.config/hypr/conf/look-and-feel.lua"
  [ "$(hypr_written_keys | wc -l)" -eq 4 ]
  assert_equal "$(hypr_read_keys)" "$(hypr_written_keys)"
}

@test "the key comparison above is not vacuous" {
  # Negative control: a reader that drops a key must not compare equal.
  run bash -c "$(declare -f hypr_written_keys hypr_read_keys); THEME_SWITCH='$THEME_SWITCH' REPO_ROOT='$REPO_ROOT'; [ \"\$(hypr_read_keys | grep -v shadow)\" = \"\$(hypr_written_keys)\" ]"
  assert_failure
}

# --- the tracked termux render is current ----------------------------------

@test "the committed termux colors.properties is what its palette renders" {
  # The phone reads the committed copy, so a palette edit committed without its
  # render leaves the phone on old colors and dirties every desktop at the next
  # day/night timer (2026-11: #950 lifted batman's ANSI contrast, the render stayed,
  # and the dirty tree on razer-laptop failed the convergence-check's git task).
  local committed="$REPO_ROOT/.termux/colors.properties" theme root
  theme="$(sed -n 's|^# colors.properties - GENERATED by theme-switch from palettes/\(.*\)\.sh$|\1|p' "$committed")"
  [ -n "$theme" ]
  root="$BATS_TEST_TMPDIR/dotfiles"
  mkdir -p "$root/.termux"
  DOTFILES_ROOT="$root" run "$THEME_SWITCH" "$theme" --only termux
  assert_success
  run diff "$committed" "$root/.termux/colors.properties"
  assert_success
}
