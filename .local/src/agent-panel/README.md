# agent-panel

A cross-platform tmux chooser for running Claude / AI agents. Lists every tmux
window running an agent, grouped by project, with a live status glyph and a
preview pane — pick one with fzf and jump to it.

Bound in `~/.tmux.conf`:

- `Prefix + g` — interactive chooser (fzf popup)
- `Prefix + G` — jump straight to the next agent needing attention

## Why a binary (replacing the old bash scripts)

This replaces `../tmux/agent-chooser.sh` + `agent-preview.sh`, which only ran on
Linux. Two reasons they broke on macOS:

- They used bash 4 associative arrays (`declare -A`); macOS ships bash 3.2.
- They mapped tmux panes to Claude sessions by walking `/proc`, which macOS lacks.

This binary gets the process tree from `ps -axo pid=,ppid=` (portable across
macOS/BSD and Linux/procps) and does all parsing in pure Rust, so behaviour is
identical on both. **fzf and tmux remain the UI** — only the fragile core was
rewritten.

How an agent is detected is deliberately robust: a pane is a Claude agent when
its process tree contains a pid that has a `~/.claude/sessions/<pid>.json` file.
This works even where tmux reports `pane_current_command` as the Claude version
string rather than `claude` (observed on macOS).

## Subcommands

| Command | Purpose |
|---------|---------|
| `agent-panel` (default) | Interactive chooser; spawns fzf, jumps on selection |
| `agent-panel next` | Cycle to the next attention-needed agent (else next in list) |
| `agent-panel preview --map-file <f> <row>` | Internal fzf preview callback |

## Layout

- `procmap.rs` — `ps`-based process table + pane→Claude pid mapping (the `/proc` replacement)
- `tmux.rs` — `tmux` CLI wrappers (list-panes, capture-pane, switch-client)
- `session.rs` — read `~/.claude/sessions/<pid>.json`; status glyph; JSONL path
- `jsonl.rs` — tail the transcript; row summary + recent-events for the preview
- `render.rs` — project grouping, ANSI fzf rows, preview formatting
- `fzf.rs` — spawn fzf with the rows + preview/next callbacks
- `chooser.rs` — orchestration for the three entry points
- `main.rs` — clap dispatch

## Build & install

Built and symlinked automatically by the dotfiles installer
(`build_local_rust_tools` in `installation_scripts/base_functions.sh`). Manually:

```sh
cargo build --release
ln -sf "$PWD/target/release/agent-panel" "$HOME/.local/bin/agent-panel"
```

Requires `tmux` and `fzf` on `PATH`.

```sh
cargo test     # unit tests (parsing, mapping, rendering)
cargo clippy
```
