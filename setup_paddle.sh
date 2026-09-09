#!/usr/bin/env bash
# Wrapper to execute scripts/setup_paddle.sh from the repository root
exec "$(dirname "$0")/scripts/setup_paddle.sh" "$@"
