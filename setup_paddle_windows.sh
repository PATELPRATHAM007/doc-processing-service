#!/usr/bin/env bash
# Wrapper to execute scripts/setup_paddle_windows.sh from the repository root
exec "$(dirname "$0")/scripts/setup_paddle_windows.sh" "$@"
