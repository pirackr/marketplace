# Autopilot Plugin — Research & Porting Plan

## Source: OpenCode autopilot plugin
`/Users/hhnguyen/Working/github.com/pirackr/autopilot`

---

## What It Does

Autonomously executes a markdown checklist ("superpowers plan") from start to finish. The core innovation is the **Enforcer** — a loop that triggers whenever the session goes idle, checks if unchecked `- [ ]` tasks remain in the plan file, and injects a continuation prompt to keep Claude working.

**Flow:**
1. User runs `/autopilot path/to/plan.md`
2. Orchestrator reads the plan, registers state to `~/.config/opencode/autopilot/active-plan-{sessionID}`
3. Orchestrator delegates each task to the appropriate subagent (`/autopilot-implementer`, `/autopilot-research`, `/autopilot-planner`)
4. Session goes idle → Enforcer fires, counts unchecked items, injects continuation prompt
5. Loop continues until all `- [ ]` checkboxes are checked → state file removed

---

## Superpowers Plan Format

Standard markdown with checkbox syntax. Example structure:

```markdown
# [Feature Name] Implementation Plan

**Goal:** One-sentence goal
**Architecture:** One-sentence summary
**Tech Stack:** comma-separated list

---

### Task 1: [Task title]

**Files:**
- Create: `/absolute/path/to/file.ts`
- Modify: `/absolute/path/to/other.ts`

- [ ] **Step 1: Description**
- [ ] **Step 2: Description**
- [ ] **Step 3: Commit**
```

- Numbered `### Task N:` headings for major work items
- `- [ ]` / `- [x]` checkboxes for progress tracking
- Inline code blocks with exact file contents or patches
- Verification steps with `Run:` and `Expected:` patterns
- Commit step at end of each task

---

## Key Files in OpenCode Plugin

| File | Role |
|---|---|
| `.opencode/plugins/autopilot.ts` | Plugin entry — registers commands, wires session events |
| `.opencode/plugins/autopilot/enforcer.ts` | **Core loop.** Detects idle, checks incomplete work, injects continuation |
| `.opencode/plugins/autopilot/sources/file-plan.ts` | Counts `- [ ]` vs `- [x]` in plan file |
| `.opencode/plugins/autopilot/sources/session-todo.ts` | Queries OpenCode session todo API |
| `.opencode/plugins/autopilot/model-fallback.ts` | Retries with next model on 429/retryable errors |
| `.opencode/commands/autopilot.md` | Main entry command template |
| `.opencode/commands/autopilot-implementer.md` | Implementer subagent command |
| `.opencode/commands/autopilot-research.md` | Research subagent command |
| `.opencode/commands/autopilot-planner.md` | Planner subagent command |

---

## Enforcer Logic (the core loop)

```
session.idle event fires
  → skip if abort detected within last 3 seconds
  → trigger context compaction if tokens > 200K
  → check two sources for incomplete work:
      1. file-plan: count - [ ] in plan file
      2. session-todo: query session API
  → if incomplete work exists:
      inject: "Incomplete tasks remain. Continue working on the next pending task.
               Proceed without asking for permission. Do not stop until all tasks are done.
               [Status: X/Y completed, Z remaining]"
  → if all done: remove state file, stop
```

---

## Porting to Claude Code

### API Mapping

| OpenCode | Claude Code Equivalent |
|---|---|
| `session.idle` event | `Stop` hook |
| `session.prompt()` inject continuation | Hook stdout + exit code `2` |
| Slash commands | Skills |
| Plugin TypeScript API | Shell scripts |
| `session.summarize()` | Built-in auto-compact (no action needed) |
| Session todo API | Not needed — rely solely on file checkboxes |

### Key Insight: Stop Hook with Exit Code 2

In Claude Code, a `Stop` hook that exits with code `2` and prints a message to stdout will inject that message and prevent Claude from stopping — this is the exact equivalent of OpenCode's `session.prompt()` in the Enforcer.

### Proposed Structure

```
skills/
├── autopilot/SKILL.md              # Entry: reads plan, registers state, starts loop
├── autopilot-implementer/SKILL.md  # Executes code changes
├── autopilot-research/SKILL.md     # Gathers context/info
└── autopilot-planner/SKILL.md      # Resolves ambiguity

hooks/
└── stop.sh                         # The Enforcer — checks plan, re-prompts if tasks remain

~/.claude/autopilot/
└── active-plan-{sessionID}         # State file (stores plan path)
```

### Simpler Than OpenCode
- No TypeScript plugin system — just shell scripts + markdown skills
- No model fallback needed (Claude Code uses one model)
- Auto-compact is built-in

### Harder Than OpenCode
- No native session todo API — rely only on markdown checkbox count
- Stop hook exit code `2` behavior needs verification before building

---

## Next Steps

1. Verify `Stop` hook exit code `2` injects prompt and continues session
2. Build `hooks/stop.sh` (the Enforcer)
3. Build `skills/autopilot/SKILL.md` (entry + orchestrator)
4. Build `skills/autopilot-implementer/SKILL.md`
5. Build `skills/autopilot-research/SKILL.md`
6. Build `skills/autopilot-planner/SKILL.md`
7. Test with a small superpowers plan
