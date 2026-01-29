#!/bin/bash
# test-pm-checkin-askuser.sh
#
# E2E Test: Verify PM uses AskUserQuestion tool for check-in frequency
#
# This test spawns Claude in headless mode and instructs it to verify
# that the PM briefing instructs usage of AskUserQuestion with specific options.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-checkin-askuser"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: PM Check-in AskUserQuestion                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test directory: $TEST_DIR"
echo "Project root: $PROJECT_ROOT"
echo ""

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    tmux kill-session -t "e2e-test-$$" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Setup test environment
echo "Step 1: Setting up test environment..."
mkdir -p "$TEST_DIR"
echo "function test() { return true; }" > "$TEST_DIR/app.js"

# 2. Run Claude in headless mode with test instructions
echo "Step 2: Running Claude to verify PM briefing..."
echo ""

TEST_PROMPT="You are an automated test verifier. Your job is to check if a specific feature exists in the codebase.

FEATURE TO TEST: PM uses AskUserQuestion tool for check-in frequency

VERIFICATION STEPS:
1. Read the file: $PROJECT_ROOT/lib/orchestrator.py
2. Find step 7 in the PM briefing (search for 'check-in interval' or 'step 7')
3. Verify it instructs the PM to use 'AskUserQuestion tool'
4. Verify it specifies these options: '3 minutes', '5 minutes', '10 minutes'
5. Verify '5 minutes' is marked as '(Recommended)'

IMPORTANT:
- Use the Read tool to examine the file
- Search for the relevant section
- Do NOT assume - actually verify by reading the code

After verification, output ONLY a JSON object (no other text):
{
  \"passed\": true or false,
  \"feature\": \"pm-checkin-askuser\",
  \"reason\": \"brief explanation\",
  \"evidence\": \"quote the relevant code snippet you found\"
}"

# Run Claude with the test prompt
RESULT=$(claude -p "$TEST_PROMPT" --model haiku --dangerously-skip-permissions 2>/dev/null)

echo "Claude response:"
echo "─────────────────────────────────────────────────────"
echo "$RESULT"
echo "─────────────────────────────────────────────────────"
echo ""

# 3. Parse result
echo "Step 3: Parsing result..."

# Try to extract JSON from the response (handle markdown code blocks)
# First try to get JSON from code blocks, then fall back to raw extraction
JSON_RESULT=$(echo "$RESULT" | sed -n '/```json/,/```/p' | grep -v '```' | tr '\n' ' ' || true)

# If no code block found, try to extract raw JSON
if [[ -z "$JSON_RESULT" ]] || [[ "$JSON_RESULT" == " " ]]; then
    JSON_RESULT=$(echo "$RESULT" | grep -o '{[^}]*"passed"[^}]*}' | head -1 || echo '{"passed": false, "reason": "Could not parse JSON"}')
fi

# Clean up any extra whitespace
JSON_RESULT=$(echo "$JSON_RESULT" | tr -s ' ')

PASSED=$(echo "$JSON_RESULT" | jq -r '.passed' 2>/dev/null || echo "false")
REASON=$(echo "$JSON_RESULT" | jq -r '.reason' 2>/dev/null || echo "Parse error")
EVIDENCE=$(echo "$JSON_RESULT" | jq -r '.evidence' 2>/dev/null || echo "")

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ "$PASSED" == "true" ]]; then
    echo "║  ✅ TEST PASSED                                              ║"
    EXIT_CODE=0
else
    echo "║  ❌ TEST FAILED                                              ║"
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Reason: $REASON"
if [[ -n "$EVIDENCE" ]] && [[ "$EVIDENCE" != "null" ]]; then
    echo ""
    echo "Evidence: $EVIDENCE"
fi
echo ""

exit $EXIT_CODE
