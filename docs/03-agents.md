# Agents

Subagent architecture: how to decompose complex tasks into specialized roles with empirically grounded coordination patterns.

Agents are reusable role definitions that an AI coding tool can assume when spawned as a subagent. Each agent carries its own system prompt, tool permissions, and behavioral constraints. The goal is the same as human team composition: give each role a clear mandate, the minimum tools it needs, and nothing more.

## Why Separate Coordination from Implementation

The most important architectural decision is the coordinator/subagent split. A coordinator (orchestrator) decides what to do and in what order. Subagents do the actual work. Three factors drive this separation:

1. **Context efficiency.** A coordinator that also reads code, runs builds, and writes features exhausts its context window on 3-4 tasks. A thin coordinator that only reads progress checkpoints and dispatches work managed about 8-10 tasks in the same window in measured runs, with 12-15 the target once checkpoints and reports are trimmed (see [Failure Patterns](15-failure-patterns.md#case-study-lessons-from-four-autonomous-runs)).
2. **Blast radius.** A subagent that misunderstands a task can only damage its own scope. A monolithic agent that coordinates and implements can corrupt progress tracking, skip tasks, or commit to the wrong branch.
3. **Parallelism.** Independent subagents (e.g., two platform implementers) can run in parallel. A single agent doing both must serialize.

### Hub-and-Spoke over Peer Networks

Empirical data strongly favors centralized coordination over peer-to-peer agent networks:

- Coding agents that cooperate on a shared task succeed about 30% less often than one agent doing both parts (CooperBench, arXiv:2601.13295).
- Centralized coordination contained error amplification to 4.4x, against 17.2x for independent agents and 7.8x for decentralized peer networks (Kim et al., "Towards a Science of Scaling Agent Systems", Google Research, arXiv:2512.08296).
- Anthropic's multi-agent research system, a lead agent that spins up 3-5 subagents in parallel, outperformed a single agent by 90.2% on Anthropic's internal research eval ("How we built our multi-agent research system", Anthropic engineering blog, June 2025, https://www.anthropic.com/engineering/built-multi-agent-research-system).

The thin coordinator principle: the orchestrator should spend roughly 300 tokens per task on coordination overhead — reading the checkpoint, dispatching the task, recording the result. It never reads architecture docs, API specs, or source code directly. All of that is the subagent's job.

## Agent Definition Anatomy

An agent definition is a markdown file with frontmatter metadata and a system prompt body. The exact format varies by tool, but the core fields are consistent.

**Cursor format** (`.cursor/agents/*.md`):

```yaml
---
name: platform-a
description: "Platform A specialist for apps/platform-a/."
---
```

Cursor agents define behavior inline but cannot specify model or tool restrictions in frontmatter. Tool scoping is enforced through prose instructions in the body (the execution policy pattern, covered below).

**Claude Code format** (`.claude/agents/*.md`):

```yaml
---
name: platform-a
description: "Platform A specialist for apps/platform-a/."
tools: Read, Edit, Write, Glob, Grep, Bash
model: opus
memory: project
---
```

Claude Code applies the frontmatter at runtime: tool scoping, model and effort are enforced, not left to instruction-following. Only `name` and `description` are required; the rest inherit from the session.

| Field | Purpose |
|-------|---------|
| `name` | Unique id, e.g. `code-reviewer` |
| `description` | When Claude should delegate to this agent |
| `tools` | Allowlisted tools; all tools when omitted |
| `model` | `sonnet`, `opus`, `haiku`, a full model id, or `inherit` |
| `effort` | Thinking effort while the agent runs; overrides the session's |

The other fields (`disallowedTools`, `permissionMode`, `skills`, `hooks`, `memory`, `isolation` and more) are in the [Claude Code subagents docs](https://code.claude.com/docs/en/sub-agents).

Regardless of tool, every agent definition should contain:

- **Identity and scope** — what the agent is responsible for, what repo or directory it operates in
- **Key context** — architecture patterns, stack details, and file references it needs before starting work
- **Execution policy** — what commands and tools are allowed and prohibited
- **Report format** — what the agent returns to the coordinator when done

## Agent Taxonomy

Six roles represent the natural division of labor in multi-agent systems. Not every project needs all six, but they cover the spectrum from coordination to implementation to validation.

### Coordinator

Delegates work, tracks progress, never implements. Reads a backlog or task list, dispatches subagents, records results in a checkpoint file, and moves to the next item. The coordinator's context must be protected above all else — it is the only agent that carries state across the full run.

Key constraint: no build tools, no code reading, no implementation. If a coordinator starts reading source files "to understand the problem better," context bloat is inevitable.

### Preparer

Reads requirements and produces a shared artifact (typically an Implementation Brief) that downstream agents execute against. The preparer reads the task or ticket, resolves shared resources, checks dependencies, and outputs a structured document. This prevents every downstream agent from independently re-reading the same requirements — a major context savings.

The preparer can write files (shared config, resource keys) but does not write platform code or run platform builds.

### Implementer

Full code generation within a specific domain. An implementer receives the preparer's brief, writes code, runs builds and tests, self-reviews, and commits. It has the broadest tool access of any role: file read/write, shell commands, build tools, test runners, linters.

In cross-platform projects, each platform gets its own implementer agent. They run in parallel against the same brief, producing platform-native code that satisfies the same acceptance criteria.

### Reviewer

Read-only validation gate. Reviewers check work against criteria and output a structured verdict (APPROVED, NEEDS-REVISION, PASS, MAJOR, MINOR). They never modify files, run builds, or create commits.

Two reviewer subtypes appear in practice:
- **Design reviewer** — validates an implementation brief *before* code is written (catches architecture mistakes early)
- **Cross-platform reviewer** — validates two implementations *after* code is written (catches platform divergence late)

### Documenter

Updates documentation after implementation. Reads the current docs and the recently changed code, then makes minimal edits to keep docs in sync. The documenter has write access to doc files but does not touch source code.

### Architect

Read-only design analysis. Produces feature designs, validates domain models, and ensures cross-cutting consistency. Outputs structured design documents (user flows, domain changes, file placement, test scenarios) that preparers and implementers consume. Similar to a reviewer but operates at design time rather than review time.

## Tool Scoping Per Role

The principle: each agent gets the minimum tool access required for its role. Over-provisioning tools invites misuse — an agent with build tools will run builds even when it should not, consuming time and context.

| Role | File Read | File Write | Git Read | Git Write | Build/Test/Lint | Shell |
|------|-----------|------------|----------|-----------|-----------------|-------|
| Coordinator | Yes | Yes (checkpoint only) | Yes | Yes (status, branch) | No | Limited |
| Preparer | Yes | Yes (shared resources) | Yes | Yes (resource commits) | No | Limited |
| Implementer | Yes | Yes | Yes | Yes | Yes | Yes |
| Reviewer | Yes | No | Yes (read-only) | No | No | No |
| Documenter | Yes | Yes (docs only) | Yes | Yes | No | Limited |
| Architect | Yes | No | Yes (read-only) | No | No | No |

In Cursor, tool scoping is advisory — write "do NOT use Write, Edit" in the execution policy and rely on instruction-following. In Claude Code, tool scoping is enforced in the frontmatter `tools` field. The Claude Code approach is more reliable because the runtime itself prevents the agent from calling unlisted tools.

## Model Selection Strategy

Not every agent needs the most capable (and most expensive) model. Match model tier to the reasoning complexity of the role.

- **Sonnet-class** for orchestration and implementation — best balance of capability and cost for general coding tasks.
- **Haiku-class** for lightweight tasks: verification, preparation, noise filtering — near-Sonnet quality at roughly one-third the cost.
- **Opus-class** for review and architecture — catches architectural drift, async bugs, and cross-cutting issues that faster models miss. Roughly 2x the cost of mid-tier.

| Role | Recommended Tier | Rationale |
|------|-----------------|-----------|
| Coordinator | Mid (Sonnet) | Dispatch and status tracking; Opus unnecessary if task graph is well-structured |
| Preparer | Fast (Haiku) | Reads a ticket, fills a template — largely mechanical |
| Implementer | Mid (Sonnet) | Code generation requires architecture understanding and pattern matching |
| Reviewer | Capable (Opus) | Logic bugs, architecture drift, and spec compliance require deep reasoning |
| Documenter | Mid (Sonnet) | Writing quality matters but reasoning demands are moderate |
| Architect | Capable (Opus) | Cross-cutting design decisions require the strongest reasoning |

**Escalation pattern:** Start at the mid tier. Upgrade to the next tier after 2 consecutive failures on the same task. This keeps cost low for straightforward work while ensuring difficult tasks get the reasoning power they need.

**Exception: a review gate pins its tier.** Escalate-on-failure suits production roles, where a failed retry is cheap and visible. A gate's misses are silent, so pin it from the start: the capable tier when it is the only reviewer of a change, the mid tier when a second, independent review covers every change ([ADR 0008](adr/0008-global-agent-roster.md)). Plan review can start mid-tier: its misses surface while there is still time to correct course.

Not all tools support per-agent model selection in frontmatter. When unavailable, apply the escalation pattern manually — start mid-tier and upgrade on repeated failure.

### Session model discipline

The same tiering applies to whole sessions; the always-on rule is [`rules/model-discipline.md`](../rules/model-discipline.md).

- **Default to the mid tier; take the capable tier for a named phase, then switch back.** The phases are open design with trade-offs, a threat model or security design, adversarial review, prompt or eval tuning, and a novel algorithm. They are short, usually at the start of a ticket.
- **Small, long-lived sessions (standby, relay) run mid or fast, and stay small.** Cache reads dominate token use, so context carried per turn is the bigger lever: one session per PR or task, started from a checkpoint, and a fresh session for an occasional question.
- **Built-in subagents inherit the parent's model.** Explore and general-purpose run on the parent's tier unless the spawn passes `model`, so pass it at every spawn, mid tier by default.

**Case study.** Over one week on one machine, 70–90% of the turns in the largest Opus sessions were routine work Sonnet handles. Opus earned its keep only in design, threat-model and novel-algorithm phases, and subagents that inherited Opus added cost for nothing.

### Effort and context

Cost and quality have three dials; in order of leverage: **context**, then **model** ([`rules/model-discipline.md`](../rules/model-discipline.md)), then **effort**.

**Effort** sets how much the model thinks per turn (`--effort`, `/effort`, `CLAUDE_CODE_EFFORT_LEVEL` or the `effortLevel` setting).

| Level | Use for |
|---|---|
| `low` | Mechanical, well-specified work with one obvious path: formatting, a scripted edit, a bounded lookup |
| `medium` | Ordinary implementation with light judgment |
| `high` | Non-trivial implementation, tricky bugs, work that needs real tracing |
| `xhigh` | Hard reasoning: subtle concurrency, security-sensitive logic, deep design, adversarial review. Slow, so worth it only when the problem's hardness demands it |
| `max` | The hardest single problems, where any latency is acceptable for depth |

- **Pass effort explicitly for any spawned or unattended session.** An unset flag falls through to the operator's own settings, then to the model's default, and those differ by model and by surface. The depth then shifts with every model change or machine.
- **Check the pair.** Not every model has every level. A level the model lacks runs at the highest supported level below it, silently, and a model the docs do not list (older Haiku, 4.5) has no effort setting. Checked against Claude Code's [model configuration docs](https://code.claude.com/docs/en/model-config) on 2026-11-08; re-check at each model release:

| Model | Effort levels |
|---|---|
| Fable 5.1; Opus 5.5, 4.8, 4.7; Sonnet 5.5; Haiku 5.5 | `low`, `medium`, `high`, `xhigh`, `max` |
| Opus 4.6, Sonnet 4.6 | `low`, `medium`, `high`, `max` (no `xhigh`) |

**Context is usually the biggest lever.** Effort deepens thinking per turn; context size sets how long each turn takes and how much the session burns. A lean context at `high` beats a bloated context at `xhigh` on both cost and wall-clock.

- Name the files in play instead of "figure out X across the repo", and sequence probe, then map, then implement: a cheap reconnaissance pass that reports where the work is keeps the implementer's context small.
- Delegate bulk reading to subagents so the main window keeps conclusions, not file dumps, and compact or hand off at task boundaries, not at the token ceiling ([13-orchestrator-context-discipline.md](13-orchestrator-context-discipline.md)).

| Job | Model | Effort | Context note |
|---|---|---|---|
| Lookup, mechanical or scripted edit | fast or mid tier | `low` | Point at the exact source or files |
| Ordinary feature, refactor, tricky bug | mid tier | `medium`–`high` | Probe first if broad; narrow to the failing path |
| Deep design, adversarial review | capable tier | `xhigh` | Keep context lean |
| Broad research | mid tier | `medium` | Delegate to subagents; never `xhigh` over a huge context |

**Case study: context beat the tier.** A session on a capable-tier model at `xhigh` ran over a roughly 1.6M-token context. Each turn took 30–40 minutes, it hit the 90-minute wall and wrote no lines. The re-run kept the same model and effort but went context-lean (probe, map, implement over a narrow file set) and made 65 tool calls in 11 minutes. Only context size changed.

**Case study: the unattended default.** Unattended sessions that pinned no model or effort inherited the operator's interactive settings. In one week Opus took 67% of their cost, about $117 of $174. A three-pair A/B on paired briefs compared Sonnet 5.5 at `medium` with Opus 5.5 at the operator's default effort. Cost per accepted job was about $0.28 against $1.07, a ratio of 0.26; all six jobs were accepted. The one quality gap was depth: on a date-library test task Opus wrote 102 tests including daylight-saving cases, Sonnet wrote 36 and said that area was untested. The brief had not asked for it. The default became Sonnet at `medium`, with a higher model or effort per job, or the coverage named in the brief.

## The Execution Policy Pattern

Subagents may not have access to external rule files, project-level instructions, or shared config. A subagent spawned by the Task tool (Cursor) or Agent tool (Claude Code) receives its agent definition and the task prompt — nothing else is guaranteed. This means safety-critical constraints must be **inline** in each agent definition.

The execution policy is a structured block that every agent definition carries:

```markdown
## Execution Policy

### Allowed Shell Commands (ONE AT A TIME)
- **Git:** git status, git log, git diff, git add, git commit
- **Build:** platform-build, platform-test, platform-lint
- **File tools:** Read, Write, Edit, Glob, Grep

### Prohibited — do not use under any circumstances
- **Tools:** web_search, browser_preview, fetch
- **Commands:** curl, wget, npx, npm
- **Chaining:** NEVER use &&, ||, or ; — one shell command per invocation

### Rules
1. If a task needs an unlisted tool or command, SKIP and report why.
2. All information needed is in the codebase. Do not search the web.
```

Three design choices are worth noting:

1. **Whitelist, not blacklist.** List what is allowed, then explicitly prohibit common escape hatches. Agents are creative about finding alternative tools when blocked.
2. **No command chaining.** The `&&`, `||`, and `;` prohibition prevents agents from combining commands into opaque one-liners that are hard to audit and easy to get wrong.
3. **Fail-safe default.** "If a task needs an unlisted tool, SKIP and report why" prevents agents from improvising with unauthorized tools.

Keep this block short: the allowed categories and the key prohibitions. Enforcement of the full list lives in `settings.json` permissions (allow and deny) and hooks, which bind every subagent; a rule file holding the list is reference only. See [Permissions and Safety](05-permissions-and-safety.md#case-study-whitelist-consolidation).

## The Report Format Pattern

When a subagent finishes, it reports back to the coordinator. Unstructured reports (free-form prose about what was done) waste coordinator context tokens and are hard to parse programmatically. Structured reports solve both problems.

Every agent definition ends with a fixed, short report format: status, commit, files, build, tests and blockers for an implementer; a verdict and numbered findings for a reviewer. Cap it at about 500 tokens, and the coordinator spends under 100 tokens per handoff. The format and its prompt wording: [The Structured Report Pattern](14-prompt-engineering.md#the-structured-report-pattern).

## Consolidation: Many Simple vs Few Rich Agents

Agent hierarchies naturally evolve from many narrow roles toward fewer consolidated ones as tooling matures. Understanding when to split and when to merge prevents both over-engineering and under-separation.

**Example: 8 narrow agents consolidated to 4:**

| Original Agent | Role | Why It Existed Separately |
|----------------|------|--------------------------|
| orchestrator | Coordinator | Needed unique checkpoint/recovery logic |
| task-preparer | Preparer | Centralized resource resolution and brief generation |
| design-reviewer | Reviewer | Pre-implementation architecture validation |
| platform-a-impl | Implementer | Platform-specific stack knowledge |
| platform-b-impl | Implementer | Platform-specific stack knowledge |
| cross-platform-reviewer | Reviewer | Post-implementation cross-platform check |
| architecture | Architect | Cross-cutting design, read-only |
| docs | Documenter | Documentation sync after implementation |

**After consolidation to 4 agents:**

| Agent | Absorbed Roles | Why It Merged |
|-------|---------------|---------------|
| platform-a-impl | Implementer + its build/test cycle | No change — implementers stay separate |
| platform-b-impl | Implementer + its build/test cycle | No change — implementers stay separate |
| architecture | Architect + design-reviewer | Both are read-only design analysis with the same tool set |
| docs | Documenter (unchanged) | Still a distinct write scope |

The orchestrator, task-preparer, and cross-platform-reviewer roles were absorbed into the coordinator workflow itself (orchestrator instructions in the project instructions file) or into skills/commands rather than standalone agents.

**When to split:** Split when agents need different tool access (reviewer vs implementer), different models (Haiku vs Opus), or operate on different file scopes. Split when combining roles would create conflicting instructions ("write code" vs "never write code").

**When to merge:** Merge when two agents have the same tool access, the same model requirement, and overlapping domain knowledge. The architecture agent and design reviewer both need read-only file access, both need Opus-tier reasoning, and both validate against the same architecture docs.

## Case Study: Cross-Platform Mobile App

A cross-platform mobile app (two native platforms) with a polyrepo structure: a shared monorepo for specs, docs, and design tokens, plus independent platform repos. The agent hierarchy was designed around this structure.

**Delegation flow for a single task:**

```
Orchestrator
  |-- reads checkpoint, picks next task from backlog
  |-- spawns Task Preparer
  |     |-- reads project management ticket via MCP
  |     |-- adds shared resource keys to monorepo
  |     |-- produces Implementation Brief
  |     \-- returns Brief to orchestrator
  |-- spawns Design Reviewer (receives Brief)
  |     |-- validates against architecture docs
  |     \-- returns APPROVED or NEEDS-REVISION
  |-- spawns Platform A + Platform B in parallel (both receive Brief)
  |     |-- each: implement, build, test, lint, self-review, commit
  |     \-- each: returns structured report
  |-- spawns Cross-Platform Reviewer (receives both reports + file lists)
  |     \-- returns PASS, MINOR, or MAJOR
  \-- updates checkpoint, moves to next task
```

**Parallel execution:** The two platform implementers run simultaneously because they operate on independent repos with no shared mutable state. The brief is their shared input; their commits are independent outputs. This cuts per-task wall-clock time roughly in half compared to serial execution.

**Context budget:** With the thin coordinator pattern and checkpointing, the orchestrator managed about 8-10 tasks per session in measured runs; checkpoint compaction and structured reports put the target at 12-15.

**Key lessons from iteration:**

- The preparer agent was the single highest-ROI addition. By centralizing requirement reading and brief generation, it eliminated redundant API calls and ensured both platforms worked from identical specs.
- A short inline policy in each of the 8 agent files proved necessary: subagents spawned via the Task tool did not reliably load parent-level rules.
- The design reviewer caught domain model mismatches that would have required two separate fix rounds — roughly 3,000 tokens of rework per incident avoided.
- Report format enforcement ("under 500 tokens") was added after early runs where implementer agents returned 2,000-token narrative reports that bloated the coordinator's context.
