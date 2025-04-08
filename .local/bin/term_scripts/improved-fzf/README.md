# Improved FZF Developer Tool

A more responsive and context-aware version of `fzf_dev.sh` with history saving and directory-relevant suggestions.

## Features

- **History Saving**: Remembers your previous commands across sessions
- **Directory-aware Suggestions**: Shows options related to your current directory and project context
- **Smart Caching**: Improves responsiveness by caching directory-specific suggestions
- **Project Detection**: Automatically suggests relevant commands based on detected project types
- **Responsive UI**: Clean interface with previews and helpful navigation hints

## Requirements

- [fzf](https://github.com/junegunn/fzf) must be installed on your system
- Bash shell environment

## Installation

1. Clone this repository or download the script:

```bash
git clone https://github.com/yourusername/improved-fzf.git
cd improved-fzf
```

2. Make the script executable:

```bash
chmod +x fzf_dev.sh
```

3. For convenience, add an alias to your `~/.bashrc` or `~/.zshrc`:

```bash
echo "alias fzd='source /path/to/improved-fzf/fzf_dev.sh'" >> ~/.bashrc
source ~/.bashrc
```

## Usage

Simply run the script or use the alias if you configured one:

```bash
./fzf_dev.sh
```

or

```bash
fzd
```

### Navigation

- Up/Down arrows: Navigate through suggestions
- Enter: Execute selected command
- Ctrl+C: Cancel and exit

### How It Works

1. The script combines your command history with contextual suggestions based on your current directory
2. History entries are given higher priority in the suggestion list
3. The script detects project types (Node.js, Python, Go, Docker, etc.) and suggests relevant commands
4. Recent and frequently used files are included in suggestions
5. Each command you execute is saved to history for future use

## Customization

You can modify these variables at the top of the script:

- `HISTORY_FILE`: Location of the history file (default: `$HOME/.fzf_dev_history`)
- `MAX_HISTORY_ENTRIES`: Number of history entries to keep (default: 1000)
- `SEARCH_DEPTH`: How deep to search for directory context (default: 3 levels)

## License

MIT
