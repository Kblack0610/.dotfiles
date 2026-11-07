#!/usr/bin/env bash
# Force-stop a stuck gungan take (Super+Ctrl+R in conf.d/keybindings.conf). Every kill is by
# a pid this checked, never a pkill -f pattern: a pattern also matches the command line of the
# shell running it (hypr's sh -c), which then dies before the cleanup below runs.

RUN="${XDG_RUNTIME_DIR:-/tmp}"
STREAM_PID_FILE="$RUN/gungan_stream.pid"
# bin/gungan's AUDIO_FILE and LOCK_FILE share this prefix; a record take's pw-record and
# whisper-cpp carry it in their command lines. Tests point it elsewhere.
REC="${GUNGAN_REC:-/tmp/gungan_recording}"

holds() { grep -qaF -- "$2" "/proc/$1/cmdline" 2>/dev/null; }   # holds <pid> <text>

# Stream: the pidfile's client, only while it is still the client (a stale pid may be reused).
# Its gungan subshell goes first, so it posts no "Stream failed" over this notice; then the
# client's own pw-record, then the client.
if read -r pid 2>/dev/null < "$STREAM_PID_FILE" && [[ "$pid" =~ ^[0-9]+$ ]] && holds "$pid" stream_client.py; then
    parent="$(ps -o ppid= -p "$pid" | tr -d ' ')"
    [[ "$(ps -o comm= -p "$parent" 2>/dev/null)" == gungan ]] && kill -9 "$parent" 2>/dev/null
    pkill -9 -P "$pid" -x pw-record
    kill -9 "$pid" 2>/dev/null
fi

# Record: the pw-record writing the take and a whisper-cpp transcribing it, by name and file.
for name in pw-record whisper-cpp; do
    for p in $(pgrep -x "$name"); do holds "$p" "$REC" && kill -9 "$p" 2>/dev/null; done
done

rm -f "$STREAM_PID_FILE" "$REC.lock"
pkill -RTMIN+9 -x waybar   # the bar's mic (custom/gungan) re-reads `gungan status`
notify-send "Gungan" "Force killed"
exit 0
