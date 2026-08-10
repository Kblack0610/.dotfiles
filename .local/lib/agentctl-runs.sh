# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# agentctl-runs.sh -- the grammar of an ad-hoc agent RUN.
#
# agentctl has always supervised RUNNERS: named .conf files, systemd units,
# timers. That covers the scheduled fleet and nothing else. There was no way to
# say "run this prompt, through the role contract, and let me see it afterwards" --
# so every ad-hoc invocation became a bare `claude -p` at a call site, with its
# own flags, and no trace anywhere. Eight of them accumulated.
#
# A RUN is the missing unit: one invocation, identified, recorded, and visible in
# the same places a supervised runner is.
#
#   $STATE_DIR/runs/<id>/
#       meta           id/label/role/harness/model/project/cwd/pid/unit/mode/started
#       status         the SAME five-key contract runners publish, byte for byte
#       last-outcome   PENDING | WORKED | NOOP | STALLED | UNKNOWN
#       output.log     harness stdout+stderr (headless only)
#       prompt         argv, one %q-quoted arg per line, mode 0600
#   $STATE_DIR/runs/ledger    append-only TSV, two rows per run, reduced on read
#
# Why a subtree and not a roster entry: fleet.sh states "THE ROSTER IS THE CONF
# DIR". A run has no conf, so a run row must not pretend to be a runner -- its
# unit field would be meaningless and the journal/start/stop binds would address
# a unit that does not exist. Two levels down also makes a name collision with a
# roster entry structurally impossible rather than merely unlikely.
#
# Why TSV and not JSONL: fleet.sh has no jq dependency and must not gain one on a
# render path. agent-notify's ledger made the same call for the same reason --
# the value is being able to see it at all, with tail and grep.
#
# This file is sourced by BOTH the writer (.local/bin/agentctl) and the reader
# (.local/src/tmux/fleet.sh), which is the point: one grammar, one place. The
# agent-board.sh / lab-feed.sh pair set that precedent.

# The one state dir, under either env name. Keep this expression identical to
# .local/bin/agentctl and .local/lib/agent-proof.sh -- they disagreed once
# (.dotfiles#231) and a status written where nothing reads is worse than none.
runs_state_dir() {
  printf '%s' "${AGENTCTL_STATE_DIR:-${AGENTCTL_STATE:-$HOME/.local/state/agentctl}}"
}

runs_dir() {
  printf '%s' "${AGENTCTL_RUNS_DIR:-$(runs_state_dir)/runs}"
}

RUNS_LEDGER_MAX="${AGENTCTL_RUNS_LEDGER_MAX:-2000}"
RUNS_KEEP="${AGENTCTL_RUNS_KEEP:-200}"

# ---------------------------------------------------------------- identity

# runs_new <label> -> absolute run dir, created.
#
# mktemp for the suffix: it is the house id primitive (agent-ask) and it makes
# the id atomic and collision-free, which a timestamp alone is not -- two runs
# started in the same second must not share a status file. The date prefix keeps
# `ls` chronological, which is the only ordering any reader here wants.
runs_new() {
  local d
  d="$(runs_dir)"
  mkdir -p "$d" 2>/dev/null || return 1
  mktemp -d "$d/$(date +%Y%m%dT%H%M%S)-XXXXXX" 2>/dev/null || return 1
}

runs_id_of() { basename "$1"; }

# ---------------------------------------------------------------- meta

runs_meta_write() {
  local dir="$1"; shift
  local kv
  for kv in "$@"; do
    # one physical line per key, same reason status_write flattens
    printf '%s\n' "${kv//$'\n'/ }"
  done >> "$dir/meta" 2>/dev/null || return 0
}

runs_meta_get() {
  local dir="$1" key="$2"
  [ -r "$dir/meta" ] || return 0
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); v=$0 } END { if (v != "") print v }' "$dir/meta"
}

# ---------------------------------------------------------------- ledger
#
# Fields, tab-separated:
#   ts  event  id  label  role  harness  project  outcome  exit  dur_s  excerpt
#
# Append-only, never rewritten in place, no locking. A single printf under
# PIPE_BUF with O_APPEND is atomic on Linux, which is why the excerpt is
# truncated hard -- a long prompt is the one thing that could push a row past it
# and interleave two runs' bytes.
runs_ledger() { printf '%s/ledger' "$(runs_dir)"; }

runs_ledger_append() {
  local f; f="$(runs_ledger)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  local out="" a
  for a in "$@"; do
    a="${a//$'\t'/ }"; a="${a//$'\n'/ }"
    out+="${a}"$'\t'
  done
  printf '%s\n' "${out%$'\t'}" >> "$f" 2>/dev/null || true
}

# Keep the newest N lines. Trim on write (agent-notify's pattern): no timer, no
# cron, and the cost is paid by whoever is already doing IO.
runs_ledger_trim() {
  local f; f="$(runs_ledger)"
  [ -r "$f" ] || return 0
  local n; n="$(wc -l < "$f" 2>/dev/null || echo 0)"
  [ "${n:-0}" -gt "$RUNS_LEDGER_MAX" ] || return 0
  local tmp="$f.trim.$$"
  tail -n "$RUNS_LEDGER_MAX" "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
  rm -f "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------- prune
#
# Deliberately paranoid about the path. The live state dir has previously had
# test fixtures leak into it, and a count-based remover plus a mis-resolved $HOME
# is how a cleanup routine eats real state. Refuse anything that is not a
# directory literally named `runs`.
runs_prune() {
  local keep="${1:-$RUNS_KEEP}" d
  d="$(runs_dir)"
  case "$d" in
    */runs) : ;;
    *) return 0 ;;                     # not the runs subtree: refuse, silently
  esac
  [ -d "$d" ] || return 0
  local -a all=()
  while IFS= read -r p; do [ -n "$p" ] && all+=("$p"); done < <(
    find "$d" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort
  )
  local n=${#all[@]}
  [ "$n" -gt "$keep" ] || return 0
  local i
  for ((i = 0; i < n - keep; i++)); do
    case "${all[$i]}" in
      "$d"/*) rm -rf -- "${all[$i]}" 2>/dev/null || true ;;
    esac
  done
}

# ---------------------------------------------------------------- reconcile
#
# A run killed by SIGKILL, or lost to a reboot, leaves status=working forever.
# Reconciling on READ rather than by a sweeper is what lets that be correct with
# no daemon and no heartbeat: the reader already has the pid, and a pid that is
# gone is all the evidence needed.
runs_pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# runs_state <dir> -> the state a reader should display.
runs_state() {
  local dir="$1" st pid
  st="$(awk -F= '$1=="state"{sub(/^[^=]*=/,"");print;exit}' "$dir/status" 2>/dev/null)"
  [ -n "$st" ] || { printf 'unknown'; return 0; }
  if [ "$st" = working ]; then
    pid="$(runs_meta_get "$dir" pid)"
    runs_pid_alive "$pid" || { printf 'error'; return 0; }
  fi
  printf '%s' "$st"
}

# runs_outcome <dir> -> the recorded verdict, reconciled the same way.
runs_outcome() {
  local dir="$1" o pid
  o="$(cat "$dir/last-outcome" 2>/dev/null)"
  [ -n "$o" ] || { printf 'UNKNOWN'; return 0; }
  if [ "$o" = PENDING ]; then
    pid="$(runs_meta_get "$dir" pid)"
    runs_pid_alive "$pid" || { printf 'ORPHANED'; return 0; }
  fi
  printf '%s' "$o"
}

# ---------------------------------------------------------------- verdict
#
# `claude -p` exits 0 whether it did the whole job or politely declined, which is
# why agent-proof.sh exists. But proof_verdict's default -- no change and no NOOP
# marker means STALLED -- is right for a runner with a known artifact and WRONG
# for `agentctl run --role plan -p "summarise this"`, whose only product is
# stdout. Calling that STALLED teaches the reader to ignore STALLED, and a signal
# everyone ignores is worse than no signal.
#
# So: tiers, and an honest UNKNOWN at the bottom. proof_verdict is NOT changed --
# five runners depend on its current semantics; this only delegates to it when a
# working set actually exists.
#
# runs_verdict <dir> <rc> [watch-path...]
runs_verdict() {
  local dir="$1" rc="$2"; shift 2
  local out="$dir/output.log"

  # Unconditional and first: plan-mode output is a stall regardless of tier, and
  # it needs no working set. This is the check that would have caught dream's
  # 150 no-op sweeps.
  if [ -r "$out" ] && [ -n "${AGENT_PROOF_STALL_RE:-}" ] \
     && grep -qEi "$AGENT_PROOF_STALL_RE" "$out" 2>/dev/null; then
    printf 'STALLED'; return 0
  fi

  [ "${rc:-0}" -ne 0 ] && { printf 'STALLED'; return 0; }

  # Tier 1: an explicit working set. Best signal; scripts should pass --watch.
  if [ "$#" -gt 0 ]; then
    local p
    for p in "$@"; do
      [ -s "$p" ] && { printf 'WORKED'; return 0; }
    done
    printf 'NOOP'; return 0
  fi

  # Tier 2: cwd is a git repo -> did anything about it change? Timeout-bounded so
  # a huge or network-backed repo cannot stall the wrapper.
  local cwd; cwd="$(runs_meta_get "$dir" cwd)"
  if [ -n "$cwd" ] && [ -d "$cwd/.git" ]; then
    local before after
    before="$(runs_meta_get "$dir" git_mark)"
    after="$(cd "$cwd" 2>/dev/null && printf '%s|%s' \
             "$(git rev-parse HEAD 2>/dev/null)" \
             "$(timeout 5 git status --porcelain 2>/dev/null | md5sum 2>/dev/null | cut -c1-32)")"
    if [ -n "$before" ]; then
      [ "$before" != "$after" ] && { printf 'WORKED'; return 0; }
      printf 'NOOP'; return 0
    fi
  fi

  # Tier 3: nothing to measure. Say so.
  printf 'UNKNOWN'
}

# The watermark tier 2 compares against. Taken at start, cheap, best-effort.
runs_git_mark() {
  local cwd="$1"
  [ -d "$cwd/.git" ] || return 0
  (cd "$cwd" 2>/dev/null && printf '%s|%s' \
     "$(git rev-parse HEAD 2>/dev/null)" \
     "$(timeout 5 git status --porcelain 2>/dev/null | md5sum 2>/dev/null | cut -c1-32)")
}
