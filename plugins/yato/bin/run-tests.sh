#!/bin/bash
# run-tests.sh - Run unit tests
#
# Usage: run-tests.sh              # Run all unit tests (verbose)
# Usage: run-tests.sh --cov        # Run with coverage report
# Usage: run-tests.sh --module X   # Run specific module (e.g. tmux_utils)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YATO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

COV=false
MODULE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cov)
            COV=true
            shift
            ;;
        --module)
            MODULE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--cov] [--module <name>]"
            exit 1
            ;;
    esac
done

if [ -n "$MODULE" ]; then
    TARGET="$YATO_ROOT/tests/unit/test_${MODULE}.py"
    if [ ! -f "$TARGET" ]; then
        echo "Error: test file not found: $TARGET"
        exit 1
    fi
else
    TARGET="$YATO_ROOT/tests/unit/"
fi

if [ "$COV" = true ]; then
    uv run --project "$YATO_ROOT" pytest "$TARGET" --cov=lib --cov-report=term-missing
else
    uv run --project "$YATO_ROOT" pytest "$TARGET" -v
fi
