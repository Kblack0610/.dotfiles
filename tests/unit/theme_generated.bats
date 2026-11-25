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

@test "waybar's rendered palette.css is ignored" {
  run is_ignored .config/waybar/palette.css
  assert_success
}

@test "swaync's rendered stylesheet is ignored" {
  run is_ignored .config/swaync/style.css
  assert_success
}

@test "swaync's hand-authored config.json is tracked" {
  run is_ignored .config/swaync/config.json
  assert_failure
}

@test "noctalia's rendered palette is ignored" {
  run is_ignored .config/noctalia/palettes/dotfiles.json
  assert_success
}

@test "noctalia's hand-authored config.toml is tracked" {
  run is_ignored .config/noctalia/config.toml
  assert_failure
}

@test "hyprland's rendered theme.lua is ignored" {
  # Hyprland requires it (conf/look-and-feel.lua), so like sketchybar's colors.sh it is
  # also why the installers and the post-merge hook render it.
  run is_ignored .config/hypr/conf/theme.lua
  assert_success
}

@test "nvim's rendered theme module, starship.toml and lazygit's config.yml are ignored" {
  # They were tracked and sed-patched in place, so the day/night timers dirtied the main
  # checkout twice a day and the dirty-mains watch tripped on it (ar-4528).
  run is_ignored .config/nvim/lua/kennethblack/theme.lua
  assert_success
  run is_ignored .config/starship.toml
  assert_success
  run is_ignored .config/jesseduffield/lazygit/config.yml
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
  # init.lua is hand-authored config that requires the generated theme module -- it is
  # genuinely tracked, so git must say so.
  run is_ignored .config/nvim/lua/kennethblack/init.lua
  assert_failure
}

@test "a path git has never heard of is reported as not ignored" {
  run is_ignored .config/theme/definitely-not-a-real-path.conf
  assert_failure
}

# ── the canary ───────────────────────────────────────────────────────────────

@test "theme-switch's write targets are still the twelve that were classified" {
  # Every target is generated and ignored except one. .termux/colors.properties is
  # generated in full, yet must stay TRACKED: the phone never runs the switcher, so a
  # desktop generates the file and commits it and the phone picks it up on `git pull`
  # -- git is the transport, and an ignored file would never arrive. A full switch
  # therefore leaves it alone (next tests); only `--only termux` writes it.
  local expected
  expected="$(printf '%s\n' \
    .config/dunst/dunstrc.d/50-theme.conf \
    .config/hypr/conf/theme.lua \
    .config/jesseduffield/lazygit/config.yml \
    .config/kitty/current-theme.conf \
    .config/noctalia/palettes/dotfiles.json \
    .config/nvim/lua/kennethblack/theme.lua \
    .config/sketchybar/colors.sh \
    .config/starship.toml \
    .config/swaync/style.css \
    .config/waybar/palette.css \
    .config/waybar/style.css \
    .termux/colors.properties | sort -u)"

  run write_targets
  assert_success

  if [ "$output" != "$expected" ]; then
    echo "theme-switch's set of write targets changed." >&2
    echo "" >&2
    echo "Answer two questions, then update this test:" >&2
    echo "  1. Is the new target GENERATED in full from the palette/template?" >&2
    echo "     no  -> make it one: patching a tracked file in place dirties the" >&2
    echo "            main checkout on every switch (ar-4528). Render a module the" >&2
    echo "            config requires, or the whole file from templates/<tool>/." >&2
    echo "  2. If generated: does anything read it that CANNOT run theme-switch," >&2
    echo "     reaching it over git rather than off this disk?" >&2
    echo "     no  -> add it to .gitignore, and to the generated cases above," >&2
    echo "            and to THEME_TARGETS_<OS> in the installers' packages.conf." >&2
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

# --- a generated file gets its $HOME link from the writer ------------------

@test "theme-switch links a render that stow never will, only from the stowed checkout" {
  local root="$BATS_TEST_TMPDIR/dotfiles"
  mkdir -p "$root" "$HOME/.config/swaync" "$HOME/.config/noctalia"
  ln -s "$root" "$HOME/.dotfiles"
  DOTFILES_ROOT="$root" run "$THEME_SWITCH" batman --only swaync,noctalia
  assert_success
  # The relative link stow writes, resolving to the render.
  case "$(readlink "$HOME/.config/swaync/style.css")" in /*) false ;; esac
  assert_equal "$(readlink -f "$HOME/.config/swaync/style.css")" "$(readlink -f "$root/.config/swaync/style.css")"
  assert_equal "$(readlink -f "$HOME/.config/noctalia/palettes/dotfiles.json")" "$(readlink -f "$root/.config/noctalia/palettes/dotfiles.json")"
  # Negative control: a worktree render (DOTFILES_ROOT is not ~/.dotfiles) links nothing.
  rm "$HOME/.config/swaync/style.css"
  DOTFILES_ROOT="$BATS_TEST_TMPDIR/worktree" run "$THEME_SWITCH" batman --only swaync
  assert_success
  [ ! -e "$HOME/.config/swaync/style.css" ] && [ ! -L "$HOME/.config/swaync/style.css" ]
}

@test "theme-switch replaces a stale plain render, and leaves one a folded directory link serves" {
  local root="$BATS_TEST_TMPDIR/dotfiles"
  mkdir -p "$root" "$HOME/.config/swaync"
  ln -s "$root" "$HOME/.dotfiles"
  # The copy an unfold moved out of the checkout: a plain file, last switch's colours.
  echo stale > "$HOME/.config/swaync/style.css"
  DOTFILES_ROOT="$root" run "$THEME_SWITCH" batman --only swaync
  assert_success
  assert [ -L "$HOME/.config/swaync/style.css" ]
  assert_equal "$(readlink -f "$HOME/.config/swaync/style.css")" "$(readlink -f "$root/.config/swaync/style.css")"
  assert_equal "$(cat "$XDG_CACHE_HOME/theme-switch/replaced/.config/swaync/style.css")" stale
  # Folded: ~/.config/noctalia is the repo dir itself, so the render is already in place.
  mkdir -p "$root/.config/noctalia"
  ln -s "$root/.config/noctalia" "$HOME/.config/noctalia"
  DOTFILES_ROOT="$root" run "$THEME_SWITCH" batman --only noctalia
  assert_success
  assert [ -f "$root/.config/noctalia/palettes/dotfiles.json" ] && assert [ ! -L "$root/.config/noctalia/palettes/dotfiles.json" ]
}

@test "theme-switch links nothing for a tool not deployed on this machine" {
  local root="$BATS_TEST_TMPDIR/dotfiles"
  mkdir -p "$root"
  ln -s "$root" "$HOME/.dotfiles"
  DOTFILES_ROOT="$root" run "$THEME_SWITCH" batman --only swaync
  assert_success
  [ ! -e "$HOME/.config/swaync" ]
}

@test "the noctalia palette is JSON whose every colour is a hex value from the theme" {
  local root="$BATS_TEST_TMPDIR/dotfiles" out
  mkdir -p "$root"
  DOTFILES_ROOT="$root" run "$THEME_SWITCH" batman --only noctalia
  assert_success
  out="$root/.config/noctalia/palettes/dotfiles.json"
  # 16 dark roles, 6 terminal keys and 16 ANSI colours, each "#rrggbb": an unset palette
  # variable would leave "" or "#" and fail here.
  run jq -r '[.dark | .. | strings] | length, all(test("^#[0-9a-fA-F]{6}$"))' "$out"
  assert_success
  assert_output $'38\ntrue'
}

# --- a full switch writes no tracked file (ar-4528) -------------------------

@test "a full switch leaves the tracked termux render alone; --only termux writes it" {
  # --dry-run: a real full switch would signal the live kitty, dunst and hyprland.
  local root="$BATS_TEST_TMPDIR/dotfiles"
  mkdir -p "$root/.termux"
  DOTFILES_ROOT="$root" run "$THEME_SWITCH" arthur --dry-run
  assert_success
  assert_output --partial "termux: tracked render left as is"
  refute_output --partial "termux: would regenerate"
  # Negative control: naming it writes it.
  DOTFILES_ROOT="$root" run "$THEME_SWITCH" arthur --only termux
  assert_success
  run grep -c 'palettes/arthur.sh' "$root/.termux/colors.properties"
  assert_output 1
}

@test "nvim, starship and lazygit render only ignored files, the templates with the palette's colours" {
  local root="$BATS_TEST_TMPDIR/dotfiles" rel tpl="$REPO_ROOT/.local/src/theme/templates"
  mkdir -p "$root"
  DOTFILES_ROOT="$root" run "$THEME_SWITCH" arthur --only nvim,starship,lazygit
  assert_success
  # Every file the run wrote is one git ignores, so the main checkout stays clean.
  while IFS= read -r rel; do
    run is_ignored "$rel"
    assert_success
  done < <(cd "$root" && find . -type f | sed 's|^\./||')
  [ "$(cd "$root" && find . -type f | wc -l)" -eq 3 ]
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.local/src/theme/palettes/arthur.sh"
  grep -qF "success_symbol = \"[❯](bold $THEME_SUCCESS)\"" "$root/.config/starship.toml"
  grep -qF "\"$THEME_LG_ACTIVE_BORDER\"" "$root/.config/jesseduffield/lazygit/config.yml"
  # Same shape as the template: only colour values changed.
  assert_equal "$(wc -l < "$root/.config/starship.toml")" "$(wc -l < "$tpl/starship/starship.toml")"
  assert_equal "$(wc -l < "$root/.config/jesseduffield/lazygit/config.yml")" "$(wc -l < "$tpl/lazygit/config.yml")"
}

# The keys apply_nvim writes into kennethblack/theme.lua, and the ones the config reads.
nvim_written_keys() {
  sed -n '/^apply_nvim()/,/^}/p' "$THEME_SWITCH" | grep -oE '^ +[a-z_]+ = "\$\{THEME_' | awk '{ print $1 }' | sort -u
}
nvim_read_keys() {
  grep -ohE 'require\("kennethblack\.palette"\)\.[a-z_]+' "$REPO_ROOT"/.config/nvim/lua/kennethblack/init.lua \
    "$REPO_ROOT"/.config/nvim/lua/kennethblack/plugins/*.lua | sed 's/.*)\.//' | sort -u
}

@test "nvim's config reads exactly the keys theme-switch writes" {
  [ "$(nvim_written_keys | wc -l)" -eq 3 ]
  assert_equal "$(nvim_read_keys)" "$(nvim_written_keys)"
  # Negative control: a reader that drops a key does not compare equal.
  [ "$(nvim_read_keys | grep -v colorscheme)" != "$(nvim_written_keys)" ]
}
