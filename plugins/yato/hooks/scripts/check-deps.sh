#!/bin/bash
# check-deps.sh - Check for required dependencies at session start
#
# This script runs on SessionStart and checks if tmux is installed.
# If missing, it outputs context that instructs Claude to ask the user
# if they want to open the tmux website to learn how to install it.

# Check if tmux is installed
if ! command -v tmux &> /dev/null; then
    # Output context for Claude to act on
    # This will be added to Claude's context and it can use AskUserQuestion
    cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "YATO DEPENDENCY CHECK: tmux is NOT installed on this system. tmux is REQUIRED for Yato to function. You MUST use AskUserQuestion to ask the user: 'Yato requires tmux but it is not installed. Would you like me to open the tmux website so you can learn how to install it?' with options: 1) 'Yes, open tmux website' (description: 'Opens https://github.com/tmux/tmux/wiki with installation instructions') 2) 'No thanks' (description: 'Skip for now - Yato skills will not work until tmux is installed'). If they choose Yes, run: open https://github.com/tmux/tmux/wiki (macOS) or xdg-open https://github.com/tmux/tmux/wiki (Linux). If they choose No, inform them that Yato skills will not work until tmux is installed."
  }
}
EOF
    exit 0
fi

# tmux is installed - no action needed
exit 0
