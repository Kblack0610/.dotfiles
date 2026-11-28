# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# store-remote.sh - how a tool reaches the agent store's two remotes: their URLs (store.env), the
# ssh each one takes, and a git call that cannot hang. store-sync (master) and fleet-lease (the
# lease branch) share it, so both reach origin and backup the same way.

# The agent store's conf and key, unless the sourcing script set its own first (store-sync
# --store notes sets CONF empty on purpose, so a set-but-empty value is kept too).
CONF="${CONF-${STORE_SYNC_CONF:-$HOME/.config/agentctl/store.env}}"
SSH_KEY="${SSH_KEY-${STORE_SYNC_SSH_KEY:-$HOME/.ssh/id_agent_sync}}"
CONNECT_TIMEOUT_S=10

# ssh for one remote: the store's deploy key, when this machine has one, only for origin; backup
# (GitHub, an https URL in store.env) answers with gh's token through git's credential helper. -T: a `RequestTTY yes` in ssh_config
# would otherwise print a pseudo-terminal warning on every call.
ssh_cmd() {
  local c="ssh -T -o BatchMode=yes -o ConnectTimeout=$CONNECT_TIMEOUT_S -o StrictHostKeyChecking=accept-new"
  [ "$1" != origin ] || [ ! -f "$SSH_KEY" ] || c="$c -i $(printf %q "$SSH_KEY") -o IdentitiesOnly=yes"
  printf '%s' "$c"
}

# net <remote> <git args...>: a git call that reaches that remote, bounded: ssh has its connect
# timeout, and an https remote gives up after 15 s below 1 byte/s.
net() {
  local r="$1"; shift
  GIT_TERMINAL_PROMPT=0 git -c core.sshCommand="$(ssh_cmd "$r")" \
    -c http.lowSpeedLimit=1 -c http.lowSpeedTime=15 "$@"
}

# load_conf: STORE_PRIMARY_URL and STORE_BACKUP_URL from store.env, empty when it names none.
load_conf() {
  # shellcheck disable=SC2034 # read by the script that sources this
  STORE_PRIMARY_URL="" STORE_BACKUP_URL=""
  # shellcheck disable=SC1090
  [ ! -r "$CONF" ] || . "$CONF"
}
