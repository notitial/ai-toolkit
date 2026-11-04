---
description: "Generate a handover document to continue work in a fresh conversation or hand it back to an orchestrator. Two modes: orchestration-bus (fixed schema → .archive/<ticket>/handoff/ when a feature workspace exists) and general (freeform doc → .archive/<slug>-handover.md otherwise). Invoke ONLY on explicit handover intent: the user (or an orchestration doc such as unattended-run Step 4) says 'handover', 'hand this off', 'status for the orchestrator', 'handover doc', or /handover. Not for ordinary summaries or session recaps."
disable-model-invocation: false
---

# Handover

Produce a handover document that gives a fresh conversation — or an orchestrator — everything it needs to continue the work. This skill is the single home for handover-doc generation.

**Boundary with `prep-compact`:** `prep-compact` decides *whether* to hand over, `/compact` in place, or `/resume` later, and owns the `/compact` continuation (and its optional focus line). This skill owns *generating the handover document itself*. If unsure which you need, start with `prep-compact`.

## Modes

- **Bus mode** — work lives under an `.archive/<ticket>/` workspace (created by `/feature-kickoff`). Writes a fixed-schema status doc into `handoff/` and updates `STATE.md`, so the orchestrator and `/archive-index` can find and parse it.
- **General mode** — no ticket workspace. Writes a freeform handover to `.archive/<slug>-handover.md`.

Use bus mode if an `.archive/<ticket>/` workspace exists or the user names a ticket; otherwise general mode.

## Input

- **Ticket slug** (bus mode) or **task name/slug** (general mode). If a single `.archive/<ticket>/` workspace exists, infer it; otherwise ask, or fall back to general mode.
- **Role** (bus mode, optional) — e.g. `backend`, `mobile`, `account`. Used in the filename. Default `worker`.

## Step 1: Gather state

From the conversation and the repo, collect:
- **Branch** and **commits made this session** (subjects + short hashes). Verify these
  actively — don't trust recall: run `git_log -1` + `git_status` on the working branch and
  record the **actual** latest short hash and branch name. If the reported work has no
  corresponding commit, say so plainly — never imply work landed that didn't. Do the same before writing a commit, PR or merge fact into STATE.md.
- **Tests / checks run** and their result. For **live/E2E verification**, record the verdict to the file bus and name which symptom path was exercised vs left untested — a result trapped in a worker's return message is lost if the worker closes ambiguously.
- **Files changed** (path + one-line what).
- **Done** — what was completed.
- **In progress / deferred / blocked** — what was not done, and why.
- **Decisions made** — with the "why," so the next session doesn't re-litigate them.
- **Open questions** for the orchestrator or other agents.

Never include secret values, tokens, or PII — reference topics, not values.

## Step 2 (bus mode): Write the handoff + update STATE.md

Write `.archive/<ticket-slug>/handoff/<role>-status.md` (create `handoff/` if missing):

```markdown
# <TICKET> — <role> handoff

**Date:** <YYYY-MM-DD>
**Branch:** <branch> @ <short-hash>
**Status:** <complete | partial | blocked>

## Done this session
- <item — commit hash if applicable>

## Verification
- **Commit:** <short-hash> on <branch> — confirmed via `git_log`/`git_status` (or "no commit this session")
- <check> → <pass/fail>
- **If this was live/E2E verification:** symptom/paths **exercised**: <list> · **not exercised**: <list>; oracle shown RED on the known-bad state? <yes/n-a>. Record the verdict **here in the bus** — do not leave it only in the return message.

## Files changed
| File | What |
|------|------|
| <path> | <one line> |

## Deferred / blocked
- <item + why>

## For the next agent
<A ready-to-paste prompt: what to do next, which files to read first, which constraints apply. For large source/code files already covered by STATE.md or the summary, say to re-read only specific ranges, never wholesale.>

## Resume (if interrupted by a session/account limit)
- **Session id:** <id> · **Branch:** <branch> · **Next task:** #<n> (<task>)
- **Limit-resets:** <value copied verbatim from STATE.md — when limits free up>
- Resume is manual: when limits reset, reopen the session; if the workspace is lock-armed
  (see `rules/workspace-lock.md`), run `workspace-lock.sh status`; re-read STATE.md, then continue at the next task.
  (No auto-resume.)
```

Then in `.archive/<ticket-slug>/STATE.md`: map this session's handoff `Status:` onto the canonical
task vocabulary (`complete`→`done`, `partial`→`in-progress`, `blocked`→`blocked`; `partial` must land as
`in-progress`, never be dropped) and update the task table; refresh the **Updated** date; fold any
review-gate verdict into the **Review verdict:** header field; and add new open questions. This keeps
the shared state authoritative.

## Step 3 (general mode): Write a freeform handover

Write `.archive/<slug>-handover.md`:

```markdown
# Handover: {task name}

## Goal
{One sentence: what the user is trying to accomplish}

## Current State
{What's done, what's in progress, what's blocked}

## Key Files
| File | State | Notes |
|------|-------|-------|
| {path} | {modified/read/created} | {what was done or matters} |

## Verification
- {Checks run → pass/fail. For live/E2E: which symptom paths were exercised vs left untested, and was the oracle shown RED on the known-bad state? Don't leave this only in a return message.}

## Decisions Made
- {Decision — what was chosen and why}

## Next Steps
1. {Immediate next action}
2. {Following action}

## Context
{Any non-obvious constraints, patterns discovered, or gotchas the next session needs to know}
```

Guidelines:
- Be specific with file paths — the next session needs to know exactly where to look. For large files already covered here or in on-disk state, tell the next session to re-read only specific ranges, never wholesale (rationale: `docs/13-orchestrator-context-discipline.md`).
- Include "why" for decisions — without it, the next session may re-litigate them.
- Next steps must be actionable, not vague ("update setup-claude SKILL.md to add the rules/ symlink loop", not "finish the setup work").
- Keep the whole document under 150 lines.
- If there's a plan file, include its path and note whether it's still valid.

## Step 4: Report

Tell the user the handover path and a one-line summary of what the next session/agent picks up. If the next step is a fresh session, remind them the handover (or the "For the next agent" block) is ready to paste. If the next worker is a **live Agent-Team teammate** (same session, requires Agent Teams enabled), deliver the "For the next agent" block via `SendMessage` to that teammate rather than pasting it into a new session.

## Stop Conditions

- Present the handover for review; do not also start the next task.
- Never write secrets/tokens/PII into the handover.
- If nothing was accomplished this session, say so rather than writing an empty handover.
- To decide between handover, `/compact`, and `/resume`, use `prep-compact` — this skill assumes the decision to hand over is already made.
