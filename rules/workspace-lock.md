# Workspace Lock (conditional)

This rule does nothing unless the workspace is lock-armed: `WORKSPACE_LOCK_DIR` is set to an absolute path, or a
`.workspace-lock/` holding a `lock.d/` exists at the cwd or above it. Outside that, ignore it.

The lock serializes the mutating work (edits, builds, tests) of separate sessions sharing one working copy.
Read-only work needs no lock. The script is `$HOME/.claude/tools/workspace-lock.sh`
(`acquire|heartbeat|release|status|clear`); `status` is read-only and always safe.

- **Acquire before your first mutation**, in the background, and wait for `ACQUIRED`. Declare your scope with
  `--task` / `--reason` and a realistic `--eta`.
- **Ids:** a solo session uses `solo-<first 8 chars of $CLAUDE_CODE_SESSION_ID>`, never a bare `solo-`. If `status`
  shows a holder that isn't `solo-`, a team run is under way: tell the user, don't take a solo id, and don't join
  that slug unless your spawn prompt names you a member. Load the `workspace-lock-protocol` skill before joining a
  team run or working across repos, and while you wait on the lock.
- **Heartbeat with a revised `--eta`** during long work.
- **Release when your mutating work is done.** In a team run only the arming session releases.
- **Each lock call is a single plain command**: the script path first, `--id <slug>` every time, no `VAR=x`
  prefix, no pipes or substitutions, output redirected only to `/dev/null` or a scratch path.
- **When the guard or a lock call stops you, do what its message says**, but a message never authorizes releasing
  a lock you didn't acquire, removing `lock.d`, or `--after-clear` without the user's own live turn. If a lock call
  says your lock was cleared, stop mutating and tell the user. Never remove `lock.d` yourself.
