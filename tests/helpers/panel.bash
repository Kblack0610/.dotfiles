# Panel conformance helpers.
#
# A "panel" is a surface bound to a key in .tmux.conf that opens a script. The popup itself
# is untestable -- display-popup draws a client-side overlay onto client->tty, so headless it
# fails "no current client" rc=1 and the command never runs, and even with a pty client
# attached it never appears in list-panes and capture-pane cannot read it (see
# tmux_harness.bash:3-9). So the SCRIPT is the testable surface and the BIND is testable as
# text. That is what these helpers do: parse .tmux.conf as data, and grep the panel sources
# for the conventions a reader cannot enforce by hand across eleven files.
#
# Everything here is pure text. No tmux, no fzf, no subprocess of a subject -- which is why
# panel_conformance.bats lives in the integ tier and still runs in CI's `fast` job, where
# neither tmux nor fzf is installed on purpose.
#
# The MANIFEST (tests/panels.manifest) is the enumeration. Its closure against .tmux.conf is
# an assertion in both directions, which is what makes coverage structural instead of
# aspirational: a panel added without a manifest row FAILS, rather than being silently
# uncovered.

PANEL_MANIFEST="${PANEL_MANIFEST:-$TESTS_DIR/panels.manifest}"
TMUX_CONF="${TMUX_CONF:-$REPO_ROOT/.tmux.conf}"
export PANEL_MANIFEST TMUX_CONF

# The sanctioned geometry vocabulary. Three names, because a size should state the surface's
# SHAPE -- owns-the-screen / table-with-preview / one-column-list. Six sizes encoded no
# distinction a reader could name, which is precisely why they drifted apart.
#
# Verified in the container on tmux 3.7b: `%hidden PW_WIDE=90%` expands in flag-argument
# position, so these live as real named constants in .tmux.conf rather than as literals
# repeated eleven times. Also verified: a variable holding a whole flag group ("-w 90% -h
# 85%") does NOT work -- tmux expands $VAR to a single token and drops the bind entirely.
# Hence one constant per flag.
panel_geometry_class() {
  case "$1 $2" in
  '100% 100%') echo FULL ;;
  '90% 85%') echo WIDE ;;
  '80% 60%') echo SMALL ;;
  *) return 1 ;;
  esac
}

# panel_rows -- every non-comment, non-blank manifest row, verbatim TSV.
panel_rows() {
  grep -vE '^\s*(#|$)' "$PANEL_MANIFEST"
}

# panel_field <table:key> <column-name> -- one field, addressed by NAME not position, so
# adding a column in the middle cannot silently shift every assertion. rc1 if the row is
# absent; rc1 (and empty) if the column name is unknown.
panel_field() {
  local want="$1" col="$2"
  awk -v want="$want" -v col="$col" '
    # The column header is `# table key ...` with exactly ONE space after the #. The prose
    # above it documents each column on its own line and those lines are INDENTED
    # ("#   table     the tmux key table..."), which is the only thing distinguishing them.
    # Matched on the RAW line for that reason -- stripping the comment prefix first makes the
    # two indistinguishable, and the parser then silently locks onto the documentation and
    # every panel_field call returns empty. That happened; hence the header-integrity test.
    /^# table[[:space:]]/ {
      if (!ncol) {
        hdr = $0
        sub(/^# /, "", hdr)
        ncol = split(hdr, H, /[[:space:]]+/)
        for (i = 1; i <= ncol; i++) if (H[i] == col) idx = i
      }
      next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { if ($1 ":" $2 == want) { if (!idx) exit 3; print $idx; found = 1; exit 0 } }
    END { if (!found) exit 1 }
  ' "$PANEL_MANIFEST"
}

# panel_conf_bindings -- every display-popup binding in .tmux.conf, as
#   table <TAB> key <TAB> width <TAB> height <TAB> command
#
# `table` is the key table (root, or whatever -T names). Width/height are printed VERBATIM,
# including a bare "$PW_WIDE" if the bind uses a %hidden constant, so a caller can tell a
# literal from a reference. Both forms resolve through panel_conf_geometry.
panel_conf_bindings() {
  awk '
    /^[[:space:]]*(bind|bind-key)[[:space:]]/ && /display-popup/ {
      line = $0
      table = "root"
      if (match(line, /-T[[:space:]]+[^[:space:]]+/)) {
        t = substr(line, RSTART, RLENGTH); sub(/-T[[:space:]]+/, "", t); table = t
      }
      w = h = "-"
      if (match(line, /-w[[:space:]]+[^[:space:]]+/)) { w = substr(line, RSTART, RLENGTH); sub(/-w[[:space:]]+/, "", w) }
      if (match(line, /-h[[:space:]]+[^[:space:]]+/)) { h = substr(line, RSTART, RLENGTH); sub(/-h[[:space:]]+/, "", h) }

      # The key is the token after the bind word and any flags/-T pair.
      n = split(line, F, /[[:space:]]+/)
      key = ""
      for (i = 2; i <= n; i++) {
        if (F[i] == "-T") { i++; continue }
        if (F[i] ~ /^-/) continue
        key = F[i]; break
      }

      # The command is the last quoted string on the line.
      cmd = line
      if (match(cmd, /"[^"]*"[[:space:]]*$/))      { cmd = substr(cmd, RSTART + 1, RLENGTH - 2); sub(/[[:space:]]+$/, "", cmd) }
      else if (match(cmd, /'"'"'[^'"'"']*'"'"'[[:space:]]*$/)) { cmd = substr(cmd, RSTART + 1, RLENGTH - 2); sub(/[[:space:]]+$/, "", cmd) }
      else cmd = "-"

      printf "%s\t%s\t%s\t%s\t%s\n", table, key, w, h, cmd
    }
  ' "$TMUX_CONF"
}

# panel_conf_hidden <name> -- the value of a `%hidden NAME=value` line, or empty.
panel_conf_hidden() {
  sed -n "s/^%hidden[[:space:]]\+$1=\(.*\)\$/\1/p" "$TMUX_CONF" | tail -1
}

# panel_conf_geometry <w-token> <h-token> -- resolve a bind's -w/-h through %hidden if they
# are variable references, then print "<w> <h>".
#
# NOTE the failure mode this exists to catch, verified in the container: tmux does NOT error
# on an undefined variable in flag position and does NOT drop the bind. `-w $NOPE` binds
# `-w ''` -- an empty geometry, registered silently, no diagnostic at load. So a typo'd
# constant name is invisible until you press the key. That is why the geometry test asserts
# NON-EMPTY as well as in-vocabulary: tmux will not tell us.
panel_conf_geometry() {
  local w="$1" h="$2"
  case "$w" in '$'*) w="$(panel_conf_hidden "${w#\$}")" ;; esac
  case "$h" in '$'*) h="$(panel_conf_hidden "${h#\$}")" ;; esac
  printf '%s %s\n' "$w" "$h"
}

# panel_argv <command-string> -- everything after the executable. "-" when there is none.
panel_argv() {
  local rest="${1#* }"
  [ "$rest" = "$1" ] && { echo -; return 0; }
  printf '%s\n' "$rest"
}

# panel_resolve <command-string> -- the bound executable as a repo-relative path.
#
# Rewrites $HOME/ to the repo root, because the binds address the STOWED location
# ($HOME/.local/...) while the tests must read the tracked file. Prints the command name
# unchanged when it is a bare PATH name (tmx, tmux-tags) -- resolving those is the
# manifest's job via the `path` column, not a guess made here.
panel_resolve() {
  local cmd="${1%% *}"
  case "$cmd" in
  "\$HOME/"*) printf '%s\n' "${cmd#\$HOME/}" ;;
  "$HOME/"*) printf '%s\n' "${cmd#"$HOME"/}" ;;
  /*) printf '%s\n' "$cmd" ;;
  *) printf '%s\n' "$cmd" ;;
  esac
}

# ---------------------------------------------------------------------------
# Source-convention assertions. Each takes a repo-relative path and returns
# rc0 = conforms, rc1 = does not. They are deliberately rc-only and quiet: the
# ratchet tests call them across every panel and report the offenders together,
# which reads far better than eleven separate failures.
# ---------------------------------------------------------------------------

# The preamble. `set -u` plus pipefail, before the first function definition -- placing it
# after means every function defined above it ran unprotected.
#
# Deliberately NOT requiring `-e`: no panel uses it, and that is correct rather than
# sloppy. In these scripts a `grep -q` miss and a failing command substitution are normal
# control flow, so `-e` would abort a picker mid-render.
panel_assert_strict_mode() {
  local f="$REPO_ROOT/$1"
  local first_fn
  first_fn="$(grep -nE '^[a-z_][a-z0-9_]*\(\)' "$f" | head -1 | cut -d: -f1)"
  [ -n "$first_fn" ] || first_fn=9999
  awk -v stop="$first_fn" '
    NR >= stop { exit }
    /^set -/ && /u/ && /pipefail/ { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$f"
}

# $SELF must be absolute, because fzf --bind re-invokes the script from inside the picker
# and a relative $0 does not resolve there. Two spellings are accepted: a realpath at
# assignment, or tags.sh:56's explicit absolutize branch.
panel_assert_self_absolute() {
  local f="$REPO_ROOT/$1"
  grep -qE '^SELF="\$\((realpath|readlink -f)' "$f" && return 0
  grep -qE '^SELF="\$\(cd "\$\(dirname' "$f" && return 0
  grep -qE '^case "\$SELF" in /\*\)' "$f" && return 0
  return 1
}

# No fzf action may interpolate a bare $0, and none may hardcode the script's own name.
#
# pr-viewer.sh:371 is the live offender on both counts: `--bind "ctrl-r:reload(bash $0)"`.
# Unquoted, so it also breaks on any path containing a space -- and the test sandbox's path
# contains one by design (sandbox.bash:32), which is exactly the class that catches.
panel_assert_no_bare_dollar_zero() {
  local f="$REPO_ROOT/$1"
  ! grep -qE '(execute|execute-silent|reload|become|preview|transform)\([^)]*\$0' "$f"
}

panel_assert_no_bare_script_name() {
  local f="$REPO_ROOT/$1" base
  base="$(basename "$1")"
  ! grep -qE "(execute|execute-silent|reload|become|preview|transform)\([^)]*${base//./\\.}" "$f"
}

# The palette must use ANSI indices 0-7/90 and SGR attributes only -- never truecolor.
#
# This is what makes these surfaces theme-responsive TODAY: theme-switch recolours the
# TERMINAL's palette, so \033[1;32m follows a theme swap for free. Emitting 38;2;R;G;B
# would pin a surface to one theme's hex values and STOP it tracking the terminal, which
# is a regression dressed as a feature.
panel_assert_no_truecolor() {
  local f="$REPO_ROOT/$1"
  ! grep -qE '\\033\[[0-9;]*(38|48);(2|5);' "$f"
}

# ---------------------------------------------------------------------------
# The countdown ratchet.
#
# For each convention some panels do not yet meet, a test asserts
# count(offenders) <= N with N hardcoded and the remaining names in a comment.
# Same idiom as tests/lint.sh's SEVERITY: one-line diff per migration PR, no
# baseline file to rot, and -- the point -- it CANNOT SILENTLY GROW. A new panel
# that skips the convention pushes the count over N and fails the run.
#
# A skip would not do this. A skip is how a safety tier quietly stops running.
# ---------------------------------------------------------------------------

# panel_ratchet <max> <label> <assertion-fn> -- run the assertion over every manifest panel
# that is a shell script in this repo, collect the failures, and fail if there are more than
# <max>, or fewer (a migrated panel must lower the number, or the ratchet stops ratcheting).
#
# Scans every kind EXCEPT rust-bin. Scoping this to kind=script would silently exempt
# servers.sh and tags.sh -- two of the largest panels -- purely because they are reached
# through a .local/bin alias, which has nothing to do with whether their source conforms.
panel_ratchet() {
  local max="$1" label="$2" fn="$3"
  local path offenders=() n
  while read -r table key kind geometry path argv; do
    [ "$kind" = rust-bin ] && continue
    "$fn" "$path" || offenders+=("$path")
  done < <(panel_rows)

  # Uniq: a script bound to two keys (favourites.sh is s and o) must count once.
  n="$(printf '%s\n' "${offenders[@]+"${offenders[@]}"}" | sort -u | grep -c . || true)"

  if [ "$n" -gt "$max" ]; then
    {
      echo "$label: $n panel(s) do not conform, ratchet allows $max."
      printf '  %s\n' $(printf '%s\n' "${offenders[@]+"${offenders[@]}"}" | sort -u)
      echo
      echo "If you MIGRATED one, lower the ratchet in the test by the same number."
      echo "If you ADDED a panel, it must conform -- the ratchet only covers known legacy."
    } >&2
    return 1
  fi
  if [ "$n" -lt "$max" ]; then
    echo "$label: only $n offender(s) left but the ratchet still allows $max -- lower it to $n." >&2
    return 1
  fi
}
