# agent-run contract

What a ROLE means, independent of which harness runs it.

Mirrors the `ticket` CLI's `docs/contract.md`: the contract is the abstraction, the
harness adapters under `harnesses/` are implementations. `agentctl` has always
described itself as harness-agnostic (claude / codex / opencode / binks); this
makes capability agnostic too, instead of burying it in each runner's `COMMAND`.

## The capability vocabulary

A `.role` file declares capability abstractly. It never names a harness flag.

| key | values | meaning |
|---|---|---|
| `ROLE_DESC` | free text | one line, shown by `agentctl-run --explain` |
| `ROLE_WRITE` | `yes` \| `no` | may create or modify files through write/edit tools |
| `ROLE_TASK` | `yes` \| `no` | may spawn subagents |
| `ROLE_BASH` | `yes` \| `no` | may run shell commands |
| `ROLE_MCP` | `<set>` \| `none` \| `inherit` | which MCP server set may SPAWN. `<set>` names `mcp/<set>.json` |
| `ROLE_MCP_DENY` | comma list | MCP families explicitly denied. Required when `ROLE_MCP=inherit` |
| `ROLE_APPROVE` | comma list | tools to pre-approve so a headless run does not hang on a prompt |

Every key must be set explicitly. A missing key is a hard error, not a default -
see "fail closed" below.

## Why `ROLE_APPROVE` is separate from the denials

They are different mechanisms and conflating them is the bug this whole thing
exists to fix.

Measured on Claude Code, 2026-07-28:

| run | result |
|---|---|
| `--allowedTools "Read,Glob,Grep"` (no Write, no Bash), told to Write a file | **wrote it** |
| `--disallowedTools "Write,Edit,NotebookEdit"`, same prompt | replied `CANNOT`, file byte-identical |

`--allowedTools` is an AUTO-APPROVE list. It pre-approves what it names and
removes nothing. Only a denial removes a capability.

So `ROLE_APPROVE` exists for a real but different reason: an unapproved tool in a
headless run would sit waiting for a human who is not there. It is about not
hanging, never about safety. Anything load-bearing goes in `ROLE_WRITE`,
`ROLE_TASK`, `ROLE_BASH` or `ROLE_MCP_DENY`.

Note for anyone reading old code: `agentctl-dream` and `agentctl-nightly-sync`
have always passed `--allowedTools "Read,Write,Bash,Glob,Grep"`, and
nightly-sync's header describes that as "NO Linear, NO memory MCPs". That
restriction was never in force.

## Fail closed, always

Four rules, no exceptions:

1. **Unknown or missing role -> refuse to run.** A typo in a `.conf` must not
   silently restore full privilege.
2. **Missing capability key -> refuse to run.** `ROLE_WRITE=no` and "the author
   forgot to write `ROLE_WRITE`" must never look the same.
3. **A harness that cannot enforce a role's denials -> refuse to run.** Never
   degrade to unrestricted. Flipping `HARNESS=claude` to `HARNESS=binks` must not
   quietly drop the guarantee, because that is exactly how "observe-only" became
   fiction: prose asserted it, nothing checked it.
4. **Unprovable model-family independence -> refuse to run.** A role that sets
   `ROLE_FAMILY_EXCLUDE` never launches on a family it must not share, and never
   launches when either side cannot be classified.

Rule 3 is why `binks.sh` ships as a stub that refuses. A stub that
refuses is worth more than an adapter that pretends.

## Rule 4: model-family independence

A reviewer that shares the author's model family is not an independent review; it
is the same weights marking their own homework in a different voice. Ours were
exactly that until 2026-08-07 — no `kb-*` agent set a `model:`, so kb-developer,
kb-reviewer and kb-qa all inherited the runner's single
`ANTHROPIC_MODEL`, and the separation was persona plus tool grant
only.

Two optional role keys:

| key | meaning |
|---|---|
| `ROLE_MODEL` | pin the model this role runs on. Exported to the harness, so the pin is real rather than documentation. |
| `ROLE_FAMILY_EXCLUDE` | a comma-separated list of family slugs, or the token `author` (read from `$AGENT_AUTHOR_FAMILY`, which may be a slug or a model id). |

Families are derived from the model id (`anthropic`, `openai`, `google`, `xai`,
`meta`, `mistral`, `deepseek`, `moonshot`, `qwen`, `zhipu`). Anything unrecognised
is `unknown`, and **`unknown` is a refusal, never a "probably fine"** — an unknown
family cannot be proven different from anything.

Every uncertain path ends in a refusal rather than a warning:

- `$AGENT_AUTHOR_FAMILY` unset -> refuse. Nothing to compare against.
- either side unclassifiable -> refuse.
- `ROLE_FAMILY_EXCLUDE` set but no model pinned -> refuse. Independence that
  depends on whatever the transport happens to point at is not independence.

The reason it is this strict: a review that cannot prove its independence still
gets *recorded* as independent, which is worse than no review at all.

**The pin must be a route with no fallback edge.** A LiteLLM fallback fires inside
the router *after* the key check, so a scoped virtual key cannot stop a spill back
onto the excluded family — which would silently re-cross the line while every
check still reported green. Prefer a direct-to-origin route, or a gateway route
with no fallback configured, and verify with `x-litellm-attempted-fallbacks: 0`
plus `x-litellm-model-api-base`.

**Bare gateway aliases (`code`, `reasoning`, `fast`) classify as `unknown` and are
therefore refused.** That is deliberate, not a gap: an alias can be repointed at
any upstream without the consumer noticing, so it is not evidence of a family.
Pin the id that names the real model.

Herdforge's `TARGET-WORKFLOW.md` states both halves of this rule and the failure
mode it guards: *"if independence cannot be proven, review waits; the router does
not degrade to self-review... Fallback can lose the different-family guarantee
instead of failing closed."*

Audit any role without spending tokens: `agentctl-run --explain <role>` prints the
model, its family, and the exclusion (or says the role is unconstrained).

**Scope limit, stated plainly:** this enforces the family of the *process*
agentctl-run launches. `kb-reviewer` and `kb-qa` are dispatched as **subagents**
inside a `kb-coordinator` process running `ROLE=build`, so rule 4 does not reach
them — their independence comes from the `model:` frontmatter in
`~/.claude/agents/*.md`. Two levers, both needed; this one covers direct runners.

## Harness mapping

| contract | claude | opencode | codex |
|---|---|---|---|
| `ROLE_WRITE=no` | `--disallowedTools Write,Edit,NotebookEdit` | agent `tools: {write:false, edit:false}` | `--sandbox read-only` (binds the shell too) |
| `ROLE_WRITE=yes` | no write denial | agent grants write | `--dangerously-bypass-approvals-and-sandbox` |
| `ROLE_TASK=no` | `--disallowedTools Task` | subagent spawning off | `--disable multi_agent` |
| `ROLE_BASH=no` | `--disallowedTools Bash` | agent `tools: {bash:false}` | refused with `ROLE_WRITE=yes`; with `ROLE_WRITE=no` the read-only sandbox leaves the shell no side effect |
| `ROLE_MCP=<set>` | `--mcp-config mcp/<set>.json --strict-mcp-config` | agent `mcp` block | `-c mcp_servers.<n>.enabled=false` for each configured server outside the set, the set's servers added inline (`-c mcp_servers={}` merges and clears nothing, measured on 0.164) |
| `ROLE_MCP=inherit` | no mcp flags; `ROLE_MCP_DENY` carries the weight | as above | config.toml servers |
| `ROLE_APPROVE` | `--allowedTools` | `permission` block | n/a: exec never prompts |
| `AGENT_SCHEMA` | `--json-schema` | refused | `--output-schema` |

`ROLE_MCP` controls what SPAWNS; denials control what may be CALLED. Both are
needed. An allowlist alone still starts every user-scope server: that is how 11
idle sessions each ended up holding a headed browser nobody asked for.

## Lane sandbox

A role says what an agent may do; a lane sandbox bounds what its shell can touch while doing it. A runner conf opts in with `SANDBOX_PROFILE=<name>`, which loads `~/.config/agentctl/sandbox/<name>.json` (override: `$AGENTCTL_SANDBOX_DIR`). The profile is Claude settings content: `sandbox.filesystem.denyRead` (credential paths), `sandbox.filesystem.allowWrite` (state dirs the lane writes), `sandbox.network.allowedDomains`. Unset means the lane runs unsandboxed. `lib/sandbox.sh` is the mechanism; `tests/integ/agent_run_sandbox.bats` checks it, and `tests/container/sandbox-proof.sh` proves the profile against the real sandbox runtime with a negative control.

| | claude | codex |
|---|---|---|
| sandbox on | `--settings` with the profile, `sandbox.enabled`, `failIfUnavailable`, `allowUnsandboxedCommands:false` and `network.strictAllowlist` forced on | `--sandbox workspace-write` in place of the bypass, for a writing role (a read-only role keeps `read-only`) |
| writable (shell) | cwd, the profile's `allowWrite`, the git common dir (so `git commit` works from a worktree) minus its `hooks` and `config` | `writable_roots`: the profile's `allowWrite` and the git common dir |
| read denial | each `denyRead` path in the sandbox, and as `Read()` and `Edit()` deny rules for the in-process tools | none, so a profile with `denyRead` is refused |
| egress | `allowedDomains` only, strict | off; a profile with `allowedDomains` is refused, since codex network is all or nothing |

- Fail closed (exit 78): a named profile that is missing, not the shape `SANDBOX_SHAPE` in `lib/sandbox.sh` checks (lists of strings, paths absolute or `~/`), or one the harness cannot hold refuses the run. A harness enforces a profile only by defining `harness_sandbox`; opencode, raw and binks do not, so they refuse every profile. `failIfUnavailable` makes a missing `bwrap` or `socat` a refusal, never an unsandboxed run.
- GitHub: the profile hides gh's login, so `GH_TOKEN_FILE=<path>` in the conf gives the lane its own repo-scoped token as `GH_TOKEN`. A sandboxed lane with no `GH_TOKEN_FILE` gets no `GH_TOKEN` or `GITHUB_TOKEN` from the environment.
- An `--agent` call inherits its caller's `SANDBOX_PROFILE`. A sandboxed lane's model cannot start a sandboxed call from its own shell (bwrap does not nest), so roll out one runner at a time.
- Claude's sandbox confines Bash only. WebFetch is not held to `allowedDomains`, and the in-process Edit and Write tools are bounded only by permission rules: the `denyRead` paths become `Edit()` denies, and anything else a lane must not edit goes in the profile's `permissions.deny`.

## Known hole: `ROLE_BASH=yes` defeats `ROLE_WRITE=no`

Measured, not theorised. A role with `ROLE_WRITE=no, ROLE_BASH=yes`, asked to use
shell redirection, created the file with `printf`.

This is not patched, deliberately:

- opencode's own `plan` agent has the identical shape (`write:false, edit:false,
  bash:true`). Closing it on one harness only would make the same role behave
  differently depending on who ran it, which defeats the contract.
- A `Bash(...)` deny list is a blocklist on a shell, and shell blocklists leak:
  `tee`, `sed -i`, `python -c`, `dd`, any redirection you did not think of.

The real fix is a sandbox with no writable mount (a lane sandbox, above, bounds writes to its roots but does not remove them). Until then, a role with
`ROLE_WRITE=no, ROLE_BASH=yes` constrains the SHAPE of the work and must not be
described as airtight. Say so in any doc that describes such a role. The codex
harness is the exception: its read-only sandbox covers the shell.

## Adding a harness

1. Write `harnesses/<name>.sh` exposing `harness_supports` and `harness_exec`.
2. `harness_supports` returns non-zero for any contract it cannot enforce. Be
   honest here; rule 3 depends on it.
3. Document the mapping in `docs/harnesses/<name>.md`.
4. Never add a fallback that runs unrestricted.
