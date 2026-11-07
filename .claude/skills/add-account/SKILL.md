---
description: "Add, remove or migrate an alternate Claude Code account launcher (claude-<name>, code-<name>): the secret goes into the macOS Keychain through a prompt the user answers, and the account into ~/.claude/accounts.conf. Run from the ai-toolkit repo."
disable-model-invocation: true
---

# Add Account

Alternate Claude Code accounts run beside the stored login in `~/.claude` on a token or a key from the macOS Keychain. Each line of `~/.claude/accounts.conf` makes two commands in new shells: `claude-<name>` and `code-<name>`. `tools/accounts.zsh` explains the format and what the commands do; `bash tools/install-copies.sh status` (`ait-status`) shows whether the file is valid and each Keychain item exists. macOS only. There is never a second config dir.

## Rules

- The secret never reaches the chat, a command argument, a file or a log. The user types it at the `security` prompt in their own terminal. Never ask for it, never ask the user to paste it or its output, and never run `security find-generic-password` with `-w` or `-g`.
- The agent runs no `security add-…` or `security delete-…`. It gives the user the command in a code block with no comment, and the user runs it in their own terminal.
- For a subscription account the user creates the token themselves with `claude setup-token`. The agent does not run it.
- Agents do not edit rc files (`~/.zshrc`, `~/.zprofile`, `~/.zshenv`). Anything there is a step the user takes.
- The agent edits `~/.claude/accounts.conf` only for the one line it adds or removes, and never shows a Keychain value (the file holds none, only service names).
- Everything the user does with their own accounts (names, services) stays out of the repo: examples use placeholders.

## Add an account

1. **Ask**, one decision at a time:
   - the name: lowercase letters, digits and dashes, 32 characters at most, no dash at either end (it becomes `claude-<name>` and `code-<name>`);
   - the kind: `oauth` for a subscription token from `claude setup-token`, `apikey` for an Anthropic API key;
   - the Keychain service: any name the user likes, letters, digits and `. _ @ -`, starting with a letter or digit, such as `claude-<name>-oauth`. If an item with that service exists, say so and ask whether to reuse it.
2. **Check the name is free.** Read `~/.claude/accounts.conf` if it exists. The user checks the commands in their own shell, since a function is not visible to the agent: in a code block, `whence -w claude-<name> code-<name>`. Anything but `none` for either means the launcher would be skipped; pick another name or have the user remove the old definition.
3. **For `oauth`, the user creates the token.** Tell them to run `claude setup-token` in a terminal and keep its output on screen for the next step. Never ask what it printed.
4. **Give the Keychain command**, for the user's own terminal window (the prompt needs a real terminal; `!` in the session does not give one):

   ```
   security add-generic-password -s <service> -a "$USER" -w
   ```

   `-w` as the last option makes `security` prompt for the secret, so it is never an argument. They paste the token or key there, and confirm. Wait for them to say it is done.
5. **Add the line.** In `~/.claude/accounts.conf`, one line, `<name> <kind> <service>`. If the file does not exist, create it owned by the user and not writable by anyone else, as one command, with `umask 077` first (`bash tools/install-copies.sh accounts` refuses a file others can write). Add to the end; never rewrite the other lines.
6. **Verify**, from the checkout: `bash tools/install-copies.sh status`. Wanted: `ok accounts.conf` and `ok account <name> (… Keychain item … found)`. A `STALE` line names the bad line and why; `MISSING` means step 4 did not store the item (re-run it).
7. **Tell the user** to open a new shell: the commands exist only in shells that load `~/.claude/tools/shell-init.zsh` after the line was added. Then `claude-<name>` starts that account (arguments pass straight through, `claude-<name> --resume <id>` works), and `code-<name> <folder>` opens VS Code with its own settings folder beside the main window, no need to quit it. Tell them the secret is in the environment of that program and of everything it starts (the Bash tool, hooks, MCP servers, extensions), and to keep `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` out of the shell they launch from, since an inherited one is not cleared. State what is unverified: whether the Claude Code extension inside a `code-<name>` window uses the account's variable.

## Remove an account

1. Remove that account's line from `~/.claude/accounts.conf` (only that line).
2. Give the user, in a code block with no comment, the commands to run themselves: `security delete-generic-password -s <service>` (only if no other account uses the service), and `rm -r ~/.vscode-accounts/<name>` to drop that account's VS Code folder (it holds links to the main settings, which `rm -r` does not follow; it also holds the account's own window state). Neither is run by the agent.
3. Tell the user to open a new shell; `claude-<name>` and `code-<name>` exist until the old one closes.

## Move from a personal launchers file

A file the user sourced from `~/.zshrc` that defines `claude-<x>` and `code-<x>` functions (typically each reading a Keychain item into a variable) is replaced by `accounts.conf`.

1. Read the file; for each account note its variable (`CLAUDE_CODE_OAUTH_TOKEN` is `oauth`, `ANTHROPIC_API_KEY` is `apikey`) and its Keychain service. The services already hold the secrets: do not add them again. Write one `accounts.conf` line per account with those services, never a secret.
2. Tell the user, as a step of their own, to remove that file's `source` line from `~/.zshrc`. Until they do, the old functions shadow or replace the new ones: sourced first, the old definitions make the new launchers skip with a message; sourced last, they overwrite the new ones without a word.
3. In a new shell, run `bash tools/install-copies.sh status` and one `claude-<name>` per account. A launcher that is skipped names the thing that already has its name.
4. The old `code-<name>` asked the user to quit VS Code first; the new one does not. It also no longer sets `AIT_ACCOUNT`, which only a retired hook read.
