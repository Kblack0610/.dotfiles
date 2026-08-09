#!/usr/bin/env bats
# agentctl-run: contract rule 4 -- a reviewer never runs on the author's model family.
#
# Until 2026-08-07 "adversarial review" in the kb pipeline meant persona and tool
# grant only. No kb-* agent set a `model:`, so kb-developer, kb-reviewer and kb-qa
# all inherited delivery-loop's single ANTHROPIC_MODEL=claude-sonnet-5: the same
# weights marking their own homework in three different voices.
#
# The rule is Herdforge's (docs/architecture/TARGET-WORKFLOW.md), and so is the
# failure mode worth testing for: "if independence cannot be proven, review waits;
# the router does not degrade to self-review... Fallback can lose the
# different-family guarantee instead of failing closed."
#
# So this file is almost entirely REFUSALS. Every one of them is a path where the
# tempting behaviour is to shrug and run: author unknown, model unknown, no pin at
# all. Shrugging is the bug -- the review still gets RECORDED as independent, so a
# review that cannot prove its independence is worth less than no review.
#
# Roles are written INLINE, never read from the private overlay: the real roles
# live in gitignored `.config/agentctl/`, so a test that read them would pass on
# this machine and fail in CI. Same convention as agent_run_headless.bats.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  RUN="$REPO_ROOT/.local/src/agent-run/agentctl-run"

  mkdir -p "$HOME/.config/agentctl/roles" "$HOME/.config/agentctl/mcp"
  printf '{"mcpServers":{}}\n' > "$HOME/.config/agentctl/mcp/none.json"

  # The reviewer: pinned to a Qwen-family model, must never share the author's.
  write_role reviewer 'ROLE_MODEL="reasoning (Qwen3.6-35B-A3B-4bit)"
ROLE_FAMILY_EXCLUDE=author'

  # A reviewer that demands independence but names no model -- the family it will
  # run on is unknowable before launch.
  write_role unpinned 'ROLE_FAMILY_EXCLUDE=author'

  # The overwhelmingly common shape: no opinion about model family at all.
  write_role plain ''

  # `claude` must exist for the non-explain paths; it is never reached in a
  # refusal, which is itself part of what these tests assert.
  cat > "$SANDBOX/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "HARNESS RAN"
EOF
  chmod +x "$SANDBOX/bin/claude"
}

# write_role <name> <extra-keys> -- a minimal valid role plus whatever is on test.
write_role() {
  { printf 'ROLE_DESC="fixture"\nROLE_WRITE=no\nROLE_TASK=no\nROLE_BASH=yes\n'
    printf 'ROLE_MCP=none\nROLE_MCP_DENY=""\nROLE_APPROVE="Read,Glob,Grep,Bash"\n'
    printf '%s\n' "$2"
  } > "$HOME/.config/agentctl/roles/$1.role"
}

# ── Refusals ─────────────────────────────────────────────────────────────────

@test "an unset AGENT_AUTHOR_FAMILY REFUSES rather than assuming independence" {
  # The default state of every caller that has not been taught the rule yet. It
  # must be loud, because the silent version of this is exactly the bug: a review
  # recorded as independent that nobody ever compared against anything.
  run env -u AGENT_AUTHOR_FAMILY "$RUN" --explain reviewer
  assert_failure
  assert_output --partial 'AGENT_AUTHOR_FAMILY'
  assert_output --partial 'cannot prove its independence'
  refute_output --partial 'HARNESS RAN'
}

@test "a same-family author and reviewer REFUSE, and do not degrade to self-review" {
  run env AGENT_AUTHOR_FAMILY='Qwen3.6-35B-A3B-4bit' "$RUN" --explain reviewer
  assert_failure
  assert_output --partial 'must not share the author'
  assert_output --partial 'self-review'
  refute_output --partial 'HARNESS RAN'
}

@test "a family slug, not just a model id, is understood as the author" {
  # Callers carry whichever they have; both must reach the same verdict.
  run env AGENT_AUTHOR_FAMILY=qwen "$RUN" --explain reviewer
  assert_failure
  assert_output --partial 'must not share the author'
}

@test "an UNCLASSIFIABLE author REFUSES -- unknown is never treated as different" {
  # The tempting shrug. A model this code has never heard of could be anything,
  # including a rebadged sibling of the reviewer's.
  run env AGENT_AUTHOR_FAMILY='some-internal-model-v3' "$RUN" --explain reviewer
  assert_failure
  assert_output --partial 'cannot classify'
}

@test "declaring an exclusion with NO model pinned REFUSES" {
  # Independence that depends on whatever the transport happens to be pointing at
  # is not independence. Names the fallback trap in the message, because that is
  # the non-obvious half of getting the pin right.
  run env -u ANTHROPIC_MODEL -u AGENTCTL_MODEL AGENT_AUTHOR_FAMILY=anthropic "$RUN" --explain unpinned
  assert_failure
  assert_output --partial 'no model is pinned'
  assert_output --partial 'fallback'
}

@test "an unclassifiable REVIEWER model REFUSES too, not just an unknown author" {
  # Both ends have to be provable. A bare gateway alias (`reasoning`, `fast`)
  # lands here on purpose: an alias can be repointed at any upstream without the
  # consumer noticing, so it is not evidence of anything.
  write_role opaque 'ROLE_MODEL=reasoning
ROLE_FAMILY_EXCLUDE=author'
  run env AGENT_AUTHOR_FAMILY=anthropic "$RUN" --explain opaque
  assert_failure
  assert_output --partial 'cannot classify its own model'
}

# ── The passing case ─────────────────────────────────────────────────────────

@test "a different-family reviewer proceeds and reports both families" {
  run env AGENT_AUTHOR_FAMILY=claude-sonnet-5 "$RUN" --explain reviewer
  assert_success
  assert_output --partial 'family:      qwen'
  assert_output --partial 'excludes:    author -> anthropic'
}

@test "the role's pin actually reaches the harness, or the pin is decoration" {
  # Guards the wiring, not the decision. Without the export the check would pass
  # while the process ran on whatever ANTHROPIC_MODEL was already set to -- a
  # green light in front of an unchanged road.
  cat > "$SANDBOX/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'MODEL=%s\n' "\${ANTHROPIC_MODEL:-<unset>}" > "$SANDBOX/seen"
EOF
  chmod +x "$SANDBOX/bin/claude"
  run env AGENT_AUTHOR_FAMILY=anthropic ANTHROPIC_MODEL=claude-sonnet-5 "$RUN" --role reviewer -p x
  assert_success
  assert_equal "$(cat "$SANDBOX/seen")" 'MODEL=reasoning (Qwen3.6-35B-A3B-4bit)'
}

# ── The unconstrained majority ───────────────────────────────────────────────

@test "a role with no exclusion runs normally and says it is unconstrained" {
  # The check must not become a tax on the seven roles that have no opinion --
  # a gate that breaks the common path gets deleted, not fixed.
  run env -u AGENT_AUTHOR_FAMILY "$RUN" --explain plain
  assert_success
  assert_output --partial 'excludes:    (none'
}

@test "a role with no exclusion is not silently exempted -- --explain still shows its family" {
  # Auditability: `--explain` costs no tokens, so the family a role WILL run on
  # should be inspectable whether or not anything constrains it.
  run env ANTHROPIC_MODEL=claude-sonnet-5 "$RUN" --explain plain
  assert_success
  assert_output --partial 'family:      anthropic'
}
