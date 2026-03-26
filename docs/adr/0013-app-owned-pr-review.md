# 13. App-Owned PR Review, Verdict as a Signal

**Status:** accepted
**Date:** 2026-10-23

This repo's own review: its setup adds the workflow, and it is not part of the toolkit's shipped files.

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
  it.

## Decision

Claude returns findings, thread verdicts and a short overview as structured data and posts nothing. A GitHub-hosted
`publish` job validates and sanitizes that result and posts everything as the App: inline findings (or the review
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
- About two billed Actions minutes per review on a private repo (`appcheck`, `publish`), plus one per push to a
  reviewed PR for the dismissal check.
- Unverified: whether a bot REQUEST_CHANGES blocks merging under a ruleset with zero required approvals; check before
  rollout in a new repo.
