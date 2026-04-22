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
SIG_FILE="$STATE_DIR/active-plan-signature-${SESSION_ID}"
TRANSCRIPT="$TMPDIR_TEST/transcript.jsonl"
touch "$TRANSCRIPT"

make_input() {
  jq -n --arg s "$SESSION_ID" --arg t "$TRANSCRIPT" \
    '{"session_id":$s,"transcript_path":$t}'
}

run_hook() {
  make_input | AUTOPILOT_STATE_DIR="$STATE_DIR" bash "$STOP_HOOK"
}

# --- Test 1: No state file → exit 0, no output ---
OUTPUT=$(make_input | AUTOPILOT_STATE_DIR="$STATE_DIR" bash "$STOP_HOOK" 2>/dev/null || true)
[ -z "$OUTPUT" ] || { echo "FAIL test1: expected no output, got: $OUTPUT"; exit 1; }
echo "  test1 pass: no state file → allow stop"

# --- Test 2: State file exists, plan has 0 unchecked → exit 0, both markers removed ---
PLAN="$TMPDIR_TEST/plan.md"
printf -- "- [x] **Done task**\n" > "$PLAN"
echo "$PLAN" > "$STATE_FILE"
echo "deadbeef" > "$SIG_FILE"
OUTPUT=$(run_hook 2>/dev/null || true)
[ -z "$OUTPUT" ] || { echo "FAIL test2: expected no output, got: $OUTPUT"; exit 1; }
[ ! -f "$STATE_FILE" ] || { echo "FAIL test2: state file should be removed"; exit 1; }
[ ! -f "$SIG_FILE" ] || { echo "FAIL test2: signature file should be removed"; exit 1; }
echo "  test2 pass: all done → allow stop, remove both markers"

# --- Test 3: Tasks remain → decision:block with plan status, creates summary + signature ---
printf -- "- [x] **Done**\n- [ ] ship feature\n" > "$PLAN"
echo "$PLAN" > "$STATE_FILE"
rm -f "$SIG_FILE"
OUTPUT=$(run_hook)
echo "$OUTPUT" | jq -e '.decision == "block"' > /dev/null || { echo "FAIL test3: expected decision:block"; exit 1; }
echo "$OUTPUT" | jq -e '.reason | test("1/2 completed")' > /dev/null || { echo "FAIL test3: expected plan status in reason"; exit 1; }
echo "$OUTPUT" | jq -e '.reason | test("\\[Current Task: ship feature\\]")' > /dev/null || { echo "FAIL test3: expected Current Task"; exit 1; }
echo "$OUTPUT" | jq -e '.systemMessage | test("ship feature")' > /dev/null || { echo "FAIL test3: systemMessage should surface current task"; exit 1; }
[ -f "$SIG_FILE" ] || { echo "FAIL test3: signature file should be created"; exit 1; }
# Summary file should exist under plan-summaries/
SUMMARY_COUNT=$(find "$STATE_DIR/plan-summaries" -type f -name "*.md" | wc -l | tr -d ' ')
[ "$SUMMARY_COUNT" -ge 1 ] || { echo "FAIL test3: summary file should be created"; exit 1; }
echo "  test3 pass: tasks remain → block, creates summary + signature"

# --- Test 4: Large transcript → compact instruction in reason ---
echo "$PLAN" > "$STATE_FILE"
dd if=/dev/zero bs=1024 count=700 2>/dev/null | tr '\0' 'x' > "$TRANSCRIPT"
OUTPUT=$(run_hook)
echo "$OUTPUT" | jq -e '.reason | test("/compact")' > /dev/null || { echo "FAIL test4: expected /compact in reason"; exit 1; }
echo "  test4 pass: large transcript → compact instruction"
truncate -s 0 "$TRANSCRIPT"

# --- Test 5: Plan signature drift triggers reconcile instruction ---
# Reset: fresh plan, run once to seed signature
printf -- "- [ ] first task\n- [ ] second task\n" > "$PLAN"
echo "$PLAN" > "$STATE_FILE"
rm -f "$SIG_FILE"
run_hook > /dev/null
[ -f "$SIG_FILE" ] || { echo "FAIL test5: signature file should have been written"; exit 1; }
# Mutate plan → drift
printf -- "- [ ] first task\n- [ ] second task updated\n" > "$PLAN"
OUTPUT=$(run_hook)
echo "$OUTPUT" | jq -e '.reason | test("Reconcile the summary")' > /dev/null || { echo "FAIL test5: expected reconcile instruction after drift"; exit 1; }
echo "  test5 pass: plan signature drift → reconcile instruction"

# --- Test 6: Plan file disappears → both markers cleared, explicit halt message ---
rm -f "$PLAN"
echo "$PLAN" > "$STATE_FILE"
echo "abc123" > "$SIG_FILE"
OUTPUT=$(run_hook)
echo "$OUTPUT" | jq -e '.reason | test("active plan for this session could not be resolved")' > /dev/null || { echo "FAIL test6: expected halt reason"; exit 1; }
[ ! -f "$STATE_FILE" ] || { echo "FAIL test6: state file should be removed"; exit 1; }
[ ! -f "$SIG_FILE" ] || { echo "FAIL test6: signature file should be removed"; exit 1; }
echo "  test6 pass: plan missing → halt and clean markers"

# --- Test 7: Stale Current Task in existing summary triggers reconcile ---
printf -- "- [ ] brand new task\n" > "$PLAN"
echo "$PLAN" > "$STATE_FILE"
rm -f "$SIG_FILE"
# Manually seed a stale summary
SUMMARY_DIR="$STATE_DIR/plan-summaries"
mkdir -p "$SUMMARY_DIR"
# Recreate the same filename algorithm would produce by running the hook once first,
# then overwriting the content so Current Task is stale.
run_hook > /dev/null
SUMMARY_FILE=$(find "$SUMMARY_DIR" -type f -name "*.md" | head -1)
cat > "$SUMMARY_FILE" <<EOF
# Autopilot Summary

## Current Task
some old task that no longer matches

## Next Step
something

## Blockers
- none

## Recent Progress
- nothing recent

## Learnings
- none yet
EOF
OUTPUT=$(run_hook)
echo "$OUTPUT" | jq -e '.reason | test("Reconcile the summary")' > /dev/null || { echo "FAIL test7: expected reconcile when Current Task is stale"; exit 1; }
echo "  test7 pass: stale Current Task → reconcile instruction"

echo "stop-hook tests OK"
