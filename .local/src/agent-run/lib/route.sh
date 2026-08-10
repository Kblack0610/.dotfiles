# shellcheck shell=bash
# This file is SOURCED, never executed (SC2148).
#
# route.sh -- WHOSE wire, WHOSE money, WHOSE data.
#
# The orthogonal half of role.sh. A ROLE says what an agent may DO; a ROUTE says
# where its tokens GO. Two registries composed at invocation, never a matrix: 4
# roles x 6 routes is 10 files, not 24, and a <role>-<route> file is a bug.
#
# WHY IT HAD TO EXIST BEFORE THE SCRUB COULD LAND. scrub.sh removes every
# transport variable unconditionally, which is correct -- an inherited
# ANTHROPIC_BASE_URL is an accident that looks like a configuration. But
# delivery-loop legitimately NEEDS the gateway, and it was expressing that by
# exporting ANTHROPIC_BASE_URL and letting agentctl-run inherit it. To the
# receiving process, "declared in my .conf" and "left over in this shell" are the
# same bytes. That indistinguishability IS the bug; a route file is what makes a
# declaration legible as one. So the scrub is only safe once there is a way to
# say the thing out loud.
#
# Search path, first hit wins:
#   $AGENTCTL_ROUTES/<n>.route            test override, single dir
#   ~/.config/agentctl/routes/<n>.route   PRIVATE overlay: site-specific, names hosts
#   <agent-run>/routes/<n>.route          PUBLIC: ships with the code
#
# Note the public tier lives in the SOURCE tree, not ~/.config/agentctl -- that
# whole directory is gitignored in the public repo, so the plan's "public .route
# files" could not have been executed as written. A machine with no private
# overlay therefore resolves `subscription` and REFUSES `client` by name, rather
# than silently doing something.

route_die() { printf 'agentctl-run: %s\n' "$*" >&2; exit 78; }

route_dirs() {
  [ -n "${AGENTCTL_ROUTES:-}" ] && { printf '%s\n' "$AGENTCTL_ROUTES"; return 0; }
  printf '%s\n' "$HOME/.config/agentctl/routes"
  printf '%s\n' "${SELF_DIR:-}/routes"
}

route_list() {
  local d
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    ls -1 "$d"/*.route 2>/dev/null | sed 's|.*/||; s|\.route$||'
  done < <(route_dirs) | sort -u
}

route_file() {
  local name="$1" d
  while IFS= read -r d; do
    [ -r "$d/$name.route" ] && { printf '%s' "$d/$name.route"; return 0; }
  done < <(route_dirs)
  return 1
}

# route_load <name> -- source and validate. Fails closed on every uncertainty.
#
# Required keys start at the __unset__ sentinel so that "the author forgot
# ROUTE_PERSONAL_SAFE" and "ROUTE_PERSONAL_SAFE=no" can never be the same
# observable. role.sh uses the same trick for the same reason.
route_load() {
  local name="$1" f
  f="$(route_file "$name")" || route_die "unknown route '$name'.
Available: $(route_list | tr '\n' ' ')"

  ROUTE_DESC=__unset__ ROUTE_TRANSPORT=__unset__ ROUTE_PAYER=__unset__
  ROUTE_PERSONAL_SAFE=__unset__ ROUTE_WORK_SAFE=__unset__ ROUTE_FALLBACK_SAFE=__unset__
  ROUTE_BASE_URL="" ROUTE_MODEL_CLAUDE="" ROUTE_MODEL_RAW="" ROUTE_MODEL_OPENCODE=""
  ROUTE_KEY_SOURCE="none" ROUTE_HARNESSES="" ROUTE_NOTE=""
  ROUTE_VERIFY_MODEL="" ROUTE_VERIFY_API_BASE=""

  # shellcheck source=/dev/null
  . "$f"
  ROUTE_NAME="$name" ROUTE_FILE="$f"

  local k
  for k in ROUTE_DESC ROUTE_TRANSPORT ROUTE_PAYER ROUTE_PERSONAL_SAFE ROUTE_WORK_SAFE ROUTE_FALLBACK_SAFE; do
    [ "${!k}" = __unset__ ] && route_die "route '$name' ($f) does not set $k.
Every key is explicit here on purpose: a forgotten one must not read as a 'no'."
  done

  case "$ROUTE_TRANSPORT" in
    anthropic-native|anthropic-gateway|openai-compatible) ;;
    *) route_die "route '$name': ROUTE_TRANSPORT='$ROUTE_TRANSPORT' is not one of anthropic-native|anthropic-gateway|openai-compatible" ;;
  esac

  # I1. A gateway route claiming personal-safety while sitting behind a failover
  # edge is the llm-judge hole expressed as a config error. Fallbacks fire INSIDE
  # the router, AFTER the key check, so a scoped key cannot stop the spill.
  if [ "$ROUTE_PERSONAL_SAFE" = yes ] && [ "$ROUTE_TRANSPORT" != anthropic-native ] \
     && [ "$ROUTE_FALLBACK_SAFE" != yes ]; then
    route_die "route '$name' claims PERSONAL_SAFE=yes on a non-native transport while
FALLBACK_SAFE=no. A failover edge fires inside the router, after the key check,
so that combination cannot be honoured. Refusing to load it."
  fi

  # I2. Claude Code canonicalizes model ids and silently DROPS one it cannot
  # parse, so a parenthesised gateway id in this field is a trap that presents as
  # "the pin did nothing". Make it untypeable instead.
  if [ -n "$ROUTE_MODEL_CLAUDE" ] && ! printf '%s' "$ROUTE_MODEL_CLAUDE" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
    route_die "route '$name': ROUTE_MODEL_CLAUDE='$ROUTE_MODEL_CLAUDE' is not a bare
canonical id. Claude Code drops what it cannot parse, so this pin would silently
do nothing. Use ROUTE_MODEL_RAW for ids with spaces or parentheses."
  fi

  # I3. An unfalsifiable safety claim is not a safety claim: if a route asserts
  # FALLBACK_SAFE it must name what `make verify-routes` should probe.
  if [ "$ROUTE_FALLBACK_SAFE" = yes ] && [ "$ROUTE_TRANSPORT" != anthropic-native ] \
     && { [ -z "$ROUTE_VERIFY_MODEL" ] || [ -z "$ROUTE_VERIFY_API_BASE" ]; }; then
    route_die "route '$name' claims FALLBACK_SAFE=yes but names no ROUTE_VERIFY_MODEL /
ROUTE_VERIFY_API_BASE, so nothing can ever check it."
  fi

  # I4. Catches a copy-paste of the client route with the safety flag left on.
  if [ "$ROUTE_PERSONAL_SAFE" = yes ] && [ "$ROUTE_PAYER" = client ]; then
    route_die "route '$name': PERSONAL_SAFE=yes with PAYER=client is a contradiction."
  fi

  # I5. A native route with a base URL is a gateway route lying about itself.
  if [ "$ROUTE_TRANSPORT" = anthropic-native ] && [ -n "$ROUTE_BASE_URL" ]; then
    route_die "route '$name': anthropic-native must not set ROUTE_BASE_URL."
  fi
}

# route_resolve -- the name, in precedence order. DEFAULTING rather than failing
# on absence is what makes migration a provable no-op: a runner that names no
# route keeps the behaviour it had.
route_resolve() {
  printf '%s' "${AGENTCTL_ROUTE:-${ROUTE:-${ROLE_ROUTE:-subscription}}}"
}

# route_data_class -- what KIND of data this invocation handles.
# Defaults to `personal`, deliberately the strictest: that is true of dream,
# nightly-sync, comms, sessions and ask-resume, and it forces delivery-loop to
# declare `work` explicitly rather than inheriting a permissive default.
route_data_class() {
  printf '%s' "${AGENTCTL_DATA_CLASS:-${DATA_CLASS:-personal}}"
}

# route_check_pair -- the interlock. Runs BEFORE the harness file is sourced, so
# "the harness was never invoked" is structurally true rather than incidental.
route_check_pair() {
  local dc; dc="$(route_data_class)"
  case "$dc" in
    personal)
      [ "$ROUTE_PERSONAL_SAFE" = yes ] || route_die "REFUSED: DATA_CLASS=personal on route '$ROUTE_NAME'
(PERSONAL_SAFE=$ROUTE_PERSONAL_SAFE, payer=$ROUTE_PAYER). Personal data does not go there.
Set DATA_CLASS explicitly if this work is genuinely not personal." ;;
    work)
      [ "$ROUTE_WORK_SAFE" = yes ] || route_die "REFUSED: DATA_CLASS=work on route '$ROUTE_NAME'
(WORK_SAFE=$ROUTE_WORK_SAFE)." ;;
    public) : ;;
    *) route_die "REFUSED: unknown DATA_CLASS='$dc'. An unrecognised label is not permissive." ;;
  esac
  if [ -n "$ROUTE_HARNESSES" ] && [ -n "${harness:-}" ]; then
    case " $ROUTE_HARNESSES " in
      *" $harness "*) : ;;
      *) route_die "REFUSED: route '$ROUTE_NAME' does not support harness '$harness'
(ROUTE_HARNESSES='$ROUTE_HARNESSES'). This is a declared incompatibility, not a guess." ;;
    esac
  fi
}

# route_key -- resolve the credential, or empty for an unauthenticated origin.
route_key() {
  local src
  for src in ${ROUTE_KEY_SOURCE//,/ }; do
    case "$src" in
      none)  printf ''; return 0 ;;
      oauth) printf ''; return 0 ;;   # the CLI's own stored credentials
      file:*)
        local f="${src#file:}"; f="${f/#\~/$HOME}"
        [ -r "$f" ] || continue
        # A key file the world can read is not a key. Refuse rather than warn:
        # the documented rbw fallback for delivery-loop never existed, so a soft
        # failure here degrades to "spend the personal subscription instead".
        local mode; mode="$(stat -c '%a' "$f" 2>/dev/null)"
        case "$mode" in
          *00|*0) : ;;
          *) route_die "route '$ROUTE_NAME': key file $f is mode $mode; run: chmod 600 $f" ;;
        esac
        tr -d '\r\n' < "$f"; return 0 ;;
      rbw:*)
        command -v rbw >/dev/null 2>&1 || continue
        local v; v="$(timeout 5 rbw get "${src#rbw:}" 2>/dev/null || true)"
        [ -n "$v" ] && { printf '%s' "$v"; return 0; } ;;
      env:*) printf '%s' "${!src#env:}" ; return 0 ;;
    esac
  done
  printf ''
}

# route_apply -- export the transport. Runs AFTER the scrub, which is the point:
# the environment the harness sees is built from a declaration, not inherited.
# NOTE ON STYLE: every branch below uses `if`, never `[ -n "$x" ] && export ...`.
# Under `set -e` a trailing && chain that evaluates FALSE makes the function
# return non-zero and kills the caller -- which is exactly what happened the
# first time this ran, and it presented as the whole command producing no output
# and no error at all. An empty model pin is a normal state, not a failure.
route_apply() {
  local key; key="$(route_key)"
  case "$ROUTE_TRANSPORT" in
    anthropic-native)
      if [ -n "$ROUTE_MODEL_CLAUDE" ]; then export ANTHROPIC_MODEL="$ROUTE_MODEL_CLAUDE"; fi
      ;;
    anthropic-gateway)
      export ANTHROPIC_BASE_URL="$ROUTE_BASE_URL"
      if [ -n "$ROUTE_MODEL_CLAUDE" ]; then export ANTHROPIC_MODEL="$ROUTE_MODEL_CLAUDE"; fi
      # Bearer, not API key: the gateway authenticates with ANTHROPIC_AUTH_TOKEN,
      # and setting both makes Claude Code prefer the wrong one.
      if [ -n "$key" ]; then export ANTHROPIC_AUTH_TOKEN="$key"; fi
      unset ANTHROPIC_API_KEY
      ;;
    openai-compatible)
      export LLM_BASE_URL="$ROUTE_BASE_URL"
      if [ -n "$ROUTE_MODEL_RAW" ]; then export LLM_MODEL="$ROUTE_MODEL_RAW"; fi
      if [ -n "$key" ]; then export LLM_API_KEY="$key"; fi
      ;;
  esac
  return 0
}

# route_provenance -- WHERE the route name came from. Printed rather than just
# the value, because "which route" and "who chose it" are different questions and
# the second is the one you ask when a runner is on the wrong wire.
route_provenance() {
  if   [ -n "${ROUTE_FROM:-}" ];   then printf '%s' "$ROUTE_FROM"
  elif [ -n "${ROLE_ROUTE:-}" ];   then printf -- 'role default'
  else                                  printf -- 'built-in default'
  fi
}

route_explain() {
  printf 'route:       %s  (from: %s)\n' "$ROUTE_NAME" "$(route_provenance)"
  printf 'route file:  %s\n' "$ROUTE_FILE"
  printf 'transport:   %s%s\n' "$ROUTE_TRANSPORT" "${ROUTE_BASE_URL:+ -> $ROUTE_BASE_URL}"
  printf 'payer:       %s\n' "$ROUTE_PAYER"
  printf 'safety:      personal=%s work=%s fallback=%s\n' \
    "$ROUTE_PERSONAL_SAFE" "$ROUTE_WORK_SAFE" "$ROUTE_FALLBACK_SAFE"
  printf 'data class:  %s  -> ALLOW\n' "$(route_data_class)"
  # A fingerprint proves WHICH key without revealing it.
  local k; k="$(route_key)"
  if [ -n "$k" ]; then
    printf 'key:         %s (present, sha256:%s)\n' "$ROUTE_KEY_SOURCE" \
      "$(printf '%s' "$k" | sha256sum | cut -c1-12)"
  else
    printf 'key:         %s (none sent)\n' "$ROUTE_KEY_SOURCE"
  fi
  if [ -n "$ROUTE_NOTE" ]; then printf 'note:        %s\n' "$ROUTE_NOTE"; fi
  return 0
}
