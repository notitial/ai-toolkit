---
description: "Set up or update global Claude Code configuration — CLAUDE.md, permissions, plugins, MCP servers, skills, agents, and hooks. Run from the ai-toolkit repo to apply best practices globally. An agent runs it only when the person asks for the setup, or from /update-toolkit."
---

# Setup Toolkit

Configure the global Claude Code environment from this repo's templates and skills. Idempotent — safe to run repeatedly. Each section reports what changed.

**macOS only.** The steps assume macOS: Homebrew install hints, `/usr/bin/jq` and the login keychain.

**What it overwrites.** Most of the settings merge only adds and never removes. Four settings are enforced instead: added when missing and overwritten when different, and every change is reported (Step 6):

- `env`: the session-quality survey and the `/feedback` upload off, and claude.ai's cloud MCP connectors off;
- `attribution`: no commit trailer, PR footer or session link;
- `autoCompactWindow`: 533000;
- `enableAllProjectMcpServers`: `false`.

Read Step 6 before the first run if you rely on other values for any of them.

**Prompt cache TTL.** Step 6 adds `promptCacheTtl: "1h"` when your settings have no such key, and keeps any value you set. It never asks about or writes `subagentPromptCacheTtl`.

**`/setup-toolkit check`:** read-only. Run only `bash tools/install-copies.sh status` (resolve the path from this skill's location: `../../../tools/install-copies.sh`), show its output, and stop. It lists the install-time settings, the github MCP guard, the `~/.zshrc` line, every unlinked or conflicting link against `main`, any hook or lock script that is not executable, and any hook `settings.json` does not run, and changes nothing.

## How the run talks to you

The run asks once up front, builds every change into files it may write, and hands the person one pasted block. The person's go is that block, informed by the change list in the final message.

1. **Round 1: one question dialog**, holding only the questions that apply (Step 4 and Step 5 say when). A machine that is already set up (install.conf present, `~/.claude/CLAUDE.md` present) gets none and the run is silent until the final message.
2. **No questions in between.** The steps below link, stage and report. The agent never asks a go per item, never says "on their go" for a merge or a repair, and never hands over a `!` line: a command for the person goes in the final block.
3. **Round 2, only when one of these turns up**, all in one dialog:
   - "Limit" was chosen in round 1 with no valid owner name (a fresh machine's one way to get a second round);
   - an `autoMode` list without `"$defaults"` (Step 6): *Replace with the template's list, backup kept (Recommended)* or *Leave it, reported as DRIFT*;
   - a per-model `autoCompactWindow` override (Step 6): *Remove it (Recommended)* or *Keep it*;
   - a `settings.json` of unexpected structure: *Stop and show it (Recommended)* or *Continue*.
4. **The final message** (Step 7): the summary table, then the staged settings changes in full, then one block of plain terminal commands, then the restart line.

The agent never writes `~/.claude/install.conf` or the live `~/.claude/settings.json` (denied, and `hooks/protected-paths-guard.sh` hard-denies the settings files), never runs `claude mcp add` or `remove`, never edits a shell rc file, and never touches the GitHub token. Those are the person's, as lines of the block.

## Step 0: Prerequisites

Check each tool with `command -v <tool>`, except gh: any Bash command naming gh is blocked for agents (`hooks/gh-block.sh`), so its state is unknowable here.

- **`jq` missing: stop.** It parses every hook's input and is needed to stage the settings. Print `brew install jq` in a block and ask for a re-run. Recent macOS ships `/usr/bin/jq`; otherwise it must be on the PATH Claude Code starts with (the guards fall back to `/usr/bin` only).
- **`node` missing:** not a stop. The block's first line is `brew install node` (the git MCP server, `tools/git-mcp/server.js`, needs it).
- **`brew` or `claude` missing from the terminal's PATH:** one report line each with the fix (brew.sh; the Claude Code install). Not a stop.
- **gh:** the report always says "the GitHub lines need gh installed and logged in (`brew install gh`, then `gh auth login`, answering **No** to 'Authenticate Git with your GitHub credentials?'); the chain stops at its first link if not".
- **`uname -s` and `uname -m`:** the GitHub MCP install is offered only on Darwin arm64, the one build the README fetches. On anything else, say so in the report and offer nothing.
- **The checkout path** (this repo's root, `cd -P <root> && pwd -P`) must be plain: letters, digits and `/ . _ - +`. Anything else: **stop** and say to move the checkout, since a quote or glob character would break every path in the block. A path under a temp folder (`/tmp`, `/private/tmp`, `/var/folders`, `/private/var/folders`) is a throwaway clone, not the live checkout: **stop** too and say to run the setup from the live checkout. Linking `~/.claude` or registering the token-bearing github server at a folder an agent may edit, with no protected marker and no guard, is never right.

## Step 1: Read current state

Read these to understand what is already configured:

- `~/.claude/CLAUDE.md`, `~/.claude/settings.json` and `~/.claude.json` (each may not exist; `~/.claude.json` is the user-scope MCP config)
- This skill's `templates/` (`global-claude-md.md`: the checklist and the starter; `safe-permissions.json`: permissions, plugins, hooks config and migration rules)
- Repo root artifacts, resolved from this skill's location via `../../../`: `agents/*.md`, `hooks/*.sh`, `rules/*.md`, `tools/statusline.sh`, `tools/workspace-lock/workspace-lock.sh`, `tools/claude-wrapper/claude-wrapper.sh`, `tools/shell-init.zsh`, `tools/install-copies.sh`
- `bash tools/install-copies.sh roster` (the agents, hooks, rules and skills committed at `HEAD`; an untracked file is never linked) and `bash tools/install-copies.sh status`; keep both outputs for the report

## Step 2: Link

Link every roster entry and the tool scripts, with no question asked:

| Source (repo) | Link (under `~/.claude`) | Needs the exec bit |
|---|---|---|
| each `agents/<name>.md` of the roster | `agents/<name>.md` | no |
| each `hooks/<name>.sh` of the roster | `hooks/<name>.sh` | yes |
| each `skills/<name>` of the roster | `skills/<name>` | no |
| each `rules/<name>.md` of the roster | `rules/<name>.md` | no |
| `tools/statusline.sh` | `statusline.sh` | no (run as `bash <path>`) |
| `tools/workspace-lock/workspace-lock.sh` | `tools/workspace-lock.sh` | yes |
| `tools/claude-wrapper/claude-wrapper.sh` | `tools/claude-wrapper.sh` | yes |
| `tools/shell-init.zsh` | `tools/shell-init.zsh` | no (sourced; it loads the `ait` zsh helpers) |

**The one rule.** For each row: nothing at the link path: `mkdir -p` its folder and `ln -s <absolute source> <link>`; a symlink to the right target: skip; anything else: report a conflict and do not overwrite. The exception is Rules ([ADR 0009](../../../docs/adr/0009-global-rules-distribution.md): always-on rules, no frontmatter; do not add any): a plain file whose bytes equal the repo copy (`cmp -s`) is replaced by the symlink, since nothing divergent can be lost. A different plain file, a symlink elsewhere, a broken symlink or a directory is a conflict. There is no prune: a rule removed from `rules/` leaves its link, which is reported as a conflict, never deleted.

**Verify.** Each link resolves to a readable file (an agent's frontmatter has name, description, model and tools; a skill has a `SKILL.md`). A row that needs the exec bit must be executable, because hooks and the lock script run by their path and a script without the bit fails open: its control is off with nothing blocking. Never `chmod` it. Report `DRIFT: <script> not executable` (Step 6's drift assertion); the fix is a PR that commits it as `100755`, then a pull and another run. When the commit has the bit and only this checkout lost it, `status` prints that smaller fix for the person.

**The protected checkout.** `hooks/protected-paths-guard.sh` (wired in Step 6) denies every write to a folder that holds a `.protected-checkout` file, and to `~/.claude/settings*.json` whether or not any marker exists. This checkout is one such folder: its tracked files go live on the next tool call (CLAUDE.md, Where agents edit). The marker is untracked, and the hook denies the agent every write to an existing one, so the person makes it. Run `ls <checkout>/.protected-checkout`; when it is missing, the block gets `touch '<checkout>/.protected-checkout'` and the report says what it does: from then on the agent's Edit, Write and Bash writes here are denied and work goes in a clone under `/tmp`. Other folders can be protected the same way, one `touch` each. `check` does not report the marker; a full run does. Without it, report `Protected checkout: marker MISSING` as a warning, not a failure.

**The shell line.** Never edit `~/.zshrc`, `~/.bashrc` or `~/.zshenv`. When `status` shows the `~/.zshrc` line MISSING, the block gets the grep-guarded append of `source ~/.claude/tools/shell-init.zsh` (Step 7).

## Step 3: Git MCP server

The toolkit's own server, `tools/git-mcp/server.js`: one node file with no dependencies, run from this checkout (`../../../tools/git-mcp/server.js`). It provides structured git tools that replace Bash git wildcards. Nothing is installed, pinned or downloaded, and a merge plus a pull is the update. Keep the name `git-mcp`: the permission rules and the hooks are keyed on it.

Assert the shape, not the key: a presence-only check is the defect Step 6's hook drift assertion exists to prevent, one section over. Run `claude mcp list 2>&1`, then `grep -A6 '"git-mcp"' ~/.claude.json` (the one user config this setup manages; `claude mcp add --scope user` writes it).

- **Absent:** the block gets `claude mcp add --scope user git-mcp -- node '<checkout>/tools/git-mcp/server.js'`.
- **`"command": "node"` and this checkout's `tools/git-mcp/server.js` in `args`:** correct, skip.
- **Anything else** (another program or path, `npx …`): the block gets `claude mcp remove --scope user git-mcp` on the line before the add. Report it as `Repaired`, never as "already installed".

`claude mcp add` and `remove` are denied to agents (the template's deny list): a server registered under another name would bypass every name-keyed MCP rule. Never get around the deny with `env …`, a full path or a wrapper. On a first run the line is only in the block, so the shape is checked by the second full run (Step 7). Changes take effect on restart; existing sessions keep their old server until then.

## Step 4: Install settings and the GitHub MCP

The github MCP launcher and guard are not copied anywhere: they run from this checkout, which stays on a clean `main` and moves only with a fast-forward pull after a merge (CLAUDE.md, Where agents edit). The logic that checks it lives in `tools/install-copies.sh` (tested by `tools/test-install-copies.sh`); do not re-implement it. Resolve the script as `check` does. Never set an `ICOPIES_*` variable (test hooks) and never change repo state (stash, checkout, pull, reset, `update-index`) to get past a gate.

**install.conf.** This repository ships no owner's values: the github guard's write owners and the launcher's keychain account are read from `~/.claude/install.conf`, the person's own file (mode 600, one `key=value` line each, read by a strict reader in `tools/install-copies.sh`, never sourced). It stays a plain file the person may edit by hand; keys the reader does not use are skipped. Read the `install.conf` line of `status`:

- **`ok`:** nothing to do. **`STALE`:** the skill does not rewrite it. Report the bad key `status` names; the person fixes that line, or deletes the file and runs the setup again.
- **`MISSING`:** the block writes it (Step 7), with `github_write_owners` from the round-1 answer below and `github_keychain_account` from `id -un`, filled in. Check the account against `^[A-Za-z0-9._@-]+$` first: a login outside it would make the block write a STALE file, so leave the install.conf line out and report why. The report says: "keychain account `<name>`: create the token under this account (tools/github-mcp/README.md, Install, Token); another account is a hand edit of install.conf".

**Round-1 question: the GitHub MCP server and its write scope.** One question, asked only when install.conf is MISSING. Show only the options that apply: on Darwin arm64 with `status` showing the github binary or registration MISSING or STALE, all three; when the github MCP is already installed or the machine is not arm64, only two scope options, *All owners (Recommended)* (the first option's scope text, with no download or token costs) and *Limit to owners you name*, each writing install.conf only. Say in plain words what each costs:

- *Install, all owners (Recommended).* Agents can read PRs, issues, checks and job logs, and open draft PRs, comments, issues and labels, all through the guard; gh is blocked for agents, so without this server they cannot read PRs, issues or checks, or comment (plain git and the git MCP still work). Writes `github_write_owners=*`: draft PRs and comments go through without a prompt in any repo your token can write or comment on (your orgs, client orgs and a stranger's public repo), text an agent posts there is not shown to you first, and a prompt-injected agent could post outside your own repos. Merges, repo settings and rulesets stay impossible, and every prompt the guard has today still prompts. Costs: a classic token you make in the browser (scopes `repo` and `project`, renewed every 180 days) that reaches every repo you can, with merge and push power, so the guard is the fence; a verified binary download that needs gh logged in; a Keychain item you type once at a hidden prompt, which any program running as you can read; the checkout must stay on a clean `main` or the server and its guard switch off; macOS on Apple silicon only.
- *Install, limit to owners you name.* The same install; writes to any owner not named are denied. The person types the owners, space-separated, in the option's notes or under Other. Check each name against `^[a-z0-9][a-z0-9-]*$` before the block is built; none valid triggers round 2.
- *Skip.* No download and no token. install.conf is still written, since the reader needs both keys, with `github_write_owners=*` (the decided default; it stays in force if you install later, and a hand edit changes it). Ask for the GitHub MCP commands any time to install it.

**The GitHub MCP block.** On an Install answer, or when the person asks for the GitHub MCP commands later, add to the final message (Step 7):

- One prose step before the block: open github.com/settings/tokens/new, make a classic token with scopes `repo` and `project` and an expiry of 180 days, and leave the page open. Do not copy the token yet: copying the block would overwrite the clipboard. Copy it only when the block's last command shows `password data for new item:`.
- One more line at the end of the same block, a single `&&` chain joined to the settings `cp` line (Step 7), so a failure stops everything after it and nothing registers and no prompt appears unless every earlier link passed. Its links come from `tools/github-mcp/README.md`, Install, with `<checkout>` and the account filled in and the paths quoted as in the rest of the block (the account is `id -un` when install.conf is MISSING, otherwise the `github_keychain_account` value read from the existing file with the Read tool: the key is not secret); this skill names that section and does not restate the commands. In order: the download (its first command, `gh auth status >/dev/null`, is the gate: a logged-out gh stops here with gh's own message), the pin check, `claude mcp add` for `github` (preceded by `claude mcp remove --scope user github` when `status` shows a stale registration), and last the Keychain store command with the hidden prompt. No later line follows it, so no pasted text can be read as the token. The line ends with `; pbcopy </dev/null` after the store command, outside the `&&` chain, so the clipboard is cleared even when the prompt is cancelled; say in the message that the clipboard is cleared after the prompt. A link whose piece `status` shows as `ok` is left out. The store link is always kept: `-U` makes a re-run overwrite the item, and nothing can tell whether the item exists without touching the Keychain.
- When the live `enabledPlugins` holds `github@claude-plugins-official`: `/plugin uninstall github@claude-plugins-official`, as a slash command in its own block.
- Report lines: "After the restart, run `/mcp`. The `github` server should list 26 tools. If it fails, paste the store command again" (macOS may ask once to let the launcher read the Keychain item); "`claude mcp list` should show no `plugin:*:github`. An org-synced connector needs its admin"; and one the person cannot miss: "Prove the hosted-server URL block once, with the probe in tools/github-mcp/README.md, Install. If the probe is not shown as blocked, remove it and stop." The probe stays the README's step.
- What is left if it does not finish: gh logged out stops the chain at the gate with nothing changed (the person runs `gh auth login`, then asks for the GitHub MCP commands); a cancelled or mistyped store prompt makes `/mcp` fail (the person asks again). Asked again, build the chain from the pieces `status` shows MISSING or STALE, plus the store link.

A later run with install.conf present never asks this question. A github piece `status` shows as MISSING is one report line: "not installed: ask for the GitHub MCP commands". Other `status` lines: a `checkout` line means the live checkout is not on a clean main (move the work into a `/tmp` clone and put the checkout back on `main`); the guard hook line is fixed by Step 6 (Hooks); `~/.zshrc` and Links are handled in Step 2; a hook or the lock script `STALE … executable bit` is reported with the fix it prints, never `chmod`ed and never wired. `MISSING hooks/<name>.sh is not wired` is fixed by Step 6 (Hooks), unless that hook also has an executable-bit line.

## Step 5: Global CLAUDE.md

`templates/global-claude-md.md` holds what a good global CLAUDE.md covers (required sections: Interaction Style, Code Changes, Communication) and a starter.

- **`~/.claude/CLAUDE.md` does not exist:** a round-1 question. *Install the starter (Recommended)*: write the starter template's markdown block to `~/.claude/CLAUDE.md` and tell the person to edit it. *Skip*: write nothing; the report lists the checklist.
- **It exists:** no question. Evaluate it against the checklist and put it in the report: which sections are present and well covered, which are missing or thin, whether it exceeds the checklist's line target (35 lines with the optional orchestration sections, 30 without), and any suggestion.

Never overwrite or modify an existing global CLAUDE.md.

## Step 6: Permissions, plugins, hooks and status line

Read `templates/safe-permissions.json` for:

- `env`, `attribution`, `autoCompactWindow`, `enableAllProjectMcpServers` — enforced (added if missing, overwritten if different)
- `promptCacheTtl` — added when absent, a live value kept (see **Prompt cache TTL**); `subagentPromptCacheTtl` is never written
- `deniedMcpServers` — MCP servers that must never connect (additive like `permissions.deny`, deduped by the `serverUrl` string; never remove live ones, report live-only ones); today GitHub's hosted server by URL
- `permissions.allow`, `permissions.deny` (security controls), `permissions.ask` (commands that always prompt) — added if missing, never removed
- `enabledPlugins` — plugins to ensure are enabled
- `autoMode` and `skillOverrides` — the classifier context and the skill switches (see **Auto mode**)
- `syncClaudeAiSkills`, `syncClaudeAiPlugins` — added when absent (see **Start context**)
- `_migration.removeBashGit`, `removeOverbroad`, `removeReplacedDeny` — entries to remove from the live file

Read `~/.claude/settings.json` (or start from `{}` if missing).

**The agent does not write the live settings file.** `hooks/protected-paths-guard.sh` hard-denies the Edit, Write and Bash writes to `~/.claude/settings*.json` (a copy or a redirect included), so this step builds the result in a staged file and the person puts it in place with one `cp` from the final block. Every merge and repair below is applied in the staged file, and listed in the final message (**Change list**), which is what the person's go rests on.

Template keys that start with `_` (`_comment`, `_env_comment`, `_migration` and the rest, at any depth) are notes for this skill: never write one to the live file, including inside a copied hook entry or the `statusLine` object. (`_migration` is still read for its remove lists below.)

**Back it up before building the staged file** (skip only when the file did not exist). The name carries the date AND the time (`YYYYMMDD-HHMMSS`), the copy is mode 600 (the file holds MCP server and env key names), an existing backup is never overwritten (`cp -n`). Check with `ls -l` only; never open a backup. Report the path.

```bash
(umask 077; b="$HOME/.claude/settings.json.bak-$(date +%Y%m%d-%H%M%S)-settings"; cp -n "$HOME/.claude/settings.json" "$b" && chmod 600 "$b" && ls -l "$b")
```

### Environment variables, attribution, auto-compact window

- **`env`:** a key absent from the live `env` is added with the template value (create `env` if needed); present with the same value: skip; a different value: overwrite and report old and new. Never remove or alter a live `env` key that is not in the template (e.g. `CLAUDE_CODE_NO_FLICKER`).
- **`attribution`:** the mechanical form of the global CLAUDE.md no-attribution rule (the harness re-applies `Co-Authored-By` / "Generated with Claude Code" by default, and only this setting stops it). Absent: add; identical: skip; different: overwrite, report old and new. `commit` and `pr` are **strings** (`""` suppresses the trailer or footer), `sessionUrl` a **boolean**.
- **`autoCompactWindow`** (533000): enforced like `env`. It sets when every model compacts; without it 1M-window models (Opus 5.x, Fable, Sonnet 5) compact near 967k and every turn re-sends that context. **Per-model override check (every run; fail loud):** a live `modelSettings.<model>.autoCompactWindow`, which is what `/autocompact` writes, beats the top-level key for that model. Report each as `DRIFT: modelSettings.<model>.autoCompactWindow = <value> overrides autoCompactWindow`; round 2 asks whether to remove it (keeping the model's other keys such as `effortLevel`, and deleting an emptied `modelSettings.<model>`). Not touched: the `CLAUDE_CODE_AUTO_COMPACT_WINDOW` env var beats this key.

### Prompt cache TTL

`promptCacheTtl` (`"1h"`) sets how long the main conversation's prompt cache survives an idle gap and needs Claude Code v2.1.242 or later. It is **add-only**, not enforced: an API-key user pays more to write a one-hour cache, so a deliberate `"5m"` must survive. Run `claude --version` first: on an older version skip this whole section, report `Skipped`, and leave any live key.

- Live key absent: add `"1h"`. Present, any value: keep it and report `Already set (<value>, left as is)`.
- `subagentPromptCacheTtl`: never ask, never write, not in the template (subagent requests are mostly short-lived, so the longer write costs more than it saves). Report a live value only.
- **Override check (every run):** a variable beats the key it names. Look in the live `env` object and test in the shell that the name is set without printing it (`[ -n "${CLAUDE_CODE_PROMPT_CACHE_TTL:-}" ] && echo set`; never a bare `printenv`): `CLAUDE_CODE_PROMPT_CACHE_TTL` overrides `promptCacheTtl`, `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL` overrides `subagentPromptCacheTtl`, `FORCE_PROMPT_CACHING_5M` equal to `1` overrides both. Report `NOTE: <variable> overrides <key>` for a key that is live or about to be added; never print a value.

### Permissions

- **Add** every `allow` entry the live array lacks.
- **Remove (Bash→MCP migration)** each `_migration.removeBashGit` entry: the Bash git wildcards `git status*`, `git diff*`, `git log*`, `git show*`, `git remote -v*`, `git tag*`, `git stash list*`, `git add *` and `git branch*`, replaced by the matching `mcp__git-mcp__git_*` tools (`git_remote` prompts; it is not auto-approved).
- **Remove (overbroad)** each `_migration.removeOverbroad` entry (currently `Bash(cat *)`, which bypasses the workspace read boundary; the Read tool covers it). Do not remove other Bash permissions (`ls`, `wc`, `pwd`, `which`, `mkdir`).
- **Remove (replaced deny)** each `_migration.removeReplacedDeny` entry from the live `deny` (currently `Read(//**/.env*)`: it denied the example files too; `hooks/secret-detector.sh` now guards `.env` names in Read, Grep, Write and Edit and passes `.env.example`, `.env.sample`, `.env.template` and `.env.dist`). Remove it only when the staged hooks section already has the secret-detector entry with the template's full matcher. Otherwise keep it and report `kept <entry>: secret-detector matcher not updated`: removing it then would leave `.env` unguarded. This is the one exception to "never remove" below, for exactly the listed strings.
- **Deny entries:** add every template `deny` entry the live array lacks (create it if absent). **Never remove** a live `deny` entry (except the replaced one above): they are security controls that may have been added outside this skill. Report live-only entries. `_deny_read_comment` in the template explains the secret-file rules.
- **Ask entries:** add every template `ask` entry the live array lacks (`caffeinate` and `pkill -x caffeinate`, the github MCP write tools, edits to any `.mcp.json`; none for `~/.claude/settings*.json`, which the hook denies before any rule runs). **Never remove** a live `ask` entry; report live-only ones. An ask rule prompts even in auto mode and wins over a matching allow. Prompts are invisible to the model, so the report carries one line: "the new ask entries prompt; confirm by running one".

### Plugins

Add every template `enabledPlugins` entry the live object lacks.

### Hooks

Read the template's `hooks` object (PreToolUse, PostToolUse, PostToolUseFailure, SessionStart), which references the scripts linked in Step 2.

- **Skip a hook that is not executable**, whether new or already wired (the merge never removes a wired one): a skipped script still logs a hook error on every tool call. Name it in the report as a control that is off; the next run after the fix wires it.
- **No `hooks` key live:** add the template's `hooks` without its `_comment` keys. **A `hooks` key live:** merge, adding each template entry not present, matching on the **(event key, `matcher`, script path) triple**; never remove a custom hook.
- **The event key is part of the identity.** One script may appear under several events with the same matcher (a script on both `PreToolUse` and `PostToolUse` at `"*"`). Keyed on (matcher, script) alone those collapse, and a live file with only the `PreToolUse` entry looks fully merged.
- **The github guard's command holds the placeholder `<checkout>`:** fill it with the checkout's real path (Step 0) before the merge or comparison, and never write the placeholder to the live file.- **Changed-matcher caveat.** The merge keys on (matcher, script path), so a template entry whose matcher string changed since it was installed adds a duplicate or leaves the stale one. When the drift assertion reports a matcher mismatch, replace the live entry's matcher with the template's full string in the staged file (never duplicate the entry) and list old and new in the change list.

**Drift assertion (run every time, after the merge; fail loud; against the staged file until the person has run the copy, then against the live one).** For every hook script in the roster (`hooks/<name>.sh` lines), assert both:

1. **Symlinked:** `~/.claude/hooks/<name>.sh` exists, resolves to the repo copy and is executable.
2. **Matcher-wired with the exact template matcher under EVERY event the template registers it on:** for each event key where the template references `$HOME/.claude/hooks/<name>.sh`, the file has an entry under that same event key referencing that script, with a `matcher` byte-identical to the template's. Presence is not enough: a stale matcher (missing a newly guarded tool) leaves the control partially dead. Assert per event, not per script: a script on three events live on only one is worse than uninstalled.

Report each failure in the summary: `DRIFT: <script> unsymlinked` / `not executable (this control is OFF until a PR commits it as 100755)` / `unwired on <event>` / `matcher differs on <event> — live: <live>, template: <template>`, and do not report the hooks section as "Already configured" while any assertion fails. A hook script in the repo with no template matcher entry is also a loud failure (roster and template out of step), and `status` reports it as not wired.

**The github MCP guard.** The template's github entry (matcher `^mcp__github__.*$`, every tool of the `github` server) runs `/bin/bash -p '<checkout>/tools/github-mcp/guard.sh' || exit 2` (`-p` keeps the shell from reading startup files; `|| exit 2` makes a guard that cannot start block the call). It is not a `hooks/*.sh` script and is never linked: it runs from the live checkout (`tools/github-mcp/README.md`) and denies every call unless that checkout is reviewed code: on `main`, no tracked file changed, `HEAD` on `origin/main`, the guard and launcher equal to their committed versions. Assert:

- the live entry's matcher and command are byte-identical to the template's with `<checkout>` filled in. The merge never updates either, so a live entry with an older matcher or another path (the old root-owned folder, another checkout) is `DRIFT: matcher differs` / `command differs`: replace it in place in the staged file (never add a second guard entry beside it) and list old and new;
- the github lines of `status` are all `ok` (clean main with `HEAD` on `origin/main`, the binary matching `tools/github-mcp/server.sha256`, the server registered at this checkout with no arguments or environment and not also at project scope, the guard hook pointing at it). A `STALE github` or `MISSING github` line is a failure: report `DRIFT: github MCP guard missing` / `command differs`, and never edit or copy the guard.

**The other guards' commands are compared too.** `protected-paths-guard.sh`, `secret-detector.sh`, `destructive-blocker.sh`, `git-mcp-guard.sh`, `git-mcp-redirect.sh` and `gh-block.sh` use the command `/bin/bash -p "$HOME/.claude/hooks/<script>.sh" || exit 2` (Claude Code blocks only on exit 2, so a bare command that fails to start, a missing link or a lost execute bit, lets the call through). The live `PreToolUse` entry for each must have a `command` byte-identical to the template's, not only the same matcher: the merge reads the script path anywhere in the command, so a live entry with the older bare `$HOME/.claude/hooks/<name>.sh` looks present and nothing replaces it. Report `DRIFT: <script> command differs on PreToolUse — live: <live>, template: <template>`, replace the command in place in the staged file, and list old and new. `status` reports the bare form as `STALE`. `protected-paths-guard.sh` also protects this skill's own work: once wired, an unwired or stale entry is `DRIFT` like any other.

### Auto mode

`autoMode` is a security control (the classifier's rules), read only from user, managed or `--settings` scope, and it applies to every session on the machine. Read the template's `autoMode` lists (`environment`, `soft_deny`, and any `allow` or `hard_deny`) with the keys starting with `_` left out: they hold no placeholder and are merged as written. Each list is handled on its own and written list by list, never as a copy of the template object. Read `skillOverrides` too.

- **List absent from live `autoMode`:** add the template list (create `autoMode` if needed).
- **Live list contains `"$defaults"`:** add each template entry not already present (exact string) after the live entries, and list each added entry's text in the change list: these change the classifier for every session. Never remove or reword a live entry; report the live-only ones. A template entry reworded since the last run leaves its old string live as one of those: name it as superseded in the report, and the person removes it by hand.
- **Live list lacks `"$defaults"`:** it REPLACES the built-in list, which is what `/auto-mode-setup` writes when you accept its draft (it spells the defaults out, often pinned to the repo it ran in). Do not merge into it. Report `DRIFT: autoMode.<list> has no "$defaults"`; round 2 shows the live list beside the template list, offers to carry chosen live-only entries over, and asks: *Replace with the template's list, backup kept (Recommended)* or *Leave it, reported as DRIFT*. The settings backup above is the backup.
- **`skillOverrides`:** add each template key that is absent (`auto-mode-setup: "off"` turns off the command and its end-of-turn offer, so a per-repo draft cannot replace the list again; the rest are in **Start context**). A live key with another value is the person's choice: report it, never overwrite. An added key disables a command, so name it in the report.
- **Live `allow` or `hard_deny`** (not in the template): leave it, but report whether it has `"$defaults"`. A live `allow` without it replaces the built-in exceptions and can be far more permissive than intended; a `hard_deny` without it drops the built-in exfiltration rule.

**Drift assertion (every run; fail loud):** each template list exists live (staged) with `"$defaults"` and every template entry. After the person has run the copy, run `claude auto-mode config` and check the effective lists hold them. A `--settings` file with no `autoMode` inherits this user-scope block: entries from each scope are combined (code.claude.com/docs/en/auto-mode-config).

### Start context

The template's `skillOverrides` (beyond `auto-mode-setup`), `syncClaudeAiSkills` and `syncClaudeAiPlugins` cut about 5.1k tokens from every session start (42.6k to 37.4k, measured 2026-11-09). The overrides switch off built-in skills not used locally; the sync keys switch off every claude.ai-synced skill and plugin (today the engineering plugin). Trade-off: claude.ai skills, `skill-creator` included, no longer load locally.

- Sync key absent: add it with the template value (`false`). Present, any value: leave it and report it.
- `skillOverrides` keys: merged per key, as under **Auto mode**.

### Status line

Read the template's `statusLine` object (without its `_comment` key). No `statusLine` live: add it. Already present: skip, never overwrite a custom one. Its command references `$HOME/.claude/statusline.sh`, linked in Step 2.

### Stage the file

**Preserve all other fields** (`effortLevel`, `voiceEnabled`, custom keys) exactly. The file is put in one fixed order by `tools/install-copies.sh order <file>`, never by hand: it only reorders (no key, entry or value is added, dropped or changed, and an unknown key stays after the known ones), and the order is documented in the script header and tested.

Write the merged result to `~/.claude/settings.json.new-<YYYYMMDD-HHMMSS>` (the backup's date and time; the name does not end in `.json`, so the hook lets the agent write it) and `chmod 600` it (the Write tool creates it with the default mode). Then run `bash <root>/tools/install-copies.sh order ~/.claude/settings.json.new-<stamp>` with the output redirected to `~/.claude/settings.json.new-<stamp>.ordered`, `mv` that over the staged file once non-empty, and `chmod 600` again. `<root>` is the repo root. If `order` exits non-zero, stop and report it: never stage an unordered file. Last, `jq empty` the staged file. The `cp` is a line of the final block; the live file is unchanged until the person runs it, and nothing in this step has taken effect before that. A first run with no `settings.json` stages the same way, and the copy creates it.

**Change list (for the final message).** Every entry added, removed or changed between the live file and the staged one, not a chosen subset, so the person can see what the `cp` applies. Group it: hook entries added (event, matcher, command) and each command or matcher replaced (old, then new); each enforced key overwritten (old, then new) and each new `env` key; the text of each `autoMode` entry added; the `allow`, `deny` and `ask` entries added; every entry removed by the migration lists (the replaced `Read(//**/.env*)` deny named as such); `deniedMcpServers`, `skillOverrides`, `statusLine` command and plugin additions; the live-only `deny` and `ask` entries; and the path of the staged file, for anyone who wants to open it first. A reordered list is not a change.

## Step 7: Report and the final block

The final message has three parts.

**1. The summary table.**

```
## Setup Summary

Prerequisites: jq / node / brew / claude; Darwin arm64: yes / no; gh: "needs gh logged in" line (always)
Roster: one row per artifact of `roster` (never a hardcoded list), per category, Status: Installed / Already installed / Conflict
  Rules may be `Replaced file (byte-match)`; hooks may be `Linked, not executable (OFF)`
Status line / tool scripts: Installed / Already installed / Conflict (+ the shell line when not in ~/.zshrc)
Git MCP: Registered (in the block) / Already correct / Repaired (in the block); only `Already correct` when the config runs this checkout's server
GitHub MCP: install.conf ok / MISSING (in the block) / STALE (<key>); github checkout, binary, server, guard hook: ok / the fix the `status` line prints
Global CLAUDE.md: Created (starter) / Skipped / Up to date / evaluation: <sections present, missing, thin>
Settings: backup <path> mode 600 / none; env keys enforced; autoCompactWindow Added / Overwritten (<old> → 533000) / Already configured, per-model overrides <list or none>; promptCacheTtl Added 1h / Already set (<value>) / Skipped (older Claude Code), overrides <NOTE list>; permissions added / removed (migration); deny and ask added, live-only ones; ask entries prompt (confirm by running one); hooks Added / Already configured / Merged; skipped hooks; Protected checkout: marker ok / MISSING; status line Added / Already configured; auto mode per list Added <n> / Already configured / DRIFT, live allow and hard_deny with or WITHOUT "$defaults", skillOverrides added; start context per key; plugins added; settings file: staged <path>, live unchanged until the copy
DRIFT lines: every one, with its fix
```

**2. The staged settings changes** (Step 6, Change list), listed in full.

**3. One block of plain terminal commands**, values filled in, only the lines that apply, no comments, in this order. Explanation goes in prose around the block, and a slash command (`/plugin uninstall …`, `/setup-toolkit`) gets its own block. The lines:

```
brew install node
touch '/abs/checkout/.protected-checkout'
claude mcp add --scope user git-mcp -- node '/abs/checkout/tools/git-mcp/server.js'
grep -qxF 'source ~/.claude/tools/shell-init.zsh' ~/.zshrc 2>/dev/null || printf '%s\n' 'source ~/.claude/tools/shell-init.zsh' >> ~/.zshrc
(umask 077; d="$HOME/.claude"; f="$d/install.conf"; if [ -e "$f" ] || [ -L "$f" ]; then echo 'install.conf exists; edit it by hand'; else t=$(mktemp "$d/install.conf.XXXXXX") && printf '%s\n' 'github_write_owners=<owners, or *>' 'github_keychain_account=<id -un value>' > "$t" && chmod 600 "$t" && mv -n "$t" "$f" && ls -l "$f"; fi)
cp ~/.claude/settings.json.new-<stamp> ~/.claude/settings.json && rm ~/.claude/settings.json.new-<stamp>
```

A wrong git-mcp entry gets `claude mcp remove --scope user git-mcp` on the line before the add. The `*` stays inside single quotes (unquoted, zsh would glob it). The GitHub MCP chain (Step 4) is the block's last line and is joined to the `cp` line with `&&`, so nothing registers unless the settings, with the guard hook and the github denies, are in place first; the store link stays last. These denies bind only the agent's tool calls, not the person's terminal: the `Bash(*install.conf*)` ask, the `Edit` deny on install.conf, and the protected-paths guard on `settings*.json`.

Then one prose line: restart Claude Code and run `/setup-toolkit` once more, with that slash command in its own block. On a set-up machine that second run asks nothing. It does what `check` cannot: it asserts the git-mcp shape, checks the live file for drift, runs `claude auto-mode config` against the lists, and confirms the github lines of `status` are `ok`. If any file was changed, say to restart.

## Stop Conditions

- Do not modify any project-level files — this skill only touches `~/.claude/`. It never runs `sudo`.
- Do not overwrite `~/.claude/CLAUDE.md` without user confirmation.
- Stop on a missing `jq`, a non-plain or temp-folder checkout path, or (after round 2's *Stop and show it*) a `settings.json` of unexpected structure.
