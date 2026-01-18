# Tmux Integration Scripts

Scripts for tmux session management, agent orchestration, and productivity workflows.

## Scripts

| Script | Keybinding | Description |
|--------|------------|-------------|
| `launcher.sh` | `Prefix+l` | Master menu for all tmux operations |
| `sessionizer.sh` | `Prefix+f` | Fast project directory switcher with fzf |
| `agent-chooser.sh` | `Prefix+g` | View and select Claude agent windows |
| `agent-starter.sh` | `Prefix+e` | Spawn new Claude agent in a directory |
| `spawn-project.sh` | `Prefix+p` | Create new tmux session with nvim |
| `claude-status.sh` | Status bar | Shows Claude agent status in tmux status line |

## Usage

All scripts are bound to tmux keybindings via `~/.tmux.conf`.

### Quick Reference

- **Switch projects**: `Prefix+f` → fuzzy find directories
- **Launch menu**: `Prefix+l` → unified launcher
- **Start agent**: `Prefix+e` → spawn Claude in directory
- **View agents**: `Prefix+g` → choose active agent windows

## Status Line Integration

`claude-status.sh` runs every 3 seconds to display agent status:
- `!n` = needs attention (n agents)
- `~n` = working (n agents)
- `·n` = idle (n agents)
