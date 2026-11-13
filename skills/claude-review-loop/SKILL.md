---
name: claude-review-loop
description: Answer the automatic Claude review on a PR in a repo with `.github/workflows/claude-review.yml` (the toolkit's Claude review kit) — open it as a draft, wait for CI before marking it ready, then read the findings, fix or reply, and ask for the follow-up run. Load before you open a PR there, mark one ready for review, push review fixes, or are asked to handle its review. Not needed in a repo without that workflow.
---

# Claude review loop

Applies only in a repo with `.github/workflows/claude-review.yml` (the toolkit's Claude review kit); elsewhere it is a
no-op. A PR you open there is not ready for the user until its Claude review has finished and been answered.

All reads and posts go through the github MCP (`gh` is blocked for agents, `rules/security.md`); where the guard
denies a post, give the user the `gh` command in a markdown code block instead.

1. Open the PR as a draft (`create_pull_request` with `draft: true`). The review runs once, when the PR is marked
   ready, so a CI fix pushed after that means it saw broken or stale code. CI runs on drafts: poll
   `pull_request_read` with `get_check_runs` every few minutes until every check outside the Claude review workflow
   (CI, the secret scan, CodeQL) has concluded `success` on the current head. Fix a failure on the branch while it is
   still a draft, then wait again. Only then mark it ready (`update_pull_request` with `draft: false`; the guard asks
   first, because it starts the paid run). If a required check stays queued for a long time, or a failure is outside
   the PR's scope, tell the user instead of marking it ready.
2. Wait for the review (the runner may be queued): poll `pull_request_read` with `get_check_runs` every few minutes,
   until the `Publish the review` run completes (`Review PR` posts nothing; `publish` posts the findings). It must
   conclude `success`: `skipped` means no review ran, so tell the user.
3. Read the findings with `pull_request_read`: the reviewer App's inline comments (`get_review_comments`), the
   review body's "Not on a changed line" section (`get_reviews`) and the overview comment (`get_comments`, the one
   starting `<!-- claude-review:summary`). The App posts APPROVE or REQUEST_CHANGES. A review that did not finish
   shows "No verdict" in the overview comment, or posts nothing at all for the head (a green `Publish the review`
   with no App review and no overview for it). Silence is never "no findings": tell the user. After a "No verdict"
   overview only a new full review runs it again; after nothing at all, the next push is reviewed afresh only if the
   App has never commented on the PR; otherwise ask the user.
4. Fix each finding on the branch, or reply in its thread (`add_reply_to_pull_request_comment`) with why it isn't a
   bug. A finding in the review body has no thread: fix it and say so in the handover.
5. Pushes after the first review are skipped, so after pushing fixes or replies, comment
   `@claude review --comments` on the PR (`add_issue_comment`, top level, cheap; the guard asks first because a
   `@claude` comment starts a paid run): Claude judges each open thread against the new code, replies, and resolves
   the fixed ones. Wait until no review is running before you post (GitHub keeps one waiting run per PR, so an early
   request can replace another). The comment starts its own run, on the `issue_comment` event: wait for that run,
   not the checks of the last push, then handle any thread it keeps open. List the findings and their outcome in the
   handover.
6. A full `@claude review` (a whole re-review, about the cost of the first) only when the user asks. A PR that
   changes that workflow file runs its own copy, so install and upgrade PRs use `[skip ci]`: review those locally.

Details: the toolkit's `tools/claude-review/README.md`, "For agents opening PRs".
