---
name: usage-cleanup
description: >-
  A token and agent usage cleanup pass: baseline, find the burn, fix waste at the root, re-measure, report. Use for "what's our burn rate", "we're burning too much", "where do the tokens go", "usage cleanup pass N". Per-task model choice: model-lane; spend alerts: sentinel.
metadata:
  category: ops
  tags: [tokens, cost, usage, agents, fleet, context]
  reviewed: "2026-11-05"
---

# Usage cleanup

One pass that spends fewer tokens on the same work. It produces a measured baseline, a ranked list of where the tokens go, one PR per lever that removes the waste, and the same numbers again afterwards, so the next pass starts from a counted line rather than a feeling.

The numbers come from `agent-usage burn` (`.local/bin/agent-usage`, `.local/lib/agent-usage-burn.py`). It owns cost, PRs and the session splits; per-response tokens and tool output are `claude-recall tool-output`'s, and what each call costs in responses is `claude-recall tool-calls`'s. The nightly `agent-usage tokens snapshot` keeps both per day in `~/.agent/token-usage/`, so read the last 7 for a trend before measuring anew. When a tool lacks a number you need, extend it with a fixture test instead of counting by hand. This file holds only the procedure.

## When to Use

- The human says usage or spend is too high, or asks for "usage cleanup pass N".
- A spend watch from `sentinel` keeps firing and nobody can say where the tokens go.
- After a usage lever lands, to prove what it saved.

Siblings: one task's model is `model-lane`; ETAs and the scorecard are `fleet-bench`; one transcript is `claude-recall`.

## Hard limits

The human sets these, and dotfiles `CLAUDE.md` "Agent runtime" holds them: no deny, no blanket model or effort downgrade, and never refuse `cl` or a hand start. Automated lanes already stop at the budgets in their confs; lowering one is a conf edit, not a new mechanism. Savings come only from waste: work nobody needed, and context paid on every turn. A lever that cuts work someone needed is out of scope, however much it saves.

## Steps

1. **In flight first.** `agent-queue list`, `gh pr list` on both dotfiles repos, and the agent board's `token use` rows. Another session may own a lever already (token-filter, start-of-session context); do not fix in its area. Send it what you found with `fleet-comms`.
2. **Baseline.** Run `agent-usage burn --days 7` and save its `--json` to the scratchpad. It splits the window by account, project, session kind and model. It also gives tokens and cost per merged PR, turn-1 fixed context and its parts in chars (`first_request_parts`: system prompt, each tool schema, skill and agent listings, CLAUDE.md layers, MEMORY.md, preflight), wait calls, the turn mix (investigate, wait, write, reply), cache-write by cause, idle wakes by trigger, compactions, dream runs per night, and a by-session table (cost, turn mix, wait share, compactions, first turn, cost per merged PR). For one night, `--since <time> --before <time>` sets the window. For model and cost, read `model-usage` and the `claude-spend-*` and `claude-acct-*` watch state too. For the scorecard and sessions with no PR, use `fleet-bench` and `agentctl-session-outcomes worst`. Name every source you could not read cleanly (Langfuse, a per-account Prometheus split) and leave it out of the totals.
3. **Find the burn.** Put the tokens in buckets. Each bucket gets a measured number and the file or behaviour behind it:
   - fixed context per turn: read it from `first_request_parts`, never estimate it;
   - compaction;
   - waiting turns (sleep loops, `--watch`, background runs nothing else used: `tool-calls` `bg_short_idle`; task-output reads, which `tool-calls` splits into before the run's notice, which is polling, and after it, which is how the session sees the output);
   - tool calls (`claude-recall tool-calls`: failures by class, denied calls, serial reads, repeats, ToolSearch loads, Agent reports, MCP calls);
   - idle wakes (cache rewrites after a gap, sorted by what woke the session);
   - turns a hook or a peer caused: burn's turns by trigger give the `stop-hook` and `peer-message` totals. Split Stop-hook bounces by the hook named in the `Stop hook feedback:` text and peer messages by the sender named in `Another Claude session sent a message`, then read what the session did after a sample of each: a block the session could only explain away is a false positive to fix in the hook;
   - duplicate work (a phase or gate run twice, an ask filed again);
   - oversized models for the lane (`model-lane`);
   - subagent and workflow fan-out: split subagent transcripts by `agentType` in each `subagents/agent-*.meta.json`. Three accounts' `projects` dirs link to one directory, so dedupe by real path or every number comes out three times;
   - runner passes, including the shepherd and dream;
   - sessions with no merged PR.

   Use `claude-recall stats` for typed command and skill use before calling any listed text unused. Write down what you ruled out, with its number, so the next pass does not redo it.
4. **Rank levers, deletion first.** A lever that removes a mechanism, a listed item, or a repeat run ranks above one that adds a guard. Then rank by tokens saved per day. Each 1K tokens of always-loaded text is paid on every turn of every session, so price it from the baseline's turn count. Behaviour that no single file causes (waiting, idle wakes) goes on the board for its owner; a new rule does not fix it.
5. **Fix, one lever per PR,** through `dotfiles-land` for the dotfiles repos, with a test and a negative control for any script change. Before deleting listed text, grep both repos, the agentctl confs, the skills and the rule layers for references. A referenced item stays. A pass with several PRs is one queue item: merge each earlier PR by hand once `gh pr checks <N>` is all green (`gh pr merge <N> --squash --match-head-commit <sha>`), and run `agent-land <N> --item <slug>` only on the last, because it closes the item. A hook test that scans every process (`/proc/*/fd`) needs ids unique to the test, since the unit tier runs tests in parallel.
6. **Re-measure the same way** after each lever lands. A lever is live once the main checkout has its merge, since stow serves `~/.dotfiles`: check `git -C ~/.dotfiles log -1` before you start its window. Measure with `agent-usage burn --days N --before <landing time>` for the before window, and the same command without `--before` once a day of data exists. A nightly lever (dream, a timer) needs the next night's log. When the levers are landed and only the measuring waits on that log or a day of data, do not keep the session open for it: queue the measure-and-report step as an `at:` item whose task text names the plan file (the `at:` rule in agentctl `QUEUE.md`), close this pass's item, and wind down. Say what one day cannot show, and say which lever moved a number only when that lever was measured alone.
7. **Report.** Write `~/.notes/lab/projects/current/agent-runtime/docs/usage-cleanup-p<N>.md` with these sections:
   - spend and tokens by account, project, kind and model;
   - the top causes, each with its number;
   - what was fixed, with the PR and its measured saving;
   - what looks efficient;
   - a table for every step-2 metric with one column per measured point (the baseline, then after each pass), so a later pass adds a column instead of a new table;
   - what is left for the next pass.

   Publish it as an Artifact page and page the human with the link: `agent-notify -p normal -t usage-cleanup '<link>'`. With no Artifact tool (the Artifact tool is off by default; a session started with `CLAUDE_CODE_ARTIFACT=1` has it), page the report's path instead.

## Do NOT

- Do not quote a number `agent-usage burn` or a named source did not print this session.
- Do not put a price table in `agent-usage`: it counts tokens. A dollar figure comes from the registry's `cost_usd`, or is marked as an estimate.
- Do not start a live claude probe or a real `agentctl-dream --dry-run` to measure anything; both make model calls.
- Do not bundle levers in one PR: the before/after then measures nothing.
- Do not restate model-lane, claude-recall, fleet-bench or sentinel here; name them.
