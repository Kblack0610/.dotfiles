---
name: deep-research-code
description: Multi-agent deep investigation of YOUR OWN systems — decompose a question into independent threads, fan out subagents across code (Explore) AND live infrastructure/tooling (kubectl, doctl, gh, curl, psql, MCP), cross-section the web where external tool/API behavior is in doubt, then adversarially RE-VERIFY every load-bearing claim against live evidence before trusting it. Produces a synthesized report with a verified/contradicted/unverified column and an explicit "contradicted & unresolved" section. Use when the user wants a deep, evidence-based answer about their own codebase + deployment + pipeline ("what will it take to get X to prod", "why does Y keep failing", "is Z actually fixed", "audit our release pipeline", "what's truly left"). Differs from deep-research (web/market questions). Differs from Explore agents (code search only, no live probing, no verify pass). Differs from bug-bash (fix-dispatch workstream). This skill INVESTIGATES across code+infra+web and trusts nothing until it's checked live.
---

# deep-research-code

Investigate a question about your own systems — code, deployment, CI/CD, live cluster, third-party tools — by fanning out isolated subagents across every relevant surface, then **adversarially re-verifying the claims that drive the answer against live evidence**. The differentiator over plain Explore: it crosses code + infra + web in one investigation, and it does not trust any finding (its own agents', the docs', the CHANGELOG's) until live state confirms it.

Core idea: **breadth from isolated parallel contexts + truth from a live-verify pass.** Docs lie, CHANGELOGs claim fixes that regressed, agents hallucinate confident-but-wrong verdicts. The verify pass is where wrong answers get caught before they reach the user.

## When to invoke
- "What will it actually take to get X to prod / launch?" / "what's truly left?"
- "Why does Y keep failing?" (flaky deploy, silent cron, stuck pipeline)
- "Is Z actually fixed?" (verify a claimed fix against running code + live state)
- "Audit our release pipeline / deployment / backups / monitoring."
- High-stakes internal decisions where a wrong assumption is expensive (a prod deploy, a migration, a launch call).

Do **not** use for: web/market research (use `deep-research`), a pure code-location search (use `Explore`), dispatching fixes after triage (use `bug-bash`), or a single known-file lookup (just read it).

## The pattern
1. **Scope.** Restate the question + what "done/answered" looks like. Ask 1-3 clarifying questions only if genuinely underspecified (which prod env? which app? launch-blocking vs nice-to-have?).
2. **Decompose into independent threads** — one non-overlapping surface each. Typical threads for an internal question:
   - **Code reality** — does the code actually do what's claimed? (Explore over services/routers/migrations/configs)
   - **Pipeline/CI** — what runs, what gates what, what's red and why (.github/workflows, deploy scripts, run history via `gh`)
   - **Live infra** — what's *actually* deployed/running right now (kubectl/doctl/curl against the real cluster + endpoints)
   - **Release delta / risk** — what would ship; destructive migrations; backward-compat; new required env vars
   - **Observability/secrets** — monitoring, alerting, error tracking, secret presence
   Name the threads explicitly. Bad decomposition = redundant agents.
3. **Fan out** — one subagent per thread, in parallel (single message, multiple `Agent` calls). Use `Explore` for code-search threads; use `general-purpose`/`claude` for threads that must run live commands. Give each a tight brief + the structured-output contract below, and tell it to **prefer primary evidence (command output, file contents) over inference**.
4. **Run live probes yourself in the same turn** — alongside the agents, fire the cheap high-signal checks directly: `kubectl get/describe`, `doctl`, `curl` health/endpoints, `gh run list/view`, a one-off test pod. These are often faster than an agent and give you ground truth to check agents against.
5. **Dedup & gap-check** — merge overlapping findings; list contradictions and what's missing. Spawn a second mini-round only for real gaps.
6. **Adversarially verify every load-bearing claim** (the differentiator — see below).
7. **Synthesize** — direct answer first, then a findings table with a **verdict column**, then an explicit **"contradicted & unverified"** section. Never bury uncertainty to make the narrative clean.

## Adversarial live-verify (the differentiator)
A claim is **load-bearing** if the recommendation changes when it's wrong. For each one, get **independent live evidence** before trusting it — don't re-ask the same agent, go to the source:
- "This bug is fixed" → read the *current* code path AND, where possible, exercise it (run the function, hit the endpoint, query the DB). The CHANGELOG saying "fixed" is not evidence.
- "The deploy/job/test passes" → pull the *actual run* (`gh run view`, pod exit code via `kubectl get pod -o jsonpath='{.status.containerStatuses[*]}'`, a live test invocation). A green-looking summary is not evidence.
- "vX is in prod" → `kubectl get deploy -o jsonpath=image` + `curl` the live endpoint. The tag existing is not evidence it deployed.
- "It fails because of <theory>" → **reproduce it live** (a one-off test pod, the exact failing command). Today's apk-egress theory was wrong; running it live redirected to the real `sslmode` cause.
- External tool/API behavior in doubt → **cross-section the web** (vendor docs, the tool's source, a direct API call) to confirm e.g. a CLI bug vs. your misuse.

Default each unverified load-bearing claim to **`unverified`** in the report. A claim is `contradicted` when live evidence disagrees with what an agent/doc said — call those out loudly; they're the highest-value findings (an agent declared a smoke test "working as designed" while its run history showed 5/5 failures — the contradiction was the real answer).

## Structured brief (each thread agent returns)
Dense, factual — it's data for an orchestrator, not a user message:
- **findings** — each `{ claim, evidence (cmd output / file:line / URL), evidence_tier, confidence }`
- **evidence_tier** — `primary` (ran the command / read the code / hit the endpoint) vs `secondary` (doc/CHANGELOG/inference)
- **load_bearing** — does this change the answer? (flag the ones to verify)
- **contradictions** — anything that disagrees with the docs or another source
- **could-not-verify** — explicit gaps + why (access, perms, env)

## Depth scaling
| Depth | Threads | Live-verify | Use |
|---|---|---|---|
| quick | 2-3 | spot-check the top 1-2 load-bearing claims live | fast orientation |
| standard | 4-6 | verify all decision-driving claims, 1 live check each | default |
| deep | 6-10 | reproduce/refute each load-bearing claim from a distinct angle; loop until dry | high-stakes (a prod deploy, a launch call) |

## Fan-out mechanics
- Small/standard: parallel `Agent` calls in one message; orchestrate + verify in the main context (you hold the live-probe results).
- Deep, or when verification has structure: author a **Workflow** (`pipeline(threads, investigate, verify)`) so each thread's claims verify as its findings land. (Needs explicit user opt-in / ultracode — invoking this skill at deep depth is that opt-in.)
- Prefer running the load-bearing live check yourself rather than delegating — you've got the cluster/CLI context and won't lose it to a subagent's isolated window.

## Primary-source discipline (internal edition)
- Any decision-driving claim must trace to **primary evidence**: command output, file contents at a line, an endpoint response, a reproduced failure. Otherwise flag it `unverified`.
- Live cluster/API access beats manifests-on-disk for "what's running"; manifests beat docs; docs beat memory. Use the highest tier you can reach and say which you used.
- When a tool misbehaves, suspect *both* your usage and the tool — verify which (e.g. run the raw API call the CLI claims to make).
- Never present a doc/CHANGELOG claim as confirmed. The verdict column is the point.

## Output
Save a report (default `claudedocs/code-research_{slug}_{YYYY-MM-DD}.md`) and print a tight summary:
```
# Code Research: {question}   ({YYYY-MM-DD}, depth={depth})
## Answer            ← conclusion / recommendation first
## Key findings      ← table: claim | evidence | tier | verdict (verified/contradicted/unverified)
## Evidence & analysis
## Contradicted & unverified   ← never omit; the highest-value section
## Recommended actions   ← ordered, with what's blocking vs nice-to-have
## Method            ← threads run, what was probed live, what was unreachable
```

## Anti-patterns
- Don't trust the CHANGELOG/docs/an agent's verdict — verify load-bearing claims live.
- Don't theorize a root cause without reproducing it (the apk-vs-sslmode lesson).
- Don't let one agent investigate everything in one context — surfaces starve.
- Don't scale agents for show — distinct surfaces, not "as many as possible".
- Don't hide contradictions or smooth over uncertainty; the "contradicted & unverified" section is mandatory.
- Don't conflate "tag exists / merged / green summary" with "live and working" — check the running thing.

## Related
- `deep-research` — the web/market sibling (same isolate-then-verify philosophy, external sources).
- `Explore` agents — code-search fan-out (no live probing, no verify pass) — this skill's code threads use them.
- `bug-bash` — after this skill identifies issues, dispatch fixes through bug-bash / kb-developer.
- Workflow tool — orchestration substrate for deep runs.
- `k8s-ops`, `gh-workflows`, `cloudflare-ops`, `forgejo-ops` — the live-probe toolkits the infra threads lean on.
