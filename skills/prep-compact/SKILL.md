---
description: "Decide how to carry context across a compaction boundary, and generate the /compact artifacts. Triages between compacting in place, handing off to a fresh session, or resuming — owns the /compact artifacts (a continuation prompt, plus an optional one-sentence focus line) and delegates handover-doc creation to the handover skill. Use when the user wants to compact, is running low on context, or says 'prep compact', 'smart compact', or 'prepare context'; 'minimal' or 'resume on minimal context' selects minimal mode."
---

# Prep Compact

Decide how to carry the current conversation forward, and write what that needs: a continuation for `/compact`
(keep going in this conversation), a handover (a fresh conversation, written by the `/handover` skill), or nothing,
because `/resume` later keeps the full history. This skill owns the triage and the `/compact` artifacts; `/handover`
owns the handover document.

`/compact` writes its own summary and keeps the working state about as well with or without steering. What it does
not do is restart the work: Claude Code waits after compacting. So the weight here is on the continuation, the first
user turn after compaction: the role, the first thing to read, the next step and the constraints that still bind. A
focus line for the summarizer is optional, and one sentence at most.

## Input

Optional: what the user plans to work on next. If not given, ask (Step 2).

Optional: **minimal mode**, when the user asks for it ("minimal", "resume on minimal context"). See **Minimal mode**.

## Step 1: Analyze conversation state

Sort the conversation into three groups:
- **Done**: finished and verified work, decisions applied, files committed.
- **In progress**: work started but not finished, open questions, uncommitted edits, blockers; for each, where it
  stands and what remains.
- **Context the next step needs**: key files, design decisions, constraints and conventions, and anything that lives
  only in the conversation (a number from command output, a decision made in chat and its reason).

If the next step needs a value that lives only in the conversation, write it to a file now (the workspace's
STATE.md, or a notes file) so the continuation can point at it. A file survives compaction; a detail in a summary
may not.

## Step 2: Ask what's next and recommend an output

In minimal mode, skip this step when the user already named the next task, and go to Step 3. Otherwise ask
Question 1 only, and use `/compact`.

Outside minimal mode, use the `AskUserQuestion` tool with both questions in one prompt.

**Question 1, what to continue with:**
- Header: `"Next task"`
- 2-4 options from Step 1 (in-progress items, pending decisions, natural next steps), each a short label (e.g.
  "Statusline pace thresholds") with a one-line description (e.g. "Decide the 5-hour rate-limit warning cutoffs in
  tools/statusline.sh"). The user can always pick "Other".

**Question 2, the output:**
- Header: `"Output"`
- Two options, the recommended one first with "(Recommended)" appended to its label:
  - `/compact`: "Continue in this conversation: a continuation to paste after compaction, and an optional
    one-sentence focus line."
  - `Handover doc`: "Start a fresh conversation, handed off by the /handover skill (bus mode if an
    .archive/<ticket>/ workspace exists, general mode otherwise)."

Recommend **`/compact`** when the next step continues the current work (same files, same problem), when the loaded
state would be costly to rebuild, or when a task boundary was just crossed and the durable state is on disk:
compacting then clears spent reasoning before the context fills up (rationale:
`docs/13-orchestrator-context-discipline.md`).

Recommend a **handover** when the context is near its limit or already degraded, the next task is a different
phase, the conversation has drifted across many topics, or the work moves to another session or agent.

**Resuming is a third option.** To step away and come back to the same work later, neither is needed: the session is
saved under `~/.claude/projects/`, and `claude --resume` or `/resume` reopens it with the full history. Say so when
the next task is the same work picked up later in the same place.

If the user picks `/compact`, go to Step 3. If they pick `Handover doc`, invoke `/handover` with the Step 1 analysis
and stop (see **Handover**).

## Step 3: Write the continuation, and an optional focus line

### The continuation

At most five lines, each one line of printable ASCII:

```
Resume as {role, one clause}.
First read: {at most 3 files on disk, with the sections or line ranges that matter}; do not re-read {large file} whole.
Next: {the immediate next step, specific and actionable}.
Constraints: {the standing constraints that still bind, e.g. no push without approval}.
Do not redo: {finished work the resumed session might repeat}.
```

- **Point at files, don't copy them.** A value that lives on disk (STATE.md, a plan, a review, a commit) is named by
  its path. Write a value inline only when it exists nowhere on disk; if more than a few qualify, write them to a
  file first (Step 1).
- **At most 3 reads, with ranges.** Right after compaction a session tends to re-read large files whole to recover
  detail the summary dropped; naming the ranges prevents that (rationale:
  `docs/13-orchestrator-context-discipline.md`).
- **Carry the constraints forward.** After compaction the session no longer remembers the ones agreed in chat;
  restate only those that still bind.
- **Check every path exists** before naming it. If an expected file is missing, say so; never invent a path.
- Leave out the "Do not redo" line when nothing is likely to be repeated. Keep the whole continuation under about
  600 characters.

### The focus line (optional)

`/compact` takes an optional instruction for its summarizer. Give it at most one sentence (about 200 characters)
saying what the session is, for example `This session is the release manager for the 2.4 cut.` Leave it out when
there is nothing to add: the summary keeps the working state without it, and the continuation carries the rest. No
lists of values or paths, and no "keep" or "drop" clauses.

### Minimal mode

- Step 2 as above: skipped when the next task is known, else Question 1 only.
- The continuation: the role, one first read, the next step and the constraints, under about 300 characters.
- No focus line.

### Output format

Present the artifacts as labeled code blocks, in the order they are used:

**① Type `/compact ` (with the trailing space), then paste this after it:**

```
{focus line}
```

**② After compaction completes, paste this to resume:**

```
{continuation}
```

With no focus line, replace block ① with "Run `/compact`." Emit one trigger only: this continuation, or the resume
prompt the handover gives the user, never both.

## Handover

When Step 2 points to a handover, invoke the `/handover` skill: it writes the handover document (bus mode for an
`.archive/<ticket>/` workspace, general mode otherwise) and what the user pastes into the fresh session. Do not
write the handover document here.

## Stop Conditions

- Never run `/compact` yourself; only write the artifacts for the user to run and paste.
- When a handover is the right call, delegate to `/handover`.
- If the conversation is short (under about 10 exchanges) or trivial, say so: a bare `/compact`, then "continue", is
  enough.
- If nothing is in progress and there is no clear next task, write nothing and say: "Nothing to carry forward — this
  conversation looks complete."
