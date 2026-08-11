#!/usr/bin/env bats
# panel-lib.sh -- the shared floor every panel stands on.
#
# Unit tier: the library is SOURCED, so these are pure function tests with no subprocess.
# That is the whole reason panel-lib.sh insists the caller set $SELF from ${BASH_SOURCE[0]}
# rather than $0 -- under `source`, $0 is the bats runner.
#
# _skeleton.sh is the library's first consumer and doubles as the fixture. Testing the
# template rather than a mock means the template cannot rot: if the skeleton stops working,
# every panel copied from it inherits the break, and this file goes red first.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PANEL_LIB="$REPO_ROOT/.local/src/tmux/panel-lib.sh"
  SKELETON="$REPO_ROOT/.local/src/tmux/_skeleton.sh"
  export PANEL_LIB SKELETON
}

# Source the library the way a real panel does.
load_lib() {
  SELF="${1:-$SKELETON}"
  # shellcheck disable=SC1090
  . "$PANEL_LIB"
}

# ── The contract with the caller ─────────────────────────────────────────────

@test "sourcing without SELF fails loudly instead of half-initialising" {
  # A library that limps on with PANEL_DIR unset would fail much later, somewhere unrelated.
  run bash -c 'unset SELF; . "$1"' _ "$PANEL_LIB"
  assert_failure
  assert_output --partial 'must set SELF'
}

@test "PANEL_DIR and PANEL_NAME derive from SELF" {
  load_lib
  assert_equal "$PANEL_DIR" "$REPO_ROOT/.local/src/tmux"
  assert_equal "$PANEL_NAME" "_skeleton"
}

@test "the strict-mode preamble is actually in effect" {
  # Prove `set -u` took, rather than trusting that the line is present. A panel that thinks
  # it is strict and is not gets the worst of both.
  # The abort is contained in a subshell so this asserts a chosen exit code rather than
  # bash's 127-for-unbound, which bats otherwise flags as a probable typo.
  run bash -c 'SELF="$2"; . "$1"; ( echo "${NOPE_DEFINITELY_UNSET}" ) 2>&1; exit 9' \
    _ "$PANEL_LIB" "$SKELETON"
  assert_equal "$status" 9
  assert_output --partial 'unbound variable'
}

@test "pipefail is on but errexit is deliberately off" {
  load_lib
  [[ "$(set -o | awk '$1=="pipefail"{print $2}')" == on ]]
  # -e is NOT set, on purpose: a grep -q miss and a failing command substitution are normal
  # control flow in a picker, so -e would abort mid-render. If someone "fixes" this, the
  # panels start dying on ordinary misses.
  [[ "$(set -o | awk '$1=="errexit"{print $2}')" == off ]]
}

@test "PATH gains ~/.local/bin exactly once, however many times we source" {
  load_lib
  load_lib
  load_lib
  local n
  n="$(tr ':' '\n' <<< "$PATH" | grep -cxF "$HOME/.local/bin")"
  assert_equal "$n" 1
}

# ── Palette ──────────────────────────────────────────────────────────────────

@test "the palette uses ANSI indices only, never truecolor" {
  # This is what keeps these surfaces theme-responsive: theme-switch recolours the TERMINAL
  # palette, so an index follows a theme swap for free. A hex triple would pin the surface to
  # one theme and stop it tracking -- a regression that looks like a feature.
  load_lib
  local c
  for c in "$C_HEAD" "$C_SEL" "$C_INP" "$C_ERR" "$C_DIM" "$C_BOX" "$C_PROJ" "$C_ACC"; do
    [ -n "$c" ] || fail "a palette entry is empty with colour enabled"
    if grep -qE '38;(2|5);' <<< "$c"; then fail "palette entry uses truecolor/256-colour: ${c@Q}"; fi
  done
}

@test "PANEL_NO_COLOR blanks every palette entry" {
  PANEL_NO_COLOR=1 load_lib
  local c
  for c in C_HEAD C_SEL C_INP C_ERR C_DIM C_BOX C_PROJ C_ACC C_OFF; do
    assert_equal "${!c}" ""
  done
}

@test "NO_COLOR is honoured as well as PANEL_NO_COLOR" {
  # The cross-tool convention. Supporting only our own variable would be needless.
  NO_COLOR=1 load_lib
  assert_equal "$C_SEL" ""
}

@test "glyphs map to a stable colour, and an unknown glyph is dim" {
  load_lib
  assert_equal "$(panel_glyph_color "$G_ATTN")" "$C_ERR"
  assert_equal "$(panel_glyph_color "$G_BUSY")" "$C_INP"
  assert_equal "$(panel_glyph_color "$G_OK")" "$C_SEL"
  assert_equal "$(panel_glyph_color "$G_IDLE")" "$C_DIM"
  assert_equal "$(panel_glyph_color 'q')" "$C_DIM"
}

@test "the four glyphs are distinct" {
  # Two glyphs collapsing onto one character would make two states indistinguishable in the
  # status line, silently.
  load_lib
  local n
  n="$(printf '%s\n' "$G_ATTN" "$G_BUSY" "$G_OK" "$G_IDLE" | sort -u | wc -l)"
  assert_equal "$n" 4
}

# ── Diagnostics ──────────────────────────────────────────────────────────────

@test "panel_warn writes to stderr, not stdout" {
  # Load-bearing: these scripts are also CLIs that agents parse. A diagnostic on stdout
  # corrupts the row stream feeding fzf.
  load_lib
  run --separate-stderr bash -c 'SELF="$2"; . "$1"; panel_warn "a problem"' _ "$PANEL_LIB" "$SKELETON"
  assert_equal "$output" ""
  [[ "$stderr" == *"_skeleton: a problem"* ]]
}

@test "panel_fail returns 1 and panel_die exits 1" {
  load_lib
  run bash -c 'SELF="$2"; . "$1"; panel_fail nope; echo "still here rc=$?"' _ "$PANEL_LIB" "$SKELETON"
  assert_success
  assert_output --partial 'still here rc=1'

  run bash -c 'SELF="$2"; . "$1"; panel_die nope; echo NOT_REACHED' _ "$PANEL_LIB" "$SKELETON"
  assert_failure
  refute_output --partial 'NOT_REACHED'
}

@test "panel_fail inside a command substitution does not kill the caller" {
  # THE reason fail and die are separate. tags.sh:66 spells out the trap: an `exit` inside
  # $( ) kills only the subshell, so the caller carries on with an EMPTY result -- and for a
  # filter, silently falls back to matching everything. This pins the distinction.
  run bash -c '
    SELF="$2"; . "$1"
    v="$(panel_fail "in a subshell" || true)"
    echo "caller alive, v=[${v}]"
  ' _ "$PANEL_LIB" "$SKELETON"
  assert_success
  assert_output --partial 'caller alive, v=[]'
}

@test "panel_have and panel_need agree, and need names the missing command" {
  load_lib
  panel_have bash
  run panel_have definitely-not-a-real-binary-xyz
  assert_failure

  run bash -c 'SELF="$2"; . "$1"; panel_need bash definitely-not-a-real-binary-xyz' _ "$PANEL_LIB" "$SKELETON"
  assert_failure
  assert_output --partial 'definitely-not-a-real-binary-xyz is not on PATH'
}

# ── Usage ────────────────────────────────────────────────────────────────────

@test "panel_usage prints the whole header block, with no hardcoded line range" {
  # Replaces servers.sh:436's `sed -n '2,40p'`, which truncates the moment the header grows
  # past line 40. Assert on the LAST line of the block, which is what a range would drop.
  load_lib
  run panel_usage "$SKELETON"
  assert_success
  assert_output --partial 'Usage: _skeleton.sh [verb]'
  assert_output --partial 'conformance tier covers the template itself'
  refute_output --partial 'SELF="$(realpath'   # stops at the first non-comment line
  refute_output --partial '#!/usr/bin/env'     # drops the shebang
}

@test "panel_usage survives a header longer than any fixed range" {
  load_lib
  local long="$SANDBOX/long.sh"
  {
    echo '#!/usr/bin/env bash'
    for i in $(seq 1 60); do echo "# line $i"; done
    echo 'echo body'
  } > "$long"
  run panel_usage "$long"
  assert_output --partial 'line 60'
}

# ── fzf ──────────────────────────────────────────────────────────────────────

@test "PANEL_FZF_OPTS is an array, so a path with a space survives" {
  # The sandbox path contains a space by design (sandbox.bash:32). A string of flags would
  # re-split and this is the test that would catch it.
  load_lib
  panel_fzf_opts
  [[ "$(declare -p PANEL_FZF_OPTS)" == "declare -a"* ]]
  assert_equal "${PANEL_FZF_OPTS[0]}" "--ansi"
}

@test "the fzf base carries --ansi and --border but not the per-surface choices" {
  load_lib
  panel_fzf_opts
  local joined="${PANEL_FZF_OPTS[*]}"
  [[ "$joined" == *--ansi* ]]
  [[ "$joined" == *--reverse* ]]
  [[ "$joined" == *--border* ]]
  # --no-input is modal nav, a surface decision, not a floor.
  [[ "$joined" != *--no-input* ]]
}

@test "panel_fzf_table delimits on a real tab" {
  load_lib
  panel_fzf_table
  [[ "$(declare -p PANEL_FZF_TABLE)" == "declare -a"* ]]
  local joined="${PANEL_FZF_TABLE[*]}"
  [[ "$joined" == *"--delimiter=$PANEL_TAB"* ]]
  assert_equal "$PANEL_TAB" "$(printf '\t')"
}

@test "panel_fzf_preview emits the modern comma form with the border on the inner edge" {
  # One dialect. notes-cockpit.sh, favourites.sh and agent-panel each spelled the legacy
  # colon form differently.
  load_lib
  assert_equal "$(panel_fzf_preview left 24)" '--preview-window=left,24%,border-right,wrap'
  assert_equal "$(panel_fzf_preview right 55)" '--preview-window=right,55%,border-left,wrap'
  assert_equal "$(panel_fzf_preview up 30)" '--preview-window=up,30%,border-bottom,wrap'
}

@test "panel_fzf_preview rejects an unknown side rather than emitting nonsense" {
  load_lib
  run panel_fzf_preview sideways 30
  assert_failure
  refute_output --partial 'preview-window'
}

# ── tmux ─────────────────────────────────────────────────────────────────────

@test "panel_in_tmux reflects TMUX, and tolerates it being unset under set -u" {
  # sandbox_init unsets TMUX. Several pre-library panels used a bare [ -n "$TMUX" ] with no
  # :- default, which aborts outright once strict mode is on.
  load_lib
  run panel_in_tmux
  assert_failure
  TMUX=/tmp/fake,1,0 run panel_in_tmux
  assert_success
}

@test "panel_focus_session switches inside tmux and attaches outside" {
  load_lib
  TMUX=/tmp/fake,1,0 panel_focus_session work
  assert_called 'switch-client -t work'

  : > "$NOTES_FIXTURE/calls.log"
  panel_focus_session work
  assert_called 'attach -t work'
}

@test "panel_new_window refuses outside tmux instead of silently doing nothing" {
  # THE fix for notes-cockpit.sh:909-911, which called new-window with no $TMUX check and
  # swallowed the failure with 2>/dev/null -- so outside tmux it did nothing at all and read
  # to the user as a dead key.
  load_lib
  run bash -c 'SELF="$2"; . "$1"; unset TMUX; panel_new_window nvim' _ "$PANEL_LIB" "$SKELETON"
  assert_failure
  assert_output --partial 'not inside tmux'
  assert_not_called 'new-window'
}

@test "panel_new_window opens the window when inside tmux" {
  load_lib
  TMUX=/tmp/fake,1,0 panel_new_window nvim foo.txt
  assert_called 'new-window nvim foo.txt'
}

@test "panel_ensure_session is idempotent and keyed on name" {
  load_lib
  # The tmux stub answers has-session with rc 0, so the session always "exists" and no
  # new-session may be issued. That is the property that makes ensure safe to call on
  # every attach.
  panel_ensure_session hub "$HOME"
  assert_called 'has-session -t =hub'
  assert_not_called 'new-session'
}

# ── The session name ─────────────────────────────────────────────────────────
#
# One rule, three former copies that disagreed (sessionizer.sh, favourites.sh, worktree.sh).
# The disagreement was not theoretical: Prefix+f on ~/.dotfiles opened `_dotfiles` beside the
# `dotfiles` session tmux-servers/hub.conf had already created there.

@test "a leading dot is stripped, not folded" {
  load_lib
  run panel_session_name /home/someone/.dotfiles
  assert_success
  assert_output 'dotfiles'
  # The negative control: the pre-fix rule produced this, and it is the whole bug.
  refute_output '_dotfiles'
}

@test "an interior dot is folded to an underscore" {
  # tmux reads `.` as the window separator inside a target, so `-t my.project` addresses
  # window "project" of session "my" -- a different thing, or nothing at all.
  load_lib
  run panel_session_name /home/someone/my.dotted.project
  assert_success
  assert_output 'my_dotted_project'
}

@test "a leading dot AND interior dots are handled in one pass" {
  load_lib
  run panel_session_name /home/someone/.my.config
  assert_success
  assert_output 'my_config'
}

@test "an ordinary name passes through untouched" {
  load_lib
  run panel_session_name /home/someone/dev/platform
  assert_success
  assert_output 'platform'
}

@test "a trailing slash does not eat the name" {
  # find(1) never emits one, but a hand-typed `sessionizer.sh ~/.dotfiles/` does, and
  # ${1##*/} on that yields the empty string -- a session named "".
  load_lib
  run panel_session_name /home/someone/.dotfiles/
  assert_success
  assert_output 'dotfiles'
}

@test "a name that is only a dot-prefix does not become empty" {
  load_lib
  run panel_session_name '/home/someone/.x'
  assert_success
  assert_output 'x'
}

# ── The skeleton is a real, working panel ────────────────────────────────────

@test "the skeleton lists three rows of two tab-separated fields" {
  # Three, not two: anything ordered needs three before a test can tell forwards from
  # backwards. Seven direction assertions in this repo once passed while asserting nothing
  # because a fixture had two sections.
  run "$SKELETON" --list
  assert_success
  assert_equal "$(wc -l <<< "$output")" 3
  assert_equal "$(awk -F'\t' 'NR==1{print NF}' <<< "$output")" 2
}

@test "the skeleton reads its env override" {
  # Proves the ${VAR:-default} config rule is wired, not just written down.
  run env SKELETON_GREETING=howdy "$SKELETON" --list
  assert_output --partial 'howdy one'
}

@test "the skeleton rejects an unknown verb instead of falling through to a picker" {
  # Two panels in this repo fall through to fzf on an unknown verb, which means a typo opens
  # a UI instead of erroring -- and blocks forever in a headless test. The template must not
  # teach that shape.
  run "$SKELETON" bogus
  assert_failure
  assert_output --partial 'unknown verb: bogus'
}

@test "the skeleton produces identical output when invoked by a relative path" {
  # fzf re-invokes $SELF from inside the picker, so a relative launch must behave the same.
  # favourites.sh:26 fails exactly this today.
  local abs rel
  abs="$("$SKELETON" --list)"
  rel="$(cd "$REPO_ROOT/.local/src/tmux" && ./_skeleton.sh --list)"
  assert_equal "$rel" "$abs"
}
