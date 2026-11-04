# Orchestrator

An autonomous pipeline that reads a backlog, delegates implementation to subagents, tracks progress, and runs unattended.

## The Thin Coordinator Principle

The orchestrator **coordinates**; it does not **implement**. A thin coordinator:

- Reads only **progress artifacts** (checkpoint, task status, structured subagent reports) — ~**300 tokens per story** of coordination overhead, not full specs or code.
- **Never** reads architecture docs, API specs, or source code. Those belong in subagent sessions or shared artifacts (implementation briefs) consumed by workers.
- Decides **what runs next**, records **outcomes**, and applies **recovery policy** (retry, skip, escalate).

**Why:** Context is finite. A coordinator that also explores the codebase exhausts its window after a handful of stories and starts corrupting progress state. Centralized coordination also contains errors better than peer networks ([Agents](03-agents.md#hub-and-spoke-over-peer-networks)). See [Agents](03-agents.md) and [Context Management](08-context-management.md).

## Pipeline Per Story

A typical story pipeline with **embedded per-task verification**:

1. **Fetch** next item from backlog / `TASKS.json` / checkpoint.
2. **Delegate prep** (optional): preparer produces an **Implementation Brief** so implementers do not each re-read the ticket.
3. **Validate design** (optional): design reviewer checks brief vs. architecture **before** code.
4. **Spawn implementers** — parallel when scopes are disjoint, serial when they touch the same files or contracts. Use explicit contract fields in task specs:
   - `outputs` — files the task must produce.
   - `exports` — symbols the task must expose.
   - `must_call_from` — call sites that must use those symbols.
   - `must_not_touch` — boundaries the task must not cross.
5. **Per-task verify**: a **separate verifier agent** (different context, read-only tools) checks contract satisfaction and call-graph connectivity. Do not rely on the implementer's self-assessment — agents report "done" when work is incomplete ([Verification Failures](15-failure-patterns.md#verification-failures)).
6. **Commit check**: orchestrator checks **git reality** (log, branch), not the subagent's verbal claim.
7. **Parity or quality review** when multiple implementations must match.
8. **Update checkpoint** and advance the wave.

Unattended mode implies **no interactive prompts**; failures route through **policy** (retry, ticket, stop).

## The Implementation Brief Pattern

A **brief** is a single artifact (markdown or structured) that contains everything implementers need **for this story**:

- Acceptance criteria and **explicit test commands** (copy-pasteable).
- File/module hints, API shapes, **non-goals** ("do not change auth").
- Links to frozen spec sections — not a dump of the whole product spec.

**Rule:** If two implementers need the same requirement text, it belongs in the brief **once**, not in two agent chats.

## Wave-Based Execution

Group stories into **waves**:

- **Wave N** contains tasks with **no unmet dependencies** inside the wave.
- **Hard gate** between waves: CI green on integrated output (or per-branch CI before merge).
- **Serialize** tasks that edit shared registries, routes, or schemas — prevents parallel agents from colliding on hotspot files.
- Max **3–5 concurrent agents** per wave. More agents in one wave means more coordination failures.

## Checkpoint-Driven Recovery

Keep a durable checkpoint that survives compaction and restarts, and treat it as authoritative over chat memory: after any recovery, re-read it before acting. Its contents, write rules and the recovery protocol are in [Context Management](08-context-management.md#checkpoint-architecture).

## Headless Mode

For unattended runs:

- **No** interactive questions; unknowns become **tickets** or "blocked" states.
- **Allowlisted** shell commands and tools per agent ([Agents](03-agents.md)); reject or skip unknown operations.
- **Caps**: max turns per subagent, wall-clock timeout, **token/budget** ceiling.
- **Failure policy**: fix loops respect the headless fix-loop cap in the [canonical iteration caps](11-convergence.md#canonical-iteration-caps), then log and continue or halt the wave.

## Structured Reports and File-Based Messaging

Subagents return a short, fixed-format report, so the coordinator spends tens of tokens per handoff, not hundreds ([format](14-prompt-engineering.md#the-structured-report-pattern)).

**File-based inter-agent communication** (JSON task files, checkpoint artifacts, CI logs) is the recommended coordination model: no infrastructure, crash-safe, and debuggable with `cat` and `grep`. Avoid peer-to-peer LLM conversation as the primary channel; cooperating agents succeed markedly less often than independent ones ([Agents](03-agents.md#hub-and-spoke-over-peer-networks)).

## Commit Verification

**Trust but verify:** After `PASS`, the orchestrator (or a tiny script) checks:

- `git log -1 --oneline` on the expected branch.
- Working tree clean or expected staged state.

One orchestration run caught a subagent that reported success **without** a commit; without this step, checkpoint state lies.

## Failure Handling

| Situation | Policy sketch |
|-----------|----------------|
| Partial implementation | Mark partial in checkpoint; retry with narrower prompt or escalate. |
| Full failure | Increment retry; after cap, move to failed queue. |
| Timeout / stall | Kill worker; fresh subagent with same contract + "second attempt." |
| Dependency blocking | Skip task; unblock in later wave. |
| Tool/MCP errors | Classify transient vs permanent; backoff vs ticket. |

**Converge loops** (self-review, fix) respect the [canonical iteration caps](11-convergence.md#canonical-iteration-caps) — then stop with explanation.

**Retry queue:** At wave end, re-evaluate skipped/failed items once dependencies or infra have changed.

## Integration Wiring Failures

The most common structural failure is **code written but never connected**: unit tests green, end-to-end red. Contract fields, a per-task integration check and a dedicated repair task prevent it; see [Integration Failures](15-failure-patterns.md#integration-failures).

## One Commit Per Story Per Platform

For multi-platform or multi-agent work:

- **One commit per story per platform** (or per isolated worktree) keeps rollback and bisect sane.
- Batch commits across unrelated stories make failures **hard to revert** and blur accountability.

Enforce at orchestrator policy and in implementer instructions.

## Git Worktree Strategy for Parallel Agents

When running multiple agents concurrently, use **one git worktree per task** with sequential merge:

```bash
git worktree add ../wt-T001 -b agent/T001 origin/main
# run agent in ../wt-T001
# after agent completes, merge sequentially with CI gate between each merge
tsc --noEmit && npm test   # gate before next merge
```

- Assign **feature domains** (not individual files) to prevent shared-file conflicts.
- **Single-writer rule** for hotspot files (routes, configs, schemas).
- **Sequential merge with CI between each merge** — never merge two agent branches simultaneously.
- **PR as integration vehicle**; no direct push to main.

The commands above are illustrative. Per [ADR 0010](adr/0010-mcp-git-over-bash-git.md), agent-driven git runs through the `mcp__git-mcp__*` tools (`git_worktree` is denied by `hooks/git-mcp-guard.sh` in this setup, so a human creates worktrees), each passed an explicit `path` — not raw Bash `git`, which the enforcement hooks redirect or deny.

With one branch per agent and hotspot files serialized, a run can use many agents in total, wave after wave, each wave within the 3–5 cap above, and keep merge conflicts rare: a wave lands before the next one branches.

## Case Study

Three of one multi-platform project's four autonomous runs each exposed one failure class (the second had none): no execution policy, then a reviewer run inline that collapsed the coordinator, then a false PASS caught by commit verification. Thin coordination, briefs and trimmed reports took it from about 8 to a target of 12–15 stories per session. The run-by-run account is in [Failure Patterns](15-failure-patterns.md#case-study-lessons-from-four-autonomous-runs).

## See Also

- [Skills and Commands](04-skills-and-commands.md) for packaging repeated orchestration steps.
- [Convergence](11-convergence.md) for fix-loop caps and self-review patterns.
- [Multi-Repo Coordination](16-multi-repo-coordination.md) for spanning separate repos (`--add-dir` / Agent Teams) — distinct from this autonomous-pipeline pattern.
- Research sources: CooperBench (arXiv:2601.13295), MAST taxonomy (arXiv:2503.13657), Anthropic engineering (2025).
