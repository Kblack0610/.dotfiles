# Fuzzy Drunk Finder (FDF)

A lightweight, fast directory navigation tool powered by fzf. Navigate your filesystem with ease and precision, even after a few drinks!

Fuzzy finder is great, I was trying to speed things up with some questionable guesses, inferences, and assumptions. This maps your directory with history of most common places you go to help you get there just a little bit faster.

## What's New in Version 1.2.0

- **Modular Structure:** Code has been reorganized into logical modules for easier maintenance
- **Configuration System:** User-customizable settings via configuration files
- **Enhanced Cache Management:** Improved cache system with rebuild option
- **Multiple Installation Methods:** System-wide, user-local, and distribution packages
- **Comprehensive Test Suite:** Automated tests to ensure reliability
- **GitHub Actions Integration:** Continuous testing for quality assurance

## Overview

Fuzzy Drunk Finder provides an intuitive interface for quickly navigating your filesystem using fuzzy search. It's designed to be:

- **Fast**: Near-instant startup time with intelligent caching
- **Intuitive**: Simple, consistent interface
- **Flexible**: Customizable search depth and starting locations
- **Friendly**: Works with hidden files when you need it to
- **Reliable**: Comprehensive test suite ensures everything works as expected

## Installation

### Quick Install (User-Local)

```bash
cd /path/to/fuzzy-drunk-finder
./install.sh
# Select option 1 for user-local installation
```

### System-Wide Installation

```bash
cd /path/to/fuzzy-drunk-finder
./install.sh
# Select option 2 for system-wide installation (requires sudo)
```

### Manual Installation

1. Clone this repository or download the script
2. Make it executable: `chmod +x fuzzy-drunk-finder.sh`
3. Source the script in your shell: `source fuzzy-drunk-finder.sh`

You can add this line to your `.bashrc` or `.zshrc` for permanent access:
```bash
source /path/to/fuzzy-drunk-finder/fuzzy-drunk-finder.sh
```

## Usage

After installation, you can use the `fdf` command:

```bash
# Basic usage - navigate from current directory
fdf

# Start from a specific directory
fdf /home/username/projects

# Include hidden directories
fdf --hidden

# Adjust search depth (default is 3)
fdf --depth 5

# Unlimited depth search
fdf --unlimited

# Disable history tracking
fdf --no-history

# Force rebuild of cache
fdf --rebuild-cache

# Show version information
fdf --version

# Combine options
fdf --hidden --unlimited /usr/local
```

## Additional Commands

```bash
# Display help information
fdf_help

# Clear cache
fdf_clear_cache

# Clear history
fdf_clear_history

# Edit user configuration
fdf_config
```

## Features

- **Simple Navigation**: Quickly find and change to any directory within your search depth
- **Hidden File Support**: Toggle visibility of hidden directories with `--hidden` flag
- **Customizable Depth**: Control how deep the search goes with `--depth N`
- **Unlimited Depth**: Use `--unlimited` for searching without depth limits
- **History Tracking**: Automatically saves and prioritizes your most frequently visited directories
- **Custom Starting Point**: Begin your search from any directory
- **Performance Caching**: Intelligent caching for fast startup and navigation
- **User Configuration**: Customize default behavior through configuration files
- **Debug Mode**: Detailed information for troubleshooting with `--debug`
- **Help System**: Built-in help with `fdf_help`

## Configuration

Fuzzy Drunk Finder supports configuration through several methods:

1. **User Configuration:** `~/.config/fdf/config`
2. **Local Configuration:** `/path/to/fuzzy-drunk-finder/.fdf_config`
3. **System Configuration:** `/etc/fdf/config` (if installed system-wide)

Create or edit your configuration:
```bash
fdf_config
```

Example configuration:
```bash
# Default depth for directory searches
DEPTH=4

# Show hidden directories by default (true/false)
SHOW_HIDDEN=true

# Cache timeout in seconds (3600 = 1 hour)
CACHE_TIMEOUT=7200
```

## Requirements

- [fzf](https://github.com/junegunn/fzf) must be installed
- Bash or compatible shell

## For Developers

### Running Tests

```bash
# Run all tests
cd /path/to/fuzzy-drunk-finder
./tests/run_all_tests.sh

# Run specific test
./tests/test_hidden.sh
```

### Project Structure

- `fuzzy-drunk-finder.sh`: Main script that loads modules
- `lib/`: Directory containing modular components
  - `fdf-core.sh`: Core functionality
  - `fdf-cache.sh`: Cache management
  - `fdf-history.sh`: History tracking
  - `fdf-config.sh`: Configuration system
  - `fdf-help.sh`: Help documentation
- `tests/`: Automated test scripts
- `install.sh`: Installation script with multiple options

### GitHub Actions Integration

The project includes GitHub Actions workflows that automatically run the test suite on:
- Push to main/master branch
- Pull requests to main/master branch

## Tips

- Use tab completion within the fzf interface to quickly navigate deep directories
- The `--depth` parameter lets you control performance vs search comprehensiveness
- For large directory structures, keep the depth lower (2-3) for best performance
- For repositories or project directories, a depth of 4-5 often works well
- Use `--unlimited` with caution in large directory structures (like `/` or `/home`) as it can be slow
- Your history will improve over time as the script learns your navigation patterns
- Use `--rebuild-cache` if you notice stale directory listings

## License

This is free and unencumbered software released into the public domain.

---

*This tool was created to help navigate the filesystem after a long night of coding (or drinking), when remembering exact paths becomes challenging. Use responsibly!*
