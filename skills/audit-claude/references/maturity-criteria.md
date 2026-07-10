# Maturity Classification Criteria

Classify the project's AI-assisted development maturity based on which artifacts are present and how they are configured.

## Level 0 — No Setup

**Criteria:** None of the following exist:
- No CLAUDE.md (or equivalent project instructions file)
- No rules directory
- No settings.json with AI tool permissions

**Recommendation:** Start with doc 11 (Repo Initialization). The bootstrapping path is:
1. Create CLAUDE.md with the six-section anatomy (doc 01)
2. Add a git safety rule (doc 02)
3. Create settings.json with minimal permissions (doc 10)

## Level A — Rules Only

**Criteria (all required):**
- CLAUDE.md exists with at least: project overview, build/test commands (or "none"), and key paths
- At least one rule file exists (git safety, code quality, or domain-specific)
- settings.json exists with explicit permission allowlist

**Typical indicators:**
- 1-3 rule files
- CLAUDE.md under 100 lines
- No skills, no agents, no orchestration artifacts
- Manual workflow — human invokes AI for individual tasks

**What to check at this level:** Categories 1, 2, 5, 6, 7, plus Categories 3 (agents) and 4 (skills) whenever their files exist. Categories 8 and 9 are N/A, and 3 and 4 when there are no agents or skills.

## Level B — Rules + Skills

**Criteria (all required):**
- Everything in Level A
- At least 2 skills or commands defined
- Optionally: agent definitions present

**Typical indicators:**
- 3-6 rule files, possibly organized in folders
- 2-5 skills covering common workflows (scaffold, verify, review)
- Agent definitions if multi-agent work is happening
- Semi-automated workflow — human triggers skills, AI executes multi-step procedures

**What to check at this level:** Categories 1, 2, 4-7, plus Category 3 whenever agent files exist (N/A otherwise). Categories 8 and 10 are N/A. Category 9 only if multi-platform.

## Level C — Mature Orchestrated

**Criteria (all required):**
- Everything in Level B
- Orchestration artifacts: checkpoint protocol, launch prompt or orchestrator agent
- Convergence patterns with iteration caps
- Structured report formats for inter-agent communication
- Multiple agent roles with role-appropriate tool scoping
- For repos exceeding 500 files: structural context tooling (code graph MCP server, repo map generator, or equivalent) configured and referenced in CLAUDE.md

**Typical indicators:**
- Orchestrator agent or launch prompt that can run unattended
- Checkpoint file pattern (JSON, markdown, or DB)
- Structured reports with delimiters (`---REPORT---`)
- Wave-based execution grouping tasks by dependency
- Commit verification after agent completion
- Review layers (self-review, design review, or full review)
- Code graph MCP server or repo map for large codebases

**What to check at this level:** All 10 categories. Category 9 only if multi-platform. Category 10 only if repo exceeds 500 files.

## Classification Procedure

1. If none of CLAUDE.md (or equivalent), a rules directory or settings.json with AI tool permissions exists → Level 0.
2. If any Level A criterion is unmet → Level A, incomplete: evaluate it at Level A and list the missing Level A
   artifacts as the first recommendations.
3. If Level A is met, check for skills/commands. If fewer than 2 → Level A.
4. If Level B is met, check every Level C criterion above: orchestration artifacts (checkpoint, convergence,
   structured reports), multiple agent roles with role-appropriate tool scoping and, in a repo over 500 files,
   structural context tooling. If any is missing → Level B, and list the missing ones as the gap to Level C.
5. If all are present → Level C.

When a project is between levels (e.g., has CLAUDE.md and skills but no rules), classify it at the lower level (here
Level A, incomplete) and note what's needed to reach the next.
