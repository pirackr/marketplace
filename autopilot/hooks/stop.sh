#!/usr/bin/env bash
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }
command -v shasum >/dev/null 2>&1 || { echo '{}'; exit 0; }

HOOK_INPUT=$(cat)
SESSION_ID=$(jq -r '.session_id' <<< "$HOOK_INPUT")
TRANSCRIPT_PATH=$(jq -r '.transcript_path' <<< "$HOOK_INPUT")

if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then exit 0; fi

STATE_DIR="${AUTOPILOT_STATE_DIR:-$HOME/.claude/autopilot}"
STATE_FILE="${STATE_DIR}/active-plan-${SESSION_ID}"
SIG_FILE="${STATE_DIR}/active-plan-signature-${SESSION_ID}"
SUMMARY_DIR="${STATE_DIR}/plan-summaries"

# No active plan → allow stop
[ -f "$STATE_FILE" ] || exit 0

PLAN_PATH=$(cat "$STATE_FILE")

# Plan file gone → clean up both markers, allow stop with a visible notice
if [ ! -f "$PLAN_PATH" ]; then
  rm -f "$STATE_FILE" "$SIG_FILE"
  REASON="Autopilot stopped because the active plan for this session could not be resolved.

- The plan marker existed, but the referenced plan file is missing.
- I am not continuing because this session is in plan-backed mode.

Tell me what changed, then restart /autopilot with a valid plan if you want to continue."
  jq -n --arg reason "$REASON" --arg msg "⚠ Autopilot halted — active plan missing" \
    '{"decision":"block","reason":$reason,"systemMessage":$msg}'
  exit 0
fi

# Count tasks (grep -c prints 0 and exits 1 on no match; || true prevents pipefail abort)
UNCHECKED=$(grep -c '^\s*- \[ \]' "$PLAN_PATH" 2>/dev/null || true)
CHECKED=$(grep -ci '^\s*- \[x\]' "$PLAN_PATH" 2>/dev/null || true)
TOTAL=$((UNCHECKED + CHECKED))

# All done → clean up, allow stop
if [ "$UNCHECKED" -eq 0 ]; then
  rm -f "$STATE_FILE" "$SIG_FILE"
  exit 0
fi

# ---- plan signature (drift detection) ----
PLAN_SIG=$(shasum -a 256 "$PLAN_PATH" | awk '{print $1}')
PREV_SIG=""
[ -f "$SIG_FILE" ] && PREV_SIG=$(tr -d '[:space:]' < "$SIG_FILE")
SIG_DRIFT=0
if [ -n "$PREV_SIG" ] && [ "$PREV_SIG" != "$PLAN_SIG" ]; then
  SIG_DRIFT=1
fi

# ---- summary file path ----
PLAN_PATH_HASH=$(printf '%s' "$PLAN_PATH" | shasum -a 256 | awk '{print $1}')
RAW_BASE=$(basename "$PLAN_PATH" .md | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
[ -n "$RAW_BASE" ] || RAW_BASE="plan"
SANITIZED_BASE=$(printf '%s' "$RAW_BASE" | cut -c1-48)
SUMMARY_FILE="${SUMMARY_DIR}/${SANITIZED_BASE}-${PLAN_PATH_HASH}.md"

# First unchecked task description (without the "- [ ]" prefix)
FIRST_UNCHECKED=$(grep -m1 '^[[:space:]]*- \[ \]' "$PLAN_PATH" 2>/dev/null | sed -E 's/^[[:space:]]*- \[ \][[:space:]]*//' || true)

# Create a default summary if none exists so the orchestrator has something to read
mkdir -p "$SUMMARY_DIR"
if [ ! -f "$SUMMARY_FILE" ]; then
  cat > "$SUMMARY_FILE" <<EOF
# Autopilot Summary

## Current Task
${FIRST_UNCHECKED:-Resume the next unchecked task in the active plan.}

## Next Step
Inspect the current task and take the next concrete action.

## Blockers
- none

## Recent Progress
- summary initialized from active plan

## Learnings
- none yet
EOF
fi

# Parse a "## Section" body from the summary (trim leading/trailing blanks)
parse_section() {
  local file="$1" section="$2"
  awk -v s="## ${section}" '
    $0 == s { flag=1; next }
    /^## / { flag=0 }
    flag { print }
  ' "$file" | awk 'NF {p=1} p' | awk 'BEGIN{n=0} {lines[n++]=$0} END{ end=n-1; while(end>=0 && lines[end]~/^\s*$/) end--; for(i=0;i<=end;i++) print lines[i] }'
}

SUMMARY_CURRENT=$(parse_section "$SUMMARY_FILE" "Current Task")
SUMMARY_NEXT=$(parse_section "$SUMMARY_FILE" "Next Step")
SUMMARY_BLOCKERS=$(parse_section "$SUMMARY_FILE" "Blockers")
SUMMARY_PROGRESS=$(parse_section "$SUMMARY_FILE" "Recent Progress")

MISSING_SECTIONS=""
for s in "Current Task" "Next Step" "Blockers" "Recent Progress" "Learnings"; do
  if ! grep -q "^## ${s}\$" "$SUMMARY_FILE"; then
    MISSING_SECTIONS="${MISSING_SECTIONS:+$MISSING_SECTIONS, }${s}"
  fi
done

STALE_CURRENT=0
if [ -n "$FIRST_UNCHECKED" ] && [ -n "$SUMMARY_CURRENT" ] && [ "$SUMMARY_CURRENT" != "$FIRST_UNCHECKED" ]; then
  STALE_CURRENT=1
fi

SHOULD_RECONCILE=0
if [ "$SIG_DRIFT" -eq 1 ] || [ -n "$MISSING_SECTIONS" ] || [ "$STALE_CURRENT" -eq 1 ]; then
  SHOULD_RECONCILE=1
fi

# ---- context-size compaction check (unchanged behavior) ----
COMPACT_THRESHOLD=600000
TRANSCRIPT_SIZE=0
if [ -f "$TRANSCRIPT_PATH" ]; then
  TRANSCRIPT_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
fi

# ---- build reason ----
REASON="Incomplete tasks remain in the active plan. Continue working on the next pending task.

- Proceed without asking for permission.
- Use the active plan as the source of truth.
- Update the summary file after every completed task and after any meaningful progress.
- Refresh Current Task, Next Step, Blockers, and Recent Progress before yielding control.
- If blockers changed, record them before stopping."

if [ "$TRANSCRIPT_SIZE" -gt "$COMPACT_THRESHOLD" ]; then
  REASON="${REASON}
- Run /compact to compress context before continuing."
fi

if [ "$SHOULD_RECONCILE" -eq 1 ]; then
  REASON="${REASON}
- Reconcile the summary with the current checklist before proceeding."
fi

if [ -n "$MISSING_SECTIONS" ]; then
  REASON="${REASON}
- Restore the canonical summary sections: ${MISSING_SECTIONS}."
fi

REASON="${REASON}

[Plan Status: ${CHECKED}/${TOTAL} completed, ${UNCHECKED} remaining]
[Plan Path: ${PLAN_PATH}]
[Summary Path: ${SUMMARY_FILE}]
[Current Task: ${SUMMARY_CURRENT:-(missing)}]
[Next Step: ${SUMMARY_NEXT:-(missing)}]
[Blockers: ${SUMMARY_BLOCKERS:-(missing)}]"

if [ -n "$SUMMARY_PROGRESS" ]; then
  REASON="${REASON}
[Recent Progress: ${SUMMARY_PROGRESS}]"
fi

# ---- system message: surface what's actually happening to the user ----
LAST_PROGRESS=$(printf '%s\n' "$SUMMARY_PROGRESS" | grep -E '^\s*-\s' | tail -1 | sed -E 's/^\s*-\s*//' || true)
SHORT_CURRENT=$(printf '%s' "${SUMMARY_CURRENT:-unknown}" | cut -c1-80)
if [ "$TRANSCRIPT_SIZE" -gt "$COMPACT_THRESHOLD" ]; then
  SYS_MSG="⚡ Autopilot compacting (${CHECKED}/${TOTAL}) — ${SHORT_CURRENT}"
else
  SYS_MSG="🔄 Autopilot (${CHECKED}/${TOTAL}) — ${SHORT_CURRENT}"
fi
if [ -n "$LAST_PROGRESS" ]; then
  SYS_MSG="${SYS_MSG} · last: ${LAST_PROGRESS}"
fi

# persist current signature
printf '%s\n' "$PLAN_SIG" > "$SIG_FILE"

jq -n --arg reason "$REASON" --arg msg "$SYS_MSG" \
  '{"decision":"block","reason":$reason,"systemMessage":$msg}'

exit 0
