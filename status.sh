#!/usr/bin/env bash
# Kept for compatibility: ./status.sh  ==  ./llm status
exec "$(dirname "${BASH_SOURCE[0]}")/llm" status "$@"
