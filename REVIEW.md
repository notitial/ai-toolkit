# REVIEW.md

The owner's brief for the automatic PR review (`.claude/commands/claude-pr-review.md`). It narrows and directs the
review; it does not replace CLAUDE.md, the finding format or the "concrete, reachable trigger" rule. How the
convention works: `tools/claude-review/README.md`, "REVIEW.md".

## What this repo is

Markdown knowledge base (`docs/`) plus working shell and Python in `hooks/` and `tools/`. The hooks in `hooks/` are
live: `/setup-claude` symlinks `~/.claude/hooks/*` to them, so a merged change runs on the next tool call. Most risk
sits in the guards (`hooks/*-guard.sh`, `secret-detector.sh`, `destructive-blocker.sh`, `gh-block.sh`,
`git-mcp-*.sh`), in `tools/github-mcp/` and in the review workflow (`tools/claude-review/`,
`.github/workflows/claude-review.yml`).

## Failure modes to hunt

In a hook or guard:
- A deny that silently passes: `grep -q` or `head` on the reading end of a pipe under `pipefail` (the writer takes
  SIGPIPE on a match in the first line of a large input), an unset variable under `set -u`, or a missing `jq`, `awk`
  or library that leaves the decision empty instead of denying.
- A bypass the author did not test: the same command behind `sudo`, `env`, `command`, `xargs`, `sh -c`, `eval`, a
  quote, a backslash-newline, an absolute path, a different case, flags in another order, or a separator inside
  quotes.
- A false deny on an ordinary command (a commit message, a `grep` pattern or a `git rm` that only names the
  dangerous text). Name the command.
- Bash 3.2 (macOS `/bin/bash`): `mapfile`, `${v,,}`, associative arrays, `|&`, `&>>`.
- A change to `hooks/<name>.sh` without a case in `tools/<name>/test-<name>.sh` for each new deny and each new pass.

In `docs/`, `rules/`, `agents/`, `skills/`: a statement that contradicts the code or another document (a path, a
flag, a count, a roster entry missing from the README install table). Not wording, except private data.

In the review workflow and `tools/github-mcp/`: anything that lets a secret, token or credential reach a log, a URL,
a comment or a file. In the workflow: PR, comment or Claude text that reaches a `run:` through `${{ }}`, and a change
to `tools/claude-review/claude-review.yml` that isn't made to the installed copy too.

## Private data

This repo is public: every line on `main` can be read by anyone. Hunt private data in every file, docs and prose
included. Fine here: the owner's own name and GitHub handle as LICENSE and README show them, public products and
projects cited as sources, and stand-ins. Private here: a name of another repo, session or machine of the owner's that
no unchanged file already mentions, and any `.archive/` path that names a person, client or ticket.

## Nit cap

Report at most 5 findings. Fewer is better. Security and private-data findings come first and always count. No
style, naming, wording, formatting or "could add a test" comments.

## Paths to skip

`.archive/`, `assets/icon/png/`, `tools/pace-vectors.tsv` (generated), and prose-only changes under `docs/` unless
they contradict code. Private data is reported in every path.

## Every finding

Cite `path:line` and name the trigger: the command, input or state that goes wrong, and what goes wrong. A finding
without one is dropped. A private-data finding names the kind of data instead, never the value.
