#!/bin/bash

# Test for the --rebuild-cache functionality

# Ensure script is executable
chmod +x "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Source the fuzzy-drunk-finder script
source "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Test directory
TEST_DIR="/home/kblack0610"

echo "===== Testing Rebuild Cache Functionality ====="
echo "Directory: $TEST_DIR"
echo ""

# Step 1: Run with normal cache
echo "Step 1: Running with normal cached results..."
time fdf --debug --hidden --unlimited --search dev "$TEST_DIR"

# Step 2: Run with forced cache rebuild
echo ""
echo "Step 2: Running with forced cache rebuild..."
time fdf --debug --hidden --unlimited --rebuild-cache --search dev "$TEST_DIR"

echo ""
echo "===== Rebuild Cache Test Complete ====="
