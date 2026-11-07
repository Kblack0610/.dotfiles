# shellcheck shell=bash
# mem0.sh - the one mem0 client config and the one key reader. Sourced by .ai-rc, agent-propose,
# agentctl-dream, agentctl-nightly-sync; the remember commands and the mem0-ops skill point at it.
#
# The endpoint, user and secret path stay out of this public repo. They live in
# ~/.config/agentctl/mem0.env (stowed from the private overlay):
#   MEM0_BASE_URL=https://mem0.your.lan
#   MEM0_USER_ID=you
#   MEM0_SECRET=$HOME/path/to/client-credentials.secret.yaml   the sops file holding MEM0_API_KEY
#
# The key is never stored in the env file: mem0_key decrypts it at the moment of use.

# mem0_load [env file]: source the env file and export the three names. Fails with the reason.
mem0_load() {
  local f="${1:-${MEM0_ENV:-$HOME/.config/agentctl/mem0.env}}"
  [ -r "$f" ] || { echo "no mem0 config at $f" >&2; return 1; }
  # shellcheck source=/dev/null
  . "$f"
  [ -n "${MEM0_BASE_URL:-}" ] && [ -n "${MEM0_USER_ID:-}" ] && [ -n "${MEM0_SECRET:-}" ] ||
    { echo "$f needs MEM0_BASE_URL, MEM0_USER_ID and MEM0_SECRET" >&2; return 1; }
  export MEM0_BASE_URL MEM0_USER_ID MEM0_SECRET
}

# mem0_key: print the m0sk_ client key from the sops file MEM0_SECRET names (run mem0_load first). sops stays quiet: a missing age key and
# a wrong path both read as "no key", and the message names the file.
# Only a key that looks like one is printed, so a partial read cannot pass as a credential and
# bring back a silent 401.
mem0_key() {
  local key
  [ -n "${MEM0_SECRET:-}" ] || { echo "no mem0 key: MEM0_SECRET is unset (run mem0_load)" >&2; return 1; }
  key="$(sops -d "$MEM0_SECRET" 2>/dev/null | awk '/MEM0_API_KEY:/ {print $2}' | tr -d '"')"
  case "$key" in
    m0sk_*) printf '%s\n' "$key" ;;
    *) echo "no mem0 key could be read from $MEM0_SECRET" >&2; return 1 ;;
  esac
}
