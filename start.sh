#!/usr/bin/env bash
# Kept for compatibility: ./start.sh N [--update]  ==  ./llm start freellm N [--update]
exec "$(dirname "${BASH_SOURCE[0]}")/llm" start freellm "$@"
