---
description: "Draft or re-draft plan.md for an existing .archive/<ticket>/ workspace with the plan-author agent, then review it with plan-reviewer. Invoke as '/fable-plan <ticket>' (a re-draft after a ticket change, or a plan for a workspace scaffolded earlier), or when feature-kickoff delegates its plan draft. Do NOT invoke when no workspace exists (that is /feature-kickoff) or for a run already armed."
disable-model-invocation: false
---

# Fable Plan

Draft or re-draft a feature's `plan.md` without re-running the whole kickoff. Two ways in: the user's
`/fable-plan <ticket>`, and [feature-kickoff](../feature-kickoff/SKILL.md) Step 4. The plan's shape is defined in
feature-kickoff; this skill drafts it with `plan-author`, reviews it with `plan-reviewer`, and writes the verdict.
Its only write is `.archive/<ticket-slug>/plan.md`; it never writes STATE.md and never arms a run. The name comes
from the drafting agent's model: `plan-author` runs on Fable.

## Input

- **Ticket id / slug** (required), `[A-Za-z0-9][A-Za-z0-9._-]*`, naming the `.archive/<ticket-slug>/` workspace. It
  must start with a letter or digit, so `.` and `..` are refused (they would put plan.md outside the workspace).
- **Mode:** `user` (the user invoked it) or `agent` (kickoff delegated it, or no user is there). In agent-mode
  plan-author marks inferred acceptance criteria `(inferred — confirm)`.
- Optional: the affected-files map (kickoff passes it; standalone, plan-author derives it).

## Step 0: Should this draft at all?

1. **The workspace must exist.** If there is none (watch for slug drift: `proj-142` vs `PROJ-142-payments`), say
   so and point at `/feature-kickoff`; this skill doesn't scaffold.
2. **An armed run in flight → don't touch the plan.** If STATE.md's Authorizations ledger has a dated row from
   `/unattended-run` arming the run, or tasks are in progress under the lock, report it and stop: swapping the plan
   mid-run corrupts its checkpoint.
3. **A re-draft of a reviewed plan is fine**, but it continues the same per-ticket cap. Read `**Plan re-reviews:**`
   from STATE.md (0 when the field is missing) and count on from it. If the cap is already reached, don't re-draft:
   report the last verdict and the count, and stop.

## Step 1: Draft

Spawn the `plan-author` agent with the ticket and goal, the acceptance criteria (or a note that they are
inferred), the affected-files map, the target repo path and the mode. It is read-only and returns the plan.md body
plus grounding notes. Author and reviewer are separate agents, so the review stays independent.

## Step 2: Write plan.md

plan-author returns a first line naming the ticket and mode (`Plan draft for <ticket> (<mode>)`), the plan body, and
a trailing **Grounding notes** list. Only the body goes into plan.md: drop the first line, keep the grounding notes
for the Step 4 report, and remove any `**Plan verdict:**` line. Write the body to `.archive/<ticket-slug>/plan.md`
with this line at the very top. Every write, each re-draft included, starts this way:

```
**Plan verdict:** UNREVIEWED
```

## Step 3: Review

Spawn `plan-reviewer` with the plan's path, `.archive/<ticket-slug>/plan.md`, and the target repo path, which it
passes to every git call; without them it may review another ticket's plan or skip its git checks. On `REVISE`,
have plan-author re-draft (no inline edits), passing it the reviewer's findings and the previous draft, and go back
to Step 2, counting cycles on from the Step 0 count against the cap in [rules/workflow.md](../../rules/workflow.md)
"Convergence and Review Termination". Stop before a re-draft that would pass the cap; a regression stops the loop too. Then replace the top line with the dated verdict:

```
**Plan verdict:** <READY | READY WITH NOTES | REVISE | INCONCLUSIVE> — <YYYY-MM-DD>
```

`INCONCLUSIVE` is for a review that couldn't verify what the plan rests on; report what it couldn't verify. This
line is the plan's only verdict; `/unattended-run`'s arm gate reads it from plan.md.

## Step 4: Report

Return the verdict and the plan re-review count. Kickoff writes the count to STATE.md's `**Plan re-reviews:**`;
standalone, tell the user to update it. Report the workspace path, plan-author's grounding notes, the parked
questions and any `(inferred — confirm)` items, and say plainly that nothing here authorizes execution or arms a run.

## Stop Conditions

- Write nothing but `.archive/<ticket-slug>/plan.md`: no ledger row, no text claiming user approval, no armed run.
- Never overwrite the plan of an armed run in flight, and don't start implementing.
