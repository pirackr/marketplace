# pirackr — Claude Code Marketplace

A Claude Code plugin marketplace by pirackr.

## Available Plugins

- **autopilot** — Autonomously executes markdown checklist plans using Opus/Sonnet/Haiku agent tiers

## Install

Add this marketplace to Claude Code, then install a plugin:

```bash
/plugin marketplace add github:pirackr/claude-autopilot
/plugin install autopilot@pirackr
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
