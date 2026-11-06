# Deployment

Two projects share this repo: the [cockpit](#deploying-the-cockpit) and [agent-runtime](#deploying-agent-runtime).

# Deploying the cockpit

There is no server and no release. The cockpit is files in the dotfiles repo, and "deploy" means those files are linked into `$HOME` and the running tmux servers have re-read them.

## Target

The human's own machines (Linux workstation and a Mac). Stow links each tracked file into `$HOME` individually (`stow --no-folding .`), so `~/.tmux.conf`, `~/.local/src/tmux/*` and `~/.config/tmux-servers/*` point at the main checkout, `~/.dotfiles`. Paths stow must not link are listed in `.stow-local-ignore`. Rust binaries (`agent-panel`, `hub`) are built by the installer's `build_local_rust_tools` and linked into `~/.local/bin`.

## Ship a change

1. Land it on `main` through a PR. CI (`.github/workflows/tests.yml`) runs the unit and integ tiers, the ui tier in a container, the Rust gate, skill lint and shellcheck.
2. Update the main checkout: `git -C ~/.dotfiles pull`. A new file needs `cd ~/.dotfiles && stow --no-folding .` to get its link; edits to a linked file are live with no step.
3. Rebuild a Rust part if its crate changed: `cargo build --release` in its directory (the symlink in `~/.local/bin` already points at `target/release/`).
4. Re-read the config on every live world: `Prefix+r`, or `tmx reload`. Scripts run fresh on each key, so they need nothing more.
5. Add a new world or repair a missing session with `tmx ensure <world>`. It only creates what is missing.

A worktree is not the deployed copy: links point at the main checkout, so run a script from a worktree by its path to try it. Never test the ui tier on the host (`make -C tests test-ui` runs it in the container).

## Roll back

Revert the PR on `main` (a new revert PR, never a rewrite of pushed history), pull in `~/.dotfiles`, then `tmx reload`. A world whose server died is brought back with `fleet-dispatch restore` (`.local/src/tmux/README.md`, "When a world's server dies").

## Not yet in place

- No deploy workflow runs on merge: the forge API check for it is still "not yet" in `.local/src/docs/stages.md`, and a pull plus `tmx reload` is the whole deploy.
- No perf baseline on the target. Worktree creation cost is measured by hand (`.local/src/tmux/README.md`, "Measuring it again").
- Secrets: none are held by this tree. Machine-local state (`~/.config/tmux-servers/hidden`, the dispatch pane map) is per machine and never synced.

# Deploying agent-runtime

Same shape as the cockpit: no server and no release. The runtime is files in two repos (this one and the private overlay), stowed into `$HOME`, plus the `systemd --user` units `agentctl reload` generates.

## Target

The human's Linux workstation, where the runners, queue and dispatch run unattended with `loginctl enable-linger` so they survive logout. Code reaches `~/.local/bin` and `~/.local/src/agent-run/` by stow. Runner confs, roles, routes and the unit template `agentctl@.service` come from the private overlay at `~/.config/agentctl/` and `~/.config/systemd/user/`. Timers are generated into `~/.config/systemd/user/` and are not tracked. The Rust views (`agent-web`, `hub`, `agent-panel`) are built by `build_local_rust_tools` and linked into `~/.local/bin`; `agent-web.service` runs the first.

## Ship a change

1. Land it on `main` through a PR (`agent-land <pr>` for a queue item). CI runs the fast tiers, the Rust gate and skill lint. A change to the private overlay is its own PR in that repo.
2. Pull the checkout that stow points at: `git -C ~/.dotfiles pull`, and the same for `~/.dotfiles-private`. A new file needs `stow --no-folding .` in that repo to get its link.
3. After a conf, role or timer change: `agentctl reload`. It validates confs, skips an invalid one (shown by `agentctl list` under "invalid"), regenerates timers and runs `daemon-reload`.
4. After a Rust crate change: `cargo build --release` in the crate, then `systemctl --user restart agent-web` if that is the crate. The `hub` TUI picks up the new binary on its next start.
5. Check: `agentctl list` for each runner's verdict and next run, `agentctl status <name>` for one, `fleet-sessions --json` for the sessions.

A worktree is not the deployed copy: links point at the main checkout, so run a script from a worktree by its path. Do not start a live model call or a daemon from a test on the host.

## Stop and roll back

- Stop everything: `agentctl pause [reason]` (no oneshot starts until `agentctl resume`; `sentinel` keeps watching). One runner: `agentctl disable <name>`.
- Caps: a runner over its budget exits 75 and pages once; `agentctl budget <name> raise <usd>` lifts it until midnight.
- Roll back by reverting the PR on `main` (a new revert PR, never a rewrite of pushed history), pulling in the checkout, and running `agentctl reload`.

## Not yet in place

- No deploy workflow runs on merge: the forge API check for it is still "not yet" in `.local/src/docs/stages.md`, and a pull plus `agentctl reload` is the whole deploy.
- No perf baseline on the target. Spend and call volume are watched instead (`~/.config/agentctl/SENTINEL.md`, "Spend alerts").
- Secrets: none are held by either tree. Route and gateway keys are machine-local files under `~/.local/state/`, per machine and never synced; there is no `secrets-sync --check` yet (stage row "P4").
