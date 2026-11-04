# Orchestrator Context Discipline

Managing the *live* coordinator's own context window: treating extended thinking as the dominant — and legitimate — consumer to garbage-collect rather than suppress, delegating the delegable slice while keeping judgment in place, and compacting on state boundaries instead of token ceilings.

## What This Covers

[08-context-management.md](08-context-management.md) covers the *durable* side of context — checkpoints, token budgets, recovery after compaction, and trimming the reports that cross the subagent boundary. This document covers the other half: what fills a long-running orchestrator's *own* window while it works, and how to keep it lean without degrading the decisions it exists to make.

The distinction matters because the largest consumer is counter-intuitive. In a long coordinator session it is not file reads, tool output, or relay traffic — it is the orchestrator's **own extended thinking**. In the audited sessions it was the largest share of every compaction cycle, ahead of all tool results combined (see the [case study](#case-study-four-session-context-audit)). Optimizing context without accounting for this optimizes the wrong thing.

## Thinking Is the Product, Not Waste

Thinking is what an orchestrator is *for*: authorization checks, topology calls, catching a coupling in a config file, reconciling parallel reports. Cutting it degrades the outcomes it produces. So the goal is not to **minimize** thinking — that optimizes the wrong metric. The goal is to:

1. **Not retain spent thinking** — once a decision is made and its result is on disk, the reasoning that produced it is dead weight in the window. Compaction is its garbage collector (see [Compact on State Boundaries](#compact-on-state-boundaries-not-token-ceilings)).
2. **Delegate only the delegable slice** — move the legwork out, keep the judgment in (see below).

Do not treat a high thinking-share as waste to be trimmed. Treat it as a signal to **GC more often** and **delegate the legwork**, not to reason less.

## Delegate the Legwork, Own the Judgment

Heavy, self-contained analysis is delegable; judgment is not.

| Delegate to a subagent | Keep in the orchestrator |
|---|---|
| Code tracing, "does X reach Y?" | Authorization / escalation decisions |
| Audits, reviews, evidence-gathering | Routing, go/no-go, wave sequencing |
| Plan drafting, option enumeration | Anything on the risk list (auth, permissions, payments, PII, security controls) |
| Reading and summarizing large files | The final call on returned evidence |

- **Delegate heavy + self-contained work only.** A subagent has real overhead — spawn, round-trip, and the subagent re-establishing its own context. For *small* reasoning that overhead is net-negative; reason inline. Reserve delegation for work that is both large and cleanly scoped.
- **The judgment stays put.** A subagent may *find and quote* the guard lines that decide whether a command is allowed; the orchestrator makes the allow/deny call. Delegation that returns a *verdict* instead of *evidence* quietly relocates judgment — which is both a context and a safety error.

## Return Evidence, Not a Verdict

A delegated task must return a **compact conclusion plus the quoted evidence** — the specific lines — not a bare verdict.

- The orchestrator keeps only the evidence and makes the call itself, so the reasoning never has to be redone in-window and the judgment never leaves.
- This is complementary to the response-trimming budget in [08-context-management.md](08-context-management.md#subagent-response-trimming): trim the subagent's *prose* (reasoning, alternatives), but keep the *evidence* it was sent to gather. "command X is blocked: yes, here are the 3 lines" is the shape to aim for, not "I reviewed it and it looks fine."

## Compact on State Boundaries, Not Token Ceilings

Compaction is the real garbage collector for spent thinking, so trigger it on **state**, not on a token threshold.

- **Externalize durable state to disk first** — STATE.md, plan.md, review files (see [08-context-management.md](08-context-management.md#checkpoint-architecture)). Once the current state postdates everything in the live window, the window is almost entirely shed-able.
- **Compact at a task boundary** — a decision made, a wave closed, a handoff done — *before* the ceiling, and **never mid-decision**. A session pushed to the ceiling compacts at an arbitrary point and risks losing un-persisted reasoning.
- **Expect near-total reclamation** when state is externalized. In one audited coordinator session, ~97–99% of the "Messages" bucket was process residue over ~142 KB of already-current on-disk state; a compaction there drops the window by >90% with no state loss.

## Guard the Post-Compaction Cycle

The cycle *immediately after* a compaction is where read discipline collapses — the summary replaced the detail, and a resumed turn is tempted to re-read whole files to recover it.

- **The continuation / focus line must name the covered files explicitly:** *"these files are covered by the summary and by on-disk state — re-read only specific ranges, never wholesale."*
- This single instruction is exactly what a collapsed session lacked when it re-read two large source files wholesale, twice each, in its final post-compaction cycle — the single largest avoidable consumption in that session.
- Keep `offset`/`limit` reads across the boundary. Never full-read a file the compaction summary already covers.

## Measuring It

- **Trust the live `/context` readout** over token counts scraped from transcripts.
- **Watch the thinking-block share.** If it is the largest category, the lever is GC-cadence and delegation — not shorter reasoning.

## Anti-Patterns

### Minimizing thinking to save tokens
Optimizes the wrong metric. The reasoning is the product; suppressing it degrades decisions. GC it and delegate the legwork instead.

### Reasoning through delegable legwork in-window
Tracing a large file or running an audit inline permanently banks that reasoning in the orchestrator's window. If it is heavy and self-contained, delegate it and keep the evidence.

### Delegating the judgment
Returning a verdict instead of evidence relocates the decision to a subagent — a context error and, for anything on the risk list, a safety error.

### Riding to the token ceiling
Waiting for a forced compaction wastes the window's final stretch on stale reasoning and compacts at an arbitrary point. Compact at the next task boundary once state is on disk.

### Wholesale re-reads after compaction
The costliest and most common collapse. Covered by the post-compaction read guard above.

## Case Study: Four-Session Context Audit

An audit of four long coordinator sessions found extended thinking was 38–46% of every compaction cycle, more than all tool results combined, while ranged file reads and subagent traffic were small. The one big avoidable cost was a session that re-read two large files wholesale, twice each, right after a compaction. The lever is cadence and delegation: GC spent thinking at state boundaries, delegate heavy legwork, ask for evidence, and guard the cycle after a compaction.
