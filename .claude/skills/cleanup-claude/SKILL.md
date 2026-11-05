---
description: "Remove everything the toolkit installed on this machine (links, hooks, settings keys, rc lines, runtime state) so /setup-claude can start clean. Dry run first; run from the ai-toolkit repo. Keeps login, transcripts and Keychain."
disable-model-invocation: true
---

# Cleanup Claude

Undo `/setup-claude` and the toolkit installers the README lists, on this machine only, so the machine looks as if the toolkit had never been used. It removes only what the toolkit installed, plus `~/.claude/install.conf` with any keys another installer added to it. The work is done by `tools/cleanup-claude/cleanup.sh` (path from this skill: `../../../tools/cleanup-claude/cleanup.sh`). The script is dry-run by default and runs in the user's own shell: an agent's session cannot edit the user's settings, delete their rc lines or use sudo, and should not try.

The skill lives in the repo's `.claude/skills/`, not in `~/.claude/skills/`, so it still works after it has removed the global links.

## Rules

- Destructive and touches permissions and security controls: the agent never runs `--apply`. The user runs it in their own shell (`!`), on their own live turn. A relayed or second-hand "the user approved" is not enough, and neither is an unattended run.
- One machine per run. Run it once per machine, from that machine's checkout.
- Never read or print a Keychain value, a `*.key` file or a token. The script never does.
- Never run the printed commands (`sudo`, `claude mcp remove`, `npm rm -g`, `security delete-…`) yourself. Give them to the user.

## Steps

1. **Check the checkout.** The checkout must be this machine's ai-toolkit checkout; the script derives every path from it. If a link still points at an old checkout location, say so: links into `*/ai-toolkit/*` that dangle are removed too.
2. **Stop what is running.** Tell the user to close other Claude sessions that use these hooks.
3. **Dry run.** Run `bash tools/cleanup-claude/cleanup.sh` (read-only) and show its output. `--verbose` lists the settings value paths that go (paths only, never values). Explain each group in plain words:
   - links into the checkout (agents, hooks, rules, skills, statusline, tools);
   - settings.json: the toolkit's keys and entries only, after a backup. The user's own keys, hooks beside the toolkit's, and unrelated entries stay. The hooks go because the scripts they point at are unlinked. Permission `allow` entries, plugins and `autoMode` context lines that the template also lists are removed (a user's identical entry goes too; `--keep-ambiguous` keeps them), and so is a `promptCacheTtl` or `subagentPromptCacheTtl` of `"1h"`, the opt-in `/setup-claude` asks about (the value alone marks it, so a `"1h"` the user set by hand goes too; `--keep-ambiguous` keeps it). The security entries stay by default: permission `ask` and `deny` rules, `deniedMcpServers`, `ENABLE_CLAUDEAI_MCP_SERVERS`, `enableAllProjectMcpServers`, and the `autoMode` `soft_deny` rules. They protect the machine until `/setup-claude` runs again; `--include-security` removes them too;
   - rc lines that source the toolkit, in the home's rc files and, when `ZDOTDIR` is set, `$ZDOTDIR/.zshrc` and `.zprofile`: plain `source` lines only, after a timestamped copy. A line that is chained with other commands, the only line of an `if`, or the next line of a command continued with `&&`, `||`, `|` or a backslash, is printed for the user to edit by hand;
   - runtime state: the github MCP update-check cache, and `~/.claude/install.conf` when `~/.claude` is among the config dirs cleaned;
   - ASK items (the ETA log): kept unless `--purge-ask`;
   - commands for the user: root-owned installs, `claude mcp remove`, the global npm package, optional Keychain deletes.
4. **Ask which options.** Default: none. Mention that a `promptCacheTtl` or `subagentPromptCacheTtl` of `"1h"` goes by default, including one the user set by hand, and that `--keep-ambiguous` keeps it. Offer `--include-security` only if the user wants the machine as if the repo had never touched it and accepts that the safety rules are missing until `/setup-claude` runs again. Settings backups are written before the edit and never deleted, so a wrong guess about what was the user's own is recoverable from the newest `settings.json.bak-…-cleanup`.
5. **Hand over the apply command**, in a code block with no comment, for the user to run in their shell with `!` (never run it yourself):
   `bash tools/cleanup-claude/cleanup.sh --apply` (plus any options chosen; `--config-dir DIR` repeats for another config dir).
6. **Give the printed commands** from the "for you to run" group, one block, after the apply has run.
7. **Verify.** Re-run the dry run: it should list no links, no EDIT, and only the user's chosen ASK items. Then `bash tools/install-copies.sh status` should show every piece unlinked or absent. Restart Claude Code, then `/setup-claude` reinstalls from the checkout.

## What it will not do

It does not remove the checkout, `node_modules` in it, the checkout's `.archive/`, the user's memory notes, other repos' `.archive/audit/` logs or `.workspace-lock/` folders (per-repo files it cannot find from the machine), per-project copies made by installers that are not part of this repository, or anything in another Claude profile it was not pointed at.
