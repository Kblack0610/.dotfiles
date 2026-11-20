# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# machine-mode.sh - the machine mode in force, the level it sets and the clock hours, for every
# script that reads them: machine-mode (the one writer of the mode), fleet-dispatch and
# claude-acct, which scale their start limits by the level where they read them.
#
# The clock: the hours file names the day's parts, each a window and the mode it runs in.
#
# The mode is the state file's MACHINE_MODE, or the modes file's last row when none is set or the
# one set is no longer listed. Its level is that row's level column. What a level multiplies is
# the levels file; the confs keep their own numbers as the mid baseline. Usage and
# troubleshooting: .local/src/docs/machine-mode.md

_mm_conf="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.config/machine-mode"
: "${MACHINE_MODE_MODES:=$_mm_conf/modes}"
: "${MACHINE_MODE_LEVELS:=$_mm_conf/levels}"
: "${MACHINE_MODE_HOURS:=$_mm_conf/hours}"
: "${MACHINE_MODE_STATE:=$HOME/.agent/machine-mode.env}"
unset _mm_conf

mode_rows() { grep -Ev '^[[:space:]]*(#|$)' "$MACHINE_MODE_MODES"; }
mode_names() { mode_rows | cut -d'|' -f1; }
mode_row() { mode_rows | awk -F'|' -v m="$1" '$1 == m { print; found = 1 } END { exit !found }'; }
state_value() { sed -n "/^$1=/{s///p;q;}" "$MACHINE_MODE_STATE" 2>/dev/null; }

hour_rows() { grep -Ev '^[[:space:]]*(#|$)' "$MACHINE_MODE_HOURS" 2>/dev/null; }

# hhmm_in <HH:MM> <from-to> -> true when the time is inside the window, which may wrap midnight.
hhmm_in() {
  local t="${1/:/}" a="${2%-*}" b="${2#*-}"
  a="${a/:/}"; b="${b/:/}"
  t=$((10#$t)) a=$((10#$a)) b=$((10#$b))
  if [ "$a" -le "$b" ]; then [ "$t" -ge "$a" ] && [ "$t" -lt "$b" ]
  else [ "$t" -ge "$a" ] || [ "$t" -lt "$b" ]; fi
}

# clock_part [HH:MM] -> the hours row whose window holds that time (MACHINE_MODE_NOW, else now, by
# default); exit 1 when none does.
clock_part() {
  local now="${1:-${MACHINE_MODE_NOW:-$(date +%H:%M)}}" row
  while IFS= read -r row; do
    IFS='|' read -r _ w _ <<< "$row"
    hhmm_in "$now" "$w" && { printf '%s\n' "$row"; return 0; }
  done < <(hour_rows)
  return 1
}


# human_here -> rc 0 unless fleet-presence says away. Unreadable counts as here: the slower rate.
human_here() { case "$(fleet-presence 2>/dev/null)" in away*) return 1 ;; esac; return 0; }

current_mode() {
  local m
  m="$(state_value MACHINE_MODE)"
  if [ -n "$m" ] && mode_row "$m" >/dev/null; then printf '%s' "$m"; else mode_names | tail -1; fi
}

# machine_level -> the current mode's level, mid when its row names none
machine_level() {
  local l
  l="$(mode_row "$(current_mode)" | cut -d'|' -f3)"
  printf '%s' "${l:-mid}"
}

# level_scale KEY VALUE [KEY VALUE ...] -> each VALUE scaled by the current level's factor for
# its KEY, space-separated, in one awk. A factor of 1 or a key with no column returns the value as
# given; an integer comes back a rounded integer and a decimal at most 2 places; a nonzero value
# never comes back 0. A level the levels file does not list scales nothing and says so on stderr:
# a bad hand edit must not stop dispatch (machine_level.bats checks the real files agree).
level_scale() {
  awk -F'|' -v level="$(machine_level)" -v kv="$*" -v file="$MACHINE_MODE_LEVELS" '
    BEGIN {
      while ((getline line < file) > 0) {
        if (line ~ /^[[:space:]]*(#|$)/) continue
        n = split(line, f, "|")
        if (!hdr) { for (i = 2; i <= n; i++) col[f[i]] = i; hdr = 1; continue }
        if (f[1] == level) { found = 1; for (i = 2; i <= n; i++) fac[i] = f[i] }
      }
      if (!found) printf "machine-mode: level %s is not in %s, so nothing is scaled\n", level, file > "/dev/stderr"
      n = split(kv, a, " ")
      for (i = 1; i < n; i += 2) {
        k = a[i]; v = a[i + 1]; r = v
        x = (found && (k in col)) ? fac[col[k]] : ""
        if (x != "" && x + 0 != 1) {
          if (v ~ /^-?[0-9]+$/) { r = int(v * x + (v < 0 ? -0.5 : 0.5)); if (r == 0 && v != 0) r = (v < 0 ? -1 : 1) }
          else { r = sprintf("%.2f", v * x) + 0; if (r == 0 && v + 0 != 0) r = 0.01 }
        }
        out = out (i > 1 ? " " : "") r
      }
      print out
    }'
}
