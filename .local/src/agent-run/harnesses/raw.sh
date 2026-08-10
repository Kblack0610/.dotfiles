# shellcheck shell=bash
# raw -- no agent harness at all: run a plain command against a route's model.
#
# The other harnesses wrap an agent CLI that owns a tool loop. This one owns
# nothing. It exists because several consumers already speak OpenAI-compatible
# HTTP directly with their own curl -- comms-triage.sh, notes-version-summary,
# llm-call.sh -- and each carried its own hardcoded base URL, model and key entry.
# That is six unshared copies of "which model, whose gateway, whose key", and the
# reason two of them were found routing personal data at a paid client proxy.
#
# Here they read the same LLM_* names they already read, and the ROUTE decides
# what those names contain.
#
# WHY harness_supports IS UNCONDITIONALLY TRUE, which looks wrong and is not:
# contract rule 3 says a harness that cannot ENFORCE a role's denials must refuse
# rather than degrade. `raw` grants no tools whatsoever -- no Write, no Bash, no
# Task, no MCP, not even a tool loop -- so every denial any role could express is
# already satisfied, vacuously but completely. It is the MOST enforcing harness
# here, not the least. The one thing it cannot do is grant a capability, which is
# never what a denial asks for.
harness_supports() { return 0; }

harness_exec() {
  # route_apply has already exported LLM_BASE_URL / LLM_MODEL / LLM_API_KEY from
  # the resolved route. Two shapes, because the two existing consumer patterns
  # genuinely differ:
  #
  #   --print-env   emit shell-quoted exports for `eval`, which is what
  #                 comms-run.sh:36-43 does to seed both halves of its pipeline
  #   -- <cmd>      exec the command with the route's env already in place
  #
  # A consumer that wants neither can still just read the variables.
  if [ "${1:-}" = --print-env ]; then
    printf 'export LLM_BASE_URL=%q\n' "${LLM_BASE_URL:-}"
    printf 'export LLM_MODEL=%q\n'    "${LLM_MODEL:-}"
    # Emitted even when empty, deliberately: an unauthenticated origin is the
    # NORMAL case for the personal-safe route, and a consumer that inherited a
    # stale key from its own environment must have it cleared rather than kept.
    printf 'export LLM_API_KEY=%q\n'  "${LLM_API_KEY:-}"
    return 0
  fi

  if [ -n "${AGENTCTL_EXPLAIN:-}" ]; then
    printf 'harness:     raw (no tools; the route decides the endpoint)\n'
    printf 'env set:     LLM_BASE_URL=%s LLM_MODEL=%s LLM_API_KEY=%s\n' \
      "${LLM_BASE_URL:-<unset>}" "${LLM_MODEL:-<unset>}" \
      "${LLM_API_KEY:+<redacted>}${LLM_API_KEY:-<unset>}"
    return 0
  fi

  [ "$#" -gt 0 ] || {
    printf 'agentctl-run: raw: nothing to run. Pass a command, or --print-env.\n' >&2
    exit 64
  }
  exec "$@"
}
