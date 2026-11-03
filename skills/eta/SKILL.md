---
description: "Assess the current task's progress and give a grounded ETA, backed by a global learning knowledge base at ~/.claude/.eta/ that gets better as real durations are recorded. Produces a progress overview, a completion table (mirrors the ticket's structure when a ticket is in scope, else a done/remaining table), an ETA with a range and its basis, then writes an 'open' estimate record. `/eta close [<id>]` reconciles the actual duration back into that record so future estimates improve. Invoke when the user says '/eta', 'eta?', 'how long', 'status and eta', 'when will this be done', or asks for progress plus a time estimate. Not for trivial one-step tasks."
disable-model-invocation: false
---

# /eta — progress + grounded ETA

Report where the current task stands and how long the rest will take — with an estimate grounded in a
growing record of estimate-vs-actual, not a guess. Every run records its estimate; `/eta close` (or a
self-close when the work finishes) fills in the real duration, so the knowledge base sharpens over time.

**Two invocations:**
- **`/eta`** — assess progress, print a completion table + ETA, write an *open* record (and sweep old opens).
- **`/eta close [<id>]`** — reconcile: fill in the actual duration, compute the error, close the record.
  With no id, closes the newest open record whose `session` is this session's; `<id>` (printed by `/eta`)
  closes across sessions.

---

## The knowledge base — `~/.claude/.eta/`

One **global** corpus feeds `/eta` in every project, so estimates learn across all your work.
One file: `records.jsonl`, one JSON object per line. Its fields are listed under **Record fields** below.

**Do not commit or share `~/.claude/.eta/`** — it is a $HOME-local personal KB (ticket ids, feature names).

**Bootstrap (first run):** if `~/.claude/.eta/` is missing, create it and an empty `records.jsonl`. Never fail
because the KB is missing — create it, note "cold start", estimate bottom-up.

### Append-only event log (race-safe — many sessions share one file)
Never rewrite a line (a read→edit→write-back drops concurrent appends). Only **append**. Two shapes:
- **Base record** — a full object written by `/eta` (an open record).
- **Event patch** — `{"id": <same id>, "event": "close"|"supersede"|"abandon", "ts": <ISO>, ...fields}`.

**To read: fold by `id`** — start from each id's base record, apply its events in time order, last event
wins. The folded view is what tables, medians, and the sweep use.

Timestamps: `date -u +%Y-%m-%dT%H:%M:%SZ` for `ts_*`; `date +%s` for `epoch_estimate` (so close computes
minutes as `(now_epoch - epoch_estimate)/60`, cross-platform — never ISO-parse in `date`).

**Privacy (hard rule):** timings, `work_type`, and neutral ≤12-word descriptors only. Never message
bodies, code, secrets, tokens, or PII. `cwd` is a **basename**, never a full path.

### Record fields
A base record (written by `/eta`):

| Field | Value |
|---|---|
| `id` | unique, e.g. `eta-<UTC timestamp>-<4 random characters>`; printed to the user |
| `session` | this session's id: `$CLAUDE_CODE_SESSION_ID` (`unknown` when unset) |
| `cwd` | basename of the working directory |
| `source`, `estimate_kind` | `live`, `live-bottom-up` |
| `work_type` | a short label, e.g. `bugfix`, `feature`, `refactor`, `docs`, `review` |
| `descriptor` | a neutral description of at most 12 words |
| `size_signals` | e.g. `{"files": 4, "tasks": 3}` |
| `convergence` | `true` for multi-round implement + review-gate work |
| `ts_estimate`, `epoch_estimate` | the time of the estimate, ISO and `date +%s` |
| `estimate_expected_minutes`, `estimate_min_minutes`, `estimate_max_minutes` | the ETA and its range |
| `estimate_raw_minutes` | the bottom-up expected time before the correction (Step 3.1); `error_ratio` is measured against it |
| `correction` | `{"multiplier": <x>, "basis": <text>}`: the multiplier applied (`1.0` at cold start) and how many rows it came from |
| `reliability` | `open` until closed, then `clean` or `noisy` |

This table is the schema: it wins over an older `~/.claude/.eta/SCHEMA.md`, and a field added here is added there
too when that file exists.

An event patch carries `id`, `event`, `ts` and the fields it sets: a `close` sets `ts_actual`, `actual_minutes`,
`error_ratio`, `outcome` and `reliability`; a `supersede` or `abandon` sets `outcome` (`superseded`, `abandoned`).
"This session's" record always means `session` equals `$CLAUDE_CODE_SESSION_ID`; a record with `session`
`unknown` is never this session's, so close it by id.

---

## Step 1 — Assess progress
Establish done vs remaining, in order of preference:
1. **Feature workspace** — `.archive/<ticket>/STATE.md` or `plan.md`: read its task table (authoritative).
2. **Ticket source** — if a ticket is in scope and this session has a ticket tool (e.g. a tracker's MCP server),
   pull the ticket's structure/status. Use if available; do not hard-depend on it.
3. **Self-assessment** — else reason over this session (todos, files changed, messages, the ask).

Classify the remaining work into a **`work_type`** and note **size signals** (files, tasks, LOC, subagents).
Flag whether it is **convergence work** (multi-round implement + review-gate) — that changes the estimate.

## Step 2 — Completion table
- **Ticket in scope** → mirror the ticket's own structure: one row per item/section, status column
  (`done`/`in-progress`/`blocked`/`todo`), keeping the ticket's ordering so it reads like the ticket.
- **No ticket** → a plain `Task | Status | Notes` done/remaining table.

Lead with a one-line overall, e.g. `Progress: 5/8 tasks (~62%)`.

## Step 3 — Estimate (grounded in the KB)
1. **Bottom-up first.** Estimate the remaining work directly (remaining tasks × your sense of each, or a
   single analog). This is your raw expected time — an honest forecast, already un-padded. Record it as
   `estimate_raw_minutes`.
2. **Pull the correcting rows.** Fold `records.jsonl` by id; keep rows with
   **`estimate_kind:"live-bottom-up"` AND `reliability:"clean"` AND `error_ratio != null`**, and only a row that
   has `estimate_raw_minutes` or whose `correction.multiplier` was 1.0 (any other row's ratio was measured against a
   corrected estimate). Narrow to the
   current `work_type` only if that type has **≥5** such rows; else pool all types; if still <3 rows,
   **apply no correction** (×1.0).
3. **Correct (once you have live rows).** Multiply the bottom-up expected by the **median `error_ratio`**
   of the correcting rows.
4. **Range**: the bottom-up (raw) expected multiplied by the **p25/p75** of those rows' `error_ratio`
   (not min/max, which a few outliers dominate); cap so max/min ≤ ~4×. With no correcting rows, use a
   deliberately wide bottom-up range.
5. **Convergence work → don't down-correct.** Multi-round implement + review-gate work tends to overrun. Widen upward and flag the overrun risk instead of shrinking it.
6. **State the basis honestly** — how many correcting rows and which percentile. With none: "cold start —
   bottom-up only, no correction, wide range."

## Step 4 — Record the estimate (and supersede a stale open)
1. **Supersede first.** If an *open* record has this session's `session`, append a `supersede` event for its id
   (`outcome:"superseded"`) so repeat `/eta` runs don't strand old opens.
2. **Append the new open record** — full object, `source:"live"`, `estimate_kind:"live-bottom-up"`,
   `reliability:"open"`, `session` = `$CLAUDE_CODE_SESSION_ID`, `cwd` = basename, `epoch_estimate` from
   `date +%s`, `estimate_raw_minutes` = the Step 3.1 bottom-up expected. Remember its `id`.

## Step 4b — Sweep stale opens (every `/eta` run)
Fold the log; for **this cwd's** open records older than **~7 days** with no close/supersede/abandon event,
prompt the user: close-with-known-actual, or append an `abandon` event (`outcome:"abandoned"` — excluded
from medians, counted in a coverage line). This counters survivorship bias: messy overrun sessions are the
least likely to get closed, so unswept data drifts optimistic.

---

## `/eta close [<id>]`
1. **Find the target.** `<id>` → that record (works across sessions; the id is printed by `/eta`). No id →
   the newest open record whose `session` is this session's. If none, say so and stop.
2. **Require `epoch_estimate`.** If the target lacks it (e.g. a hand-added record), stop and report — do not ISO-parse.
3. **Compute.** `ts_actual` = now; `actual_minutes` = `(now_epoch - epoch_estimate)/60`;
   `error_ratio` = `actual_minutes / estimate_raw_minutes`, kept unrounded (it is authoritative): the uncorrected
   estimate, so the correction learns from raw forecasts. An older record without that field divides by
   `estimate_expected_minutes` if its `correction.multiplier` was 1.0, else sets `error_ratio` to `null`;
   `outcome` = `beat | on-target | overran` (on-target ≈ within min–max).
4. **Tag `reliability`.** If `actual_minutes` exceeds `estimate_max_minutes` by **>3× and >120 min**, the
   gap is probably idle/overnight/human-latency, not work — ask "was this continuous work?"; on no/unknown
   mark `noisy`, else `clean`. Default `noisy` when uncertain. (Noisy rows never enter the median.)
5. **Append a `close` event** referencing the id with `ts_actual, actual_minutes, error_ratio, outcome,
   reliability` — never rewrite the base line.
6. Tell the user the delta: estimated vs actual and the error ratio.

## Self-close on completion (best-effort)
If the work an `/eta` estimate covered visibly completes **in the same session**, run the close step before
wrapping up — don't wait to be asked. Manual `/eta close [<id>]` is the reliable fallback. An unclosed open
record is harmless; it just adds no learning signal until closed (and the sweep will catch it later).

## Output format
```
Progress: <fraction> (~<pct>%) — <one-line what's being worked on>

<completion table>

ETA: ~<expected> (range <min>–<max>) — <basis: # correcting rows, percentile, prior/cold-start; convergence flag if set>
Recorded: <id>   (run `/eta close <id>` when done)
```

## Privacy & stop conditions
- KB stores timings + work_type + neutral descriptors only; `cwd` is a basename; never secrets/PII/code.
- `~/.claude/.eta/` is do-not-commit / do-not-share.
- `/eta` is read-and-record; it does not start or change the underlying work.
- The KB lives in `$HOME`, outside any repo — writing it needs no repo/workspace lock.
- If there is no discernible task in progress, say so rather than inventing one to estimate.
