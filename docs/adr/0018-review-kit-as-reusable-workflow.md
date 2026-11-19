# 18. The Review Kit as a Reusable Workflow

**Status:** accepted
**Date:** 2026-11-19

## Context

The review kit ([ADR 0013](0013-app-owned-pr-review.md)) ships as byte-identical copies: a repo copies the workflow
and the command and changes a few listed lines. That choice causes most of the kit's upkeep:
- A change lands twice here (canonical and installed copy) and again in every repo that installed it, which are
  then on different versions.
- The README keeps a SHA table and a table of replacement points keyed to line numbers that move with every edit.
- The Python is embedded in YAML, because a single vendored file cannot carry modules.
- An action bump touches several places, so Dependabot's own PR fails the equality test and a person supersedes it.
- The workflow's header repeats the README, since the copy is the only documentation in the target repo.

## Options Considered

- **Keep copies and trim the code.** Removes lines but not the copies, the tables or the per-repo drift. Every later
  change still pays once here and once per repo.
- **Go back to the Claude plugin posting.** Rejected in ADR 0013: it puts a posting tool in the model's hands.
- **A reusable workflow (`on: workflow_call`) that each repo calls from a thin caller: chosen.** The org already shares
  its PR-title check this way.

## Decision

The kit is `.github/workflows/claude-review-kit.yml`, a reusable workflow. A repo's `.github/workflows/claude-review.yml`
is a caller of about 30 lines that owns three things:
- **The triggers**, `pull_request` and `issue_comment`, which the kit's `if:` conditions assume.
- **The permission ceiling**, on its one job: `contents: write`, `pull-requests: write`, `issues: read`. A called job
  can only narrow it, never widen it. Every kit job declares its own `permissions:` (`appcheck` none, `preflight` and
  `review` read-only, `publish` `contents: write` and `pull-requests: write`), so each job holds exactly what it
  held as a vendored copy. A test fails a kit job that declares none, since it would inherit the whole ceiling.
- **The credentials**, mapped by name: the App key, and the Claude API key and OAuth token. Never `secrets: inherit`.
  The kit declares all three optional, so a missing one still reaches the kit's own "Missing: secret ..." check.
  The `CLAUDE_REVIEW_*` variables stay repository variables: a called workflow reads the caller's `vars`.

The kit's inputs are `runs-on` (a JSON array, for `preflight` and `review`, default `["ubuntu-latest"]`),
`changes-event` and `approve-event` (the two verdict events, defaults as before). They replace the lines a repo used
to edit by hand. The key jobs still read `CLAUDE_REVIEW_KEY_RUNS_ON`.

**How a repo calls it.** This repo calls its own copy by a local path (`uses: ./.github/workflows/claude-review-kit.yml`),
which GitHub resolves to the caller's own commit. A SHA of a file that is part of the same PR cannot exist yet, and the
local path keeps what a PR that edits the review has always done: it is reviewed by its own edited copy. Every other
repo pins the kit by full commit SHA (`uses: <owner>/ai-toolkit/.github/workflows/claude-review-kit.yml@<sha>`),
so upgrading is one line.

**Migration.** The vendored workflow, `tools/claude-review/claude-review.yml`, is frozen at v3.4, with its SHA row,
for repos that have not moved; it is deleted once none uses it. This record covers the first step: the kit moves,
its behaviour does not change, and the scripts stay inline and the command stays installed in each repo. Later steps
move the scripts into files run from a checkout of the kit at the pinned SHA, feed the command to the review from the
kit, and simplify what `publish` posts. Each is its own PR and amends this record where it changes a rule.

## Consequences

- A kit change is made once; a repo picks it up by changing a SHA. The kit's diff is reviewed in the toolkit, not in
  each repo's upgrade PR.
- The permission ceiling lives in the caller, so a caller that grants less than the kit's jobs ask for fails at
  start-up ("requesting ... is only allowed ..."), and a caller that grants more gives a job nothing extra.
- A same-repo PR can still edit the caller and run any code with the keys. This is the residual ADR 0013 already
  accepts; the `@sha` is now what such a PR would edit.
- A repo's required-check names change: a called job reports as `<caller job id> / <job name>`.
- ADR 0015's byte-identical-copies model still holds for the build kit; the review kit no longer follows it.
- The verdict inputs are checked in `publish` (two accepted values each), since a called workflow has no choice type.
- Fork and Dependabot `pull_request` runs: GitHub documents that a fork's write permissions are changed to read after
  the workflow's own `permissions:` are applied, and that a Dependabot run's token is read-only by default and the
  `permissions:` key raises it. Neither is documented as a start-up failure, which comes from a called job asking
  for more than its caller grants. The kit still skips both in `preflight`.
- Unverified until a live run: that the three credentials reach the called workflow (GitHub documents that `vars` come
  from the caller's repository); whether a called job that asks for write passes start-up in a fork run, where the
  caller's write is adjusted down (the docs do not say which level the check sees); and that Dependabot proposes bumps
  for a SHA-pinned reusable workflow.
