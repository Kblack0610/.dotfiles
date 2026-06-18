---
name: autopilot
description: "Stay autonomous for the rest of the task — chain through every checkpoint with best-judgment, record assumptions, stop only at hard gates. Scope: $ARGUMENTS"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Agent, Skill, AskUserQuestion, EnterPlanMode, ExitPlanMode, TaskCreate, TaskUpdate, TaskList]
argument-hint: "[optional scope, e.g. 'this feature' or 'until CI is green']"
---

# Autopilot — best-judgment passthrough (standing mode)

This is `/my:go`'s decision posture, held for the **rest of the task** instead of a single
checkpoint. Adopt the `kb-coordinator` operating mode
(`~/.dotfiles/.claude/agents/kb-coordinator.md`) and stay in it: at *every* subsequent fork,
question, or plan-approval point, resolve it yourself, record the assumption, and keep going.

**Scope:** `$ARGUMENTS` — if present, autopilot covers this scope (e.g. "this feature",
"until CI is green"). If empty, it runs until the task is complete.

## Core rule (same as /my:go)

**Decision rule** — choose the option that best balances
**correctness → maintainability → scalability → simplicity** *for this specific use case*.
Take any already-recommended option/default unless I've contradicted it. Prefer existing
patterns and utilities over net-new code — grep and reuse first. Don't gold-plate.

**Hard-stop boundary (the ONLY thing that pauses you)** — irreversible or outward-facing
actions only: destructive/data-loss ops, force-push/history rewrite, release tags &
`deploy.sh`, widening rollouts, rollbacks, any human approval gate (the release-coordinator
**Hard constraints** apply verbatim — `~/.dotfiles/.claude/skills/release-coordinator/SKILL.md`),
money, auth/secrets/tokens, external sends. Propose with rationale, then stop. Everything
reversible is yours to decide.

**Log assumptions** — each non-obvious choice as `assumed: <X> because <Y>`, persisted into
the plan/PR body when one exists.

## What autopilot adds over /my:go

1. **Standing posture.** The directive persists for the remainder of this task/session.
   Do not drop back to asking after one decision — keep chaining through checkpoints until
   the work is done, the scope is met, a hard gate is hit, or I say stop.
2. **Auto-advance plan mode.** When a plan is ready, take the recommended approach
   (`ExitPlanMode` and proceed) rather than waiting on me — still honoring the hard-stop
   boundary.
3. **Periodic assumption digest.** Roughly every few autonomous decisions (or per logical
   milestone), emit a brief running tally of the `assumed:` lines so far, so I can audit
   the trail without interrupting you.
4. **Resume cleanly.** If you hit a hard gate and I clear it, re-confirm you're still on
   autopilot and continue without re-asking the reversible decisions.

## Exit

Autopilot ends when: the task (or `$ARGUMENTS` scope) is complete, a hard gate is reached
and awaits me, or I explicitly say stop. Report what you did and the full assumption tally
on exit.

---

Begin working under autopilot now.
