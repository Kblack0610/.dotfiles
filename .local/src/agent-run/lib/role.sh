# shellcheck shell=bash
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
  # Optional: extra tool denials beyond what the yes/no keys imply. Defaults to
  # empty rather than the __unset__ sentinel because, unlike the capability keys,
  # "no extras" is a sane and common answer that need not be restated in every
  # role file.
  ROLE_DENY_EXTRA=""
  # Optional: pin the model this role runs on, and the model FAMILY it must never
  # share with the work's author. Empty means "no opinion" — the overwhelmingly
  # common case — so these are plain empty defaults, not __unset__ sentinels.
  ROLE_MODEL=""
  ROLE_FAMILY_EXCLUDE=""

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

# ── model-family independence (contract rule 4) ──────────────────────────────
#
# A reviewer that shares the author's model family is not an independent review;
# it is the same weights marking their own homework in a different voice. Ours
# have been exactly that: no kb-* agent carried a `model:` key, so kb-developer,
# kb-reviewer and kb-qa all inherited delivery-loop's single claude-sonnet-5 and
# the "adversarial" pass differed only by persona and tool grant.
#
# Herdforge's TARGET-WORKFLOW.md states the rule and, crucially, the failure
# mode: "if independence cannot be proven, review waits; the router does not
# degrade to self-review... Fallback can lose the different-family guarantee
# instead of failing closed." We reached the same conclusion from the other end
# on 2026-08-05 — a LiteLLM fallback edge fires INSIDE the router, after the key
# check, so a scoped virtual key cannot stop a spill onto another family's model.
# That is why a pinned review model must be a route with NO fallback edge.

# role_family_of <model-id-or-family> - the model family, or `unknown`.
#
# Matched on the id because that is what every layer here actually carries.
# Anything unrecognised is `unknown` and must be treated as a refusal, never as
# "probably fine" — an unknown family cannot be proven different from anything.
role_family_of() {
  local m
  m="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$m" in
    anthropic|openai|google|xai|meta|mistral|deepseek|moonshot|qwen|zhipu) printf '%s' "$m" ;;
    *claude*|*anthropic*|opus*|sonnet*|haiku*|fable*)      printf 'anthropic' ;;
    *gpt-*|gpt*|o1|o1-*|o3|o3-*|o4|o4-*|*codex*|*luna*)    printf 'openai' ;;
    *gemini*|*gemma*)                                      printf 'google' ;;
    *grok*)                                                printf 'xai' ;;
    *llama*)                                               printf 'meta' ;;
    *mistral*|*mixtral*|*magistral*|*devstral*)            printf 'mistral' ;;
    *deepseek*)                                            printf 'deepseek' ;;
    *kimi*|*moonshot*)                                     printf 'moonshot' ;;
    *qwen*|*qwq*)                                          printf 'qwen' ;;
    *glm*)                                                 printf 'zhipu' ;;
    *)                                                     printf 'unknown' ;;
  esac
}

# role_run_model - the model this invocation will actually run on.
# Precedence: the role's pin > an explicit override > the harness transport's
# model. Empty when nothing names one.
role_run_model() {
  printf '%s' "${ROLE_MODEL:-${AGENTCTL_MODEL:-${ANTHROPIC_MODEL:-}}}"
}

# role_family_check - enforce ROLE_FAMILY_EXCLUDE. Refuses on ANY doubt.
#
# ROLE_FAMILY_EXCLUDE is either a comma-separated list of family slugs, or the
# token `author`, meaning "whatever family wrote the work" — read from
# $AGENT_AUTHOR_FAMILY, which may be a family slug or a model id.
#
# Every uncertain path here ends in role_die, not in a warning. A review whose
# independence we merely hope for is worth less than no review, because it is
# recorded as one.
role_family_check() {
  [ -n "$ROLE_FAMILY_EXCLUDE" ] || return 0

  local excl="$ROLE_FAMILY_EXCLUDE" mine model f
  if [ "$excl" = "author" ]; then
    [ -n "${AGENT_AUTHOR_FAMILY:-}" ] || role_die \
"role '$ROLE_NAME' excludes the AUTHOR's model family, but \$AGENT_AUTHOR_FAMILY
is unset, so there is nothing to compare against. Refusing to run: an
independent review that cannot prove its independence is not one.
Set AGENT_AUTHOR_FAMILY to the family (or model id) that produced the work."
    excl="$(role_family_of "$AGENT_AUTHOR_FAMILY")"
    [ "$excl" != "unknown" ] || role_die \
"role '$ROLE_NAME': cannot classify the author's model '\$AGENT_AUTHOR_FAMILY=$AGENT_AUTHOR_FAMILY'.
Refusing rather than assuming it differs from the reviewer's - see
docs/contract.md, rule 4."
  fi

  model="$(role_run_model)"
  [ -n "$model" ] || role_die \
"role '$ROLE_NAME' declares ROLE_FAMILY_EXCLUDE but no model is pinned, so the
family it will run on is unknowable before launch. Set ROLE_MODEL in the role
file (a route with NO fallback edge - a router fallback silently re-crosses the
family line), or pass AGENTCTL_MODEL."
  mine="$(role_family_of "$model")"
  [ "$mine" != "unknown" ] || role_die \
"role '$ROLE_NAME': cannot classify its own model '$model', so independence from
'$excl' is unproven. Refusing - see docs/contract.md, rule 4."

  local IFS=,
  for f in $excl; do
    [ -n "$f" ] || continue
    if [ "$mine" = "$(role_family_of "$f")" ]; then
      role_die \
"role '$ROLE_NAME' must not share the author's model family, but it would run on
'$model' (family: $mine) and the excluded set is '$ROLE_FAMILY_EXCLUDE'.
Refusing. This is NOT a case to fall back on - a same-family review is
self-review wearing a different persona, and it gets recorded as independent."
    fi
  done
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
  # Extras exist for capabilities the yes/no keys cannot express, e.g. "may
  # create new files but must never modify an existing one" (agentctl-skill-refine
  # is propose-only and documented as such, but nothing enforced it).
  [ -n "$ROLE_DENY_EXTRA" ] && d="$d,$ROLE_DENY_EXTRA"
  echo "${d#,}"
}
