# E2E Tests Not Running From Inside Tmux

All tests have been migrated to run their logic through tmux sessions using `tmux send-keys`.

No remaining tests run commands directly via bash without a tmux session.
