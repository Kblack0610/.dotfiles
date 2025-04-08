#!/bin/bash

# Test for search functionality

# Ensure script is executable
chmod +x "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Source the fuzzy-drunk-finder script
source "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Clear cache to ensure fresh results
fdf_clear_cache

# Test directory
TEST_DIR="$HOME"

# Search term - should find directories with "doc" in them
SEARCH_TERM="doc"

echo "===== Testing Search Functionality ====="
echo "Directory: $TEST_DIR"
echo "Search Term: $SEARCH_TERM"
echo "Expected: Directories containing the search term '$SEARCH_TERM'"
echo ""

# Run the search
fdf --debug --search "$SEARCH_TERM" "$TEST_DIR"

echo ""
echo "===== Search Test Complete ====="

# Test with hidden directories
echo ""
echo "===== Testing Search with Hidden Directories ====="
echo "Directory: $TEST_DIR"
echo "Search Term: $SEARCH_TERM"
echo "Expected: Both normal and hidden directories containing '$SEARCH_TERM'"
echo ""

# Run the search with hidden flag
fdf --debug --hidden --search "$SEARCH_TERM" "$TEST_DIR"

echo ""
echo "===== Hidden Search Test Complete ====="
