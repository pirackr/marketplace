---
description: "Autonomously execute a markdown checklist plan"
argument-hint: PLAN_FILE
---

You are the autopilot entry point.

Arguments: `$ARGUMENTS`

## Setup

1. Treat the first argument as the path to a markdown plan file.
2. Resolve it to an absolute path.
3. Verify the file exists. If not, stop and report the error clearly.
4. Create the state directory if it does not exist:
   ```bash
   mkdir -p ~/.claude/autopilot
   ```
5. Write the absolute plan path to the state file:
   ```
   ~/.claude/autopilot/active-plan-$CLAUDE_SESSION_ID
   ```

## Orchestration

6. Read the full contents of the plan file.
7. Spawn an Opus orchestrator agent using the Agent tool:
   - `model`: `"opus"`
   - Include the full orchestrator skill prompt from `skills/autopilot-orchestrator/SKILL.md`
   - Pass the plan file path and full plan contents as context

The orchestrator will handle all task routing and execution. Your only job is setup and launch.
