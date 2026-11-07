---
name: usage-cleanup
description: >-
  A token and agent usage cleanup pass: baseline, find the burn, fix waste at the root, re-measure, report. Use for "what's our burn rate", "we're burning too much", "where do the tokens go", "usage cleanup pass N". Per-task model choice: model-lane; spend alerts: sentinel.
metadata:
  category: ops
  tags: [tokens, cost, usage, agents, fleet, context]
  reviewed: "2026-11-07"
---

# Usage cleanup

One pass that spends fewer tokens on the same work. It produces a measured baseline, a ranked list of where the tokens go, one PR per lever that removes the waste, and the same numbers again afterwards, so the next pass starts from a counted line rather than a feeling. The method (finding shape, in flight, baseline, one lever per PR, re-measure, proposals, next pass) is `~/.local/src/docs/analysis-streams.md`; this file holds what is specific to tokens.

The numbers come from `agent-usage burn` (`.local/bin/agent-usage`, `.local/lib/agent-usage-burn.py`). It owns cost, PRs and the session splits; per-response tokens and tool output are `claude-recall tool-output`'s, and what each call costs in responses is `claude-recall tool-calls`'s. The nightly `agent-usage tokens snapshot` keeps both per day in `~/.agent/token-usage/`, so read the last 7 for a trend before measuring anew. When a tool lacks a number you need, extend it with a fixture test instead of counting by hand. This file holds only the procedure.

## Scope and triggers

- The human says usage or spend is too high, or asks for "usage cleanup pass N".
- A spend watch from `sentinel` keeps firing and nobody can say where the tokens go.
- After a usage lever lands, to prove what it saved.

Siblings: one task's model is `model-lane`; ETAs and the scorecard are `fleet-bench`; one transcript is `claude-recall`.

## Hard limits

The human sets these, and dotfiles `CLAUDE.md` "Agent runtime" holds them: no deny, no blanket model or effort downgrade, and never refuse `cl` or a hand start. Automated lanes already stop at the budgets in their confs; lowering one is a conf edit, not a new mechanism. Savings come only from waste: work nobody needed, and context paid on every turn. A lever that cuts work someone needed is out of scope, however much it saves.

## Steps

1. **In flight first.** `agent-queue list`, `gh pr list` on both dotfiles repos, and the agent board's `token use` rows. Another session may own a lever already (start-of-session context, dispatch tool lists).
2. **Baseline.** Run `agent-usage burn --days 7` and save its `--json` to the scratchpad (`--sort cost|turns|context` orders the by-session table, so the longest sessions show whatever they cost). It splits the window by account, project, session kind and model. It also gives tokens and cost per merged PR, turn-1 fixed context and its parts in chars (`first_request_parts`: system prompt, each tool schema, skill and agent listings, CLAUDE.md layers, MEMORY.md, preflight), wait calls, the turn mix (investigate, wait, write, reply), cache-write by cause, idle wakes by trigger, compactions, dream runs per night, and a by-session table (cost, turn mix, wait share, compactions, first turn, cost per merged PR). For one night, `--since <time> --before <time>` sets the window. For model and cost, read `model-usage` and the `claude-spend-*` and `claude-acct-*` watch state too. For the scorecard and sessions with no PR, use `fleet-bench` and `agentctl-session-outcomes worst`. Name every source you could not read cleanly (Langfuse, a per-account Prometheus split) and leave it out of the totals.
3. **Find the burn.** Put the tokens in buckets. Each bucket gets a measured number and the file or behaviour behind it:
   - fixed context per turn: read it from `first_request_parts`, never estimate it;
   - compaction;
   - waiting turns (sleep loops, `--watch`, background runs nothing else used: `tool-calls` `bg_short_idle`; task-output reads, which `tool-calls` splits into before the run's notice, which is polling, and after it, which is how the session sees the output);
   - tool calls (`claude-recall tool-calls`: failures by class and by tool (`fail_tool`), denied calls, serial reads, repeats, ToolSearch loads, Agent reports, MCP calls);
   - idle wakes (cache rewrites after a gap, sorted by what woke the session);
   - turns a hook or a peer caused: burn's turns by trigger give the `stop-hook` and `peer-message` totals. `agentctl-session-outcomes worst --by hook` ranks hook denials by name, and `--by skill` ranks skills by calls. Split Stop-hook bounces by the hook named in the `Stop hook feedback:` text and peer messages by the sender named in `Another Claude session sent a message`, then read what the session did after a sample of each: a block the session could only explain away is a false positive to fix in the hook;
   - duplicate work (a phase or gate run twice, an ask filed again);
   - oversized models for the lane (`model-lane`);
   - subagent and workflow fan-out: split subagent transcripts by `agentType` in each `subagents/agent-*.meta.json`. Three accounts' `projects` dirs link to one directory, so dedupe by real path or every number comes out three times;
   - runner passes, including the shepherd and dream;
   - sessions with no merged PR.

   Use `claude-recall stats` for typed command and skill use before calling any listed text unused. Write down what you ruled out, with its number, so the next pass does not redo it.
4. **Rank levers,** deletion first, by tokens saved per day. Each 1K tokens of always-loaded text is paid on every turn of every session, so price it from the baseline's turn count. Behaviour that no single file causes (waiting, idle wakes) goes on the board for its owner; a new rule does not fix it.
5. **Fix, one lever per PR,** through `dotfiles-land` for the dotfiles repos. Before deleting listed text, grep both repos, the agentctl confs, the skills and the rule layers for references. A referenced item stays. A hook test that scans every process (`/proc/*/fd`) needs ids unique to the test, since the unit tier runs tests in parallel.
6. **Claim each lever; the verdict is automatic.** Each lever names the token KPI it should move (`responses_per_merged_pr`, `context_per_merged_pr`, `tool_chars_per_call`, `locate_read_share`, `reread_share`, `cache_write_share`, `start_share`, `compactions_per_session`, all in `fleet-bench kpi`, summed from the nightly snapshots). At landing, run `fleet-bench improve claim <kpi> <ar-N|item:slug>`; a KPI is claimable only past its threshold in `kpi-thresholds`, so set one below today's value first. Retro then reads it `BENCH_EFFECT_DAYS` after the close and files a #high revert row when it regressed, so a lever that does nothing reads flat with no by-hand compare. For an early lead, `fleet-bench effect owner/repo#N --days N` compares the snapshots before and after the merge. A lever is live once the main checkout has its merge, since stow serves `~/.dotfiles`: check `git -C ~/.dotfiles log -1`. When the levers are landed and only the verdicts wait, do not keep the session open: queue the report step as an `at:` item whose task text names the plan file (the `at:` rule in agentctl `QUEUE.md`), close this pass's item, and wind down. Say which lever moved a number only when that lever was measured alone.
7. **Report.** Write `~/.notes/lab/projects/current/agent-runtime/docs/usage-cleanup-p<N>.md` with these sections:
   - spend and tokens by account, project, kind and model;
   - the top causes, each with its number;
   - what was fixed, with the PR and its measured saving;
   - what looks efficient;
   - a table for every step-2 metric with one column per measured point (the baseline, then after each pass), so a later pass adds a column instead of a new table;
   - what is left for the next pass.

   Post each lever left undone as one proposal (stream `usage-cleanup`, project `agent-runtime`, evidence the report path).

   Publish it as an Artifact page and page the human with the link: `agent-notify -p normal -t usage-cleanup '<link>'`. With no Artifact tool (the Artifact tool is off by default; a session started with `CLAUDE_CODE_ARTIFACT=1` has it), page the report's path instead.

8. **Queue the next pass** per the method (`--project agent-runtime`, slug `usage-cleanup-p<N+1>`, baseline `~/.notes/lab/projects/current/agent-runtime/docs/usage-cleanup-p<N>.md`). Queue it before `agent-land`.

9. **Re-measure** one day after a lever goes live. Queue it with the report (step 8's `agent-queue add`, tag `at:<live time + 1 day>`, task text naming the plan and report); step 8's weekly pass is a different item. Read the window `t..t+24h` with explicit ISO times (`2026-11-06T05:40:00Z`; a bare date means midnight and shifts the window), and add one column to the report's table:
   - `agent-usage burn --since <t> --before <t+24h>` and `claude-recall tool-calls --since <t> --until <t+24h>`.
   - A subagent-model lever: read `subagents/*.meta.json` (`isBuiltIn` false, deduped by real path) and the model in the sibling `.jsonl`. The Opus share is `by_origin.subagent` `opus_turns` over `turns`; report `1 - that` as "not Opus", and Haiku turns from `by_model` separately.
   - A deny lever: `tool-calls` counts a denied call, so subtract the `fail_text` rows that carry the lever hook's own message text (and no other hook's), and say how many were denied.
   - Burn %/h: the `claude-acct status` fleet line, and for the window `sum(clamp_min(claude_account_week_used_percent @ <end epoch> - claude_account_week_used_percent @ <start epoch>, 0))` through `prom_q` in `claude-acct`, divided by 24. An account whose week reset inside the window clamps to 0: name it and call the figure a floor.

## Do NOT

- Do not put a price table in `agent-usage`: it counts tokens. A dollar figure comes from the registry's `cost_usd`, or is marked as an estimate.
- Do not start a live claude probe or a real `agentctl-dream --dry-run` to measure anything; both make model calls.
- Do not restate model-lane, claude-recall, fleet-bench or sentinel here; name them.
