#!/usr/bin/env bash
# common.sh — shared helpers for the `ticket` CLI and its backends.
# Sourced by the entrypoint; backends rely on these functions.

# --- diagnostics --------------------------------------------------------------
die()  { echo "ticket: $*" >&2; exit 1; }
warn() { echo "ticket: $*" >&2; }

# DRY_RUN is exported by the entrypoint (1 when --dry-run was passed).

# --- config access ------------------------------------------------------------
# TICKET_CFG holds the resolved tracker config object (raw JSON) for this repo.
# cfg <jq-filter> [default]  — read a value out of it.
cfg() {
  local filter="$1" default="${2:-}"
  local v
  v=$(printf '%s' "${TICKET_CFG:-{\}}" | jq -r "$filter // empty" 2>/dev/null)
  if [[ -n "$v" ]]; then printf '%s' "$v"; else printf '%s' "$default"; fi
}

# Resolve the auth token from the env var named in the config's `tokenEnv`.
# Falls back to a backend-supplied list of common env names.
resolve_token() {
  local env_name
  env_name=$(cfg '.tokenEnv')
  if [[ -n "$env_name" && -n "${!env_name:-}" ]]; then
    printf '%s' "${!env_name}"
    return 0
  fi
  # backend may pass extra candidate env var names as args
  local cand
  for cand in "$@"; do
    if [[ -n "${!cand:-}" ]]; then printf '%s' "${!cand}"; return 0; fi
  done
  return 1
}

# --- HTTP ---------------------------------------------------------------------
# Redact secrets from a header list for safe printing: masks the credential
# portion of any Authorization header (Bearer/Basic token, or a bare token).
_redact_hdrs() {
  local out="" a
  for a in "$@"; do
    case "$a" in
      Authorization:*) a=$(printf '%s' "$a" | sed -E 's/(Authorization:[[:space:]]*(Bearer|Basic|Token)?[[:space:]]*).+/\1***REDACTED***/I') ;;
    esac
    out+="${out:+ }$a"
  done
  printf '%s' "$out"
}

# http METHOD URL [body] [extra curl args...]
# Honors --dry-run: prints the intended call to stderr (secrets redacted),
# echoes a stub body, and makes no network request. On real runs, returns the
# response body.
http() {
  local method="$1" url="$2" body="${3:-}"; shift 3 || shift $#
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    {
      echo "[dry-run] $method $url"
      [[ -n "$body" ]] && echo "[dry-run]   body: $body"
      [[ $# -gt 0 ]]   && echo "[dry-run]   hdrs: $(_redact_hdrs "$@")"
    } >&2
    # Stub response so callers can keep parsing (synthetic id 999999).
    echo '{"id":999999,"key":"DRY-999","stub":true}'
    return 0
  fi
  local args=(-fsSL -X "$method" "$@")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}" "$url"
}
