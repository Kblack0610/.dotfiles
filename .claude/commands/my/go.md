---
name: go
description: "Proceed at this checkpoint with your best-practice recommendation — record assumptions, don't ask. Optional scope: $ARGUMENTS"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Agent, Skill, AskUserQuestion, EnterPlanMode, ExitPlanMode, TaskCreate, TaskUpdate, TaskList]
argument-hint: "[optional scope, e.g. 'until tests pass' or 'just this PR']"
---

# Go — best-judgment passthrough (one-shot)

You are at a decision checkpoint — a question I'd normally answer, a plan awaiting
approval, or an ambiguous fork mid-task. **Don't ask me. Make the call and proceed.**
This is the `kb-coordinator` operating posture (`~/.dotfiles/.claude/agents/kb-coordinator.md`)
invoked on demand: resolve it yourself by recording an explicit assumption, then continue.

**Scope:** `$ARGUMENTS` — if present, bound the autonomy to this (e.g. "just this PR",
"until tests pass"). If empty, this applies to the current checkpoint and its immediate
next steps, then yield back at the next natural stopping point.

## Decision rule

Choose the option that best balances, in order:
**correctness → maintainability → scalability → simplicity** — *for this specific use case*,
not in the abstract. Concretely:

- If a recommended option was already presented (a plan, an AskUserQuestion option marked
  "Recommended", a default), **take it** unless something I've said contradicts it.
- Prefer existing patterns, utilities, and conventions in this codebase over net-new code.
  Grep first; reuse before you write.
- Don't gold-plate. Match the altitude of the surrounding work — the smallest change that
  fully solves it, no more.

## Proceed, don't ask

Do not re-pose the question back to me. Execute the chosen path. Keep moving through the
immediate next steps without checking in.

## Hard-stop boundary (the ONLY thing that still pauses you)

Stop and surface a proposal **only** for irreversible or outward-facing actions:

- Destructive / data-loss ops (deleting files you didn't create, dropping tables, `rm -rf`,
  overwriting un-backed-up state), force-push or history rewrite.
- Release tags, `deploy.sh`, widening a rollout, executing a rollback, satisfying any
  human approval gate — the release-coordinator **Hard constraints** apply verbatim
  (`~/.dotfiles/.claude/skills/release-coordinator/SKILL.md`); do not restate or weaken them.
- Money, auth/secrets/tokens, anything sent to an external service or another person.

For these: propose with a one-line rationale, then stop and wait. Everything reversible is
yours to decide.

## Log your assumptions inline

Every non-obvious choice gets a short line in your reply:

```
assumed: <the choice> because <the reason>
```

When a plan file or PR body exists, also persist these into it (mirror the
`## Assumptions` section convention) so the decision trail stays auditable.

---

Continue with the work now under these rules. For full-task autonomy (chain through *every*
subsequent checkpoint, not just this one), the user wants `/my:autopilot` instead.
