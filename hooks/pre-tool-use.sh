#!/usr/bin/env bash
# PreToolUse hook — receives JSON on stdin
# Exit 0 to allow, non-zero to block

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty')
tool_input=$(echo "$input" | jq -r '.tool_input // empty')

# Add your logic here
# Example: log all tool calls
# echo "[hook] $tool_name: $tool_input" >> /tmp/claude-tools.log

exit 0
