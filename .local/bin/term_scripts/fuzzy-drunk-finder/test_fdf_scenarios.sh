#!/bin/bash
# Comprehensive test script for Fuzzy Drunk Finder
# This script tests various scenarios to ensure functionality works correctly

# Colors for better readability
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Track test results
PASSED=0
FAILED=0
TOTAL=0

# Log test status
log_test() {
    local name="$1"
    local result="$2"
    local details="$3"
    TOTAL=$((TOTAL + 1))
    
    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}[PASS]${NC} $name"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}[FAIL]${NC} $name"
        echo -e "${YELLOW}Details:${NC} $details"
        FAILED=$((FAILED + 1))
    fi
}

# Source the FDF script - adjust path if needed
echo -e "${BLUE}=== Sourcing Fuzzy Drunk Finder ====${NC}"
. "$(dirname "$0")/fuzzy-drunk-finder.sh" || {
    echo "Error: Could not source fuzzy-drunk-finder.sh"
    exit 1
}

# Print test header
print_header() {
    echo
    echo -e "${BLUE}===================================================${NC}"
    echo -e "${BLUE}=== $1 ===${NC}"
    echo -e "${BLUE}===================================================${NC}"
}

# Test: Clear history
test_clear_history() {
    print_header "Testing history clear functionality"
    
    # Clear history
    fdf_clear_history
    
    # Check if history file exists and is empty
    if [ -f "$HISTORY_FILE" ] && [ ! -s "$HISTORY_FILE" ]; then
        log_test "Clear history" "PASS" ""
    else
        log_test "Clear history" "FAIL" "History file either doesn't exist or is not empty"
    fi
}

# Test: Basic search functionality
test_basic_search() {
    print_header "Testing basic search functionality"
    
    # Test search for common directories
    local search_output=$(fdf --search "tmp" 2>&1)
    
    # Check if search output contains what we expect
    if echo "$search_output" | grep -q "Total matches:"; then
        log_test "Basic search" "PASS" ""
    else
        log_test "Basic search" "FAIL" "Search output doesn't contain expected results"
    fi
    
    # Test with empty search term
    search_output=$(fdf --search "" 2>&1)
    if echo "$search_output" | grep -q "Total matches:"; then
        log_test "Empty search term" "PASS" ""
    else
        log_test "Empty search term" "FAIL" "Empty search doesn't show results"
    fi
}

# Test: Hidden files search
test_hidden_search() {
    print_header "Testing hidden files search"
    
    # Regular search
    local reg_count=$(fdf --search ".config" | grep "Total directory matches:" | grep -o "[0-9]*")
    
    # Hidden search
    local hidden_count=$(fdf --hidden --search ".config" | grep "Total directory matches:" | grep -o "[0-9]*")
    
    # Hidden should find more (or equal) matches
    if [ "$hidden_count" -ge "$reg_count" ]; then
        log_test "Hidden search finds more matches" "PASS" ""
    else
        log_test "Hidden search finds more matches" "FAIL" "Hidden search found fewer results than regular"
    fi
}

# Test: History functionality
test_history_functionality() {
    print_header "Testing history functionality"
    
    # Clear history first
    fdf_clear_history
    
    # Create a test directory
    local test_dir="/tmp/fdf_test_$(date +%s)"
    mkdir -p "$test_dir"
    
    # Get starting directory
    local start_dir=$(pwd)
    
    # Direct test of history functions
    echo -e "${YELLOW}Testing direct history functions...${NC}"
    echo "Adding test entry to history file directly..."
    add_to_history "$start_dir" "$test_dir" true
    
    # Check if direct addition worked
    if grep -q "$start_dir:$test_dir" "$HISTORY_FILE"; then
        echo -e "${GREEN}Direct history addition success${NC}"
        log_test "Direct history addition" "PASS" ""
    else
        echo -e "${RED}Direct history addition failed${NC}"
        echo "History file content:"
        cat "$HISTORY_FILE"
        log_test "Direct history addition" "FAIL" "Failed to add entry directly to history"
    fi
    
    # Test context history retrieval
    echo -e "${YELLOW}Testing context history retrieval...${NC}"
    local retrieved_history=$(get_context_history "$start_dir" true)
    echo "Retrieved history: '$retrieved_history'"
    
    if [ -n "$retrieved_history" ] && echo "$retrieved_history" | grep -q "$test_dir"; then
        log_test "Context history retrieval" "PASS" ""
    else
        log_test "Context history retrieval" "FAIL" "Failed to retrieve history context"
        echo "History file content:"
        cat "$HISTORY_FILE"
        echo "get_context_history output:"
        get_context_history "$start_dir" true
    fi
    
    # Navigate to test directory via FDF
    cd "$start_dir"
    fdf --debug "$test_dir" >/dev/null 2>&1
    
    # Check if history recorded
    sleep 1  # Give time for history to be written
    local history_content=$(cat "$HISTORY_FILE")
    
    if echo "$history_content" | grep -q "$start_dir:$test_dir"; then
        log_test "History records navigation" "PASS" ""
    else
        log_test "History records navigation" "FAIL" "Navigation wasn't recorded in history file: $history_content"
    fi
    
    # Test that history entries appear first
    local history_search=$(fdf --search "fdf_test" | grep -A1 "=== History Entries ===" | tail -1)
    
    if echo "$history_search" | grep -q "$test_dir"; then
        log_test "History entries in search" "PASS" ""
    else
        log_test "History entries in search" "FAIL" "History entries not visible in search: $history_search"
    fi
    
    # Clean up
    rm -rf "$test_dir"
}

# Test: History prioritization
test_history_prioritization() {
    print_header "Testing history entry prioritization"
    
    # Clear history first
    fdf_clear_history
    
    # Create a test directory with a unique name
    local unique_name="unique_test_$(date +%s)"
    local test_dir="/tmp/$unique_name"
    mkdir -p "$test_dir"
    
    # Get starting directory
    local start_dir=$(pwd)
    
    # Add to history directly
    add_to_history "$start_dir" "$test_dir" true
    
    # Test search results with --search
    local search_output=$(fdf --search "$unique_name")
    
    # Check if history entries appear first
    local first_result=$(echo "$search_output" | grep -A1 "=== History Entries ===" | tail -1)
    
    if echo "$first_result" | grep -q "$unique_name"; then
        log_test "History entries appear in search" "PASS" ""
    else
        log_test "History entries appear in search" "FAIL" "History entry not found in search results"
        echo "Search output:"
        echo "$search_output"
    fi
    
    # Clean up
    rm -rf "$test_dir"
}

# Test: Debug mode output
test_debug_mode() {
    print_header "Testing debug mode output"
    
    local debug_output=$(fdf --debug --search "tmp" 2>&1)
    
    # Check for debug information
    if echo "$debug_output" | grep -q "Debug:"; then
        log_test "Debug mode shows info" "PASS" ""
    else
        log_test "Debug mode shows info" "FAIL" "Debug output doesn't contain 'Debug:' messages"
    fi
}

# Test function to evaluate FZF options
test_fzf_options() {
    print_header "Testing FZF options configuration"
    
    # Get debug output which shows FZF options
    local fzf_options=$(fdf --debug --search "" 2>&1 | grep "FZF options:" | head -1)
    
    # Check for key bindings
    if echo "$fzf_options" | grep -q "ctrl-y"; then
        log_test "FZF Ctrl+Y option" "PASS" ""
    else
        log_test "FZF Ctrl+Y option" "FAIL" "FZF options don't include Ctrl+Y binding"
    fi
    
    # Check for tiebreak option to prioritize history
    if echo "$fzf_options" | grep -q "tiebreak"; then
        log_test "FZF tiebreak option" "PASS" ""
    else
        log_test "FZF tiebreak option" "FAIL" "FZF options don't include tiebreak setting"
    fi
}

# Run all tests
run_all_tests() {
    echo -e "${BLUE}Starting Fuzzy Drunk Finder tests...${NC}"
    
    test_clear_history
    test_basic_search
    test_hidden_search
    test_history_functionality
    test_history_prioritization
    test_debug_mode
    test_fzf_options
    
    # Summary
    echo
    echo -e "${BLUE}=== Test Summary ===${NC}"
    echo -e "Total tests: ${TOTAL}"
    echo -e "${GREEN}Passed: ${PASSED}${NC}"
    echo -e "${RED}Failed: ${FAILED}${NC}"
    
    if [ "$FAILED" -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        return 1
    fi
}

# Run tests if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi
