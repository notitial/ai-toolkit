# 16. Guarded Issue, Label and Project Writes

**Status:** accepted
**Date:** 2026-11-08

## Context

Agents planning work need to file issues, split them into sub-issues, label them and put them on a GitHub Project
board. The guarded github MCP server (`tools/github-mcp/`, ADR 0014 for where it runs) exposed PR, comment and Actions
writes only, and the permission template denied `issue_write`, `sub_issue_write` and `label_write` by name.

The pinned server, v2.0.3, offers these writes in two shapes:

- **Bundled tools** (`issue_write`, `sub_issue_write`, `label_write`, `projects_write`): one tool per area, with the
  operation in a `method` argument. `--tools` can switch them on.
- **Per-field tools** (`create_issue`, `update_issue_state` and the rest): one tool per change, which name rules could
  split. They sit behind the `issues_granular` feature flag, which `--tools` does not switch on.

A Project belongs to a user or an organization, not to a repo, so the guard's owner/repo check does not fit it as it
stands. The token is a classic PAT with the `repo` scope; Projects need the `project` scope as well.

## Options Considered

- **Per-field tools with name rules:** simpler rules, but they need a feature flag, an extra launcher input that
  changes what the server exposes. Rejected.
- **Bundled tools, judged by the guard per method and argument: chosen.** It is the pattern the guard already uses for
  `actions_run_trigger` and `update_pull_request`.
- **A fine-grained token owned by the Project's organization:** narrower, but a fine-grained token has a single
  resource owner, so it would cut off every other write owner. A second token needs a second server, under a name the
  guard does not cover. Rejected; the classic PAT gains the `project` scope instead.
- **Project scope from the write owners alone:** no new setting, but every Project of every write owner would be
  writable without a prompt. Rejected in favour of a list.

## Decision

- `launch` exposes `issue_write`, `sub_issue_write`, `label_write` and `projects_write`, plus the reads `list_label`,
  `projects_list` and `projects_get`. The template allows the reads and lists the writes nowhere, so the guard decides
  them, as it does for the PR and comment writes.
- The guard allows the everyday writes in the write-owner repos: creating and editing an issue, adding and reordering
  sub-issues, creating and updating labels. It asks on what is hard to see or undo: a state change (the same call
  closes PRs), assignees (assigning Copilot starts a paid run), `@claude`, removing or moving a sub-issue, and deleting
  a label. It denies unknown methods, unknown arguments and values of the wrong type.
- Project writes need the Project in a new optional install setting, `github_projects` (`<owner>/<number>` entries in
  `~/.claude/install.conf`, read on every call), under a write owner. One item added or updated and a status update
  are allowed there. A Project not listed, a bulk update, deletes, view and field changes, and a new Project ask. An
  owner outside the write owners denies.
- The token is a classic PAT with the `repo` and `project` scopes.

## Consequences

- Agents can keep issues, labels and the listed Projects up to date without a prompt. The prompts that remain are
  the changes that close, delete, notify, cost money or touch many items at once.
- Issue, label and Project item text from any GitHub user reaches the agent, and now leads to silent writes. What an
  injected agent can do without a prompt is noise: issues, labels and items it can add or edit, all visible and all
  undoable. Residuals in `tools/github-mcp/README.md`.
- The `project` scope reads every Project the user can reach; only writes are limited.
- A sub-issue or Project item named by its id can't be traced to a repo, so an allowed add can link an issue from
  outside the write owners.
- Without the hook, the four writes fall back to the default prompt with no argument limits, like
  `update_pull_request`.
- A settings file merged from an earlier template keeps the three name denies until the user removes them by hand;
  until then those tools stay denied.
- A server upgrade has to re-read these four tools' snapshots for new methods and arguments, which the guard denies
  until reviewed.
