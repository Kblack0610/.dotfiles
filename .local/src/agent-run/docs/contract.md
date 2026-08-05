# agent-run contract

What a ROLE means, independent of which harness runs it.

Mirrors the `ticket` CLI's `docs/contract.md`: the contract is the abstraction, the
harness adapters under `harnesses/` are implementations. `agentctl` has always
described itself as harness-agnostic (opencode / claude / openclaw / binks); this
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

Three rules, no exceptions:

1. **Unknown or missing role -> refuse to run.** A typo in a `.conf` must not
   silently restore full privilege.
2. **Missing capability key -> refuse to run.** `ROLE_WRITE=no` and "the author
   forgot to write `ROLE_WRITE`" must never look the same.
3. **A harness that cannot enforce a role's denials -> refuse to run.** Never
   degrade to unrestricted. Flipping `HARNESS=claude` to `HARNESS=binks` must not
   quietly drop the guarantee, because that is exactly how "observe-only" became
   fiction: prose asserted it, nothing checked it.

Rule 3 is why `openclaw.sh` and `binks.sh` ship as stubs that refuse. A stub that
refuses is worth more than an adapter that pretends.

## Harness mapping

| contract | claude | opencode |
|---|---|---|
| `ROLE_WRITE=no` | `--disallowedTools Write,Edit,NotebookEdit` | agent `tools: {write:false, edit:false}` |
| `ROLE_TASK=no` | `--disallowedTools Task` | subagent spawning off |
| `ROLE_BASH=no` | `--disallowedTools Bash` | agent `tools: {bash:false}` |
| `ROLE_MCP=<set>` | `--mcp-config mcp/<set>.json --strict-mcp-config` | agent `mcp` block |
| `ROLE_MCP=inherit` | no mcp flags; `ROLE_MCP_DENY` carries the weight | as above |
| `ROLE_APPROVE` | `--allowedTools` | `permission` block |

`ROLE_MCP` controls what SPAWNS; denials control what may be CALLED. Both are
needed. An allowlist alone still starts every user-scope server: that is how 11
idle sessions each ended up holding a headed browser nobody asked for.

## Known hole: `ROLE_BASH=yes` defeats `ROLE_WRITE=no`

Measured, not theorised. A role with `ROLE_WRITE=no, ROLE_BASH=yes`, asked to use
shell redirection, created the file with `printf`.

This is not patched, deliberately:

- opencode's own `plan` agent has the identical shape (`write:false, edit:false,
  bash:true`). Closing it on one harness only would make the same role behave
  differently depending on who ran it, which defeats the contract.
- A `Bash(...)` deny list is a blocklist on a shell, and shell blocklists leak:
  `tee`, `sed -i`, `python -c`, `dd`, any redirection you did not think of.

The real fix is a sandbox with no writable mount. Until then, a role with
`ROLE_WRITE=no, ROLE_BASH=yes` constrains the SHAPE of the work and must not be
described as airtight. Say so in any doc that describes such a role.

## Adding a harness

1. Write `harnesses/<name>.sh` exposing `harness_supports` and `harness_exec`.
2. `harness_supports` returns non-zero for any contract it cannot enforce. Be
   honest here; rule 3 depends on it.
3. Document the mapping in `docs/harnesses/<name>.md`.
4. Never add a fallback that runs unrestricted.
