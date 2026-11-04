# Global CLAUDE.md Checklist

A good global CLAUDE.md defines **personal preferences** that apply across all projects. It should not contain project-specific details — those belong in each project's own CLAUDE.md.

The global CLAUDE.md works together with the global rules installed by this skill's rules step (`~/.claude/rules/`, symlinked from this repo's `rules/`). Keep each concern in exactly one place: CLAUDE.md carries one-line pointers; the rule files carry the detailed protocols (workflow.md, communication.md, engineering-defaults.md, security.md), and workflow.md holds the canonical risk-topic list.

## Required Sections

### Interaction Style
How you want the agent to approach ambiguity, questions, and task planning.

Example directives:
- Topics that always require confirmation before acting: point at the risk-topic list in workflow.md (its one canonical home, and always loaded too) instead of restating it
- How to handle simple vs complex requests differently
- Pointers to the clarifying-question protocol in workflow.md (do not duplicate the protocol)

### Code Changes
Your guardrails for how the agent modifies code.

Example directives:
- Understand existing patterns before introducing new ones
- Flag breaking changes, performance risks, security implications
- When to ask for confirmation vs proceed autonomously
- Place temporary artifacts in a gitignored `.archive/` folder, creating it if needed
- If `docs/adr/` exists, check it before proposing architectural changes; when a significant decision is made, propose creating an ADR
- Use git MCP tools (`mcp__git-mcp__*`) for all git operations instead of Bash git commands. Always pass the `path` parameter on every git call; never rely on `git_set_working_dir` — the server has one global cwd and concurrent agents race on it
- Commit titles under ~50 characters; put specifics in the body
- Commit and PR attribution is disabled by the `attribution` setting (this skill enforces it); never add Claude trailers or footers manually unless explicitly asked

### Communication
Your preferred tone, format, and verbosity. Prefer a one-line pointer to communication.md over restating it.

## Optional Sections

These earn their always-on slot for users doing multi-agent or multi-session work:

- **Subagents & Delegation** — model/agent selection policy (cheapest model that fits), when to resume an existing agent vs spawn fresh, and the delegation-judgment boundary: delegate heavy, self-contained legwork (code tracing, audits, large-file reads) to subagents that return **evidence — the quoted lines — not just a verdict**, and keep the judgment (routing, authorization, anything on the risk list) in the orchestrator. See `docs/13-orchestrator-context-discipline.md`.
- **Multi-session / orchestrator work** — kickoff/handover/review-gate skill pointers, session-splitting policy.

## Sizing

Target: **≤35 lines including the optional orchestration sections**; a minimal file without them should stay in the generic 10–30 range (see docs/01). The overage is earned by the two orchestration sections — everything else must stay pointer-thin because this file is loaded into every conversation.

## Starter Template

If no global CLAUDE.md exists, offer this as a starting point for the user to customize:

```markdown
# User Preferences

## Interaction Style

- Always stop and ask when the request touches a risk topic: the canonical list is in workflow.md (Unattended runs, Risk topic exception)
- For simple informational questions, answer directly without preamble
- Clarifying-question protocol (when and how many to ask): see workflow.md, Clarifying Questions

## Code Changes

- Understand existing patterns before introducing new ones
- Proactively flag breaking changes, performance risks, and security implications
- Never edit code without user approval — see workflow.md Analysis-First for the gate sequence
- Place temporary artifacts (handover docs, draft specs, research, logs, chat trackers — session tracking across conversations) in a gitignored `.archive/` folder, creating it if needed
- If `docs/adr/` exists, check it before proposing architectural changes; when a significant decision is made, propose creating an ADR
- Use git MCP tools (`mcp__git-mcp__*`) for all git operations instead of Bash git commands. Always pass the `path` parameter on every git call; never rely on `git_set_working_dir` — the server has one global cwd and concurrent agents race on it
- After a major code change, invoke the `code-reviewer` subagent before declaring the task complete. Major = ≥3 files touched, ≥100 lines changed, or any change to auth/permissions/payments/data migrations/concurrency/public APIs/error handling. Minor fixes (typos, formatting, single-line bug fixes, doc-only or test-only changes) are exempt.
- Commit titles under ~50 characters; put specifics in the body
- Commit and PR attribution is disabled by the `attribution` setting; never add Claude trailers or footers manually unless explicitly asked

## Communication

- Tone, structure, and the change-summary format: see communication.md
```

The user should review and customize this — it is a starting point, not a prescription. The Subagents & Delegation and Multi-session sections from the Optional Sections list above are worth adding once the user works with subagents regularly.
