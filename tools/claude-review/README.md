# claude-review

An automatic Claude code review for GitHub pull requests, owned by a GitHub App. Claude reads the PR and returns its
findings, thread verdicts and a short overview as data; it has no shell, web, write or posting tool. The workflow
checks that result and posts all of it as the repo's **reviewer App**: inline findings, thread replies, one overview
comment edited on every run, and an APPROVE or REQUEST_CHANGES review. Nothing is posted as `claude[bot]` or
`github-actions[bot]`.

The two files in this folder are the **canonical copies**. Every repo that uses the review copies them byte for byte
and changes only the lines listed in [Replacement points](#replacement-points). This repo runs the review itself, from
copies equal to these (`tests/test_install.py` checks).

| File | Install path in the target repo | SHA-256 |
|---|---|---|
| [claude-review.yml](claude-review.yml) | `.github/workflows/claude-review.yml` | `11c526b5d9d347ee96141b76523ce6e9bf530acb1114389f35b64968433d2cb2` |
| [claude-pr-review.md](claude-pr-review.md) | `.claude/commands/claude-pr-review.md` | `7b96973af49215e0ab073d305df5651d996ca7ba90ccbb0c9533e40a4d5b8137` |

**Version:** v3.1 (2026-11-05): a sixth review pass flags private data (credentials, people, clients, private ticket
keys, hosts and home paths, ignored folders) in the lines a PR adds and in its title and description, and the review
is told never to repeat the value. v3.0 (2026-11-04): a new review command, written from the kit's interface alone. It keeps v2.5's result
format and modes, and an incomplete review now posts no verdict instead of approving. v2.5 (2026-10-24): a full
`@claude review` reopens the thread of a fixed finding whose issue is back, instead of dropping it and approving.
v2.4 (2026-10-23) made the review App-owned. v2.4 and v2.5 were tested end to end on a throwaway repo with
`ubuntu-latest` runners; the v3.x command has had no live run yet (run the [Test protocol](#test-protocol) before
relying on it). The [tests/](tests/) folder runs the workflow's inline scripts against a fake
GitHub: `python3 -I -B -m unittest discover -s tools/claude-review/tests` from the repo root (`bash tools/test-all.sh
claude-review` runs the same).

## What it does

Four jobs:
- **`preflight`** (`ubuntu-latest`, or your own runner): skips fork PRs with a notice, checks the App variables are
  set, checks the commenter has write access, applies the once-per-PR gate. Its `GITHUB_TOKEN` is read-only. Only if
  it passes does the rest run.
- **`appcheck`** (`ubuntu-latest`): mints an App token and throws it away, so a bad key, a missing install or a wrong
  `CLAUDE_REVIEW_APP_LOGIN` fails before Claude costs anything. On a comment request it reacts 🚀 as the App (since
  v2.5; a 👀 from claude[bot] means the Claude GitHub App is still installed on the repo, which nothing here needs).
- **`review`** (`ubuntu-latest`, or your own runner): fetches the PR, runs Claude read-only (its `GITHUB_TOKEN` is
  read-only), uploads the result as an artifact. One at a time per PR, never cancelled.
- **`publish`** (`ubuntu-latest`, no checkout, no Claude): posts as the App, in this order: thread replies, resolve,
  the overview comment, the review. On a push to a same-repo PR it also dismisses the App's approval of an older
  commit. Re-running it never posts a second review (every review body has a run marker).

On a private repo, `appcheck` and `publish` are about two billed Actions minutes per review (more when `preflight`
and `review` run on GitHub-hosted runners too), and `publish` runs (one minute) on every push to a reviewed PR for the
dismissal check. Public repos don't pay for GitHub-hosted minutes.

Three modes:

| Trigger | Mode | What happens | Typical cost |
|---|---|---|---|
| A non-draft same-repo PR is opened, pushed to, reopened or marked ready, and has no review yet (Dependabot and forks skipped) | `initial` | Full review: a triage and a guidance agent, six review passes (defects in the change, interaction with the code around it, security, failure paths, written CLAUDE.md rules, private data), then one verifier per candidate. Up to 8 findings, inline on their lines (else in the review body), REQUEST_CHANGES; or APPROVE with "No issues found" | $0.5–2 on real feature PRs ($0.18–0.33 on small test PRs), measured before v3.1's sixth pass |
| A push to a PR that was already reviewed | none | `preflight` skips; Claude doesn't run. `publish` dismisses a stale APPROVE | $0 |
| A comment starting `@claude review`, from someone with write access | `rereview` | Judges each open review thread, replies, resolves the fixed ones, then reviews the whole PR again (drafts too) without repeating raised issues. A fixed issue that is back reopens its old thread with a "Regressed:" reply (a new finding if the thread can't be reopened); only a thread this review resolved at an earlier commit, so a person's resolve, or one Claude accepted as not a bug, stays. APPROVE when nothing is found and no thread is open | about `initial` |
| A comment starting `@claude review --comments` | `followup` | The thread follow-up only: new code, and a fixed issue that came back, aren't seen. When every thread is resolved, the App dismisses its REQUEST_CHANGES and posts a COMMENT "Findings addressed; new code was not re-reviewed." | $0.04–0.25 |
| `--comments` again with no push and no new thread reply | none | One follow-up per branch state; Claude doesn't run | $0 |
| `@claude review` again with no push and no new thread reply | `rereview` or none | Skipped when every open thread already has a rereview reply for this head or, with no open thread, when this head already has a clean overview | $0 or about `initial` |

- **A stopped run:** an `initial` review of a PR with nothing to review (an automated bump, a trivial change) stops
  early; the overview says "Review stopped (eligibility)" and there is no verdict.
- **The overview comment:** one issue comment from the App, edited on every run. It shows the head, the mode, the
  result (`clean`, `issues`, `stopped` or `followup`) with numbered links to the findings, Claude's 2–3 sentence
  overview, the open threads with links, and the last 10 runs.
- **The verdict is a signal.** `publish` decides it from Claude's result, never Claude: findings or an open thread →
  REQUEST_CHANGES; a full review with no findings and no open thread → APPROVE; a follow-up that leaves no thread
  open → COMMENT (after dismissing the App's REQUEST_CHANGES). It submits only when the verdict changes.
- **Findings without a thread** (in the review body, because their line isn't in the diff) aren't judged by a
  follow-up. The follow-up says so ("N findings without a review thread weren't re-checked"); a full
  `@claude review` checks them.
- **Requests are top-level PR comments.** `@claude review` typed as a reply inside a review thread triggers
  nothing.
- **Reports:** code that won't build, parse or load, logic wrong for every input, bugs with a concrete reachable
  trigger, security issues and unhandled error paths in the changed code, clear breaks of a quoted CLAUDE.md rule.
- **An incomplete review gives no verdict:** when a review pass or a verifier fails twice, the result carries the
  verified findings only, and with none `publish` rejects it, so a review that reports itself unfinished never approves. A
  review that cut the pipeline short without saying so still can (Known limitations).
- **Doesn't report:** style, nitpicks, pre-existing issues, what the compiler or linter catches, test coverage, docs.
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
(default `/tmp/review-replay`), restores `.claude/` and the root `CLAUDE.md` from `--base` as the workflow does,
installs the command, and runs `claude -p` with the workflow's own `--disallowedTools`, `TOOLS` and result schema,
read from `claude-review.yml` so they cannot drift. Each run is one full review: use the subscription outside a busy
window and run PRs one after the other.

```text
python3 -I -B tools/claude-review/replay/replay.py --repo OWNER/NAME --pr N --base BASE_SHA --head HEAD_SHA \
  [--verifier-model sonnet] [--arm NAME] [--run K] [--title T] [--body-file F] [--command FILE] [--model M] [--prepare-only]
```

- `--verifier-model` rewrites the 7.4 line for the defect, interaction, security and failure-path verifiers in a temp
  copy of the command; the run fails if the line has changed, so a reworded command cannot run the unpatched arm.
- Results go to `~/review-replay-results/<owner_name>/pr<N>-<head8>-<arm>-<run>.json` (the result, `total_cost_usd`,
  per-model cost, duration, turns, agent count by requested model) plus the gzipped stream next to it. Nothing is
  written in the repo.
- Differences from CI: the PR title and description are placeholders unless given, the lead model is the CLI's
  default for the account, and the review runs on your machine's `claude` version, not the pinned action's.

`tests/test_replay.py` covers the parts that do not call claude.

## REVIEW.md (the owner's review brief)

A repo can put a `REVIEW.md` at its root. The review command looks for it, and when it exists hands its path to every
review agent, which reads it first. It is written by the repo owner and kept apart from CLAUDE.md: CLAUDE.md says how
to work in the repo, REVIEW.md says what the reviewer should hunt for and what to leave alone. Without one, nothing
changes.

What goes in it (this repo's own, `REVIEW.md` at the repo root, is the worked example):
- **Failure modes to hunt:** the repo's recurring bugs, by area, each concrete enough to check against a diff.
- **A nit cap:** the most findings to return (never more than the workflow's 8), and what never to report.
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
- The command is read from `main` (`.claude/` is restored from main on every run), so a command change takes effect
  once it has landed; a `REVIEW.md` added in the same PR is not read by that PR's own review.

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

## Adding it to a repo

The `/add-claude-review` skill (installed by `/setup-claude`) does the steps below from the target repo.

### Prerequisites

1. **Runner** for `preflight` and `review`: `ubuntu-latest` (the canonical value), or a self-hosted label set.
   - Tested on self-hosted Linux runners (v2.3) and `ubuntu-latest` (v2.4).
   - A self-hosted runner needs at least 2G of memory; `gh`, `jq`, `git` and `python3` ≥ 3.8 on `PATH`; and outbound
     HTTPS to github.com, api.anthropic.com and claude.ai. Never a runner that holds a deploy key. The App key never
     reaches it.
   - On a **public repo**, keep `ubuntu-latest`. GitHub recommends self-hosted runners for private repos only,
     since a pull request from a fork of a public repo can run its own code on them.
2. **GitHub-hosted runners allowed** for the repo: `appcheck` and `publish` always run on `ubuntu-latest` (they hold
   the App key and tokens).
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
   gh secret set <CLAUDE SECRET NAME> -R <owner/repo>
   ```
   Then delete the downloaded `.pem`, or keep it only in a password manager. The workflow must reference no other
   secret. Pick a Claude secret name nothing else uses (a repo with a production `ANTHROPIC_API_KEY` uses e.g.
   `CLAUDE_REVIEW_API_KEY`).

   Also turn on **"Always suggest updating pull request branches"** (repo Settings → General → Pull Requests; API
   field `allow_update_branch`). It is off by default, with no org-level switch. Without it a PR that has fallen
   behind `main` shows no Update branch button, and the workflow, which checks out `refs/pull/<N>/head`, can fail on
   a missing ref until the branch is updated. Update a stale branch by merging `main` into it, never by rebasing
   (`rules/workflow.md`, Stale PR Branches).
5. **The Claude GitHub App is not needed.** If it is installed on the repo, it still reacts 👀 to every `@claude`
   comment (its own mention handling): remove the repo from its installation.
6. **Required reviews:** the App's review must never satisfy one. Scope required reviews to people or teams, or set
   `CHANGES_EVENT` and `APPROVE_EVENT` in `publish` to `COMMENT` (a replacement point, below).
7. **Org repos:** an org owner may have blocked GitHub-hosted runners or restricted workflow permissions; then
   `appcheck` or `publish` never starts, and no review is posted.
8. **Recommended:** a "Review" section in the root `CLAUDE.md` listing quotable rules. The CLAUDE.md agents flag only
   clear breaks of quotable rules.

### Replacement points

Change only these lines of `claude-review.yml`. Everything else, `claude-pr-review.md` included, stays byte-identical.

| Line | Canonical | Replace with |
|---|---|---|
| 48 | `#   secret    ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN   Claude credential (...)` (2 lines) | the Claude secret names and what they are |
| 106 (`preflight`) | `    runs-on: ubuntu-latest` | the repo's runner labels, if not GitHub-hosted |
| 236 (`review`) | `    runs-on: ubuntu-latest` | the same labels |
| 497 (+1) | `anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}` and the `claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}` line under it | the one line for the chosen credential, with its secret name (what `/add-claude-review` does), or both lines with the repo's names |

Optional, only for a repo whose required reviews could count the App: lines 644–645 (`CHANGES_EVENT`,
`APPROVE_EVENT`) → `COMMENT`. Never change `appcheck`'s and `publish`'s `runs-on: ubuntu-latest` (lines 194, 636). A
diff against the canonical file must show only these lines; check it and both SHAs before merging.

**Auth options:** the default passes both inputs, so the credential is whichever org or repo secret exists; switch
between them by changing which secret is set, with no workflow edit.
- **API key** (tested): a Claude Console key in `ANTHROPIC_API_KEY`, passed as `anthropic_api_key:`.
- **Subscription OAuth token** (tested, as the only input): the token made by `claude setup-token` in
  `CLAUDE_CODE_OAUTH_TOKEN`, passed as `claude_code_oauth_token:`. The cost line still reports `total_cost_usd`, but
  on a subscription that figure is notional: usage counts against the account's limits, shared with its interactive
  sessions, and when the limit is reached the review fails in under a second with "did not return
  structured_output". The token is a personal credential, usually long-lived: revoke it from the Claude account and
  mint a new one to rotate.
- Unverified: that the action accepts both inputs when one secret is empty or absent. If it rejects that, keep only
  the line for the secret that exists.

### Steps

1. Branch from the default branch.
2. Copy both files to their install paths, check their SHAs, then apply the replacements.
3. Commit both in one PR. The action restores `.claude/` from the default branch, so the command only works once it
   is there: the two must land together. Add `[skip ci]` to the commit message so the PR doesn't run its own copy,
   unless the repo's ruleset requires status checks from other workflows (see Quirks): `[skip ci]` would stop them
   from reporting and the PR could not merge.
4. Check the target repo's `.claude/settings.json` (loaded by `--setting-sources project`): `permissions.allow`
   rules, `additionalDirectories` and `defaultMode` can widen what Claude reads in the review (hooks are off), and
   `enableAllProjectMcpServers` or `enabledMcpjsonServers` would let a `.mcp.json` the PR adds start a server: keep
   them out.
5. Review the PR locally (code-reviewer, plus security-auditor), checking the SHAs and the replacement diff.
6. (user) Merge, then run the test protocol.

## For agents opening PRs

In a repo with the review, a PR isn't ready for the user until its review has finished and been answered. Agents
read and post through the GitHub MCP server (`gh` is blocked for agents by `hooks/gh-block.sh`); where its guard
denies a post, give the user the `gh` command instead.

1. A draft isn't reviewed until it is marked ready for review, which starts a paid run. Wait for the checks (the runner
   may be queued): poll `pull_request_read` with `get_check_runs` every few minutes, until the `Publish the review` run
   completes (about 1–2 minutes once a runner picks it up). It must conclude `success`: `skipped` means no review ran,
   so tell the user.
2. Read the findings with `pull_request_read`: the App's inline comments (`get_review_comments`), the review body's
   "Not on a changed line" section (`get_reviews`), and the overview comment (`get_comments`, the one starting
   `<!-- claude-review:summary`). A review that did not finish shows "No verdict" in the overview comment, or posts
   nothing at all for the head (a green `Publish the review` with no App review and no overview for it). Silence is never
   "no findings": tell the user. After a "No verdict" overview only a new full review runs it again; after nothing at
   all, the next push is reviewed afresh only if the App has never commented on the PR; otherwise ask the user.
3. Fix each finding, or reply in its thread (`add_reply_to_pull_request_comment`) with why it isn't a bug.
4. Pushes after the first review are skipped. After pushing fixes or replies, and once no review is running, comment
   `@claude review --comments` (`add_issue_comment`, top level): it judges the open threads, replies and resolves
   the fixed ones. Wait for that run, handle any thread it keeps open, and report the findings and their outcome in
   the handover. A finding in the review body has no thread: fix it and say so in the handover (only a full review
   re-checks it).
5. Ask the user before a full `@claude review`.

## Test protocol

Use a throwaway PR. Each run's job summary shows
`Claude review (<mode>): $<cost>, <s> s, <turns> turns, <a> agents, <n> findings, <t> threads judged` and
`Publish: <i> inline, <b> in body, <d> dropped, <m> moved, verdict <X>, <r> replied, <s> resolved, <o> reopened, <x> dismissed, …`.
`<a>` is at least 8 in `initial` and `rereview`, plus one per candidate issue (and the thread judges in `rereview`); below that the step warns.

| # | Do | Pass when |
|---|---|---|
| 1 | Open a clean PR (non-draft) | APPROVE from the App, overview `result=clean`; nothing from `claude[bot]` or `github-actions[bot]` |
| 2 | Push a commit | `preflight` logs `Already reviewed: skipping`; `publish` dismisses the APPROVE ("New commits since this approval.") |
| 3 | Open a PR with real bugs | Inline findings on the right lines, one REQUEST_CHANGES, the overview links each finding |
| 4 | Push fixes, then comment `@claude review --comments` | App replies in each thread, threads resolved, the same overview comment edited (`result=followup`), REQUEST_CHANGES dismissed + COMMENT "Findings addressed…" |
| 5 | Comment `@claude review` | `rereview`, APPROVE, overview history shows 3 runs |
| 6 | Re-run `publish` of any run | "verdict already submitted"; no second review; the history entry is replaced |
| 7 | Unset `CLAUDE_REVIEW_APP_CLIENT_ID`, comment `@claude review --comments`, set it back | `preflight` fails with "Missing: variable CLAUDE_REVIEW_APP_CLIENT_ID"; nothing else runs |
| 8 | (if available) someone with read access comments `@claude review` | Fails at "Check the commenter can write to the repo" |
| 9 | On a PR with a resolved finding, push a commit that brings the bug back, comment `@claude review` | The old thread is reopened with an App "Regressed:" reply, `1 reopened` in the publish line, REQUEST_CHANGES, the overview shows a **Regressions:** line; no second thread for the issue |
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
  REQUEST_CHANGES first. If a dismissal fails (403), the overview says "Change request is stale: dismiss it
  manually": dismiss it from the PR's review list.
- **A PR that changes the workflow runs its own copy** (with the Claude key in `review` and the App key in `appcheck`
  and `publish`). Use `[skip ci]` on install and upgrade PRs. Exception: in a repo whose ruleset requires status
  checks from other workflows, `[skip ci]` skips those workflows too, so the required checks never report and the PR
  hangs. Install and upgrade PRs there go without it, and run their own copy of the workflow: review the diff and
  SHAs locally first (step 5), and only the owner pushes.
- **The root CLAUDE.md and `.claude/` are read from the default branch,** never the PR's. A `CLAUDE.md` the PR
  adds or edits elsewhere is reviewed as changed content, never used as rules (see Security model).
- **The transcript is hidden.** Only `show_full_output: true` shows it, which this workflow never sets.
- **Green, nothing posted, "agents still running":** upstream anthropics/claude-code-action#1499. The workflow sets
  `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` for it; remove that once the issue is fixed.
- **Unresolve alone gets re-resolved** by the next request on the same commit. To reopen a thread, reply in it saying
  why it isn't fixed, then unresolve.
- **`the PR moved`:** a push during the run; the result is for older code and isn't posted (a stale approval is
  still dismissed, which can fail the job on a transient API error). Comment again.
- **Two requests for the same head in quick succession** can both review it (posting happens in `publish`, outside
  the `review` queue).
- **A failed review leaves no trace on the PR** except the red check; the overview still shows the previous run.

## Troubleshooting

- **Green but nothing posted:** did `preflight` skip it (already reviewed, fork, draft)? Did "Save the result" warn
  "no structured result"? What does `publish` print ("No verdict: …", "No-op: …")?
- **"No verdict: Claude's result has issues reported without findings":** a review pass or a verifier failed twice,
  so the review didn't finish (the command fails closed). Comment `@claude review` to run it again.
- **Fails in under a second, `$0`, "did not return structured_output":** the Claude credential is out of usage or
  invalid. Re-run the failed jobs once it's back.
- **`appcheck` fails:** the key doesn't match the Client ID, the App isn't installed on the repo, or
  `CLAUDE_REVIEW_APP_LOGIN` isn't the App's slug (the error says which). A key deleted after a review shows up on
  push-only runs as a token-mint failure in `publish`.
- **Every comment run fails at "Couldn't read the commenter's permission":** the job's token can't read
  `GET /repos/<repo>/collaborators/<user>/permission`.
- **"Claude launched N agents; a full review … launches at least M":** the model cut the pipeline short. Findings
  may still be right; note the run id.
- **`N moved` in the publish line:** Claude gave a wrong line number, and the finding's line text put it on the right
  line. A finding whose text matches no single diff line goes to the review body.
- **Permission denials:** `permission_denials_count` in the cost artifact. Never add bare `Read`/`Grep`/`Glob` or
  `gh api` to `--allowedTools`.
- **"GitHub wouldn't give the diff":** the PR is too large for the diff API; Claude reviews from the per-file patches.

## Rollback

Revert the PR (`[skip ci]`). Posted comments, reviews and resolved threads stay; a stale App review can be dismissed
from the PR's review list.

## Security model

Don't loosen any of this when adapting the files.

- **Nothing from the PR checkout executes** in the review steps. Comment runs always use the default branch's
  workflow. No PR, comment or Claude text reaches a `run:` through `${{ }}`; it goes through files and env vars. The
  mode is a fixed `startsWith()` test, and the comment text never reaches Claude.
- **Claude posts nothing.** `Bash`, `WebFetch`, `WebSearch`, `Write`, `Edit`, `NotebookEdit`, `PowerShell`, `Monitor`
  and every GitHub MCP tool are denied, and its `GITHUB_TOKEN` is read-only. Reads are limited to the checkout and
  the review folder; the checkout's `.git`, step-output files, SSH and gh config, `/run/secrets`, `/proc`,
  `/actions-runner` and `/etc` are denied. **Never deny the runner's work dir.** Only the repo's own settings load
  (`--setting-sources project`) and its hooks are off (`disableAllHooks`).
- **`publish` treats Claude's result as untrusted:** it checks the shape, posts findings only on lines of the PR's
  own files, strips HTML comments and markers, escapes links, images, HTML, mentions and bare URLs, breaks
  cross-repo references, and keeps code spans and fences. The overview paragraph and thread replies are plain text.
- **The App key and tokens live only in `appcheck` and `publish`** (GitHub-hosted). No expression in `preflight` or
  `review`, which may run self-hosted, names the key. The App has Pull requests: write only; `publish`'s
  `GITHUB_TOKEN` has `contents: write` for resolving and reopening threads only. `publish` resolves a thread only if
  the review started it, it is on this PR and open, and its last comment is this workflow's `verdict=resolved` marker
  for the reviewed commit. It reopens a thread only in a rereview, only one the review started on this repository's
  PR, that the `review` job collected at the reviewed commit as resolved after this workflow's own
  `verdict=resolved` reply for an earlier commit, and whose last comment is still that reply. Then it posts the
  finding in it as the App; if that reply fails, it resolves the thread back.
- **Fork PRs never get the secrets:** a `pull_request` run from a fork is skipped, and a comment run needs write
  access and runs the default branch's workflow.
- **Pinned actions** (full commit SHAs): `actions/checkout` v7.0.1, `anthropics/claude-code-action` v1.0.252,
  `actions/upload-artifact` v7.0.2, `actions/download-artifact` v8.0.2, `actions/create-github-app-token` v3.3.0.
  Bump deliberately, in every repo.
- **Residual risk (accepted under a sole-pusher assumption):** a same-repo PR can edit the workflow and so read the
  App key (one App per owner: the key reaches every repo it is installed on; one key per repo limits rotation, not
  reach); a self-hosted runner shared with CI jobs that run PR code can carry planted files into a review; a
  `CLAUDE.md` the PR adds or edits in a subdirectory is not used as rules, but Claude Code itself loads it into an
  agent's context when the agent reads files there, so its text can still steer like any other injection; a prompt
  injection in the PR can steer misleading findings, a wrong "resolved", a "no issues" (which becomes an APPROVE),
  a committable suggestion, or the reopening of threads this workflow resolved (never a person's resolve). All
  visible and attributed to the App; the verdict is never a required review. The private-data pass is a model's
  judgement: it can miss a name, and an injection can talk it out of a finding.

## Known limitations

- **Cross-path bugs are missed:** new code whose assumption is broken by another path, often an unchanged line.
- **The pipeline is cut short** (0–6 agents instead of the expected 7, seen on most v2.x live runs, 2026-10-23/24; v3.1 expects at least 8): the warning detects
  it; nothing prevents it yet, and a review that ran no agent can still APPROVE.
- **A follow-up reads no new code:** after `--comments` dismisses the REQUEST_CHANGES, code pushed since the last full
  review (a new bug, or a fixed one brought back) is unreviewed until the next `@claude review`.
- **A follow-up keeps the last full review's overview paragraph,** which can describe findings that are now fixed.
- **Reopens aren't in the overview's history:** a run whose only findings reopened threads shows as "issues" with no
  count.
- **A failed run leaves no trace on the PR** (above).
- **A body finding's heading shows Claude's line number** even when its line text didn't match.
- Legacy authors (`claude[bot]` threads, the `github-actions[bot]` summary) are still trusted by the gates, for PRs
  reviewed by v2.3: remove once no repo using the kit has an open PR reviewed by v2.3.

## Upkeep

- Keep `RESULT_SCHEMA` in the workflow byte-identical with the schema in the command's "The result" section (a test
  checks).
- Keep the cost record's `reviewer` string (`claude-pr-review@v3.1`) equal to the version above (a test checks).
- Run `tests/` after any change to the inline scripts.
- `REVIEW.md` (repo root) is the repo's own file, not part of the kit: edit it freely.
- A new version updates both files here first, with new SHAs in the table above, then this repo's installed copies in
  the same PR (`tests/test_install.py` fails until they match); then every other repo gets a PR.
