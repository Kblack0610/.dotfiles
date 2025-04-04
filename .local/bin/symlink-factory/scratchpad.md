# Symlink Factory Project

## Task Description
Create a bash script that accepts a variable list of files and iterates through them to symlink certain files (specifically windsurf rules and cursor rules) to multiple directories. The script should also support reading lists of files and directories from text files.

## Progress
[X] Create project directory
[X] Create main symlink_factory.sh script with the following features:
  - Ability to specify multiple source files
  - Ability to specify multiple target directories
  - Force option to overwrite existing files
  - Backup option to create backups of existing files
  - Verbose mode for detailed output
  - Dry-run mode to preview changes without making them
  - Source directory option to specify where source files are located
  - Color-coded output for better readability
  - Help message with usage examples
[X] Make script executable
[X] Add ability to read source files from a text file (--files-list)
[X] Add ability to read target directories from a text file (--dirs-list)
[X] Create example file lists for demonstration
[X] Create comprehensive README with usage examples and integration tips
[ ] Test the script with sample windsurf and cursor rules files
[ ] Document usage examples specific to windsurf and cursor rules

## Integration with Dotfiles
The script can be integrated with the existing dotfiles structure at `~/.dotfiles/.local/bin/installation_scripts/` by either:
1. Adding it as a new installation function in the appropriate installation scripts file
2. Using it standalone with file lists that point to the right locations

## Next Steps
- Test the script with actual windsurf and cursor rules files
- Consider adding the script to the dotfiles installation system
- Consider any additional improvements or refinements

## Lessons
- Bash scripts can be made more robust with proper error handling and clear output messages
- For symlinking configuration files, it's useful to have options like backup and dry-run
- Creating a flexible script allows for reuse beyond just the initial use case
- Using text files to store lists of files and directories makes batch operations more manageable
- Integrating with existing systems (like dotfiles) requires understanding their structure and conventions
