#!/usr/bin/env bash

# setup_symlinks.sh
# Script to create target directories and run symlink-factory

# We'll set -e for the directory creation part but not for the symlink creation
set -e

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}Creating target directories...${NC}"

# Read target directories from file and create them if they don't exist
while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comments
    if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
        # Trim leading/trailing whitespace
        dir="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        
        if [ ! -d "$dir" ]; then
            echo "Creating directory: $dir"
            mkdir -p "$dir"
        else
            echo "Directory already exists: $dir"
        fi
    fi
done < "target_dirs.txt"

echo -e "${GREEN}All target directories created successfully!${NC}"
echo

# Get absolute paths for the files list and dirs list
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_LIST_PATH="$SCRIPT_DIR/source_files.txt"
DIRS_LIST_PATH="$SCRIPT_DIR/target_dirs.txt"

echo "Files list path: $FILES_LIST_PATH"
echo "Dirs list path: $DIRS_LIST_PATH"

# Print the content of the files to verify
echo -e "${BLUE}Source files to be symlinked:${NC}"
grep -v "^#" "$FILES_LIST_PATH" | grep -v "^$"

echo -e "${BLUE}Target directories:${NC}"
grep -v "^#" "$DIRS_LIST_PATH" | grep -v "^$"

# Turn off exit-on-error for the symlink creation part
set +e

# Make our fixed script executable
chmod +x "$SCRIPT_DIR/symlink_factory_fixed.sh"

# Run our fixed symlink factory script instead
echo -e "${BLUE}Running fixed symlink-factory script...${NC}"
"$SCRIPT_DIR/symlink_factory_fixed.sh" -f -v -b \
    --files-list "$FILES_LIST_PATH" \
    --dirs-list "$DIRS_LIST_PATH"
FACTORY_EXIT=$?

if [ $FACTORY_EXIT -eq 0 ]; then
    echo -e "${GREEN}Symlinks created successfully!${NC}"
else
    echo -e "${YELLOW}Symlink creation completed with exit code $FACTORY_EXIT.${NC}"
    echo -e "${YELLOW}Some symlinks may not have been created. Check the output above for details.${NC}"
fi
