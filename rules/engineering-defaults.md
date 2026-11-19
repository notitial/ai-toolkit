# Engineering Defaults

Default quality bar for all code changes: change discipline, sourcing values, and runtime robustness.

## Minimal Changes
Minimal means the least code left to maintain and a tight task scope, not the smallest diff, and never at the cost of clarity, tests or input validation. Prefer the change that removes lines over the one that adds them; for a fix, see `rules/workflow.md`, Fixing a Failure. Stay inside the task: no unrelated formatting, renames or refactors. A plan or PR says what it deletes and its net lines.
- Reuse before adding: look in the shared module first; a difference is data or an option on the shared piece, never a copy.
- Build a piece only when something in scope calls it: no option, seam, flag or mode for a later step, and one path where a branch per mode would do the same job.
- An optional add-on (never a guard or validation) fails soft: when it cannot apply, it warns and the core path still works.

## No Hardcoding
Never hardcode values to match expected output. Trace the real source of truth (data sources, configuration, APIs, databases, environment variables, constants). Hardcoding is only acceptable when explicitly requested or as a temporary diagnostic step removed before final output.

## Respect Existing Patterns
Follow the repository's architecture and style. Understand existing patterns first and build consistently upon them.

## Breaking Changes
Avoid breaking changes unless explicitly required. When one is, document it, give migration steps, and prefer a backwards-compatible shim when feasible.

## Performance
Consider performance implications for loops, database queries, and data structures. Flag potential N+1 queries, expensive operations in hot paths, or unbounded growth.

## Error Handling
Handle error paths explicitly (network failures, missing data, invalid inputs, empty states). Prefer explicit behavior over silent failure. Keep user-facing errors clear and non-sensitive.

## Testing
Write tests for new functionality when a test suite exists. Maintain or improve existing test coverage. Do not remove or weaken existing tests without explicit approval. **Verify in proportion:** run the smallest check that discriminates the question, not the most — over-verification (another check, round, or reviewer on a finding already understood) is a failure mode of equal standing to under-verification.

## Proportionate Hardening
Weigh the realistic setting before adding a guard or another fix round. Drop edge cases and attackers that cannot occur where the code runs (a bootstrap step that runs once on a fresh machine before any agent exists needs no defence against a hostile agent). Prefer the simple guard: layered fix rounds make code dense and hard for a person to follow. Before briefing a fix for an obscure finding, ask whether a human designer would decide to handle it, and say so when you recommend not fixing it. This never relaxes input validation or the other rules in `rules/security.md`, and the risk topics in `rules/workflow.md` still go to the user.

## Dependencies
Avoid adding dependencies unless there is a clear benefit. Prefer built-in libraries and existing dependencies. If adding a dependency is necessary, choose a maintained, widely used option and document why it's needed.
