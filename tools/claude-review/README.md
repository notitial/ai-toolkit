# claude-review

An automatic Claude code review for GitHub pull requests, owned by a GitHub App. Claude reads the PR and returns its
findings, thread verdicts and a short overview as data; it has no shell, web, write or posting tool. The workflow
checks that result and posts all of it as the repo's **reviewer App**: inline findings, thread replies, one overview
comment edited on every run, and an APPROVE or REQUEST_CHANGES review. Nothing is posted as `claude[bot]` or
`github-actions[bot]`.

The review is a **reusable workflow**, [`.github/workflows/claude-review-kit.yml`](../../.github/workflows/claude-review-kit.yml)
([ADR 0018](../../docs/adr/0018-review-kit-as-reusable-workflow.md)). A repo calls it from a thin caller that owns the
triggers, the permission ceiling and the credentials; see [The reusable kit](#the-reusable-kit). This repo runs the
review that way, and its tests read the kit from that path.

The kit reads the review command, [claude-pr-review.md](claude-pr-review.md), from its own checkout: no copy is
installed in a repo that calls it, and this repo has none.

| File | Read from | SHA-256 |
|---|---|---|
| [claude-pr-review.md](claude-pr-review.md) | the kit's own checkout (v4.7) | `ee1d8911cdedba1cd52e99edca1ab0cf74b9fc83f69074a735dcf4fa181b2350` |

**Version:** v4.9 (2026-11-23), **breaking**: the kit declares one Claude secret, `CLAUDE_REVIEW_CREDENTIAL`, an API key or an
OAuth token told apart by its prefix, and no longer declares `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`. A caller
that still passes either fails at start-up; the fix is one line, replacing those two lines with
`CLAUDE_REVIEW_CREDENTIAL: ${{ secrets.CLAUDE_REVIEW_CREDENTIAL }}`. The review command is unchanged. v4.8 (2026-11-22): a `--comments` follow-up resolves a suggestion thread once someone has replied in
it. `collect.py` lists those threads and `publish` posts a fixed reply with the follow-up marker, then resolves the
thread as it resolves a judged one. Nothing judges them, so with no finding thread to follow up Claude does not run
and the verdict and the overview stay as they were; a follow-up with only suggestion threads says
so in its log instead of "already covered". The review command is unchanged. v4.7 (2026-11-22): two new candidate kinds inside existing passes, so a full review is still seven passes. The defects pass also reports a test the PR adds or changes that cannot fail, repeats another case or whose name claims what it does not check; the written-rules pass also reports a statement in a doc, ADR, README, `CLAUDE.md` or code comment that the PR's change makes false. Both are verified on `sonnet`, block like other findings and sort last. v4.6 (2026-11-20): wording and docs only. The stopped overview says why the review stopped, a rereview waits for the thread judges before the guidance step, the command tells Claude not to search outside its folders for a called workflow, and Auth options describe how the kit passes the credential. v4.5 (2026-11-20): the review has no early stop for a PR it judges trivial; only a draft or closed PR stops, so a small change to a `CLAUDE.md`, a rule or a workflow gets the full review. The triage and guidance agents are gone (the lead lists the `CLAUDE.md` paths and writes the overview itself), so a full review is seven agents and the cost step warns below 7. v4.4 (2026-11-20; breaking for a repo that set the old variable): one variable, `SELF_HOSTED_REVIEW`, sets the runners of all four jobs and replaces `CLAUDE_REVIEW_KEY_RUNS_ON`, which the kit no longer reads. Unset, `preflight` and `review` take the `runs-on` input as before (still accepted) and `appcheck` and `publish` run on `ubuntu-latest`. Set, the App key shares runners with Claude (see [Prerequisites](#prerequisites), item 2). A repo that set the old variable sets the new one before this reaches it. The review command, findings and modes are unchanged. v4.3 (2026-11-19): a third least-code kind, "no caller" (see [Least code](#least-code)): a new export, option, parameter, prop or type field nothing uses is a non-blocking suggestion, checked by a `sonnet` verifier like a simplification. v4.2 (2026-11-19): the kit's `review` job runs a pinned Claude Code CLI directly instead of through `claude-code-action`. What the review posts is unchanged; the root `CLAUDE.md` it reads is now the PR's copy, not the default branch's, and is not a rule source when the PR changes it. The CLI is pinned by `reviewer/package.json` and its lockfile, the session starts in a copy of the kit's `reviewer/` folder with no GitHub token in its environment, and nothing the PR holds can configure it (see the trust rules below). The cost record's `action` field is now `claude_code`. v4.1 (2026-11-19): a seventh review pass, "least code" (see [Least code](#least-code)). Duplication of
code the repo already has is a blocking finding; a clear simpler rewrite is a non-blocking suggestion, posted inline
from a new `suggestions` list in the result (at most 3). The pass added one agent to a full review, so the cost step's
minimum became 9 (7 from v4.5). v4.0 (2026-11-19; breaking): a fixed issue that comes back is an ordinary new finding, not a reopened
thread. `publish` no longer unresolves anything: resolving a thread is the only write it makes with its
`GITHUB_TOKEN`. `collect` leaves resolved threads out of the threads file, and the result schema loses the `reopens`
key. When Claude finds the bug again, it is a new finding, so the review is REQUEST_CHANGES. A repo that moved to the
reusable kit got this by pinning the new SHA (callers now use `@main`). v3.4 (2026-11-17; as a reusable workflow, 2026-11-19, with no behaviour change): the review step runs with `--permission-mode default`. Since `claude-code-action` v1.0.273 a
session that has a prompt starts in auto mode, where a tool call no allow rule covers can be approved by a safety
review; `default` refuses it, so `--allowedTools` stays a strict list. The deny list, review command, findings format and
modes are unchanged. v3.3 (2026-11-10): the two jobs that hold the App key, `appcheck` and `publish`, may run on a dedicated
self-hosted pool instead of GitHub-hosted runners, chosen by the optional repo variable `CLAUDE_REVIEW_KEY_RUNS_ON`
(unset: `ubuntu-latest`, as before), so those two jobs need no file edit; the review command, findings
format and modes are unchanged. The key pool first ran live on 2026-11-10, on a private repo: `appcheck` and
`publish` both ran on a pool runner that re-registered and wiped itself between jobs. v3.2 (2026-11-09): a cheaper model mix. The
defects pass and its verifiers, and the judges of a `--comments` follow-up, run on `sonnet` instead of `opus`; interaction, security and failure-path passes and
verifiers, and the judges of a full `@claude review`, stay on `opus`. Findings format and modes are unchanged.
v3.1 (2026-11-05): a sixth review pass flags private data (credentials, people, clients, private ticket
keys, hosts and home paths, ignored folders) in the lines a PR adds and in its title and description, and the review
is told never to repeat the value. v3.0 (2026-11-04): a new review command, written from the kit's interface alone. It keeps v2.5's result
format and modes, and an incomplete review now posts no verdict instead of approving. v2.5 (2026-10-24): a full
`@claude review` reopens the thread of a fixed finding whose issue is back, instead of dropping it and approving.
v2.4 (2026-10-23) made the review App-owned. v2.4 and v2.5 were tested end to end on a throwaway repo with
`ubuntu-latest` runners. The v3.x command has run in live reviews since 2026-11-04 but has not been through the
[Test protocol](#test-protocol) on a throwaway repo; run it before relying on a mode no live review has used. The [tests/](tests/) folder runs the kit's scripts (`collect.py`, `publish.py`) against a fake
GitHub: `python3 -I -B -m unittest discover -s tools/claude-review/tests` from the repo root (`bash tools/test-all.sh
claude-review` runs the same).

## What it does

Four jobs. Where they run: one optional variable, `SELF_HOSTED_REVIEW`, puts all four on your own runners; unset,
`preflight` and `review` take the `runs-on` input and `appcheck` and `publish` run on `ubuntu-latest`
([Prerequisites](#prerequisites)).
- **`preflight`**: skips fork PRs with a notice, checks the App variables are
  set, checks the commenter has write access, applies the once-per-PR gate. Its `GITHUB_TOKEN` is read-only. Only if
  it passes does the rest run.
- **`appcheck`**: mints an App token and throws it away, so a bad key, a missing install or a wrong
  `CLAUDE_REVIEW_APP_LOGIN` fails before Claude costs anything. On a comment request it reacts 🚀 as the App (since
  v2.5; a 👀 from claude[bot] means the Claude GitHub App is still installed on the repo, which nothing here needs).
- **`review`**: fetches the PR, installs the pinned Claude Code, runs it read-only
  with no GitHub token in its environment, uploads the result as an artifact. One at a time per PR, never cancelled.
- **`publish`** (no PR checkout, no Claude): posts as the App, in this order: thread replies, resolve,
  the overview comment, the review. On a push to a same-repo PR it also dismisses the App's approval of an older
  commit. Re-running it never posts a second review (every review body has a run marker).

On a private repo, with `appcheck` and `publish` on GitHub-hosted runners, they are about two billed Actions minutes
per review (more when `preflight` and `review` run on GitHub-hosted runners too), and `publish` runs (one minute) on
every push to a reviewed PR for the dismissal check. `SELF_HOSTED_REVIEW` removes those minutes. Public repos don't
pay for GitHub-hosted minutes.

Three modes:

| Trigger | Mode | What happens | Typical cost |
|---|---|---|---|
| A non-draft same-repo PR is opened, pushed to, reopened or marked ready, and has no review yet (Dependabot and forks skipped) | `initial` | Full review: seven review passes (defects in the change, interaction with the code around it, security, failure paths, written CLAUDE.md rules, private data, least code), then one verifier per candidate. Up to 8 findings, inline on their lines (else in the review body), REQUEST_CHANGES; or APPROVE with "No issues found". Up to 3 non-blocking suggestions ride inline on either | $0.5–2 on real feature PRs ($0.18–0.33 on small test PRs), measured before v3.1's sixth pass; one replay of a 4-file PR with the seventh pass cost $2.51 (12 agents, no baseline arm) |
| A push to a PR that was already reviewed | none | `preflight` skips; Claude doesn't run. `publish` dismisses a stale APPROVE | $0 |
| A comment starting `@claude review`, from someone with write access | `rereview` | Judges each open review thread, replies, resolves the fixed ones, then reviews the whole PR again (drafts too) without repeating the issue of a thread that is still open. A fixed issue that is back is a new finding in a new thread (resolved threads cover nothing). APPROVE when nothing is found and no thread is open | about `initial` |
| A comment starting `@claude review --comments` | `followup` | The thread follow-up only: new code, and a fixed issue that came back, aren't seen. When every thread is resolved, the App dismisses its REQUEST_CHANGES and posts a COMMENT "Findings addressed; new code was not re-reviewed." | $0.04–0.25 |
| `--comments` again with no push and no new thread reply | none | One follow-up per branch state; Claude doesn't run | $0 |
| `--comments` with no open finding thread, only suggestion threads someone replied in | none | Claude doesn't run; `publish` replies in each and resolves it, and leaves the verdict and the overview as they were | $0 |
| `@claude review` again with no push and no new thread reply | `rereview` or none | Skipped when every open thread already has a rereview reply for this head or, with no open thread, when this head already has a clean overview | $0 or about `initial` |

- **A stopped run:** an `initial` review of a PR that was closed or turned back to a draft after the run was queued
  stops at once; the overview says "Review stopped: the PR was closed or a draft when the review ran" and there is no
  verdict. No other PR is stopped, however small or trivial.
- **The overview comment:** one issue comment from the App, edited on every run. It shows the head, the mode, the
  result (`clean`, `issues`, `stopped` or `followup`) with a link to the review, Claude's 2–3 sentence overview and
  the open threads with links. It is rendered again from the current state on every run and keeps no history.
- **The verdict is a signal.** `publish` decides it from Claude's result, never Claude: findings or an open thread →
  REQUEST_CHANGES; a full review with no findings and no open thread → APPROVE; a follow-up that leaves no thread
  open → COMMENT (after dismissing the App's REQUEST_CHANGES). It submits only when the verdict changes.
- **Findings without a thread** (in the review body, because their line isn't in the diff) aren't judged by a
  follow-up; a full `@claude review` checks them.
- **Requests are top-level PR comments.** `@claude review` typed as a reply inside a review thread triggers
  nothing.
- **Reports:** code that won't build, parse or load, logic wrong for every input, bugs with a concrete reachable
  trigger, security issues and unhandled error paths in the changed code, clear breaks of a quoted CLAUDE.md rule.
- **An incomplete review gives no verdict:** when a review pass or a verifier fails twice, the result carries the
  verified findings only, and with none `publish` rejects it, so a review that reports itself unfinished never approves. A
  review that cut the pipeline short without saying so still can (Known limitations).
- **A re-run stops at its own review, and a failed write fails the job:** every review carries the run marker, the
  only idempotency key. An attempt that finds its run's review (after finishing any thread reply or resolve that
  failed) posts and writes nothing more. Any failed write (a reply, a resolve, the overview, a dismissal, the review
  itself) fails the job; "Re-run failed jobs" is the retry. A failed write never approves, and never holds back a
  request for changes.
- **The overview shows the current state only:** the head, the mode, the result line, Claude's paragraph and the
  threads. The Actions run list and the PR timeline hold the history.
- **Doesn't report:** style, nitpicks, pre-existing issues, what the compiler or linter catches, missing tests or
  docs. A test that cannot fail and a doc the PR makes false are reported.
- **Threads it touches:** only threads the review started. A thread is judged fixed when the code handles it, or a
  reply's "not a bug" argument holds up. A claimed fix the code doesn't show stays open.
- **Queueing:** GitHub keeps one waiting run per PR, so a third request replaces a waiting second one. Wait for a
  review to finish before asking again.
- **Fork PRs:** skipped with a notice (their runs get no secrets). `@claude review` from someone with write access
  reviews one; it gets a COMMENT instead of an APPROVE, because a later push to a fork never reaches `publish` to
  dismiss it.
- **Cost record:** every run that reaches Claude writes a cost line to the job summary and uploads a numbers-only
  artifact, `claude-review-cost-<run id>-<attempt>` (90 days).

## Reviewer cases

`cases/` holds changes the reviewer saw and let through, each with the finding it should have raised, checked by the
owner. They are the regression set for changes to the command, `REVIEW.md` or the model; there is no scorer yet (the
replay runner below runs a PR but does not score it), and the set starts empty in this repo. Format and how to add
one: `cases/README.md`. `tests/test_cases.py` checks the shape.

### Replaying a PR offline

`replay/replay.py` (stdlib Python, git on the path, `claude` logged in) runs one PR through the review command on a
local `claude -p`, to compare a command or a model change on PRs already reviewed. It posts nothing and calls no
GitHub API: it fetches `refs/pull/<N>/head`, builds the context folder from git (`pr.json` with state `OPEN` and
`isDraft` false so the gate passes, `pr-files.json`, `pr.diff`), checks the head out in a clone under `--work-dir`
(default `/tmp/review-replay`; `--base` defaults to `auto`: the default branch's tip, whose merge base with the head is
what GitHub diffs), copies the kit's `reviewer/` folder and the command into a setup folder beside the clone, as the
workflow does, and runs `reviewer/run.sh` there: the same file, so the same flags, tool limits and result schema, as the
workflow's run, and they cannot drift. Each run is one full review: use the subscription outside a busy
window and run PRs one after the other.

```text
python3 -I -B tools/claude-review/replay/replay.py --repo OWNER/NAME --pr N --head HEAD_SHA [--base BASE_SHA] \
  [--verifier-model sonnet] [--arm NAME] [--run K] [--title T] [--body-file F] [--command FILE] [--model M] [--prepare-only]
```

- `--verifier-model` moves the verifiers that 7.4 puts on `opus` to the given model, in a temp copy of the command
  (the tracked file is never touched); the run fails if the 7.4 model line is not found exactly once, so a reworded
  command cannot run the unpatched arm.
- Results go to `~/review-replay-results/<owner_name>/pr<N>-<head8>-<arm>-<run>.json` (the result, `total_cost_usd`,
  per-model cost, duration, turns, agent count by requested model) plus the gzipped stream next to it. Nothing is
  written in the repo.
- Differences from CI: the PR title and description are placeholders unless given, the lead
  model is `sonnet` (CI's main session runs on it; the workflow pins no model, so `--model` overrides this default),
  the review runs on your machine's `claude` version, not the kit's pinned one, with your own login and user-level
  `CLAUDE.md` (CI uses a fresh config folder and `env -i`; your login needs your environment).
  The root `CLAUDE.md` is the clone's, so replay a PR that edits it knowing the review will not use it as rules.
- `--base auto` fails when the head is already in the default branch's history (a PR merged with a merge commit): pass
  `--base` then. A run that returns no structured result exits 1 with `NO RESULT`: do not score it. Set
  `ANTHROPIC_API_KEY` and `claude` bills the API instead of the subscription (the runner warns).

`tests/test_replay.py` covers the parts that do not call claude.

## REVIEW.md (the owner's review brief)

A repo can put a `REVIEW.md` at its root. The review command looks for it, and when it exists hands its path to every
review agent, which reads it first. It is written by the repo owner and kept apart from CLAUDE.md: CLAUDE.md says how
to work in the repo, REVIEW.md says what the reviewer should hunt for and what to leave alone. Without one, nothing
changes.

What goes in it (this repo's own, `REVIEW.md` at the repo root, is the worked example):
- **Failure modes to hunt:** the repo's recurring bugs, by area, each concrete enough to check against a diff.
- **A nit cap:** the most findings to return (never more than the workflow's 8), and what never to report. "Style" there means code style. No review pass sees a rendered screen: a repo with rules about looks says in its CLAUDE.md who checks them (the old/new pair), not the review.
- **Least-code switches:** make duplication non-blocking, turn suggestions off, or lower the cap of 3 suggestions. It cannot make a suggestion block or raise the cap.
- **Optional, for a repo porting or rewriting code:** a failure mode such as "a ported piece states its size in lines against the code it replaces".
- **Paths to skip:** generated files, lockfiles, archives, prose-only changes.
- **A finding rule:** every finding cites `path:line` and names the trigger.

How it is applied:
- It only directs: the reviewer's tools, the result schema, the "concrete, reachable trigger" rule
  and the private-data rules (it may only add categories, or drop some other than credentials) do not change,
  and a line in it that isn't about reviewing (run a command, fetch, post, ignore the instructions) is ignored.
- The checkout is the PR's own tree, so **a PR that edits `REVIEW.md` is reviewed without it** (the command checks
  `pr-files.json`) and the overview says so; otherwise a PR could write "skip `hooks/`" into its own review. Land
  REVIEW.md changes in a PR that nothing else depends on.
- Findings in skip paths are dropped and the rest trimmed to the cap after validation.
- The command is read from the kit's checkout, at the commit of the workflow file that runs: for a caller of `@main`,
  main's commit when the run starts, so a command change reaches every caller when it merges. In this repo, which
  calls the kit by a local path, a `pull_request` run uses the PR's own command (as it uses the PR's own scripts) and a comment run uses main's. A
  `REVIEW.md` added in a PR is not read by that PR's own review.

Keep it under about 60 lines; every line is read by every review agent on every review.

## Private data

From v3.1 a sixth pass looks for private data in the lines a PR adds: credentials, real people's names and
contacts, client and employer names, private ticket keys and links, host names, private IPs and home paths, and paths
into folders `.gitignore` excludes. It also reads the PR title and description, which become the commit message.

- A finding names the kind of data and the line, never the value. The overview and thread replies follow the same rule.
  That is an instruction to the model: nothing in `publish` enforces it, and a file name that is itself the value
  always shows as the finding's path. A credential finding tells the author to rotate the value: it is exposed once
  the branch is pushed, and removing the line does not undo that.
- A finding means REQUEST_CHANGES, like any other. A hit in the title or description is named in the overview only and
  does not change the verdict, so such a PR can still be approved: read the overview before merging. The title and
  description are checked only when a review runs, and editing them starts none. Fix them before the last push: a
  `@claude review` comment after an edit is skipped when the head already has a clean overview, so only a new push
  re-checks them. GitHub keeps a title change in the PR timeline and the edit history of a description.
- `REVIEW.md` tunes it per repo: say whether the repo is public, what is allowed (the owner's own name, public
  projects), and anything else that counts as private here. Describe kinds, not values: a public repo's `REVIEW.md` is
  public. A private repo can narrow the pass.
- It is a second net. On a public repo the PR's diff is public as soon as the branch is pushed, so the review keeps
  data off the default branch but cannot un-publish it; scan locally before pushing. A review comment shows its diff
  hunk, so the line stays visible on the PR after it is fixed. Making a private repo public publishes all its PRs
  too: audit them first, or publish a fresh repo from the default branch.
- It cannot see binary files (no patch), commit messages or author emails; a repo that does not squash-merge keeps
  those on the default branch unchecked.
- No term list is passed to the review on purpose: a prompt injection in the PR could make Claude repeat the whole list
  in a public comment.

## Least code

From v4.1 a seventh pass reads the lines a PR adds for three things (the third from v4.3), and each candidate gets its
own verifier (duplication on `opus`, because it blocks; simplification and no caller on `sonnet`).

- **Duplication** is code that does the job of code the repo already has (a helper, component or constant), or the same
  logic added twice. It is an ordinary finding, last in severity order, so it means REQUEST_CHANGES. The verifier
  reads the existing code and confirms it gives the same result for every input, that the file can use it without a
  new dependency or import cycle, and that the duplication is new in this PR. A repo can soften this in `REVIEW.md`.
- **Simplification** is a concrete rewrite with the same behaviour and less code (a special case folded into the
  general path, a redundant branch or guard removed, hand-written code replaced by a standard-library feature). It
  goes in the result's `suggestions` list, at most 3, most lines saved first, and never blocks.
- **No caller** is a new export, option, parameter, prop or type field that nothing in the PR or the repo uses. It is a
  suggestion too, never blocking, since a PR in a stack may add the caller next. The verifier searches the checkout,
  tests and dynamic uses included (for a parameter or option: a call site that passes it, code that reads it), and
  rejects a piece something outside the repo's code reaches or reads (a public API, an entry point, a CLI flag, a
  route, a framework hook, a config key, a field a serializer or schema reads), an override or a parameter a required
  signature holds, and code in docs, generated or vendored files.
- `publish` posts a suggestion only as an inline comment (one that cannot go inline is dropped, not put in the review
  body), starting with a hidden marker and "Suggestion (non-blocking):". The sanitizer strips markers from Claude's
  text, so only `publish` can write one. A thread that starts with the marker never counts as open: the
  review's thread count and its verdict ignore it, `collect.py` hands it to a rereview as context only, resolved or not (so it is not
  suggested twice, and not judged). Once someone has replied in it, the next `--comments` follow-up answers it with a
  fixed reply and resolves it without judging it (any reply counts, a question too, and an Unresolve does not stick);
  a person may also resolve it or ignore it. A suggestion never changes the verdict, and
  a run that posts no verdict posts no suggestions.
- Not reported: renames and formatting, a new dependency, a rewrite that adds an abstraction or lines, performance,
  duplication that predates the PR.

## Adding it to a repo

The `/add-claude-review` skill (installed by `/setup-claude`) writes the reusable kit's caller below from the target repo.

### The reusable kit

A caller is one job that sets the permission ceiling, calls the kit and maps its credentials by name:

```yaml
name: Claude Review

on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]
  issue_comment:
    types: [created]

permissions: {}

jobs:
  claude-review:
    permissions:
      contents: write
      pull-requests: write
      issues: read
    uses: <owner>/ai-toolkit/.github/workflows/claude-review-kit.yml@main
    secrets:
      CLAUDE_REVIEW_APP_KEY: ${{ secrets.CLAUDE_REVIEW_APP_KEY }}
      CLAUDE_REVIEW_CREDENTIAL: ${{ secrets.CLAUDE_REVIEW_CREDENTIAL }}
```

- **Call `@main`**: a kit change reaches every caller when it merges. Before that, CI runs the kit's tests and the kit
  PR's own review runs its edited copy (below); a break that shows only in another repo's call is not caught first.
  Write access to the kit's `main` reaches every caller's keys. To roll a bad change back, merge a revert of its PR. This repo calls its own copy by a local path
  (`uses: ./.github/workflows/claude-review-kit.yml`, the caller's own commit), because a SHA of a file in the same PR
  cannot exist yet and a PR that edits the review has always been reviewed by its own edited copy.
- **Inputs** (all optional, in a `with:` block): `runs-on`, a JSON array of labels for `preflight` and `review`
  (default `["ubuntu-latest"]`, ignored when `SELF_HOSTED_REVIEW` is set); `changes-event` (`REQUEST_CHANGES` or
  `COMMENT`) and `approve-event` (`APPROVE` or `COMMENT`). The
  variables are the ones the calling repo sees: its own, or an org's it can see.
- **Credentials:** pass the two names above. Never `secrets: inherit`, and never a secret the kit does not declare (a
  caller that passes one fails, the retired `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` included). Both are
  optional in the kit, so a missing App key reaches `appcheck`'s own message.
- **Permissions:** the ceiling above is the union of what the kit's jobs ask for. Each kit job narrows it to what it
  needs (`appcheck` none, `preflight` and `review` read-only, `publish` `contents: write` and
  `pull-requests: write`); a caller that grants less makes the run fail at start-up.
- **Check names** read `<caller job id> / <job name>`, for example `claude-review / Publish the review`.
- **The scripts** (`collect.py`, `publish.py` in this folder) are checked out by the kit itself, at the commit of its own
  workflow file (`job.workflow_sha`), so the scripts always match the
  workflow that runs: for a caller of `@main`, main's commit when the run starts. Nothing to install.
- **The command** (`claude-pr-review.md` in this folder) and **the reviewer folder** (`reviewer/`: `CLAUDE.md`, `run.sh`,
  the result schema, `package.json` and its lockfile) come from the same checkout: `review` checks them out with
  `collect.py`, copies them to a folder in the runner's temp directory, installs the pinned Claude Code there with
  `npm ci` and starts Claude in that folder, so there is no `.claude/commands/` copy to install or keep in step. The
  result schema is in the kit's `reviewer/result-schema.json` only (`run.sh` passes it as `--json-schema`, `publish` checks the result against it). The command keeps its
  frontmatter and its `$ARGUMENTS` placeholder; the kit's prompt says what `$ARGUMENTS` is.
- The prerequisites below apply to both ways of installing; "the workflow" means the kit.

### Prerequisites

1. **Runners, by default:** with the variable `SELF_HOSTED_REVIEW` (prerequisite 2) unset, `preflight` and `review`
   take the `runs-on` input (`ubuntu-latest`, the canonical value, or a self-hosted label set), and `appcheck` and
   `publish`, which hold the App key and tokens, run on `ubuntu-latest`. GitHub-hosted runners must be allowed for
   every job left on them: a private repo that may not use them gets no review, because its jobs wait for a hosted
   runner that never starts and nothing is posted on the PR.
   - Tested on self-hosted Linux runners (v2.3) and `ubuntu-latest` (v2.4); `appcheck` and `publish` on a
     self-hosted pool since v3.3.
   - A self-hosted runner for `review` needs at least 2G of memory; `gh`, `jq`, `git` and `python3` ≥ 3.8 on `PATH`;
     and outbound HTTPS to github.com, registry.npmjs.org, api.anthropic.com and claude.ai, direct (Claude runs under
     `env -i`, so no `HTTPS_PROXY` or custom CA variables reach it). Node 22 comes from the job
     (`actions/setup-node`, from the runner's tool cache or a download), so the runner needs none; it must let the
     job run the Claude Code package's install script (`npm ci`). Never a runner that holds a deploy key.
     `appcheck` and `publish` need `bash`, `gh`, `git`
     and `python3` ≥ 3.8; the runner's bundled Node runs their three JavaScript actions (the token minter, the
     artifact download and the checkout of the kit's script); and they reach github.com, api.github.com and the
     Actions and artifact service hosts. The kit repository must be one a job's `GITHUB_TOKEN` can read (this one is
     public). These hosts are what the jobs need, not a control: self-hosted egress allow-lists are often not enforced.
   - On a **public repo**, keep `ubuntu-latest`. GitHub recommends self-hosted runners for private repos only,
     since a pull request from a fork of a public repo can run its own code on them.
2. **`SELF_HOSTED_REVIEW`, for a private repo only:** a JSON array of labels such as `["self-hosted","review"]`. When
   set, all four jobs run there and the `runs-on` input is ignored. Set it as a repository variable, or as an
   organisation variable whose visibility is private repositories only, never one a public repo can see. A public repo
   ignores it (the `runs-on` expressions check `github.event.repository.private`), so one it sees by mistake leaves it
   on the defaults above. It must be a non-empty JSON array of strings: anything else fails the jobs when they are
   queued, and a pool that is offline leaves the review waiting with nothing on the PR. Delete it to go back to the
   defaults above.
   - **The cost:** the App key then reaches the runners where Claude reads PR text, and, if the pool also runs CI,
     where PR code runs. Code that gets to run on such a runner can leave something behind that reads the key in a
     later `appcheck` or `publish`: a PR's CI job, a Dependabot PR's CI job (third-party install scripts), a
     compromised package in the review's install, or a tool escape steered by text in the PR. The sole-pusher
     assumption bounds only the first; the others need no second writer. Setting the variable is the owner's choice
     (see the residual risk under Security model).
   - The pool's runner group allows no public repository: that setting, not the variable, decides which repos' jobs
     reach the pool.
   - The runners hold no deploy key and no other long-lived secret on the host. Their own runner-registration
     credential (for example a PAT or a registration App) is a different thing from the reviewer App's key, which
     arrives per job as the repo secret; it is read only by the runner's start-up and never reaches a job's
     environment or a path the job's user can read.
   - Only private repos with the same single writer reach the pool: a pool that serves several repos carries over
     between them.
   - Recommended: a runner that is restarted and re-registered for each job, with its work and temp directories
     wiped (not a clean machine: the runner's install directory stays writable by the job's user); a pool apart from
     the CI runners that run PR code; no route to internal networks or services beyond what the jobs need.
3. **(user) A reviewer GitHub App**, one per owner (a personal account, or an org), shared by its repos:
   - Create it in the owner's settings → Developer settings → GitHub Apps → New GitHub App. Name it (its slug becomes
     the bot login, e.g. `acme-review` → `acme-review[bot]`); no webhook; repository permission **Pull requests: Read
     and write** and nothing else (no Contents: it can comment and review but never push); "Only on this account".
   - Generate a private key (Settings → Private keys). Note the **Client ID**.
   - Install it on each repo that uses the review.
4. **(user) Repo config** (names only here; the key is prompted, never typed on a command line):
   ```
   gh variable set CLAUDE_REVIEW_APP_CLIENT_ID -R <owner/repo> --body <Client ID>
   gh variable set CLAUDE_REVIEW_APP_LOGIN -R <owner/repo> --body <app slug>
   gh secret set CLAUDE_REVIEW_APP_KEY -R <owner/repo> < <path to the .pem>
   gh secret set CLAUDE_REVIEW_CREDENTIAL -R <owner/repo>
   ```
   For every private repo of an org at once, set the Claude secret on the org instead:
   `gh secret set CLAUDE_REVIEW_CREDENTIAL --org <org> --visibility private`.
   Optional, only for a private repo on its own runners (prerequisite 2): set `SELF_HOSTED_REVIEW` to the pool's
   labels, on the repo or, for every private repo of an org at once, on the org with private visibility:
   ```
   gh variable set SELF_HOSTED_REVIEW -R <owner/repo> --body '["self-hosted","review"]'
   gh variable set SELF_HOSTED_REVIEW --org <org> --visibility private --body '["self-hosted","review"]'
   ```
   The org variable reaches every private repo of the org, those added later included, so each must meet the
   single-writer condition of prerequisite 2; otherwise use repository variables. Deleting it (`gh variable delete`)
   goes back to the defaults of prerequisite 1.
   Then delete the downloaded `.pem`, or keep it only in a password manager. The workflow must reference no other
   secret. The Claude secret is review-only: do not reuse a key that production runs on.

   Also turn on **"Always suggest updating pull request branches"** (repo Settings → General → Pull Requests; API
   field `allow_update_branch`). It is off by default, with no org-level switch. Without it a PR that has fallen
   behind `main` shows no Update branch button, and the workflow, which checks out the PR's head commit, can fail on
   a missing ref until the branch is updated. Update a stale branch by merging `main` into it, never by rebasing
   (`rules/workflow.md`, Stale PR Branches).
5. **The Claude GitHub App is not needed.** If it is installed on the repo, it still reacts 👀 to every `@claude`
   comment (its own mention handling): remove the repo from its installation.
6. **Required reviews:** the App's review must never satisfy one. Scope required reviews to people or teams, or set
   the inputs `changes-event` and `approve-event` to `COMMENT`.
7. **Org repos:** an org owner may have blocked GitHub-hosted runners or restricted workflow permissions; then
   the jobs left on hosted runners never start (all four use `SELF_HOSTED_REVIEW` when it is set), and no review is
   posted. Do not restrict the
   pool to one workflow ref: on `pull_request` the ref is the merge ref, so such a restriction never matches and the
   jobs queue.
8. **Recommended:** a "Review" section in the root `CLAUDE.md` listing quotable rules. The CLAUDE.md agents flag only
   clear breaks of quotable rules.

**Auth options:** one secret, `CLAUDE_REVIEW_CREDENTIAL`, holds either credential. The `review` step trims its
whitespace and picks the variable by prefix: `sk-ant-oat` becomes `CLAUDE_CODE_OAUTH_TOKEN`, `sk-ant-api` becomes
`ANTHROPIC_API_KEY`, and only that one enters the pinned Claude Code CLI's environment. An empty value or any other
prefix fails the job with a message that names the secret and the two prefixes, never the value. Switch between them by
setting the secret to the other credential, with no workflow edit.
- **API key** (tested): a Claude Console key (`sk-ant-api...`).
- **Subscription OAuth token** (tested): the token made by `claude setup-token` (`sk-ant-oat...`). The cost line still reports `total_cost_usd`, but
  on a subscription that figure is notional: usage counts against the account's limits, shared with its interactive
  sessions, and when the limit is reached the review fails in under a second with "did not return
  structured_output". The token is a personal credential, usually long-lived: revoke it from the Claude account and
  mint a new one to rotate.

## For agents opening PRs

In a repo with the review, a PR isn't ready for the user until its review has finished and been answered. Agents
read and post through the GitHub MCP server (`gh` is blocked for agents by `hooks/gh-block.sh`); where its guard
denies a post, give the user the `gh` command instead.

1. Open the PR as a draft (`create_pull_request` with `draft: true`). The review runs once, when the PR is marked
   ready for review, so a CI fix pushed after that means it saw broken or stale code, and a second look costs a
   `--comments` round. CI runs on drafts: poll `pull_request_read` with `get_check_runs` every few minutes until every
   check outside the Claude review workflow (the kit's checks are named `claude-review / ...`; CI, the secret scan, CodeQL) has concluded `success` on the current head.
   Fix a failure on the branch while it is still a draft, then wait again. A PR that changes rendered UI carries its
   old/new or mockup/built pair in the description first. Only then mark it ready
   yourself (`update_pull_request` with `draft: false`; `tools/github-mcp/guard.sh` allows it and cannot see CI, so
   the green-checks condition is the agent's to keep).
   If a required check stays queued for a long time, or a failure is outside the PR's scope, tell the user instead of
   marking it ready.
2. Wait for the review (the runner may be queued): poll `pull_request_read` with `get_check_runs` every few minutes,
   until the `claude-review / Publish the review` run that started after you marked the PR ready completes (about 1–2 minutes once a
   runner picks it up). The draft phase left a `skipped` one on the same head: ignore it. The new run must conclude
   `success`: `skipped` means no review ran, so tell the user.
3. Read the findings with `pull_request_read`: the App's inline comments (`get_review_comments`), the review body's
   "Not on a changed line" section (`get_reviews`), and the overview comment (`get_comments`, the one starting
   `<!-- claude-review:summary`). A review that did not finish shows "No verdict" in the overview comment, or posts
   nothing at all for the head (a green `claude-review / Publish the review` with no App review and no overview for it). Silence is never
   "no findings": tell the user. After a "No verdict" overview only a new full review runs it again; after nothing at
   all, the next push is reviewed afresh only if the App has never commented on the PR; otherwise ask the user.
4. Fix each finding, or reply in its thread (`add_reply_to_pull_request_comment`) with why it isn't a bug. A thread
   that starts **Suggestion (non-blocking)** is never judged: apply or decline it, reply in its thread either way, and
   the next `--comments` run resolves it without judging it. Don't post `--comments` for a suggestion you haven't replied to.
5. Pushes after the first review are skipped. After pushing fixes or replies, and once no review is running, comment
   `@claude review --comments` (`add_issue_comment`, top level): it judges the open threads, replies and resolves
   the fixed ones. Wait for that run, handle any thread it keeps open, and report the findings and their outcome in
   the handover. A finding in the review body has no thread: fix it and say so in the handover (only a full review
   re-checks it).
6. Ask the user before a full `@claude review`.

## Test protocol

Use a throwaway PR. Each run's job summary shows
`Claude review (<mode>): $<cost>, <s> s, <turns> turns, <a> agents, <n> findings, <t> threads judged` and
`Publish: <i> inline, <b> in body, <d> dropped, <m> moved, <g> suggested, verdict <X>, <r> replied, <s> resolved, <x> dismissed, …`.
`<a>` is at least 7 in `initial` and `rereview`, plus one per candidate issue (and the thread judges in `rereview`); below that the step warns.

| # | Do | Pass when |
|---|---|---|
| 1 | Open a clean PR (non-draft) | APPROVE from the App, overview `result=clean`; nothing from `claude[bot]` or `github-actions[bot]` |
| 2 | Push a commit | `preflight` logs `Already reviewed: skipping`; `publish` dismisses the APPROVE ("New commits since this approval.") |
| 3 | Open a PR with real bugs | Inline findings on the right lines, one REQUEST_CHANGES, the overview links the review and lists the open threads |
| 4 | Push fixes, then comment `@claude review --comments` | App replies in each thread, threads resolved, the same overview comment edited (`result=followup`), REQUEST_CHANGES dismissed + COMMENT "Findings addressed…" |
| 5 | Comment `@claude review` | `rereview`, APPROVE, the same overview comment edited (`result=clean`) |
| 6 | Re-run `publish` of any run | "already submitted"; no second review, no write |
| 7 | Unset `CLAUDE_REVIEW_APP_CLIENT_ID`, comment `@claude review --comments`, set it back | `preflight` fails with "Missing: variable CLAUDE_REVIEW_APP_CLIENT_ID"; nothing else runs |
| 8 | (if available) someone with read access comments `@claude review` | Fails at "Check the commenter can write to the repo, and read the PR head" |
| 9 | On a PR with a resolved finding, push a commit that brings the bug back, comment `@claude review` | A new inline finding on the bug, REQUEST_CHANGES, and the old thread stays resolved and untouched (no `unresolve` call) |
| 10 | Open a PR that adds a doc line naming an invented client and person as real, an invented ticket key, an internal-looking host and a home path | REQUEST_CHANGES; each finding names the category and the line, and no posted text (inline, body, overview) contains any planted value |
| 11 | Open a PR that adds the same kind of line with obvious stand-ins only (`ACME`, `ABC-123`, `example.com`, `~/`) | No private-data finding |

A thread a person starts must never get a reply or be resolved.

## Quirks

- **Two kinds of 👀 and "github-actions resolved":** `preflight` reacts with the workflow's token, and threads are
  resolved with `publish`'s `GITHUB_TOKEN` (resolving needs `contents: write`, which the App doesn't have). A
  `claude[bot]` 👀 comes from the Claude GitHub App if it is still installed (Prerequisites 5).
- **Every thread reply also adds an empty "<app> reviewed" entry** to the timeline: GitHub wraps each reply in its
  own review. Cosmetic.
- **A ```suggestion in the review body renders as a plain code block** (suggestions only work inline).
- **Stale APPROVE after a push to a draft, by Dependabot, or to a fork:** those pushes don't reach `publish`, so the
  approval stays until the next review. Fork PRs get a COMMENT instead of an APPROVE for this reason.
- **COMMENT doesn't clear REQUEST_CHANGES** in GitHub's review decision, so a follow-up dismisses the App's
  REQUEST_CHANGES first. If that dismissal fails (403), the job fails and no comment is posted: dismiss it from the PR's
  review list and re-run the job.
- **A PR that changes the caller runs its own copy** (with the Claude key in `review` and the App key in `appcheck`
  and `publish`). An install or upgrade PR goes without `[skip ci]`: its own run is the first live test, so the repo's
  variables and secrets are set before it is marked ready, and the caller is reviewed locally first. A comment run
  uses the default branch's caller, so on an install PR `@claude review` runs nothing until the merge.
- **The repo's `.claude/` never configures its reviewer,** and its `CLAUDE.md` files are data: every agent is told to
  read the root `CLAUDE.md` for orientation, and a `CLAUDE.md` the PR adds or edits is reviewed as changed content,
  never used as rules (see Security model). The reviewer's own rules are `reviewer/CLAUDE.md`.
- **The transcript is hidden.** Claude's output goes to a file in a mode-700 folder; the log gets the exit status and
  the result's subtype only.
- **Unresolve alone gets re-resolved** by the next request on the same commit. To reopen a thread, reply in it saying
  why it isn't fixed, then unresolve.
- **A resolved thread covers nothing:** a rereview that finds an issue again posts it as a new finding, also when a
  person, or Claude's own judge, had resolved the old thread as "not a bug". Reply in the new thread, or leave the old one resolved and say why in the PR.
- **`the PR moved`:** a push during the run; the result is for older code and isn't posted (a stale approval is
  still dismissed, which can fail the job on a transient API error). Comment again.
- **Two requests for the same head in quick succession** can both review it (posting happens in `publish`, outside
  the `review` queue).
- **A failed review leaves the overview saying what was decided,** with the red check: the overview is written before
  the review, and says "A write failed: re-run this job" when the review itself failed.

## Troubleshooting

- **Green but nothing posted:** did `preflight` skip it (already reviewed, fork, draft)? Did "Save the result" warn
  "no structured result"? What does `publish` print ("No verdict: …", "No-op: …")?
- **"No verdict: Claude's result has issues reported without findings":** a review pass or a verifier failed twice,
  so the review didn't finish (the command fails closed). The overview comment says "Review incomplete" and no review is posted. Comment `@claude review` to run it again.
- **"CLAUDE_REVIEW_CREDENTIAL is missing or not a Claude credential", or "Claude exited with status 1":** the secret is missing from the caller or has the wrong prefix, or the credential is
  out of usage or invalid. Re-run the failed jobs once it's back.
- **`appcheck` fails:** the key doesn't match the Client ID, the App isn't installed on the repo, or
  `CLAUDE_REVIEW_APP_LOGIN` isn't the App's slug (the error says which). A key deleted after a review shows up on
  push-only runs as a token-mint failure in `publish`.
- **Every comment run fails at "Couldn't read the commenter's permission":** the job's token can't read
  `GET /repos/<repo>/collaborators/<user>/permission`.
- **"Claude launched N agents; a full review … launches at least M":** the model cut the pipeline short. Findings
  may still be right; note the run id.
- **`N moved` in the publish line:** Claude gave a wrong line number, and the finding's line text put it on the right
  line. A finding whose text matches no single diff line goes to the review body.
- **Permission denials:** `permission_denials_count` in the cost artifact, and a `::notice::` line per denied tool and path (at most 10) in the cost step's log. Never add bare `Read`/`Grep`/`Glob` or a
  shell tool to the allow rules in `reviewer/run.sh`, and never `--add-dir` (an added folder's `.claude/agents` and skills load).
- **"GitHub wouldn't give the diff":** the PR is too large for the diff API; Claude reviews from the per-file patches.

## Rollback

Revert the PR (`[skip ci]`). Posted comments, reviews and resolved threads stay; a stale App review can be dismissed
from the PR's review list.

## Security model

Don't loosen any of this when adapting the files.

- **Nothing from the PR checkout executes** in the review steps. The kit's scripts run from a checkout of the kit at
  the commit of its own workflow file: for a caller of `@main`, main's commit when the run starts, or, for a local
  `./` call, the caller's own commit
  (on `pull_request` the PR's merge commit, so a PR that edits a script runs its edit, as it runs an edited caller).
  Comment runs always use the default branch's workflow. No PR, comment or Claude text reaches a `run:` through `${{ }}`; it goes through files and env vars. The
  mode is a fixed `startsWith()` test, and the comment text never reaches Claude.
- **Claude posts nothing.** Its tools are `Read`, `Grep`, `Glob` and `Agent` and nothing else (`--tools`: no shell, web,
  write or edit tool, no MCP server), in a session that refuses whatever no rule allows (`--permission-mode dontAsk`).
  Reads are allowed in the checkout (not its `.git`) and the review folder only, by allow rules in `reviewer/run.sh`;
  a symlink out of them is refused too (checked on the pinned CLI: Read resolves the link, Grep does not follow it). Hooks are off (`disableAllHooks`).
- **Claude gets no GitHub token.** The run step holds only the Claude credential, and Claude runs under `env -i` with
  `PATH`, `HOME`, a fresh `CLAUDE_CONFIG_DIR` and that credential. The credential is the one secret it can read
  (as before: it is in the process's environment). The Claude Code package is the version in `reviewer/package.json`,
  installed from its lockfile (an integrity hash per package; `npm ci` runs its install script, in a step that holds
  no secret). Dependabot bumps it.
- **Only the kit configures the reviewer.** The session starts in a copy of `reviewer/` taken from the commit of the
  workflow file, outside the PR's workspace. Its `CLAUDE.md` is the only memory file that loads; the PR's `CLAUDE.md`
  files, `.claude/` settings, agents, skills and commands do not (checked with a canary PR on the pinned CLI: the
  lead and a subagent read a root and a nested `CLAUDE.md` under the checkout, and neither loaded). The checkout is deliberately not added with
  `--add-dir`: an added folder contributes its `.claude/agents` and skills, so a PR could replace the subagents'
  instructions (checked with a canary PR on the pinned CLI). **Never deny the runner's work dir.**
- **`publish` treats Claude's result as untrusted:** it checks the shape, posts findings only on lines of the PR's
  own files, strips HTML comments and markers, escapes links, images, HTML, mentions and bare URLs, breaks
  cross-repo references, and keeps code spans and fences. The overview paragraph and thread replies are plain text.
- **The caller maps the credentials and sets the ceiling.** A caller passes the two declared secrets by name, never
  `secrets: inherit`. Every kit job declares its own `permissions:` inside the caller's ceiling (a test fails one that
  declares none: it would inherit the whole ceiling).
- **The App key and tokens live only in `appcheck` and `publish`** (GitHub-hosted by default, or the runners of
  `SELF_HOSTED_REVIEW`, prerequisite 2). No expression in `preflight` or `review` names the key, so neither job's
  runner receives it. With the variable set, all four jobs share one pool, so the key reaches runners where Claude
  reads PR text: the owner's choice, in the residual risk below. There, a kept workspace can still hold a PR tree an
  earlier job left, so `publish` refuses a `.claude-review-kit` that is a symlink before it checks the kit out (a
  folder is its own from an earlier run, cleaned in place). The App has Pull requests: write only; `publish`'s
  `GITHUB_TOKEN` has `contents: write` for resolving threads only. `publish` resolves a thread only if
  the review started it, it is on this PR and open, and its last comment is this workflow's `verdict=resolved` marker
  for the reviewed commit.
- **Fork PRs never get the secrets:** a `pull_request` run from a fork is skipped, and a comment run needs write
  access and runs the default branch's workflow.
- **Pinned actions** (full commit SHAs): `actions/checkout` v7.0.1, `actions/setup-node` v7.1.0,
  `actions/upload-artifact` v7.0.2, `actions/download-artifact` v8.0.2, `actions/create-github-app-token` v3.3.0.
  Bump deliberately, in the kit; callers pick it up when it merges.
- **Residual risk (accepted under a sole-pusher assumption):** a same-repo PR can edit the workflow and so read the
  App key (one App per owner: the key reaches every repo it is installed on; one key per repo limits rotation, not
  reach, and the same PR can target any runner; the pool's rules limit who can reach the pool, not what the workflow
  runs there; and a pool shared by several repos carries over between them, because code a PR runs there can leave
  something in the runner's install directory for a later job of another repo, accepted only while every repo that
  reaches the pool is private with the same single writer: give a repo with a second writer its own pool, or unset the
  variable); with `SELF_HOSTED_REVIEW` set, the key jobs share runners with `review` (and with CI, where the pool runs
  it), so code that gets to run there (a PR's CI job, a Dependabot PR's CI job, a compromised package in the review's
  install, or a tool escape steered by PR text) can leave something that reads the key in a later job, and only the
  first of those is bounded by the sole-pusher assumption (the owner's choice, prerequisite 2); a self-hosted runner shared with CI jobs
  that run PR code can carry planted files into a review; a prompt
  injection in the PR can steer misleading findings, a wrong "resolved", a "no issues" (which becomes an APPROVE),
  or a committable suggestion. All
  visible and attributed to the App; the verdict is never a required review. The private-data pass is a model's
  judgement: it can miss a name, and an injection can talk it out of a finding.

## Known limitations

- **Cross-path bugs are missed:** new code whose assumption is broken by another path, often an unchanged line.
- **The pipeline is cut short** (0–6 agents instead of the expected 7, seen on most v2.x live runs, 2026-10-23/24; v3.1 expects at least 8): the warning detects
  it; nothing prevents it yet, and a review that ran no agent can still APPROVE.
- **A follow-up reads no new code:** after `--comments` dismisses the REQUEST_CHANGES, code pushed since the last full
  review (a new bug, or a fixed one brought back) is unreviewed until the next `@claude review`.
- **A follow-up keeps the last full review's overview paragraph,** which can describe findings that are now fixed.
- **A follow-up doesn't re-check findings that sit in a review body:** it judges threads only, and a finding that
  could not go inline has none.
- **A failed dismissal of the App's approval is not retried by a re-run:** when a review with findings is posted as a
  COMMENT (`changes-event: COMMENT`) and dismissing the earlier approval fails (403), the job fails and the findings
  are posted, but the re-run stops at that review. Dismiss the approval from the PR's review list.
- **A re-run that finds its review does not update the overview:** when a failure after the review (the link, the
  thread recount) or a resolve that finished in the re-run changed the state, the overview and the review keep what
  they said until the next request.
- **A failure right after the approval can leave it standing on newer code:** when a push lands while the approval is
  being posted and the head re-read or the dismissal then fails (or a 5xx on submit hides a review that did land), the
  job fails, but the overview already says clean and a re-run stops at the review. Check the approval against the
  head; `@claude review` reviews it again.
- **A body finding's heading shows Claude's line number** even when its line text didn't match.
- **A PR reviewed by v2.3 or earlier is reviewed again:** `collect` and `publish` trust only the App's threads, replies
  and overview, so a `claude[bot]` thread or a `github-actions[bot]` summary covers nothing. The `preflight` and `review`
  gates still count those authors, so an automatic review of such a PR is skipped; ask with `@claude review`.

## Upkeep

- Keep the cost record's `reviewer` string (`claude-pr-review@v4.9`) equal to the version above (a test checks).
- Run `tests/` after any change to `collect.py`, `publish.py` or `reviewer/`.
- Claude Code's version is `reviewer/package.json`'s, bumped by Dependabot's `npm` entry. Check a bump PR with a
  replay (`replay/replay.py`) before it merges: the flags in `reviewer/run.sh` are the CLI's, and a version can drop one
  (`--permission-mode default` is no longer listed as of 2.1.328).
- `REVIEW.md` (repo root) is the repo's own file, not part of the kit: edit it freely.
- A change to the review, the command included, goes in the reusable kit. A repo on the reusable kit picks it up when
  it merges.
