# 13. App-Owned PR Review, Verdict as a Signal

**Status:** accepted
**Date:** 2026-10-23
**Amended:** 2026-11-10 (the key jobs may run on a dedicated runner pool)

The toolkit ships this review as a kit, `tools/claude-review/`, and this repo runs its own copy of it.

The automatic Claude PR review (`.github/workflows/claude-review.yml`) posts as a per-owner GitHub App, and that App
submits APPROVE / REQUEST_CHANGES reviews as a signal. It replaced an earlier, unrecorded approach that posted a
closing comment instead of a review.

## Context

Originally, Claude posted its inline findings itself (`claude[bot]`, through the Claude GitHub App's token), while the
workflow posted the "No issues found" summary and thread replies as `github-actions[bot]` and resolved threads in a
separate job. Three problems followed:
- **Two identities, no verdict.** Findings and replies came from different bots, and nothing on the PR said "this
  passed" or "this needs changes" in GitHub's own terms.
- **Approving was refused** because the only identity that could approve was `github-actions[bot]`, which needs the
  repo-wide "Allow GitHub Actions to create and approve pull requests" setting: every workflow in the repo could then
  approve.
- **Claude held a posting tool,** so a prompt injection in the PR could post whatever it steered Claude to write, with
  only Claude's own restraint between the PR's text and the comment.

## Options Considered

- **Who posts.**
  - Claude, as today: keeps a posting tool in the model's hands.
  - `github-actions[bot]` for everything: needs the repo-wide approve setting to give a verdict.
  - **A GitHub App per owner: chosen.** It has its own identity, Pull requests: write only (no Contents), and approves
    without any repo-wide setting. One App per owner (a personal account, a client's organization), configured per
    repo by two variables and a private-key secret.
- **Fallback when the App isn't configured.** Falling back to `GITHUB_TOKEN` keeps two code paths and a quiet
  degradation. **Rejected: the App is required,** and missing config fails before Claude runs, with a named error.
- **Verdict.** None (the previous version); a COMMENT only; **APPROVE / REQUEST_CHANGES decided by the workflow
  from Claude's result: chosen**, as a signal only. The App's review must never satisfy a required review (repos
  scope required reviews to people, or set `CHANGES_EVENT`/`APPROVE_EVENT` to COMMENT).
- **Where the key lives.** **Only in the `appcheck` and `publish` jobs;** the `review` job that runs Claude never sees
  it. Those two jobs run on GitHub-hosted runners by default. A repo may point them at a dedicated self-hosted pool
  instead (the repo variable `CLAUDE_REVIEW_KEY_RUNS_ON`, a JSON label array; unset means GitHub-hosted), to stop
  paying hosted minutes on a private repo. The pool is an option, described only by what it must be:
  - it runs only `appcheck` and `publish`: no PR code, no checkout, no CI or deploy jobs;
  - it holds no deploy key and no other long-lived secret on the host. Its own runner-registration credential (for
    example a PAT or a registration App) is a different thing from the reviewer App's key, which arrives per job as
    the repo secret; it is read only by the runner's start-up and never reaches a job's environment or a path the
    job's user can read;
  - it is not shared with the runners that run `preflight`/`review` or CI, and it has no route to internal networks
    or services beyond what the jobs need;
  - only private repos can reach it, never a public repo (the variable is set at repository scope, never
    organisation scope);
  - a runner that is restarted and re-registered for each job, with its work and temp directories wiped, is
    recommended. That does not make the machine clean (the runner's install directory stays writable by the job's
    user), so the controls that matter are that only private repos reach the pool and that only `appcheck` and
    `publish` run there;
  - the outbound hosts it needs (github.com, api.github.com and the Actions and artifact service hosts) are what the
    jobs need, not a control: self-hosted egress allow-lists are often not enforced.

## Decision

Claude returns findings, thread verdicts and a short overview as structured data and posts nothing. A
`publish` job, on GitHub-hosted runners by default or on the dedicated pool above, validates and sanitizes that
result and posts everything as the App: inline findings (or the review
body when a line isn't in the diff), thread replies, one sticky overview comment edited on every run, and the review.
The workflow, never Claude, decides the verdict: findings or an open thread → REQUEST_CHANGES; a full review with no
findings and no open thread → APPROVE; a follow-up that clears every thread → the App dismisses its own
REQUEST_CHANGES and posts a COMMENT. A push dismisses the App's approval of an older commit.

## Consequences

- **Accepted residual:** a same-repo PR can change the workflow and read the App key (the key reaches every repo the
  owner's App is installed on). Accepted because these repos have one pusher, or a second author with the same access.
- A prompt injection can still steer a misleading finding or a "no issues" that becomes an APPROVE; it can no longer
  post arbitrary text, since `publish` strips links, images, HTML and mentions and posts only on the PR's own lines.
- The Claude GitHub App is no longer needed; while installed it still reacts to `@claude` comments.
- On GitHub-hosted runners, about two billed Actions minutes per review on a private repo (`appcheck`, `publish`),
  plus one per push to a reviewed PR for the dismissal check. A pool removes them.
- A pool moves the App key onto machines the owner runs. The residual above holds, but its blast radius moves: a
  same-repo PR that edits the workflow could already read the key, and can now also target the pool and run code on
  a persistent host. That is why the pool rule is about who can reach the pool and what the host can reach, not about
  the workflow. Publish still validates and sanitizes, the App still has Pull requests: write only, and the
  workflow, never Claude, still decides the verdict.
- **Accepted limit of a shared pool:** a pool that serves several repos carries over between them. A PR that edits the
  workflow in one repo can run its own code on a pool runner and leave something in the runner's install directory,
  which the start-up wipe does not cover; a later `appcheck` or `publish` job for another repo, holding that repo's
  App key and token, then runs with it. Accepted only while every repo that reaches the pool is private and has the
  same single writer. Revisit when any repo that reaches the pool gets a second writer, or a pool runner is not
  wiped per job: then use a pool per repo, or GitHub-hosted runners for that repo (unset the variable).
- Unverified: whether a bot REQUEST_CHANGES blocks merging under a ruleset with zero required approvals; check before
  rollout in a new repo.
