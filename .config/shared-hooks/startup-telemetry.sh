# shellcheck shell=bash
# startup-telemetry.sh (sourced) - how long a Claude Code start took, one jsonl row per start.
# The hook calls startup_mark <phase> after each part of its work and startup_record once at
# the end; `fleet-bench startup` reads CLAUDE_STARTUP_LOG (the KPI and the claude-startup watch).
#   process_ms  claude process start -> this hook's process start (the harness boot)
#   hook_ms     the hook's own wall time; it is the only SessionStart hook, so also the chain's
#   ready_ms    claude process start -> startup_record: the turn-1 context is ready (the TUI's
#               first paint is not visible to a hook)
#   hooks       [{name, ms, phases: {<phase>: ms}}]
#   mcp         [{name, spawn_ms}] per stdio server in the project's .mcp.json, null when its
#               process was not running by the end of the hook
# Process times come from /proc, so they are null on macOS; phases need EPOCHREALTIME (bash 5).
# Builtins only until the one jq that writes the row: this runs on the path it measures.
# Every failure is quiet: a telemetry row must never cost the session its preflight.

: "${CLAUDE_STARTUP_LOG:=$HOME/.agent/telemetry/claude-startup.jsonl}"

_ST_LAST=${EPOCHREALTIME:-} _ST_PHASES='' _ST_TCK=100
_ST_LAST=${_ST_LAST/[.,]/}

# startup_mark <phase> -> the ms since the previous mark, recorded under <phase>
startup_mark() {
  local now=${EPOCHREALTIME:-}
  now=${now/[.,]/}
  [ -n "$now" ] && [ -n "$_ST_LAST" ] || return 0
  _ST_PHASES+="${_ST_PHASES:+,}\"$1\":$(( (now - _ST_LAST) / 1000 ))"
  _ST_LAST=$now
}

# _st_stat <pid> -> the fields of /proc/<pid>/stat after comm, which may hold spaces, in _ST_F:
# _ST_F[1] is the ppid, _ST_F[19] the start time in clock ticks
_st_stat() {
  local s
  [ -r "/proc/$1/stat" ] && read -r s <"/proc/$1/stat" || return 1
  read -ra _ST_F <<<"${s##*) }"
  [ -n "${_ST_F[19]:-}" ]
}

# _st_start_ms <pid> -> how many ms ago <pid> started, from its start ticks and /proc/uptime
_st_start_ms() {
  local up
  _st_stat "$1" && read -r up _ 2>/dev/null </proc/uptime || return 1
  echo $(( ${up%.*} * 1000 + 10#${up#*.} * 10 - _ST_F[19] * 1000 / _ST_TCK ))
}

# _st_claude_pid -> the claude process this hook runs under: CLAUDE_PID, else the nearest
# ancestor named claude
_st_claude_pid() {
  local p=$PPID comm
  if [ -n "${CLAUDE_PID:-}" ] && [ -r "/proc/$CLAUDE_PID/stat" ]; then printf '%s' "$CLAUDE_PID"; return 0; fi
  for _ in 1 2 3 4 5; do
    [ -r "/proc/$p/comm" ] && read -r comm <"/proc/$p/comm" || return 1
    [ "$comm" = claude ] && { printf '%s' "$p"; return 0; }
    _st_stat "$p" || return 1
    p=${_ST_F[1]}
    [ "$p" -gt 1 ] || return 1
  done
  return 1
}

# _st_mcp <claude pid> <claude age ms> <project dir> -> the mcp array. A server's process is
# the claude child whose command line holds the basename of its last argument (npx and uvx
# rewrite argv, the package or script name survives).
_st_mcp() {
  local cfg="$3/.mcp.json" kids='' c age a
  [ -r "$cfg" ] || { echo '[]'; return 0; }
  for c in $(cat "/proc/$1"/task/*/children 2>/dev/null); do
    age=$(_st_start_ms "$c") && [ -r "/proc/$c/cmdline" ] || continue
    mapfile -d '' -t a <"/proc/$c/cmdline"
    kids+="$(( $2 - age ))"$'\t'"${a[*]}"$'\n'
  done
  jq -c --arg kids "$kids" '
    [$kids | split("\n")[] | select(. != "") | split("\t") | {ms: (.[0] | tonumber), cmd: (.[1:] | join("\t"))}] as $k
    | [.mcpServers // {} | to_entries[] | select((.value.type // "stdio") == "stdio" and .value.command)
       | (((.value.args // []) | last) // .value.command | split("/") | last) as $tok
       | {name: .key, spawn_ms: ([$k[] | select(.cmd | contains($tok)) | .ms] | min)}]' "$cfg" 2>/dev/null || echo '[]'
}

# startup_record <hook> <session id> <source> <project> -> one row appended to CLAUDE_STARTUP_LOG
startup_record() {
  command -v jq >/dev/null 2>&1 || return 0
  local hook_age claude claude_age mcp='[]' hook_ms phases="{$_ST_PHASES}" exe=${CLAUDE_CODE_EXECPATH:-}
  local dir=${CLAUDE_STARTUP_LOG%/*}
  _ST_TCK=$(getconf CLK_TCK 2>/dev/null) && [ "${_ST_TCK:-0}" -gt 0 ] 2>/dev/null || _ST_TCK=100
  hook_age=$(_st_start_ms $$) || hook_age=null
  if claude=$(_st_claude_pid) && claude_age=$(_st_start_ms "$claude"); then
    mcp=$(_st_mcp "$claude" "$claude_age" "${CLAUDE_PROJECT_DIR:-$PWD}")
  else
    claude_age=null
  fi
  hook_ms=$hook_age
  [ "$hook_ms" != null ] || hook_ms=$(jq -n "$phases | [.[]] | add" 2>/dev/null) || hook_ms=null
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  jq -nc --arg sid "$2" --arg source "$3" --arg project "$4" --arg hook "$1" \
     --argjson phases "$phases" --argjson mcp "$mcp" --argjson hook_ms "${hook_ms:-null}" \
     --argjson c "$claude_age" --argjson h "$hook_age" \
     --arg version "${exe##*/}" --arg entry "${CLAUDE_CODE_ENTRYPOINT:-}" \
     --arg attended "${CLAUDE_CODE_SESSION_ATTENDED:-}" --arg host "${HOSTNAME:-$(uname -n)}" '
    def nz: if . == "" then null else . end;
    {ts: (now | todate), epoch: (now | floor), sid: $sid, source: $source, project: $project,
     host: $host, version: ($version | nz), entry: ($entry | nz), attended: ($attended == "1"),
     process_ms: (if $c != null and $h != null then $c - $h else null end),
     hook_ms: $hook_ms, ready_ms: $c,
     hooks: [{name: $hook, ms: $hook_ms, phases: $phases}], mcp: $mcp}' \
    >>"$CLAUDE_STARTUP_LOG" 2>/dev/null || true
}
