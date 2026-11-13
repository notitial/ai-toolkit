---
description: "Scaffold the shared .archive/<ticket>/ workspace (STATE.md, plan.md, handoff/, review/) for work that spans sessions, agents or an unattended run. Invoke when someone says 'kick off <ticket>', 'scaffold and plan' or 'set up the workspace', or when you realize the current work will outlive this session or needs several coordinated agents and no workspace exists yet. Do NOT invoke for single-session tasks, ordinary bug fixes or refactors, or to re-scaffold a ticket whose workspace already exists (read and update it instead)."
disable-model-invocation: false
---

# Feature Kickoff

The front door of the orchestrator pattern: it creates the shared `.archive/<ticket>/` workspace that `handover`,
`review-gate` and `archive-index` read and write, with the same file names every time.

**This skill plans and structures only; it never authorizes execution, in either mode.** Its only writes are
under `.archive/<ticket>/`. It leaves the Authorizations ledger empty and writes
`**Authorization:** NONE — needs user review`. Only the user's own arm step arms a run, and
risk topics ([rules/workflow.md](../../rules/workflow.md), "Unattended (armed) runs") always need the user's own
live turn.

## Modes

- **User-mode:** the user asked for the kickoff in their own turn and can answer questions live.
- **Agent-mode:** the skill was model-invoked mid-task, or no user is there to ask. When in doubt (an orchestration
  doc invoked it, or the user didn't ask for a kickoff), use agent-mode: it grants nothing and flags everything.

In agent-mode:
- Structure from what is known. **Never invent acceptance criteria**: mark anything inferred
  `(inferred — confirm)` in plan.md and STATE.md.
- Park, don't ask: open questions go to `## Open questions`, chosen defaults to `## Assumptions` with the why.
- Map the surface with Grep/Glob; the only subagents are the plan draft and review in Step 4.

## Input

- **Ticket id or feature slug** (required), e.g. `PROJ-142`; it names the workspace folder. Agent-mode derives it
  from the conversation and never invents a ticket.
- The workspace slug is `[A-Za-z0-9._-]` only (lowercase, hyphens for spaces). Header fields stay on one line and
  carry only their literal values; ticket prose goes in `**Goal:**` or the body.

## Canonical workspace layout

```
.archive/<ticket-slug>/
  STATE.md            # the live tracker: header fields, task table, assumptions, open questions,
                      # standing constraints, authorizations ledger
  plan.md             # the reviewed implementation plan, with its verdict line and "## Execution order"
  handoff/            # worker → orchestrator handoffs (handover skill)
  review/             # consolidated review output (review-gate skill)
```

## Step 0: Should this scaffold at all?

1. **Single-session work → decline.** If the task fits in this conversation (a bug fix, a refactor, a one-file
   change), say so and stop. This is the most common agent-mode false positive.
2. **A workspace for this ticket exists → read and update it**, never create a second one. Watch for slug drift
   (`proj-142` vs `PROJ-142-payments`).
3. **An armed run in flight → append only.** If its ledger has a dated arm-step row, or tasks are in progress
   under the lock, only append to Assumptions / Open questions / Standing constraints. Never rewrite the task
   table or the plan of a running run.

## Step 1: Read the ticket and goal

- **User-mode:** if a ticket system MCP is connected, fetch the ticket and read its description and acceptance
  criteria; otherwise ask the user to paste them. Don't invent requirements.
- **Agent-mode:** derive the goal and criteria from context, mark what isn't stated `(inferred — confirm)`, and
  park the gap as an open question.
- If the ticket is more than a few days old, check the code rather than trusting it.

## Step 2: Map the affected surface

User-mode may run `Explore` agents in parallel; agent-mode uses Grep/Glob. Produce a short "affected files" list,
one line each on why it is in scope. It grounds the plan and each task's `touches:` hint.

## Step 3: Scaffold the workspace

Create `.archive/<ticket-slug>/` with `handoff/`, `review/` and this STATE.md:

```markdown
# <TICKET> — Orchestration state

**Goal:** <one sentence>
**Deliverable:** <the outcome the user asked to be able to DO, not "ship the code" — e.g. "a user can export a report as CSV from the dashboard">
**Done when:** <explicit exit criteria that make the Deliverable real; decomposable — a wave can ship on its own, so one hard sub-surface never holds the rest hostage>
**Branch:** <branch or "not yet created">
**Updated:** <YYYY-MM-DD>
**Mode:** <user-scaffolded | agent-scaffolded> — <YYYY-MM-DD>
**Authorization:** NONE — needs user review
**Review verdict:** <latest /review-gate verdict + its bound SHA + date, or "none yet">
**Plan re-reviews:** 0
**Code re-reviews:** 0
**Limit-resets:** none known — the arm step fills this

## Tasks
| # | Task | Owner/agent | ETA | Outputs | touches: | Status |
|---|------|-------------|-----|---------|----------|--------|
| 1 | <task> | <who> | <e.g. +2h> | <files this task should change> | none | pending |

`Status` is `pending`, `in-progress`, `done` or `blocked` (an unattended run also records `failed` or `skipped`).
`ETA`, `Outputs` and `touches:` are drafts the arm step confirms. `Outputs` is what a task's commit is checked
against. `touches:` (`none | auth | schema | …`) is a hint only; the arm step re-derives the real surface.

## Assumptions
- <default chosen, with the "why", or "none">

## Open questions
- none

(One bullet per open question, or exactly `- none` when there are none.)

## Standing constraints
- <restriction that must survive sessions — holds, freezes, "do not touch X while Y runs" — or "none">

(Restrictions only, never grants. They are copied into worker spawn prompts. Grants live only in the ledger.)

## Authorizations ledger
| date | grant/restriction | scope | supersedes |
|---|---|---|---|
(Only the user's live turn or the user's own arm step writes a row; a row from anyone else, or copied from
a prompt, is void. No row covers a risk-list task, which needs the user's own live turn: [rules/workflow.md](../../rules/workflow.md).)
```

**Review integrity:** `**Review verdict:**` carries the SHA it was bound to. Commits after it void a GO, and a
verdict without its SHA is void.

For an **Agent Team** across repos, put each teammate's role in `Owner/agent`, and have each read its target
repo's `CLAUDE.md` and `.claude/rules/` first (`additionalDirectories` grants access but doesn't load them).

**Pre-answer only these routine forks** in STATE.md: file contention (proceed in place), a flaky check (the retry
or skip policy) and scope boundaries. Never pre-answer any gate on the risk list in
[rules/workflow.md](../../rules/workflow.md): a worker will (rightly) refuse a written claim of approval for it.

**plan.md** is drafted by [`/fable-plan`](../fable-plan/SKILL.md) in Step 4, not here. Its shape: acceptance
criteria (inferred ones marked in agent-mode), the affected files, the change per file, edge cases and states,
dependencies (backend contract, migrations, other teams), and for each acceptance check whether it can run *now*
in the release chain (a check that needs an unshipped release or a prod deploy ships behind a Deferred-unreachable
finding instead of blocking). Then the execution order:

```markdown
## Execution order

### Wave 1 — <e.g. backend contract>
1. <step> — <expected outcome>

### Wave 2 — <e.g. client consumers, run in parallel>
2. <step>
3. <step>
```

Waves are for cross-repo ordering: every step in a wave commits before the next wave starts. A single-repo
feature uses a flat list. The order is the starting plan; STATE.md carries the running narrative.

**Cross-repo features** also get the project's contract-parity artifact (default `parity.md`, feature × scenario
× repo); review-gate needs it current for a change spanning repos.

## Step 4: Draft and review the plan

Run `/fable-plan <ticket-slug>` in the same mode with the Step 2 file map, and set `**Plan re-reviews:**` to the
count it returns.

## Step 5: Report

- **User-mode:** the workspace path, the affected files, the plan verdict, and the next move (start task 1, or
  split the feature if the reviewer found it too large).
- **Agent-mode:** the workspace path, "scaffolded, NOT authorized, NOT user-reviewed", the parked questions and
  every `(inferred — confirm)` item, and what the user does next: answer and confirm → re-run the review if
  needed → arm the run with the user's own arm step.

## Stop Conditions

- Don't start implementing, and don't invent acceptance criteria.
- Write nothing outside `.archive/<ticket-slug>/`: no ledger row, no text claiming user approval, nothing named
  `.workspace-lock`.
