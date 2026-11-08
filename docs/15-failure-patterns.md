# Failure Patterns and Recovery

Error taxonomy, recovery strategies, and lessons from autonomous orchestration runs.

## Error Taxonomy

Failures in autonomous orchestration fall into six categories. Classifying failures by category — not by when they occurred — enables targeted fixes.

| Category | Description | Example |
|----------|-------------|---------|
| **Operational** | Missing infrastructure: whitelists, commit policies, checkpoints | Agent invokes arbitrary commands with wrong flags |
| **Context** | Orchestrator token budget mismanagement or thin-coordinator violations | Running review logic inline collapses the coordinator after 2-3 tasks |
| **Verification** | False-PASS claims, unverified completions | Agent reports success but no matching commit exists in git |
| **Integration** | Code written but never wired to existing system | Function defined but never called; unit tests pass, e2e fails |
| **Specification** | Underspecified requirements cause downstream failures | Missing data model leads to incompatible implementations across agents |
| **Coordination** | Peer-to-peer breakdown between agents | Agents produce conflicting interfaces for shared contracts |

The MAST taxonomy of multi-agent failures (Cemri et al., UC Berkeley, arXiv:2503.13657) finds two of these dominate: specification and system-design failures (about 40%) and inter-agent misalignment (about a third).

## Recovery Decision Tree

When the orchestrator detects a failure, classify it into one of six branches. Each branch has a distinct recovery path — applying the wrong recovery wastes budget and context.

**Budget or blast-radius exceeded:**
- HALT the run immediately. Create a human ticket. Do not spawn further agents.
- This is the only branch where stopping the entire pipeline is correct.

**Stall (no diff, no test progress, heartbeat stale):**
- Kill the stalled agent process.
- Respawn with the same contract, a `SECOND_ATTEMPT` flag, and a summarized prior error.
- If the respawned agent stalls again, escalate to human.

**Transient errors (429, 503, timeout, rate limit):**
- Retry with exponential backoff and jitter (cap at 5-7 attempts).
- If retries exhaust, activate a circuit breaker (5-minute cooldown).
- If still failing after cooldown, escalate to human.

**Tests red or lint red:**
- Feed error logs back to the same agent (1-2 attempts).
- If the same root cause repeats, escalate model tier (e.g., Sonnet to Opus).
- If still failing, mark `FAILED_TASK` and continue the DAG or halt based on task criticality.

**Spec or plan inconsistency (impossible acceptance criteria):**
- Block the current wave. Do not allow downstream tasks to proceed.
- Route to human for spec clarification before resuming.

**Integration wiring missing (unit green, e2e red):**
- Spawn a dedicated integration task with an explicit "wire call sites" objective.
- Grant the integration agent access to the full call graph and system topology.
- Do not re-run the original implementation agent — the code is correct, the wiring is absent.

Source: synthesized from Galileo's debugging methodology, the MAST failure taxonomy (arXiv:2503.13657), SRE practice and practitioner accounts.

## Operational Failures

Operational failures stem from missing infrastructure. The agents are capable of the work — the environment they operate in is not configured to keep them safe.

**Batched commits lose work on failure.** When multiple tasks are committed together, a revert rolls back everything. One commit per task per platform is the minimum isolation boundary.

**No command whitelist means arbitrary execution.** Without an explicit allowlist, agents invent their own build invocations with wrong flags, run commands in the wrong directory, or modify files in the wrong repository. Enumerate allowed commands; prohibit everything else.

**No checkpoint means restart from zero.** When a session hits context limits, all progress tracking is lost. A persistent checkpoint file (read at session start, updated after each task) enables recovery across sessions.

**No repository boundaries means cross-repo contamination.** In polyrepo setups, each agent must be told which repository it operates in. Crossing boundaries silently corrupts unrelated codebases.

These are first-session failures. They surface immediately and are fully preventable with operational guardrails. See [12-orchestrator.md](12-orchestrator.md) for thin coordinator design that enforces these boundaries.

## Context Failures

Context failures occur when the orchestrator consumes tokens on work that belongs in subagents. The orchestrator's context window is the single most constrained resource in the pipeline.

**The thin-coordinator violation pattern:** Running review logic, file reading, or implementation-adjacent work inline in the orchestrator multiplies context consumption per task several times over. Degradation appears after 2-3 tasks — the orchestrator loses track of its checkpoint, and the session must be terminated (not just degraded).

**Quantified impact:** in that project, about 2,000 tokens per task of unnecessary inline context, work that should have happened in a subagent. It compounds: each task carries the leftovers of the ones before it, which is why degradation shows after 2-3 tasks.

**The rule:** Every token that enters the orchestrator should be essential for coordination — checkpoint reads, status updates, delegation decisions. Everything else belongs in a subagent that returns a compact report. See the thin coordinator principle in [12-orchestrator.md](12-orchestrator.md).

**Detection:** Context collapse manifests as the orchestrator producing confused or contradictory delegation instructions, skipping tasks in the checkpoint, or repeating work already completed. Monitor for these signals rather than waiting for total session failure.

## Verification Failures

Agents claim completion without evidence. This is a documented systemic problem: agents "make code changes and even do testing but fail to recognize that the feature didn't work end-to-end" (Anthropic engineering, 2025).

**False-PASS detection:** After every reported completion, verify that a matching commit actually exists in git. Run `git log` to confirm — do not trust the agent's report alone.

**Structured reports over prose.** Machine-parsable reports with fixed delimiters (e.g., `---REPORT--- / ---END---`) cut the orchestrator's parsing cost per handoff (see Run D below). They also eliminate ambiguous completions — a structured format forces explicit status fields.

**What structured reports catch:**
- Agent reports `status: PASS` but no commit exists in the repository
- Agent reports completion but acceptance tests were never run
- Agent reports partial completion as full completion (missing fields surface the gap)

**Commit verification protocol:**
1. Agent completes work and reports status via structured report
2. Orchestrator checks git state: does the claimed commit SHA exist? Do the claimed files appear in the diff?
3. If verification fails, mark the task as `FAILED` regardless of the agent's self-report
4. Re-dispatch to a fresh agent with the verification failure as context

**Verification itself fails in two directions** (the rules are in the [Verification Gate](10-reviews.md#verification-gate)):

- **False-green:** an oracle never shown to fail on the broken state proves nothing. In one run a wrong fix passed four checks keyed on the same wrong instrumentation and reached `main`.
- **False-blocker:** a live failure blamed on code before checking the build, the target host and the infra. One run spent three live rounds on a "defect" that was a build pointing at the wrong backend.

**Split expensive live verification into capture + judge.** Driving a device or browser (capture) is mechanical and belongs on a cheap tier; the judgment about whether the observed behavior is correct belongs on a stronger tier. Splitting them keeps a multi-hundred-thousand-token live run from monopolizing the most expensive model.

## Guardrail and Observer Failures

The controls that confine unattended agents, and the recorders that watch them, fail in ways that look healthy. Six rules:

- **Disarming a control needs evidence, not an acknowledgement.** An accepted request is not a completed action: a stop command that exits 0 says the request was accepted, not that the process died. Observed: a background session stayed in `working` about 28 minutes after its job was recorded as cancelled, and treating the exit code as proof disarmed the guard on a live agent. Confirm with a fresh observation taken after the action (not a snapshot from before it) and confirm liveness, not absence. Fail toward keeping the control: unconfirmed means retain, with a timestamp and a sweep so "retained" does not become "immortal". Enumerate every path that can disarm it; hardening the obvious one left two siblings clearing on weaker evidence.
- **Make refusals observable at the source.** In an auto-denying mode the refusal text goes to the agent's own context, the agent carries on, and the job still reports `running`. Record attempts and completions with hooks and derive refusals from the gap: a denied call fires its pre-call event alone. Register every event the inference needs, since a recorder wired to the pre-call event alone makes every successful call look refused. Whether a call is still running needs age and order combined as a union (open if young enough, or nothing has completed since): age alone fails on slow builds, and order alone fails under parallel calls.
- **A recorder is not a guard.** Give it no way to deny: always exit 0 and never write a decision to stdout. A pre-call hook that exits non-zero blocks the call, and one once denied every tool call in every session on the machine. Its failure mode must be a missing log line. Report absence as absence: "no refusals recorded" and "the recorder is not installed" are different facts.
- **Never let the observed party mute the observer.** Withholding numbers when the data looks untrustworthy is right in principle, but if the trigger is "any malformed record" and the observed agent can write the log, one malformed line switches the reporting off. Scope the withholding to the failure that justifies it and degrade the rest to "these numbers are a lower bound".
- **Reports are untrusted input.** An agent reads repo content an attacker may control, and its report is read by the orchestrator that decides the next step. Wrap returned content in a nonce-bearing delimiter and strip delimiter-shaped text from it; a fixed tag is escaped by any report that contains the closing tag.
- **A verification spike before implementation pays for itself.** Probe each mechanism in the mode you actually run, before building on it.

**Case study.** One spike found four of five original assumptions wrong, each of which would have produced a system that looked fine. A hook event named for refusals, documented as firing when the auto-mode classifier denies a call, emitted nothing across four refusals in the mode the agents ran, while the pre-call and post-call events fired throughout. "Everything unlisted is denied" was false: an unlisted `whoami` ran while `curl` was refused. An untrusted workspace silently ignored its own allow-list in a headless session. A plausible name in a changelog is not evidence, so repeat the spike for each new mechanism. Source: retired ai-tooling doc 17.

## Integration Failures

Integration failures are the most insidious mechanical failure mode. The code is correct in isolation — functions are well-implemented, unit tests pass — but nothing is connected to the existing system.

**Manifestation:** Functions defined but never called. Routes added but never registered. Services implemented but never instantiated in the dependency graph. Unit tests pass because they test in isolation; end-to-end tests fail because the new code is unreachable.

**Why agents produce this failure:** Each agent operates in a narrow context scoped to its task. The agent has no visibility into call sites, initialization paths, or registration mechanisms outside its assigned files. The code it writes is internally sound but externally orphaned.

**Field reports:** practitioners writing about overnight autonomous runs often name this as a top mechanical failure: correctly implemented features that were never wired into the application.

**Mitigation — explicit contract fields:**

Give every task contract four fields: `outputs` (files it produces), `exports` (symbols it exposes), `must_call_from` (call sites that must use them) and `must_not_touch`:

```json
{
  "contract": {
    "outputs": ["src/auth/login.ts"],
    "exports": ["loginHandler", "verifySession"],
    "must_call_from": ["src/routes/auth.ts", "src/app.ts"],
    "must_not_touch": ["src/billing/**"]
  }
}
```

**Mitigation — dedicated integration verification:**
- After each wave, run e2e tests (not just unit tests) as a gate.
- When e2e fails with unit green, spawn a dedicated integration agent with call-graph access and a "wire call sites" objective.
- Do not re-run the implementation agent — the implementation is correct, the wiring is missing.

## Specification Failures

Underspecification causes the largest share of autonomous agent failures (see the [Error Taxonomy](#error-taxonomy)). Without a spec that says otherwise, agents invent schemas, skip auth checks, touch shared modules and write happy-path code. Every such gap is preventable before agents run: the [spec quality gate](10-reviews.md#spec-quality-gate) lists the six to check.

## Improvement Methodology

After each orchestration run, conduct a structured gap analysis. The goal is to identify the dominant failure category and design a targeted fix — not to fix everything at once.

1. **Catalog failures** — classify every failure by taxonomy category (operational, context, verification, integration, specification, coordination).
2. **Identify the dominant category** — the category with the most failures gets the fix. Do not spread effort across multiple categories.
3. **Root-cause the gap** — for each failure in the dominant category, identify the specific missing guardrail, policy, or verification step.
4. **Design a targeted fix** — a concrete change to agent instructions, orchestrator logic, task contracts, or verification steps.
5. **Validate incrementally** — apply the fix and run a small test batch before the next full run.

Fixes are additive. Each run's improvements compound with previous runs. A fix for operational chaos (whitelists, checkpoints) remains in place while subsequent runs address context, verification, or integration failures.

## Key Metrics

Track these across runs to measure improvement trajectory:

| Metric | What it measures | Target |
|--------|-----------------|--------|
| Tasks per session | Context efficiency — coordination overhead vs available tokens | 12-15 |
| Failure rate | Percentage of tasks that fail or require human intervention | <5% |
| Partial implementations | Tasks marked complete but missing functionality | 0 |
| Context collapse incidents | Sessions terminated due to orchestrator context corruption | 0 |
| Integration failures | Code written but not wired (unit green, e2e red) | 0 |
| Throughput trajectory | Tasks per session trend across successive runs | Increasing |

**Tasks per session** is the north star metric. It is a function of context efficiency — how many tokens the orchestrator spends per task on coordination overhead versus how many it has available.

## Case Study: Lessons from Four Autonomous Runs

Four sequential orchestration runs illustrate how the improvement methodology works in practice. Each run revealed one dominant failure category; fixing that category produced measurable improvement in the next.

**Run A — Operational chaos (17 tasks).** No command whitelist, no checkpoint, batched commits. Agents ran arbitrary commands with wrong flags, modified files in the wrong repository, and batched unrelated tasks into single commits. Every failure was operational — the agents were capable of the work, but the infrastructure was absent. Fix: add whitelists, checkpoints, one-commit-per-task policy, repository boundaries.

**Run B — Zero failures (25 tasks, 3 sessions).** All Run A fixes applied. Thin coordinator delegated everything. Checkpoint-driven recovery enabled seamless session handoffs. Wave-based execution prevented dependency violations. Result: 25 tasks, 0 failures, 0 partial implementations, ~8 tasks per session. The operational layer was validated as sufficient.

**Run C — Context collapse (2 tasks).** A new review capability was added inline in the orchestrator instead of as a subagent. The review consumed ~2,000 tokens per task of orchestrator context. After 2 tasks, the orchestrator lost track of its checkpoint and the session was terminated. Root cause: thin-coordinator principle violated. Fix: delegate all non-coordination work as subagents, no exceptions.

**Run D — Verification pays off (~10 tasks).** Structured reports with fixed delimiters reduced orchestrator parsing cost from ~200 to ~50 tokens per handoff. Commit verification caught an agent that reported `status: PASS` with no matching commit in git — a false completion that would have corrupted the checkpoint. Tool context limits surfaced as a real constraint on tasks with large file changes. Fix: always verify claims against git state; use structured reports; account for tool-imposed context limits.

**The improvement arc:**

```
Run A: No structure       → Add whitelists, checkpoints, commit rules
Run B: Structure works    → Validate at scale (25 tasks, 0 failures)
Run C: Violated principle → Re-enforce thin coordinator (delegate everything)
Run D: Trust but verify   → Add structured reports + git verification
```

Each run's failures were specific, classifiable, and fixable. The fixes were additive — Run D still relied on Run A's whitelists. The methodology transforms orchestration from "try and hope" into an engineering practice with measurable improvement per iteration.
