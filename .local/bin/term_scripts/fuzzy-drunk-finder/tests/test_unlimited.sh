#!/bin/bash

# Test for unlimited depth directory listing functionality

# Ensure script is executable
chmod +x "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Source the fuzzy-drunk-finder script
source "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Test directory - use a smaller directory than home for speed
TEST_DIR="$HOME/bin"
[ ! -d "$TEST_DIR" ] && TEST_DIR="$HOME"

echo "===== Testing Unlimited Depth Directory Listing ====="
echo "Directory: $TEST_DIR"
echo "Expected: Directories listed with unlimited depth (or max 7 in home directories)"
echo ""

# Run the test in search mode to see output without user interaction
fdf --debug --unlimited --search "$TEST_DIR"

echo ""
echo "===== Unlimited Depth Test Complete ====="
