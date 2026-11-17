# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# fleet-hosts.sh - the fleet worker roster, the one ssh path to a worker, and the one way a
# session on a worker writes the agent store on the workstation.
#
# The roster is the home-config Ansible inventory group `fleet_workers` (FLEET_HOSTS_GROUP), the
# same file that provisions them (roles/fleet-worker): no second hosts file. fleet-dispatch places
# sessions on it, wt opens them there, fleet-sessions reads them back. The workstation itself is
# not in the group: it is where the store lives, and its own limits stay in fleet-dispatch.conf.
#
# The roster's fleet_state_host is the fleet home: the one machine that holds the store and runs
# the singletons (dispatch, fleet-state, ask delivery, store sync, agent-web). Every other machine
# forwards: agent-queue and agent-ask call state_forward first, which runs the same command there
# over ssh, so the queue, the asks and their one writer stay on the home (agentctl QUEUE.md). A
# session placed on a worker has AGENT_STATE_HOST on its launch line; any other machine that reads
# the roster forwards to the home it names. fleet-is-home gates the singleton units on fleet_is_home.
# Runbook: home-config docs/runbooks/fleet-worker.md.

_fh_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
: "${FLEET_HOST:=${HOSTNAME%%.*}}"   # this machine's short name, compared with the roster's fleet_state_host
: "${FLEET_HOSTS_GROUP:=fleet_workers}"
: "${FLEET_SSH_TIMEOUT:=5}"   # seconds an ssh to a worker or the state host may take to connect, and may go silent
: "${FLEET_FETCH_SECS:=20}"   # seconds fleet_roster_fetch may take before the roster stays as last fetched
: "${FLEET_ROSTER_MAX_SECS:=900}"   # a roster last fetched longer ago is fetched before it is read: fleet-dispatch's pass cadence
: "${FLEET_ROSTER_RETRY_SECS:=60}"   # after a failed fetch, seconds before a read tries again
: "${FLEET_ROSTER_TRUST_SECS:=3600}"   # a roster last fetched longer ago cannot say which machine is home (fleet_is_home): four pass cadences, so a forge blip keeps the home home

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
# (fleet_roster_fresh), so a machine back from being off never reads itself as the home it was.
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
# always the last fetch that landed: fleet_roster_fresh ages it, and fleet_is_home trusts it.
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
# together at boot all see the new home. A forge that is down costs one fetch a minute, not one a
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

# _fh_untrusted -> why the roster as last fetched cannot name the home, or nothing: its last fetch
# that landed is FLEET_ROSTER_TRUST_SECS old or more. A machine back from days off whose fetch fails
# reads its old roster, which may still name it. FLEET_INVENTORY is a file, never fetched.
_fh_untrusted() {
  [ -z "${FLEET_INVENTORY:-}" ] || return 0
  local hc stamp; hc=$(fleet_inventory_repo) && stamp=$(_fh_stamp "$hc") && [ -n "$stamp" ] || return 0
  _fh_older "$stamp" "$FLEET_ROSTER_TRUST_SECS" || return 0
  printf 'no fetch of it has landed in the last %ss' "$FLEET_ROSTER_TRUST_SECS"
}

# fleet_hosts -> one JSON object a line per host of the group, in file order:
#   {name, dest: user@host, port, max_live, place, repos: [dir], state_host, power}
# host is fleet_ssh_host when set, else ansible_host: a cloud worker's ansible_host is an instance
# id that Ansible reaches through SSM, and fleet_ssh_host its tailnet name. power is fleet_power,
# "governor" for a box the ci-runner-governor starts on demand (fleet-dispatch demand_pass).
# Vars merge as Ansible reads them for this file's shape: all.vars, then group vars (a child group
# over its parent), then the host's own entries over every group, a later entry winning among
# equals, so ansible_host may sit in another group. Nothing when the
# file or group is missing. Read once per shell (FLEET_HOSTS_JSON): a caller that loops over it, or
# runs fleet_host_run in one, calls fleet_hosts >/dev/null first, so the subshells inherit it.
# FLEET_ROSTER_ERR, set with it, is why the roster cannot be read (no checkout or file, no group, no
# host in it, a parse that failed, a last fetch too old), and empty when it can.
fleet_hosts() {
  if [ -z "${FLEET_HOSTS_JSON+x}" ]; then
    local inv
    FLEET_HOSTS_JSON='' FLEET_ROSTER_ERR=''
    if ! inv=$(fleet_inventory_text); then
      FLEET_ROSTER_ERR="$(fleet_inventory || echo "home-config's checkout") could not be read"
    # A file that never names the group has no workers; that case skips python.
    elif ! grep -qs "^[[:space:]]*$FLEET_HOSTS_GROUP:" <<<"$inv"; then
      FLEET_ROSTER_ERR="the inventory has no $FLEET_HOSTS_GROUP group"
    elif ! FLEET_HOSTS_JSON=$(_fh_parse "$inv"); then
      FLEET_HOSTS_JSON='' FLEET_ROSTER_ERR="the inventory did not parse"
    elif [ -z "$FLEET_HOSTS_JSON" ]; then
      FLEET_ROSTER_ERR="the $FLEET_HOSTS_GROUP group lists no host"
    else
      FLEET_ROSTER_ERR=$(_fh_untrusted)
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
        "state_host": v.get("fleet_state_host", ""),
        "power": str(v.get("fleet_power", "")),
    }))
PY
}

# fleet_state_addr -> the roster's fleet_state_host as written (the name ssh dials), empty when no
# worker names one. It is the one reader of which machine is the fleet home, so a machine back from
# an outage reads that it no longer is.
fleet_state_addr() { fleet_hosts | jq -r '.state_host // empty' 2>/dev/null | grep -m1 .; }

# fleet_is_home -> rc 0 when this machine (FLEET_HOST) is the fleet home, or a roster that reads
# names no fleet_state_host (one machine). Rc 1 when it names another machine. Rc 2 when the roster
# cannot be read (FLEET_ROSTER_ERR says why): a machine without home-config's checkout, or back from
# being off with a fetch that fails, cannot tell it is not the home, so it stands down as one that is not.
fleet_is_home() {
  fleet_hosts >/dev/null
  [ -n "$FLEET_HOSTS_JSON" ] && [ -z "${FLEET_ROSTER_ERR:-}" ] || {
    FLEET_ROSTER_ERR=${FLEET_ROSTER_ERR:-the roster lists no host}
    return 2
  }
  local a; a=$(fleet_state_addr); [ -z "$a" ] || fleet_addr_is_me "$a"
}

# fleet_addr_is_me <addr> -> rc 0 when the address names this machine: its short name is FLEET_HOST
# in any case, or one of its A records is a non-loopback IPv4 address of this machine (an IP address
# resolves to itself). A user@ in front is ssh's and dropped. The inventory may name a machine by its
# DHCP name (pc-home-cachy-main.lan), which is not its hostname (cachyos-x8664-main). The lookup
# needs the LAN's DNS: while that is down the home cannot tell it is home.
: "${FLEET_RESOLVE_SECS:=2}"   # seconds the lookup may take, so a hung resolver never blocks a call
fleet_addr_is_me() {
  local a=${1##*@} short ips
  [ -n "$a" ] || return 1
  short=${a%%.*}
  [ "${short,,}" != "${FLEET_HOST,,}" ] || return 0
  ips=$(timeout "$FLEET_RESOLVE_SECS" getent ahostsv4 "$a" 2>/dev/null | awk '$1 !~ /^127\./ { print $1 }' | sort -u)
  [ -n "$ips" ] && ip -o -4 addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }' | grep -qxF -f <(printf '%s\n' "$ips")
}

# fleet_host <name> -> that host's roster line; rc 1 when the roster does not list it.
fleet_host() { fleet_hosts | jq -c --arg n "$1" 'select(.name == $n)' 2>/dev/null | grep -m1 .; }

# fleet_host_run <name> <command> [args...] -- run one command on the worker over ssh, each
# argument quoted, with ~/.local/bin first on PATH (a non-interactive ssh shell reads no rc file).
# stdin goes through only with FLEET_SSH_STDIN=1: a forwarded command in a `while read` loop must
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

# _fh_ssh <dest> [ssh options...] -- <command> [args...] -- the one ssh call both paths share.
_fh_ssh() {
  local dest="$1" opts=() n=-n
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
  shift
  [ "${FLEET_SSH_STDIN:-0}" != 1 ] || n=''
  # -T: a forwarded call never wants a tty; a `RequestTTY yes` in ssh_config otherwise puts a
  # "Pseudo-terminal will not be allocated" line into every call's output.
  # ServerAlive ends a link that went half-open mid-command (a laptop asleep) in about two timeouts.
  # shellcheck disable=SC2016 # $HOME and $PATH are the remote shell's
  ssh $n -T -o BatchMode=yes -o ConnectTimeout="$FLEET_SSH_TIMEOUT" -o ServerAliveInterval="$FLEET_SSH_TIMEOUT" -o ServerAliveCountMax=2 "${opts[@]}" "$dest" \
    'PATH="$HOME/.local/bin:$PATH" exec env' "$(printf '%q ' "$@")"
}

# Environment a forwarded command keeps: what names the item and the session it runs for. A pane
# id or tmux socket means nothing on the state host, so TMUX and TMUX_PANE are never sent.
FLEET_FORWARD_ENV="AGENT_QUEUE_ITEM CLAUDE_CODE_SESSION_ID CLAUDE_CODE_SESSION_ATTENDED"

# state_forward <tool> <verbs that read stdin> "$@" -- run <tool> "$@" on the state host and exit
# with its code: AGENT_STATE_HOST when set, else the roster's fleet home when this machine is not
# it. Otherwise return, and the tool runs here. AGENT_STATE_LOCAL=1 means this process writes the
# store here: the remote run has it, so it never forwards again even from a home whose roster is
# stale, and so do the home's gated units and its dispatch pass, which skip the roster read on each
# of their many calls. A verb in the list keeps stdin (`agent-queue add` with no task reads it);
# every other verb runs with none.
state_forward() {
  [ -z "${AGENT_STATE_LOCAL:-}" ] || return 0
  local to=${AGENT_STATE_HOST:-}
  # One roster read: the same test as fleet_is_home, on the address it already holds.
  [ -n "$to" ] || { to=$(fleet_state_addr); if fleet_addr_is_me "$to"; then to=; fi; }
  [ -n "$to" ] || return 0
  local tool="$1" stdin_verbs=" $2 " env=(-u AGENT_STATE_HOST AGENT_STATE_LOCAL=1) v rc
  shift 2
  for v in $FLEET_FORWARD_ENV; do [ -z "${!v:-}" ] || env+=("$v=${!v}"); done
  local FLEET_SSH_STDIN=0; [[ "$stdin_verbs" != *" ${1:-} "* ]] || FLEET_SSH_STDIN=1
  _fh_ssh "$to" -- "${env[@]}" "$tool" "$@"; rc=$?
  [ "$rc" -ne 255 ] || echo "$tool: the state host $to did not answer over ssh; nothing was written" >&2
  exit "$rc"
}
