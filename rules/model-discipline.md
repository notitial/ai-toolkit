# Model Discipline

Which model a session or subagent runs on. Context carried per turn is the main cost, and most turns are routine. Rationale and source: [doc 03](../docs/03-agents.md), Session model discipline.

## Sessions

- **Default to Sonnet.** Switch to Opus (`/model opus`) only for a named phase, say which, and switch back (`/model sonnet`) when it ends. The phases:
  - open design or architecture with trade-offs
  - a threat model or security design
  - adversarial review
  - prompt or eval tuning
  - a novel algorithm
- **Small, long-lived sessions run on Sonnet.**
- **One session per PR or task.** Start it from the checkpoint (`.archive/<ticket>/STATE.md`, or a `/handover`), not one session per workstream for days.

## Subagents

- Always pass `model` when spawning Explore or general-purpose agents: `sonnet` by default, `haiku` for mechanical reads. Without it they inherit the parent's model.
- An agent with a pinned `model:` keeps it: `code-reviewer` and `plan-reviewer` are Sonnet; `security-auditor` is Opus.
