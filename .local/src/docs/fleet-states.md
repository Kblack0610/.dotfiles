# Fleet state: the document and its vocabulary

Every view of the agent fleet (phone and Home Assistant, the shepherd, fleet-bench) reads one file instead of working session state out for itself:

```
~/.local/state/fleet/state.json        ($FLEET_STATE_FILE)
```

`fleet-sessions --write` is the only writer. It runs on two triggers:

| Trigger | When | Why |
| --- | --- | --- |
| `fleet-state.path` | `agent-ask` posts, answers or cancels an ask (it rewrites `~/.agent/asks/.changed`) | A new ask shows as NEEDS within seconds |
| `fleet-bench sample` | every 10 minutes (agentctl runner `fleet-bench`) | Backstop for everything without a change event: git, gh, plan files |

The document is built beside the target and renamed into place, so a reader never sees half of one. A pass that started before the document on disk was generated leaves it alone, so a slow pass cannot overwrite a newer one. `agent-mqtt-sessions.path` watches the file and republishes to Home Assistant when it changes.

## Two fields, never one word

A session has two independent states, and no surface may fold them into one word:

- **`activity`** is what the Claude process is doing right now, read from agent-panel. It changes many times a minute.
- **`bucket`** is where the session is in its delivery: does it need the human, has it landed, is it stuck. It is derived from git, gh, the plan file and the ask queue, and changes a few times an hour.

An `idle` session can be NEEDS (an ask is open), LANDED (start the next phase) or STALLED (a green PR nobody merged). Reading "idle" as "done" was the mistake this split exists to stop: `claude-status.sh` used to count idle panes as `done`.

The document holds `activity` as of `generated_at`. A view that needs it live (the tmux status line, agent-web, the phone's working/attention counts) reads agent-panel directly and joins `bucket` from the document by `target`. It never computes a bucket itself.

### activity

| Value | Meaning |
| --- | --- |
| `busy` | Mid-turn |
| `waiting` | Blocked on a prompt or a permission in the pane |
| `shell` | Turn ended, a background shell is still running |
| `idle` | Turn ended, nothing running |

### bucket

Decided by `session_bucket` in `.local/bin/fleet-sessions`, in this order (first match wins). The `reason` field carries the detail. A pending ask and an open PR that conflicts with the default branch decide before `activity`: a session busy on other work still waits on its ask, and every run on a PR that cannot merge is wasted.

| Value | Meaning | Who acts |
| --- | --- | --- |
| `NEEDS` | Waiting on a prompt, a pending ask (even while busy), or plan approval | The human |
| `STALLED` | An open PR that conflicts with the default branch (even while busy), or idle with unlanded work: dirty files, commits off the default branch, a red or green-but-unmerged PR, or a merge suspected of turning main red | The shepherd nudges once |
| `WORKING` | Busy, a background shell younger than 2h, a heavy child process, idle under 20m, or a PR whose CI is running | Nobody |
| `LANDED` | Tree clean and the plan has a next phase, or a plan with no `## Phases` checklist and nothing merged | The session starts it |
| `DONE` | Nothing unlanded, no ask of its own open, idle, and either every `## Phases` line ticked or a merged PR with no checklist (one phase of work) | The shepherd winds it down |
| `UNCLEAR` | Not in a git repo, or its PR closed unmerged | A human look |

Thresholds are the `FLEET_*` block at the top of `fleet-sessions`. A red default branch is not a session: it is listed under `main`.

## Schema (version 1)

```
schema            1; bumped when a field changes meaning or is removed
generated_epoch   when the pass that wrote this started (epoch seconds)
generated_at      the same, ISO 8601 UTC
unreadable[]      sources this pass could not read ("agent-panel", "gh pr list (<repo>)", "agent-ask");
                  facts from them are missing, not false
sessions[]        one object per live Claude session: the `fleet-sessions --json` row
main[]            {repo, id, reason, escalated, owners[]}: a default branch whose latest CI run failed,
                  with the live sessions whose merge is a suspect
asks[]            pending asks: {id, project, kind, question (160 chars), task, created, session}
```

A session object carries `bucket`, `reason`, `fact` (bucket + reason + branch, the key the shepherd nudges once per), `activity`, `target`, `pane`, `session_id`, `cwd`, `branch`, `pr`, `pr_state`, `ci`, `behind`, `conflicts`, `dirty`, `ahead`, `idle_min`, `context_tokens`, `plan_file`, `phases_done`, `phases_total`, `next_phase`, `finished`, `labels[]`, `dispatch`, `nudged`, `escalated`, `owners[]`, `asks` (pending asks this session posted, matched on the ask's `claude_session` only), `blockers[]` (every reason `finished` is false, empty when it is true). A fact the pass could not establish is `null`.

Adding a field does not bump `schema`. Readers ignore fields they do not know.

## Readers

| Reader | Reads |
| --- | --- |
| `agent-mqtt-publish` | `bucket` per session (joined to agent-panel's live list by `target`), `generated_at` |
| `fleet-bench sample` | Writes the document itself and records the same rows as progress lines |

Runner and watch state are not in the document: each already has one contract file (`~/.local/state/agentctl/<name>/last-outcome`, `~/.local/state/watch-companion/<name>.state`).
