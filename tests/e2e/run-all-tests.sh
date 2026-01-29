#!/bin/bash
# run-all-tests.sh
#
# Runs all E2E tests for tmux-orchestrator and reports results
#
# Usage: ./run-all-tests.sh [--verbose]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERBOSE=false

if [[ "$1" == "--verbose" ]] || [[ "$1" == "-v" ]]; then
    VERBOSE=true
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     TMux Orchestrator - E2E Test Suite                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Running tests from: $SCRIPT_DIR"
echo ""

# Track results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
declare -a FAILED_TEST_NAMES

# Find and run all test scripts
for test_file in "$SCRIPT_DIR"/test-*.sh; do
    if [[ -f "$test_file" ]]; then
        test_name=$(basename "$test_file" .sh)
        TOTAL_TESTS=$((TOTAL_TESTS + 1))

        echo "─────────────────────────────────────────────────────"
        echo "Running: $test_name"
        echo "─────────────────────────────────────────────────────"

        if [[ "$VERBOSE" == true ]]; then
            # Run with full output
            "$test_file"
            exit_code=$?
        else
            # Run with minimal output
            output=$("$test_file" 2>&1)
            exit_code=$?

            # Show just the result line
            echo "$output" | grep -E "(✅ ALL TESTS PASSED|❌ SOME TESTS FAILED)"
        fi

        if [[ $exit_code -eq 0 ]]; then
            echo "Result: ✅ PASSED"
            PASSED_TESTS=$((PASSED_TESTS + 1))
        else
            echo "Result: ❌ FAILED"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("$test_name")
        fi
        echo ""
    fi
done

# Summary
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    TEST SUITE SUMMARY                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Total tests: $TOTAL_TESTS"
echo "Passed:      $PASSED_TESTS"
echo "Failed:      $FAILED_TESTS"
echo ""

if [[ $FAILED_TESTS -gt 0 ]]; then
    echo "Failed tests:"
    for name in "${FAILED_TEST_NAMES[@]}"; do
        echo "  - $name"
    done
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ❌ SOME TESTS FAILED                                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 1
else
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✅ ALL TESTS PASSED                                         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 0
fi
