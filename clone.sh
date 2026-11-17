#!/usr/bin/env bash
# Kept for compatibility: ./clone.sh [:port]  ==  ./llm clone [:port]
exec "$(dirname "${BASH_SOURCE[0]}")/llm" clone "$@"
