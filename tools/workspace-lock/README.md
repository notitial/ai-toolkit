# workspace-lock

An advisory lock that **serializes the mutating work** of several independent Claude Code
orchestrators running **unattended overnight** against **one shared working copy** on **one
machine**. Read-only work (research, review, planning) needs no lock; only code edits, builds,
tests, and e2e runs are serialized.

It is a **pure lock mechanism**: it does **no git** and **no network**. All git work is done by
the calling skill through MCP git tools (see [ADR 0010](../../docs/adr/0010-mcp-git-over-bash-git.md)).
For the full pattern and rationale see
[ADR 0012](../../docs/adr/0012-overnight-orchestrator-lock.md). The `unattended-run` skill wraps
this script into the per-run flow.

## Install

`/setup-claude` symlinks this script to a stable, machine-independent path. It runs by that path, so it
is committed `100755`, and `tools/install-copies.sh status` reports it if it is not executable:

```
~/.claude/tools/workspace-lock.sh   ->   tools/workspace-lock/workspace-lock.sh
```

Invoke it by that path with a literal `$HOME` (portable across machines/usernames), and allowlist
the **same** form:

```
$HOME/.claude/tools/workspace-lock.sh <sub> …
Bash($HOME/.claude/tools/workspace-lock.sh *)      # in the workspace settings.json allow list
```

Whether the permission matcher honors literal `$HOME` is **undocumented** (it is a different
mechanism from hook `command` `$HOME`, which is execution, not matching). If a plain `status` call
still asks for permission, the entry did not match: add the literal absolute path as well
(`Bash(/Users/<you>/.claude/tools/workspace-lock.sh *)`).

## Model

- **One lock per workspace** held across a whole mutating phase → runs execute **serially** (one
  mutator at a time). On one machine this also means only one heavy build runs at once.
- **Shared working copy, not worktrees.** The lock guards the single working copy's checked-out
  branch state + build env. A single copy contains the blast radius if coordination hiccups.
- **Dot-prefixed folder** (default `$PWD/.workspace-lock/`, created on first use; an env-set
  `WORKSPACE_LOCK_DIR` **must be absolute** — a relative value dies, so the lock path can never
  silently depend on where a fresh shell starts):
  ```
  .workspace-lock/
    status.json              # persistent mirror: {"state":"free"} | {"state":"locked", holder…}
    lock.d/                  # the atomic mutex (mkdir/rmdir) — AUTHORITATIVE
    lock.d/holder            # the holder id, written first; release and heartbeat check it
    lock.d/{eta_epoch,phase,task,reason,repos,acquired_at}   # token metadata the mirror is rebuilt from
    lock.d/heartbeat_epoch   # last acquire or heartbeat: the liveness half of `clear`
    cleared/<id>             # "<epoch> <by-id>": <id>'s lock was cleared; its next lock call fails loudly
    sessions/<session_id>    # written by the guard hook: the id this session acquired with
    workspace-lock.log       # durable give-up/refuse/wedge/clear log
  ```
- **Atomic acquire** via `mkdir .../lock.d` (a directory *is* the mutex — exactly one racer wins).
  The holder id is written to `lock.d/holder` *before* the mirror; `release`/`heartbeat`
  authenticate against it (refuse on unknown/mismatch), never against `status.json`.
- **`status.json` is a display MIRROR, not the lock.** Created on first `acquire`, it **persists**
  across free↔locked (does not vanish on release). Every acquire gates on `lock.d`, never on the
  flag, so it can never cause a double-acquire. **Crash-drift rule:** `lock.d` is authoritative; the
  `status` subcommand is **read-only** and reconciles from the token on every read (present → held,
  absent → free), so it always reports correctly.
- **A free/debris folder does not arm via walk-up.** A workspace is guarded persistently (even
  while the lock is free) when `WORKSPACE_LOCK_DIR` is set — the deliberate, persistent arm. The
  guard's walk-up fallback counts a `.workspace-lock/` **only when it holds an active `lock.d/`**,
  so a leftover free/debris folder (`status.json` + log, no `lock.d/`) does **not** arm a workspace
  and never blocks a local session, and the guard never recreates such a folder just to log a
  denial. A mis-scoped `acquire` in an unrelated repo can still create a `$PWD/.workspace-lock`
  while it actively holds the lock, but once released the leftover is inert. (Preventing the
  mis-scoped acquire itself belongs at the launch layer — ensure workers carry the canonical
  `WORKSPACE_LOCK_DIR` — not in `acquire`, which must stay able to arm a fresh workspace from its
  `$PWD` default.)

## Usage

```bash
export WORKSPACE_LOCK_DIR=/path/ws/.workspace-lock  # shared by all runs; MUST be absolute
                                                          # (default: $PWD/.workspace-lock)

# Take the lock (run in BACKGROUND — the wait can last hours, past the 10-min Bash-tool cap).
# Identity goes on the command line via --id (survives fresh shells and compaction):
$HOME/.claude/tools/workspace-lock.sh acquire --id backend-orch --repos "/abs/backend,/abs/api" \
  --task "PROJ-142" --reason "edit+build+e2e" --eta +4h

$HOME/.claude/tools/workspace-lock.sh status                     # always prints status.json
$HOME/.claude/tools/workspace-lock.sh heartbeat --id backend-orch --eta +2h --phase e2e-tests
$HOME/.claude/tools/workspace-lock.sh release --id backend-orch  # only if you hold it
```

**Identity: pass `--id <slug>` on every `acquire`/`release`/`heartbeat` call.** `env
WORKSPACE_LOCK_ID` still works as a fallback (the flag wins if both are set), but only `--id`
survives a fresh shell after compaction AND stays visible in the command string for the lock-guard
hook to parse. **Never use the inline env-prefix form** (`WORKSPACE_LOCK_ID=x
$HOME/.claude/tools/workspace-lock.sh …`) — the leading `VAR=` defeats the
`Bash($HOME/.claude/tools/workspace-lock.sh *)` allowlist prefix match and the call falls back
to a permission prompt, which no one answers overnight. When redirecting lock-script output, send it
to `/dev/null` or a scratch path (`> /tmp/lock.log 2>&1`); any other redirect target voids the always-allow exemption
and the call falls under normal lock rules. Keep every lock-script call a single plain command: a `|`/`;`/`&`/newline
trailer or any substitution (`$(…)`, backticks, `<(…)`, `>(…)`) voids the exemption too.

Re-acquiring a lock you already hold is safe: `acquire --id x` when `x` is the current holder
prints `ACQUIRED (already held)`, refreshes the ETA/metadata from the new call's args, and exits 0
— a post-compaction orchestrator that re-runs its own acquire does not deadlock on itself. The
flip side: self-registration accepts **any** slug, so an id collision with the current holder is
destructive — a second session acquiring with the holder's id reentrantly refreshes (and can
shorten) the holder's own lease. Ids MUST be unique per run.

### Subcommands
| Command | Effect |
|---|---|
| `acquire --id x [--repos a,b] [--task t] [--reason r] [--eta +4h] [--after-clear]` | Atomically take the lock; **reentrant** (already-mine → `ACQUIRED (already held)`, ETA refreshed, exit 0); if held by another, recheck every 30–35 s until free or `MAX_WAIT`. Exit 0 = held, 2 = gave up. An id whose lock was `clear`ed is refused (loudly) until it passes `--after-clear`, once the user agrees. |
| `release --id x` | Release — authenticates against `lock.d/holder`; refuses on mismatch/unknown. Idempotent when the lock folder exists here and is free; **errors (non-zero) when no lock folder exists at the resolved path** (likely released from the wrong directory). A successful release removes a `cleared/x` marker. |
| `status` | **Read-only**: print the current state, reconciled from the authoritative `lock.d` (never creates or writes). |
| `heartbeat --id x [--eta +2h] [--phase p]` | Update ETA/heartbeat/phase — refuses if not the holder. Past the ETA a bare heartbeat is refused: `heartbeat --eta <new>` is the **retake**. Every heartbeat **rebuilds the full locked `status.json` from the token metadata**, so a mirror stamped free by a release/re-acquire race is repaired too. |
| `clear --id me --holder h [--check]` | Free a lock held by `h` once `WEDGE_GRACE` has passed since **both** its ETA and its last heartbeat. Compare-and-clear; never acquires; refuses an empty holder and your own lock. `--check` prints one `CLEARABLE …` / `NOT-CLEARABLE …` line and changes nothing. The guard runs `--check` and turns `CLEARABLE` into a **permission prompt**; it denies `clear` from workers, headless sessions and any non-canonical spelling. Writes `cleared/h`, logs `CLEARED`. |

### Config (env)
| Var | Default | Purpose |
|---|---|---|
| `WORKSPACE_LOCK_ID` | *(unset)* | Holder identity fallback (`[A-Za-z0-9._-]+`) — prefer `--id`; the flag wins if both set. |
| `WORKSPACE_LOCK_DIR` | `$PWD/.workspace-lock` | The lock folder (created on first use) — **same shared value for every run; must be absolute when set**. |
| `WORKSPACE_LOCK_MAX_WAIT` | `28800` (8h) | Seconds `acquire` waits before giving up (exit 2). |
| `WORKSPACE_LOCK_INIT_LEASE` | `1800` (30m) | Initial ETA when `acquire` gets no `--eta` (see below). |
| `WORKSPACE_LOCK_WEDGE_GRACE` | `1800` (30m) | The one grace: seconds past the holder's ETA before a waiter escalates to the wedge WARN + durable log line, and past both ETA and last heartbeat before `clear` is allowed. |
| `WORKSPACE_LOCK_LOG` | `<lockdir>/workspace-lock.log` | Durable give-up/refuse/wedge log. |
| `WORKSPACE_LOCK_TEST_POLL` | *(unset)* | Test hook: force the poll interval. Do not set in normal use. |

### Polling
A waiter rechecks every **30 s plus 0–5 s of jitter**, whatever ETA the holder declared, so a
holder that releases early is noticed within ~35 s; the jitter reduces lockstep rechecks between
waiters (`mkdir` picks the one winner), and the last sleep is clamped so the wait never overruns `MAX_WAIT`. (An earlier
ETA-scaled ladder slept up to 60 min after an early release, because declared ETAs are padded.)
The `BUSY` / `WARN` stderr line prints on the first check, whenever the holder or wedge state
changes, and otherwise at most every 10 min. **Because a single foreground Bash call caps at 10
minutes, run `acquire` as a background task**; the harness wakes the session when it exits with
`ACQUIRED` / `TIMEOUT`.

There is no queue: the lock goes to whichever `mkdir` lands first after a release, so a fresh
acquirer can win the gap ahead of an earlier waiter (correct — the waiter keeps waiting). A
background `acquire` whose session no longer needs the lock can still win it and hold it
unattended; it surfaces as wedged at its ETA + grace.

### Wedge detection (waiter-side)
When a waiter sees the holder more than `WORKSPACE_LOCK_WEDGE_GRACE` seconds past its ETA, it
escalates the `BUSY` stderr line to `WARN lock wedged since <eta>, held by <id>, heartbeat last
<ts>` and writes one durable `WEDGED …` line to the log — this is the signal the morning handover
reads. The same path fires when `lock.d` exists with an empty/missing holder (a SIGKILL corpse):
`WARN lock wedged, holder unknown — tell the user (a human inspects and clears it)`. In both cases the waiter keeps
waiting/timing out; it never takes the lock. When the holder's last heartbeat is past the grace
too, the WARN line adds the `clear` command a session with a human
can run.

### Expiry, retake and clear (ADR 0012)
- **Re-arm.** Past its ETA a lock is re-armed: the guard denies the holder's own mutations (reads
  and `.archive`/scratch writes still pass) and a bare `heartbeat` is refused.
- **Retake.** The holder (any team member, for a team slug) runs `heartbeat --id x --eta <new>`.
  No prompt: it is its own lock and still held.
- **Clear.** After `WEDGE_GRACE` past both the ETA and the last heartbeat (`lock.d/heartbeat_epoch`;
  missing counts as stale), another interactive session runs `clear --id me --holder x`; the guard
  asks the user with the holder, ETA, heartbeat and lock dir. The cleared id's next `heartbeat`,
  `release` or `acquire` fails loudly naming who cleared it — the retake cannot follow a clear.

### Heartbeat before a human-paced wait
Wedge detection and expiry key on the holder's ETA and last heartbeat. An *interactive* holder that
idles waiting on a person (a question, a review, a decision) stops heartbeating, so its ETA lapses:
the guard denies its own next edit until it retakes the lock, and after the grace waiters flag it
`WEDGED` though it is alive and another session may ask the user to clear it. Before a human-paced wait,
run `heartbeat --id <id> --eta <generous>` with an ETA that covers the wait. Found by re-running the
protocol in a fresh interactive session.

## Deliberate limitations

- **No automatic break of a stale lock.** A waiter that sees a wedged or empty-holder lock
  **WARNs and logs, but never removes `lock.d`**; a long-silent holder is freed only by a
  prompted `clear` (above), and an empty-holder corpse only by hand (`status` to inspect, then
  remove `lock.d`). Softeners: `release` runs on
  ordinary failures; a bounded `MAX_WAIT` makes waiters log-and-exit instead of hanging all night;
  waiter-side wedge WARN + the durable `WEDGED` log line let the morning handover spot a dead
  holder fast. (A hard signal in the one-statement gap between winning the `mkdir` and writing
  `status.json` leaves the same empty-holder signature — an irreducible micro-window of the same
  class; waiters surface it as `holder unknown`, and `status` as locked-with-metadata-unavailable,
  never free.)
- **Won-after-parent-death.** If `acquire` runs in the background and the parent session dies *after*
  it wins the lock, nobody runs the work or releases. Mitigation: the lock always carries an ETA
  (`--eta`, or the short `INIT_LEASE` when none is given), and the `unattended-run` skill heartbeats
  each task in with that task's ETA, so a dead parent leaves a lock whose ETA expires and is visibly stale.
- **Repo paths must not contain commas** — the `--repos` list is comma-separated. Quotes/control
  chars in field values are escaped/stripped; `WORKSPACE_LOCK_ID` is restricted to `[A-Za-z0-9._-]`.
- **Same-machine, same-filesystem only.** `mkdir` atomicity is not guaranteed over networked FS.
- **Workspace root must not sit under a `.archive` path component without an intervening `.git`
  marker** — such a root can be neither armed nor guarded (the guard's `.archive` exemption
  swallows it: arm refuses, guard skips — symmetric). Keep the lock at a true repo/workspace root.

## Tests

`bash tools/workspace-lock/test-acquire.sh` (about 1.5 min) runs the acquire wait loop and `clear` for real.
`bash tools/workspace-lock/test-guard.sh` runs the guard hook: the reads a non-holder may run, scratch writes, the
lock-script exemption, the re-arm and the clear prompt.
