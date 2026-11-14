# 12. Workspace Lock

**Status:** accepted
**Date:** 2026-07-03 · **Amended:** 2026-10-26 (expiry, retake and the prompted `clear`), 2026-11-13 (arm step moved out), 2026-11-14 (owned team)

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
- **An advisory lock directory with a guard hook as the backstop: chosen.**

## Decision

The threat model is cooperative: the lock stops well-meaning sessions from forgetting the protocol, not a session that
works around it on purpose, the same stance as the hooks in [ADR 0011](0011-shell-hook-enforcement.md).

- **The lock.** `<workspace>/.workspace-lock/lock.d/` is the mutex, won by an exclusive create (`O_EXCL`) of
  `lock.d/claim`, never by `mkdir`'s exit status (some mkdir builds exit 0 after losing the create race). The holder
  id lives inside it (`lock.d/holder`), and `release` and `heartbeat` check that token; `status.json` is a display mirror that
  can never cause a double acquire. `tools/workspace-lock/workspace-lock.sh` does no git: a run branches off `main`,
  commits locally and never pushes or merges, with git through the MCP tools
  ([ADR 0010](0010-mcp-git-over-bash-git.md)). `/setup-claude` links the script to `~/.claude/tools/workspace-lock.sh`.
- **The guard.** `hooks/workspace-lock-guard.sh` (PreToolUse on edits, Bash and git MCP) denies a mutation in a guarded
  workspace unless this session holds the lock. A session registers by running `acquire --id <slug>` and holds the lock
  when that slug equals `lock.d/holder`. A non-holder may still read (a short list of read-only commands, among them
  `git fetch`, `git branch` listings, `git rev-parse`, `git ls-files`, `git merge-base`, `git remote -v` and `get-url`,
  `git worktree list` and `git config --get <key>`, each in its read-only form only: a fetch with a refspec that has a
  destination, a branch name outside `--list`, or `config --list` is still a mutation). A fetch does write inside
  `.git` (`FETCH_HEAD`, remote-tracking refs, tags, maybe an automatic gc), also in a repo named with `-C`; that is
  accepted. A non-holder may also write under `.archive/` or a temp dir, append to a file in the workspace's own
  `.archive/` with a single-quoted `cat >> <path> <<'TAG'` heredoc, and run the lock script. Builds and tests are not
  on that list: serializing them is the point. A deny names the holder and ETA and says how to proceed. An empty
  holder denies everyone until a human inspects
  it and removes `lock.d` by hand; `clear` refuses an empty holder.
- **The rule.** `rules/workspace-lock.md` is installed globally but does nothing unless the workspace is armed
  (`WORKSPACE_LOCK_DIR` set, or a held lock at or above the cwd). Where it applies, agents acquire before their first
  mutation, heartbeat with a revised ETA during long work, and release when done. An open team shares one slug that
  only the session that took the lock first releases; a solo session uses `solo-<first 8 characters of its session id>`.
- **Arming.** Arming is user-triggered only, so an agent never arms itself. An arm step arms only the non-risk tasks and
  holds every risk-topic task for the user's live turn. (Amended 2026-11-13: no arm step ships in this repo any
  more. The lock, the guard and the `STATE.md` Authorizations ledger stay here; any arm step supplied elsewhere
  must meet the risk-topic exception in [rules/workflow.md](../../rules/workflow.md).)
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

- **Owned team (amended 2026-11-14).** `acquire --owned --sid <sid>` makes the calling session the **owner** of a
  closed lock; without it the lock stays an open one, with the behavior above. The owner adds and removes **members**
  (`member add|remove`, at most 16); a session that is neither never mutates, never acquires the slug and is not
  registered by trying. One **turn** serializes the members: a session mutates only while `lock.d/turn.d/sid` is its
  own id and the turn is within its ETA, for Bash, the file tools and git MCP alike, the owner's own edits included. A
  member takes the turn with `turn take` (run in the background), keeps it alive with `turn beat` and hands it back
  with `turn give --tree clean|dirty`. The tree state is the giver's word, recorded for the next member and for
  `status`: the script does no git and a dirty hand-over only warns. Only the owner heartbeats or releases; the lock's
  ETA gates the owner's own turn and `clear`, not the members, so an owner that waits on them cannot lock them out.
  Identity is the session id (`$CLAUDE_CODE_SESSION_ID`; probes saw it survive compaction, resume and reload and
  change after `/clear`), passed as a literal value. The guard checks the caller's own id (`--by`, and `--sid` on the
  caller's own verbs) before the script runs; a member, force or transfer target is only checked for shape.
  Freeing a turn takes the owner's `turn give --force`: a healthy turn is refused, a turn past its ETA plus the
  grace with a stale heartbeat needs a permission prompt, and one still held by a session marked `ended` passes the
  guard without it. `owner transfer`, for an owner that lost its id, always prompts. They go through the
  script's read-only `--check` and, like `clear`, the guard's prompt; a headless session cannot answer one. A session-end hook, where installed,
  marks a stopped session `ended` and frees its turn but keeps its membership; it runs on a normal stop, on
  SIGTERM, SIGHUP and SIGINT and on a window close, but not after SIGKILL or a crash, so a stale turn can remain, and the prompted force
  covers it. The members, turn files and `ended/` markers
  are plain files of the same user, so a session that forges them is outside the cooperative threat model, as before.
  The protocol is in [the protocol skill](../../skills/workspace-lock-protocol/SKILL.md); a repo is armed for it by the
  person adding the literal absolute-path lock script entry to the repo's gitignored `.claude/settings.local.json`
  (never a leading-wildcard allow entry, which auto-approves any command naming that path), and no agent writes that.

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
- An owned team trades speed for safety: one member mutates at a time, a stuck turn needs the owner and sometimes
  the user's click, and a dead owner's lock waits for `clear` or `owner transfer`.
- Clearing a lock is a recovery the user approves, not a pattern for risk-topic actions, where a relayed approval
  carries no weight.
- The protocol is [rules/workspace-lock.md](../../rules/workspace-lock.md); the script reference is
  [tools/workspace-lock/README.md](../../tools/workspace-lock/README.md).
