# Architecture

Two projects share this repo: notes-cockpit (below) and [agent-runtime](#agent-runtime). Features and status of both: [overview.md](overview.md).

# notes-cockpit

What the cockpit is made of and how a key press reaches code. Panel authoring rules: `.local/src/tmux/CONVENTIONS.md`.

## Layers

```
server   one per socket   hub, lab, ...      .config/tmux-servers/<world>.conf, servers.sh (tmx)
  session                                     sessionizer.sh, worktree.sh (wt), editor.sh
    window                                    tags.sh (tmux-tags), window-name.sh
      pane / popup                            panels bound in .tmux.conf
```

- `.tmux.conf` is the one binding table. Every `bind` runs a script under `.local/src/tmux/`, `.local/bin/` or a `tmx` verb. `tests/unit/tmux_keys_doc.bats` keeps it equal to the Keys table in `.local/src/tmux/README.md`.
- `servers.sh` (`tmx`) owns the server layer: `ensure` creates the sessions a manifest declares and are missing, `hop`, `toggle`, `root`, `goto` and `land` move the client, `reload` re-sources `.tmux.conf` on every live world.
- `worlds.sh` (`tmux-world`) is the only reader of the manifests. It never asks tmux, so the answer to "where does this directory belong" is the same whether the world is up or not. First match wins: a manifest-named directory, then any linked worktree (the `@agents` world), then the deepest `@repos`, then the caller's own world. Format and rules: `.config/tmux-servers/README.md`.
- `panel-lib.sh` is the floor every panel sources: palette, fzf dialect, geometry classes, `panel_fail` vs `panel_die`, `$TMUX` handling. `_skeleton.sh` is a runnable template.
- `tests/panels.manifest` has one row per `display-popup` bind (key, kind, geometry, path). Closure with `.tmux.conf` is checked both ways, so a panel without a row fails the fast tier.
- Rust parts are separate crates under `.local/src/`: `agent-panel`, `hub-tui` (the `hub` binary), `muxpoon` (a submodule). They are built into `~/.local/bin` by the installer.
- State that outlives a session stays out of this tree: tags are server-lifetime options, and `fleet-dispatch record` keeps the pane map under `~/.agent/dispatch/panes/`.

## Data flow for a key

1. `Prefix+f` matches `bind f` in `.tmux.conf`, which opens `display-popup -E` running `sessionizer.sh` by absolute path.
2. The script sources `panel-lib.sh`, builds its rows, and renders them in fzf.
3. On Enter it asks `tmux-world route <dir>` for the world and session, then calls `tmx goto <world> <session>`, which ensures the world and hops the client.

## Tests

Three tiers in `tests/` (`tests/Makefile` is the entry point, `.github/workflows/tests.yml` the CI):

- `unit`: sourced bash functions, no subprocess, no tmux server. Host-safe.
- `integ`: the `$SELF --verb` contract of each script as a subprocess. Host-safe.
- `ui`: real tmux servers driven with real keys. Container only: `make -C tests test-ui` hands off to `tests/docker.sh`, and the tier refuses to run on a real account because a stray `kill-server` would take out live sessions.

## Standards

- Panel rules and the test that enforces each one: `.local/src/tmux/CONVENTIONS.md`, "What is enforced, and where".
- Repo-wide shell rules are checked by `tests/lint.sh` (shellcheck, shfmt, house rules).
- The shared agent-runtime standards: `.local/src/docs/standards.md`. Stage and system criteria this repo is held to: `.local/src/docs/stages.md`, `.local/src/docs/systems.md`.

# agent-runtime

How agent work is run, recorded and read. The fleet-wide picture with its diagram is `~/.config/agentctl/ARCHITECTURE.md` (private overlay); this page is the part that lives in this repo. Each plane has one producer, one document, and views that render the document without recomputing it.

## Planes

| Plane | Producer (code in this repo) | Document | Views |
|---|---|---|---|
| Runners | `agentctl` turns `agents/<name>.conf` into `agentctl@<name>.service` plus a timer; `agentctl-run` starts every model | `~/.local/state/agentctl/<name>/last-outcome`, one of `WORKED NOOP BLOCKED FAILED STALLED`, written by `proof_report` in `.local/lib/agent-proof.sh` | `agentctl list`, the `fleet-liveness` watch |
| Work | `agent-queue` (only writer) and `fleet-dispatch run` (starts items) | `~/.agent/queue/<state>/*.md`, one file per item, a transition is one `mv` | `agent-queue list`, hub Queue tab, agent-web, `fleet-bench` |
| Sessions | `fleet-sessions tick` and `--write`, under `flock`, by atomic rename | `~/.local/state/fleet/state.json` (schema: `.local/src/docs/fleet-states.md`) | hub Sessions tab, `fleet.sh`, `agent-mqtt-publish` |
| Evals | `agentctl-session-outcomes` and `fleet-bench`, no model | `~/.agent/outcomes/<project>/`, `calls.jsonl` | `fleet-bench` scorecard, the briefing |
| Asks | `agent-ask` | one file per ask, pending until answered or cancelled | agent-panel, agent-web, hub |

## One model call

1. A runner's conf names `COMMAND`, `ROLE`, `ROUTE` and `DATA_CLASS`. `agentctl@.service` loads the conf as environment and runs the command.
2. The command calls `agentctl-run` (`.local/src/agent-run/agentctl-run`). With `--agent <name>` it reads the agent's conf first (`lib/agent.sh`), whose role, model, route, data class and harness replace what a parent left in the environment.
3. It scrubs transport variables before the role loads (`lib/scrub.sh`), so an ambient model id cannot satisfy the model-family check, then declares `CLAUDE_HEADLESS=1`.
4. `lib/role.sh` loads the role (`ROLE_WRITE`, `ROLE_TASK`, `ROLE_BASH`, `ROLE_MCP`, `ROLE_APPROVE`). A missing key, an unknown role or a harness that cannot enforce the denials is a refusal, never a default.
5. `lib/route.sh` resolves the route (`routes/` here for the public one, the overlay for the rest) and `lib/budget.sh` checks the caps against `calls.jsonl`.
6. A harness adapter (`harnesses/claude.sh`, `opencode.sh`, `raw.sh`; `binks.sh` is a stub that refuses) execs the model. `lib/calls.sh` appends one line to `calls.jsonl`.

## Work to a merged PR

1. `agent-queue add` files an item (and its board row). `fleet-dispatch run` starts the head as an interactive session through `fleet-dispatch start`, the one start path.
2. The session works in a worktree under `~/.worktrees/` and opens a PR.
3. `agent-land <pr>` checks that HEAD contains `origin/<base>`, waits for the checks, squash-merges with `--match-head-commit`, proves the merge commit is on the base (`.local/lib/agent-merge-proof.sh`), moves the item to `done/<date>/` and closes the board row.
4. `fleet-sessions` reads the result into the state document; `agentctl-session-outcomes` and `fleet-bench` score it later.

## Where it is split

- Public repo: the code above, `routes/subscription.route`, the Rust crates (`agent-panel`, `agent-web`, `hub-core`, `hub-tui`) and the tests.
- Private overlay: runner confs, roles, the unit template `agentctl@.service`, site routes, prompts and the runbooks. Both are stowed into `$HOME`. A change that touches both is two PRs.
- Runtime state stays out of both trees: `~/.agent/`, `~/.local/state/agentctl/`, `~/.local/state/fleet/`.

## Tests

The same tiers as the cockpit (`tests/Makefile`, `.github/workflows/tests.yml`), plus `make -C tests test-rust` for the crates. The runtime's own contract tests are `tests/unit/runner_contract.bats`, `tests/integ/agent_run_*.bats`, `tests/integ/agent_queue.bats`, `tests/integ/agentctl_*.bats`, `tests/unit/agent_land.bats`, `tests/unit/fleet_dispatch.bats`, `tests/unit/fleet_sessions.bats`, `tests/unit/pipelines_doc.bats` and `tests/unit/standards_doc.bats`.

## Standards

- Invariants, each with its why and the test that holds it: `.local/src/docs/standards.md` (a headless run goes through `agentctl-run`, one `last-outcome` word per pass, one state document per plane, runners only shrink, no model scores a transcript).
- Stage and system criteria: `.local/src/docs/stages.md`, `.local/src/docs/systems.md`.
