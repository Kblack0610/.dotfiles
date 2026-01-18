# FZF Utilities

Shell scripts leveraging fzf for enhanced productivity.

## Scripts

| Script | Alias | Description |
|--------|-------|-------------|
| `dev.sh` | `f` | Fuzzy find and navigate to project directories |
| `history.sh` | `h` | Search shell command history with fzf |

## Usage

Source these scripts via shell aliases defined in `~/.commonrc`:

```bash
alias f=". $HOME/.local/src/fzf/dev.sh"
alias h=". $HOME/.local/src/fzf/history.sh"
```

### dev.sh (`f`)

Quickly navigate to project directories:
1. Type `f` in terminal
2. Fuzzy search your projects
3. Select to cd into directory

### history.sh (`h`)

Search and execute previous commands:
1. Type `h` in terminal
2. Fuzzy search command history
3. Select to execute or edit command
