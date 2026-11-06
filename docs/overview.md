# notes-cockpit overview

The tmux cockpit: a set of tmux servers, key-bound popup panels and small CLIs that turn one terminal into the working surface for notes, worktrees, agent sessions and the fleet. It lives in the dotfiles repo (`.tmux.conf`, `.local/src/tmux/`, `.config/tmux-servers/`, `tests/`). The shape is in [architecture.md](architecture.md), shipping it in [operations/deploy.md](operations/deploy.md), every key in `.local/src/tmux/README.md`.

## Features

- Worlds: each world is a tmux server on its own socket (`hub`, `lab`, plus private ones), so one `kill-server` takes out one world. `tmx` hops, toggles and repairs them (`Prefix+H`, `Prefix+C-h`, `Prefix+N`).
- Routing: a directory belongs to a world by the manifests in `.config/tmux-servers/`, asked through `tmux-world route <dir>`.
- Finders: `sessionizer.sh` (`Prefix+f`) opens a repo or worktree as a session, `sesh` (`Prefix+S`) lists the current world, `projects.sh` (`Prefix+p`) lists projects with stage and open counts.
- Worktrees: `wt new` and `wt done` (`Prefix+F`, `Prefix+X`) cut a worktree under `~/.worktrees/` with its own session and reap it again.
- Agent surfaces: `agent-panel` (`Prefix+g`, `Prefix+G`), `questions.sh` (`Prefix+y`), `fleet.sh` (`Prefix+C-g`), `hub` (`Prefix+i`), and the scratch Claude (`Prefix+A`).
- Window tags (`tags.sh`, `tmux-tags`) and one editor window per session (`editor.sh`, `Prefix+Space`).
- Recovery: `fleet-dispatch record` and `restore` bring a dead world's conversations back.

## Status

- In daily use on the human's Linux workstation, shared with a Mac, so panels avoid GNU-only calls (`CONVENTIONS.md`).
- Under test: unit and integ tiers on every PR, a tmux ui tier in a container (`docs/architecture.md`, "Tests").
- Stage and its gaps: `project-stage-check notes-cockpit`. Not yet measured: a perf baseline on the real target and a deploy workflow that runs on merge (`operations/deploy.md` says why).
