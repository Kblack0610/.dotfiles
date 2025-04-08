#!/bin/bash

# Cleanup script for fuzzy-drunk-finder
# This script improves code organization and fixes common issues

# Ensure script is executable
chmod +x "$(dirname "$0")/fuzzy-drunk-finder.sh"
chmod +x "$(dirname "$0")/tests"/*.sh

echo "===== Fuzzy Drunk Finder Code Cleanup ====="

# Fix permissions
echo "Fixing permissions..."
chmod +x "$(dirname "$0")/fuzzy-drunk-finder.sh"
chmod +x "$(dirname "$0")/tests"/*.sh

# Check for shellcheck
if command -v shellcheck &> /dev/null; then
    echo "Running shellcheck for code quality improvements..."
    shellcheck "$(dirname "$0")/fuzzy-drunk-finder.sh" || echo "shellcheck found issues to fix"
else
    echo "shellcheck not found. Install with 'sudo apt install shellcheck' for code quality checks."
fi

# Check script syntax
echo "Checking script syntax..."
bash -n "$(dirname "$0")/fuzzy-drunk-finder.sh" && echo "Syntax check passed!"

# Check for unused or duplicate functions
echo "Checking for unused or duplicate functions..."
grep -E '^[[:space:]]*([[:alnum:]_]+[[:space:]]*\(\)|function[[:space:]]+[[:alnum:]_]+)' "$(dirname "$0")/fuzzy-drunk-finder.sh" | sed 's/[[:space:]]*(//' | sort

# Organize cache directory
echo "Organizing cache directory..."
mkdir -p "$(dirname "$0")/.fdf_cache"

# Ensure history file exists
echo "Setting up history file..."
touch "$(dirname "$0")/.fdf_history"

# Create backup of original script
echo "Creating backup..."
cp "$(dirname "$0")/fuzzy-drunk-finder.sh" "$(dirname "$0")/fuzzy-drunk-finder.sh.bak"

echo "Cleanup complete!"
echo "Suggestions for further cleanup:"
echo "1. Review debug statements for consistency"
echo "2. Consider adding a config file for default settings"
echo "3. Add more inline documentation for complex functions"
echo "4. Consider splitting the script into multiple files for better organization"
echo "5. Add a --version flag to track changes"
