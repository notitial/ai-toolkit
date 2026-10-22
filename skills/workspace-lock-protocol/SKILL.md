---
name: workspace-lock-protocol
description: Workspace-lock team runs, cross-repo workers and waiting — the shared team slug, which lock is yours to take, authority vs resolution for a cross-repo worker, and what to do while the acquire waits. Load before joining a team run or working across repos, and while you wait on the lock. Not needed for read-only work or outside a lock-armed workspace.
---

# Workspace Lock — team runs, scope and waiting

## Which id

An id **is** ownership. A wrong one either deadlocks two sessions or lets both mutate at once.

### Team run (the only shared id)

The arming session mints one slug for the run (e.g. `<ticket>-YYYYMMDD`) and every session in the run uses it.

- **Subagents you spawn** are covered by your registration; they don't acquire.
- **Separate team sessions** each run `acquire --id <team-slug> --eta +<realistic>h`. Acquire is reentrant for the
  same id. Always pass `--eta` on the join: without it the shared lease resets to the 30-minute default and
  waiters see the team as wedged.
- **Workers heartbeat only and never release.** An early release removes `lock.d` and denies the whole team until
  the arming session re-acquires.

### Solo session

1. Run `status` first. If the holder's id is not `solo-`-prefixed, a team run is under way: don't take a solo id
   and don't join the team slug on your own. Tell the user, and join only if your spawn prompt names you a member.
2. Read the session id (`echo $CLAUDE_CODE_SESSION_ID`; a read, allowed before you hold the lock) and acquire as
   `solo-<first 8 chars>`, passing the literal value. Never a bare `solo-` and never a shared or date-based solo
   id: two sessions with one id both pass the guard.
3. Use a short `--eta` and `release` at task end.

## Which lock is yours to take

Acquire only when the lock script and the guard land on the **same** lock; otherwise you create a second lock and
two sessions stop serializing. Both must hold, except as a cross-repo worker (below):

1. The workspace root (the folder holding `.workspace-lock/`) is your cwd or above it.
2. `WORKSPACE_LOCK_DIR` points at that lock, or your cwd is the root itself (the script defaults to
   `$PWD/.workspace-lock`).

A `WORKSPACE_LOCK_DIR` pointing outside your tree that your spawn prompt does not name: ignore it. The guard
ignores it too.

### Cross-repo team worker

- *Authority* (may I act on this lock?) comes from your spawn prompt and the arm-time ledger row, which name the
  lock path. An env var's presence grants nothing.
- *Resolution* (which lock do the tools use?) comes from `WORKSPACE_LOCK_DIR`, which the arm ceremony sets in a
  cross-repo worker's launch environment ([unattended-run](../unattended-run/SKILL.md) Steps 1.9 and 2.4). Act on
  it only when it matches the path your spawn prompt names.
- Acquire with the team slug. The guard counts you as a member only when your cwd is under one of the lock's
  `--repos` paths.

## While you wait

- Do read-only work (search, read, plan, review) instead; it needs no lock.
- Don't poll `status` just to keep your context warm. A cold first turn after `ACQUIRED` is usually cheaper.
- `heartbeat == acquired_at` right after an acquire is normal; the holder hasn't declared its ETA yet.
- If the acquire log prints `WARN`, do what it says.
