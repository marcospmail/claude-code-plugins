#!/bin/bash
# test-helpers.sh - Shared helpers for e2e tests
#
# Source this file at the top of tests:
#   source "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

# Create a tmux session with retry logic.
# Usage: create_test_session [-n window_name] [-x width] [-y height]
# Requires: TMUX_SOCKET, SESSION_NAME, TEST_DIR to be set
create_test_session() {
    local extra_args=("$@")
    local max_retries=5

    for i in $(seq 1 $max_retries); do
        tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" "${extra_args[@]}" 2>/dev/null

        if tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
            return 0
        fi

        sleep 1
    done

    echo "ERROR: Failed to create tmux session '$SESSION_NAME' after $max_retries retries" >&2
    return 1
}
