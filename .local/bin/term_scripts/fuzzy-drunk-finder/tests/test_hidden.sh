#!/bin/bash

# Test for hidden directory listing functionality

# Ensure script is executable
chmod +x "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Source the fuzzy-drunk-finder script
source "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Test directory
TEST_DIR="$HOME"

echo "===== Testing Hidden Directory Listing ====="
echo "Directory: $TEST_DIR"
echo "Expected: Both normal and hidden directories, default depth (3)"
echo ""

# Run the test in search mode to see output without user interaction
fdf --debug --hidden --search "$TEST_DIR"

echo ""
echo "===== Hidden Test Complete ====="
