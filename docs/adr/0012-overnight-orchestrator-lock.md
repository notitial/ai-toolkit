# 12. Workspace Lock

**Status:** accepted
**Date:** 2026-07-03 · **Amended:** 2026-10-26 (expiry, retake and the prompted `clear`)

## Context

Separate Claude Code sessions that share one working copy on one machine (an unattended overnight run, an interactive
daytime session, a second terminal) must take turns on anything that changes it: edits, builds, tests and end-to-end
runs. Otherwise they collide on the checkout and on the one build environment. Read-only work (search, read, plan,
review) doesn't conflict and needs no coordination. The mechanism has to work with no human present to break ties, and
it must not weaken the risk-topic rule: auth, permissions, payments, PII, encryption, security controls, data
migrations, schema changes, production changes and destructive actions always need the user's own live turn, so an
unattended run never includes them.

## Options Considered

- **A git worktree per session:** rejected for the unattended case. Separate trees let a lock hiccup split work silently
  while the simulator and backend point at one of them; a shared copy keeps failures visible.
- **Lock verbs as an MCP server:** considered, not chosen. MCP can't veto other tools' calls, so enforcement would still
  need a PreToolUse hook, and a server adds failure modes (losing the background acquire's wake-up, a headless gap, hook
  and server resolving workspaces differently). Revisit when there is a real need.
- **Automatic takeover of a stale lock:** rejected. A session that looks dead may be alive (a long build, a sleeping
  laptop), and breaking its lock lets two sessions mutate at once, the failure the lock exists to prevent.
- **An advisory `mkdir` lock with a guard hook as the backstop: chosen.**

## Decision

The threat model is cooperative: the lock stops well-meaning sessions from forgetting the protocol, not a session that
works around it on purpose, the same stance as the hooks in [ADR 0011](0011-shell-hook-enforcement.md).

- **The lock.** `<workspace>/.workspace-lock/lock.d/`, created atomically by `mkdir`, is the mutex. The holder id lives
  inside it (`lock.d/holder`), and `release` and `heartbeat` check that token; `status.json` is a display mirror that
  can never cause a double acquire. `tools/workspace-lock/workspace-lock.sh` does no git: a run branches off `main`,
  commits locally and never pushes or merges, with git through the MCP tools
  ([ADR 0010](0010-mcp-git-over-bash-git.md)). `/setup-claude` links the script to `~/.claude/tools/workspace-lock.sh`.
- **The guard.** `hooks/workspace-lock-guard.sh` (PreToolUse on edits, Bash and git MCP) denies a mutation in a guarded
  workspace unless this session holds the lock. A session registers by running `acquire --id <slug>` and holds the lock
  when that slug equals `lock.d/holder`. A non-holder may still read (a short list of read-only commands), write under
  `.archive/` or a temp dir, and run the lock script. Builds and tests are not on that list: serializing them is the
  point. A deny names the holder and ETA and says how to proceed. An empty holder denies everyone until a human inspects
  it and removes `lock.d` by hand; `clear` refuses an empty holder.
- **The rule.** `rules/workspace-lock.md` is installed globally but does nothing unless the workspace is armed
  (`WORKSPACE_LOCK_DIR` set, or a held lock at or above the cwd). Where it applies, agents acquire before their first
  mutation, heartbeat with a revised ETA during long work, and release when done. A team run shares one slug that only
  the arming session releases; a solo session uses `solo-<first 8 characters of its session id>`.
- **Arming.** `/unattended-run` is user-triggered only (`disable-model-invocation: true`), so an agent never arms
  itself. It arms the non-risk tasks and holds every risk-topic task for the user's live turn.
- **Expiry and retake (amended 2026-10-26).** No lock stays held for good. Once its ETA passes, the guard denies the
  holder's own mutations and the script refuses a bare `heartbeat`, until the holder retakes the lock with
  `heartbeat --id <slug> --eta <new>`.
- **Prompted clear (amended 2026-10-26).** Once `WORKSPACE_LOCK_WEDGE_GRACE` (default 30 minutes) has passed since both
  the ETA and the last heartbeat, another session may run `workspace-lock.sh clear --id <me> --holder <h>`. The guard
  runs the script's read-only `clear --check` and turns a clearable lock into a permission prompt showing the holder,
  ETA and last heartbeat. It denies `clear` in headless sessions, in permission modes that may not show a prompt, and in
  a compound, redirected or `cd`-prefixed command; `permissions.ask` entries for the plain spellings back it up if the
  hook fails open. A wrapped spelling (an env prefix, `bash -c`, a subshell) is not gated, a known gap this cooperative
  threat model accepts. The cleared id's next lock call fails loudly, naming who cleared it, and it gets back in only with
  `acquire --after-clear`, once the user agrees.

## Consequences

- Mutating work is serial: total wall-clock is the sum of the runs, and the machine never runs two heavy builds at once.
- Every session in a guarded workspace acquires before mutating, daytime sessions included. The guard is the backstop
  for forgetting.
- The rule is inert outside an armed workspace, so installing it globally is safe.
- A crashed session's lock stays held until its ETA and heartbeat go stale and someone clears it at the prompt. Nothing
  clears a lock automatically.
- When jq is missing or the hook's input is unreadable, a session without `WORKSPACE_LOCK_ID` set gets a warning and a
  pass (fails open), and one with it set is denied (fails closed).
- Accepted residuals: a Bash command's guardedness follows its cwd; session registrations don't expire; a cleared holder
  is stopped at its next lock call, not its next edit; hard links and symlink swaps are outside the cooperative threat
  model.
- Clearing a lock is a recovery the user approves, not a pattern for risk-topic actions, where a relayed approval
  carries no weight.
- The protocol is [rules/workspace-lock.md](../../rules/workspace-lock.md); the script reference is
  [tools/workspace-lock/README.md](../../tools/workspace-lock/README.md).
