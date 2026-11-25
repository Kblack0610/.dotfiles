#!/bin/bash
# wind-down.sh — arm / fire a clean self-teardown of Claude's own tmux window.
#
# Subcommands:
#
#   wind-down.sh arm [--session]
#       Record a spin-down request for THIS tmux window. Captures the exact
#       target now (arm time, while $TMUX_PANE is reliable) into a sentinel at
#       ~/.agent/spin-down/<session-id>.request (<project>.request with no session id).
#       The Stop hook (95-wind-down.sh)
#       reads it after the normal Stop pipeline runs and fires the teardown.
#       --session widens the kill from the window to the whole tmux session, unless a world
#       manifest declares it (tmux-close, close.sh): then only the window closes.
#       A Claude background session (CLAUDE_CODE_SESSION_KIND=bg, run by `claude daemon`) has
#       no tmux window of its own: arm records its daemon job instead (scope=bg), and fire
#       ends the session with `claude stop <job>`. The daemon's TMUX_PANE is the pane of the
#       foreground claude that spawned it, a different live session, so it is never killed.
#
#   wind-down.sh fire <sentinel-path>
#       Executor — called by the Stop hook, NOT by Claude. Saves the window
#       scrollback, then schedules a detached kill-window (or kill-session)
#       so the calling hook can exit cleanly before the window dies.
#
#   wind-down.sh close --server S --pane %N --sid ID
#       The same teardown for a session that was told to close and did not, run by
#       fleet-shepherd (close_refused): writes the sentinel as .fired and fires it.
#
#   wind-down.sh note-path
#       Print (and ensure the dir for) the session wrap-up note path on the
#       agent-runtime axis: ~/.agent/sessions/<project>/<date>-wind-down.md.
#       The skill writes the wrap-up there. Project resolution matches the hook.
#
#   (A dead session's scratchpad is reaped hourly by agentctl-tmp-gc, not here.)
#
# Sentinel format (key=val, one per line):
#   scope=window|session|bg
#   target=<window_id>          # stable @N — NEVER use window_index (it renumbers
#                               #   and bare display-message returns the session's
#                               #   ACTIVE window, not Claude's pane's window)
#                               # scope=bg: the daemon job's short id instead
#   label=<session_name>:<window_index>   # human-readable, for messages only
#   pane=<pane_id>
#   session=<session_name>
#   windows=<window_count_in_session>
#   worktree=<path>             # set only when this session sits in a `wt` worktree; `fire`
#                               #   hands it to `wt reap` AFTER the kill, and reap refuses
#                               #   unless it is clean, landed and has no live session
#   sid=<claude_session_id>     # `fire` removes this session's scratchpad AFTER the kill
#   ts=<unix>

set -uo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
HISTORY_DIR="${WIND_DOWN_HISTORY_DIR:-$HOME/.local/share/tmux-history}"
SPIN_DIR="$HOME/.agent/spin-down"

# Canonical project name (matches the Stop-hook's resolution).
# shellcheck source=../../../.config/shared-hooks/project-name.sh
. "${PROJECT_NAME_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../.config/shared-hooks/project-name.sh}"
# shellcheck source=../../lib/ask-store.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../lib/ask-store.sh"   # reopen_asks

cmd_arm() {
  local scope="window"
  for a in "$@"; do
    case "$a" in
      --session) scope="session" ;;
      *) echo "wind-down arm: unknown arg '$a'" >&2; return 2 ;;
    esac
  done

  # First, whatever TMUX says: a TMUX a background session inherited names the foreground claude's
  # pane, never its own.
  local job
  if job=$(own_bg_job); then
    arm_bg "$scope" "$job"
    return
  fi

  if [ -z "${TMUX:-}" ]; then
    echo "wind-down: not inside tmux — nothing to spin down. (Note still written; no kill armed.)" >&2
    return 1
  fi

  local target session windows label pane
  # Resolve EVERYTHING against THIS pane (-t "$pane"), never the session's active
  # window: Claude runs `arm` non-interactively and is often NOT the focused
  # window, so a bare `display-message` captures whatever window the user is
  # looking at — and the hook then kills that innocent window instead of Claude's
  # (the 2026-06-18 bug). write_sentinel records the stable window_id (@N), which tmux
  # never renumbers, so `kill-window -t @N` at Stop time is always exact.
  pane="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"
  if [ -z "$pane" ]; then
    echo "wind-down: could not resolve \$TMUX_PANE — aborting arm." >&2
    return 1
  fi

  local sentinel sid
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  mkdir -p "$SPIN_DIR"
  # Key the sentinel by Claude session id ALONE. Multiple Claude windows can run in the
  # SAME project's tmux session at once; a single shared "<proj>.request" let one
  # session's Stop hook consume another's sentinel and kill the wrong window. The
  # session id (== the Stop hook's stdin .session_id) isolates them, and it is unique
  # on its own: a project part only made arm and the hook disagree when arm ran from a
  # cwd outside the project (2026-11-08, "_unscoped__<sid>" never found). Fall back to
  # the project-only name for non-Claude callers.
  if [ -n "$sid" ]; then
    sentinel="$SPIN_DIR/${sid}.request"
  else
    sentinel="$SPIN_DIR/$(resolve_project "${CLAUDE_PROJECT_DIR:-$PWD}").request"
  fi
  write_sentinel "$sentinel" "$scope" "$pane" "$sid" tmux || return 1

  if [ "$scope" = "session" ]; then
    echo "wind-down armed: session '$session' will be torn down at next Stop (sentinel: $sentinel)"
  elif [ "${windows:-1}" -le 1 ] 2>/dev/null; then
    echo "wind-down armed: window '$label' [$target] (the only window in '$session', so the session ends too) at next Stop"
  else
    echo "wind-down armed: window '$label' [$target] will close at next Stop; session '$session' survives (sentinel: $sentinel)"
  fi
}

# own_bg_job: print this session's daemon job, rc 1 when this is not a background session. The job
# is the daemon's own key for it (CLAUDE_JOB_DIR=<config>/jobs/<short>), the id `claude stop` takes.
# It counts only when the job's state names this session: a claude started from inside a background
# session inherits its KIND and JOB_DIR with a session id of its own, and must never stop its parent.
own_bg_job() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}" dir="${CLAUDE_JOB_DIR:-}" job
  dir="${dir%/}"; job="${dir##*/}"
  [ "${CLAUDE_CODE_SESSION_KIND:-}" = bg ] && is_session_id "$sid" && [[ "$job" =~ ^[0-9a-f]{8}$ ]] || return 1
  [ "$(jq -r '.sessionId // empty' "$dir/state.json" 2>/dev/null)" = "$sid" ] || return 1
  echo "$job"
}

# arm_bg <scope> <job>: arm `claude stop <job>` for this background session, keyed by the session id
# as the Stop hook looks it up. It needs setsid for the detached stop (Linux; macOS has none), so
# without one it refuses here rather than leave a sentinel whose fire can schedule nothing.
arm_bg() {
  local sid="$CLAUDE_CODE_SESSION_ID" job="$2" sentinel
  if ! command -v setsid >/dev/null 2>&1; then
    echo "wind-down: no setsid here to stop background session '$job' detached: nothing armed; end it with: claude stop $job" >&2
    return 1
  fi
  mkdir -p "$SPIN_DIR"
  sentinel="$SPIN_DIR/${sid}.request"
  {
    echo "scope=bg"
    echo "target=$job"
    echo "label=bg-$job"
    echo "worktree=$(worktree_of "$PWD")"
    echo "sid=$sid"
    echo "ts=$(date +%s)"
  } > "$sentinel"
  echo "wind-down armed: background session '$job' will stop at next Stop (claude stop $job; sentinel: $sentinel)"
  [ "${1:-}" != session ] || echo "wind-down: --session has nothing wider to close here: a background session has no tmux session, so only it stops."
}

# worktree_of <dir>: the root of the `wt` worktree <dir> sits in, or nothing. Only a tree under
# $WT_ROOT counts: winding down an ordinary session must never put a main checkout near `reap`.
# --show-toplevel, not <dir> itself: a pane in <worktree>/tests is still in the worktree, but
# `git worktree remove <worktree>/tests` is simply an error.
worktree_of() {
  local top
  [ -n "${1:-}" ] && top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  case "$top" in
    "${WT_ROOT:-$HOME/.worktrees}"/*) echo "$top" ;;
  esac
}

# write_sentinel <path> <scope> <pane> <sid> <tmux argv...>: resolve the pane's window, session and
# worktree through the given tmux command and write the sentinel `fire` reads. It sets the
# caller's target, session, windows and label (bash dynamic scope) for its messages.
write_sentinel() {
  local sentinel="$1" scope="$2" pane="$3" sid="$4" socket
  shift 4
  target=$("$@" display-message -p -t "$pane" '#{window_id}' 2>/dev/null)
  session=$("$@" display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
  windows=$("$@" display-message -p -t "$pane" '#{session_windows}' 2>/dev/null)
  label=$("$@" display-message -p -t "$pane" '#{session_name}:#{window_index}' 2>/dev/null)
  # Pin the server socket: on macOS tmux finds its server via $TMPDIR, which the
  # Stop hook's (sanitized) env may not share. Capturing the absolute socket path
  # now lets `fire` reach the right server with `tmux -S <socket>` regardless.
  socket=$("$@" display-message -p -t "$pane" '#{socket_path}' 2>/dev/null)

  if [ -z "$target" ] || [ -z "$session" ]; then
    echo "wind-down: could not resolve tmux target for $pane: aborting." >&2
    return 1
  fi

  # The worktree this session is sitting in, resolved NOW for the same reason as everything
  # above: at fire time the window is being killed and $PWD is long gone.
  local worktree
  worktree=$(worktree_of "$("$@" display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)")

  {
    echo "scope=$scope"
    echo "target=$target"
    echo "label=$label"
    echo "pane=$pane"
    echo "session=$session"
    echo "socket=$socket"
    echo "windows=$windows"
    echo "worktree=$worktree"
    echo "sid=$sid"
    echo "ts=$(date +%s)"
  } > "$sentinel"
}

# close --server S --pane %N --sid ID: the teardown for a session that was told to close and did
# not (fleet-shepherd close_refused). The same fire as the Stop hook's: scrollback saved, the window
# killed, the worktree reaped only when clean and landed. The sentinel is written straight to .fired,
# so fleet-dispatch restore skips the conversation, as it does one that closed itself.
cmd_close() {
  local server='' pane='' sid=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --server) server="${2:-}"; shift 2 ;;
      --pane)   pane="${2:-}"; shift 2 ;;
      --sid)    sid="${2:-}"; shift 2 ;;
      *) echo "wind-down close: unknown arg '$1'" >&2; return 2 ;;
    esac
  done
  [[ "$pane" == %* ]] && is_session_id "$sid" || { echo "wind-down close: needs --pane %N and --sid <session id>" >&2; return 2; }
  local TM=(tmux) target session windows label sentinel="$SPIN_DIR/$sid.fired"
  [ -n "$server" ] && TM=(tmux -L "$server")
  mkdir -p "$SPIN_DIR"
  write_sentinel "$sentinel" window "$pane" "$sid" "${TM[@]}" || return 1
  # fire returns 0 on its no-op paths too (a protected window, one already gone), so success is
  # the close it scheduled; anything else drops the .fired marker, or restore would skip a live session.
  WD_SCHEDULED=''
  cmd_fire "$sentinel"
  [ -n "$WD_SCHEDULED" ] && return 0
  rm -f "$sentinel"
  echo "wind-down close: nothing scheduled for $pane" >&2
  return 1
}

cmd_fire() {
  local sentinel="${1:-}"
  [ -n "$sentinel" ] && [ -f "$sentinel" ] || { echo "wind-down fire: sentinel not found: $sentinel" >&2; return 1; }

  # shellcheck source=/dev/null
  local scope target session pane socket label worktree sid
  scope=$(grep -m1 '^scope=' "$sentinel" | cut -d= -f2-)
  sid=$(grep -m1 '^sid=' "$sentinel" | cut -d= -f2-)
  worktree=$(grep -m1 '^worktree=' "$sentinel" | cut -d= -f2-)
  target=$(grep -m1 '^target=' "$sentinel" | cut -d= -f2-)
  session=$(grep -m1 '^session=' "$sentinel" | cut -d= -f2-)
  pane=$(grep -m1 '^pane=' "$sentinel" | cut -d= -f2-)
  socket=$(grep -m1 '^socket=' "$sentinel" | cut -d= -f2-)
  label=$(grep -m1 '^label=' "$sentinel" | cut -d= -f2-)
  scope="${scope:-window}"

  [ -n "$target" ] || { echo "wind-down fire: no target in sentinel" >&2; return 1; }
  if [ "$scope" = bg ]; then
    fire_bg
    return
  fi

  # Reach the SAME tmux server the window lives on. Pinning the socket (-S) makes
  # this work regardless of $TMPDIR/$TMUX in the Stop hook's environment, which is
  # how tmux otherwise locates its server (and a mismatch = silent no-op on macOS).
  # An array, so a socket path with a space in it stays one word.
  local TM=(tmux)
  [ -n "$socket" ] && [ -S "$socket" ] && TM=(tmux -S "$socket")

  # `fire` is invoked by the Stop hook and may be the first thing to touch SPIN_DIR
  # (arm can have run on a different machine, or the dir can be swept). Without this,
  # every append below fails -- and it fails LOUDLY despite the `2>/dev/null || true`,
  # because a redirection that cannot open its target is reported by the shell before
  # the command ever runs, so neither guard applies to it. Cost: one mkdir.
  mkdir -p "$SPIN_DIR"
  local logf="$SPIN_DIR/fire.log"
  printf '[%s] fire: scope=%s target=%s pane=%s socket=%s TM="%s"\n' \
    "$(date '+%F %T' 2>/dev/null)" "$scope" "$target" "$pane" "$socket" "${TM[*]}" >> "$logf" 2>/dev/null || true

  # Validate the target still exists before doing anything.
  if ! "${TM[@]}" has-session -t "$session" 2>/dev/null; then
    echo "wind-down fire: session '$session' gone — nothing to do." >&2
    printf '[%s] fire: session %s NOT found on %s - abort\n' "$(date '+%F %T' 2>/dev/null)" "$session" "${TM[*]}" >> "$logf" 2>/dev/null || true
    return 0
  fi
  # For window scope, target is a stable window_id (@N). If that exact window is
  # already gone, do nothing — never fall back to a guessed index (that's what
  # killed the wrong window before).
  if [ "$scope" != "session" ]; then
    if ! "${TM[@]}" list-windows -a -F '#{window_id}' 2>/dev/null | grep -qxF "$target"; then
      echo "wind-down fire: window '$target' already gone — nothing to do." >&2
      return 0
    fi
  fi

  # Honour window tags (Prefix+t, see tags.sh): a pinned/important window keeps
  # its wrap-up note but is never auto-closed. Window scope only — an explicit
  # `--session` teardown is a deliberate, wider ask.
  if [ "$scope" != "session" ] && [ -x "$HOME/.local/bin/tmux-tags" ]; then
    if reason=$("$HOME/.local/bin/tmux-tags" protected -t "$target" 2>/dev/null); then
      printf '[%s] fire: skipped, window %s is %s\n' \
        "$(date '+%F %T' 2>/dev/null)" "$target" "$reason" >> "$logf" 2>/dev/null || true
      echo "wind-down: '$target' is tagged ${reason} — note written, window left open."
      return 0
    fi
  fi

  reopen_asks "$sid" "$logf"

  # Resolve the window's CURRENT session:index from its stable id, only to name the saved history.
  label=$("${TM[@]}" list-windows -a -F '#{window_id} #{session_name}:#{window_index}' 2>/dev/null \
    | awk -v w="$target" '$1==w{print $2; exit}')

  # Prefer the pane id for the kill: pane ids (%N) are stable, while window
  # indices drift under `renumber-windows on`. Fall back to the index.
  local killtarget="${pane:-$target}"

  # Save the pane's whole history first, on the same server as the kill, so a closed window keeps
  # its screen and any draft in its prompt: $HISTORY_DIR/<time>-<session>_<index>-<sid>.txt, kept
  # 30 days. Best effort: a failed save never holds the close, and leaves no empty file.
  local hist
  if mkdir -p "$HISTORY_DIR" 2>/dev/null; then
    hist="$HISTORY_DIR/$(date +%F-%H%M%S)-${label//[^A-Za-z0-9_-]/_}-${sid:-nosid}.txt"
    "${TM[@]}" capture-pane -p -J -S - -t "$killtarget" > "$hist" 2>/dev/null || true
    [ -s "$hist" ] || rm -f -- "$hist"
    prune_history
  fi

  # Schedule the kill on the tmux SERVER via `run-shell -b`, NOT as a child of
  # this Stop hook. The hook's process tree is reaped when the turn ends; on
  # macOS (no setsid) a nohup'd child got killed before its `sleep` elapsed, so
  # the window stayed open. The tmux server is a persistent daemon, so a
  # backgrounded run-shell job reliably outlives the hook and fires the kill —
  # while the `sleep 1` still lets the Stop pipeline finish first. Kill by the
  # stable window_id (@N) so renumbering / active-window drift can't redirect it.
  # tmux-close decides what a teardown may close: a `--session` teardown of a world session
  # (hub dotfiles, where the human's chats live, or shepherd, where the passes run) closes this
  # window only.
  local kill_cmd close sock=''
  close="$(printf '%q' "$SCRIPT_DIR/close.sh")"
  [ "${#TM[@]}" -eq 1 ] || sock="-S $(printf '%q' "$socket") "
  if [ "$scope" = "session" ]; then
    kill_cmd="$close ${sock}session '$session' --window '$target'"
  else
    kill_cmd="$close ${sock}window '$target'"
  fi

  # `-c /`: the job would start in this hook's cwd, the worktree, and hold it against the reap.
  "${TM[@]}" run-shell -b -c / "sleep 1; $kill_cmd; echo \"[\$(date +%H:%M:%S)] ran: $kill_cmd\" >> '$logf'$(after_kill "$worktree" "$sid" "$logf")" 2>/dev/null
  local sched_rc=$?
  [ "$sched_rc" = 0 ] && WD_SCHEDULED=1   # read by cmd_close
  printf '[%s] fire: scheduled rc=%s cmd=%s\n' "$(date '+%F %T' 2>/dev/null)" "$sched_rc" "$kill_cmd" >> "$logf" 2>/dev/null || true
  echo "wind-down: scheduled '$kill_cmd' (rc=$sched_rc)"
}

# fire_bg: end a background session (scope=bg) with `claude stop <job>`; the daemon keeps its
# conversation, so `claude attach` or `--resume` reopens it. It reads fire's locals (bash dynamic
# scope). There is no window, so no tag protection: the session armed this itself.
fire_bg() {
  local logf="$SPIN_DIR/fire.log" claude_bin kill_cmd hist save_cmd=''
  mkdir -p "$SPIN_DIR"
  [[ "$target" =~ ^[0-9a-f]{8}$ ]] || { echo "wind-down fire: bad background job '$target'" >&2; return 1; }
  claude_bin=$(command -v claude) || { echo "wind-down fire: no claude on PATH to stop '$target'" >&2; return 1; }
  reopen_asks "$sid" "$logf"
  kill_cmd="$(printf '%q' "$claude_bin") stop '$target'"
  # The session's screen, as capture-pane saves a window's: in the detached job right before the
  # stop, so it never holds the Stop hook; best effort, and never an empty file. `claude logs` prints
  # the recent output and exits (it has no follow mode); the timeout only bounds a wedged daemon.
  if mkdir -p "$HISTORY_DIR" 2>/dev/null; then
    prune_history
    hist="$(printf '%q' "$HISTORY_DIR/$(date +%F-%H%M%S)-${label//[^A-Za-z0-9_-]/_}-${sid:-nosid}.txt")"
    save_cmd="$(printf '%q' "$claude_bin") logs '$target' > $hist 2>/dev/null; [ -s $hist ] || rm -f -- $hist; "
    command -v timeout >/dev/null 2>&1 && save_cmd="timeout 10 $save_cmd"
  fi
  # setsid: `claude stop` ends this session's process tree, the hook included, and the reap and
  # scratchpad removal chained behind it must outlive that. `sleep 1` lets the Stop pipeline finish
  # first, as the tmux path's does. `cd /`: the job would hold the worktree against the reap.
  # Reap and scratchpad only after a stop that worked: with no tmux session behind it, `wt reap` has
  # no live-session guard for a background session that is still running.
  setsid -f bash -c "cd /; sleep 1; $save_cmd if $kill_cmd >> '$logf' 2>&1; then echo \"[\$(date +%H:%M:%S)] ran: claude stop $target\" >> '$logf'$(after_kill "$worktree" "$sid" "$logf"); else echo \"[\$(date +%H:%M:%S)] claude stop $target failed: worktree and scratchpad kept\" >> '$logf'; fi" </dev/null >/dev/null 2>&1
  local sched_rc=$?
  [ "$sched_rc" = 0 ] && WD_SCHEDULED=1
  printf '[%s] fire: scheduled rc=%s cmd=%s\n' "$(date '+%F %T' 2>/dev/null)" "$sched_rc" "$kill_cmd" >> "$logf" 2>/dev/null || true
  echo "wind-down: scheduled '$kill_cmd' (rc=$sched_rc)"
}

# Saved screens are kept 30 days.
prune_history() { find "$HISTORY_DIR" -type f -name '*.txt' -mtime +30 -delete 2>/dev/null; }

# after_kill <worktree> <sid> <logf>: the steps chained behind a teardown, as one "; ..." string.
# Reap the worktree AFTER the kill and never before: `wt reap` refuses while a tmux session for the
# worktree is live, which is the correct answer right up until the window is gone. `reap` also
# refuses anything dirty or unpushed, so a session that ended mid-thought keeps its worktree and says
# so in the log -- there is no --force. The scratchpad goes after the kill too: until then Claude may
# still be writing to it. The id sits inside a glob, so anything that is not exactly a session id
# schedules nothing.
after_kill() {
  local out=''
  if [ -n "$1" ] && [ -d "$1" ] && [ -x "$HOME/.local/bin/wt" ]; then
    out="; $(printf '%q' "$HOME/.local/bin/wt") reap --after-kill '$1' >> '$3' 2>&1"
  fi
  is_session_id "$2" && out+="; rm -rf -- '$(scratch_root)'/*/'$2'"
  printf '%s' "$out"
}

# reopen_asks <sid> <logf>: each pending ask this session posted or joined is set to reopen it on the answer, so the answer
# carries on without the window: a `/wind-down` the human typed skips the skill's close check, where
# the model ran this. An ask that already resumes some other way keeps that resume; a refusal goes
# to fire.log and never holds the close (fleet-shepherd's close sets them first and keeps a window
# whose asks it cannot set). Set before the kill is scheduled, so the kill cannot cut a write short.
# Asks are read where agent-ask keeps them, <root>/<project>/<id>.md.
reopen_asks() {
  if is_session_id "$1"; then
    local af err
    while IFS= read -r af; do
      err="$(CLAUDE_CODE_SESSION_ID="$1" "$SCRIPT_DIR/../../bin/agent-ask" reopen-on-answer "$(basename "$af" .md)" 2>&1 >/dev/null)" ||
        printf '[%s] fire: ask %s not set to reopen: %s\n' "$(date '+%F %T' 2>/dev/null)" "$(basename "$af" .md)" "${err##*$'\n'}" >> "$2" 2>/dev/null || true
    done < <(grep -lxF "claude_session: $1" "$(ask_root)"/*/*.md 2>/dev/null |
      while IFS= read -r af; do ask_open "$af" && printf '%s\n' "$af"; done)
  fi
}

cmd_note_path() {
  local proj dir
  proj=$(resolve_project "${CLAUDE_PROJECT_DIR:-$PWD}")
  dir="$HOME/.agent/sessions/${proj}"
  mkdir -p "$dir"
  echo "$dir/$(date +%Y-%m-%d)-wind-down.md"
}

# Claude Code keeps each session's scratchpad at <root>/<project-slug>/<session-id>/.
scratch_root() { echo "${CLAUDE_SCRATCH_ROOT:-/tmp/claude-$(id -u)}"; }

is_session_id() {
  [[ "${1:-}" =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]]
}

# UserPromptSubmit hook: a new prompt, typed or a cross-session message, cancels this
# session's pending teardown. A teardown deferred by failing Stop checks otherwise fires at
# the next clean Stop, even when the human has since started new work. Never blocks a prompt.
# Also clears a "<project>__<sid>" file written before the key was the session id alone.
# A .fired marker on a prompt means the teardown already ran and this conversation is still
# talking (resumed, or its window survived); its transcript still reads "wind-down armed",
# so say it is not, or it waits on a Stop that closes nothing (ar-1197, 2026-11-08).
cmd_disarm() {
  local sid='' payload removed fired
  [ ! -t 0 ] && payload=$(cat 2>/dev/null)
  if [ -n "${payload:-}" ] && command -v jq >/dev/null 2>&1; then
    sid=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)
  fi
  sid="${sid:-${CLAUDE_CODE_SESSION_ID:-}}"
  is_session_id "$sid" || return 0
  fired=$(clear_markers "$sid" fired)
  removed=$(clear_markers "$sid" request)
  if [ "$removed" = 1 ]; then
    echo "wind-down disarmed: a new prompt or message arrived, so nothing fires at this Stop; run /wind-down again when this work is done."
  elif [ "$fired" = 1 ]; then
    echo "wind-down is not armed: this session's earlier teardown was spent at a Stop, so nothing fires at this Stop; run /wind-down again when this work is done."
  fi
  return 0
}

# clear_markers <sid> <ext>: remove this session's <sid>.<ext> and legacy <project>__<sid>.<ext>
# markers; print 1 when one existed, whether or not its rm succeeded.
clear_markers() {
  local f found=0
  for f in "$SPIN_DIR/$1.$2" "$SPIN_DIR"/*__"$1.$2"; do
    [ -f "$f" ] || continue
    found=1
    rm -f -- "$f"
  done
  echo "$found"
}

# Sourced (by the test suite) rather than run: stop here with every function defined but
# no verb dispatched. Without this, sourcing falls into the case below with $1 unset, hits
# the usage arm and `exit 2`s the test runner -- which is why the suite had reached for
# `eval "$(sed -n ...)"` extraction instead, and why this file ended up with no coverage
# at all despite arming a deferred `tmux kill-window`.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

case "${1:-}" in
  arm)       shift; cmd_arm "$@" ;;
  fire)      shift; cmd_fire "$@" ;;
  close)     shift; cmd_close "$@" ;;
  note-path) shift; cmd_note_path "$@" ;;
  disarm)    shift; cmd_disarm "$@" ;;
  *)
    echo "usage: wind-down.sh {arm [--session] | fire <sentinel-path> | close --server S --pane %N --sid ID | note-path | disarm}" >&2
    exit 2
    ;;
esac
