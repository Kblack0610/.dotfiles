# Tmux Integration Scripts

Scripts for tmux session management, agent orchestration, and productivity workflows.

## Scripts

| Script | Keybinding | Description |
|--------|------------|-------------|
| `launcher.sh` | `Prefix+l` | Master menu for all tmux operations |
| `sessionizer.sh` | `Prefix+f` | Fast project directory switcher with fzf |
| `agent-panel` (Rust) | `Prefix+g` / `Prefix+G` | View/select Claude agent windows (`G` = jump to next needing attention). Cross-platform binary; see `../agent-panel/`. |
| `agent-starter.sh` | `Prefix+e` | Spawn new Claude agent in a directory |
| `spawn-project.sh` | `Prefix+p` | Create new tmux session with nvim |
| `favourites.sh` | `Prefix+s` / `Prefix+o` | Star a claude/opencode chat; reopen & resume it later |
| `tags.sh` | `Prefix+T` / `Prefix+w` / `Prefix+W` | Tag windows important/pinned/agent or group them; also on PATH as `tmux-tags` |
| `claude-status.sh` | Status bar | Shows Claude agent status in tmux status line |

## Usage

All scripts are bound to tmux keybindings via `~/.tmux.conf`.

### Quick Reference

- **Switch projects**: `Prefix+f` → fuzzy find directories
- **Launch menu**: `Prefix+l` → unified launcher
- **Start agent**: `Prefix+e` → spawn Claude in directory
- **View agents**: `Prefix+g` → choose active agent windows
- **Favourite a chat**: `Prefix+s` → star the agent in the current pane
- **Reopen a chat**: `Prefix+o` → pick a favourite, resume the conversation
- **Tag a window**: `Prefix+T` then `i`/`p`/`a`/`g` → important / pinned / agent / group
- **Find a tagged window**: `Prefix+w` (all, tag column) · `Prefix+C-w` (tagged only) · `Prefix+W` (fzf)

## Window Tags

`tags.sh` (on PATH as `tmux-tags`) marks windows so you, your scripts, and your
agents can tell them apart. A tag is a tmux **window user-option** (`@tag_*`),
not part of the window name: the `.zshrc` precmd hook rewrites window names to
the git branch on every prompt, so a name-based marker never survives.

- `Prefix+T` then `i` important · `p` pinned · `a` agent · `g` group:<name> ·
  `x` clear · `l` list. It is a native one-shot key table, so one key and you
  are back to normal.
- Status bar shows `*` for important and `+` for pinned.
- `Prefix+w` is the window chooser with a tag column; `Prefix+C-w` filters to
  tagged windows only; `Prefix+W` is an fzf picker (type a tag to filter).

Scripts and agents query it:

```sh
tmux-tags ls --json                    # every tagged window, structured
tmux-tags targets --tag important      # bare @N ids, one per line
tmux-tags protected -t @66             # exit 0 if pinned/important
tmux-tags gather --tag group:work --into work   # a tag is a group
```

`cleanup.sh`, `stale-detector.sh` and `wind-down.sh` all refuse to kill a window
tagged `pinned` or `important`.

Tags are **server-lifetime only** - they do not survive `tmux kill-server` or a
reboot. That is deliberate; for windows that should come back tagged, declare
them in the session manager's config and have the window tag itself on startup.

## Session Favourites

`favourites.sh` bookmarks a *specific* claude/opencode conversation so you can
resume it later — even after its window has closed or the agent exited
(`agent-chooser.sh` only lists **live** panes).

- `Prefix+s` — star the agent in the current pane. Claude sessions are read from
  `~/.claude/sessions/<pid>.json` (exact session id); opencode resolves the
  most-recent session for the pane's directory (read-only query of
  `~/.local/share/opencode/opencode.db`).
- `Prefix+o` — fzf picker over favourites with a live preview.
  - `Enter` restores: switches to (or creates) a tmux session at the chat's
    directory and resumes it (`claude --resume` / `opencode --session`).
  - `ctrl-x` removes a favourite · `ctrl-r` reloads · `ctrl-a` browses recent
    sessions to star one (handy for chats not currently open).

Registry: `~/.local/state/tmux-favourites/favourites.tsv` (runtime state, not in
the repo). Stale favourites fall back to a fresh agent in the directory.

## Status Line Integration

`claude-status.sh` runs every 3 seconds to display agent status:
- `!n` = needs attention (n agents)
- `~n` = working (n agents)
- `·n` = idle (n agents)
