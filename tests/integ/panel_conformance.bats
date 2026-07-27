#!/usr/bin/env bats
# Panel conformance: .tmux.conf and the panel sources, checked as DATA.
#
# Eleven popups grew one at a time over months, and every cross-cutting concern drifted
# independently -- six geometries, four fzf dialects, three palette schemes, ten scripts with
# no strict mode, five ways to resolve $0. None of it is detectable by running a panel; it is
# only visible by cross-referencing the whole set at once. This file is that cross-reference.
#
# It is the sibling of cockpit_binds.bats, which does the same trick for ONE script's verbs.
# The pattern generalises: build two lists, comm them, and guard the lint itself against
# matching nothing.
#
# Pure text -- no tmux, no fzf, no subject subprocess. That is deliberate: CI's `fast` job
# installs neither binary on purpose ("if a test ever starts reaching for a real binary, this
# job is where that shows up"), and this file must keep passing there.
#
# The popup itself is NOT tested here, because it cannot be: display-popup is a client-side
# overlay drawn onto client->tty, so it fails "no current client" rc=1 headless and never
# appears in list-panes even with a pty client attached. The bind is text; the script is a
# process; the overlay is neither, and a human pressing the key is its only test.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  load '../helpers/panel'
}

# ---------------------------------------------------------------------------
# Guard the lint before trusting it. .tmux.conf mixes `bind` and `bind-key`,
# bare keys and -T tables, single and double quotes -- and if the awk stops
# matching, every comm below passes vacuously. "Nothing to check" and
# "everything passed" print the same green.
# ---------------------------------------------------------------------------

@test "the parser can actually see the popups and the manifest" {
  local binds rows
  binds="$(panel_conf_bindings | grep -c .)"
  rows="$(panel_rows | grep -c .)"
  [ "$binds" -ge 10 ] || fail "parsed only $binds popup bindings from .tmux.conf -- the awk stopped matching"
  [ "$rows" -ge 10 ] || fail "read only $rows manifest rows -- the manifest is truncated or the filter is wrong"
}

@test "panel_field addresses columns by name, not position" {
  # If this breaks, every column-based assertion silently reads the wrong field.
  assert_equal "$(panel_field root:t path)" ".local/src/tmux/notes-cockpit.sh"
  assert_equal "$(panel_field root:t geometry)" "FULL"
  assert_equal "$(panel_field tags:l kind)" "bin-symlink"
  run panel_field root:NOPE path
  assert_failure
}

@test "every declared column resolves to a non-empty field" {
  # THE guard for panel_field. It located the header by content and locked onto the COLUMNS
  # documentation block instead -- whose lines also begin with "table" -- so every lookup
  # returned an empty string and the ratchets counted zero offenders while reporting green.
  # An empty field must never read as a passing assertion.
  local col
  for col in table key kind geometry path argv; do
    local v
    v="$(panel_field root:t "$col")" || fail "panel_field could not read column '$col' -- the header row was not located"
    [ -n "$v" ] || fail "column '$col' resolved to an EMPTY field for root:t"
  done
}

# ---------------------------------------------------------------------------
# Closure. Both directions, each naming the key, because the two failures mean
# opposite things: a bind with no row is an untested panel; a row with no bind
# is a manifest that has rotted past the config.
# ---------------------------------------------------------------------------

@test "every popup binding in .tmux.conf has a manifest row" {
  local missing
  missing="$(comm -23 \
    <(panel_conf_bindings | awk -F'\t' '{print $1 ":" $2}' | sort -u) \
    <(panel_rows | awk '{print $1 ":" $2}' | sort -u))"
  if [ -n "$missing" ]; then
    {
      echo "These popups are bound in .tmux.conf but absent from tests/panels.manifest."
      echo "A panel with no manifest row is a panel with no coverage:"
      printf '  %s\n' $missing
    } >&2
    return 1
  fi
}

@test "every manifest row is actually bound in .tmux.conf" {
  local orphan
  orphan="$(comm -13 \
    <(panel_conf_bindings | awk -F'\t' '{print $1 ":" $2}' | sort -u) \
    <(panel_rows | awk '{print $1 ":" $2}' | sort -u))"
  if [ -n "$orphan" ]; then
    {
      echo "These manifest rows have no popup binding -- the bind was dropped or rekeyed:"
      printf '  %s\n' $orphan
    } >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Every bound command must resolve to something that exists. This is the check
# that catches "renamed the script, forgot the bind" -- and it works on a CI
# runner where none of these tools are installed, because it stats files rather
# than executing anything.
# ---------------------------------------------------------------------------

@test "every panel's path exists and matches its declared kind" {
  local table key kind geometry path argv full
  while read -r table key kind geometry path argv; do
    full="$REPO_ROOT/$path"
    case "$kind" in
    script)
      [ -f "$full" ] || fail "$table:$key -> $path does not exist"
      [ -x "$full" ] || fail "$table:$key -> $path is not executable"
      run git -C "$REPO_ROOT" ls-files --error-unmatch "$path"
      assert_success
      ;;
    bin-symlink)
      # The bind calls a .local/bin name; the manifest points at the real source. Assert
      # the alias exists AND lands on that source, or the two drift apart unnoticed.
      [ -f "$full" ] || fail "$table:$key -> $path does not exist"
      [ -x "$full" ] || fail "$table:$key -> $path is not executable"
      ;;
    rust-bin)
      # Only the CRATE is in the repo; the binary is cargo-installed and absent from both
      # the repo and the test image. So conformance stops at the crate.
      [ -f "$full/Cargo.toml" ] || fail "$table:$key -> $path has no Cargo.toml"
      ;;
    *) fail "$table:$key has unknown kind '$kind'" ;;
    esac
  done < <(panel_rows)
}

@test "every bin-symlink panel's .local/bin alias resolves into .local/src" {
  local table key kind geometry path argv cmd base target
  while read -r table key kind geometry path argv; do
    [ "$kind" = bin-symlink ] || continue
    # Find the alias the bind actually invokes, and prove it lands on `path`.
    cmd="$(panel_conf_bindings | awk -F'\t' -v t="$table" -v k="$key" '$1==t && $2==k {print $5}')"
    base="$(basename "${cmd%% *}")"
    [ -L "$REPO_ROOT/.local/bin/$base" ] || fail "$table:$key invokes '$base' but .local/bin/$base is not a symlink"
    target="$(readlink "$REPO_ROOT/.local/bin/$base")"
    case "$target" in
    *"$(basename "$path")") ;;
    *) fail "$table:$key: .local/bin/$base -> $target, but the manifest says $path" ;;
    esac
  done < <(panel_rows)
}

@test "no popup composes shell inline instead of calling a script" {
  # `bind -T tags l` is the live offender: "tmux-tags ls; read -n 1". Inline shell in a bind
  # is unreachable from a test and undiscoverable from the script it half-lives in.
  #
  # RATCHET: 1 remaining -- tags:l, which becomes `tmux-tags ls --wait`.
  local offenders n
  offenders="$(panel_conf_bindings | awk -F'\t' '$5 ~ /;/ {print $1 ":" $2}')"
  n="$(printf '%s' "$offenders" | grep -c . || true)"
  if [ "$n" -ne 1 ]; then
    {
      echo "expected exactly 1 inline-shell popup (tags:l), found $n:"
      printf '  %s\n' $offenders
    } >&2
    return 1
  fi
  assert_equal "$offenders" "tags:l"
}

# ---------------------------------------------------------------------------
# Geometry.
#
# Verified in the container on tmux 3.7b AND 3.4: `%hidden PW_WIDE=90%` expands
# in flag-argument position, so the vocabulary can live as named constants in
# .tmux.conf itself. Two things that do NOT work, both verified rather than
# assumed:
#
#   - a variable holding a whole flag group ("-w 90% -h 85%") drops the bind
#     entirely, because tmux expands $VAR to a single token. Hence one constant
#     per flag.
#   - an UNDEFINED variable does not error and does not drop the bind: `-w $NOPE`
#     registers `-w ''`, an empty geometry, silently, with no diagnostic at load.
#     So this test must assert non-empty as well as in-vocabulary. tmux will not
#     tell us, and the first symptom would be a broken popup under a finger.
# ---------------------------------------------------------------------------

@test "every popup's geometry resolves to a non-empty value" {
  local table key w h cmd resolved rw rh
  while IFS=$'\t' read -r table key w h cmd; do
    resolved="$(panel_conf_geometry "$w" "$h")"
    read -r rw rh <<< "$resolved"
    [ -n "$rw" ] || fail "$table:$key has an EMPTY width (-w $w did not resolve; tmux binds this silently)"
    [ -n "$rh" ] || fail "$table:$key has an EMPTY height (-h $h did not resolve; tmux binds this silently)"
  done < <(panel_conf_bindings)
}

@test "popup geometry is in the sanctioned vocabulary" {
  # RATCHET: 8 of 11 popups are off-vocabulary today. .tmux.conf is normalised to
  # %hidden FULL/WIDE/SMALL in one late pass, deliberately AFTER every script owns its own
  # --border, so that adding -B cannot leave a surface frameless.
  #
  # Remaining: f and S (80%x80%), C-s (60%x50%), tags:l (70%x50%). The 90%x85% four are
  # already WIDE. Lower this number by exactly what you normalise.
  local max=4
  local table key w h cmd resolved rw rh offenders=() n
  while IFS=$'\t' read -r table key w h cmd; do
    resolved="$(panel_conf_geometry "$w" "$h")"
    read -r rw rh <<< "$resolved"
    panel_geometry_class "$rw" "$rh" >/dev/null || offenders+=("$table:$key ($rw x $rh)")
  done < <(panel_conf_bindings)

  n="${#offenders[@]}"
  if [ "$n" -gt "$max" ]; then
    {
      echo "$n popup(s) use an unsanctioned geometry, ratchet allows $max:"
      printf '  %s\n' "${offenders[@]}"
      echo
      echo "The vocabulary is FULL 100%x100% / WIDE 90%x85% / SMALL 80%x60%."
      echo "A NEW panel must use one of them -- the ratchet only covers known legacy."
    } >&2
    return 1
  fi
  [ "$n" -eq "$max" ] || fail "only $n off-vocabulary popup(s) left but the ratchet allows $max -- lower it to $n"
}

@test "every popup closes on exit" {
  # Without -E the popup lingers after its command returns and has to be dismissed by hand.
  # Unlike geometry there is no legacy here: all eleven already pass, so this is a real gate.
  local line
  while read -r line; do
    grep -qE '^\s*(bind|bind-key)\s' <<< "$line" || continue
    grep -qE ' -E( |$)|-[A-Za-z]*E[A-Za-z]* ' <<< "$line" \
      || fail "popup binding lacks -E (it will not close on exit): $line"
  done < <(grep -E '^\s*(bind|bind-key)\s.*display-popup' "$TMUX_CONF")
}

# ---------------------------------------------------------------------------
# Source conventions, as countdown ratchets.
#
# Each of these is a real defect class, not a style preference, and each has a
# live example named in the ratchet comment.
# ---------------------------------------------------------------------------

@test "panels have the strict-mode preamble" {
  # Without `set -u`, a typo'd variable expands to empty and the script carries on with a
  # wrong value instead of stopping.
  #
  # RATCHET: 1 -- pr-viewer.sh. (sessionizer.sh migrated onto panel-lib.sh.)
  panel_ratchet 1 "strict-mode preamble" panel_assert_strict_mode
}

@test "panels resolve \$SELF absolutely" {
  # fzf --bind re-invokes the script from inside the picker, where a relative $0 does not
  # resolve.
  #
  # RATCHET: 2.
  #   pr-viewer.sh       no SELF at all; :371 interpolates $0 directly into a reload()
  #   servers.sh:228     no SELF; embeds printf '%q' "$0" into the detach-client hop string,
  #                      which survives only because `tmx` happens to be on PATH
  # tags.sh:56 already conforms, via the explicit absolutize branch this assertion accepts.
  # sessionizer.sh and favourites.sh migrated onto panel-lib.sh.
  panel_ratchet 2 "absolute \$SELF" panel_assert_self_absolute
}

@test "no fzf action interpolates a bare \$0" {
  # pr-viewer.sh:371 -- `--bind "ctrl-r:reload(bash $0)"`. Unquoted, so it breaks on any
  # path containing a space, and the sandbox path contains one by design (sandbox.bash:32).
  # RATCHET: 1 -- pr-viewer.sh.
  panel_ratchet 1 "no bare \$0 in an fzf action" panel_assert_no_bare_dollar_zero
}

@test "no fzf action hardcodes the script's own name" {
  # A bare `notes-cockpit.sh --list` inside an action depends on PATH, which display-popup
  # does not guarantee. Generalises cockpit_binds.bats:85 to every panel. No legacy: 0.
  panel_ratchet 0 "no bare script name in an fzf action" panel_assert_no_bare_script_name
}

@test "panels never emit truecolor escapes" {
  # These surfaces are theme-responsive precisely BECAUSE they use ANSI indices: theme-switch
  # recolours the terminal's palette, so \033[1;32m follows a theme swap for free. Emitting
  # 38;2;R;G;B would pin a surface to one theme and stop it tracking. No legacy: 0.
  panel_ratchet 0 "ANSI indices only, no truecolor" panel_assert_no_truecolor
}
