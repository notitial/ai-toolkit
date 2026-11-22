# 12. Workspace Lock

**Status:** accepted
**Date:** 2026-07-03 · **Amended:** 2026-10-26 (expiry, retake and the prompted `clear`), 2026-11-13 (arm step moved out), 2026-11-14 (owned team), 2026-11-19 (session lock: owned team and shared slugs removed), 2026-11-22 (fewer false denies for reads and scratch heredocs)

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
- **Owned teams, shared slugs and a precise Bash parser (2026-11-14 design):** rejected on 2026-11-19, see the
  amendment below. The owned team, the open team and cross-repo resolution were never used. The holder was a name the
  agent typed instead of the session id the hook already receives, and the guard tried to read Bash as the shell does,
  so each new spelling became another rule.
- **An advisory lock directory with a guard hook as the backstop: chosen.**

## Decision

The threat model is cooperative: the lock stops well-meaning sessions from forgetting the protocol, not a session that
works around it on purpose, the same stance as the hooks in [ADR 0011](0011-shell-hook-enforcement.md).

- **The lock.** `<root>/.workspace-lock/lock.d/` is the mutex, won by an exclusive create (`O_EXCL`) of
  `lock.d/claim`, never by `mkdir`'s exit status (some mkdir builds exit 0 after losing the create race). The holder
  lives inside it (`lock.d/holder`), and `release` checks it. `tools/workspace-lock/workspace-lock.sh` does no git: a
  run branches off `main`, commits locally and never pushes or merges, with git through the MCP tools
  ([ADR 0010](0010-mcp-git-over-bash-git.md)). `/setup-claude` links the script to `~/.claude/tools/workspace-lock.sh`.
- **The holder is the session.** The holder id is the session id: the script reads `$CLAUDE_CODE_SESSION_ID` and the
  guard reads the hook's `session_id`, so nothing is typed, pasted or registered, and a subagent shares its parent's
  holder. Probes saw the id survive compaction, resume and reload and change after `/clear`. A `--id` argument is
  accepted and ignored for a transition period.
- **The workspace is the git root, armed by the folder.** The workspace is the nearest ancestor of the target that
  holds `.git`, from any subfolder. It is armed when `<root>/.workspace-lock/` exists; a person creates the folder and
  gitignores it, and the script never creates it. No environment variable arms or redirects it.
- **The guard.** `hooks/workspace-lock-guard.sh` (PreToolUse on edits, Bash and git MCP, and SessionEnd) denies a
  mutation in an armed workspace unless this session holds the lock. Each guarded call by the holder stamps
  `lock.d/seen`. A non-holder may still read: Read-style tools, git MCP read tools by name, writes under the root's
  `.archive/` or outside the root, the lock script as one plain call, scratch writes (`mkdir`, `cp`, `mv`, `touch`,
  `rm` on absolute paths under a temp directory) and a Bash read check that **fails closed**: anything it does not
  recognise counts as a mutation. The check allows no command substitution, process substitution or backtick, only
  `2>&1` and redirects to `/dev/null`, splits on `&& || ; |` and newline with no quote awareness (a quoted `|` makes a
  segment that fails the check, a safe deny), allows leading `cd <path>` segments, and requires every other segment to
  start with a word from a fixed read set without a write flag. Builds and tests are not on that list: serializing them
  is the point. A deny names the holder, ETA and task and says how to proceed. A missing `jq`, malformed input or a
  missing `session_id` in an armed workspace denies (fail closed, as in `gh-block.sh`).
- **Session end.** The guard also handles SessionEnd: if `lock.d/holder` is the ending session, it renames `lock.d`
  away and logs it. A resumed session acquires again. A separate session-end hook is not kept.
- **The rule.** `rules/workspace-lock.md` is installed globally but does nothing unless the workspace is armed. Where
  it applies, agents acquire in the background before their first mutation and wait for `ACQUIRED`, re-run
  `acquire --eta` to extend a long job, and release when done. Arming is user-triggered only, so an agent never arms
  itself. The `STATE.md` Authorizations ledger stays in this repo; any arm step supplied elsewhere must meet the
  risk-topic exception in [rules/workflow.md](../../rules/workflow.md).
- **Expiry and prompted clear (amended 2026-10-26, reworked 2026-11-19).** No lock stays held for good. A lock is
  stale once `now > max(ETA, seen) + grace` (default 30 minutes), so a holder that keeps working never looks stale and
  there is no separate heartbeat verb. Another session may then run `clear`; the guard turns a plain call on a stale
  lock into a permission prompt showing the holder, ETA and last activity, read straight from `lock.d`. It denies
  `clear` on a lock that is not stale, in headless sessions and in permission modes that may not show a prompt;
  `permissions.ask` entries for `clear` and `--after-clear` back it up if the hook fails open. `clear` renames `lock.d`
  away and writes `cleared/<sid>`. The cleared session's next guarded call is denied, loudly, and it gets back in only
  with `acquire --after-clear`, once the user agrees. A wrapped spelling (an env prefix, `bash -c`, a subshell) is not
  gated, a known gap this cooperative threat model accepts.

### Amendment 2026-11-19: what the session lock removes

The 2026-11-14 owned team and the open team's shared slug are removed, with everything that existed only to support
them:

- the owned team: owner, members, turns, `force`, `transfer`, the `ended/` markers and the separate session-end hook;
- the open team: a slug several sessions share. Sessions that share a checkout take the one lock in turn, which is
  what turns added;
- cross-repo workers (`--repos`) and `WORKSPACE_LOCK_DIR`: a worker that mutates another repo takes that repo's lock;
- `WORKSPACE_LOCK_ID` and `WORKSPACE_LOCK_BYPASS`;
- the `sessions/` registration, the second parser for `release`, the literal-session-id rule and the
  `workspace-lock-protocol` skill;
- the `status.json` mirror (`status` reads `lock.d`), the wedge-warning ladder and the guard of the lock folder itself
  (no owned lock remains to protect).

The change lands in stages: remove the owned team, replace the Bash read check, then key the lock on the session id.
Until the last stage merges, the code still uses typed slugs; the text above describes the end state.

## Consequences

- Mutating work is serial: total wall-clock is the sum of the runs, and the machine never runs two heavy builds at once.
- Every session in a guarded workspace acquires before mutating, daytime sessions included. The guard is the backstop
  for forgetting.
- The rule is inert outside an armed workspace, so installing it globally is safe.
- A crashed session's lock stays held until its ETA and last activity go stale and someone clears it at the prompt; a
  session that ends normally frees its own lock. Nothing else clears a lock automatically.
- Clearing a lock is a recovery the user approves, not a pattern for risk-topic actions, where a relayed approval
  carries no weight.
- Residuals the session lock accepts:
  - A waiting session's Bash narrows: `sed -n`, `curl`, `sort`, `uniq`, `sysctl`, `log show`, the git `fetch`, `branch`,
    `remote` and `config` read forms, and `tee` scratch writes become denies (amended 2026-11-22: `pgrep`, `cmp` and
    `od` read, and a quoted-delimiter heredoc to a scratch path passes, as `echo x > file` does; it used to pass into the
    root's `.archive/` only. `sed` without `-n` stays a deny: a substitution read needs the guard to model shell
    quoting it does not). It uses Read, Grep, Glob, the
    Write tool for `.archive/` and the git MCP reads, as the global rules already prefer. A quoted metacharacter
    (`grep "a|b"`) is a false deny, never a false allow.
  - Nothing guards the lock folder: a holder's `git clean -fdx` or `rm -rf .workspace-lock` removes the lock and the
    arming. The ADR accepted this before the owned team.
  - There is no closed membership and no queue: any session in the checkout may take the lock between another's units,
    and waiters poll with jitter, so one that re-acquires at once can starve the rest.
  - A holder blocked inside one Bash call longer than ETA plus grace looks stale; the user still decides at the
    `clear` prompt.
  - SessionEnd frees the lock on any stop, including one that is later resumed; a session that stopped mid-change
    leaves a dirty tree that the next holder sees in `git_status`.
  - A session id that differs between the hook and the Bash environment would mismatch holder and caller. The tests
    probe that they match, for subagents too.
  - A Bash command's guardedness follows its cwd; hard links and symlink swaps are outside the cooperative threat
    model.
- The protocol is [rules/workspace-lock.md](../../rules/workspace-lock.md); the script reference is
  [tools/workspace-lock/README.md](../../tools/workspace-lock/README.md).
