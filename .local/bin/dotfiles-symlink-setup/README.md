# Symlink Factory

A flexible bash script to create symlinks for configuration files (like windsurf and cursor rules) across multiple directories.

## Features

- Symlink multiple files to multiple target directories in one command
- Read source files and target directories from text files
- Force overwrite option with backup capability
- Verbose mode for detailed output
- Dry-run mode to preview changes without making them
- Color-coded output for better readability

## Usage

### Basic usage

```bash
./symlink_factory.sh windsurf.rules cursor.rules ~/.config/rules/ /etc/rules/
```

### quick command
./symlink_factory_fixed.sh --files-list ~/.dotfiles/ai/source_files.txt --dirs-list ~/.dotfiles/ai/target_dirs.txt

### Using file lists

You can define your source files and target directories in text files:

```bash
./symlink_factory.sh --files-list example_files.txt --dirs-list example_dirs.txt
```

### Integration with dotfiles

This script is designed to integrate with your existing dotfiles structure at `~/.dotfiles/.local/bin/installation_scripts/`. You could add it to your installation scripts or use it standalone.

Example integration into your dotfiles installation system:

```bash
# In your install_requirements_functions.sh or similar
install_symlinks() {
  echo "Installing symlinks for config files..."
  
  # Path to your symlink factory script
  local symlink_script="$HOME/.dotfiles/.local/bin/symlink_factory.sh"
  
  # Path to your file lists
  local files_list="$HOME/.dotfiles/config/symlink_files.txt"
  local dirs_list="$HOME/.dotfiles/config/symlink_dirs.txt"
  
  # Run symlink factory
  $symlink_script -f -b -v --files-list "$files_list" --dirs-list "$dirs_list"
}
```

## Options

```
  -h, --help                Display this help message
  -f, --force               Force overwrite of existing symlinks
  -v, --verbose             Enable verbose output
  -b, --backup              Create backup of existing files before overwriting
  -s, --source-dir DIR      Source directory (default: current directory)
  -n, --dry-run             Show what would be done without making changes
  --files-list FILE         Read source files from FILE (one per line)
  --dirs-list FILE          Read target directories from FILE (one per line)
```

## File list format

Each line in a file list contains one file path or directory path. Empty lines and lines starting with `#` are ignored.

Example files list:
```
# Windsurf rules
/home/kblack0610/.dotfiles/rules/windsurf.rules

# Cursor rules
/home/kblack0610/.dotfiles/rules/cursor.rules
```

Example directories list:
```
# Config directories
/home/kblack0610/.config/rules
/home/kblack0610/.local/share/rules
```
