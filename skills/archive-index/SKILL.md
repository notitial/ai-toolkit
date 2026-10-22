---
description: "Summarize and index a feature's .archive workspace: list every doc with ticket, date, and a one-line summary, and flag stale or superseded files. User-invoked: run /archive-index at the start of a session resuming ongoing work, or to answer 'what's in .archive', 'index the archive' or 'catch me up on this feature'."
disable-model-invocation: true
---

# Archive Index

Produce a navigable index of an `.archive` workspace so a session can orient in one read instead of opening every file. This fixes the recurring "re-read everything to find out where we are" startup cost, and surfaces stale or superseded docs that would otherwise mislead.

## Input

- **Scope** (optional) — a specific `.archive/<ticket-slug>/` workspace, or all of `.archive/`. If a single active workspace is obvious, default to it; otherwise index the top level and ask which to expand.

## Step 1: Enumerate

- Use Glob/Bash to list `*.md` (and other docs) under the scope, with last-modified dates (`stat`).
- Group by workspace folder (`.archive/<ticket>/`).
- Also include loose docs not under a `<ticket>/` folder — general-mode handovers (`.archive/<slug>-handover.md`) and ticketless review output (`.archive/review/`) — in a separate "Loose / non-workspace" group, so nothing is silently left out of the index.

## Step 2: Classify each document

Read only the first ~20 lines of each file (title + purpose) — do not load whole files. For each, determine:
- **Title / purpose** — one line.
- **Date** — from frontmatter if present, else file mtime.
- **Status** — using these heuristics:
  - **active** — referenced by the workspace's `STATE.md`, or the newest doc on its topic.
  - **superseded** — an older doc whose topic a newer doc covers (e.g. `plan.md` vs `plan-v2.md`, or an earlier handoff replaced by a later one).
  - **stale** — not touched recently and not referenced by `STATE.md`; likely abandoned.

When in doubt, mark **active** and note the uncertainty — do not hide a file.

## Step 3: Output the index

Present a table per workspace, newest-first:

```markdown
## .archive/<ticket>/  — <goal from STATE.md if present>

| Doc | Date | Status | Summary |
|-----|------|--------|---------|
| STATE.md | <date> | active | orchestration state — <N tasks, M open questions> |
| plan.md | <date> | active | <one line> |
| handoff/backend-status.md | <date> | active | <one line> |
| plan-old.md | <date> | superseded | replaced by plan.md |
```

Lead with `STATE.md`'s current task summary and open questions if it exists — that's the fastest orientation. Then list the rest.

Re-verify, don't transcribe: for each ticket's recorded PR/merge/SHA facts, re-check against
live git (`git_log`, the github MCP's `pull_request_read`) and mark drift explicitly — bus records rot after external
merges/rebases.

## Step 4: Offer to persist (optional)

Ask whether to write the index to `.archive/<ticket>/INDEX.md`. If yes, write it. Otherwise leave it in the conversation. Default to not writing unless asked — the index goes stale and is cheap to regenerate.

## Stop Conditions

- Read-only by default — only write `INDEX.md` if the user opts in.
- Do not read whole files; headers are enough for indexing. If a summary needs more, read a bit more for that one file only.
- Do not delete or move anything flagged stale/superseded — flag it and let the user decide.
- If `.archive` doesn't exist or is empty, say so and suggest `feature-kickoff` to start a workspace.
