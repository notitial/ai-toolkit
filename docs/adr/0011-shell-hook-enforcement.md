# 11. Shell-Hook Enforcement for Agent Guardrails

**Status:** accepted
**Date:** 2026-04-02

## Context

Several classes of agent behavior need to be reliably blocked or redirected: writing secrets to files, running destructive Bash commands, using raw `git` instead of the MCP server, and logging tool calls for auditability. The question is where to enforce these constraints — in CLAUDE.md instructions, or at the harness level via hooks.

## Options Considered

1. **PreToolUse/PostToolUse shell hooks** — scripts receive tool call JSON on stdin, return a structured deny decision; harness enforces before the tool runs
2. **CLAUDE.md instructions only** — model is told to avoid these behaviors via natural language rules
3. **Agent-level system prompt rules** — embed guardrails in each agent's definition

## Decision

Use shell hooks for enforcement. Five hooks are defined in `hooks/`:

| Hook | Event | Purpose |
|------|-------|---------|
| `secret-detector.sh` | PreToolUse | Blocks Bash, Write, Edit, MultiEdit, NotebookEdit and git MCP commit calls that carry a secret pattern, read or write a `.env` file, search recursively where `.env` files may be, or (Bash) print a Keychain secret with `security find-*-password -w/-g` or `dump-keychain -d` |
| `destructive-blocker.sh` | PreToolUse | Blocks destructive Bash commands (rm -rf, force push, DROP TABLE, etc.). A forced delete or truncation of one absolute path, or a bulk delete, asks instead in an interactive session (since 2026-10-20) |
| `git-mcp-redirect.sh` | PreToolUse | Denies `git *` Bash commands, redirects to `mcp__git-mcp__*` equivalents |
| `secret-redact-output.sh` | PostToolUse | Replaces token-shaped values in Bash and MCP tool output with `[REDACTED:<kind>]` before the model sees it; never blocks (added 2026-10-27) |
| `audit-logger.sh` | PostToolUse | Logs Bash and MCP tool calls to `.archive/audit/` |

Hooks always `exit 0` — enforcement is via structured JSON output (`permissionDecision: "deny"`), not exit codes; the output redactor never blocks and returns `updatedToolOutput` instead. All hooks depend on `jq` for JSON parsing.

CLAUDE.md instructions are unreliable for hard constraints — they guide the model but can be overridden or missed. Hooks execute at the harness level and cannot be talked around. Agent definitions are scoped per-agent; cross-cutting concerns like secret detection belong in the shared harness.

## Consequences

- Guardrails are enforced regardless of which agent or session is running
- `jq` is a required runtime dependency on all machines using these hooks
- Audit logs are written to `.archive/audit/` in the project directory — requires `.archive/` to be gitignored
- New hook coverage requires a new shell script + `settings.json` registration, not a CLAUDE.md edit
- Hooks apply globally — no per-project opt-out without removing from `settings.json`
