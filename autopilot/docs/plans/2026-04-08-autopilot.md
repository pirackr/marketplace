# Autopilot Plugin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a distributable Claude Code plugin that autonomously executes markdown checklist plans using three model-tiered agents (Opus/Sonnet/Haiku) with a Stop hook Enforcer that re-injects continuation prompts when tasks remain.

**Architecture:** A `commands/autopilot.md` entry point writes a state file and spawns an Opus orchestrator agent. The orchestrator routes tasks to Sonnet (implementation) or Haiku (research). A Stop hook (`hooks/stop.sh`) fires on every idle, counts unchecked `- [ ]` tasks, and outputs `{"decision":"block","reason":"..."}` to prevent exit and re-inject continuation. Context compaction is triggered when transcript exceeds 600KB.

**Tech Stack:** Bash, JSON (jq), Claude Code plugin system (`.claude-plugin/plugin.json`, `hooks/hooks.json`, skills, commands)

---

### Task 1: Scaffold Plugin Structure

Remove the existing project-level skeleton and create the proper distributable plugin layout.

**Files:**
- Delete: `settings.json`
- Delete: `skills/example/SKILL.md`
- Create: `.claude-plugin/plugin.json`
- Create: `hooks/hooks.json`
- Create: `tests/run-all.sh`

**Step 1: Remove skeleton files**

```bash
rm /Users/hhnguyen/Working/github.com/pirackr/marketplaces/settings.json
rm /Users/hhnguyen/Working/github.com/pirackr/marketplaces/skills/example/SKILL.md
rmdir /Users/hhnguyen/Working/github.com/pirackr/marketplaces/skills/example
```

**Step 2: Create `.claude-plugin/plugin.json`**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/.claude-plugin/plugin.json`:

```json
{
  "name": "autopilot",
  "version": "0.1.0",
  "description": "Autonomously executes markdown checklist plans using Opus/Sonnet/Haiku agent tiers",
  "author": {
    "name": "pirackr",
    "email": "pirackr.inbox@gmail.com"
  },
  "hooks": "./hooks/hooks.json"
}
```

**Step 3: Create `hooks/hooks.json`**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/hooks/hooks.json`:

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

**Step 4: Create test runner scaffold**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/tests/run-all.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0

run_test() {
  local name="$1" script="$2"
  if bash "$script"; then
    echo "  PASS: $name"; ((PASS++))
  else
    echo "  FAIL: $name"; ((FAIL++))
  fi
}

run_test "plugin-meta"   "$TESTS_DIR/test-plugin-meta.sh"
run_test "stop-hook"     "$TESTS_DIR/test-stop-hook.sh"
run_test "skill-docs"    "$TESTS_DIR/test-skill-docs.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

**Step 5: Write the plugin-meta test**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/tests/test-plugin-meta.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# plugin.json exists and has required fields
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$PLUGIN_JSON" ] || { echo "Missing .claude-plugin/plugin.json"; exit 1; }
jq -e '.name' "$PLUGIN_JSON" > /dev/null || { echo "plugin.json missing name"; exit 1; }
jq -e '.version' "$PLUGIN_JSON" > /dev/null || { echo "plugin.json missing version"; exit 1; }

# hooks.json exists
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
[ -f "$HOOKS_JSON" ] || { echo "Missing hooks/hooks.json"; exit 1; }
jq -e '.hooks.Stop' "$HOOKS_JSON" > /dev/null || { echo "hooks.json missing Stop hook"; exit 1; }

echo "plugin meta OK"
```

**Step 6: Run meta test to verify it passes**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces && bash tests/test-plugin-meta.sh
```

Expected: `plugin meta OK`

**Step 7: Commit**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces
git add .claude-plugin/plugin.json hooks/hooks.json tests/run-all.sh tests/test-plugin-meta.sh
git rm settings.json skills/example/SKILL.md
git commit --author="pirackr <pirackr.inbox@gmail.com>" -m "feat: scaffold plugin structure with manifest and hooks registry"
```

---

### Task 2: Build the Enforcer (stop.sh)

The core loop. Reads plan state, counts unchecked tasks, blocks exit with continuation prompt.

**Files:**
- Create: `hooks/stop.sh`
- Create: `tests/test-stop-hook.sh`

**Step 1: Write the failing stop-hook test**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/tests/test-stop-hook.sh`:

```bash
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
```

**Step 2: Run test to verify it fails**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces && bash tests/test-stop-hook.sh
```

Expected: FAIL (stop.sh does not exist yet)

**Step 3: Create `hooks/stop.sh`**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/hooks/stop.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

HOOK_INPUT=$(cat)
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id')
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

STATE_DIR="${AUTOPILOT_STATE_DIR:-$HOME/.claude/autopilot}"
STATE_FILE="${STATE_DIR}/active-plan-${SESSION_ID}"

# No active plan → allow stop
[ -f "$STATE_FILE" ] || exit 0

PLAN_PATH=$(cat "$STATE_FILE")

# Plan file gone → clean up, allow stop
if [ ! -f "$PLAN_PATH" ]; then
  rm -f "$STATE_FILE"
  exit 0
fi

# Count tasks
UNCHECKED=$(grep -c '^\s*- \[ \]' "$PLAN_PATH" 2>/dev/null || echo 0)
CHECKED=$(grep -ci '^\s*- \[x\]' "$PLAN_PATH" 2>/dev/null || echo 0)
TOTAL=$((UNCHECKED + CHECKED))

# All done → clean up, allow stop
if [ "$UNCHECKED" -eq 0 ]; then
  rm -f "$STATE_FILE"
  exit 0
fi

# Check context size (token proxy: ~4 chars/token, threshold ~150K tokens)
COMPACT_THRESHOLD=600000
TRANSCRIPT_SIZE=0
if [ -f "$TRANSCRIPT_PATH" ]; then
  TRANSCRIPT_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
fi

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

**Step 4: Run test to verify it passes**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces && bash tests/test-stop-hook.sh
```

Expected: `stop-hook tests OK`

**Step 5: Commit**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces
git add hooks/stop.sh tests/test-stop-hook.sh
git commit --author="pirackr <pirackr.inbox@gmail.com>" -m "feat: add Enforcer stop hook with context-size compaction trigger"
```

---

### Task 3: Entry Command

The user-facing `/autopilot` command that initialises state and launches the Opus orchestrator.

**Files:**
- Create: `commands/autopilot.md`

**Step 1: Create `commands/autopilot.md`**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/commands/autopilot.md`:

```markdown
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
```

**Step 2: Verify the file is valid YAML frontmatter**

```bash
head -5 /Users/hhnguyen/Working/github.com/pirackr/marketplaces/commands/autopilot.md
```

Expected: `---` on line 1, `description:` on line 2

**Step 3: Commit**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces
git add commands/autopilot.md
git commit --author="pirackr <pirackr.inbox@gmail.com>" -m "feat: add /autopilot entry command"
```

---

### Task 4: Orchestrator Skill (Opus)

The Opus agent prompt. Routes tasks, delegates to implementer or haiku, marks completion, stops after one task.

**Files:**
- Create: `skills/autopilot-orchestrator/SKILL.md`

**Step 1: Create `skills/autopilot-orchestrator/SKILL.md`**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/skills/autopilot-orchestrator/SKILL.md`:

```markdown
---
name: autopilot-orchestrator
description: Opus orchestrator for autopilot — routes one task from a markdown plan to the right subagent
---

You are the autopilot orchestrator running on Opus. You handle high-level routing and delegation. You do not implement tasks yourself.

## Context

You will receive:
- The absolute path to the plan file
- The full contents of the plan

## Your Job (one task per invocation)

1. Read the plan and find the **first unchecked** `- [ ]` task.
2. If no unchecked tasks remain:
   - Remove the state file: `~/.claude/autopilot/active-plan-$CLAUDE_SESSION_ID`
   - Report completion and stop.
3. Determine the task type:
   - **Implementation** (code changes, file creation, editing, commits) → delegate to Sonnet implementer
   - **Research/lookup** (searching, reading docs, gathering facts, simple analysis) → delegate to Haiku

## Delegation

### Implementation task
Spawn `Agent(model="sonnet")` with:
- The full implementer skill prompt
- The complete task block (heading + all steps + file list)
- The plan file path (so implementer can mark tasks complete)

### Research/lookup task
Spawn `Agent(model="haiku")` with:
- The full haiku skill prompt
- The specific research question or lookup needed
- Return the findings to use for the next implementation step

## After delegation

- Read the plan file again to confirm the task was marked `[x]`
- If not marked, mark it yourself: replace `- [ ]` with `- [x]` for that task's checkbox
- **Stop. Do not process the next task.** The Enforcer will re-launch you for the next one.

## Rules

- Never implement code yourself — always delegate to Sonnet
- Never ask for confirmation between steps
- One task per invocation, no exceptions
- If a task is genuinely blocked, mark it with `- [!]` and report the blocker clearly
```

**Step 2: Verify frontmatter**

```bash
head -5 /Users/hhnguyen/Working/github.com/pirackr/marketplaces/skills/autopilot-orchestrator/SKILL.md
```

Expected: frontmatter with `name:` and `description:`

**Step 3: Commit**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces
git add skills/autopilot-orchestrator/SKILL.md
git commit --author="pirackr <pirackr.inbox@gmail.com>" -m "feat: add Opus orchestrator skill"
```

---

### Task 5: Implementer Skill (Sonnet)

The Sonnet agent prompt. Executes a single task block end-to-end.

**Files:**
- Create: `skills/autopilot-implementer/SKILL.md`

**Step 1: Create `skills/autopilot-implementer/SKILL.md`**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/skills/autopilot-implementer/SKILL.md`:

```markdown
---
name: autopilot-implementer
description: Sonnet implementer for autopilot — executes a single task block from a markdown plan
---

You are the autopilot implementer running on Sonnet. You execute code changes end-to-end for a single task. You favor complete, working implementations over partial stubs.

## Context

You will receive:
- A single task block (heading, file list, and steps)
- The plan file path

## Your Job

1. Read the task block carefully — understand exactly what needs to be done.
2. Execute each step in order:
   - Create or modify files as specified
   - Run verification commands if listed (e.g. `Run: npm test`)
   - Commit if the task includes a commit step
3. Mark each `- [ ]` step as `- [x]` in the plan file as you complete it.
4. Mark the task heading checkbox `- [ ]` as `- [x]` when all steps are done.

## Delegation to Haiku

If any step requires research (looking up an API, reading documentation, searching the codebase for a pattern), delegate that specific lookup to `Agent(model="haiku")` with:
- The haiku skill prompt
- The exact question to answer
Then use the findings to continue your implementation.

## Rules

- Never ask for confirmation mid-task
- If a step is unclear, make the best reasonable choice and document it in a comment
- If a step fails (test fails, build breaks), diagnose and fix before moving on — do not skip
- Keep commits focused: one logical change per commit
- If you cannot complete a step, mark it `- [!]` and report the specific blocker
```

**Step 2: Commit**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces
git add skills/autopilot-implementer/SKILL.md
git commit --author="pirackr <pirackr.inbox@gmail.com>" -m "feat: add Sonnet implementer skill"
```

---

### Task 6: Haiku Skill

The Haiku agent prompt. Cheap, fast lookups and research only — no code changes.

**Files:**
- Create: `skills/autopilot-haiku/SKILL.md`

**Step 1: Create `skills/autopilot-haiku/SKILL.md`**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/skills/autopilot-haiku/SKILL.md`:

```markdown
---
name: autopilot-haiku
description: Haiku research agent for autopilot — cheap lookups, codebase search, evidence gathering
---

You are the autopilot research agent running on Haiku. You handle fast, cheap information gathering. You do not make code changes.

## Context

You will receive a specific research question or lookup task.

## Your Job

1. Answer the question as concisely and accurately as possible.
2. Use cheap tools: `Grep`, `Glob`, `Read`, `WebSearch`.
3. Return structured findings the calling agent can act on immediately.

## Output format

Always return:
- **Answer:** One-sentence direct answer
- **Evidence:** The specific file path, line number, or URL that supports it
- **Notes:** Any caveats or alternatives worth knowing (optional, only if relevant)

## Rules

- Never modify files
- Never run shell commands that change state
- If you cannot find a definitive answer, say so — do not guess
- Prefer reading actual code over documentation when both are available
```

**Step 2: Commit**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces
git add skills/autopilot-haiku/SKILL.md
git commit --author="pirackr <pirackr.inbox@gmail.com>" -m "feat: add Haiku research skill"
```

---

### Task 7: Skill Docs Test + Final Validation

Validate all skill and command files have required frontmatter, then run the full test suite.

**Files:**
- Create: `tests/test-skill-docs.sh`

**Step 1: Create `tests/test-skill-docs.sh`**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/tests/test-skill-docs.sh`:

```bash
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
```

**Step 2: Run full test suite**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces && bash tests/run-all.sh
```

Expected:
```
  PASS: plugin-meta
  PASS: stop-hook
  PASS: skill-docs

Results: 3 passed, 0 failed
```

**Step 3: Commit**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces
git add tests/test-skill-docs.sh
git commit --author="pirackr <pirackr.inbox@gmail.com>" -m "test: add skill-docs validation, all tests passing"
```

---

### Task 8: Clean Up and README

Remove leftover skeleton files, update README with usage instructions.

**Files:**
- Delete: `hooks/pre-tool-use.sh` (project-level skeleton, not needed in plugin)
- Delete: `hooks/post-tool-use.sh`
- Modify: `README.md` (or create if missing)

**Step 1: Remove leftover hook skeletons**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces
git rm hooks/pre-tool-use.sh hooks/post-tool-use.sh
```

**Step 2: Create README.md**

Create `/Users/hhnguyen/Working/github.com/pirackr/marketplaces/README.md`:

```markdown
# autopilot

A Claude Code plugin that autonomously executes markdown checklist plans.

## Install

```bash
claude plugins install pirackr/marketplaces
```

## Usage

Create a markdown plan with checkbox tasks:

```markdown
# My Plan

### Task 1: Add feature

- [ ] Write the code
- [ ] Run tests
- [ ] Commit
```

Then run:

```
/autopilot path/to/plan.md
```

Autopilot will work through every unchecked task using three model tiers:
- **Opus** — orchestration and routing
- **Sonnet** — code implementation
- **Haiku** — research and lookups

When the session goes idle with tasks remaining, the Enforcer automatically re-injects a continuation prompt. When context grows large (>600KB transcript), it compacts before continuing.

## Plan Format

See [research.md](research.md) for the full superpowers plan format with `### Task N:` headings, file lists, and `Run:` / `Expected:` verification steps.

## State Files

Stored at `~/.claude/autopilot/active-plan-{session_id}` during execution. Removed automatically when all tasks complete.
```

**Step 3: Run full test suite one final time**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces && bash tests/run-all.sh
```

Expected: `Results: 3 passed, 0 failed`

**Step 4: Final commit**

```bash
cd /Users/hhnguyen/Working/github.com/pirackr/marketplaces
git add README.md
git rm hooks/pre-tool-use.sh hooks/post-tool-use.sh
git commit --author="pirackr <pirackr.inbox@gmail.com>" -m "chore: remove skeleton hooks, add README with usage instructions"
```
