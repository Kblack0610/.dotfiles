# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# stat.sh - the one GNU-then-BSD stat fallback, for the scripts that also run on macOS.
#
#   stat_mtime <path>   seconds since the epoch of the last change
#   stat_dev <path>     the device number
#   stat_mode <path>    the permission bits, octal (755)
#
# Each prints nothing and fails when <path> is gone.

stat_mtime() { stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null; }
stat_dev() { stat -c %d -- "$1" 2>/dev/null || stat -f %d -- "$1" 2>/dev/null; }
stat_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp -- "$1" 2>/dev/null; }
