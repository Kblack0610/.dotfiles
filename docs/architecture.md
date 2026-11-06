# notes-cockpit architecture

What the cockpit is made of and how a key press reaches code. Features and status: [overview.md](overview.md). Panel authoring rules: `.local/src/tmux/CONVENTIONS.md`.

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
