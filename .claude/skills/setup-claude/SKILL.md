---
description: "Set up or update global Claude Code configuration — CLAUDE.md, permissions, plugins, MCP servers, skills, agents, and hooks. Run from the ai-toolkit repo to apply best practices globally."
disable-model-invocation: true
---

# Setup Claude

Configure the global Claude Code environment from this repo's templates and skills. Idempotent — safe to run repeatedly. Each section reports what changed.

**macOS only.** The steps assume macOS: Homebrew install hints, `/usr/bin/jq`, the login keychain and root:wheel copies.

**What it overwrites.** Most of the settings merge only adds and never removes. Four settings are enforced instead: added when missing and overwritten when different, and every change is reported (Step 10):

- `env`: the session-quality survey and the `/feedback` upload off, and claude.ai's cloud MCP connectors off;
- `attribution`: no commit trailer, PR footer or session link;
- `autoCompactWindow`: 500000;
- `enableAllProjectMcpServers`: `false`.

Read Step 10 before the first run if you rely on other values for any of them.

**What it asks.** The prompt cache TTL (`promptCacheTtl`, `subagentPromptCacheTtl`) is opt-in: with no such key in the template, Step 10 asks before it writes either one and never overwrites a value you set.

**`/setup-claude check`:** read-only. Run only `bash tools/install-copies.sh status` (resolve the path from this skill's location: `../../../tools/install-copies.sh`), show its output, and stop. It lists the install-time settings, the github MCP guard, the `~/.zshrc` line and every unlinked or conflicting link against `main`, and changes nothing.

## Step 0: Check prerequisites

Check each tool with `command -v <tool>`, except gh: any Bash command naming gh is blocked for agents
(`hooks/gh-block.sh`). If any is missing, **stop**: print the missing rows with their install hint and ask the user
to re-run `/setup-claude` once they are installed. Install nothing yourself. For gh, give the user
`gh auth status` (never `--show-token`) in a markdown code block and ask for its output: if gh is missing or not logged in, **warn** and
continue.

| Tool | Needed by | Install (macOS) |
|------|-----------|-----------------|
| `jq` | every hook parses its input with it | recent macOS ships `/usr/bin/jq`; otherwise `brew install jq` (it must then be on the PATH Claude Code starts with: the guards fall back to `/usr/bin` only) |
| `node` + `npm` | git-mcp-server | `brew install node` |
| `gh` | the user's own commands (agents are blocked from it); a missing login only warns | `brew install gh`, then `gh auth login`, answering **No** to "Authenticate Git with your GitHub credentials?" |

## Step 1: Read current state

Read these files to understand what's already configured:

- `~/.claude/CLAUDE.md` (may not exist)
- `~/.claude/settings.json` (may not exist)
- `~/.claude.json` (user-scope MCP server config; may not exist)
- This skill's templates:
  - `templates/global-claude-md.md` — the CLAUDE.md checklist
  - `templates/safe-permissions.json` — permissions, plugins, hooks config, and migration rules
- Repo root artifacts (resolve from this skill's location via `../../../`):
  - `agents/*.md` — global agent definitions
  - `hooks/*.sh` — global hook scripts
  - `rules/*.md` — global always-on rule files (no frontmatter — distinct from project-scoped `.claude/rules/`)
  - `tools/statusline.sh` — status line script
  - `tools/workspace-lock/workspace-lock.sh` — overnight-orchestrator lock script
  - `tools/shell-init.zsh` — `~/.zshrc` sources it through its `~/.claude/tools/` link; it loads the `ait` zsh helpers (`tools/ait.zsh`)
  - `tools/install-copies.sh` — the status of what is installed outside the checkout (Step 8b)

## Step 2: Install global agents

Discover all agent definitions at the repo root:

```
agents/*.md
```

For each discovered agent:

- **No existing symlink at `~/.claude/agents/<name>.md`:** Create it:
  ```bash
  mkdir -p ~/.claude/agents
  ln -s <absolute-path-to-agents/name.md> ~/.claude/agents/<name>.md
  ```
- **Existing symlink pointing to the correct target:** Skip.
- **Existing symlink pointing elsewhere or existing file:** Report conflict. Do not overwrite without user confirmation.

Verify each symlink resolves to a readable file with valid YAML frontmatter (name, description, model, tools).

## Step 3: Install global hooks

Discover all hook scripts at the repo root:

```
hooks/*.sh
```

For each discovered hook:

- **No existing symlink at `~/.claude/hooks/<name>.sh`:** Create it:
  ```bash
  mkdir -p ~/.claude/hooks
  ln -s <absolute-path-to-hooks/name.sh> ~/.claude/hooks/<name>.sh
  ```
- **Existing symlink pointing to the correct target:** Skip.
- **Existing symlink pointing elsewhere or existing file:** Report conflict. Do not overwrite without user confirmation.

Verify each symlink resolves and the target script is executable (`chmod +x` if needed).

## Step 4: Install global skills

Discover all skills in the repo's `skills/` directory:

```
skills/*/SKILL.md
```

For each discovered skill:

- **No existing symlink at `~/.claude/skills/<name>`:** Create it:
  ```bash
  mkdir -p ~/.claude/skills
  ln -s <absolute-path-to-skills/name> ~/.claude/skills/<name>
  ```
- **Existing symlink pointing to the correct target:** Skip.
- **Existing symlink pointing elsewhere or existing directory:** Report conflict. Do not overwrite.

Verify each symlink resolves to a readable SKILL.md.

### Project-local install (alternative to global)
To make skills invocable in ONE project only, symlink into that project's `.claude/skills/`:
`ln -s <relative-path-to>/ai-toolkit/skills/<name> <project>/.claude/skills/<name>`.
Use this when a workspace's CLAUDE.md promises project-local skills — a global install also
works but exposes the skills to every project.

## Step 5: Install global rules

Discover all global rule files at the repo root (see [ADR 0009](../../../docs/adr/0009-global-rules-distribution.md)):

```
rules/*.md
```

These are always-on rules with no frontmatter — a different artifact class from project-scoped `.claude/rules/*.md` (which activate on `paths` frontmatter). Do not add frontmatter to them.

For each discovered rule:

- **No existing file or symlink at `~/.claude/rules/<name>.md`:** Create the symlink:
  ```bash
  mkdir -p ~/.claude/rules
  ln -s <absolute-path-to-rules/name.md> ~/.claude/rules/<name>.md
  ```
- **Existing symlink pointing to the correct target:** Skip.
- **Existing plain file (not a symlink):** Compare byte-for-byte: `cmp -s <existing> <repo-copy>`.
  - Identical → replace the file with the symlink. This auto-replace is deliberately **more permissive** than Steps 2–4 (which never overwrite anything); it is safe because the byte-match precondition guarantees nothing divergent can be lost.
  - Different → report conflict with a diff summary. Do not overwrite without user confirmation.
- **Existing symlink pointing elsewhere:** Report conflict. Do not overwrite without user confirmation.
- **Existing broken symlink (target does not exist) or existing directory:** Report conflict. Do not remove or overwrite without user confirmation.

Verify each symlink resolves to a readable file.

Note: there is no prune step — a rule removed from `rules/` leaves its symlink behind; report any dangling symlink in `~/.claude/rules/` as a conflict instead of deleting it.

## Step 6: Install global MCP servers

Install MCP servers at user scope so they are available across all projects.

### Git MCP server

The server provides structured git tools that replace Bash git wildcards — better input validation, structured output, and individual permission scoping.

**Run it as an installed binary, never through `npx`.** This is the fix for a measured fault, not a preference — see the diagnosis below. The pinned version is:

```
GIT_MCP_VERSION=2.15.1
```

**Step 6a — install the binary if absent.**

```bash
which git-mcp-server
```

- **Found:** check the version with `git-mcp-server --version 2>&1 | head -1` and reinstall only if it differs from the pin.
- **Not found:** `npm i -g @cyanheads/git-mcp-server@<GIT_MCP_VERSION>`

**Step 6b — assert the config invokes that binary directly.** Presence is not enough:

```bash
claude mcp list 2>&1
```

- **Absent:** have the user add it — `claude mcp add --scope user git-mcp -- git-mcp-server`
- **Present as `git-mcp-server`:** correct, skip.
- **Present as `npx …` (any form):** this is the broken shape. Have the user repair it —
  ```bash
  claude mcp remove --scope user git-mcp
  claude mcp add --scope user git-mcp -- git-mcp-server
  ```
  Report it as `Repaired (was npx)`, never as "already installed".

`claude mcp add` and `claude mcp remove` are denied to agents (the template's deny list): a server
registered under another name would bypass every name-keyed MCP rule. Give the user the commands to run with the `!`
prefix, then re-run `claude mcp list` to check. Never get around the deny with `env …`, a full path or a wrapper.

A presence-only check is the exact defect Step 10's hook drift assertion exists to prevent, one section over: a stale entry passes a presence check while the thing it configures misbehaves. Assert the **shape**, not the key.

**Step 6c — repair EVERY user config, not just the active one.** `claude mcp add --scope user` writes to whichever config `CLAUDE_CONFIG_DIR` selects, so a machine that sets that variable (e.g. via `direnv`) has **two** user configs that drift independently:

```bash
echo "${CLAUDE_CONFIG_DIR:-<unset>}"
```

- **Unset:** one config, `~/.claude.json`. Done.
- **Set:** repair both — the active one as above, then the default: the user runs the same two commands prefixed with `env -u CLAUDE_CONFIG_DIR`. Verify both files afterwards:
  ```bash
  grep -A4 '"git-mcp"' ~/.claude.json
  grep -A4 '"git-mcp"' "$CLAUDE_CONFIG_DIR/.claude.json"
  ```
  Both must show `"command": "git-mcp-server"`. Report each file separately.

**Changes take effect on restart**, and existing sessions keep their old server until then.

#### Why not npx

`npx -y @cyanheads/git-mcp-server@latest` was the previous instruction here: `npx` wraps the server in a parent process that does not reliably forward signals, and `@latest` re-resolves against the npm registry on every spawn, and together they caused mid-session disconnects. The installed, pinned binary has neither problem and no version drift between machines.

## Step 7: Install status line

The repo includes a custom status line script at `tools/statusline.sh` (resolve from this skill's location: `../../../tools/statusline.sh`).

- **No existing symlink at `~/.claude/statusline.sh`:** Create it:
  ```bash
  ln -s <absolute-path-to-tools/statusline.sh> ~/.claude/statusline.sh
  ```
- **Existing symlink pointing to the correct target:** Skip.
- **Existing symlink pointing elsewhere or existing file:** Report conflict. Do not overwrite without user confirmation.

Verify the symlink resolves and the target script is executable (`chmod +x` if needed).

The `statusLine` config in `~/.claude/settings.json` is handled in the settings-update step (Step 10) along with other settings.json entries. The template's `statusLine` object defines the command reference.

## Step 8: Install tool scripts

Some skills invoke helper scripts from the repo's `tools/` directory that must be reachable at a stable, machine-independent path. Install **named** tool scripts (not the whole `tools/` tree) into `~/.claude/tools/`.

Scripts to install:

- `tools/workspace-lock/workspace-lock.sh` → `~/.claude/tools/workspace-lock.sh` (used by the `unattended-run` skill)
- `tools/shell-init.zsh` → `~/.claude/tools/shell-init.zsh` (`~/.zshrc` sources it; it loads the `ait` zsh helpers, `tools/ait.zsh`)

For each:

- **No existing symlink at `~/.claude/tools/<name>`:** Create it:
  ```bash
  mkdir -p ~/.claude/tools
  ln -s <absolute-path-to-tools/workspace-lock/workspace-lock.sh> ~/.claude/tools/workspace-lock.sh
  ```
- **Existing symlink pointing to the correct target:** Skip.
- **Existing symlink pointing elsewhere or existing file:** Report conflict. Do not overwrite without user confirmation.

Verify the symlink resolves and the target script is **executable** (`chmod +x` if needed) — these scripts are invoked **directly** (e.g. `$HOME/.claude/tools/workspace-lock.sh …`), so the executable bit is load-bearing (unlike `statusline.sh`, which is invoked as `bash <path>`). `shell-init.zsh` is the exception: it is **sourced**, not run, so it needs no executable bit.

**Never edit a shell rc file** (`~/.zshrc`, `~/.bashrc`, and `~/.zshenv` above all) to load them. If `~/.zshrc` does not already contain `source ~/.claude/tools/shell-init.zsh`, print that one line in the report for the user to add.

## Step 8b: Copied pieces (github MCP guard)

The github MCP launcher and guard cannot be symlinks: they are root-owned on purpose, so no session can edit the live guard. They go stale silently after a merge, so this step checks them. The logic lives in `tools/install-copies.sh` (tested by `tools/test-install-copies.sh`); do not re-implement it here.

Resolve the script from this skill's location (`../../../tools/install-copies.sh`), as `check` does. Never set any `ICOPIES_*` variable (they are test hooks) and never change repo state (stash, checkout, pull, reset, `update-index`) to get past a gate.

**Install-time settings (before anything installs).** This repository ships no owner's values: the github MCP guard's
write owners and the launcher's keychain account are read from `~/.claude/install.conf`, the user's own file (mode 600,
one `key=value` line each, read by a strict reader in `tools/install-copies.sh`, never sourced). The agent's Edit and
Write tools are denied on it and every Bash command naming it asks (Step 10). When the `install.conf` line of
`status` (item 1) is `MISSING` or `STALE`, do this before items 2-4:

- Ask the user for each value and offer no default (no value is anyone's name until the user types it):
  `github_write_owners`, the GitHub owners whose repos the github MCP write tools may target, space-separated, each
  `^[a-z0-9][a-z0-9-]*$` (this sets a security control's scope); `github_keychain_account`, the account of the
  launcher's `mcp-github` keychain item, `^[A-Za-z0-9._@-]+$`. Then the optional ones, each skippable: the three that fill the auto
  mode classifier's placeholders in Step 10 (an unset one drops the entries that name it): `github_username`, the
  user's GitHub login, one of the write owners (its entries count only once the installed root-owned guard lists it,
  that is after `ghm-install`); `lan_host`, the
  self-hosted host's LAN name ending in `.lan`, `.local` or `.home.arpa`; `router_ip`, the router's private
  (RFC 1918) address. A value that fails its check is asked again, never written.
- Show the user the whole file and the autoMode entries it would fill: the template's entries naming `<username>`,
  `<host>` or `<router.ip>`, with the values put in and those whose key is unset left out. Writing the file adds none
  of them: Step 10 asks again before any reaches the live settings. Then write it only on their explicit go typed in
  this session, with this command (each quoted line one checked `key=value`; add one quoted line per optional key the
  user set, nothing else):

  ```bash
  (umask 077; d="$HOME/.claude"; f="$d/install.conf"; [ ! -L "$f" ] && t=$(mktemp "$d/install.conf.XXXXXX") && printf '%s\n' 'github_write_owners=<owners>' 'github_keychain_account=<account>' > "$t" && chmod 600 "$t" && mv -f "$t" "$f" && ls -l "$f")
  ```
- Run `status` again: the `install.conf` line must read `ok`. A changed owner or account reaches the root-owned copies
  only when the user runs `ghm-install` again, which shows both values and the diff and asks before its `sudo` install.

1. Run `bash tools/install-copies.sh status` and keep its output for the report.
2. **Github MCP** `STALE` or `MISSING`: do not try to fix it (installing needs `sudo`, which agents do not have). Put `ghm-test`, then `ghm-install`, in the report for the user to run from a shell; a `github-mcp (install settings …)` line means the settings step above comes first. When the status is `ok`, say nothing more.
3. **`~/.zshrc`** `MISSING`: rc files are the user's; put the line it prints in the report (Step 8).
4. **Links** `UNLINKED` or `CONFLICT`: those are handled by Steps 2-5, 7 and 8 (run them first); anything still listed after those steps is a conflict to report.

## Step 9: Evaluate global CLAUDE.md

Read the checklist in `templates/global-claude-md.md` for what a good global CLAUDE.md covers.

- **If `~/.claude/CLAUDE.md` does not exist:** Show the user the starter template from the checklist. Ask them to review and customize before writing it.
- **If it exists:** Evaluate it against the checklist (required sections: Interaction Style, Code Changes, Communication). Report:
  - Which sections are present and well-covered
  - Which sections are missing or thin
  - Whether it exceeds the checklist's line target (35 lines with the optional orchestration sections, 30 without)
  - Specific suggestions for improvement (if any)

Present findings to the user. Only modify the file with explicit user approval.

Do not silently overwrite the user's global CLAUDE.md.

## Step 10: Update global permissions, plugins, hooks, and status line

Read `templates/safe-permissions.json` for:
- `env` — global env-var policy keys to enforce (added if missing, overwritten if different)
- `attribution` — commit/PR attribution policy to enforce (added if missing, overwritten if different)
- `autoCompactWindow` — the machine-wide compaction window to enforce (see **Auto-compact window**)
- `promptCacheTtl`, `subagentPromptCacheTtl` — optional: enforced when the template carries one, asked about when it does not (see **Prompt cache TTL**)
- `enableAllProjectMcpServers` — enforced `false` (added if missing, overwritten if different): each project `.mcp.json` server needs its own approval
- `deniedMcpServers` — MCP servers that must never connect (additive like `permissions.deny`, deduped by the `serverUrl` string: add missing entries, never remove live ones, report live-only ones); today GitHub's hosted server by URL
- `permissions.allow` — safe permissions to ensure are present
- `permissions.deny` — deny entries to ensure are present (security controls)
- `permissions.ask` — commands that always prompt (added if missing, never removed)
- `enabledPlugins` — plugins to ensure are enabled
- `autoMode` and `skillOverrides` — auto mode classifier context and the /auto-mode-setup switch (merged; see **Auto mode**)
- `_migration.removeBashGit` — old Bash git permissions to remove (replaced by MCP git)
- `_migration.removeOverbroad` — overbroad permissions to remove (e.g. `Bash(cat *)`, which bypasses the workspace read boundary; the Read tool covers it)

Read `~/.claude/settings.json` (or create `{}` if missing).

Template keys that start with `_` (`_comment`, `_env_comment`, `_migration` and the rest, at any depth) are notes for this skill: never write one to the live file, including inside a copied hook entry or the `statusLine` object. (`_migration` is still read for its remove lists below; it is never copied.)

**Back it up before the first write in this step** (skip only when the file did not exist). The backup name must
carry the date AND the time (`YYYYMMDD-HHMMSS`), the copy is created mode 600 (the file holds MCP server and env key
names), and an existing backup is never overwritten (`cp -n`). Check the result with `ls -l` only; never open a
backup. Report the path in the Step 10 report.

```bash
(umask 077; b="$HOME/.claude/settings.json.bak-$(date +%Y%m%d-%H%M%S)-settings"; cp -n "$HOME/.claude/settings.json" "$b" && chmod 600 "$b" && ls -l "$b")
```

### Environment variables

Read the `env` object from `templates/safe-permissions.json`. These are **enforced** global-policy keys — unlike the additive `allow`/`enabledPlugins` merges:

- **Key absent from live `env`:** add it with the template value (create the `env` object if the live settings has none).
- **Key present with the template value:** skip.
- **Key present with a different value:** overwrite to the template value and report the change.

**Never remove or alter a live `env` key that is not in the template** (e.g. `CLAUDE_CODE_NO_FLICKER`) — preserve those exactly, the same as any other custom field.

Note: `$CLAUDE_CONFIG_DIR/settings.json` is commonly a symlink to `~/.claude/settings.json`; where it is, this one write updates both config roots.

### Attribution

Read the `attribution` object from `templates/safe-permissions.json`. **Enforced** exactly like `env` (overwrite, not additive), because it is the mechanical form of the global CLAUDE.md no-attribution rule — the harness re-applies the `Co-Authored-By` / "Generated with Claude Code" attribution by default even against that rule, and only this setting stops it:

- **`attribution` absent from live settings:** add it with the template value.
- **`attribution` present and identical:** skip.
- **`attribution` present with any different value:** overwrite to the template value and report the change.

`attribution.commit` and `attribution.pr` are **strings** (`""` suppresses the trailer/footer), and `sessionUrl` is a **boolean** (Claude Code v2.0.62+, deprecating `includeCoAuthoredBy`) — do not write booleans for `commit`/`pr`.

### Auto-compact window

Read the top-level `autoCompactWindow` from `templates/safe-permissions.json` (500000). **Enforced** like `env`:
add it when absent, overwrite a different live value and report the change. It sets when every model compacts;
without it, 1M-window models (Opus 5.x, Fable, Sonnet 5) compact near 967k, and every turn re-sends that context.

**Per-model override check (run every time; fail loud):** a live `modelSettings.<model>.autoCompactWindow`, which
is what `/autocompact` writes, beats the top-level key in the same file for that model, so the enforced value would
silently not apply to it. Report each one as `DRIFT: modelSettings.<model>.autoCompactWindow = <value> overrides
autoCompactWindow`, and remove that key only on the user's go, keeping the model's other keys (`effortLevel`).
Delete an emptied `modelSettings.<model>` object.

Not touched: the `CLAUDE_CODE_AUTO_COMPACT_WINDOW` env var beats this key, so a session that sets it keeps its own
window. The status line's `used_percentage` counts
against the model's full window, so it reads low at compaction time.

### Prompt cache TTL

Read the top-level `promptCacheTtl` and `subagentPromptCacheTtl` from `templates/safe-permissions.json`. Each takes
`"5m"` or `"1h"` and needs Claude Code v2.1.242 or later. `promptCacheTtl` sets how long the main conversation's cache
survives an idle gap; `subagentPromptCacheTtl` does the same for everything else (subagents, workflows, teammates,
forks, compaction). Neither is a security control.

- **The template carries a key:** it is **enforced** like `autoCompactWindow`: add it when absent, overwrite a different
  live value and report the change.
- **The template does not carry it (the default here): ask first.** Do this only for a key the live settings lack: a
  live value of either kind is the user's choice, so report it and leave it. Before asking, say:
  - on a Claude subscription the main conversation already gets one hour within the plan's included usage, so
    `promptCacheTtl: "1h"` only changes what happens after that usage runs out into usage credits; with an API key or
    a cloud provider the default is five minutes;
  - an hour of cache costs more to write (2x the base input price, against 1.25x for five minutes) and pays off only
    when the session sits idle for between 5 and 60 minutes; steady bursts of work pay more and gain nothing;
  - a conversation left idle on the one-hour TTL can be compacted by Claude Code on its own (`idleCompaction: false`
    turns that off; this skill does not set it);
  - `subagentPromptCacheTtl: "1h"` raises the write cost of every subagent, compaction and fork request, and most of
    those are short-lived, so recommend leaving it off unless the user's sessions regularly resume after five minutes.

  Ask for each key on its own and write `"1h"` only on a yes typed in this run. A no writes nothing (never `"5m"`, which
  would lower a subscription's default), and the question comes back on the next run while the key is absent.

**Override check (every run, the opt-in case too):** `CLAUDE_CODE_PROMPT_CACHE_TTL` and
`CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL` (in the live `env` or the shell) beat the setting, and `FORCE_PROMPT_CACHING_5M=1`
beats both. Report each one found as `NOTE: <variable> overrides promptCacheTtl`; write the setting anyway only if
the user asks for it after hearing that.

### Permissions

**Add** any permission from the template's `allow` array that is not already present.

**Remove (Bash→MCP migration):** Remove any permission listed in `_migration.removeBashGit` — these are Bash git wildcards replaced by MCP git tools:

| Remove (Bash) | Replaced by (MCP) |
|---|---|
| `Bash(git status*)` | `mcp__git-mcp__git_status` |
| `Bash(git diff*)` | `mcp__git-mcp__git_diff` |
| `Bash(git log*)` | `mcp__git-mcp__git_log` |
| `Bash(git show*)` | `mcp__git-mcp__git_show` |
| `Bash(git remote -v*)` | `mcp__git-mcp__git_remote` (prompts — not auto-approved) |
| `Bash(git tag*)` | `mcp__git-mcp__git_tag` (prompts — not auto-approved) |
| `Bash(git stash list*)` | `mcp__git-mcp__git_stash` (prompts — not auto-approved) |
| `Bash(git add *)` | `mcp__git-mcp__git_add` |
| `Bash(git branch*)` | (prompts — not auto-approved) |

**Remove (overbroad):** Remove any permission listed in `_migration.removeOverbroad` (currently `Bash(cat *)`).

Only remove these specific listed patterns. Do not remove other non-git Bash permissions (`ls`, `wc`, `pwd`, `which`, `mkdir`).

**Deny entries:** Read `permissions.deny` from the template. **Add** any entry not already present in the live `deny` array (create the array if absent). **Never remove** existing live `deny` entries — they are security controls that may have been added outside this skill; report any live-only entries instead of touching them. Append in template order: a `Read(!…)` exception counts only after the rule it carves from, in the same file, so never add one without its rule or ahead of it. If the live array already has `Read(.env.*)`, put the template's `!` lines directly after it. Report any unanchored `.env` rule that comes after the `!` lines: the last matching rule wins, so it would deny `.env.example` again. `_deny_read_comment` in the template explains the secret-file rules.

**Ask entries:** Read `permissions.ask` from the template (`caffeinate` and `pkill -x caffeinate`, which start and stop a keep-awake power assertion, the
github MCP write tools, and edits to any `.mcp.json`). **Add** any entry not
already present in the live `ask` array (create it if absent); **never remove** a live `ask` entry, and report
live-only ones. An ask rule prompts even in auto mode and wins over a matching allow rule, so a live allow
entry never suppresses the prompt. Prompts are invisible to the model: after adding an entry, ask the user to
confirm that the command prompts.

### Plugins

**Add** any plugin from the template's `enabledPlugins` that is not already present.

### Hooks

Read the `hooks` object from `templates/safe-permissions.json`. This defines PreToolUse, PostToolUse, PostToolUseFailure and SessionStart hooks that reference the scripts installed in Step 3.

- **If `~/.claude/settings.json` has no `hooks` key:** Add the entire `hooks` object from the template, leaving out its `_comment` keys.
- **If it already has `hooks`:** Merge — add any hook entries from the template that are not already present, matching on the **(event key, `matcher`, script path) triple**. Do not remove existing custom hooks.

**The event key is part of the identity, not a container.** One script may legitimately appear under
several event keys with the *same* matcher — for example a script registered on both `PreToolUse`
and `PostToolUse` at `"*"`. Keyed on (matcher, script) alone those template entries collapse into
one, so a live settings file carrying only the `PreToolUse` entry looks fully merged and nothing is
added.

**Changed-matcher caveat (the additive merge cannot fix these):** because the merge keys on
(matcher, script path), a template entry whose **matcher string changed** since it was installed
does not match the live entry — the merge either adds a duplicate or silently leaves the live
matcher stale. When the drift assertion below reports a matcher mismatch for a script, apply the
change to live settings by **explicit diff**: replace the live entry's matcher with the template's
full matcher string for that script (never duplicate the entry), show the user the before/after,
and re-run the assertion.

**Drift assertion (run every time, after the merge; fail loud):** for **every** hook script
discovered in Step 3 (`hooks/*.sh` — the filesystem is the roster), assert BOTH:

1. **Symlinked** — `~/.claude/hooks/<name>.sh` exists, resolves to the repo copy, and is executable.
2. **Matcher-wired with the exact template matcher, under EVERY event the template registers it
   on** — for each event key where the template references `$HOME/.claude/hooks/<name>.sh`, live
   `~/.claude/settings.json` must have an entry under **that same event key** referencing that
   script, with a `matcher` string **byte-identical to the template's**. Comparing mere presence
   is not enough — a stale matcher (e.g. missing a newly guarded tool) passes a presence check
   while leaving the control partially dead.

   **Assert per event, not per script.** A script registered on three events that is live on only
   one is *worse than uninstalled*, and it passes any per-script check.

Report each failure explicitly in the Step 11 summary (`DRIFT: <script> unsymlinked` /
`DRIFT: <script> unwired on <event>` / `DRIFT: <script> matcher differs on <event> — live:
<live>, template: <template>`) and do not report the hooks section as "Already configured" while
any assertion fails. A hook script that exists in the repo but has no template matcher entry is
also a loud failure (roster/template desync).

**GitHub MCP guard (assert when the template wires it; fail loud):** the template's github MCP entry (matcher
`^mcp__github__.*$`: every tool of the github server) runs
`/usr/local/libexec/mcp-github/guard.sh`, which is not a `hooks/*.sh` script and is never symlinked: the user installs
it root-owned from `tools/github-mcp/guard.sh` (see `tools/github-mcp/README.md`), so no session can edit the live
copy. Assert:

- the live entry's matcher and command are byte-identical to the template's (the command is
  `/usr/local/libexec/mcp-github/guard.sh`). The additive merge never updates a matcher, so a live entry with an older template's `mcp__github__.*` is `DRIFT: matcher differs`: show the user the diff and change it on their go, replacing the
  entry's matcher in place (never add a second guard entry beside it);
- `guard.sh` and `launch` exist in `/usr/local/libexec/mcp-github`, and that folder and both files are root:wheel,
  mode 755.

```bash
bash tools/install-copies.sh status
```

The Bash deny `Bash(*mcp-github*)` blocks a raw `stat` of that folder, so use this script (its command line does not
name it). Its github-mcp lines cover the folder (root:wheel 755) and both files (content, root:wheel 755). Any `STALE github-mcp` line is a failure. Report `DRIFT: github MCP guard missing` /
`not root-owned` / `command differs`, and never install or copy it yourself.

The other hook commands reference `$HOME/.claude/hooks/<script>.sh` — these are the scripts installed in Step 3.

### Auto mode

**Render the template's `autoMode` first.** Its entries carry the placeholders `<username>`, `<host>` and
`<router.ip>`, which only `~/.claude/install.conf` fills (the optional `github_username`, `lan_host` and `router_ip`
keys, Step 8b). Run `bash tools/install-copies.sh automode` (resolved as in Step 8b): it prints the template's
`autoMode` lists as JSON with each placeholder filled and every entry whose key is unset dropped, and exits 1 on an
invalid settings file (then stop this section and report it; Step 8b's settings sub-step fixes the file). A
`<username>` entry is kept only while `github_username` is a write owner in the installed root-owned guard; otherwise
it prints why on stderr: pass that line on in the report. Those rendered lists stand in for the template's everywhere
below: the exact-string merge, the superseded-entry report and the drift assertion with its `claude auto-mode config`
check. Never write a placeholder to the live file, and never merge the raw template lists.

**Entries filled from install.conf need the user's go.** They widen what the classifier trusts (the GitHub login's
repositories and images, the LAN host, the router), and the settings file alone must not do that. Run
`bash tools/install-copies.sh automode --valued`: it prints just those rendered entries. Before the merge, show the user
every one of them that the live list does not hold yet, word for word with its list name, and add them only on the
user's explicit go typed in this session. Without that go, merge the other rendered entries and leave these out:
never add one silently, never add first and report after. An entry the user declined in this run is not missing for
the drift assertion below; name it in the report.

Read `autoMode` (rendered, above) and `skillOverrides` from `templates/safe-permissions.json`. `autoMode` is a security control
(the auto mode classifier's rules), it is read only from user, managed or `--settings` scope, and it applies to
every session on the machine. Each list in it (`environment`, `allow`, `soft_deny`, `hard_deny`) is handled on its
own, and written list by list, never as a copy of the template object. Template keys starting with `_`
(`_autoMode_comment`, `_migration`) are notes for this skill and are never written to the live file.

- **List absent from live `autoMode`:** add the rendered list (create `autoMode` if needed).
- **Live list contains `"$defaults"`:** add each rendered entry that is not already present (exact string), after
  the live entries, and list each added entry's text in the report: these change the classifier for every session.
  Never remove or reword a live entry; report the live-only ones. A template entry reworded since the last run
  leaves its old string live as one of those: name it as superseded and remove it only on the user's go.
- **Live list lacks `"$defaults"`:** it REPLACES the built-in list, which is what `/auto-mode-setup` writes for
  `environment` when you accept its draft (it spells the defaults out, often pinned to the repo it ran in). Do not
  merge into it. Report `DRIFT: autoMode.<list> has no "$defaults"`, show the live list beside the template list,
  and offer to carry chosen live-only entries over, all BEFORE asking for the go. Replace it only on the user's
  explicit go, after backing up `~/.claude/settings.json` with the command below: date and time in the name, mode
  600, never over an existing backup (`cp -n`), checked with `ls -l` only.

  ```bash
  (umask 077; b="$HOME/.claude/settings.json.bak-$(date +%Y%m%d-%H%M%S)-automode"; cp -n "$HOME/.claude/settings.json" "$b" && chmod 600 "$b" && ls -l "$b")
  ```
- **`skillOverrides`:** add each template key that is absent (`auto-mode-setup: "off"` turns off the command and its
  end-of-turn offer, so a per-repo draft cannot replace the list again). A live key with another value is the user's
  choice: report it, do not overwrite. An added key disables a command, so name it in the report.
- **Live `allow` or `hard_deny`** (not in the template): leave it as it is, but report whether it has `"$defaults"`.
  A live `allow` without it replaces the built-in exceptions and can be far more permissive than intended; a
  `hard_deny` without it drops the built-in exfiltration rule.

**Drift assertion (run every time; fail loud):** for each list in the rendered `autoMode`, the live list exists,
contains `"$defaults"` and holds every rendered entry (an install.conf-valued entry the user declined in this run
excepted). After writing, run `claude auto-mode config` and check that
the effective lists hold the rendered entries. Then run `claude auto-mode critique` (a model call: if it fails or
returns nothing, retry once with `--model`, then report the failure without blocking) and include its output in the
Step 11 summary.
A `--settings` file that carries no `autoMode` inherits this
user-scope block: entries from each scope are combined, per the auto mode docs ("Where the classifier reads
configuration", code.claude.com/docs/en/auto-mode-config). Where `$CLAUDE_CONFIG_DIR/settings.json` is the symlink
(see the note above **Attribution**), this one write reaches both config roots; a root holding a plain copy needs its own run.

### Status line

Read the `statusLine` object from `templates/safe-permissions.json`.

- **If `~/.claude/settings.json` has no `statusLine` key:** Add the `statusLine` object from the template, without its `_comment` key.
- **If it already has `statusLine`:** Skip — do not overwrite custom status line configurations.

The status line command references `$HOME/.claude/statusline.sh` — this is the script installed in Step 7.

### Write settings.json

**Preserve all other fields** (`effortLevel`, `voiceEnabled`, custom keys, etc.) exactly as they are.

**Ordering when writing:**
1. Permissions grouped: Bash shell utilities, then MCP git tools (alphabetical), then MCP plugin tools; `ask`, then `deny`, after `allow`
2. Plugins sorted alphabetically
3. Hooks after plugins
4. Status line after hooks
5. `autoMode`, then `skillOverrides`, after the status line when they are new; an existing key keeps its position
6. Other fields last

Write the updated `~/.claude/settings.json`.

## Step 11: Report

Output a summary:

```
## Claude Setup Summary

### Prerequisites
jq / node+npm / gh: all present (or: stopped at Step 0, missing <list>); gh login: ok / WARNING not logged in

### Agents / Hooks / Skills / Rules

One table per category, **one row per artifact discovered in Steps 2–5** — do not use a
hardcoded roster; the filesystem is the roster (see ADR 0009 / README install table).

```
### <Category>
| <Artifact> | Status |
|------------|--------|
| <name>     | Installed / Already installed / Conflict |
```

Rules rows may additionally report `Replaced file (byte-match)`.

### MCP Servers

One row per **config file** repaired, not one per server — a machine with
`CLAUDE_CONFIG_DIR` set has two, and reporting a single row hides the one that
was missed.

| Server | Config file | Binary | Status |
|--------|-------------|--------|--------|
| git-mcp | `~/.claude.json` | `git-mcp-server` v\<pinned\> | Installed / Already correct / **Repaired (was npx)** / Skipped (error) |

`Already correct` requires the config to invoke the binary directly. An entry
still running through `npx` is **Repaired**, never `Already installed` — that
wording is what let the broken shape survive earlier runs of this skill.

If any file was changed, say so explicitly: **restart Claude Code**, since
running sessions keep their existing server process.

### Status Line
| Tool | Status |
|------|--------|
| statusline.sh | Installed / Already installed / Conflict |

### Tool Scripts
| Script | Status |
|--------|--------|
| workspace-lock.sh | Installed / Already installed / Conflict |
| shell-init.zsh | Installed / Already installed / Conflict (+ "add `source ~/.claude/tools/shell-init.zsh` to ~/.zshrc" when it is not there) |

### Copied pieces
| Piece | Status |
|-------|--------|
| install.conf | ok / MISSING / STALE (Step 8b's settings sub-step) |
| github-mcp launch / guard.sh | Current / "run: ghm-install" (needs sudo) |

### Global CLAUDE.md
Status: Created / Up to date / Updated (with user approval) / Skipped (user chose to keep)

### Permissions, Hooks & Status Line Config
Settings backup: <path> mode 600 / none (no settings.json, or nothing written)
Env vars enforced: <list of keys set or overwritten, or "none — already up to date">
Auto-compact window: Added / Overwritten (<old> → 500000) / Already configured; per-model overrides: <DRIFT list (removed on go | left), or "none">
Prompt cache TTL (promptCacheTtl, subagentPromptCacheTtl), per key: Added 1h (asked) / Enforced (<old> → <new> | already set) / Declined / Already set (<value>, left as is); overrides: <NOTE list, or "none">
Permissions added: <list, or "none — already up to date">
Permissions removed (migration): <list, or "none — already clean">
Deny entries added: <list, or "none — already up to date"> (live-only deny entries: <list, or "none">)
Ask entries added: <list, or "none — already up to date"> (live-only ask entries: <list, or "none">); user to confirm they prompt
Hooks config: Added / Already configured / Merged
Status line config: Added / Already configured / Skipped
Auto mode, per list (environment, soft_deny): Added / Merged <entries added> / Already configured / DRIFT (replaced on go, backup <path> mode 600 | left as is); live allow / hard_deny: <absent | with "$defaults" | WITHOUT "$defaults">; skillOverrides: <keys added, or "none">
Auto mode critique: <the output of `claude auto-mode critique`>

### Plugins
Added: <list, or "none — already up to date">
Removed: <list, or "none — already clean">
```

If any changes were made, remind the user to restart Claude Code.

## Stop Conditions

- Do not modify any project-level files — this skill only touches `~/.claude/`. It never runs `sudo`.
- Do not overwrite `~/.claude/CLAUDE.md` without user confirmation.
- If `~/.claude/settings.json` has unexpected structure, show it to the user and ask before modifying.
