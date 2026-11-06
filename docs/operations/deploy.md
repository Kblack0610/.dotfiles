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
