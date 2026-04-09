#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$PLUGIN_JSON" ] || { echo "Missing .claude-plugin/plugin.json"; exit 1; }
jq -e '.name' "$PLUGIN_JSON" > /dev/null || { echo "plugin.json missing name"; exit 1; }
jq -e '.version' "$PLUGIN_JSON" > /dev/null || { echo "plugin.json missing version"; exit 1; }

HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
[ -f "$HOOKS_JSON" ] || { echo "Missing hooks/hooks.json"; exit 1; }
jq -e '.hooks.Stop' "$HOOKS_JSON" > /dev/null || { echo "hooks.json missing Stop hook"; exit 1; }

echo "plugin meta OK"
