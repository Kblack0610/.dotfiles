# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# fleet-hosts.sh - the fleet worker roster and the one ssh path to a worker.
#
# The roster is the home-config Ansible inventory group `fleet_workers` (FLEET_HOSTS_GROUP), the
# same file that provisions them (roles/fleet-worker): no second hosts file. fleet-dispatch places
# sessions on it, wt opens them there, fleet-sessions reads them back. The workstation itself is
# not in the group: its own limits stay in fleet-dispatch.conf.

_fh_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
: "${FLEET_HOST:=${HOSTNAME%%.*}}"   # this machine's short name
: "${FLEET_HOSTS_GROUP:=fleet_workers}"
: "${FLEET_SSH_TIMEOUT:=5}"   # seconds an ssh to a worker may take to connect, and may go silent
: "${FLEET_FETCH_SECS:=20}"   # seconds fleet_roster_fetch may take before the roster stays as last fetched
: "${FLEET_ROSTER_MAX_SECS:=900}"   # a roster last fetched longer ago is fetched before it is read: fleet-dispatch's pass cadence
: "${FLEET_ROSTER_RETRY_SECS:=60}"   # after a failed fetch, seconds before a read tries again

# fleet_inventory_repo -> home-config's checkout, from the project map.
fleet_inventory_repo() {
  declare -F project_repo_path >/dev/null ||
    . "${PROJECT_NAME_LIB:-$_fh_lib/../../.config/shared-hooks/project-name.sh}" 2>/dev/null || return 1
  local hc; hc=$(project_repo_path home-config 2>/dev/null) && [ -n "$hc" ] || return 1
  printf '%s' "$hc"
}

# fleet_roster_ref <checkout> -> the remote-tracking ref its mainline (main, else master) follows,
# such as forgejo/master, whatever branch the checkout itself is on.
fleet_roster_ref() {
  local b up
  for b in main master; do
    up=$(git -C "$1" rev-parse --abbrev-ref --symbolic-full-name "$b@{u}" 2>/dev/null) &&
      [ -n "$up" ] && { printf '%s' "$up"; return 0; }
  done
  return 1
}

# fleet_inventory -> where the roster is read from: FLEET_INVENTORY, else
# "<checkout> <ref>:ansible/inventory.yml".
fleet_inventory() {
  if [ -n "${FLEET_INVENTORY:-}" ]; then printf '%s' "$FLEET_INVENTORY"; return; fi
  local hc ref; hc=$(fleet_inventory_repo) && ref=$(fleet_roster_ref "$hc") || return 1
  printf '%s %s:ansible/inventory.yml' "$hc" "$ref"
}

# fleet_inventory_text -> the inventory's YAML. home-config's comes from its mainline's
# remote-tracking ref, never its working tree: nothing pulls that checkout, so the tree lags what
# merged on the forge. A checkout with no such ref or file reads as no roster, said on stderr, so
# every session stays here. A ref last fetched over FLEET_ROSTER_MAX_SECS ago is fetched first
# (fleet_roster_fresh), so a machine back from being off reads the roster as it is now.
fleet_inventory_text() {
  if [ -n "${FLEET_INVENTORY:-}" ]; then cat "$FLEET_INVENTORY" 2>/dev/null; return; fi
  local hc ref
  hc=$(fleet_inventory_repo) || return 1
  ref=$(fleet_roster_ref "$hc") || {
    echo "fleet-hosts: $hc has no main or master tracking a remote, so the fleet roster reads as empty" >&2
    return 1
  }
  fleet_roster_fresh "$hc"
  git -C "$hc" show "$ref:ansible/inventory.yml" 2>/dev/null || {
    echo "fleet-hosts: $ref in $hc has no ansible/inventory.yml, so the fleet roster reads as empty" >&2
    return 1
  }
}

# fleet_roster_fetch: fetch that ref alone, so a roster change merged on the forge reaches the next
# pass; the working tree never moves. It cannot prompt, and runs no gc in a checkout others share.
# A failed fetch says so on stderr, marks <stamp>.failed and returns 1; the roster stays as last
# fetched. A fetch that lands stamps the checkout (_fh_stamp) and clears the mark, so the stamp is
# always the last fetch that landed, which fleet_roster_fresh ages.
fleet_roster_fetch() {
  [ -z "${FLEET_INVENTORY:-}" ] || return 0
  local hc ref stamp; hc=$(fleet_inventory_repo) && ref=$(fleet_roster_ref "$hc") || return 0
  stamp=$(_fh_stamp "$hc")
  if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' timeout "$FLEET_FETCH_SECS" \
    git -C "$hc" -c gc.auto=0 fetch --quiet "${ref%%/*}" "${ref#*/}" 2>/dev/null; then
    [ -z "$stamp" ] || { touch "$stamp"; rm -f "$stamp.failed"; } 2>/dev/null || true
    return 0
  fi
  echo "fleet-hosts: fetching $ref in $hc failed, so the roster is as last fetched" >&2
  [ -z "$stamp" ] || touch "$stamp.failed" 2>/dev/null || true
  return 1
}

# _fh_stamp <checkout> -> the file in its git dir whose mtime is the roster's last fetch. The ref's
# reflog cannot say: a fetch that finds nothing new writes no entry.
_fh_stamp() { git -C "$1" rev-parse --path-format=absolute --git-path fleet-roster-fetched 2>/dev/null; }

# _fh_older <file> <secs> -> rc 0 when the file was last touched <secs> ago or more, or is missing.
_fh_older() {
  local last; last=$(date -r "$1" +%s 2>/dev/null || echo 0)
  [ $(($(date +%s) - last)) -ge "$2" ]
}

# _fh_due <stamp> -> rc 0 when the last fetch is FLEET_ROSTER_MAX_SECS old or more and none failed in
# the last FLEET_ROSTER_RETRY_SECS.
_fh_due() { _fh_older "$1" "$FLEET_ROSTER_MAX_SECS" && _fh_older "$1.failed" "$FLEET_ROSTER_RETRY_SECS"; }

# fleet_roster_fresh <checkout>: fetch the roster when it is due (_fh_due). One reader fetches under
# a lock beside the stamp; the others wait for it and read what it fetched, so units that start
# together at boot all see the same roster. A forge that is down costs one fetch a minute, not one a
# call, and the roster reads as last fetched. A reader that cannot write the lock (a sandboxed lane)
# never fetches and reads the ref as it is.
fleet_roster_fresh() {
  local stamp; stamp=$(_fh_stamp "$1") && [ -n "$stamp" ] || return 0
  _fh_due "$stamp" || return 0
  { : >>"$stamp.lock"; } 2>/dev/null || return 0
  {
    flock -w "$((FLEET_FETCH_SECS + 5))" 9 && _fh_due "$stamp" || return 0
    fleet_roster_fetch
    return 0
  } 9>>"$stamp.lock"
}

# fleet_hosts -> one JSON object a line per host of the group, in file order:
#   {name, dest: user@host, port, max_live, place, repos: [dir], power, first: [class]}
# host is fleet_ssh_host when set, else ansible_host: a cloud worker's ansible_host is an instance
# id that Ansible reaches through SSM, and fleet_ssh_host its tailnet name. power is fleet_power,
# "governor" for a box the ci-runner-governor starts on demand (fleet-dispatch demand_pass). first is
# fleet_first, the item classes (canary) this worker takes ahead of the dispatching machine.
# Vars merge as Ansible reads them for this file's shape: all.vars, then group vars (a child group
# over its parent), then the host's own entries over every group, a later entry winning among
# equals, so ansible_host may sit in another group. Nothing when the
# file or group is missing. Read once per shell (FLEET_HOSTS_JSON): a caller that loops over it, or
# runs fleet_host_run in one, calls fleet_hosts >/dev/null first, so the subshells inherit it.
fleet_hosts() {
  if [ -z "${FLEET_HOSTS_JSON+x}" ]; then
    local inv
    FLEET_HOSTS_JSON=''
    # A file that never names the group has no workers; that case skips python.
    if inv=$(fleet_inventory_text) && grep -qs "^[[:space:]]*$FLEET_HOSTS_GROUP:" <<<"$inv"; then
      FLEET_HOSTS_JSON=$(_fh_parse "$inv") || FLEET_HOSTS_JSON=''
    fi
  fi
  [ -z "$FLEET_HOSTS_JSON" ] || printf '%s\n' "$FLEET_HOSTS_JSON"
}

# _fh_parse <inventory yaml> -> fleet_hosts' lines for FLEET_HOSTS_GROUP; rc 1, said on stderr, when
# python has no yaml module or the YAML does not load.
_fh_parse() {
  python3 -I - <(printf '%s\n' "$1") "$FLEET_HOSTS_GROUP" <<'PY'
import json, os, sys
try:
    import yaml
except ImportError:
    sys.exit("fleet-hosts: python3 has no yaml module (python-yaml), so the fleet roster reads as empty")

inv, group = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(inv)) or {}
root = doc.get("all") or {}
base = dict(root.get("vars") or {})
gmerged, hmerged, members = {}, {}, {}

def walk(name, node, chain):
    node = node or {}
    gvars = dict(node.get("vars") or {})
    path = chain + [(name, gvars)]
    for h, hv in (node.get("hosts") or {}).items():
        gm = gmerged.setdefault(h, {})
        for _, gv in path:
            gm.update(gv)
        hmerged.setdefault(h, {}).update(hv or {})
        for g, _ in path:
            members.setdefault(g, [])
            if h not in members[g]:
                members[g].append(h)
    for c, cn in (node.get("children") or {}).items():
        walk(c, cn, path)

walk("all", root, [])

for h in members.get(group, []):
    v = dict(base)
    v.update(gmerged.get(h, {}))
    v.update(hmerged.get(h, {}))
    user = v.get("ansible_user")
    host = v.get("fleet_ssh_host") or v.get("ansible_host", h)
    repos = [os.path.expanduser(str(r.get("dest") if isinstance(r, dict) else r)) for r in (v.get("fleet_repos") or [])]
    print(json.dumps({
        "name": h,
        "dest": f"{user}@{host}" if user else str(host),
        "port": int(v.get("ansible_port", 22)),
        "max_live": int(v.get("fleet_max_live", 1)),
        "place": bool(v.get("fleet_place", True)),
        "repos": repos,
        "power": str(v.get("fleet_power", "")),
        "first": [str(c) for c in (lambda f: f if isinstance(f, list) else [f])(v.get("fleet_first") or [])],
        "agent_cpus": str(v.get("agent_cpus") or ""),
        "local": v.get("ansible_connection") == "local",
    }))
PY
}

# fleet_cap_hosts -> one fleet_hosts-shaped line per inventory host, in any group, that sets
# agent_cpus: the cpuset home-config's agent-host-budget role pins every tmux pane and agent lane
# to. The workstation is one though it is no fleet worker. Read fresh, never from FLEET_HOSTS_JSON.
fleet_cap_hosts() {
  local inv
  inv=$(fleet_inventory_text) && grep -qs '^[[:space:]]*agent_cpus:' <<<"$inv" || return 0
  FLEET_HOSTS_GROUP=all _fh_parse "$inv" | jq -c 'select(.agent_cpus != "")'
}

# fleet_host <name> -> that host's roster line; rc 1 when the roster does not list it.
fleet_host() { fleet_hosts | jq -c --arg n "$1" 'select(.name == $n)' 2>/dev/null | grep -m1 .; }

# fleet_host_run <name> <command> [args...] -- run one command on the worker over ssh, each
# argument quoted, with ~/.local/bin first on PATH (a non-interactive ssh shell reads no rc file).
# stdin goes through only with FLEET_SSH_STDIN=1: a remote command in a `while read` loop must
# not eat the loop's input. The command's own exit code comes back; 255 is ssh's, an unreachable
# host or a refused key.
fleet_host_run() {
  local h dest port
  fleet_hosts >/dev/null
  h=$(fleet_host "$1") || { echo "fleet-hosts: $1 is not in $FLEET_HOSTS_GROUP" >&2; return 255; }
  shift
  IFS=$'\t' read -r dest port < <(jq -r '[.dest, .port] | @tsv' <<<"$h")
  _fh_ssh "$dest" -p "$port" -- "$@"
}

# fleet_host_panel <name> -> that worker's `agent-panel list --json` rows, each with the worker in
# `host` and its target as <host>@<server>/<session>:<window>, which names no tmux server here, so
# nothing aimed at the row lands on a local session that shares its name. The one reader of a
# worker's sessions: fleet-sessions (which publishes what it read, fleet_panel_publish) and the walk of
# the peers when no snapshot is fresh (fleet_panel_row) go through it.
# Rc is the call's: 255 the host did not answer, 3 a read with a gap (its rows still print), any
# other the worker's agent-panel failed and prints no row.
fleet_host_panel() {
  local out rc=0
  out=$(fleet_host_run "$1" agent-panel list --json 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || return "$rc"
  jq -c --arg h "$1" 'select(type == "object") | . + {host: $h, target: ($h + "@" + (.target // ""))}' <<<"$out" 2>/dev/null
  return "$rc"
}

# fleet_peers -> the name of each fleet worker but this machine ($FLEET_HOST), in roster order: the
# machines a read or verb meant for every machine asks over ssh, beside what this one does itself.
# A caller reading it through <(...) runs `fleet_hosts >/dev/null` first, so the roster it caches
# is read once.
fleet_peers() { fleet_hosts | jq -r --arg me "$FLEET_HOST" 'select(.name != $me) | .name'; }

# fleet_panel_file -> where the minute record publishes every worker's rows: worker-panel.json beside
# state.json (FLEET_STATE_FILE, else $XDG_STATE_HOME/fleet), the path agent-web's
# hub_core::boards::worker_panel derives the same way.
fleet_panel_file() {
  local f="${FLEET_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet/state.json}"
  printf '%s/worker-panel.json\n' "${f%/*}"
}

# fleet_panel_publish <ttl secs> [<silent worker>...] -- stdin: the worker rows (fleet_host_panel's
# lines) the minute record just read; the workers named did not answer it, so their rows are missing
# and not gone. Writes {at, ttl, rows, silent} to fleet_panel_file, atomically, so a reader never sees
# half a file. The writer owns the ttl: how long a reader may trust these rows without asking.
fleet_panel_publish() {
  local f ttl="$1"; f=$(fleet_panel_file)
  shift
  mkdir -p "${f%/*}" || return 1
  jq -cs --argjson ttl "$ttl" '{at: (now | floor), ttl: $ttl, rows: ., silent: $ARGS.positional}' --args "$@" > "$f.tmp.$$" &&
    mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
}

# fleet_panel_snapshot -> the published document {at, ttl, rows, silent}; rc 1 and nothing printed when
# there is none or it is older than its own ttl (the minute record has not run, or has died).
fleet_panel_snapshot() {
  jq -ce 'select(now - .at <= .ttl)' "$(fleet_panel_file)" 2>/dev/null
}

# _fh_panel_walk <claude session id> [<worker>...] -> the first row of that session among these
# workers (fleet_host_panel), in the order given, asking them all at once so the wait is the slowest
# one's, not the sum. A worker that does not answer adds no row.
_fh_panel_walk() {
  local sid="$1" row name dir pids=()
  shift
  [ $# -gt 0 ] || return 0
  fleet_hosts >/dev/null
  dir=$(mktemp -d) || return 0
  for name in "$@"; do
    fleet_host_panel "$name" >"$dir/$name" 2>/dev/null &
    pids+=("$!")
  done
  wait "${pids[@]}"
  for name in "$@"; do
    row=$(jq -cn --arg s "$sid" 'first(inputs | select(.session_id == $s))' <"$dir/$name" 2>/dev/null)
    [ -z "$row" ] || { printf '%s\n' "$row"; break; }
  done
  rm -rf "$dir"
}

# fleet_panel_row <claude session id> -> the first worker row of that session in roster order, nothing
# when no worker has it. For a caller that already missed it in this machine's own agent-panel.
# It reads the snapshot (fleet_panel_snapshot), so a read costs no ssh; only a worker the snapshot
# names silent is asked, and with no fresh snapshot every peer is. A live session read as gone is
# reopened as a second copy, which costs more than the ssh.
fleet_panel_row() {
  [ -n "${1:-}" ] || return 0
  local doc row names=()
  if doc=$(fleet_panel_snapshot); then
    row=$(jq -c --arg s "$1" --arg me "$FLEET_HOST" 'first(.rows[] | select(.session_id == $s and .host != $me)) // empty' <<<"$doc" 2>/dev/null)
    [ -z "$row" ] || { printf '%s\n' "$row"; return 0; }
    mapfile -t names < <(jq -r --arg me "$FLEET_HOST" '.silent[]? | select(. != $me)' <<<"$doc" 2>/dev/null)
  else
    fleet_hosts >/dev/null
    mapfile -t names < <(fleet_peers)
  fi
  _fh_panel_walk "$1" "${names[@]}"
  return 0
}

# _fh_ssh <dest> [ssh options...] -- <command> [args...] -- the one ssh call to a worker.
# FLEET_SSH_TTY=1 is an interactive call (tmx goto <host>@<server>, a tmux attach on the worker):
# a tty, and the terminal's stdin.
_fh_ssh() {
  local dest="$1" opts=() n=-n tty=-T
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
  shift
  [ "${FLEET_SSH_STDIN:-0}" != 1 ] || n=''
  [ "${FLEET_SSH_TTY:-0}" != 1 ] || { n=''; tty=-t; }
  # -T: a worker call never wants a tty; a `RequestTTY yes` in ssh_config otherwise puts a
  # "Pseudo-terminal will not be allocated" line into every call's output.
  # ServerAlive ends a link that went half-open mid-command (a laptop asleep) in about two timeouts.
  # shellcheck disable=SC2016 # $HOME and $PATH are the remote shell's
  ssh $n $tty -o BatchMode=yes -o ConnectTimeout="$FLEET_SSH_TIMEOUT" -o ServerAliveInterval="$FLEET_SSH_TIMEOUT" -o ServerAliveCountMax=2 "${opts[@]}" "$dest" \
    'PATH="$HOME/.local/bin:$PATH" exec env' "$(_fh_sq "$@")"
}

# _fh_sq <args...> -> each argument in POSIX single quotes, space-separated, which sh, bash and zsh
# all read back literally. Not bash's %q: it leaves a leading = bare, which zsh expands to a
# command's path, so `has-session -t =<name>` exited 1 on a zsh worker and reap read every session
# there as gone (razer-laptop, 2026-11-18).
_fh_sq() {
  local a q="'" out=''
  for a in "$@"; do out+="'${a//$q/$q\\$q$q}' "; done
  printf '%s' "$out"
}
