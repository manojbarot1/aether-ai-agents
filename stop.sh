#!/usr/bin/env bash
# Kept for compatibility: ./stop.sh [N | :port]  ==  ./llm stop freellm [N | :port]
exec "$(dirname "${BASH_SOURCE[0]}")/llm" stop freellm "$@"
