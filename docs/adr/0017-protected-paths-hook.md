# 17. A Hard-Deny Hook for Protected Checkouts and the Settings Files

**Status:** accepted
**Date:** 2026-11-13

## Context

ADR 0014 runs the installs from the live checkout, so a stray write there goes live on the next tool call. Its
controls were permission rules: Edit denies on parts of the checkout and an ask on the user settings. ADR 0014's own
Consequences say what is missing: a shell write (`sed -i`, a redirect, a `git checkout` in the live checkout) is not an
Edit, so no rule stops it, and the clone rule in CLAUDE.md is the only layer. An ask rule on the settings files asks
the same person who is being protected from a mistaken click, and an agent can reach the prompt through auto mode.

Other tools that sit on top of this repo have the same need for their own checkouts and state folders, and some had
built a best-effort reader of shell text inside their own plugin to cover it. That reader is the wrong place: it
only runs when a prompt exists, it breaks with every new shell shape, and it duplicates a control that belongs in the
base install.

## Options Considered

- **More permission rules.** They match tool arguments, not shell text, so they cannot see a redirect or a
  `git -C`. Rejected: this is the gap.
- **A sandbox.** The only complete answer, and out of scope for this install: the threat model is the one in ADR 0014.
- **A hook that hard-denies, driven by a marker file: chosen.** A hook sees the tool's input and, for Bash, the
  command text, before any prompt exists.
- **Roots named in settings or an environment variable.** A hook is not handed settings. A project-local setting
  covers only sessions started in that folder. A global variable puts absolute paths in a shared file. Rejected.
- **A committed marker.** It is cloned with the repository, so a clone under `/tmp` would be locked too. Rejected.

## Decision

`hooks/protected-paths-guard.sh`, a PreToolUse hook on `Edit|Write|MultiEdit|NotebookEdit|Bash|Monitor|mcp__git-mcp__.*`.

- **Hard deny only; it never asks.** A prompt can be answered by the person's own habit, by an allow rule or by an
  auto mode that decides for them. A deny cannot. It fails closed without jq, as `git-mcp-guard.sh` does: because the matcher is global, a machine without jq then denies every Bash, Edit, Write and git MCP call (jq is a Step 0 prerequisite of `/setup-claude`).
- **A folder opts in with a marker.** A folder holding a file named `.protected-checkout`, and everything under it,
  is protected. The marker is untracked and listed in `.gitignore`; the person makes it with `touch`, and the hook
  denies every write to an existing one, so an agent cannot remove or move one. An agent can create one, which only
  widens the protection (a copy of a protected folder carries its marker; the person removes it there). The hook finds a root by walking up from the
  target's real path, so a clone elsewhere has no marker and stays editable, and a folder that is no repository (a
  state folder) is protected the same way. The hook is generic: it names no repository, tool or project, and nothing
  that depends on this repository may be named in it.
- **Fixed in the hook: `~/.claude/settings*.json`.** Any such file directly under `~/.claude`, whatever markers exist.
  `~/.claude/hooks` and `~/.claude/rules` hold links into the checkout, so resolving real paths covers them.
- **What counts as a write.** File tools by real path (links followed, case-insensitive). Git MCP tools other than the
  read ones, by the call's `path`. Bash by one simple rule: segments, a tracked `cd`, redirects and a fixed list of
  write verbs and git subcommands, with the folder git runs in judged for the git ones. Reads are never denied. The
  exact list and the limits are in the hook's header and tested in `tools/protected-paths-guard/`.
- **Exceptions.** `<root>/.archive/**` stays writable (the gitignored working area). `git pull --ff-only`, `git merge
  --ff-only` and the git MCP `git_pull` with `fastForwardOnly` are allowed in a root: they move a checkout to a
  reviewed commit, which is how a protected checkout is updated.
- **Targets are judged, not the session's folder.** A session that stands in a protected folder and works in a clone
  under `/tmp` is not blocked. The folder only decides a relative operand with no `cd` before it.
- **The setup.** `/setup-claude` links the hook (it is in the roster), wires it (a template entry, covered by the drift
  assertion) and tells the user to make the marker for this checkout. Because the hook now denies the agent's writes to
  the settings files, Step 10 stages the merged settings in a file beside the live one and gives the user a copy
  command; the agent never writes the live file.

## Consequences

- The live checkout, the settings files and any other marked folder are safe from an agent's file tool, git MCP call
  and simple shell write, not only from an Edit. A person's own terminal is not covered (the hook sees only tool
  calls), and a person's `!` line in a session is theirs.
- **It is a guard against mistakes, not a sandbox.** Interpreters (`python -c`, `node -e`, a script file), `make` and
  package installers, `eval` and `bash -c` strings that are built at run time, paths built at run time, a `cd` to a
  variable, file names fed to `xargs` on stdin, hard links, the target of a `find -exec`, programs that write on their own (archive creators, compressors, formatters with an in-place flag), and a git MCP call with no `path` when the server's own
  folder differs from the session's all get past it. The clone rule and auto mode's classifier stay as the second line.
  The same threat model as ADR 0014: accidents and a forgetful session, not a hijacked agent working around
  the control.
- A recursive delete or move of a folder that contains a protected root is caught only for the session's own root and
  for `~/.claude`. `destructive-blocker.sh` already hard-denies the `rm -rf` forms.
- The marker is the switch: removing it (the person's act) turns the protection off for that folder, and a folder with
  no marker is unprotected. The setup reports a missing marker for this checkout as a warning.
- The cost is a handful of small processes per call (about 0.03 s for an ordinary command on a laptop, under 2 s for
  a command with hundreds of operands); the test suite runs several hundred cases in about 15 s.
- Settings changes through `/setup-claude` take one extra step from the user. That is deliberate: the file holds the
  hooks and permissions that this hook and every other control run under.
