# Archived Scripts

Scripts that are no longer actively used but preserved for reference or potential future use.

## Archived Scripts

| Script | Original Purpose | Why Archived |
|--------|------------------|--------------|
| `launch_agents.sh` | Batch launch Claude agents | Not referenced in configs |
| `tmux_session_starter.sh` | Start tmuxinator projects | Replaced by launcher.sh menu |
| `tmux_spawn_server.sh` | Spawn API/web dev servers | Commented out in tmux.conf |
| `tmux_nvim_spawner.sh` | Open nvim in repo root | Commented out in tmux.conf |
| `tmux_claude_viewer.sh` | View Claude agent logs | Migrated to waybar click handler |
| `tmux_session_chooser.sh` | Choose tmux sessions | Superseded by built-in tmux features |

## Restoration

To restore a script to active use:

1. Move it to the appropriate directory (`tmux/`, `fzf/`, etc.)
2. Rename following current conventions (dash-separated: `my-script.sh`)
3. Update references in:
   - `~/.tmux.conf` (for tmux keybindings)
   - `~/.commonrc` (for shell aliases)
   - `~/.config/fish/config.fish` (for fish abbreviations)

## Archive Date

Scripts archived: 2026-01-18 during term_scripts reorganization.
