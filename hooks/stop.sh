#!/usr/bin/env bash
set -euo pipefail

HOOK_INPUT=$(cat)
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id')
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

STATE_DIR="${AUTOPILOT_STATE_DIR:-$HOME/.claude/autopilot}"
STATE_FILE="${STATE_DIR}/active-plan-${SESSION_ID}"

# No active plan → allow stop
[ -f "$STATE_FILE" ] || exit 0

PLAN_PATH=$(cat "$STATE_FILE")

# Plan file gone → clean up, allow stop
if [ ! -f "$PLAN_PATH" ]; then
  rm -f "$STATE_FILE"
  exit 0
fi

# Count tasks (disable pipefail temporarily so grep exit-1 on no-match doesn't abort)
set +o pipefail
UNCHECKED=$(grep -E '^\s*- \[ \]' "$PLAN_PATH" 2>/dev/null | wc -l | tr -d ' ')
CHECKED=$(grep -Ei '^\s*- \[x\]' "$PLAN_PATH" 2>/dev/null | wc -l | tr -d ' ')
set -o pipefail
TOTAL=$((UNCHECKED + CHECKED))

# All done → clean up, allow stop
if [ "$UNCHECKED" -eq 0 ]; then
  rm -f "$STATE_FILE"
  exit 0
fi

# Check context size (token proxy: ~4 chars/token, threshold ~150K tokens)
COMPACT_THRESHOLD=600000
TRANSCRIPT_SIZE=0
if [ -f "$TRANSCRIPT_PATH" ]; then
  TRANSCRIPT_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
fi

if [ "$TRANSCRIPT_SIZE" -gt "$COMPACT_THRESHOLD" ]; then
  REASON="Run /compact to compress context, then continue with the next pending task.

- Proceed without asking for permission
- Do not stop until all tasks are done
[Status: ${CHECKED}/${TOTAL} completed, ${UNCHECKED} remaining]"
  SYS_MSG="⚡ Context large — compacting before continuing (${CHECKED}/${TOTAL} done)"
else
  REASON="Incomplete tasks remain. Continue with the next pending task.

- Proceed without asking for permission
- Do not stop until all tasks are done
[Status: ${CHECKED}/${TOTAL} completed, ${UNCHECKED} remaining]"
  SYS_MSG="🔄 Autopilot continuing (${CHECKED}/${TOTAL} done, ${UNCHECKED} remaining)"
fi

jq -n --arg reason "$REASON" --arg msg "$SYS_MSG" \
  '{"decision":"block","reason":$reason,"systemMessage":$msg}'
