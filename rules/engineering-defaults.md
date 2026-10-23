# Engineering Defaults

Default quality bar for all code changes: change discipline, sourcing values, and runtime robustness.

## Minimal Changes
Make the smallest change that fully solves the task. Touch the fewest files needed. Avoid unrelated formatting, renames, or refactors. Reuse existing helpers and components. Keep interfaces stable unless breaking changes are explicitly required.

## No Hardcoding
Never hardcode values to match expected output. Trace the real source of truth (data sources, configuration, APIs, databases, environment variables, constants). Hardcoding is only acceptable when explicitly requested or as a temporary diagnostic step removed before final output.

## Respect Existing Patterns
Follow the repository's architecture and style. Understand existing patterns first and build consistently upon them. Reuse existing components from shared modules.

## Breaking Changes
Avoid breaking changes unless necessary. If a breaking change is required:
- Document it clearly
- Provide migration steps
- Prefer backwards-compatible shims when feasible

## Performance
Consider performance implications for loops, database queries, and data structures. Flag potential N+1 queries, expensive operations in hot paths, or unbounded growth.

## Error Handling
Handle error paths explicitly (network failures, missing data, invalid inputs, empty states). Prefer explicit behavior over silent failure. Keep user-facing errors clear and non-sensitive.

## Testing
Write tests for new functionality when a test suite exists. Maintain or improve existing test coverage. Do not remove or weaken existing tests without explicit approval. **Verify in proportion:** run the smallest check that discriminates the question, not the most — over-verification (another check, round, or reviewer on a finding already understood) is a failure mode of equal standing to under-verification.

## Dependencies
Avoid adding dependencies unless there is a clear benefit. Prefer built-in libraries and existing dependencies. If adding a dependency is necessary, choose a maintained, widely used option and document why it's needed.
