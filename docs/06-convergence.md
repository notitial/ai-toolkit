# Convergence

Intelligent loop termination — knowing when another pass is worthwhile vs when to stop.

## The Problem

Many AI workflows involve iteration: fix lint issues, review code and address findings, stabilize failing tests. The naive approach — "repeat until zero issues" — fails for three reasons:

1. **Unfixable residuals.** Some issues cannot be resolved in the current scope (e.g., a lint rule that conflicts with a framework requirement, a test that depends on unmerged code). Looping forever on these wastes tokens.
2. **Regression.** Fixing issue A can introduce issue B. Without tracking, the agent oscillates between fixes indefinitely.
3. **Diminishing returns.** The first pass might fix 80% of issues. The second fixes 10% more. The third fixes 2%. At some point, the token cost of another pass exceeds the value of the fix.

Without explicit stop logic, an agent running a "fix all issues" task will consume its entire context window chasing the last unfixable issue — and often make things worse in the process.

## The Converge Pattern

A converge loop wraps any repeatable task with metrics tracking and between-pass analysis:

```
repeat:
  1. Run the task (e.g., lint, self-review, test suite)
  2. Extract metrics (issues found, fixed, remaining, categories)
  3. Compare against previous pass
  4. Decide: continue or stop
  5. If stopping, produce convergence report with explanation
```

The critical difference from a simple retry loop: **step 4 is an LLM judgment call**, not a `remaining == 0` check. The agent examines the trajectory — are issues decreasing? Are the same issues recurring? Are remaining issues in fixable categories? — and makes a decision.

## Stop Signals

Five signals that indicate a loop should terminate:

### Clean
Zero issues remaining. The ideal outcome — the task is complete.

### Plateau
The same number and type of issues remain for two or more consecutive passes. The agent is unable to make further progress. Continuing will only consume tokens without fixing anything.

**Detection:** Compare `issues_remaining` and the **stable finding IDs** across passes (on re-review, mark each resolved/persisting/new — see [07-reviews.md](07-reviews.md#verdict-values-and-re-review-tracking)). Same count alone isn't sufficient — the agent might fix one issue but introduce another.

### Regression
More issues after a pass than before it. The fixes are making things worse. Stop immediately and report.

**Detection:** `issues_remaining[n] > issues_remaining[n-1]`. A single regression should halt the loop — never give the agent a third chance to make it worse.

### Diminishing Returns
Less than ~10% improvement between passes. The remaining issues are likely hard or unfixable in context. The cost of another pass (tokens, time) exceeds the probable benefit.

**Detection:** `(issues_fixed[n] / issues_remaining[n-1]) < 0.1`. Tune the threshold based on task type — lint fixes might warrant a lower threshold than architecture issues.

### Repeated Fixes
The agent is fixing the same things each pass — its previous fixes are being reverted or overwritten. This signals a conflict between the task's goals and some constraint (e.g., a formatter undoing manual style fixes).

**Detection:** Track which specific issues were fixed. If the same issue ID appears as "fixed" in consecutive passes, the fix isn't sticking.

## Continue Signals

Continue iterating when:

- Issues remaining > 0 **and** the trend is meaningfully downward
- Issues are in categories the agent can actually fix (code changes, not environment issues)
- The agent fixed new issues this pass (not the same ones from last pass)
- You haven't hit the iteration cap

## The Convergence Report

When the loop terminates, produce a structured report:

```markdown
## Convergence Report

**Result:** CONVERGED | PLATEAU | REGRESSION | CAP_REACHED
**Iterations:** 3

### History

| Pass | Found | Fixed | Remaining | Categories |
|------|-------|-------|-----------|------------|
| 1    | 12    | 10    | 2         | naming (1), unused-import (1) |
| 2    | 2     | 0     | 2         | naming (1), unused-import (1) |

### Analysis
Plateaued after pass 2. Remaining issues:
- `naming`: `FooBar` matches project convention but violates lint rule XYZ — suppression appropriate
- `unused-import`: Import is used by generated code not visible to linter — false positive

### Recommendation
Suppress both remaining warnings with inline annotations. No code changes needed.
```

The report serves two purposes: it gives the invoking skill (or human) enough context to decide what to do next, and it creates an audit trail of why the loop stopped.

## Key Principle: Analysis Over Counting

The between-pass analysis is the core innovation. A simple `while issues > 0` loop is trivial to implement and fails badly in practice. The LLM brings judgment:

- "These two remaining issues are in generated code — they'll come back if I fix them."
- "I fixed the same import three times but the formatter keeps adding it back — there's a config conflict."
- "The remaining 3 issues are all in test files and don't affect the acceptance criteria."

This judgment is exactly what makes convergence loops an AI-specific pattern rather than a traditional retry mechanism. The loop body is automated; the stop decision is intelligent.

## Design Constraints

### Idempotent tasks only
The task being looped must be safe to run multiple times. A converge loop on "deploy to production" would be catastrophic. Typical safe tasks: lint fix, code review, test stabilization, formatting.

### Canonical iteration caps
[rules/workflow.md](../rules/workflow.md) enforces the re-review cap; this table explains it. Always set a maximum,
and take it from this table. Never exceed the cap regardless of analysis: context is finite, and a runaway loop can consume an entire session.

| Loop | Cap | Where it applies |
|------|-----|------------------|
| Headless fix-loop (unattended) | **2** passes | orchestrator self-review / fix loops in headless mode ([05-orchestrator.md](05-orchestrator.md#headless-mode)) |
| Interactive converge (self-review) | **3** passes | the default converge loop for most tasks |
| Thorough review | **5** passes | review-convergence at milestone / full-review gates ([07-reviews.md](07-reviews.md#choosing-review-scale)) |
| Re-reviews per ticket | **2**, flat | REVISE → re-review cycles at the review gate; never scales with waves or sub-tasks ([07-reviews.md](07-reviews.md#adversarial-review-and-reviewer-failure-modes)) |

The design-review gate is stricter still — one revision round (see [07-reviews.md](07-reviews.md#design-review-gate)).

### No confirmation between iterations
In headless/unattended mode, the loop must not pause for human input. If the agent can't decide whether to continue, it should stop with an explanation rather than block. Interactive confirmation between passes defeats the purpose of automation.

### Track metrics, not just pass/fail
"Pass 2: still failing" is useless. "Pass 2: 3 issues remaining (down from 7), all in test naming category" is actionable. The metrics enable the analysis that makes stop decisions intelligent.

## Nesting

Converge loops compose. A common pattern: a pipeline skill wraps its self-review step in a converge loop.

```
implement-story skill:
  1. Read requirements
  2. Write code
  3. Build + test
  4. CONVERGE(self-review, max=3):
       - Run 10-point checklist against changed files
       - Fix issues found
       - Track: checklist violations found/fixed/remaining
       - Stop: clean, plateau, or cap
  5. Commit
```

The outer skill (implement-story) does not need to understand convergence mechanics. It delegates to the converge meta-skill and receives a report. This separation keeps pipeline skills focused on workflow orchestration while convergence logic lives in one reusable place.

**Caution with nesting depth:** A converge loop inside a retry loop inside a pipeline skill can quickly exhaust context. Keep nesting to one level — converge wrapping a single task. If you need deeper nesting, you probably need to decompose the problem differently.

## Case Study: Self-Review Convergence

One project's self-review converge loop ran the 10-point self-review checklist (canonical list in [07-reviews.md](07-reviews.md#the-self-review-pattern)) on every pass — not just re-checking previous failures. This catches regressions where fixing one issue introduces another (e.g., extracting a magic number into a constant but placing the constant in the wrong layer).

In practice, most stories converged in 1-2 passes. The 3-pass interactive-converge cap was rarely hit. When it was, the remaining issues were typically unfixable in context (e.g., a naming conflict with an existing pattern that would require a broader refactor). The plateau detection caught these within 2 passes and stopped cleanly.
