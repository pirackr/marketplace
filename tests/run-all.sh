#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0

run_test() {
  local name="$1" script="$2"
  if bash "$script"; then
    echo "  PASS: $name"; PASS=$((PASS+1))
  else
    echo "  FAIL: $name"; FAIL=$((FAIL+1))
  fi
}

run_test "plugin-meta"   "$TESTS_DIR/test-plugin-meta.sh"
run_test "stop-hook"     "$TESTS_DIR/test-stop-hook.sh"
run_test "skill-docs"    "$TESTS_DIR/test-skill-docs.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
