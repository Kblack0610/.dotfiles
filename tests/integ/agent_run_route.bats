#!/usr/bin/env bats
# The TRANSPORT half of the contract: whose wire, whose money, whose data.
#
# role.sh answers what an agent may DO. Nothing answered where its tokens GO --
# so of the raw call sites this replaced, one set transport, one defensively
# scrubbed it, and six silently INHERITED whatever was in the environment,
# including the two runners that read the personal notes vault.
#
# Two mechanisms, and they only work together:
#
#   scrub.sh   removes every transport variable, unconditionally
#   route.sh   puts back exactly what a route file DECLARES
#
# The scrub alone would have broken delivery-loop, which legitimately needs the
# gateway and was expressing that by exporting ANTHROPIC_BASE_URL for
# agentctl-run to inherit. To the receiving process a declaration and a leftover
# are the same bytes; that indistinguishability IS the bug, and a route file is
# what makes a declaration legible as one.
#
# Route fixtures are written INLINE. The real routes live in the private overlay,
# which CI cannot see, and reading the deployed ~/.config copy would assert this
# machine's provisioning rather than the contract -- the same reasoning
# agent_run_headless.bats spells out for roles.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  RUN="$REPO_ROOT/.local/src/agent-run/agentctl-run"
  export AGENTCTL_ROUTES="$SANDBOX/routes"
  mkdir -p "$AGENTCTL_ROUTES"

  mkdir -p "$HOME/.config/agentctl/roles" "$HOME/.config/agentctl/mcp"
  cat > "$HOME/.config/agentctl/roles/fixture.role" <<'ROLE'
ROLE_DESC="test fixture"
ROLE_WRITE=no
ROLE_TASK=no
ROLE_BASH=yes
ROLE_MCP=none
ROLE_MCP_DENY=""
ROLE_APPROVE="Read,Glob,Grep,Bash"
ROLE
  printf '{"mcpServers":{}}\n' > "$HOME/.config/agentctl/mcp/none.json"

  # A personal-safe native route, the shape `subscription` has.
  route safe 'anthropic-native' '' yes yes yes subscription
  # A route nothing personal may touch, the shape `client` has.
  route paid 'anthropic-gateway' 'https://gw.example' no yes no client
}

# route <name> <transport> <base> <personal> <work> <fallback> <payer> [extra...]
route() {
  cat > "$AGENTCTL_ROUTES/$1.route" <<EOF
ROUTE_DESC="fixture $1"
ROUTE_TRANSPORT="$2"
ROUTE_BASE_URL="$3"
ROUTE_PERSONAL_SAFE="$4"
ROUTE_WORK_SAFE="$5"
ROUTE_FALLBACK_SAFE="$6"
ROUTE_PAYER="$7"
ROUTE_KEY_SOURCE="none"
ROUTE_HARNESSES="claude"
${8:-}
EOF
}

# ---------------------------------------------------------------- the scrub

# THE test of the scrub. A hostile value must be visibly TAKEN AWAY, and must not
# reappear anywhere in what the harness is handed. Naming it in `env scrubbed:`
# is half the point -- a scrub nobody can see is indistinguishable from one that
# did not run.
@test "an inherited ANTHROPIC_BASE_URL is scrubbed, named, and not passed on" {
  ANTHROPIC_BASE_URL=https://evil.example \
    run "$RUN" --role fixture --route safe --data-class personal --explain
  assert_success
  assert_output --partial 'ANTHROPIC_BASE_URL'
  refute_output --partial 'evil.example'
}

@test "a clean environment reports (none), so the line is not a stuck string" {
  run "$RUN" --role fixture --route safe --data-class personal --explain
  assert_success
  assert_output --partial 'env scrubbed: (none)'
}

# The scrub runs BEFORE role_load, and that ordering is load-bearing rather than
# stylistic: role_run_model() falls back to ${ANTHROPIC_MODEL:-}, so scrubbing
# afterwards would let an AMBIENT model id satisfy the model-family independence
# check. An independence claim established by a leftover variable is exactly what
# contract rule 4 exists to refuse.
@test "an ambient ANTHROPIC_MODEL can no longer satisfy the family check" {
  ANTHROPIC_MODEL='claude-sonnet-5' \
    run "$RUN" --role fixture --route safe --data-class personal --explain
  assert_success
  assert_output --partial 'family:      unknown'
  refute_output --partial 'family:      anthropic'
}

# The classification is DATA, and this is the test that keeps it honest: every
# transport-shaped name anywhere in the tree must be filed under [scrub] or
# [not-transport], with a reason. A new one fails the suite until a human says
# which kind it is.
@test "every transport-shaped env name in the tree is classified" {
  local list="$REPO_ROOT/.local/src/agent-run/lib/scrub.list"
  assert [ -r "$list" ]

  # Scope: code WE own and deploy. Excluded, each for a reason:
  #   .git         compressed objects whose bytes match the pattern by accident
  #   node_modules vendored third-party JS (the opencode SDK names its own vars)
  #   vendor       vendored bats
  #   .serena      a third-party tool's own config, which names model ids
  # The question this test asks is "what can OUR code be handed", so a vendored
  # library's private variable names are noise, and history is not code at all.
  #
  # Note this file is itself in scope, which is correct and is a small trap: an
  # identifier written into a comment here is indistinguishable from one in real
  # code. It caught me once already. So do not spell unclassified examples out.
  local -a names=()
  while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < <(
    grep -rhoE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor \
      --exclude-dir=.serena --exclude-dir=.opencode \
      '\b(ANTHROPIC|CLAUDE_CODE|LLM|OPENCODE)_[A-Z0-9_]+\b' "$REPO_ROOT" 2>/dev/null | sort -u
  )
  # Empty input is FAILURE, not success. A scanner that matched nothing would
  # otherwise report a perfectly classified codebase.
  assert [ "${#names[@]}" -gt 20 ]

  local -a unclassified=()
  local n
  for n in "${names[@]}"; do
    grep -qE "^[[:space:]]*${n}([[:space:]]|#|$)" "$list" || unclassified+=("$n")
  done
  # Named in the failure, so the fix is obvious rather than a hunt.
  [ "${#unclassified[@]}" -eq 0 ] || \
    echo "unclassified: ${unclassified[*]}" >&2
  assert [ "${#unclassified[@]}" -eq 0 ]
}

# ---------------------------------------------------------------- the interlock

@test "personal data on a route that is not personal-safe is REFUSED" {
  run "$RUN" --role fixture --route paid --data-class personal --explain
  assert_equal "$status" 78
  assert_output --partial 'REFUSED'
  assert_output --partial 'personal'
}

# Paired positive control. Without it, a wrapper that refused EVERYTHING would
# satisfy the test above.
@test "...and the same role and data class on a safe route is allowed" {
  run "$RUN" --role fixture --route safe --data-class personal --explain
  assert_success
  assert_output --partial 'ALLOW'
}

@test "the refusal happens before the harness is sourced" {
  # No flags line means harness_exec was never reached. That ordering is what
  # makes "the model was never invoked" structural rather than incidental.
  run "$RUN" --role fixture --route paid --data-class personal --explain
  assert_equal "$status" 78
  refute_output --partial 'flags:'
}

@test "an unrecognised data class is refused, not treated as permissive" {
  run "$RUN" --role fixture --route safe --data-class confidential --explain
  assert_equal "$status" 78
  assert_output --partial 'not permissive'
}

@test "a route refuses a harness it declares it cannot support" {
  route rawonly 'openai-compatible' 'http://x.example/v1' yes yes yes none \
    'ROUTE_HARNESSES="raw"
ROUTE_VERIFY_MODEL="m"
ROUTE_VERIFY_API_BASE="http://x.example"'
  run "$RUN" --role fixture --harness claude --route rawonly --data-class public --explain
  assert_equal "$status" 78
  assert_output --partial 'does not support harness'
}

@test "an unknown route is refused and the available ones are listed" {
  run "$RUN" --role fixture --route nope --explain
  assert_equal "$status" 78
  assert_output --partial 'unknown route'
  assert_output --partial 'safe'
}

# ---------------------------------------------------------------- invariants

@test "I1: personal-safe on a gateway with a failover edge refuses to LOAD" {
  route liar 'anthropic-gateway' 'https://gw.example' yes yes no none
  run "$RUN" --role fixture --route liar --data-class personal --explain
  assert_equal "$status" 78
  assert_output --partial 'FALLBACK_SAFE=no'
}

@test "I2: a model id Claude Code would silently drop cannot be typed" {
  route parens 'anthropic-native' '' yes yes yes subscription \
    'ROUTE_MODEL_CLAUDE="code (Qwen3-Coder-Next-4bit)"'
  run "$RUN" --role fixture --route parens --data-class personal --explain
  assert_equal "$status" 78
  assert_output --partial 'silently'
}

@test "I3: an unfalsifiable fallback-safety claim refuses to load" {
  route unprovable 'openai-compatible' 'http://x.example/v1' yes yes yes none
  run "$RUN" --role fixture --route unprovable --data-class personal --explain
  assert_equal "$status" 78
  assert_output --partial 'nothing can ever check it'
}

@test "I4: personal-safe and payer=client is a contradiction" {
  route both 'anthropic-native' '' yes yes yes client
  run "$RUN" --role fixture --route both --data-class personal --explain
  assert_equal "$status" 78
  assert_output --partial 'contradiction'
}

@test "a missing required key is refused, and never reads as a 'no'" {
  cat > "$AGENTCTL_ROUTES/partial.route" <<'EOF'
ROUTE_DESC="forgot the safety flags"
ROUTE_TRANSPORT="anthropic-native"
ROUTE_PAYER="subscription"
EOF
  run "$RUN" --role fixture --route partial --data-class personal --explain
  assert_equal "$status" 78
  assert_output --partial 'does not set ROUTE_PERSONAL_SAFE'
}

# ---------------------------------------------------------------- application

@test "a gateway route sets the transport the harness will use" {
  route gw 'anthropic-gateway' 'https://gw.example' no yes no client
  run "$RUN" --role fixture --route gw --data-class work --explain
  assert_success
  assert_output --partial 'https://gw.example'
  assert_output --partial 'payer:       client'
}

@test "the default route is subscription when nothing names one" {
  # Uses the SHIPPED routes, not the fixtures: this asserts the built-in default
  # exists and is loadable, which is what makes adopting routes a no-op for a
  # runner that says nothing.
  unset AGENTCTL_ROUTES
  run "$RUN" --role fixture --data-class personal --explain
  assert_success
  assert_output --partial 'route:       subscription'
  assert_output --partial 'built-in default'
}
