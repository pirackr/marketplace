#!/usr/bin/env bash
# PostToolUse hook — receives JSON on stdin

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty')

# Add your logic here

exit 0
