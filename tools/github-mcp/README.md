# GitHub MCP

The official [github/github-mcp-server](https://github.com/github/github-mcp-server), pinned at **v2.0.3**, run over
stdio in every session (user scope). macOS on Apple silicon only: the launcher reads the token from the Keychain and
the install fetches the Darwin arm64 build.

It relies on the toolkit's install tooling: the zsh helpers `ghm-install`, `ghm-status` and `ghm-test`
(`tools/ait.zsh`) and the install-time settings file `~/.claude/install.conf` (read by `tools/install-copies.sh`).

| File | What it is |
|---|---|
| `launch` | Source of the launcher you install root-owned at `/usr/local/libexec/mcp-github/launch` |
| `guard.sh` | Source of the PreToolUse guard for the tools of the `github` MCP server, installed root-owned at `/usr/local/libexec/mcp-github/guard.sh` |
| `test-guard.sh` | Tests for both, including a check that the guard's tool list equals the launcher's |
| `test-update-check.sh` | Tests for `hooks/github-mcp-update-check.sh`, the hook that says when an upgrade is due (see Upgrades) |

Both are root-owned so no session can change the live copies; a change lands by PR, then you install it with
`sudo`. The guard is deliberately not in `hooks/`, which `/setup-claude` symlinks into `~/.claude/hooks`.

## Layers

1. **Token:** a classic PAT, scope `repo`, 180 days, keychain service `mcp-github`, account `<keychain-account>` (the `github_keychain_account` install setting). It reaches
   every repo you can, with merge and push power. The layers below are the only fences.
2. **Launcher:** runs under `sh -p`, so the shell ignores an exported `SHELLOPTS` (`xtrace` would print the token),
   exported functions (an exported `cd` would undo the `cd` below), `BASH_ENV` and `ENV`. Stage one re-execs it
   under `env -i` with `HOME` from the user record (`dscl`), `TMPDIR` from `getconf DARWIN_USER_TEMP_DIR` and
   `PATH=/usr/bin:/bin`; stage two clears anything else, `cd`s into its own root-owned folder, reads the token and
   execs the server with a fixed `--tools` list. Without a token it refuses to start, so the server's browser OAuth
   login never opens. The server's `--lockdown-mode` is off on purpose (2026-11-04): it filters content from users
   without push access on public repos, which hid the reviewer App's posts there. What that costs is under Residuals.
   - `--clean-env` only says "stage one already ran". A caller can pass it to skip stage one, but stage two still
     clears every variable except `HOME`, `TMPDIR` and `PATH`; those three then come from the caller, so a same-user
     process could point `HOME` or `TMPDIR` elsewhere. Same-user processes are already outside the fence (see
     Residuals).
   - The server reads every `GITHUB_*` variable (viper `SetEnvPrefix("github")` + `AutomaticEnv` in
     `cmd/github-mcp-server/main.go`), including `GITHUB_HOST` (where the token is sent), `GITHUB_TOOLS`,
     `GITHUB_TOOLSETS`, `GITHUB_EXCLUDE_TOOLS`, `GITHUB_INSIDERS` and `GITHUB_LOG_FILE`, and `GITHUB_MCP_<KEY>` to
     override tool descriptions. Claude Code passes its environment to the server, and a project's settings can set
     it.
   - It loads `github-mcp-server-config.json` (tool-description overrides) from its working directory
     (`pkg/translations/translations.go`). Started in a checkout, a planted file would put text into every session.
3. **`--tools`:** only the 19 tools below exist. Everything else is absent from the server.
4. **Permission rules** (the `safe-permissions.json` template): reads allowed, the 5 write tools on ask, the rest
   denied by name as a second layer. Every one of them keys on the server name `github` (allow rules can't glob the
   server), so the template also
   denies `claude mcp add`, `add-json`, `add-from-claude-desktop` and `remove` (`list` stays usable) and edits to
   `~/.claude.json`, asks on edits to any `.mcp.json`, and enforces `enableAllProjectMcpServers: false`;
   registering the launcher under another name would bypass every rule. These name-keyed denies are defence in depth,
   not a fence: Residuals lists the routes they miss. Bash denies on `security`, `gh auth token` and `gh` (the last two
   alongside the gh-block hook) are defence in depth only too (a full path or another program gets past them). `Bash(security:*)` also blocks `security`'s
   codesign and certificate subcommands; nothing in the toolkit uses them, and you run them with the `!` prefix.
   - GitHub's hosted server (`https://api.githubcopilot.com/mcp/`, OAuth, every toolset including merge and push)
     ships in the official `github` plugin, and a plugin your organization syncs (such as `engineering`) can carry
     it too. The template blocks it by URL in `deniedMcpServers` ("nothing overrides a denylist match"), and denies
     the plugin copies' tool names (`mcp__plugin_engineering_github`, `mcp__plugin_github_github`) as a second
     layer. You also remove it at the source (see Install).
5. **Guard hook:** v2 bundles reads and writes behind a `method` argument, which name rules can't split. Its matcher
   is `^mcp__github__.*$`, every tool of the `github` server; other servers are not judged. The hook:
   - on `github`, denies any tool it doesn't know (an upgrade that adds tools stays shut until reviewed);
   - limits every non-read tool to the write repos: every repo of the owners in the `github_write_owners` install
     setting, future ones included (an owner wildcard). The repo name must be a plain GitHub name (letters, digits,
     `.`, `_`, `-`; not empty, not only dots, 100 characters at most); any other owner is denied.
     The owner list is fixed in the root-owned guard, not read from disk: `ghm-install` fills it in from the
     `github_write_owners` setting in `~/.claude/install.conf` (written by `/setup-claude`) when it makes the copy, so
     adding an owner is a settings change plus the reinstall, which shows the owners and the diff and asks first. The
     wildcard widens what an agent can open a PR in, comment on or re-run: a new repo under a write owner, private
     ones included, is covered from its first day. Merge, repo settings and rulesets stay denied (they are not
     exposed);
   - lets `actions_run_trigger` through only for re-run, re-run failed jobs, cancel and dispatch (`run_workflow`), each
     as an ask with a warning (re-runs and cancels can redeploy, see Residuals; a dispatch shows the workflow, ref and
     inputs); log deletion is denied. The v1 `run_workflow` tool name stays denied;
   - lets `update_pull_request` through only when it sets `title`, `body` or `draft` (a retitle or a description fix): any other key (`state`, which closes or reopens, `base`, `reviewers`,
     `maintainer_can_modify`) is denied, as are a missing or non-numeric `pullNumber`, a call that
     sets none of the three, and values of the wrong type. The
     ask shows the new title and body (up to 600 characters each; when cut, the first and last 300 and the full
     size) and warns when `draft` goes to false, which marks the PR ready and starts the automatic paid review.
     Merge, closing and re-basing stay with you;
   - returns ask for every write it lets through except four, so the prompt doesn't depend on the name-keyed ask
     rules (a hook ask prompts in auto mode too), and adds a cost warning when a comment mentions `@claude` (a paid
     review run);
   - returns allow for `create_pull_request`, `add_issue_comment`,
     `add_reply_to_pull_request_comment` and `update_pull_request` in the write-owner repos (they were most of the waiting prompts,
     and no agent route merges). A comment, title or body that mentions `@claude`, a body that is
     not text, and `draft: false` stay ask, and so does a `create_pull_request` that is not a draft. The template lists the four names nowhere: an ask rule would outrank the
     hook's allow, and an allow rule would pass them unchecked when the hook is missing. The template merge only
     adds, so ask entries for them already in your settings stay until you remove them by hand.

   Reads pass with no decision. Every write other than those four is ask or deny. It fails closed on what it handles, but if the hook is
   missing, crashes or times out, Claude Code goes ahead without it: reads stay allowed, the four writes fall back to
   the default prompt (in auto mode the classifier may decide it, since no ask rule forces it), and the other write
   tools to their ask rules, so a dispatch asks either way, without the warning text. For `update_pull_request` the fallback is wide: the template does not deny the name, and a name rule can't split arguments, so without
   the hook it is an unrestricted ask (any owner; `state`, `base` and `reviewers` included). Read the keys in the
   prompt, and keep the hook healthy (`ghm-status`).

| Rule | Tools (`mcp__github__<name>`) |
|---|---|
| allow | `get_me`, `pull_request_read`, `list_pull_requests`, `search_pull_requests`, `issue_read`, `list_issues`, `search_issues`, `get_file_contents`, `get_commit`, `list_commits`, `list_branches`, `actions_get`, `actions_list`, `get_job_logs` |
| none in the template; hook allow on the `github` server | `create_pull_request`, `add_issue_comment`, `add_reply_to_pull_request_comment`, `update_pull_request` (title, body and draft only), in repos of the write owners only; ask when a comment, title or body mentions `@claude`, when `draft` is false, and on `create_pull_request` unless `draft` is true |
| ask | `actions_run_trigger` (re-run, re-run failed, cancel, dispatch), in repos of the write owners only (hook) |
| deny | `merge_pull_request`, `push_files`, `create_or_update_file`, `delete_file`, `create_branch`, `fork_repository`, `create_repository`, `delete_repository`, `update_issue_comment`, `update_pull_request_branch`, `pull_request_review_write`, `add_comment_to_pending_review`, `issue_write`, `sub_issue_write`, `label_write`, `create_repository_ruleset`, `custom_properties_write`; `actions_run_trigger` log deletion (hook) |

v2.0.3 has no tool for Actions variables or secret names; its `secret_protection` toolset is secret-scanning alerts.

## Install (you, in your own terminal)

Download, verify the checksum and the build attestation, and install root-owned:

```
D=$(mktemp -d) && cd "$D" && gh release download v2.0.3 -R github/github-mcp-server -p github-mcp-server_Darwin_arm64.tar.gz -p github-mcp-server_2.0.3_checksums.txt && shasum -a 256 -c --ignore-missing github-mcp-server_2.0.3_checksums.txt && gh attestation verify github-mcp-server_Darwin_arm64.tar.gz -R github/github-mcp-server && tar -xzf github-mcp-server_Darwin_arm64.tar.gz github-mcp-server && sudo install -d -o root -g wheel -m 0755 /usr/local/libexec/mcp-github && sudo install -o root -g wheel -m 0755 github-mcp-server /usr/local/libexec/mcp-github/github-mcp-server && /usr/local/libexec/mcp-github/github-mcp-server --version
```

Install the launcher and the guard with `ghm-install`, from a zsh whose `~/.zshrc` has
`source ~/.claude/tools/shell-init.zsh` (`/setup-claude` links it). Run `ghm-test` first: `ghm-install` does not run
the suites. It wants the checkout on `main` with no uncommitted changes and `main` equal to `origin/main` after a fetch,
and it installs `main`'s committed files, so only merged code goes root-owned. It fills in the settings from
`~/.claude/install.conf`, shows the write owners and the keychain account it read back and the diff against the
installed copies, asks `[y/N]`, then sets the folder to root:wheel, mode 755, and installs both files the same way
with `sudo install`. `ghm-status` shows, with no sudo, whether the folder and the installed files are `root:wheel 755`
and the files match `main`.

Wire it: merge the template's rules, the guard's hook entry, `deniedMcpServers` and `enableAllProjectMcpServers`
into `~/.claude/settings.json` (`/setup-claude`). Then register the server for every session, from your own
terminal (agents may not run `claude mcp add`):

```
claude mcp add --scope user github -- /usr/local/libexec/mcp-github/launch
```

If `claude mcp list` already shows a `github` server in another scope, remove that one first (for a local one,
`claude mcp remove --scope local github`), so one name doesn't point at two scopes. Never approve a project `.mcp.json` server named
`github`: a project server outranks the user one, and it would inherit the read allow rules.

Remove the hosted GitHub server at its sources: `/plugin uninstall github@claude-plugins-official`, and if your
organization syncs a plugin that carries the GitHub connector, ask its admin to drop the connector there.

Then check in a new session: `/mcp` lists the `github` server with exactly the 19 tools above, and
`claude mcp list` shows no `plugin:*:github`. That passes after the uninstall alone, so prove the URL block
separately from a new empty folder (the probe is local scope, so it stays in that folder): add a probe server,
check that `claude mcp list` shows it blocked, then remove it:

```
cd "$(mktemp -d)"
claude mcp add --transport http copilot-probe https://api.githubcopilot.com/mcp/
claude mcp list
claude mcp remove copilot-probe
```

If the probe is not shown as blocked, remove it, never authenticate it (its OAuth grant would merge and push), and
stop the rollout until the denylist is fixed.

## Upgrades

Nothing upgrades the pinned binary on its own. `hooks/github-mcp-update-check.sh` (PreToolUse on
`^mcp__github__.*$`, installed by `/setup-claude` like the other `hooks/` scripts) says when one is due:

- At most once every 7 days, on a github call, it starts a background check, one at a time. The check reads the
  installed `--version` and asks the GitHub API, with no token, for the latest release and the reviewed advisories
  on `github.com/github/github-mcp-server`.
- A notice is due when the release is newer than the installed version, or when an advisory applies. An advisory
  applies when it hasn't been withdrawn, the installed version is in its vulnerable range, and its first patched
  version is newer. One with no patched version applies when it was published after the installed build.
  Prereleases and tags that aren't `vX.Y.Z` are ignored.
- A failed call or an unexpected answer keeps the previous notice, and the check retries about a day later.
- While a notice is pending, the first github call each day shows it as a message to the user. Installing a
  different version clears it, and the next call checks again.
- It never blocks a call and makes no permission decision. Its state is in `~/.cache/mcp-github/` (`checked`,
  `notice.json`, `shown`, and `lock.d` while a check runs). Deleting that folder forces a new check on the next call.
  It needs macOS `date` and `find`.

An upgrade repeats the download with the new tag, after re-reading the tool snapshots
(`pkg/github/__toolsnaps__/*.snap`) for renamed tools and new `method` values. A renamed tool or a new `method` value
needs a `launch` and `guard.sh` change in the same PR, then the root install.

## Token rotation

The token expires 180 days after creation. Create the new classic PAT (scope `repo` only), then store it (you type
it at the prompt):

```
security add-generic-password -U -s mcp-github -a <keychain-account> -w
```

Restart the sessions that use the server, check one read, and revoke the old token on GitHub.

A 401 or "Bad credentials" means the token expired or was revoked: sessions stop and tell you
(`rules/security.md`), with no `gh` fallback.

## Same-user credentials

Agents run as your user, so a Bash command can use any GitHub credential that user holds, outside the guard and the
permission rules: the `mcp-github` Keychain item, a `gh` login, a stored HTTPS password, SSH keys. Root-owning
`launch` and `guard.sh` does not change that: the launcher must run as you. The template's `Bash(*mcp-github*)` deny
and the gh-block hook are tripwires on the normal routes, not a fence. Check which of these your machine holds, and
remove or narrow the ones you don't need (fewer scopes on the `gh` login, a passphrase on SSH keys).

Side effect of the deny: a Bash `ls` or `stat` of `/usr/local/libexec/mcp-github` is denied too. `/setup-claude` checks
that folder's owner and mode through `bash tools/install-copies.sh status`, whose command line does not name it.

## Residuals

- The token's `repo` scope covers every repo you can reach; the guard limits writes, not reads, so a session can
  read any of those repos without a prompt.
- Lockdown mode is off (2026-11-04): issue, PR and comment text by any GitHub user on a public repo, the owner's own
  public repos included, reaches the agent unfiltered through the allowed reads (`pull_request_read`, `issue_read`,
  `list_issues`, `search_*`). That is a prompt-injection route toward the hook-allowed comment and PR writes in
  write-owner repos.
- Any same-user process can read the keychain item, or the running server's environment, and call the API outside
  every rule. The Bash denies are defence in depth only.
- A draft PR changing `.github/**` gets no prompt: `create_pull_request` of a draft is a hook allow in the write-owner repos. A
  same-repo PR runs its own copy of a changed workflow when it is opened, so merge staying with you does not cover
  it; a branch push already allows the same for `on: push` workflows.
- Text in a PR title, body or comment leaves the machine without a prompt: a secret an agent pastes there is not seen first (the output-redaction hook filters tool output, not this input; the secret detector does not match `mcp__github__*`).
- `update_pull_request` can edit the title and body of a PR you already reviewed, and of other people's PRs in the write repos, and the squash merge takes its commit record from them.
- The audit logger records the first short string argument of each github call, which can be a short comment body.
- Only the server registered as `github` is guarded: a launcher or plugin server under any other name gets no repo
  or method check, only the default MCP prompt. Known routes the template doesn't close: `claude --mcp-config <file>`, a plugin that ships an MCP server, a
  project `settings.local.json` that sets `enableAllProjectMcpServers: true` (it outranks user settings), and a Bash
  write to `~/.claude.json` or a `.mcp.json` (Bash redirects aren't Edit or Write calls). Each needs the token,
  which the launcher reads and any same-user process can read too (above).
- Two interactions are unverified: whether the plugin servers' settings deny still
  wins over the guard's ask (the URL block is the main layer there), and whether a hook ask still prompts in a
  `bypassPermissions` session. Don't use bypass mode for GitHub work: there, `update_pull_request` could run
  unprompted too (title, body and a draft-to-ready flip, which starts a paid review).
- The template doesn't deny edits to `~/.claude/settings.json`, which holds the hook entry and `deniedMcpServers`:
  `/setup-claude` writes it.
- Re-run and cancel are allowed on ask in every write repo. Where a workflow deploys on manual runs, re-running an
  old run can put that run's branch back on production, and cancelling a deploy can stop it halfway. The prompt
  says so.
- Every repo of a write owner is a write repo, including one that holds personal data or infrastructure config: a
  PR, comment or re-run there is one approved prompt away. Keep such repos under an owner that is not in
  `github_write_owners`.

## Sessions

User scope loads the server in every session on the machine.

| Session type | Covered by | Gap |
|---|---|---|
| Interactive sessions: CLI, VS Code, Desktop | `~/.claude/settings.json` rules and the guard | none new |
| Subagents | the parent's tools and rules | none |
| Background sessions (`claude --bg`) | the same user settings and the guard (user hooks still load) | none new |
| A session started with its own settings file (`--settings`) | the user rules and hooks, plus what its file adds | to keep it off GitHub, deny the `github` server and the plugin servers in that file; a renamed server gets only the default MCP prompt |
| Headless `claude -p` | an ask is refused, not prompted | none |
| `bypassPermissions` | the guard, if its ask still prompts there | unverified (Residuals) |
| `--strict-mcp-config` | doesn't load the server | none |
| A machine without the launcher or token (a CI runner, another computer) | nothing to cover | none |

Each session runs its own server process, which holds the token in its environment, and all of them share the
token's 5,000 requests an hour.

**Context cost:** tool search is on by default, so a session starts with the 19 tool names and the server's
instructions (about 150 words); a tool's schema loads only when it is called. Don't set `alwaysLoad`, and leave
`ENABLE_TOOL_SEARCH` unset.
