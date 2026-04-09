#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOP_HOOK="$PLUGIN_ROOT/hooks/stop.sh"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

SESSION_ID="test-session-$$"
STATE_DIR="$TMPDIR_TEST/autopilot"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/active-plan-${SESSION_ID}"
TRANSCRIPT="$TMPDIR_TEST/transcript.jsonl"
touch "$TRANSCRIPT"

make_input() {
  jq -n --arg s "$SESSION_ID" --arg t "$TRANSCRIPT" \
    '{"session_id":$s,"transcript_path":$t}'
}

# --- Test 1: No state file → exit 0, no output ---
OUTPUT=$(make_input | AUTOPILOT_STATE_DIR="$STATE_DIR" bash "$STOP_HOOK" 2>/dev/null || true)
[ -z "$OUTPUT" ] || { echo "FAIL test1: expected no output, got: $OUTPUT"; exit 1; }
echo "  test1 pass: no state file → allow stop"

# --- Test 2: State file exists, plan has 0 unchecked → exit 0, state file removed ---
PLAN="$TMPDIR_TEST/plan.md"
printf -- "- [x] **Done task**\n" > "$PLAN"
echo "$PLAN" > "$STATE_FILE"
OUTPUT=$(make_input | AUTOPILOT_STATE_DIR="$STATE_DIR" bash "$STOP_HOOK" 2>/dev/null || true)
[ -z "$OUTPUT" ] || { echo "FAIL test2: expected no output, got: $OUTPUT"; exit 1; }
[ ! -f "$STATE_FILE" ] || { echo "FAIL test2: state file should be removed"; exit 1; }
echo "  test2 pass: all done → allow stop, remove state"

# --- Test 3: Tasks remain → decision:block with status ---
printf -- "- [x] **Done**\n- [ ] **Pending**\n" > "$PLAN"
echo "$PLAN" > "$STATE_FILE"
OUTPUT=$(make_input | AUTOPILOT_STATE_DIR="$STATE_DIR" bash "$STOP_HOOK")
echo "$OUTPUT" | jq -e '.decision == "block"' > /dev/null || { echo "FAIL test3: expected decision:block"; exit 1; }
echo "$OUTPUT" | jq -e '.reason | test("1/2")' > /dev/null || { echo "FAIL test3: expected status in reason"; exit 1; }
echo "  test3 pass: tasks remain → block with status"

# --- Test 4: Large transcript → compact instruction in reason ---
echo "$PLAN" > "$STATE_FILE"
dd if=/dev/zero bs=1024 count=700 2>/dev/null | tr '\0' 'x' > "$TRANSCRIPT"
OUTPUT=$(make_input | AUTOPILOT_STATE_DIR="$STATE_DIR" bash "$STOP_HOOK")
echo "$OUTPUT" | jq -e '.reason | test("compact")' > /dev/null || { echo "FAIL test4: expected compact in reason"; exit 1; }
echo "  test4 pass: large transcript → compact instruction"

echo "stop-hook tests OK"
