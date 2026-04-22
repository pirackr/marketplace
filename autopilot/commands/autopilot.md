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
5. Write the absolute plan path to the active plan marker file:
   ```
   ~/.claude/autopilot/active-plan-$CLAUDE_CODE_SESSION_ID
   ```

## Summary File

6. Derive the structured summary file path from the absolute plan path:
   ```
   ~/.claude/autopilot/plan-summaries/<lowercase-basename-with-non-alnum-runs-replaced-by->-<sha256-of-absolute-plan-path>.md
   ```
   - Basename: the plan file's name without `.md`, lowercased, non-alphanumeric runs collapsed to `-`, trimmed of leading/trailing `-`, clamped to 48 chars.
   - Hash: SHA-256 of the absolute plan path.
7. If the summary file does not exist yet, create it with these canonical sections:
   ```md
   # Autopilot Summary

   ## Current Task
   <first unchecked task from the plan>

   ## Next Step
   Inspect the current task and take the next concrete action.

   ## Blockers
   - none

   ## Recent Progress
   - summary initialized from active plan

   ## Learnings
   - none yet
   ```
8. Keep the summary file current for the full `/autopilot` run. After every completed task and after any meaningful progress, refresh:
   - `## Current Task`
   - `## Next Step`
   - `## Blockers`
   - `## Recent Progress`
9. When delegating to a subagent, pass the summary path in context and require the subagent to return a short structured report that updates those sections.

## Orchestration

10. Read the full contents of the plan file.
11. Spawn an Opus orchestrator agent using the Agent tool:
    - `model`: `"opus"`
    - Include the full orchestrator skill prompt from `skills/autopilot-orchestrator/SKILL.md`
    - Pass the plan file path, the summary file path, and the full plan contents as context

The orchestrator handles routing and execution. Your only job is setup and launch.

## Cleanup

12. When every checkbox in the plan is `- [x]`, remove both session marker files:
    ```
    ~/.claude/autopilot/active-plan-$CLAUDE_CODE_SESSION_ID
    ~/.claude/autopilot/active-plan-signature-$CLAUDE_CODE_SESSION_ID
    ```
    The summary file under `plan-summaries/` is keyed by plan path (not session) and is left in place as a durable notepad for that plan.

## State Directory Reference

The plugin stores session-scoped plan markers and plan-backed summaries under:

```
~/.claude/autopilot/
├── active-plan-<session-id>             # absolute path to the active plan
├── active-plan-signature-<session-id>   # SHA-256 of the plan contents at last continuation (drift detection)
└── plan-summaries/
    └── <sanitized-plan-name>-<sha256-of-plan-path>.md   # structured notepad
```

Set `AUTOPILOT_STATE_DIR` to override the base directory.
