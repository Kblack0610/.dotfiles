#!/usr/bin/env bash
# Waybar custom/webcam: a red CAM pill while any process holds a /dev/video* node open, hidden
# otherwise; the tooltip names the holders. Not gated: a live camera is a privacy indicator.
#
# No interval and no signal: waybar keeps this running and takes one JSON line per change.
# inotify reports every open and close of a video node, and each one can re-read who holds the
# nodes from /proc/*/fd. A second watch on the device directory re-arms the first when a camera
# is plugged in or out.
#
# Something on this desktop opens and closes both Brio nodes every 3 s (a device probe), and a
# /proc scan costs about 50 ms, so while hidden the loop keeps a count of opens not yet matched by
# a close and scans only when one is left over: a probe's open and close cancel with no scan.
# Once shown, every open and close scans, to name the holders and catch the last close. Only this
# user's fds are readable, which covers everyone the nodes' ACL lets open them (this user, group
# video).
#
# WEBCAM_DEV_DIR moves the device directory, for the tests.

here="$(dirname "$(readlink -f "$0")")"
# shellcheck source=pango.sh
. "$here/pango.sh"
shopt -s nullglob
dev_dir="${WEBCAM_DEV_DIR:-/dev}"
shown=0 last='' watcher='' pending=0

# holders: one "comm (pid)" line per process with a video node open.
holders() {
  local pid
  find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -lname "$dev_dir/video*" -printf '%h\n' 2>/dev/null \
    | cut -d/ -f3 | sort -un | while read -r pid; do
      printf '%s (%s)\n' "$(cat "/proc/$pid/comm" 2>/dev/null)" "$pid"
    done
}

scan() {
  local who line
  who="$(holders)"
  if [[ -n $who ]]; then
    shown=1
    line="$(emit CAM "Webcam in use by:"$'\n'"$(pango_esc "$who")" active)"
  else
    ((shown)) && pending=0 # every holder seen is gone; count afresh
    shown=0
    line='{"text":""}'
  fi
  [[ $line == "$last" ]] || { printf '%s\n' "$line"; last=$line; }
}

# watch: one line per event ("OPEN <path>", "CLOSE_NOWRITE,CLOSE <path>", "CREATE <path>"),
# plus inotifywait's own "Watches established." once each watch is armed.
watch() {
  trap 'kill $(jobs -p) 2>/dev/null' EXIT TERM
  local nodes=("$dev_dir"/video*)
  inotifywait -m -e create -e delete --include '/video[0-9]+$' --format '%e %w%f' "$dev_dir" 2>&1 &
  if ((${#nodes[@]})); then
    inotifywait -m -e open -e close --format '%e %w%f' "${nodes[@]}" 2>&1 &
  fi
  wait
}

arm() {
  [[ -n $watcher ]] && { kill "$watcher" 2>/dev/null; exec {ev}<&-; }
  exec {ev}< <(watch)
  watcher=$!
}

trap '[[ -n $watcher ]] && kill "$watcher" 2>/dev/null' EXIT
trap exit TERM INT
arm
while read -r -u "$ev" line; do
  rearm=0 touched=0 other=0
  while :; do # this event and any already queued behind it, as one batch
    case $line in
      CREATE* | DELETE*) rearm=1 ;;
      OPEN*) touched=1 pending=$((pending + 1)) ;;
      # A close of something opened before the count began must not cancel a later open.
      CLOSE*) touched=1 pending=$((pending > 0 ? pending - 1 : 0)) ;;
      *) other=1 ;; # Watches established, or a watch that went away with its node
    esac
    read -r -t 0 -u "$ev" || break
    read -r -u "$ev" line || break
  done
  if ((rearm)); then
    arm # its "Watches established." lines bring the scan
  elif ((other || (shown && touched) || (!shown && pending > 0))); then
    scan
  fi
done
