# git-mcp

The git MCP server of this toolkit: `server.js`, one node file with no dependencies and no build. It speaks JSON-RPC
over stdio, one process per session, and runs git through an argument array, never a shell. Why an MCP server and not
Bash git: [ADR 0010](../../docs/adr/0010-mcp-git-over-bash-git.md).

| File | What it is |
|---|---|
| `server.js` | The server, run from this checkout |
| `test-server.sh` | A stdio round trip per tool against temporary repos, and one case per refusal |

## Register

From your own terminal (agents may not run `claude mcp add`), with the absolute path of your checkout:

```
claude mcp add --scope user git-mcp -- node <checkout>/tools/git-mcp/server.js
```

Keep the name `git-mcp`: the hooks and the permission rules are keyed on `mcp__git-mcp__git_*`. Sessions pick the
server up when they start. `node` must be on the PATH Claude Code starts with (an app started from the Dock may not
have Homebrew's folder on it); if it is not, register the absolute path of `node` in its place. Nothing is installed: a merge plus a pull of the checkout is the update.

## Tools

`git_status`, `git_log`, `git_show`, `git_diff`, `git_blame`, `git_reflog`, `git_add`, `git_commit`, `git_branch`,
`git_checkout`, `git_merge`, `git_rebase`, `git_cherry_pick`, `git_reset`, `git_clean`, `git_stash`, `git_tag`,
`git_remote`, `git_fetch`, `git_pull`, `git_push`, `git_init`, `git_clone`.

Not offered: tools that set or clear a working directory, and `git_worktree` (`hooks/git-mcp-guard.sh` denied all
three already and still names them), and the earlier server's `git_changelog_analyze` and `git_wrapup_instructions`,
which nothing here used.

An answer is git's own text (stdout, then stderr) in one text block, cut at 1 MB with a note; a failed command sets
`isError`. Nothing in the answer is a parsed field.

## What the server guarantees

The hooks decide what is allowed. The server decides what a call can mean, so that a hook reading `remote`, `branch`,
`mode` or `dryRun` and git acting on them cannot disagree.

- **An absolute `path` on every call.** No working-directory state and no default folder: a missing or relative
  `path` is refused. For every tool but `git_init` and `git_clone` it must be an existing folder.
- **A closed parameter set and strict types.** An unknown key, a string where a boolean belongs (`"true"`), a number
  where a string belongs, or `null` is refused, never coerced. The hooks read these fields with jq, which prints
  `"true"` and `true` alike. An empty string counts as not given, which is how the hooks read it too.
- **No value becomes an option.** A value in a ref, remote, URL or file position may not start with `-` (a file of
  that name is `./-name`). Free text (a commit message, a date, a search pattern) is only ever the value of its own
  `--option=value`. File paths follow `--`. No value reaches `-c`.
- **A remote is a configured name**, never a URL or a path: letters, digits and `. _ -`, not starting with a dot, and
  `git_fetch`, `git_pull` and `git_push` refuse a name the repo has no remote for (git would read it as a folder).
  `git_fetch` and `git_pull` use `origin` when none is given.
- **`git_push` picks no remote for the caller.** With no `remote` and no `branch` it runs a plain `git push`, so git
  resolves the remote the way the hooks model it. `branch`, `remoteBranch` and `delete` need `remote`.
- **A branch or tag name carries no refspec:** no `:`, no leading `+`, no whitespace, none of `~ ^ ? * [ \`. A
  refspec is only ever built by the server, and a named branch always gets an explicit destination
  (`branch:branch`, `branch:remoteBranch`, `HEAD:remoteBranch`), so `push.default` or a `remote.<name>.push` mapping
  cannot send it elsewhere.
- **A dry run changes nothing:** `dryRun` on `git_push` and `git_clean` wins over `force` and `delete`.
- **`git_checkout`'s `target` is a branch or commit, never a path:** `--` always follows it.
- **No mirror clone.** `git_clone` has no `mirror` parameter: a mirror clone marks its remote so that every later
  plain push is a forced push of all refs, which no hook would see.
- **`rebase: false` on `git_pull` means a merge** (`--no-rebase`), whatever `pull.rebase` is set to.
- **A URL** (`git_clone`, `git_remote`) is http(s), ssh, git or file, `user@host:path`, or an absolute path. The
  `transport::address` form, which runs a helper program, is refused.
- **A clean environment.** git gets the server's environment without any `GIT_*` variable, so an inherited `GIT_DIR`,
  `GIT_WORK_TREE`, `GIT_CONFIG_*`, `GIT_SSH_COMMAND` or `GIT_EXTERNAL_DIFF` cannot redirect a call, plus
  `GIT_TERMINAL_PROMPT=0`, `GIT_EDITOR=true`, `GIT_PAGER=cat` and `GIT_OPTIONAL_LOCKS=0`. Set an ssh command or an
  identity in git config, not in the environment.
- **One call at a time per `path`,** so two calls sent together do not collide on the index lock.

Not defended, as with any git front end: a program named in the repo's own `.git/config` or `.git/hooks` runs when git
runs it. `git_push` with no `branch` pushes what the repo's `push.default` says; the guard resolves that destination
before it allows the call. A remote marked as a mirror by hand (`remote.<name>.mirror`) still pushes as one. A
credential written into a remote's URL is shown by `git_remote`. A git child that waits on something outside git (an
ssh prompt on the terminal) is stopped after ten minutes, and calls on the same `path` wait behind it.

## Changing it

A tool name, a parameter name, a default or the meaning of a parameter is an interface three hooks read:
`hooks/git-mcp-guard.sh`, `hooks/protected-paths-guard.sh` and `hooks/workspace-lock-guard.sh`. Read them before
changing one, and run their suites with this one. A new parameter is a new way to reach git: the lock guard already
treats an unknown `git_fetch` key as a write.

```
bash tools/git-mcp/test-server.sh
```
