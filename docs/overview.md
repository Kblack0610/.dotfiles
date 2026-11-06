# Overview

Two projects share this repo and this docs tree: [notes-cockpit](#notes-cockpit) (the tmux working surface) and [agent-runtime](#agent-runtime) (the fleet that runs agent work). Shape: [architecture.md](architecture.md). Shipping: [operations/deploy.md](operations/deploy.md).

## notes-cockpit

The tmux cockpit: a set of tmux servers, key-bound popup panels and small CLIs that turn one terminal into the working surface for notes, worktrees, agent sessions and the fleet. It lives in the dotfiles repo (`.tmux.conf`, `.local/src/tmux/`, `.config/tmux-servers/`, `tests/`). Every key is in `.local/src/tmux/README.md`.

### Features

- Worlds: each world is a tmux server on its own socket (`hub`, `lab`, plus private ones), so one `kill-server` takes out one world. `tmx` hops, toggles and repairs them (`Prefix+H`, `Prefix+C-h`, `Prefix+N`).
- Routing: a directory belongs to a world by the manifests in `.config/tmux-servers/`, asked through `tmux-world route <dir>`.
- Finders: `sessionizer.sh` (`Prefix+f`) opens a repo or worktree as a session, `sesh` (`Prefix+S`) lists the current world, `projects.sh` (`Prefix+p`) lists projects with stage and open counts.
- Worktrees: `wt new` and `wt done` (`Prefix+F`, `Prefix+X`) cut a worktree under `~/.worktrees/` with its own session and reap it again.
- Agent surfaces: `agent-panel` (`Prefix+g`, `Prefix+G`), `questions.sh` (`Prefix+y`), `fleet.sh` (`Prefix+C-g`), `hub` (`Prefix+i`), and the scratch Claude (`Prefix+A`).
- Window tags (`tags.sh`, `tmux-tags`) and one editor window per session (`editor.sh`, `Prefix+Space`).
- Recovery: `fleet-dispatch record` and `restore` bring a dead world's conversations back.

### Status

- In daily use on the human's Linux workstation, shared with a Mac, so panels avoid GNU-only calls (`CONVENTIONS.md`).
- Under test: unit and integ tiers on every PR, a tmux ui tier in a container (`architecture.md`, "Tests").
- Stage and its gaps: `project-stage-check notes-cockpit`. Not yet measured: a perf baseline on the real target and a deploy workflow that runs on merge (`operations/deploy.md` says why).

## agent-runtime

The agent runtime itself: the machinery that takes a piece of agent work from intake to a merged PR and records what happened, mostly with no human attached. The code is in this repo (`.local/bin/agent*`, `.local/bin/fleet-*`, `.local/src/agent-run/`, `.local/src/{agent-panel,agent-web,hub-core,hub-tui}/`, `.local/lib/`, `tests/`). Runner confs, roles, routes and the runbooks sit in the private overlay and show up at `~/.config/agentctl/`.

### Features

- Runners: one conf per runner becomes a `systemd --user` service and timer. `agentctl list`, `status`, `start`, `stop`, `enable`, `disable`, `pause`, `resume`, `logs`, `reload`, `budget` manage them (`~/.config/agentctl/README.md` has the conf schema and lanes).
- One launcher for every model call: `agentctl-run` resolves a role (what the agent may do), a route (whose wire and data) and a harness (`claude`, `opencode`, `raw`) into one invocation, and refuses when it cannot enforce the role (`.local/src/agent-run/docs/contract.md`).
- Budgets: each automated call carries a per-call cap, a per-day cap and a calls-per-hour cap, checked from `calls.jsonl` before the call (`.local/src/agent-run/lib/budget.sh`). Over one, the run is BLOCKED and exits 75.
- Work queue: `agent-queue` is the one intake and the only writer of the store under `~/.agent/queue/`, one file per item, state is the directory.
- Dispatch: `fleet-dispatch run` starts queue items as interactive sessions behind the account, idle and rate gates, and tops the queue up from board rows a judge picks.
- Sessions: `fleet-sessions` computes each session's bucket and writes the state document every view renders (`fleet-states.md`). `fleet-shepherd` nudges stalled ones.
- Asks: `agent-ask` is the two-way queue a headless agent uses to ask the human a question and read the answer.
- Landing: `agent-land <pr>` waits for checks, squash-merges the validated head, records the PR on the queue item and closes its board row.
- Evals with no model in them: `agentctl-session-outcomes` and `fleet-bench` score sessions from transcript structure, git and gh.
- Views: the `hub` TUI, `agent-web`, `agent-panel`, waybar chips and a Home Assistant feed (`agent-mqtt-publish`).

### Status

- In daily use. The confs, queue, dispatch, shepherd and evals run unattended on the human's workstation.
- Held by tests: `tests/unit/runner_contract.bats` (no direct `claude -p`), `tests/integ/agent_run_budget.bats`, `tests/integ/agent_queue.bats`, `tests/unit/agent_land.bats`, `tests/unit/fleet_dispatch.bats`, `tests/unit/pipelines_doc.bats`.
- Invariants, each with the test that fails when it breaks: `.local/src/docs/standards.md`.
- Stage and its gaps: `project-stage-check agent-runtime`. Not yet in place: a deploy workflow that runs on merge and a perf baseline on the target (`operations/deploy.md`).
