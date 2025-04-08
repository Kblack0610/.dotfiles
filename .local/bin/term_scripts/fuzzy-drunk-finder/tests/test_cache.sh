#!/bin/bash

# Test for cache functionality

# Ensure script is executable
chmod +x "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Source the fuzzy-drunk-finder script
source "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Test directory
TEST_DIR="$HOME/bin"
[ ! -d "$TEST_DIR" ] && TEST_DIR="$HOME"

echo "===== Testing Cache Functionality ====="
echo "Directory: $TEST_DIR"
echo ""

# Step 1: Clear the cache
echo "Step 1: Clearing cache..."
fdf_clear_cache

# Step 2: First run (should rebuild cache)
echo ""
echo "Step 2: First run - should build cache..."
time fdf --debug --search "$TEST_DIR"

# Step 3: Second run (should use cache)
echo ""
echo "Step 3: Second run - should use cache and be faster..."
time fdf --debug --search "$TEST_DIR"

echo ""
echo "===== Cache Test Complete ====="
