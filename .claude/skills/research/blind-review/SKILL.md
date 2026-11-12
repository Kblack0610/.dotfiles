---
name: blind-review
description: >-
  Independent second plan from a fresh agent that never sees plan X: frozen repo snapshot, banned paths, leak audit, side by side for the human. Use for "independent review", "fresh eyes", "blind plan", "compare to plan X". Own-code research: deep-research-code.
metadata:
  category: research
  tags: [research, review, planning, subagent]
  reviewed: "2026-11-11"
---

# blind-review

Get a second answer to a question that already has one (plan X) from an agent that has never seen X, then lay the two side by side for the human to pick. The value is the lack of anchoring: an agent that reads X first, or is briefed by someone who did, returns X with edits. So the blind agent gets only the original ask, a copy of the repo from before X existed, and read-only data, and its transcript is checked afterwards to prove it stayed blind.

## Scope and triggers

- "Do your own independent research and compare it to plan X", "fresh eyes on this", "a blind plan", "a second opinion that has not seen the plan".
- Before committing to a costly or hard-to-reverse plan, when one alternative from a clean context is cheap insurance.

Not for investigating with everything in view: `deep-research-code`. Not for reviewing a diff for defects: `code-review`.

## Steps

1. **Freeze.** Pick the commit before X landed (`git log` it yourself, here, not in the brief), or HEAD when X is unlanded. Snapshot it with no history:
   `~/.claude/skills/blind-review/blind.sh snapshot <repo> <sha>` prints the path, under `~/.cache/blind-review/$CLAUDE_CODE_SESSION_ID/`.
2. **Brief.** Fill `assets/brief.md` with the original ask in the human's words, the snapshot path, the read-only data sources and the live checkout path to forbid. Leave out X, its owner's reasoning and your own view. If you have already read X, write the ask from the human's message, not from memory of X.
3. **Run.** One fresh Agent (`general-purpose` or `claude`; never `fork`, which inherits your context). Note the agent ID it returns.
4. **Audit.** `blind.sh audit <agent-id> <live checkout path>` exits 1 and prints the call when the agent read a plan, `~/.agent`, `~/.notes`, the live checkout or git history. A leak voids the run: fix the brief and run it again.
5. **Verify.** Re-check the blind answer's numbers and load-bearing claims against the live system before anyone acts on them. An independent answer is not a correct one.
6. **Compare.** One table, X beside blind: approach, cost, risks, what each missed. Add your recommendation and leave the pick to the human.
7. **Clean.** `blind.sh clean` deletes this session's snapshots.

## Do NOT

- Hand the blind answer to X's owner, or file it on an agent-ask the judge auto-answers, before the human picks. Why: on 2026-11-11 that started an adoption of the blind plan before anyone had judged whether it was any good.
- Change X because of the blind answer before the human has chosen.
- Use a git worktree as the snapshot. Why: it carries the history and the commits that made X.
