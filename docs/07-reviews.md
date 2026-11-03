# Reviews

Multi-agent review architecture — layered gates for catching different classes of issues at different costs.

## The Multi-Layer Review Philosophy

Code review in AI-assisted development works best as multiple specialized passes rather than one monolithic review. Each layer catches a different class of issue:

1. **Design review** (before code) — validates the implementation plan against architecture constraints. Catches misaligned domain models, wrong layer placement, missing error handling before any code is written.
2. **Self-review** (after code, before commit) — the implementing agent reviews its own work against a checklist. Catches mechanical issues: hardcoded strings, magic numbers, missing test scenarios, wrong state types. See [Convergence](06-convergence.md).
3. **Platform code review** (after commit) — specialized reviewers examine platform-specific quality: architectural compliance, security patterns, concurrency, dependency injection correctness, naming conventions.
4. **Cross-platform parity review** (after both platforms commit) — compares implementations across targets. Catches divergence: different error handling, missing test scenarios on one platform, inconsistent naming.
5. **Comprehensive review** (milestone gates) — full multi-agent sweep at phase boundaries. Expensive in tokens but catches systemic issues that individual reviews miss.

**A CI layer:** an automatic model review of every non-draft PR, run in CI with no shell or write tools, posting its verdict as a signal rather than a required check ([ADR 0013](adr/0013-app-owned-pr-review.md)).

**Why layers:** No single review catches everything. A design reviewer does not see code quality. A platform reviewer does not see cross-platform divergence. A self-review does not catch architecture violations the implementing agent is unaware of.

## Review Scales

Match review depth to change scope and risk.

### Full review (20-30 agents)
For milestone gates, release candidates, or initial architecture validation:

- **Phase 0:** Blocking CI gate — if build/test/lint fails, stop.
- **Phase 1:** 20+ parallel deep-dive agents, each covering a specific domain (build/CI, contracts, security, architecture, testing, accessibility, design system, error handling).
- **Phase 2:** 3-4 gatekeeper agents that read all Phase 1 reports and produce rollup verdicts.
- **Phase 3:** Final synthesis — single report with prioritized findings and readiness verdict.

Token cost: ~50K-100K tokens. Use sparingly — once per major milestone, not per feature.

### Mini review (5-7 agents)
For feature completion or cross-cutting changes:

- Platform-specific code review (1 agent per platform)
- Cross-platform parity check (1 agent)
- Security scan (1 agent)
- Optional: architecture alignment (1 agent)

Token cost: ~15K-25K tokens. Suitable for weekly cadence or per-feature.

### Self-review (1 agent, converge loop)
For every implementation, before commit. A checklist-driven pass inside a converge loop. Runs inside the implementing agent's context — no new agent spawn required.

Token cost: ~2K-5K tokens per pass. Use on every story or significant change.

## Severity Rubric

Consistent severity levels across all review types:

| Level | Definition | Examples | Action |
|-------|-----------|----------|--------|
| **CRITICAL** | Security vulnerability, data loss risk, crash in core path | Secrets in code/logs, force-unwrap on API response, SQL injection, missing auth check | Block merge. Fix immediately. |
| **HIGH** | Architecture violation, incorrect error handling, missing tests for critical path | Business logic in UI layer, unhandled error case, no test for auth flow | Block merge. Fix before approval. |
| **MEDIUM** | Pattern violation, missing tests for non-critical path, inconsistency | Wrong naming convention, missing edge case test, state type mismatch | Fix in current PR or create follow-up. |
| **LOW** | Style preference, minor naming, documentation gap | Variable name could be clearer, missing doc comment on public API | Note for future. Do not block merge. |

**Key rule:** Define severity once and reference it everywhere. If each review agent invents its own scale, findings are incomparable.

**Reachability, not severity, decides blocking.** A HIGH defect that no released client can run today is filed as deferred, bound to the release that makes it reachable, and doesn't block this merge; that release is when the filed finding is enforced.

## The Readiness Model

Define explicit verdicts so "are we ready?" never becomes a vague yes/no:

**Verdict A — Architecture Ready:** Zero CRITICAL/HIGH findings. CI green. Contracts aligned between platforms. Architecture is sound for the next development phase.

**Verdict B — Ship Ready:** Verdict A met, plus: features implemented, localization complete, tests passing and covering critical paths, parity confirmed between platforms.

A project can be architecture-ready but not ship-ready — that distinction is useful information for planning.

## The Self-Review Pattern

A checklist the implementing agent runs against its own changes, typically inside a converge loop:

1. **Acceptance criteria coverage** — every AC has corresponding code and test
2. **Test naming convention** — `featureName_scenario_expectedResult`
3. **Tests pass** — hard gate, no exceptions
4. **No hardcoded strings** — all user-facing text through localization system
5. **No magic numbers** — named constants (exceptions: 0, 1, test data)
6. **Error boundaries** — errors mapped to a consistent domain error type at the data layer
7. **State management** — consistent state management type throughout the feature
8. **Layer placement** — no UI framework imports in domain, no data layer logic in presentation
9. **No secrets in logs or code** — API keys, tokens, PII stripped before logging
10. **Follows existing patterns** — matches conventions already established in the codebase

**Run the full checklist every pass.** Do not just re-check previous failures. Fixing one issue can introduce another (extracting a magic number into a constant but placing it in the wrong layer).

## The Gatekeeper Pattern

In large reviews, Phase 1 produces many reports. Gatekeeper agents in Phase 2 read all reports and produce rollup verdicts:

- **Criticality gatekeeper** — reads all findings, identifies true CRITICAL/HIGH vs. over-classified
- **Parity gatekeeper** — cross-references platform-specific reports for divergence
- **Contracts gatekeeper** — checks domain model alignment, error type parity, API contract consistency
- **Readiness gatekeeper** — synthesizes everything into a verdict (A/B/blocked)

Gatekeepers prevent the "30 agents, 30 reports, now what?" problem. They compress many reports into actionable decisions.

**Multi-review aggregation:** Multiple independent reviews aggregated through a judge agent consistently outperform single-reviewer approaches. The architectural pattern — parallel narrow reviewers feeding a judge agent that filters to high-signal findings — is the highest-confidence review recommendation across multiple independent implementations (Diffray, GitHub Copilot Code Review, practitioner reports).

## Adversarial Review and Reviewer Failure Modes

Review is only as good as the reviewer. AI reviewers suffer from well-documented cognitive failures that can turn a review gate into theatre.

### Why grounded review matters

Pure self-review — one model reviewing its own output with no external signal — is nearly worthless. RefineBench (2025) tested SOTA models across 1,000 problems and measured self-refinement gains of +1.8 percentage points or less across five iterative attempts. The ICLR 2024 paper "Large Language Models Cannot Self-Correct Reasoning Yet" showed LLMs cannot reliably find their own mistakes without external feedback. For weaker models, self-repair performs **worse** than regenerating from scratch.

**Grounded review — where the reviewer can run tests, read linter output, or consult static analysis — delivers 2–15% improvement** on standard benchmarks. Self-Debugging with unit-test feedback improved baseline accuracy up to 12%. Security-vulnerability patching with static-analysis feedback reduced vulnerabilities up to 33%, versus under 10% without external signals. OpenAI's CriticGPT (fine-tuned for critique) produced reviews preferred over human critiques 80%+ of the time. Sources: RefineBench 2025, ICLR 2024 (arXiv:2310.01798), CriticGPT (OpenAI 2024), Self-Debugging (Chen et al. 2023).

**Rule:** A reviewer that cannot run tests, read lint output, or consult a type checker is a reviewer that cannot ground its claims. Give reviewers read-only access to test/build/lint output wherever possible. "Think harder" is not a substitute.

### The separation principle

**The agent that wrote the code is compromised.** It knows what it built, it will rationalize its choices, and it will minimize its own mistakes. Separation of generation from evaluation is non-negotiable for meaningful review. This means:

- Generator and reviewer run in **isolated contexts**, not the same session.
- The reviewer does not see the generator's commit message, PR description, or self-assessment before forming its own view. Framing code as "bug-free" can drop an AI reviewer's defect detection by 16–93%, and stripping that framing restores most of it.
- Reviewers should be subagents with their own context window, not inline checklists run by the implementing agent. See [Agents](03-agents.md) for the hub-and-spoke pattern that enforces context separation.

The self-review pattern earlier in this document is useful for catching mechanical issues but must not be mistaken for adversarial review. It is a first pass, not a gate.

### Six reviewer failure modes

| Failure mode | Symptom | Mitigation |
|---|---|---|
| **Sycophancy** | Reviewer defers to the generator, softens findings, agrees without analysis | Explicit anti-sycophancy framing: "Assume issues exist. Your job is to find them, not to confirm correctness." Session separation — never run generation and review in the same context. |
| **Confirmation bias** | Framing code as "bug-free" or "reviewed" drops defect detection 16–93% | Strip commit messages, PR descriptions, and author assertions before presenting code to the reviewer. Metadata redaction restores most of the lost detection. |
| **Critique collapse** | Generator accepts all criticism blindly, introducing regressions to appease the reviewer | Require the generator to rebut each finding before conceding. Route findings through a moderator/gatekeeper agent that filters and deduplicates (see Gatekeeper Pattern above). |
| **Trivial-issue crowding** | Reviewer front-loads naming/formatting observations and misses deep bugs | Force correctness-first ordering in the reviewer's report format: correctness → error handling → performance → security → maintainability → testing gaps. Exclude style unless it masks a bug. |
| **Non-convergence** | Review loop runs indefinitely; fixes introduce new issues that trigger new reviews | Hard iteration limits per the [canonical iteration caps](06-convergence.md#canonical-iteration-caps). Fresh context per iteration. Explicit stopping criteria. See [Convergence](06-convergence.md) for plateau and regression detection. |
| **Over-correction** | Detailed chain-of-thought prompts inflate false-positive rates — reviewer rejects correct code | Frame the verdict as "approve with suggestions" rather than binary pass/fail. Require evidence (file:line) for every rejection. |

### Verdict values and re-review tracking

Three conventions keep multi-round review legible:

- **INCONCLUSIVE is a first-class verdict.** Every reviewer's verdict enum carries an INCONCLUSIVE value (with a one-line reason) alongside its pass/revise values. A reviewer that cannot ground a claim — no test/build/lint output available, or the change depends on code outside the diff — records INCONCLUSIVE rather than being forced to pick a side. A forced binary verdict on an ungroundable change is noise, not signal.
- **Stable finding IDs across re-reviews.** On any re-review, tag each finding with a stable ID and mark it resolved / persisting / new. Without stable IDs a lead cannot distinguish a plateau (the same findings recurring — stop) from real progress. Re-reviews per ticket are capped by the [canonical iteration caps](06-convergence.md#canonical-iteration-caps).
- **Report overflow, never silent truncation.** When findings exceed a reasonable length, rank by severity (correctness first) and state explicitly that lower-severity findings were omitted for brevity — never silently drop a finding.

### Budget allocation

When budget is tight, diversify generation rather than deep-iterating a single attempt. An ablation across repair budgets found that **10 initial samples × 1 repair each** yielded 1.05× higher pass rates, while **2 samples × 10 repairs each** yielded 0.97× — worse than baseline. After 2–3 review rounds, returns diminish sharply. One round of grounded adversarial review captures most of the available value.

### Cross-model review

For high-stakes code, route the critic to a different model than the generator. GPT-4 reviewing GPT-3.5 code yielded larger gains than GPT-3.5 reviewing itself. In Claude Code, this is a one-line change in the subagent's YAML frontmatter — set `model: opus` on the critic while the generator runs on `sonnet` (or vice versa). See [Agents](03-agents.md) for model-tier selection and the `model:` field. Cross-model review is not always warranted, but it is cheap to configure when it is.

The `code-reviewer` and `security-auditor` agents in this repo embody this pattern: read-only tool scope, explicit anti-sycophancy framing, and correctness-first report ordering. They are the reference implementation for the rules in this section.

## Design Review Gate

The cheapest place to catch architecture mistakes is before code exists. A design review agent validates the implementation brief (see [Orchestrator](05-orchestrator.md)) against:

1. **Domain model alignment** — do the proposed models match the cross-platform contract?
2. **Layer placement** — are responsibilities in the right architecture layer?
3. **UI guidelines** — do proposed screens follow the design system?
4. **Component reuse** — are existing components being leveraged, not duplicated?
5. **Repository interface** — does the data layer contract match the API spec?
6. **Test scenario coverage** — are the proposed test scenarios sufficient for the acceptance criteria?

**Verdict types:** APPROVED, NEEDS-REVISION (with specific feedback), or conditional APPROVED (minor notes, proceed anyway). Limit to one revision round — do not let design review become a bottleneck.

**Delegate design review to a subagent.** Running it inline in the orchestrator's context consumes ~2,000 tokens per story that the orchestrator cannot shed. After a few stories, context collapse sets in and the orchestrator loses track of its checkpoint.

## Spec Quality Gate

Before implementation begins, validate the specification against six common underspecification gaps. Specification problems are the largest category of multi-agent failures ([Failure Patterns](12-run-history.md#error-taxonomy)).

Verify the spec addresses:

1. **Data model/schema definitions** — leading cause of brownfield integration failures
2. **Acceptance criteria with runnable test commands** — not prose descriptions, actual commands
3. **Architectural constraints and repo idioms** — existing patterns the agent must follow
4. **Security/authentication requirements** — auth flows, token handling, permission boundaries
5. **Explicit negative requirements** — scope boundaries stating what not to touch or change
6. **Error handling specifications** — failure modes, retry policies, user-facing error states

A spec that leaves any of the six open is underspecified. Reject it back to the planning phase. Catching a missing schema definition before implementation is orders of magnitude cheaper than debugging integration failures after code is written.

## Verification Gate

A review verdict that rests on a test, oracle, or live/E2E check is only as good as that check's ability to discriminate. Two requirements keep a verdict honest:

1. **Oracle discrimination.** Trust a passing check only if it was demonstrated to **fail on the known-bad state** first. A check green on both the buggy and the fixed build — or keyed on the same instrumentation as the fix hypothesis — is non-discriminating and proves nothing. For user-visible symptoms, gate on the observed symptom, not on unit/instrumentation greens; state which symptom paths were exercised and which were not.
2. **Ground-truth pre-flight before a NO-GO.** Do not block on a live/integration failure until you confirm the artifact under test is the current build, the client targets the intended host/env, and the process/infra is healthy — a live failure that looks like a code defect is often an env/build artifact. An unconfirmed live failure is *inconclusive*, not a NO-GO.

These guard the two verification failure modes — false-green (a wrong fix that passes every check) and false-blocker (a NO-GO that stalls authorized work). See [12-run-history.md](12-run-history.md) for the failure-mode detail and the `review-gate` skill for the verdict template that enforces them.

## Choosing Review Scale

| Change scope | Risk | Recommended scale |
|---|---|---|
| Single feature, one platform | Low | Self-review only |
| Single feature, both platforms | Medium | Self-review + parity check |
| Multiple features or cross-cutting change | Medium-High | Mini review (5-7 agents) |
| Milestone gate, release candidate | High | Full review (20-30 agents) |
| Architecture change, schema migration | Very High | Full review + human sign-off |

**Budget matters:** A full review costs 50K-100K tokens. Self-review + parity check per story, full review per wave or milestone.

## Case Study: Review System Evolution

One cross-platform mobile project's review system evolved through three iterations:

**Initial (full review):** A 30-agent full review with 4 phases. Used for architecture validation before feature development. Produced Verdict A and Verdict B assessments. Expensive but caught systemic issues — missing error mapping, test parity gaps, localization inconsistencies.

**Refined (mini review):** Lighter 7-agent review for ongoing feature work. Dropped the parallel deep-dive phase in favor of focused platform + parity agents. Became the standard review automation.

**Optimized (self-review converge):** The 10-point checklist inside a converge loop, running inside every story implementation. In that project it caught most issues before they reached code review (the author's estimate, not a measurement). Key insight: self-review is nearly free when run inside the implementing agent's context — no new agent spawn, just a checklist pass over the code just written.
