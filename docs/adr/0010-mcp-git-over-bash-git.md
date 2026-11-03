# 10. MCP Git Over Bash Git for Agent Permissions

**Status:** accepted
**Date:** 2026-03-27

## Context

AI agents need git access for status, diff, log, and staging operations. The initial approach used Bash wildcard permissions (`Bash(git status*)`, `Bash(git diff*)`, etc.) in `settings.json`. This worked but had a safety gap: `Bash(git branch*)` matched both `git branch --list` (read-only) and `git branch -D` (destructive deletion). Wildcard patterns cannot distinguish safe from unsafe flag combinations.

Additionally, Bash git permissions allow command chaining (`&&`, `||`, `;`) within a single shell invocation, and return unstructured text that agents must parse.

## Options Considered

1. **MCP git server (`@cyanheads/git-mcp-server`)** — structured tools with typed parameters, one tool per operation, no shell involved
2. **Tighter Bash wildcards** — more specific patterns like `Bash(git branch --list*)` to exclude destructive flags
3. **Custom wrapper scripts** — shell scripts that validate arguments before passing to git

## Decision

Use the MCP git server. Each git operation is a separate tool (`mcp__git-mcp__git_status`, `mcp__git-mcp__git_diff`, etc.) with validated parameters. The setup template auto-approves `git_status`, `git_diff`, `git_log`, `git_show`, `git_blame` and `git_add`; every other tool (`git_commit`, `git_push`, `git_branch`, `git_remote`, `git_tag`, `git_reset` and the rest) prompts for confirmation.

MCP tools are better for three reasons: granular per-tool permissions (no wildcard ambiguity), structured JSON output (no parsing errors), and no command chaining risk (no shell involved). Tighter wildcards would be fragile — every new flag combination needs a new pattern. Wrapper scripts add maintenance burden and still run through the shell.

## Consequences

- Bash git permissions are fully replaced — `setup-claude` migrates old patterns automatically
- The git-mcp server must be installed at user scope (`claude mcp add --scope user`)
- Agents pass an explicit `path` on every call: the server doesn't inherit the working directory, and its one global working directory (`git_set_working_dir`) is shared by every agent, so it is never used; `hooks/git-mcp-guard.sh` denies a push without a `path`
- Non-git Bash permissions (`ls`, `wc`, `pwd`, `which`, `mkdir`) remain — no MCP equivalent exists; `Bash(cat *)` is removed, since the Read tool covers it
- Two hooks enforce the decision: `hooks/git-mcp-redirect.sh` sends a Bash git command to the matching MCP tool, and `hooks/git-mcp-guard.sh` blocks force and delete pushes, pushes to protected branches, hard and merge resets, `git_clean` other than a dry run, and worktree operations
