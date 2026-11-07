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
# A session on a worker has AGENT_STATE_HOST set on its launch line. agent-queue and agent-ask
# call state_forward first, which runs the same command on that host over ssh, so the queue, the
# asks and their one writer stay on the workstation (agentctl QUEUE.md).
# Runbook: home-config docs/runbooks/fleet-worker.md.

_fh_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
: "${FLEET_HOSTS_GROUP:=fleet_workers}"
: "${FLEET_SSH_TIMEOUT:=5}"   # seconds an ssh to a worker or the state host may take to connect

# fleet_inventory -> the inventory file: FLEET_INVENTORY, else home-config's from the project map.
fleet_inventory() {
  if [ -n "${FLEET_INVENTORY:-}" ]; then printf '%s' "$FLEET_INVENTORY"; return; fi
  declare -F project_repo_path >/dev/null ||
    . "${PROJECT_NAME_LIB:-$_fh_lib/../../.config/shared-hooks/project-name.sh}" 2>/dev/null || return 1
  local hc; hc=$(project_repo_path home-config 2>/dev/null) && [ -n "$hc" ] || return 1
  printf '%s/ansible/inventory.yml' "$hc"
}

# fleet_hosts -> one JSON object a line per host of the group, in file order:
#   {name, dest: user@host, port, max_live, place, repos: [dir], state_host}
# Vars merge as Ansible reads them for this file's shape: all.vars, then each group's vars, then
# each host entry, later ones winning, so ansible_host may sit in another group. Nothing when the
# file or group is missing. Read once per process (FLEET_HOSTS_JSON).
fleet_hosts() {
  if [ -z "${FLEET_HOSTS_JSON+x}" ]; then
    local inv; inv=$(fleet_inventory) && [ -f "$inv" ] || inv=''
    FLEET_HOSTS_JSON=''
    [ -z "$inv" ] || FLEET_HOSTS_JSON=$(python3 -I - "$inv" "$FLEET_HOSTS_GROUP" <<'PY' 2>/dev/null
import json, os, sys
import yaml

inv, group = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(inv)) or {}
root = doc.get("all") or {}
base = dict(root.get("vars") or {})
merged, members = {}, {}

def walk(name, node, chain):
    node = node or {}
    gvars = dict(node.get("vars") or {})
    path = chain + [(name, gvars)]
    for h, hv in (node.get("hosts") or {}).items():
        m = merged.setdefault(h, {})
        for _, gv in path:
            m.update(gv)
        m.update(hv or {})
        for g, _ in path:
            members.setdefault(g, [])
            if h not in members[g]:
                members[g].append(h)
    for c, cn in (node.get("children") or {}).items():
        walk(c, cn, path)

walk("all", root, [])
for h in members.get(group, []):
    v = dict(base)
    v.update(merged.get(h, {}))
    user = v.get("ansible_user")
    host = v.get("ansible_host", h)
    repos = [os.path.expanduser(str(r.get("dest") if isinstance(r, dict) else r)) for r in (v.get("fleet_repos") or [])]
    print(json.dumps({
        "name": h,
        "dest": f"{user}@{host}" if user else str(host),
        "port": int(v.get("ansible_port", 22)),
        "max_live": int(v.get("fleet_max_live", 1)),
        "place": bool(v.get("fleet_place", True)),
        "repos": repos,
        "state_host": v.get("fleet_state_host", ""),
    }))
PY
)
  fi
  [ -z "$FLEET_HOSTS_JSON" ] || printf '%s\n' "$FLEET_HOSTS_JSON"
}

# fleet_host <name> -> that host's roster line; rc 1 when the roster does not list it.
fleet_host() { fleet_hosts | jq -ce --arg n "$1" 'select(.name == $n)' 2>/dev/null | head -1 | grep .; }

# fleet_host_run <name> <command> [args...] -- run one command on the worker over ssh, each
# argument quoted, with ~/.local/bin first on PATH (a non-interactive ssh shell reads no rc file).
# stdin goes through only with FLEET_SSH_STDIN=1: a forwarded command in a `while read` loop must
# not eat the loop's input. The command's own exit code comes back; 255 is ssh's, an unreachable
# host or a refused key.
fleet_host_run() {
  local h dest port
  h=$(fleet_host "$1") || { echo "fleet-hosts: $1 is not in $FLEET_HOSTS_GROUP" >&2; return 255; }
  shift
  dest=$(jq -r .dest <<<"$h"); port=$(jq -r .port <<<"$h")
  _fh_ssh "$dest" -p "$port" -- "$@"
}

# _fh_ssh <dest> [ssh options...] -- <command> [args...] -- the one ssh call both paths share.
_fh_ssh() {
  local dest="$1" opts=() n=-n
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
  shift
  [ "${FLEET_SSH_STDIN:-0}" != 1 ] || n=''
  # shellcheck disable=SC2016 # $HOME and $PATH are the remote shell's
  ssh $n -o BatchMode=yes -o ConnectTimeout="$FLEET_SSH_TIMEOUT" "${opts[@]}" "$dest" \
    'PATH="$HOME/.local/bin:$PATH" exec env' "$(printf '%q ' "$@")"
}

# Environment a forwarded command keeps: what names the item and the session it runs for. A pane
# id or tmux socket means nothing on the state host, so TMUX and TMUX_PANE are never sent.
FLEET_FORWARD_ENV="AGENT_QUEUE_ITEM CLAUDE_CODE_SESSION_ID CLAUDE_CODE_SESSION_ATTENDED"

# state_forward <tool> <verbs that read stdin> "$@" -- when AGENT_STATE_HOST is set, run <tool>
# "$@" on that host and exit with its code; else return, and the tool runs here. The remote run
# has AGENT_STATE_HOST unset, so it never forwards again. A verb in the list keeps stdin
# (`agent-queue add` with no task reads it); every other verb runs with none.
state_forward() {
  [ -n "${AGENT_STATE_HOST:-}" ] || return 0
  local tool="$1" stdin_verbs=" $2 " env=(-u AGENT_STATE_HOST) v rc
  shift 2
  for v in $FLEET_FORWARD_ENV; do [ -z "${!v:-}" ] || env+=("$v=${!v}"); done
  local FLEET_SSH_STDIN=0; [[ "$stdin_verbs" != *" ${1:-} "* ]] || FLEET_SSH_STDIN=1
  _fh_ssh "$AGENT_STATE_HOST" -- "${env[@]}" "$tool" "$@"; rc=$?
  [ "$rc" -ne 255 ] || echo "$tool: the state host $AGENT_STATE_HOST did not answer over ssh; nothing was written" >&2
  exit "$rc"
}
