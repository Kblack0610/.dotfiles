#!/bin/bash

# Test Suite for Fuzzy Drunk Finder
# This script tests all major functionality of the fuzzy-drunk-finder.sh script

# Colors for test output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

# Source the script to test
source "$(dirname "$0")/fuzzy-drunk-finder.sh"

# Setup test environment
TEST_DIR="/tmp/fdf_test_$(date +%s)"
mkdir -p "$TEST_DIR"
mkdir -p "$TEST_DIR/dir1/subdir1/subsubdir1"
mkdir -p "$TEST_DIR/dir2/subdir2"
mkdir -p "$TEST_DIR/.hidden_dir/subdir"
touch "$TEST_DIR/file1.txt"
touch "$TEST_DIR/dir1/file2.txt"
touch "$TEST_DIR/.hidden_file"

# Backup original history and cache
ORIGINAL_HISTORY_FILE="$HISTORY_FILE"
ORIGINAL_CACHE_DIR="$CACHE_DIR"
HISTORY_FILE="$TEST_DIR/.fdf_test_history"
CACHE_DIR="$TEST_DIR/.fdf_test_cache"
mkdir -p "$CACHE_DIR"
touch "$HISTORY_FILE"

# Helper function to print test results
print_result() {
    local test_name="$1"
    local result="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}✓ PASS${NC}: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Mocked FZF function for testing
fzf() {
    # For testing purposes, we'll just echo the first item from stdin
    # or use a provided test value
    if [ -n "$TEST_SELECTION" ]; then
        echo "$TEST_SELECTION"
        return 0
    fi
    
    head -n 1
    return 0
}

# Mock CD function to prevent actual directory changes during tests
cd() {
    # Store the intended directory in a variable instead of actually changing dirs
    TEST_CURRENT_DIR="$1"
    return 0
}

echo -e "${BLUE}=== Fuzzy Drunk Finder Test Suite ===${NC}"
echo "Setting up test environment in $TEST_DIR"

# Test 1: Basic directory listing
test_basic_listing() {
    local result=$(get_directories "$TEST_DIR" false 3 false | grep "dir1")
    if [ -n "$result" ]; then
        print_result "Basic directory listing shows directories" "PASS"
    else
        print_result "Basic directory listing shows directories" "FAIL"
    fi
}

# Test 2: Hidden directory listing
test_hidden_listing() {
    local result=$(get_directories "$TEST_DIR" true 3 false | grep ".hidden_dir")
    if [ -n "$result" ]; then
        print_result "Hidden directory listing shows hidden directories" "PASS"
    else
        print_result "Hidden directory listing shows hidden directories" "FAIL"
    fi
}

# Test 3: Depth limitation
test_depth_limitation() {
    local shallow_result=$(get_directories "$TEST_DIR" false 1 false | grep "subdir1")
    local deep_result=$(get_directories "$TEST_DIR" false 3 false | grep "subsubdir1")
    
    if [ -z "$shallow_result" ] && [ -n "$deep_result" ]; then
        print_result "Depth limitation works correctly" "PASS"
    else
        print_result "Depth limitation works correctly" "FAIL"
    fi
}

# Test 4: Unlimited depth
test_unlimited_depth() {
    local result=$(get_directories "$TEST_DIR" false 3 true | grep "subsubdir1")
    if [ -n "$result" ]; then
        print_result "Unlimited depth shows deep directories" "PASS"
    else
        print_result "Unlimited depth shows deep directories" "FAIL"
    fi
}

# Test 5: History recording
test_history_recording() {
    # Clear history first
    > "$HISTORY_FILE"
    
    # Add a directory to history
    add_to_history "$TEST_DIR/dir1" "$TEST_DIR"
    
    # Check if it was added
    if grep -q "$TEST_DIR:$TEST_DIR/dir1" "$HISTORY_FILE"; then
        print_result "History recording works" "PASS"
    else
        print_result "History recording works" "FAIL"
    fi
}

# Test 6: Context-aware history
test_context_history() {
    # Clear history first
    > "$HISTORY_FILE"
    
    # Add entries with different contexts
    add_to_history "$TEST_DIR/dir1" "$TEST_DIR"
    add_to_history "$TEST_DIR/dir2" "$TEST_DIR"
    add_to_history "$TEST_DIR/dir1/subdir1" "$TEST_DIR/dir1"
    
    # Get context-specific history for TEST_DIR
    local result=$(grep "^$TEST_DIR:" "$HISTORY_FILE" | sed "s|^$TEST_DIR:||" | sort | uniq -c | sort -nr | sed 's/^ *[0-9]* *//' | grep -v '^$')
    
    if echo "$result" | grep -q "dir1" && echo "$result" | grep -q "dir2"; then
        print_result "Context-aware history works" "PASS"
    else
        print_result "Context-aware history works" "FAIL"
    fi
}

# Test 7: Cache creation and usage
test_cache() {
    # Clear cache first
    rm -rf "$CACHE_DIR"/*
    mkdir -p "$CACHE_DIR"
    
    # Get directories to create cache
    get_directories "$TEST_DIR" false 3 false > /dev/null
    
    # Check if cache file was created
    if [ "$(ls -A "$CACHE_DIR")" ]; then
        print_result "Cache creation works" "PASS"
    else
        print_result "Cache creation works" "FAIL"
    fi
    
    # Clear cache
    fdf_clear_cache
    
    # Check if cache was cleared
    if [ ! "$(ls -A "$CACHE_DIR")" ]; then
        print_result "Cache clearing works" "PASS"
    else
        print_result "Cache clearing works" "FAIL"
    fi
}

# Test 8: Selection and navigation
test_selection() {
    # Mock the selection
    TEST_SELECTION="D:dir1"
    
    # Call fdf with test directory
    TEST_CURRENT_DIR="" # Reset
    fdf "$TEST_DIR"
    
    # Check if navigation would happen to the right place
    if [ "$TEST_CURRENT_DIR" = "$TEST_DIR/dir1" ]; then
        print_result "Directory selection and navigation works" "PASS"
    else
        print_result "Directory selection and navigation works" "FAIL"
    fi
}

# Test 9: History selection
test_history_selection() {
    # Clear history first
    > "$HISTORY_FILE"
    
    # Add a history entry
    add_to_history "$TEST_DIR/dir1" "$TEST_DIR"
    
    # Mock the selection of a history entry
    TEST_SELECTION="H:dir1"
    
    # Call fdf with test directory
    TEST_CURRENT_DIR="" # Reset
    fdf "$TEST_DIR"
    
    # Check if navigation would happen to the right place
    if [ "$TEST_CURRENT_DIR" = "$TEST_DIR/dir1" ]; then
        print_result "History selection and navigation works" "PASS"
    else
        print_result "History selection and navigation works" "FAIL"
    fi
}

# Test 10: Absolute path handling
test_absolute_path() {
    # Mock the selection of an absolute path
    TEST_SELECTION="D:/tmp"
    
    # Call fdf
    TEST_CURRENT_DIR="" # Reset
    fdf "$TEST_DIR"
    
    # Check if navigation would happen to the right place
    if [ "$TEST_CURRENT_DIR" = "/tmp" ]; then
        print_result "Absolute path handling works" "PASS"
    else
        print_result "Absolute path handling works" "FAIL"
    fi
}

# Run all tests
test_basic_listing
test_hidden_listing
test_depth_limitation
test_unlimited_depth
test_history_recording
test_context_history
test_cache
test_selection
test_history_selection
test_absolute_path

# Print summary
echo -e "\n${BLUE}=== Test Summary ===${NC}"
echo -e "Total tests: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"

# Clean up
echo -e "\nCleaning up test environment..."
rm -rf "$TEST_DIR"
HISTORY_FILE="$ORIGINAL_HISTORY_FILE"
CACHE_DIR="$ORIGINAL_CACHE_DIR"

# Exit with appropriate code
if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
