#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

check_frontmatter() {
  local file="$1" field="$2"
  if ! grep -q "^${field}:" "$file"; then
    echo "  MISSING $field in $file"
    FAIL=1
  fi
}

# Check all skills have name + description
for skill in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  check_frontmatter "$skill" "name"
  check_frontmatter "$skill" "description"
done

# Check autopilot command has description + argument-hint
CMD="$PLUGIN_ROOT/commands/autopilot.md"
[ -f "$CMD" ] || { echo "Missing commands/autopilot.md"; exit 1; }
check_frontmatter "$CMD" "description"
check_frontmatter "$CMD" "argument-hint"

[ "$FAIL" -eq 0 ] || { echo "skill-docs FAILED"; exit 1; }
echo "skill-docs OK"
