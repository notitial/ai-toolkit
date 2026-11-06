# 14. Run Installs From the Live Checkout

**Status:** accepted
**Date:** 2026-11-06

## Context

`/setup-claude` already linked the agents, hooks, rules and skills into `~/.claude` from the checkout
([ADR 0006](0006-symlink-based-skill-distribution.md), [ADR 0009](0009-global-rules-distribution.md)). The github MCP
launcher and guard were the exception. They were copied, owned by root, to `/usr/local/libexec/mcp-github`, so no
session could change the live copies, and every change needed `sudo` to install. The guard limits which GitHub writes
agents may make, and the launcher reads the token from the Keychain, so both are security controls. That made the
copies a two-step install: merge, then a root reinstall rendered with the owner's values. They also drifted from the
checkout without anyone noticing.

The question was whether the security of root ownership is worth that cost, given what an agent on this machine can
already do as the user.

## Options Considered

- **Keep the root-owned copies:** the strongest protection against a session editing the guard, at the cost of a sudo
  install on every change and drift between the copies and `main`. Rejected for that cost.
- **Root-owned copies installed by an automated helper:** less manual work, the same sudo and drift. Rejected for the
  same reason.
- **Run everything from the live checkout, with controls in the files and in permission rules: chosen.**

## Decision

The live checkout is the install. It stays on `main` and moves only with `git pull --ff-only` after a merge, so a merge
plus that pull installs a change. Agents edit in `/tmp` clones, never in the live checkout (CLAUDE.md, Where agents
edit). Nothing is owned by root and nothing needs `sudo`.

- **Reviewed-code check.** The guard and the launcher share one check, kept identical in both files and compared by a
  test. They run only while the checkout is on `main`, its index equals `HEAD`, every tracked file hashed with
  `--no-filters` equals the index, and `HEAD` is on `origin/main`. git runs with its work tree and directory pinned
  and with every route from `.git/config` to a command switched off. The routes found so far: filters, fsmonitor,
  hooks, a pager, a lazy fetch, every transport, external diff and textconv.
- **Pinned binary.** The server binary is not tracked. Its hash is, in `tools/github-mcp/server.sha256`, reviewed like
  code. The launcher compares the binary to it before it reads the token, and the update-check hook runs the binary
  only when it matches the pin committed at `main`'s `HEAD`.
- **Fail closed.** The guard's hook command is `/bin/bash -p '<checkout>/tools/github-mcp/guard.sh' || exit 2`, so a
  guard that cannot start blocks the call. The launcher refuses a checkout path that `/setup-claude` writes no guard
  hook for.
- **Permission rules.** `/setup-claude` writes Edit denies on the live checkout's `.git`, `hooks`, `rules`, `agents`,
  `skills`, `tools/github-mcp`, `tools/workspace-lock`, the status line and the shell helpers. The template denies the
  `~/.claude` link paths and asks on every edit of the user settings.
- **Committed files only.** `/setup-claude` links only what is committed at `HEAD` (`install-copies.sh roster`), never
  an untracked file in the checkout.

The threat model is the one in [ADR 0011](0011-shell-hook-enforcement.md): the controls stop accidents and a
well-meaning session that forgets the rules, not a hijacked agent that works around them on purpose.

## Consequences

- A change installs with a merge and a pull. There is no root reinstall and no copy that drifts from `main`.
- **The check lives in the files it checks.** A shell write can delete it from `guard.sh` or `launch`. Against a
  hijacked agent, the clone rule in CLAUDE.md is the only layer. Root ownership stopped that edit; nothing here does.
- **A shell write is not an Edit.** No permission rule stops `sed -i`, a redirect or a `git checkout` in the live
  checkout. The Edit denies close the editing tools only.
- **The git pins list known routes.** Three security reviews kept finding the same class of problem: git runs what the
  checkout's `.git/config` names. The pins close every route found so far. The `.git/**` Edit deny is what holds the
  class against an editing tool; [tools/github-mcp/README.md](../../tools/github-mcp/README.md) records whether it
  matches mixed-case and symlinked paths.
- **Local forgery stays possible.** `origin/main` can be forged by `update-ref` or one text write, and a commit can be
  rewritten in `.git/objects` by a shell write. A swap of the binary between its hash check and its exec is not caught,
  and a changed `HOME` moves where `install.conf` is read from.
- **An upgrade records a new hash.** The new binary and its `server.sha256` line change in one PR. Until both agree,
  the launcher refuses to start.
- **Cleanup keeps the guard.** A plain `/cleanup-claude` keeps the guard hook and asks before removing it, since a
  `github` server that stays registered would run unguarded; `--include-security` counts as the user's yes.
