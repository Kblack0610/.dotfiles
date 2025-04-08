#!/bin/bash

# Test for the specific dog search issue

# Ensure script is executable
chmod +x "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Source the fuzzy-drunk-finder script
source "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Clear cache to ensure fresh results
fdf_clear_cache

# Test directory
TEST_DIR="$HOME"

# Search term
SEARCH_TERM="dog"

echo "===== Testing Specific Search Issue with 'dog' ====="
echo "Directory: $TEST_DIR"
echo "Search Term: $SEARCH_TERM"
echo "Expected: Directories containing the search term '$SEARCH_TERM', including hidden ones"
echo ""

# Run the search with hidden and unlimited flags
fdf --debug --hidden --unlimited --search "$SEARCH_TERM" "$TEST_DIR"

echo ""
echo "===== Dog Search Test Complete ====="
