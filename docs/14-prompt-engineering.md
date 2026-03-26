# Prompt Engineering

Prompt patterns that work in practice for AI-assisted development, distilled from real orchestration runs.

## Plan Heavy, Execute Light

Spend the majority of orchestration effort on specification before unattended execution begins. The most successful multi-agent runs allocate the bulk of their time to Phase 1 (specification) rather than Phase 2 (execution).

- Define every decision point, failure mode, and output format before the first subagent launches.
- Harness improvements alone — not model changes — have produced 36-point improvements on coding benchmarks (CORE-Bench). Better prompts beat better models.
- Treat the launch prompt as the primary deliverable of planning. If you spend 30 minutes writing the prompt and 4 hours running the pipeline, the ratio is right.

See [05-orchestrator.md](05-orchestrator.md) for the pipeline architecture these prompts support.

## The Context Handoff Prompt

A canonical document that restores full project understanding in a new session. Used when starting fresh conversations or onboarding a new agent.

**Structure:**
1. Project identity — what the app does, who it's for, tech stack
2. Current state — what's built, what's in progress, what's next
3. Architecture summary — key patterns, layer structure, data flow
4. Cross-platform contracts — shared types, error hierarchy, state machine
5. Key conventions — naming, localization, error handling, testing
6. Paths to important files — so the agent can orient itself

**Key property:** Self-contained. The agent should not need to read anything else to start working. If it needs to read 5 more files after the handoff prompt, the prompt is incomplete.

**Anti-pattern:** Including implementation details that change frequently. The handoff prompt should be stable across weeks. Volatile details (current branch, last commit, in-progress feature) go in a checkpoint or session-specific context, not the handoff.

## The Orchestrator Launch Prompt

A complete instruction document for an autonomous agent. Everything the orchestrator needs to run unattended, in one place.

**Sections:**
- **Identity:** What role this agent plays, what tools it uses
- **Pipeline:** Step-by-step procedure for processing work items
- **Failure policy:** What to do when things go wrong (retry, skip, escalate)
- **Token optimization:** How to stay within context limits
- **Checkpoint protocol:** How to read, write, and trust the checkpoint
- **Recovery protocol:** How to resume after context compaction or restart
- **Execution rules:** Command whitelist, one-at-a-time execution, no interactive prompts

**Key property:** No ambiguity. Every decision point has a specified action. "If X, do Y. If Z, do W." In a headless pipeline the orchestrator should never need to exercise judgment about _what to do_, only about _how to do it_.

**Size:** One project's orchestrator launch prompt was ~540 lines. This is on the large side but justified by the complexity of headless operation. For simpler orchestration, 100-200 lines is sufficient.

## Headless Mode Rules

For agents that run unattended (overnight orchestration, CI pipelines, background tasks):

1. **Never ask for input.** If something is unclear, make the safest decision and log the reasoning.
2. **Only run whitelisted commands.** Unknown or novel commands are skipped with an explanation.
3. **Fail gracefully.** When a task fails, log the failure, update the checkpoint, and move to the next task. Do not halt the entire pipeline for one failure (unless it's a build failure that would cascade).
4. **Cap iterations.** Every loop has a maximum. Every retry has a limit. No unbounded work.
5. **Produce machine-parsable output.** The next agent (or human) that reads your output should spend seconds, not minutes, extracting the key information.

**Why these rules:** Headless agents cannot ask "should I continue?" at 3 AM. Every decision must be pre-specified. The rules above eliminate the most common failure modes: hanging on input, running dangerous commands, infinite loops, and unreadable output.

## The Execution Policy Inline Pattern

Each agent's prompt includes its own execution policy — the whitelist and prohibitions are self-contained, not referenced from an external file.

```markdown
## Execution Policy
ALLOWED: git (read+write), project-build, project-test,
         project-lint, file read/write
PROHIBITED: web_search, curl, npm, raw build tools, command chaining (&&, ||, ;)
ONE COMMAND AT A TIME. No exceptions.
```

**Why inline:** a subagent may not load rule files, so the policy it must follow belongs in its own prompt. On one project, moving the full whitelist inline into each agent's prompt took violations from about three per run to zero. A short form (about 50 tokens of allowed categories and key prohibitions) is lighter but untested against that result; either way, enforcement of the full list belongs in `settings.json` permissions and hooks ([Permissions and Safety](10-permissions-and-safety.md#case-study-whitelist-consolidation)).

## The Structured Report Pattern

Subagents return machine-parsable reports with fixed delimiters:

```
---REPORT---
status: PASS
commit: abc1234
files: ViewModel.kt, Screen.kt, ViewModelTest.kt
build: PASS
tests: PASS (4/4)
blockers: none
---END---
```

**Rules:**
- Delimiter-based (not JSON, not YAML) — LLMs produce these more reliably than structured formats
- Fixed fields — the orchestrator knows exactly what to expect
- Max length enforced, about 500 tokens, and stated absolutely: "Your ENTIRE final response must be the report block below — no preamble, no explanation. Begin immediately with `---REPORT---`." "Keep it brief" is not enough: agents read "brief" differently.
- No prose, reasoning, or explanation outside the block
- A reviewer's report leads with its verdict (`PASS | MINOR | MAJOR | NEEDS-REVISION`), then numbered findings with file paths

**Why not JSON?** LLMs frequently produce invalid JSON (unescaped quotes, trailing commas, wrong nesting). Simple key-value with delimiters is more robust. If you need structured data, have a post-processing script parse the report — do not rely on the LLM to produce valid structured format. One project saw zero parsing failures across about 40 delimited reports.

## The Checkpoint Mandate Pattern

After every significant action, update the persistent checkpoint before proceeding:

```
Complete story → Write checkpoint → (only then) Start next story
```

**Never defer checkpoint writes.** One run that batched them lost four stories of progress when context compacted mid-wave. The checkpoint is cheap to write (one file operation) and expensive to lose (re-processing stories).

**Checkpoint before communication:** Write the checkpoint before logging to the activity report or updating external systems. If the session dies between checkpoint write and activity log, you lose a log entry but not progress. The reverse — logging before checkpointing — risks re-processing completed work.

## The Recovery on Resume Pattern

Start a resume prompt with the [recovery protocol](08-context-management.md#recovery-protocol): checkpoint first, then git, and the checkpoint wins over memory.

## The Human-Task Skip Pattern

Some work items require human input (design decisions, external approvals, manual testing). Agents should detect and skip these:

```
1. Read work item
2. Check labels/tags for "human-task" or "needs-input"
3. If tagged: log "Skipped [ID] — requires human input" → continue
4. If not tagged: proceed with implementation
```

**Why not just fail?** A failed task enters the retry queue, consumes retry budget, and clutters the failure log. A skipped task is cleanly excluded — it was never attempted, does not count as a failure, and does not consume resources.

## The Read Before Doing Instruction

Agents should read context files before starting work:

> "Before implementing anything, read: CLAUDE.md, then the relevant rules for the files you'll touch, then the existing code in the feature directory."

**Why explicit:** Without this instruction, agents start writing code based on their training data rather than the project's actual conventions. The result: correct code that does not match the project's patterns, requiring rework.

**Order matters:** CLAUDE.md first (project identity), then rules (conventions), then existing code (patterns). This mirrors how a human developer would onboard — understand the project, learn the rules, then look at examples.

## Anti-Patterns

### Asking for confirmation in headless mode
"Should I proceed?" at 3 AM hangs the pipeline. Pre-specify the answer to every question, or default to the safe option and log it.

### Reading docs the agent does not need
The orchestrator reading a 500-line architecture doc "for context" wastes tokens. If the orchestrator needs architecture knowledge, the subagent should include relevant bits in its report.

### Long task prompts when an ID suffices
Passing the full story description to a subagent when the subagent can read it from the ticket system. "Implement TASK-42" is 3 tokens. The full story text is 200+ tokens. If the subagent has access to the ticket system, pass the ID.

### Instruction by implication
"Follow best practices" means nothing. "Map HTTP 401 to AppError.api.unauthorized" is actionable. Every instruction should be specific enough that two different agents would do the same thing.

### Specifying tone in technical prompts
"Be enthusiastic and helpful!" wastes tokens and changes nothing about output quality. Save the personality instructions for user-facing agents — implementation agents need precision, not personality.

