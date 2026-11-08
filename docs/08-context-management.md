# Context Management

Token optimization, checkpoints, and managing session degradation in long-running AI workflows.

## The Problem

Every AI tool has a finite context window. In a single task — write a function, fix a bug — you rarely approach the limit. But in long-running workflows — orchestrating 15 features overnight, running a 30-agent review — context becomes the binding constraint.

When context fills:
- **Compaction** kicks in: the tool summarizes or drops earlier messages. Information is lost silently.
- **Confusion** follows: the agent forgets decisions it already made, re-reads files it already processed, contradicts its earlier approach.
- **Corruption** is the worst case: the agent writes incorrect checkpoint data because it has lost track of what was completed.

Context management is not an optimization — it is a correctness concern. An orchestrator that loses track of completed work will re-process items, skip items, or report false results.

## Checkpoint Architecture

The checkpoint is a persistent file that survives context compaction and session restarts. It is the **single source of truth** for workflow state — authoritative over the agent's memory.

In the `feature-kickoff` / `unattended-run` workflow the ticket workspace's `STATE.md` is this checkpoint: a row is written after each task, while the [workspace lock](adr/0012-overnight-orchestrator-lock.md) is still held. When artifacts disagree, the last durable `STATE.md` write wins, over chat memory and over any earlier handoff.

**Contents:**
- Current wave/phase and backlog pointer
- Completed items: ID, commit SHA, timestamp, verdict
- Partial items: what finished, what remains, last error
- Failed items: reason, retry count, escalation status
- Retry queue: items to re-evaluate at wave end

**Rules:**
1. Write checkpoint **after every task**, not in batches. A crash between tasks should lose at most one task's progress.
2. On recovery, **re-read checkpoint first**, then decide what to do. Never trust in-memory state after compaction.
3. Keep checkpoint **compact** — it is read on every recovery. Long checkpoints waste tokens when you need them most.

## Checkpoint Compaction

As work progresses, the checkpoint grows. A checkpoint with 40 completed tasks wastes tokens that could be spent on the next task. Compact it:

**After each wave:**
1. Move completed tasks from the active checkpoint to an archive file (e.g., `checkpoint-archive.md`)
2. Keep only the last 3 completed tasks in the active checkpoint (for recent context)
3. Keep the full retry queue and failed list (these need attention)

This technique yields roughly 3–4 extra tasks per session — a significant improvement when each task costs ~300 tokens of orchestration overhead.

## Subagent Response Trimming

Reports cross into the orchestrator's context, so cap them at about 500 tokens of status, commit, files, errors and blockers, in the fixed format of [The Structured Report Pattern](14-prompt-engineering.md#the-structured-report-pattern). Reasoning, alternatives and code stay in the subagent's session.

## Brief Trimming

The implementation brief (see [12-orchestrator.md](12-orchestrator.md)) is consumed by subagents, not the orchestrator. But if the orchestrator generates or passes it through, unnecessary sections waste tokens.

**Remove from briefs that pass through the orchestrator:**
- Dependency verification details (pass/fail is sufficient)
- Full acceptance criteria to code mapping tables
- Reference implementation snippets
- Design rationale paragraphs

**Keep in briefs sent to subagents:**
- Acceptance criteria
- File paths and module hints
- API shapes
- Non-goals ("do not change X")
- Test scenarios

The orchestrator sees: "Brief generated for TASK-42, 8 acceptance criteria, 2 localization keys." The subagent sees the full brief.

## Token Budgets

Set explicit budgets per role:

| Role | Budget | Rationale |
|------|--------|-----------|
| Orchestrator | ~300 tokens/task | Reads checkpoint, delegates, writes checkpoint |
| Always-applied rules | <4,000 tokens total | Loaded on every turn; exceeding this crowds out working memory. |
| Subagent report | ~500 tokens | Only actionable data crosses the boundary |
| CLAUDE.md | <200 lines | Read on session start; every line costs tokens on every turn ([sizing](01-project-instructions.md)) |
| Checkpoint (active) | <100 lines | Read on recovery; bloat here costs tokens when you need them most |

These are guidelines, not hard limits. The point is to be intentional — every token in the orchestrator's context should earn its place.

### Token Measurement Guidance

Measure actual token consumption per run. Track:
- **Total tokens per task** — the end-to-end cost including all agent invocations
- **Orchestration overhead per task** — tokens consumed by coordination versus actual work
- **Peak context utilization per agent type** — how close each role gets to its window limit

Without measurement, optimization is guesswork. Log these metrics from early runs to establish baselines before tuning budgets.

### Cost Anchors

Multi-agent systems use about 15x the tokens of a single chat (Anthropic, "How we built our multi-agent research system", 2025). Measure your own runs before budgeting.

### Prompt Cache

A session re-sends its whole conversation every turn. While the prompt cache is warm that costs a discounted cache read; once the cache expires, the next turn reprocesses everything cold, the most expensive turn the session takes. Every request that hits the cache resets its timer.

**TTL.** In Claude Code the main conversation's cache lasts one hour on a subscription within plan usage and five minutes on usage credits, an API key or a cloud provider. Subagents get five minutes unless you set a longer TTL. Read the TTL from the docs or from `usage.cache_creation` in `claude -p … --output-format json` instead of hardcoding it. Source: [Claude Code prompt caching](https://code.claude.com/docs/en/prompt-caching.md), checked 2026-11-08.

**When keeping the cache warm pays.** Compare how long the session will sit idle with the TTL:

- Idle for less than the TTL: the cache survives alone. A keepalive is pure cost.
- Idle for longer than the TTL: a trivial call every half TTL keeps it warm, and one missed call still leaves a full TTL of margin.
- Context below roughly 200k tokens: skip it. A cold reprocess costs less than the calls.
- Pause below a usage limit, not at it. At 100% no request succeeds, so the keepalive must be paid for from headroom reserved before the wall.

**Measure before trusting.** The discount is a published API price (0.1x for a read), but the weighting a subscription's usage meter gives cache reads is not, so treat the keepalive rule as advisory until measured.

**Case study.** Two months of heavy agent use showed cache reads were 95.35% of all input-side tokens (7.28 billion; raw input was 7.75 million, the rest cache writes), so the cache is most of the input side, not a marginal optimisation. Two local cost tools disagreed 4x on the same data ($1,663 against $6,955), because both shipped stale price tables that zeroed cache pricing for the newest models. Token counts were reliable; the dollar columns were not.

## Context Exhaustion Signals

Watch for these signs that an agent's context is degrading:

- **Repeating questions** about items already decided in this session
- **Contradicting earlier decisions** without acknowledging the change
- **Missing context** — referring to files or tasks it should know about
- **Checkpoint confusion** — writing incorrect state (wrong commit hash, wrong status)
- **Style drift** — commit messages or reports losing their format consistency

After ~15 tasks in a single orchestrator session, degradation is likely regardless of context window size. Plan for session boundaries.

## Recovery Protocol

When starting a new session or recovering from compaction:

1. **Read checkpoint** — this is ground truth
2. **Read launch prompt / CLAUDE.md** — re-establish operating instructions
3. **Check git state** — `git log`, `git status` on all repos to verify checkpoint claims
4. **Reconcile** — if checkpoint says task X is done but git shows no matching commit, mark X as partial/failed; commit the finished part of an in-progress task, or discard a broken partial
5. **Resume from checkpoint** — pick up the next unfinished item

Never assume memory is complete after compaction. The agent might remember the last 3 tasks but have lost the context of tasks 4–10. The checkpoint covers those.

## The Rolling Window Pattern

For checkpoints and activity logs, keep a rolling window of recent detail with compressed older entries:

```markdown
## Completed (recent)
| ID | Task | Wave | Platform A | Platform B | Parity |
|----|------|------|------------|------------|--------|
| 42 | Instance settings | 2 | abc1234 | def5678 | PASS |
| 43 | Delete instance | 2 | ghi9012 | jkl3456 | PASS |
| 44 | Edit instance | 2 | mno7890 | pqr1234 | MINOR |

## Completed (archived)
Wave 1: 12 tasks, all PASS. See checkpoint-archive.md for details.
```

The agent gets full context on recent work and a one-line summary of older work. If it needs historical detail, it can read the archive — but most of the time it does not, saving tokens.

## Anti-Patterns

### Duplicating instructions across files
The same list copied into agents, rules, skills and the orchestrator's context costs its tokens once per copy, every session. Define it once and reference it ([whitelist case study](05-permissions-and-safety.md#case-study-whitelist-consolidation)).

### Reading docs in the orchestrator context
The orchestrator does not need to understand architecture docs, API specs, or code. Subagents do. Reading a 500-line architecture doc into the orchestrator's context wastes tokens that could have processed 2 more tasks.

### Unbounded checkpoint growth
Without compaction, a checkpoint after 40 tasks is 200+ lines of completed items. On recovery, the agent reads all of them — but only needs the last few and the retry queue.

### Verbose commit messages in checkpoints
Store commit hashes, not commit messages. If the orchestrator needs to verify a commit, it can `git log` the hash. Storing full messages doubles checkpoint size for no benefit.

## Case Study: Multi-Platform Orchestration

One mobile project's runs went from about 8 to a projected 12–15 tasks per session with these techniques: checkpoint compaction gave the most (+3–4 tasks), report trimming +1–2, and keeping briefs out of the orchestrator +1. The run-by-run history is in [Failure Patterns](15-failure-patterns.md#case-study-lessons-from-four-autonomous-runs).
