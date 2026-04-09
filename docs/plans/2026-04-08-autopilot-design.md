# Autopilot Plugin — Design

**Date:** 2026-04-08
**Status:** Approved

## Goal

Port the OpenCode autopilot plugin to Claude Code as a distributable plugin installable via `claude plugins install`. Autonomously executes a markdown checklist plan from start to finish using three model-tiered agents, with an Enforcer Stop hook that re-injects a continuation prompt whenever the session goes idle with unchecked tasks remaining.

## Architecture

### Distribution
Plugin format: `.claude-plugin/plugin.json` manifest + `hooks/hooks.json` + `commands/` + `skills/`.
Installed via `claude plugins install`. Uses `CLAUDE_PLUGIN_ROOT` for all plugin-relative paths.

### Three-Tier Agent Model
- **Opus** — orchestrator: reads plan, routes tasks, marks completion
- **Sonnet** — implementer: executes code changes for a single task
- **Haiku** — delegatable work: research, lookups, evidence gathering

### Enforcer Loop
A Stop hook fires whenever the session goes idle. It checks for unchecked `- [ ]` tasks in the active plan file and blocks the session exit by injecting a continuation prompt. This is the core mechanism that keeps Claude working autonomously.

---

## File Structure

```
.claude-plugin/
  plugin.json                        # manifest

commands/
  autopilot.md                       # /autopilot PLAN_FILE — entry point

skills/
  autopilot-orchestrator/
    SKILL.md                         # Opus orchestrator instructions
  autopilot-implementer/
    SKILL.md                         # Sonnet implementer instructions
  autopilot-haiku/
    SKILL.md                         # Haiku research/planning instructions

hooks/
  hooks.json                         # registers Stop hook
  stop.sh                            # the Enforcer

State (runtime, not in repo):
  ~/.claude/autopilot/active-plan-{session_id}   # absolute path to plan file
```

The existing `settings.json` / `skills/example/SKILL.md` skeleton is replaced by this structure.

---

## Data Flow

```
User: /autopilot path/to/plan.md
  │
  ▼
commands/autopilot.md  (current session)
  1. Resolve plan path to absolute
  2. Verify file exists
  3. mkdir -p ~/.claude/autopilot/
  4. Write plan path → ~/.claude/autopilot/active-plan-{CLAUDE_SESSION_ID}
  5. Spawn Agent(model="opus", prompt=<orchestrator skill + plan content>)
  │
  ▼
Opus Orchestrator  (fresh Agent context)
  - Reads plan file, finds first unchecked task
  - Routes:
      implementation work  → Agent(model="sonnet", prompt=<implementer skill + task block>)
      research/simple work → Agent(model="haiku",  prompt=<haiku skill + task block>)
  - Marks task [x] when done
  - Stops after ONE task (keeps context bounded; stop hook re-launches for next)
  - When all tasks done: rm ~/.claude/autopilot/active-plan-{session_id}
  │
  ▼  (session goes idle)
hooks/stop.sh  (Stop hook fires)
  - Reads session_id, transcript_path from stdin JSON
  - Looks up ~/.claude/autopilot/active-plan-{session_id}
  - If missing → exit 0 (allow stop)
  - Counts - [ ] in plan file
  - If 0 remaining → rm state file, exit 0
  - Checks transcript file size (token proxy)
  - If size > 600KB → prepend /compact instruction to prompt
  - Outputs {"decision":"block","reason":"...","systemMessage":"X/Y done, N remaining"}
  │
  ▼
Claude continues → next Opus orchestrator invocation → next task
```

---

## Components

### `commands/autopilot.md`

User-facing entry point. No `model:` frontmatter (runs in current session). Responsibilities:
- Accept `PLAN_FILE` argument
- Resolve to absolute path, verify exists
- Create `~/.claude/autopilot/` if needed
- Write absolute plan path to `~/.claude/autopilot/active-plan-{CLAUDE_SESSION_ID}`
- Spawn `Agent(model="opus")` with orchestrator skill + full plan content

### `skills/autopilot-orchestrator/SKILL.md`

Injected as the system prompt for the Opus agent. Instructions:
- Read the plan file (path passed in context)
- Find the first unchecked `- [ ]` task
- Determine task type and route to appropriate subagent
- Mark task `- [x]` when subagent completes
- **Stop after one task** — do not loop internally; the Enforcer handles re-launch
- If all tasks done: remove state file

### `skills/autopilot-implementer/SKILL.md`

Injected as the system prompt for the Sonnet agent. Instructions:
- Receive a single task block as context
- Execute code changes end-to-end
- Run verification steps if specified in task
- Commit if the task includes a commit step
- Can delegate to `Agent(model="haiku")` for research subtasks
- Report completion clearly

### `skills/autopilot-haiku/SKILL.md`

Injected as the system prompt for the Haiku agent. Instructions:
- Receive a delegated subtask (research, lookup, file reading, evidence)
- Favor cheap operations: Grep, Glob, Read, WebSearch
- Return structured findings for the calling agent to act on
- Do not make code changes

### `hooks/stop.sh`

The Enforcer. Full logic:

```bash
# Read hook input
HOOK_INPUT=$(cat)
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id')
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

STATE_FILE=~/.claude/autopilot/active-plan-${SESSION_ID}

# No active plan → allow stop
[ -f "$STATE_FILE" ] || exit 0

PLAN_PATH=$(cat "$STATE_FILE")

# Plan file gone → clean up, allow stop
[ -f "$PLAN_PATH" ] || { rm "$STATE_FILE"; exit 0; }

# Count tasks
UNCHECKED=$(grep -c '^\s*- \[ \]' "$PLAN_PATH" || true)
CHECKED=$(grep -ci '^\s*- \[x\]' "$PLAN_PATH" || true)
TOTAL=$((UNCHECKED + CHECKED))

# All done → clean up, allow stop
[ "$UNCHECKED" -eq 0 ] && { rm "$STATE_FILE"; exit 0; }

# Check context size
TRANSCRIPT_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
COMPACT_THRESHOLD=600000  # ~600KB ≈ proxy for ~150K tokens

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
```

### `hooks/hooks.json`

```json
{
  "description": "Autopilot enforcer — re-injects continuation prompt when tasks remain",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/stop.sh\""
          }
        ]
      }
    ]
  }
}
```

### `.claude-plugin/plugin.json`

```json
{
  "name": "autopilot",
  "version": "0.1.0",
  "description": "Autonomously executes markdown checklist plans using Opus/Sonnet/Haiku agent tiers",
  "author": {
    "name": "pirackr"
  },
  "hooks": "./hooks/hooks.json"
}
```

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| One task per Opus invocation | Bounds context window; Enforcer handles re-launch |
| Agent tool for model routing | `model:` frontmatter only applies to user-invoked commands; Agent tool is reliable |
| Transcript size as token proxy | No token count API in hooks; file size (~4 chars/token) is good enough |
| 600KB compact threshold | ~150K tokens — leaves headroom before 200K limit |
| State file in `~/.claude/autopilot/` | User-global, survives project changes, keyed by session ID |
| Skills as prompt templates | Separates agent behavior from plumbing; easy to tune per agent |

---

## Corrections to research.md

The research.md stated Stop hook uses "exit code 2". **This is wrong.** The actual API is JSON output:
```json
{"decision": "block", "reason": "...", "systemMessage": "..."}
```
Exit 0 always. The `reason` field becomes the injected user prompt.

---

## Out of Scope

- Model fallback on 429/retryable errors (OpenCode had this; Claude Code uses one model tier)
- Session todo API (OpenCode had this; we rely solely on file checkboxes)
- Abort detection window (OpenCode had 3s abort guard; not needed with JSON-based hook API)
