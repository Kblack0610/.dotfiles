# Tmux Suite

Tmux productivity suite with agent orchestration, session management, PR viewer, and status dashboards. **1,800+ lines** of battle-tested shell scripts for power users.

## Features

- 🤖 **AI Agent Integration** - Manage Claude, Codex, Gemini, OpenCode, and Aider agents across tmux windows
- 📊 **PR Dashboard** - Interactive PR viewer with live CI/CD status (14KB script!)
- 🚀 **Project Switcher** - Fast fuzzy project navigation with fzf
- 🧹 **Session Management** - Cleanup, monitoring, and housekeeping tools
- 📈 **Status Bar** - Real-time agent status in tmux status line

## Quick Start

```bash
git clone https://github.com/Kblack0610/tmux-suite.git ~/.local/src/tmux-suite

# Add keybindings to ~/.tmux.conf (see Configuration section)
# Then reload: tmux source-file ~/.tmux.conf
```

## Scripts

| Script | Size | Keybinding | Description |
|--------|------|------------|-------------|
| `pr-viewer.sh` | 14KB | - | Interactive PR dashboard with live CI status |
| `agent-chooser.sh` | 8KB | `Prefix+g` | View and select AI agent windows |
| `dashboard.sh` | 7KB | - | Comprehensive tmux dashboard view |
| `agent-summary-daemon.sh` | 5KB | - | Background agent state tracker |
| `agent-status.sh` | 5KB | Status bar | Real-time agent status display |
| `cleanup.sh` | 4KB | - | Clean up stale sessions/windows |
| `stale-detector.sh` | 3.6KB | - | Detect idle sessions |
| `history-capture.sh` | 3.3KB | - | Capture command history |
| `launcher.sh` | 2.3KB | `Prefix+l` | Master menu for all operations |
| `spawn-project.sh` | 1.2KB | `Prefix+p` | Create new tmux session with nvim |
| `sessionizer.sh` | 1.2KB | `Prefix+f` | Fast project directory switcher |
| `agent-starter.sh` | 1.5KB | `Prefix+e` | Spawn a new agent CLI |

## Installation

```bash
# Clone
git clone https://github.com/Kblack0610/tmux-suite.git ~/.local/src/tmux-suite

# Add to ~/.tmux.conf
bind-key f run-shell "tmux neww ~/.local/src/tmux-suite/sessionizer.sh"
bind-key g run-shell "~/.local/src/tmux-suite/agent-chooser.sh"
bind-key e run-shell "~/.local/src/tmux-suite/agent-starter.sh"
bind-key p run-shell "~/.local/src/tmux-suite/spawn-project.sh"
bind-key l run-shell "~/.local/src/tmux-suite/launcher.sh"

# Status bar
set-option -g status-right "#(~/.local/src/tmux-suite/agent-status.sh)"
set-option -g status-interval 3

# Reload
tmux source-file ~/.tmux.conf
```

## Usage

### Quick Reference

- `Prefix+f` - Fuzzy find and switch projects
- `Prefix+g` - Choose AI agent window
- `Prefix+e` - Start a new agent CLI
- `Prefix+p` - Spawn new project session
- `Prefix+l` - Open master launcher menu

### PR Viewer

```bash
# Configure repos in pr-repos.conf
echo "my-app|username/my-app|main" >> pr-repos.conf

# Run viewer
./pr-viewer.sh
```

Interactive commands: `j/k` (navigate), `Enter` (open), `r` (refresh), `q` (quit)

### Agent Summary Daemon

```bash
./agent-summary-daemon.sh start  # Start background tracker
```

### Status Bar

Status indicators:
- `!n` = needs attention (n agents)
- `~n` = working (n agents)
- `·n` = idle (n agents)

## Configuration

Edit scripts to customize:
- Project directories in `sessionizer.sh`
- Repositories in `pr-repos.conf`
- Agent state detection in `agent-summary-daemon.sh`

## Dependencies

Required: `tmux`, `fzf`, `jq`, `bash`
Optional: `gh` (PR viewer), `claude`, `codex`, `gemini`, `opencode`, `aider` (agent features), `nvim` (spawn-project)

## License

MIT - Use freely!
