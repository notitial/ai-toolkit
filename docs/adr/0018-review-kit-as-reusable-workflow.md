# 18. The Review Kit as a Reusable Workflow

**Status:** accepted
**Date:** 2026-11-19 · **Amended:** 2026-11-20 (callers use `@main`)

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
repo calls the kit's main (`uses: <owner>/ai-toolkit/.github/workflows/claude-review-kit.yml@main`), so a kit change
reaches it when it merges (amended 2026-11-20, below; callers pinned a full commit SHA before).

**Scripts.** The kit's Python is `collect.py` and `publish.py` in `tools/claude-review/`. `review` (every run) and
`publish` check the kit out into `.claude-review-kit/` (sparse, only the files they use, no credentials kept) at
`job.workflow_repository` and `job.workflow_sha`, and run the script from there with `python3 -I`. In GitHub's `job`
context those name the repository and commit of the workflow file that defines the job, so inside a called workflow
they name the kit, not the caller. The PR checkout step is never a script source. The checkout lives under the
workspace because `actions/checkout` cannot place a repository outside it; `review` takes it after the PR checkout,
whose clean-up would remove it. A step in `review` fails the run if the PR itself holds that folder (a symlink could
aim the checkout's clean-up elsewhere), and an empty `job.workflow_sha` falls back to a ref that fails rather than to
the kit's default branch.

**A SHA pin is not needed for this.** A local `./` call takes the kit "from the same commit as the caller", so the
scripts come from the commit the inline code came from. On `pull_request` that is the PR's merge commit: a PR that
edits a script runs its own edit, as it ran its own inline code, and as editing the caller already allows (the
residual below). On `issue_comment`, the event a person other than the author can trigger, GitHub runs the default
branch's caller, so the scripts are main's. A `uses:` SHA would not change who can edit the scripts a PR runs,
since a same-repo PR can edit that line too, and fork and Dependabot runs get no secrets (and fork PRs never reach
`publish`). For a caller in another repo, `job.workflow_sha` is the commit of the kit's main the run resolved when it
started; the scripts use it rather than `main`, so a merge during a run cannot give it scripts from a later commit.

**Migration.** The vendored workflow, `tools/claude-review/claude-review.yml`, is frozen at v3.4, with its SHA row,
for repos that have not moved; it is deleted once none uses it. This record covers the first step: the kit moves,
its behaviour does not change, and the command stays installed in each repo. The second step moved the scripts into
files (above) with no change to them. The third step feeds the command to the review from the kit's checkout: `review`
checks it out with `collect.py` on every run, the prompt tells Claude to follow that file (the action restores
`.claude/` from the default branch, so a copy placed there would not survive), and the installed copy and the schema
copy inside it are gone (`--json-schema` gives the shape). The command's trust source becomes the kit's commit
instead of each repo's default branch; for this repo's local call, a `pull_request` run uses the PR's own command, the
same as its scripts. A fourth step runs the Claude Code CLI directly, not through `claude-code-action`
(2026-11-19; what the review does and posts is unchanged, except that the root `CLAUDE.md` is now the PR's copy, below). The CLI is pinned in the kit by `reviewer/package.json` and its
lockfile; the session starts in a copy of the kit's `reviewer/` folder, taken from the same kit commit, and the
PR's checkout is only readable data (read allow rules, not `--add-dir`: an added folder would contribute its
`.claude/agents` and skills). The command's trust source is now one rule: every piece of configuration comes from the
kit, and nothing the PR or the calling repo holds can configure its reviewer, its root `CLAUDE.md` included (it is read
as orientation, and is not a rule source when the PR changes it). Claude's environment holds no GitHub token. The PR is checked out by the head commit `preflight` reads from the API (the event's own on a PR event), not by the moving `refs/pull/<N>/head`, so a push after a comment request cannot swap the code under the secrets. Later steps simplify what
`publish` posts. Each is its own PR and amends this record where it changes a rule.

## Consequences

- A kit change is made once and reaches every caller when it merges. The kit's diff is reviewed in the toolkit, not
  in each repo.
- The permission ceiling lives in the caller, so a caller that grants less than the kit's jobs ask for fails at
  start-up ("requesting ... is only allowed ..."), and a caller that grants more gives a job nothing extra.
- A same-repo PR can still edit the caller and run any code with the keys. This is the residual ADR 0013 already
  accepts; the `uses:` line is now what such a PR would edit.
- Amended 2026-11-20: callers use `@main`, not a commit SHA. Why: a SHA pin left one line to bump in every repo after
  each kit change, and repos drifted onto different versions. Cost: a bad kit merge reaches every caller at once. The
  guard is the kit PR itself: in this repo its `pull_request` run reviews it with its own edited copy, and CI runs the
  kit's tests, before it merges. A comment run in this repo uses main's workflow, as before. Rollback: revert the kit
  PR; every caller runs the reverted kit from its next run, with nothing to change in the repos.
- A repo's required-check names change: a called job reports as `<caller job id> / <job name>`.
- ADR 0015's byte-identical-copies model still holds for the build kit; the review kit no longer follows it.
- The verdict inputs are checked in `publish` (two accepted values each), since a called workflow has no choice type.
- Fork and Dependabot `pull_request` runs: GitHub documents that a fork's write permissions are changed to read after
  the workflow's own `permissions:` are applied, and that a Dependabot run's token is read-only by default and the
  `permissions:` key raises it. Neither is documented as a start-up failure, which comes from a called job asking
  for more than its caller grants. The kit still skips both in `preflight`.
- Unverified until a live run: that the three credentials reach the called workflow (GitHub documents that `vars` come
  from the caller's repository); whether a called job that asks for write passes start-up in a fork run, where the
  caller's write is adjusted down (the docs do not say which level the check sees).
- Seen on a live run (the review of the PR that moved the scripts): in `publish`, `job.workflow_repository` and
  `job.workflow_sha` resolved to this repository and the commit of the called workflow file, which for the local call
  is the PR's merge commit; the sparse checkout of one script by commit SHA worked and the script ran from it. Not
  yet seen: a call from another repository, where the value is the kit's commit and a local call
  cannot tell it from the caller's own; and Claude reading the command from the kit's file (a plain prompt that names it, instead of a slash command) under
  `--permission-mode default`: the first live run of the third step, which is the PR's own review, is the test.
