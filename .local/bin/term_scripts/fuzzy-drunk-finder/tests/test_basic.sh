#!/bin/bash

# Test for basic directory listing functionality

# Ensure script is executable
chmod +x "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Source the fuzzy-drunk-finder script
source "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Test directory
TEST_DIR="$HOME"

echo "===== Testing Basic Directory Listing ====="
echo "Directory: $TEST_DIR"
echo "Expected: Normal directories, no hidden directories, default depth (3)"
echo ""

# Run the test in search mode to see output without user interaction
fdf --debug --search "$TEST_DIR"

echo ""
echo "===== Basic Test Complete ====="
