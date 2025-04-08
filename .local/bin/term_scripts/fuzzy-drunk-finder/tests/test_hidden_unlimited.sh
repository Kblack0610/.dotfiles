#!/bin/bash

# Test for combined hidden and unlimited depth directory listing functionality

# Ensure script is executable
chmod +x "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Source the fuzzy-drunk-finder script
source "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Test directory - use a smaller directory than home for speed
TEST_DIR="$HOME/bin"
[ ! -d "$TEST_DIR" ] && TEST_DIR="$HOME"

echo "===== Testing Hidden AND Unlimited Depth Directory Listing ====="
echo "Directory: $TEST_DIR"
echo "Expected: Both hidden and normal directories with unlimited depth"
echo ""

# Run the test in search mode to see output without user interaction
fdf --debug --hidden --unlimited --search "$TEST_DIR"

echo ""
echo "===== Hidden AND Unlimited Depth Test Complete ====="
