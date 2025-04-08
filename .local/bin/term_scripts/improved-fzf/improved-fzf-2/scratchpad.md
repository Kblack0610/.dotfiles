# Improved FZF Developer Script

## Task Description
Create a more responsive version of `fzf_dev.sh` that:
1. Saves command history
2. Shows options more closely related to the current directory the user is in

## Plan
[X] Create project structure
[X] Create the improved fzf script (fzf_dev.sh)
  - [X] Add history saving functionality
  - [X] Add directory-aware suggestions
  - [X] Make it more responsive
[X] Fix directory navigation issue
  - [X] Redesigned approach: directories have no prefix, while files and commands do
  - [X] Use pattern matching to identify entry types rather than explicit extraction
  - [X] Updated preview command and filter bindings to match new format
[X] Create documentation (README.md)
[X] Improve boot time measurement to accurately reflect startup time
[X] Remove conflicting key bindings
[X] Create compatible function definition that works across shells
[ ] Implement additional improvements

## Lessons
- When working with file system operations, ensure you have the correct permissions and paths
- Caching directory-specific suggestions improves responsiveness
- Using md5sum of the current directory path creates unique cache identifiers
- Prioritizing history entries above directory suggestions creates a better user experience
- When using the script with directory navigation, it must be sourced (not executed) to affect the parent shell
- For scripts that change directories, they need to be sourced with `source fzf_dev.sh` or `. fzf_dev.sh` to affect the parent shell
- Boot time performance is critical - the tool must start near-instantaneously to be useful, otherwise the project is pointless
- Always provide visual indicators for different types of items (files, directories, commands) for better UX
- When extracting dir/file names from tagged entries like "[DIR] path", be sure to correctly remove the prefix
- Be careful with key bindings - they can conflict with regular user input in interactive tools
- When measuring performance, position timing code carefully to capture what you actually want to measure
- Function names can conflict with existing aliases - use unique function names or check first
- Shell function definitions must be compatible with the user's shell environment
- Sometimes a complete design change is better than trying to fix a problematic approach - for directories, we removed prefixes entirely to avoid extraction issues
- Always test your changes in the environment where they'll be used, not just in theory
- For directory navigation, avoid adding any tags or prefixes to directory names when they need to be used directly with cd

## Potential Additional Improvements
1. Add fuzzy search capabilities for deeper directory structures
2. Implement custom keybindings for common operations
3. Add project-specific command templates based on detected frameworks
4. Include Git branch and status information in the prompt
5. Add colorful highlighting for different types of suggestions
6. Implement tab completion for selected commands
7. Add recent git commits as suggestions in git repositories
8. Implement a help screen with F1 or ? key
9. Add ability to filter by file type
10. Create per-project history files for more relevant suggestions

## Implementation Plan for Additional Features

### Phase 1: Git Integration
- [ ] Add git branch info to prompt when in git repositories
  - Use `git rev-parse --is-inside-work-tree` to check if in git repo
  - Use `git branch --show-current` to get current branch
- [ ] Include recent git commits as suggestions
  - Use `git log --oneline -n 10` to get recent commits
  - Format as "git show <commit_hash>" for easy viewing

### Phase 2: Visual and UX Enhancements
- [ ] Add color highlighting for different suggestion types
  - Files: blue
  - Directories: green
  - Git commands: yellow
  - History items: default
- [ ] Implement help screen with F1 or ? key
  - Create a help text variable with all commands and shortcuts
  - Add `--bind "f1:preview($HELP_TEXT)"` to fzf options
- [ ] Add custom keybindings for common operations
  - `Alt+F`: Filter by file type
  - `Alt+D`: Show only directories
  - `Alt+G`: Show only git commands
  - `Alt+H`: Show only history items

### Phase 3: Advanced Filtering and Organization
- [ ] Implement project-specific history files
  - Create hash of project root directory for unique file names
  - Store in `$HOME/.fzf_dev_history_<project_hash>`
- [ ] Add favorites system for frequently used commands
  - Create a favorites file in `$HOME/.fzf_dev_favorites`
  - Add `Alt+S` shortcut to save current command to favorites
  - Mark favorites with a star icon in the list
- [ ] Implement filtering by file type
  - Parse file extensions and create filter groups
  - Use header bar buttons to quickly filter by type

### Phase 4: Framework and Project Intelligence
- [ ] Expand framework detection for more project types
  - Add support for Ruby/Rails projects
  - Add support for Rust/Cargo projects
  - Add support for C/C++ projects with CMake
- [ ] Add context-aware command suggestions based on project structure
  - Look for test directories to suggest test commands
  - Look for build scripts to suggest build commands
- [ ] Implement command previews for better context
  - Show documentation for common commands
  - Show file contents for file operations
  - Show git diff for git commands
