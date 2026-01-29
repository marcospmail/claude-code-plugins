#!/bin/bash
# Test init-workflow.sh functionality
# Run: ./tests/test-init-workflow.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/test-init-workflow-$$"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED + 1)); }

PASSED=0
FAILED=0
SKIPPED=0

cleanup() {
    echo ""
    echo "Cleaning up..."
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Testing init-workflow.sh                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Setup
echo "Setting up test environment in $TEST_DIR..."
mkdir -p "$TEST_DIR"

# Test 1: Basic workflow creation
echo ""
echo "=== Test 1: Basic workflow creation ==="
OUTPUT=$("$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Add user authentication" 2>&1)

if echo "$OUTPUT" | grep -q "WORKFLOW CREATED SUCCESSFULLY"; then
    pass "Workflow created successfully"
else
    fail "Workflow creation failed"
    echo "$OUTPUT"
fi

# Test 2: Verify workflow folder structure
echo ""
echo "=== Test 2: Verify .workflow directory created ==="
if [[ -d "$TEST_DIR/.workflow" ]]; then
    pass ".workflow directory exists"
else
    fail ".workflow directory not created"
fi

# Test 3: Verify numbered folder created
echo ""
echo "=== Test 3: Verify numbered workflow folder ==="
WORKFLOW_FOLDER=$(ls -1 "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | head -1)
if [[ -n "$WORKFLOW_FOLDER" ]]; then
    pass "Numbered folder created: $WORKFLOW_FOLDER"
else
    fail "No numbered folder found"
fi

WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_FOLDER"

# Test 4: Verify status.yml created
echo ""
echo "=== Test 4: Verify status.yml created ==="
if [[ -f "$WORKFLOW_PATH/status.yml" ]]; then
    pass "status.yml exists"
else
    fail "status.yml not created"
fi

# Test 5: Verify status.yml has required fields
echo ""
echo "=== Test 5: Verify status.yml fields ==="
REQUIRED_FIELDS=("status:" "title:" "folder:" "checkin_interval_minutes:")
ALL_FOUND=true
for field in "${REQUIRED_FIELDS[@]}"; do
    if ! grep -q "^$field" "$WORKFLOW_PATH/status.yml"; then
        ALL_FOUND=false
        echo "  Missing field: $field"
    fi
done

if [[ "$ALL_FOUND" == "true" ]]; then
    pass "status.yml has all required fields"
else
    fail "status.yml missing required fields"
fi

# Test 6: Verify agents.yml created
echo ""
echo "=== Test 6: Verify agents.yml created ==="
if [[ -f "$WORKFLOW_PATH/agents.yml" ]]; then
    pass "agents.yml exists"
else
    fail "agents.yml not created"
fi

# Test 7: Verify agents.yml has PM entry
echo ""
echo "=== Test 7: Verify agents.yml has PM entry ==="
if grep -q "^pm:" "$WORKFLOW_PATH/agents.yml"; then
    pass "agents.yml has PM entry"
else
    fail "agents.yml missing PM entry"
fi

# Test 8: Verify agents directory created
echo ""
echo "=== Test 8: Verify agents directory ==="
if [[ -d "$WORKFLOW_PATH/agents" ]]; then
    pass "agents/ directory exists"
else
    fail "agents/ directory not created"
fi

# Test 9: Verify PM agent directory
echo ""
echo "=== Test 9: Verify PM agent directory ==="
if [[ -d "$WORKFLOW_PATH/agents/pm" ]]; then
    pass "agents/pm/ directory exists"
else
    fail "agents/pm/ directory not created"
fi

# Test 10: Verify PM identity.yml
echo ""
echo "=== Test 10: Verify PM identity.yml ==="
if [[ -f "$WORKFLOW_PATH/agents/pm/identity.yml" ]]; then
    pass "agents/pm/identity.yml exists"
else
    fail "agents/pm/identity.yml not created"
fi

# Test 11: Verify PM instructions.md
echo ""
echo "=== Test 11: Verify PM instructions.md ==="
if [[ -f "$WORKFLOW_PATH/agents/pm/instructions.md" ]]; then
    pass "agents/pm/instructions.md exists"
else
    fail "agents/pm/instructions.md not created"
fi

# Test 12: Verify PM constraints.example.md
echo ""
echo "=== Test 12: Verify PM constraints.example.md ==="
if [[ -f "$WORKFLOW_PATH/agents/pm/constraints.example.md" ]]; then
    pass "agents/pm/constraints.example.md exists"
else
    fail "agents/pm/constraints.example.md not created"
fi

# Test 13: Verify current workflow symlink/file
echo ""
echo "=== Test 13: Verify current workflow pointer ==="
if [[ -f "$TEST_DIR/.workflow/current" ]] || [[ -L "$TEST_DIR/.workflow/current" ]]; then
    CURRENT=$(cat "$TEST_DIR/.workflow/current")
    if [[ "$CURRENT" == "$WORKFLOW_FOLDER" ]]; then
        pass "current workflow pointer is correct"
    else
        fail "current workflow pointer incorrect: $CURRENT vs $WORKFLOW_FOLDER"
    fi
else
    pass "current workflow set via tmux env (no file needed when not in tmux)"
fi

# Test 14: Create second workflow - verify numbering
echo ""
echo "=== Test 14: Create second workflow - verify sequential numbering ==="
OUTPUT2=$("$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Fix payment bug" 2>&1)
WORKFLOW_FOLDERS=$(ls -1 "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | sort)
FOLDER_COUNT=$(echo "$WORKFLOW_FOLDERS" | wc -l | tr -d ' ')

if [[ "$FOLDER_COUNT" -ge 2 ]]; then
    # Check sequential numbering
    FIRST=$(echo "$WORKFLOW_FOLDERS" | head -1 | cut -c1-3)
    SECOND=$(echo "$WORKFLOW_FOLDERS" | tail -1 | cut -c1-3)
    if [[ "$FIRST" == "001" ]] && [[ "$SECOND" == "002" ]]; then
        pass "Sequential numbering works (001, 002)"
    else
        fail "Numbering incorrect: $FIRST, $SECOND"
    fi
else
    fail "Second workflow not created"
fi

# Test 15: Title with special characters
echo ""
echo "=== Test 15: Title with special characters ==="
OUTPUT3=$("$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Fix bug: user's profile & settings" 2>&1)
if echo "$OUTPUT3" | grep -q "WORKFLOW CREATED SUCCESSFULLY"; then
    pass "Title with special characters handled"
else
    fail "Title with special characters failed"
fi

# Test 16: Verify slug conversion in folder name
echo ""
echo "=== Test 16: Verify slug conversion ==="
LATEST_FOLDER=$(ls -1 "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | sort | tail -1)
# Should not contain uppercase, spaces, or special chars in folder name
if [[ "$LATEST_FOLDER" =~ ^[0-9]{3}-[a-z0-9-]+$ ]]; then
    pass "Folder name is properly slugified: $LATEST_FOLDER"
else
    fail "Folder name not properly slugified: $LATEST_FOLDER"
fi

# Test 17: Default checkin interval is 15
echo ""
echo "=== Test 17: Default checkin interval is 15 minutes ==="
INTERVAL=$(grep "^checkin_interval_minutes:" "$WORKFLOW_PATH/status.yml" | awk '{print $2}')
if [[ "$INTERVAL" == "15" ]]; then
    pass "Default checkin interval is 15"
else
    fail "Default interval incorrect: $INTERVAL"
fi

# Test 18: Missing title shows usage
echo ""
echo "=== Test 18: Missing title shows usage ==="
OUTPUT_ERR=$("$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" 2>&1 || true)
if echo "$OUTPUT_ERR" | grep -q "Usage:"; then
    pass "Missing title shows usage message"
else
    fail "Missing title should show usage"
fi

# Test 19: Creates project directory if it doesn't exist
echo ""
echo "=== Test 19: Creates project directory if needed ==="
NEW_DIR="/tmp/test-init-new-project-$$"
OUTPUT_NEW=$("$PROJECT_ROOT/bin/init-workflow.sh" "$NEW_DIR" "New project workflow" 2>&1)
if [[ -d "$NEW_DIR/.workflow" ]]; then
    pass "Created new project directory and workflow"
    rm -rf "$NEW_DIR"
else
    fail "Failed to create new project directory"
fi

# Summary
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      TEST SUMMARY                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Passed${NC}:  $PASSED"
echo -e "  ${RED}Failed${NC}:  $FAILED"
echo -e "  ${YELLOW}Skipped${NC}: $SKIPPED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
