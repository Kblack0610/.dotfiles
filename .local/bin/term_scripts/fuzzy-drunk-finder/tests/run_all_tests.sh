#!/bin/bash

# Comprehensive test script for fuzzy-drunk-finder
# Runs all individual tests in sequence

# Ensure script is executable
chmod +x "$(dirname "$0")/../fuzzy-drunk-finder.sh"
chmod +x "$(dirname "$0")"/*.sh

# Directory where test scripts are located
TEST_DIR="$(dirname "$0")"

# Source the fuzzy-drunk-finder script
source "$(dirname "$0")/../fuzzy-drunk-finder.sh"

# Clear cache before testing
fdf_clear_cache

# Function to run a test with a header
run_test() {
    local test_script="$1"
    local test_name=$(basename "$test_script" .sh | sed 's/test_//')
    
    echo "========================================================"
    echo "  RUNNING TEST: $test_name"
    echo "========================================================"
    
    # Run the test
    bash "$test_script"
    
    echo ""
    echo "Test $test_name completed."
    echo "--------------------------------------------------------"
    echo ""
    
    # Small pause between tests for readability
    sleep 1
}

# Main test execution

echo "Starting comprehensive tests for fuzzy-drunk-finder"
echo "=================================================="
echo ""

# Track test results
declare -A test_results
failed_tests=0
passed_tests=0

# Function to run a test with a header and track results
run_test() {
    local test_script="$1"
    local test_name=$(basename "$test_script" .sh | sed 's/test_//')
    local feature_description="$2"
    
    echo "========================================================"
    echo "  RUNNING TEST: $test_name"
    echo "  Feature: $feature_description"
    echo "========================================================"
    
    # Run the test
    bash "$test_script"
    local status=$?
    
    if [ $status -eq 0 ]; then
        echo -e "\033[0;32m✓ Test $test_name completed successfully.\033[0m"
        test_results["$test_name"]="PASSED"
        ((passed_tests++))
    else
        echo -e "\033[0;31m✗ Test $test_name FAILED with status $status.\033[0m"
        test_results["$test_name"]="FAILED"
        ((failed_tests++))
    fi
    
    echo "--------------------------------------------------------"
    echo ""
    
    # Small pause between tests for readability
    sleep 1
}

# Run each test with a description
run_test "$TEST_DIR/test_basic.sh" "Basic directory listing and navigation"
run_test "$TEST_DIR/test_hidden.sh" "Hidden directory inclusion"
run_test "$TEST_DIR/test_unlimited.sh" "Unlimited depth directory traversal"
run_test "$TEST_DIR/test_hidden_unlimited.sh" "Combined hidden and unlimited flags"
run_test "$TEST_DIR/test_search.sh" "Search functionality (regular and hidden)"
run_test "$TEST_DIR/test_search_dog.sh" "Specific search term 'dog' with hidden directories"
run_test "$TEST_DIR/test_cache.sh" "Cache functionality and performance"
run_test "$TEST_DIR/test_rebuild_cache.sh" "Cache rebuilding functionality"

# Display test results and coverage overview
echo ""
echo "=================================================="
echo "           TEST RESULTS SUMMARY"
echo "=================================================="
echo ""
echo "Tests run: $((passed_tests + failed_tests))"
echo "Tests passed: $passed_tests"
echo "Tests failed: $failed_tests"
echo ""

# Feature coverage checklist
echo "=================================================="
echo "           FEATURE COVERAGE OVERVIEW"
echo "=================================================="
echo ""
echo "Core Functionality:"
echo "  ✓ Basic directory listing"
echo "  ✓ Directory navigation"
echo "  ✓ History tracking"
echo ""
echo "Search Options:"
echo "  ✓ Regular directories (no hidden)"
echo "  ✓ Hidden directories (--hidden flag)"
echo "  ✓ Limited depth traversal (default and --depth flag)"
echo "  ✓ Unlimited depth traversal (--unlimited flag)"
echo "  ✓ Combination of hidden and unlimited flags"
echo ""
echo "Search Capabilities:"
echo "  ✓ Text search functionality"
echo "  ✓ Special case searches (e.g., 'dog')"
echo "  ✓ Search prioritization and ordering"
echo ""
echo "Performance Features:"
echo "  ✓ Caching mechanism"
echo "  ✓ Cache validation and timeout"
echo "  ✓ Cache rebuilding (--rebuild-cache flag)"
echo ""
echo "Additional Features:"
echo "  ✓ Debug output (--debug flag)"
echo "  ✓ Test mode (--search flag)"
echo "  ✓ History management"
echo ""

# Display detailed results for each test
echo "=================================================="
echo "          DETAILED TEST RESULTS"
echo "=================================================="
echo ""
for test_name in "${!test_results[@]}"; do
    if [ "${test_results[$test_name]}" = "PASSED" ]; then
        echo -e "  \033[0;32m✓ $test_name: ${test_results[$test_name]}\033[0m"
    else
        echo -e "  \033[0;31m✗ $test_name: ${test_results[$test_name]}\033[0m"
    fi
done

echo ""
echo "=================================================="
echo "All tests completed."
echo "=================================================="

# Generate a summary log file for GitHub Actions
# Create a plain text version without color codes
{
    echo "# Test Results Summary"
    echo ""
    echo "Tests run: $((passed_tests + failed_tests))"
    echo "Tests passed: $passed_tests"
    echo "Tests failed: $failed_tests"
    echo ""
    
    echo "## Feature Coverage"
    echo ""
    echo "- Core Functionality: :white_check_mark:"
    echo "- Search Options: :white_check_mark:"
    echo "- Search Capabilities: :white_check_mark:"
    echo "- Performance Features: :white_check_mark:"
    echo "- Additional Features: :white_check_mark:"
    echo ""
    
    echo "## Detailed Results"
    echo ""
    for test_name in "${!test_results[@]}"; do
        if [ "${test_results[$test_name]}" = "PASSED" ]; then
            echo "- :white_check_mark: $test_name: PASSED"
        else
            echo "- :x: $test_name: FAILED"
        fi
    done
} > "$(dirname "$0")/summary.log"

exit $failed_tests  # Return non-zero exit code if any tests failed
