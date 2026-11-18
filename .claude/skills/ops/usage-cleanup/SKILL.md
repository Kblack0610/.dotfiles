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

One pass that spends fewer tokens on the same work: a ranked list of where the tokens go, and one PR per lever that removes the waste. The pass itself (finding shape, in flight, baseline, one lever per PR, re-measure, report, proposals, next pass) is `~/.local/src/docs/analysis-streams.md`; read it first. This file holds what is specific to tokens.

The numbers come from `agent-usage burn` (`.local/bin/agent-usage`, `.local/lib/agent-usage-burn.py`). It owns cost, PRs and the session splits; per-response tokens and tool output are `claude-recall tool-output`'s, and what each call costs in responses is `claude-recall tool-calls`'s. The nightly `agent-usage tokens snapshot` keeps both per day in `~/.agent/token-usage/`, so read the last 7 for a trend before measuring anew.

## Scope and triggers

- The human says usage or spend is too high, or asks for "usage cleanup pass N".
- A spend watch from `sentinel` keeps firing and nobody can say where the tokens go.
- After a usage lever lands, to prove what it saved.

Siblings: one task's model is `model-lane`; ETAs and the scorecard are `fleet-bench`; one transcript is `claude-recall`.

## Hard limits

The human sets these, and dotfiles `CLAUDE.md` "Hard limits on budgets" holds them: no deny, no blanket model or effort downgrade, and never refuse `cl` or a hand start. Automated lanes already stop at the budgets in their confs; lowering one is a conf edit, not a new mechanism. Savings come only from waste: work nobody needed, and context paid on every turn. A lever that cuts work someone needed is out of scope, however much it saves.

## Steps

1. **In flight first,** per the method, on both dotfiles repos and the agent board's `token use` rows. Another session may own a lever already (start-of-session context, dispatch tool lists).
2. **Baseline.** Run `agent-usage burn --days 7` and save its `--json` to the scratchpad (`--sort cost|turns|context` orders the by-session table, so the longest sessions show whatever they cost). It splits the window by account, project, session kind and model. It also gives tokens and cost per merged PR, turn-1 fixed context and its parts in chars (`first_request_parts`: system prompt, each tool schema averaged over the requests that carry it, skill and agent listings, CLAUDE.md layers, MEMORY.md, preflight), the same parts over every recorded request, subagents included, with each part's share of their context (`every_request_parts`), wait calls, the turn mix (investigate, wait, write, reply), cache-write by cause, idle wakes by trigger, compactions, dream runs per night, and a by-session table (cost, turn mix, wait share, compactions, first turn, cost per merged PR). For one night, `--since <time> --before <time>` sets the window. For model and cost, read `model-usage` and the `claude-spend-*` and `claude-acct-*` watch state too. For the scorecard and sessions with no PR, use `fleet-bench` and `agentctl-session-outcomes worst`. The sources most often unclean, and so left out of the totals, are Langfuse and a per-account Prometheus split.
3. **Find the burn.** Put the tokens in buckets. Each bucket gets a measured number and the file or behaviour behind it:
   - fixed context per turn: read it from `first_request_parts`, and what it costs across the window from `every_request_parts` `context_share` (chars over the first requests' chars a token, so a part's share, not an exact token count), never estimate it;
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

   Use `claude-recall stats` for typed command and skill use before calling any listed text unused.
4. **Rank levers** per the method, by tokens saved per day. Each 1K tokens of always-loaded text is paid on every turn of every session, so price it from the baseline's turn count. Behaviour that no single file causes (waiting, idle wakes) goes on the board for its owner; a new rule does not fix it.
5. **Fix, one lever per PR,** through `dotfiles-land` for the dotfiles repos. Before deleting listed text, grep both repos, the agentctl confs, the skills and the rule layers for references. A referenced item stays. A hook test that scans every process (`/proc/*/fd`) needs ids unique to the test, since the unit tier runs tests in parallel.
6. **Claim each lever; the verdict is automatic.** Each lever names the token KPI it should move (`responses_per_merged_pr`, `context_per_merged_pr`, `tool_chars_per_call`, `locate_read_share`, `reread_share`, `cache_write_share`, `start_share`, `start_context_median`, `compactions_per_session`, all in `fleet-bench kpi`, summed from the nightly snapshots). At landing, run `fleet-bench improve claim <kpi> <ar-N|item:slug>`; a KPI is claimable only past its threshold in `kpi-thresholds`, so set one below today's value first. Retro then reads it `BENCH_EFFECT_DAYS` after the close and files a #high revert row when it regressed, so a lever that does nothing reads flat with no by-hand compare. For an early lead, `fleet-bench effect owner/repo#N --days N` compares the snapshots before and after the merge. When the levers are landed and only the verdicts wait, queue the report step as an `at:` item and wind down, per the method's re-measure rule.
7. **Report** in `~/.notes/lab/projects/current/agent-runtime/docs/usage-cleanup-p<N>.md` per the method: spend and tokens by account, project, kind and model, then the causes, fixes, what looks efficient, the table (every step-2 metric) and what is left. Proposals per the method (project `agent-runtime`). Publish and page per the method (`-t usage-cleanup`).

8. **Queue the next pass** per the method (`--project agent-runtime`, baseline the step-7 report).

9. **Re-measure** one day after a lever goes live. Queue it with the report (step 8's `agent-queue add`, tag `at:<live time + 1 day>`, task text naming the plan and report); step 8's weekly pass is a different item. Read the window `t..t+24h` with explicit ISO times (`2026-11-06T05:40:00Z`), and add one column to the report's table:
   - `agent-usage burn --since <t> --before <t+24h>` and `claude-recall tool-calls --since <t> --until <t+24h>`.
   - A subagent-model lever: read `subagents/*.meta.json` (`isBuiltIn` false, deduped by real path) and the model in the sibling `.jsonl`. The Opus share is `by_origin.subagent` `opus_turns` over `turns`; report `1 - that` as "not Opus", and Haiku turns from `by_model` separately.
   - A deny lever: `tool-calls` counts a denied call, so subtract the `fail_text` rows that carry the lever hook's own message text (and no other hook's), and say how many were denied.
   - Burn %/h: the `claude-acct status` fleet line, and for the window `sum(clamp_min(claude_account_week_used_percent @ <end epoch> - claude_account_week_used_percent @ <start epoch>, 0))` through `prom_q` in `claude-acct`, divided by 24. An account whose week reset inside the window clamps to 0: name it and call the figure a floor.

## Do NOT

- Do not put a price table in `agent-usage`: it counts tokens. Burn's cost, per merged PR, by origin and by session are `fleet_cost()`, billed where a session reports cost and priced at rates fitted to the billed ones otherwise, each marked measured or estimated; the `registry`, `by_account` and `by_project` cost is billed sessions only, a cross-check (moving them is ar-2793).
- Do not start a live claude probe or a real `agentctl-dream --dry-run` to measure anything; both make model calls.
