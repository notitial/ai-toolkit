# Security policy

ai-toolkit installs hooks, guards and permission defaults into Claude Code. Several of them are security controls,
so a flaw in one can matter to everyone who uses them.

## Supported versions

Only `main`. The repo has no releases; fixes land on `main`.

## Reporting a vulnerability

Please report privately through GitHub: open the repository's **Security** tab and choose **Report a
vulnerability**. Don't open a public issue or pull request for a security problem.

A useful report says which file is affected, what you expected the control to do, what it did instead, and the
smallest steps that reproduce it.

## Scope

The hooks in `hooks/`, the GitHub MCP guard in `tools/github-mcp/`, the workspace lock and the permission template
that `/setup-claude` installs are security controls. In scope:

- a guard hook that can be bypassed, or that fails open where it should deny
- a secret that gets past the secret scan or the output redaction
- an install, setup or cleanup script that can be made to write, delete or run more than it says it does
- a default permission template that grants more than it documents

Out of scope:

- bugs in Claude Code itself, or a model ignoring an instruction when no hook was bypassed
- third-party MCP servers and other tools the toolkit only configures
- residual risks the docs and ADRs already record as accepted

## What to expect

This is a personal project, maintained on a best-effort basis with no SLA. Reports are acknowledged within 14 days.
Fixes land on `main`, and the advisory is published once the fix is in.
