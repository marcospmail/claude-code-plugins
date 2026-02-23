#!/usr/bin/env bash
# Check if running inside a tmux session.
# Outputs: IN_TMUX or NOT_IN_TMUX

if [ -n "$TMUX" ]; then
    echo "IN_TMUX"
else
    echo "NOT_IN_TMUX"
fi
