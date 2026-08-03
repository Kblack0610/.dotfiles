# role.sh - resolve a role name into the capability contract.
#
# Sourced by agentctl-run. Mirrors ticket/lib/config.sh: this file decides WHAT
# the contract is; harnesses/<name>.sh decides how to express it.
#
# Contract keys and why each must be explicit: docs/contract.md.

ROLES_DIR="${AGENTCTL_ROLES:-$HOME/.config/agentctl/roles}"
MCP_DIR="${AGENTCTL_MCP:-$HOME/.config/agentctl/mcp}"

EX_CONFIG=78

role_die() { echo "agentctl-run: $*" >&2; exit $EX_CONFIG; }

role_list() { ls -1 "$ROLES_DIR" 2>/dev/null | sed 's/\.role$//' | tr '\n' ' '; }

# role_load <name> - source the role file and validate every contract key.
#
# The sentinel-default pattern below is load-bearing. If these were empty-string
# defaults, "ROLE_WRITE=no" and "the author forgot ROLE_WRITE" would be
# indistinguishable, and the forgetful case would silently grant less (or, worse,
# a future refactor could make it grant more). An unset key is a bug; say so.
role_load() {
  local name="$1"
  [ -n "$name" ] || role_die "no role set. Pass --role <name> or set ROLE in the agent's .conf.
Available: $(role_list)"

  local f="$ROLES_DIR/$name.role"
  [ -r "$f" ] || role_die "unknown role '$name' (no $f).
Available: $(role_list)"

  ROLE_DESC=""
  ROLE_WRITE="__unset__"; ROLE_TASK="__unset__"; ROLE_BASH="__unset__"
  ROLE_MCP="__unset__";   ROLE_MCP_DENY="__unset__"; ROLE_APPROVE="__unset__"

  # shellcheck source=/dev/null
  . "$f"

  local k
  for k in ROLE_WRITE ROLE_TASK ROLE_BASH ROLE_MCP ROLE_MCP_DENY ROLE_APPROVE; do
    [ "$(eval "printf '%s' \"\$$k\"")" != "__unset__" ] \
      || role_die "role '$name' does not set $k.
Every capability key must be explicit - see docs/contract.md. Use the empty
string or 'no' deliberately, but write it down. Refusing to guess."
  done

  for k in ROLE_WRITE ROLE_TASK ROLE_BASH; do
    case "$(eval "printf '%s' \"\$$k\"")" in
      yes|no) ;;
      *) role_die "role '$name': $k must be exactly 'yes' or 'no'." ;;
    esac
  done

  # inherit means the harness cannot pin the server set (OAuth remotes cannot be
  # expressed as stdio entries). Denials then carry the entire weight, so an
  # empty ROLE_MCP_DENY there is almost certainly a mistake rather than a choice.
  if [ "$ROLE_MCP" = "inherit" ] && [ -z "$ROLE_MCP_DENY" ]; then
    role_die "role '$name' sets ROLE_MCP=inherit with an empty ROLE_MCP_DENY.
With inherit, nothing pins which servers spawn, so the denylist is the ONLY
enforcement. An empty one means every user-scope server is callable."
  fi

  ROLE_NAME="$name"
}

# role_mcp_file - absolute path to the MCP set, or empty for none/inherit.
role_mcp_file() {
  case "$ROLE_MCP" in
    inherit) echo "" ;;
    *)
      local f="$MCP_DIR/$ROLE_MCP.json"
      [ -r "$f" ] || role_die "role '$ROLE_NAME' wants MCP set '$ROLE_MCP' but $f is unreadable.
Failing closed rather than inheriting the full user-scope server list."
      echo "$f" ;;
  esac
}

# role_denied_tools - the harness-neutral list of what this role may NOT do.
# Harness adapters translate this; they do not reinterpret it.
role_denied_tools() {
  local d=""
  [ "$ROLE_WRITE" = "no" ] && d="$d,Write,Edit,NotebookEdit"
  # Task is denied alongside writes because a subagent is otherwise a trivial way
  # to launder a write past the parent's denylist.
  [ "$ROLE_TASK"  = "no" ] && d="$d,Task"
  [ "$ROLE_BASH"  = "no" ] && d="$d,Bash"
  [ -n "$ROLE_MCP_DENY" ] && d="$d,$ROLE_MCP_DENY"
  echo "${d#,}"
}
