#!/bin/bash
# Test checkin interval save and read functionality
# Run: ./tests/test-checkin-interval.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/test-checkin-interval-$$"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

echo "=== Testing Checkin Interval Save/Read ==="
echo ""

# Setup
echo "Setting up test environment in $TEST_DIR..."
mkdir -p "$TEST_DIR"

# Source workflow utils
source "$PROJECT_ROOT/bin/workflow-utils.sh"

# Test 1: Create workflow with default interval
echo ""
echo "Test 1: Create workflow has default interval of 15"
WORKFLOW_NAME=$(create_workflow_folder "$TEST_DIR" "Test Workflow")
STATUS_FILE="$TEST_DIR/.workflow/$WORKFLOW_NAME/status.yml"

if [[ -f "$STATUS_FILE" ]]; then
    INTERVAL=$(grep "^checkin_interval_minutes:" "$STATUS_FILE" | awk '{print $2}')
    if [[ "$INTERVAL" == "15" ]]; then
        pass "Default interval is 15"
    else
        fail "Expected 15, got $INTERVAL"
    fi
else
    fail "status.yml not created"
fi

# Test 2: Update interval to 5
echo ""
echo "Test 2: Update interval to 5 minutes"
# Create current file for workflow discovery (since we're not in tmux)
echo "$WORKFLOW_NAME" > "$TEST_DIR/.workflow/current"
update_checkin_interval "$TEST_DIR" 5

INTERVAL=$(grep "^checkin_interval_minutes:" "$STATUS_FILE" | awk '{print $2}')
if [[ "$INTERVAL" == "5" ]]; then
    pass "Interval updated to 5"
else
    fail "Expected 5, got $INTERVAL"
fi

# Test 3: Read interval using the PM's grep command
echo ""
echo "Test 3: Read interval using PM grep command"
CURRENT=$(cat "$TEST_DIR/.workflow/current")
READ_INTERVAL=$(grep checkin_interval_minutes "$TEST_DIR/.workflow/$CURRENT/status.yml" | awk '{print $2}')

if [[ "$READ_INTERVAL" == "5" ]]; then
    pass "PM grep command reads correct interval: $READ_INTERVAL"
else
    fail "PM grep command failed, got: $READ_INTERVAL"
fi

# Test 4: Update to different value
echo ""
echo "Test 4: Update interval to 2 minutes"
update_checkin_interval "$TEST_DIR" 2

INTERVAL=$(grep "^checkin_interval_minutes:" "$STATUS_FILE" | awk '{print $2}')
if [[ "$INTERVAL" == "2" ]]; then
    pass "Interval updated to 2"
else
    fail "Expected 2, got $INTERVAL"
fi

# Test 5: Verify schedule-checkin.sh would use correct value
echo ""
echo "Test 5: Verify interval is readable for schedule-checkin.sh"
INTERVAL=$(grep checkin_interval_minutes "$TEST_DIR/.workflow/$(cat $TEST_DIR/.workflow/current)/status.yml" | awk '{print $2}')
if [[ "$INTERVAL" == "2" ]]; then
    pass "Interval correctly reads as 2 for scheduling"
else
    fail "Expected 2, got $INTERVAL"
fi

# Cleanup
echo ""
echo "Cleaning up..."
rm -rf "$TEST_DIR"

echo ""
echo "=== All tests passed! ==="
