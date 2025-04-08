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
[X] Create enhanced directory navigation script (enhanced_fzd.sh)
  - [X] Add support for starting from a specified directory
  - [X] Add --hidden flag to include hidden files and directories
  - [X] Add --depth parameter for customizing search depth
  - [X] Create help function for usage instructions
[X] Refactor script to use "fdf" (Fuzzy Drunk Finder) naming
  - [X] Rename all functions and references from fzd to fdf
  - [X] Update help text and aliases
  - [X] Ensure consistent naming throughout the script
[X] Create comprehensive documentation in README.md
  - [X] Document installation process
  - [X] Document usage examples
  - [X] Document features and options
  - [X] Add tips and requirements
[X] Add unlimited depth search capability
  - [X] Add --unlimited flag for searching without depth restrictions
  - [X] Make --depth 0 equivalent to --unlimited for user convenience
  - [X] Add appropriate warnings about performance with unlimited depth
[X] Add history tracking functionality
  - [X] Create ~/.fdf_history file to store visited directories
  - [X] Prioritize frequently used directories in search results
  - [X] Add --no-history option for users who prefer no tracking
  - [X] Display history items with [HISTORY] tag for clarity
[X] Enhance script with caching and context-aware history
  - [X] Add caching system to improve boot time with large directories
  - [X] Create cache directory at ~/.cache/fdf with security permissions
  - [X] Add fdf_clear_cache function to manually clear the cache
  - [X] Display boot time in header for performance monitoring
  - [X] Make history context-aware (only show relevant entries for current location)
  - [X] Store directory context with each history entry
  - [X] Improve modular design with separate functions for maintainability
[X] Fix history filtering issue
  - [X] Implement proper prefix-based filtering for history items
  - [X] Use fzf's --delimiter and --nth options to maintain searchability
  - [X] Add preview window to show [HISTORY] tag without affecting search text
  - [X] Use a temporary file for proper handling of newlines and special characters
  - [X] Clean parsing of selected item with cut to avoid any formatting issues
[X] Fix performance issues with unlimited depth searches
  - [X] Add pragmatic depth limit (7) for unlimited searches to prevent system hangs
  - [X] Special handling for home directories with automatic depth adjustment
  - [X] User notification when depth is automatically limited
  - [X] Improved caching to minimize repeat searches
[X] Create comprehensive test suite
  - [X] Implement test_fdf.sh script with 10 different test cases
  - [X] Mock FZF functionality for automated testing
  - [X] Test directory structure creation
  - [X] Cover basic functionality, history, caching, and selection
  - [X] Generate clear test reports with pass/fail indicators
[X] Add debug mode and improve history visibility
  - [X] Add [HISTORY] tag for better visibility of history entries
  - [X] Implement --debug flag for detailed debugging information
  - [X] Show entry counts, settings, and performance data in debug mode
  - [X] Fix history filtering to work with all flag combinations
  - [X] Fix temporary file handling to ensure consistent behavior
[X] Fix history search with all flag combinations
  - [X] Completely redesign history handling with direct [HISTORY] tags
  - [X] Remove temporary file approach which was causing search issues
  - [X] Combine entries with proper newline handling
  - [X] Ensure history entries appear in search with all flag combinations
  - [X] More verbose debug information to help troubleshoot
[X] Add test capabilities for search functionality
  - [X] Add --search flag for non-interactive testing of search results
  - [X] Allow specifying an optional search term to test filtering
  - [X] Show separate sections for history and directory matches
  - [X] Display clear counts of matched entries
  - [X] Provide detailed summary to help diagnose issues
[X] Further improve history search behavior
  - [X] Ensure history entries are mixed with regular entries based on search relevance
  - [X] Make history entries distinctly visible with "HISTORY: " prefix only in debug mode
  - [X] Fix issues with --hidden and --unlimited flags for history visibility
  - [X] Use separate temporary files for more reliable processing
  - [X] Add custom preview functionality to enhance visibility
[X] Add history management functionality
  - [X] Create fdf_clear_history command to easily reset history
  - [X] Update help documentation to document the new command
  - [X] Ensure history entries don't keep old prefix formats
[X] Simplify code for better search capabilities
  - [X] Revert to direct piping of files to fzf without complex combining logic
  - [X] Remove unnecessary flags that were limiting search flexibility
  - [X] Keep history entries simple in regular mode to maximize searchability
  - [X] Return to the core functionality that made the original approach effective
[X] Improve robustness
  - [X] Fix Escape key behavior to always leave the user in their original directory
  - [X] Add clear user feedback in both normal and debug modes
  - [X] Maintain the test mode functionality for easier debugging
  - [X] Add Ctrl+Y shortcut to copy a path to clipboard
  - [X] Use proper exit code checking to ensure Escape works correctly
  - [X] Fix history tracking to properly record navigation context
  - [X] Fix hanging issues with simpler code approach
[ ] Additional performance optimizations (deferred)
[ ] Implement additional improvements

## Lessons

### Technical Lessons
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
- When creating command-line utilities, provide clear help documentation
- Command line arguments should follow standard conventions (--flag for boolean options, --option value for options with values)
- Scripts that affect shell state (like changing directories) must be sourced rather than executed
- When allowing custom starting directories, validate they exist before using them
- Provide reasonable defaults so the script is useful without any parameters
- Adding a depth parameter lets users control performance vs. comprehensiveness tradeoff
- Consistent naming is important for user understanding - use the same prefix (like "fdf_") for all related functions
- README documentation should include clear examples and explain not just how to use a tool but why certain choices were made
- When creating command-line tools, explain any requirements (like needing to be sourced) clearly to prevent user confusion
- History tracking makes navigation tools more useful over time as they learn user patterns
- Providing an unlimited depth option gives users flexibility, but should come with performance warnings
- It's helpful to mark history entries distinctly (with a tag like [HISTORY]) so users understand why certain items appear at the top
- Having multiple ways to invoke the same functionality (--unlimited or --depth 0) makes the tool more intuitive for different users
- Remember to handle corner cases like empty history files or directories with no contents
- Cache frequently used and expensive operations (like directory listings) to improve performance
- Display performance metrics (like boot time) to users for transparency
- Store metadata along with primary data for more intelligent features (like storing 'from' directory with history)
- Make history context-aware instead of global - users expect to see relevant history for their current context
- Use modular functions to keep code maintainable and organized
- Creating a unique cache key using md5sum of input parameters creates a reliable caching system
- Add commands to manually clear/reset cached data for users who want fresh results
- Only display global history when it makes sense - often context-specific history is more valuable
- Design for both performance and user experience - caching improves response time but context-aware results improve usability
- When implementing features, focus on one problem at a time and test thoroughly
- FZF has powerful filtering capabilities that can be leveraged with --delimiter and --nth options
- The preview feature in FZF is useful for showing additional info without affecting the search text
- Using a temporary file ensures proper handling of newlines and special characters
- Simple data prefixing (H: and D:) can be more reliable than ANSI color codes for marking item types
- The cut command is a clean way to parse delimited output without sed's complexity
- For complex filtering needs, use fzf's built-in capabilities rather than trying to craft complex formatting
- Always test search functionality with various inputs to ensure consistent behavior
- Sometimes simpler approaches (prefixes + delimiter) are more reliable than complex ones (ANSI codes)
- Unlimited depth doesn't literally need to be unlimited - a reasonable max depth (like 7) is deep enough for most use cases
- Always implement safeguards against operations that could hang the system 
- For home directories or large file systems, be especially careful about recursive operations
- Be transparent with users when automatically adjusting parameters for performance/safety reasons
- Communicate performance trade-offs to users with clear notifications
- It's better to set reasonable defaults than to allow operations that might hang the system
- For FZF, --with-nth controls display but still allows search on all fields, while --nth controls which fields are searchable
- Automated tests are crucial for shell scripts to avoid regressions
- Mocking external commands like FZF and cd allows for proper testing without affecting the real system
- When testing, create isolated environments with temporary directories
- Use color-coded output in tests to quickly identify successes and failures 
- Test both positive and negative cases (e.g., testing that shallow depth doesn't show deep directories)
- Running a suite of automated tests before making changes can prevent introducing bugs
- Sometimes users want to see debugging information that's normally hidden (like which entries are from history)
- A debug mode is a clean way to provide detailed information without cluttering the normal interface
- When filtering with many options/flags, ensure all combinations work correctly
- Proper temporary file handling is critical for data with special characters and newlines
- Small changes in command arguments (--nth vs --with-nth) can have big impacts on functionality
- Combining a clean interface with an optional debug mode gives users the best of both worlds
- Different types of users have different needs - some want simplicity while others want visibility into internal operations
- Sometimes complex approaches (temporary files, prefixes) cause more problems than they solve
- Direct text manipulation with tools like sed can be more reliable than complex parsing
- Always test your changes with all possible flag combinations
- Temporary files can introduce issues with newlines and special characters
- When things get complex, simplify your approach and start over
- Make debugging easy by showing real examples of data in debug mode
- Keep detailed information available in debug mode but hidden in normal operation
- Sometimes you need specialized testing tools to diagnose complex issues
- Non-interactive testing modes can help identify problems that are hard to see in interactive use
- When diagnosing search issues, it helps to see exactly what would be searched and matched
- Separate testing tools are invaluable for shell scripts where normal debugging is challenging
- For search issues, creating a dedicated test mode is better than trying to debug via the UI
- Simulate user actions in test mode to verify expected behavior works correctly
- Don't force entries to the top unless specifically requested - let search relevance determine order
- Using two separate files (for history and directories) and manually combining them gives you more control
- Adding a preview feature to FZF can greatly enhance the usability of the tool
- FZF options like --exact can make search results more intuitive but also limit fuzzy matching
- Maintaining the original relevance-based searching is important for large directories
- Include commands to fix or reset data when things might get corrupted
- Balance visibility with normal operation - use debug mode to show tags and extra information
- Make sure users can easily clear or reset state if it gets into a weird state
- Sometimes simpler is better - overcomplicated approaches can cause more problems than they solve
- Handle user cancellation paths (like Escape key) as first-class citizens in your code
- Always give users feedback on what happened, especially when nothing appears to happen
- Over-optimization can make things worse - focus on core functionality first
- Check exit codes when using external tools to properly handle different termination paths
- Adding handy shortcuts like copying paths can greatly enhance user experience
- A good help menu should document all keyboard shortcuts
- Keep it simple - complex file descriptor approaches can cause hanging issues
- When capturing command output AND exit codes, the standard approach ($? after command) is more reliable
- Test key keyboard shortcuts thoroughly - especially those that exit the program
- Favor reliable simple approaches over clever complex ones for better stability

### Technical Lessons
- Avoid overly complex file descriptor manipulation when simpler methods exist
- Properly handle exit codes from external tools like FZF
- Test in both debug and regular mode to catch differences in behavior
- Keep cancellation behavior simple and intuitive
- History tracking with context makes navigation more efficient
- Prefer direct piping to FZF over complex redirection
- Temporary file cleanup is essential for script reliability
- Shell functions should be designed with clean return values

### UX Lessons
- Users expect to stay in their current directory when they hit Escape
- Copy to clipboard functionality adds significant convenience
- Verbose debug output helps troubleshoot issues while keeping regular output clean
- Preview of directories provides valuable context when navigating
- Keep messages minimal for common operations to avoid clutter
- Match behavior to user expectations rather than technical correctness
- Never force users to navigate when they cancel a selection

## Recent Improvements

### Fixed Directory Handling
- Completely rewrote directory handling to keep track of two separate paths:
  - `from_dir`: the original directory where the command was executed (never changes)
  - `start_dir`: the target directory to search in (parameter to fdf command)
- This ensures that when specifying a target search directory like `fdf /tmp`, canceling with Escape still keeps you in your original directory

### Improved History Context
- History entries are now always collected from the original directory
- This ensures context-aware history works properly regardless of search directory
- Fixed processing of history entries with search terms

### Code Organization
- Moved function definitions to ensure they're defined before use
- Improved temporary file handling to prevent errors
- Added explicit debug information about both original and target directories

### Escape Key Behavior
- Added proper exit code detection to ensure Escape key doesn't change directories
- Simplified the code approach to avoid hanging issues
- Added clear feedback messages to inform users when staying in original directory

### Keyboard Shortcuts
- Added Ctrl+Y shortcut to copy the selected path to clipboard without navigating
- Updated help documentation to make users aware of all keyboard shortcuts
- Made sure shortcuts don't interfere with normal operation

### Test Mode
- Ensured test mode stays in original directory
- Added explicit comments and logic to prevent directory changes
- Fixed issues with search term handling to show relevant results

### Debugging
- Added more verbose debug output in debug mode
- Added test mode with --search to easily test what entries would be found
- Enhanced error handling and feedback for all operations

## Final Testing
- [X] Test Escape key behavior to ensure it stays in original directory
- [X] Test Ctrl+Y clipboard functionality
- [X] Test --search mode with and without search terms
- [X] Test history entries with various flag combinations
- [ ] Test in directories with many subdirectories to verify performance

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
