---
description: "Add an alternate Claude Code account launcher (claude-<name>, code-<name>): the secret goes into the macOS Keychain through a prompt the user answers, and the account into ~/.claude/accounts.conf. Run from the ai-toolkit repo. To remove one: /remove-account."
disable-model-invocation: true
---

# Add Account

Alternate Claude Code accounts run beside the stored login in `~/.claude` on a token or a key from the macOS Keychain. Each line of `~/.claude/accounts.conf` makes two commands in new shells: `claude-<name>` and `code-<name>`. `tools/accounts.zsh` explains the format and what the commands do; `bash tools/install-copies.sh status` (`ait-status`) shows whether the file is valid and each Keychain item exists. macOS only. There is never a second config dir. `/remove-account` removes one or all.

## Rules

- The secret never reaches the chat, a command argument, a file or a log. The user types it at the `security` prompt in their own terminal. Never ask for it, never ask the user to paste it or its output, and never run `security find-generic-password` with `-w` or `-g`.
- The agent runs no `security add-…`. It gives the user the command in a code block with no comment, and the user runs it in their own terminal.
- For a subscription account the user creates the token themselves with `claude setup-token`. The agent does not run it.
- Agents do not edit rc files (`~/.zshrc`, `~/.zprofile`, `~/.zshenv`). Anything there is a step the user takes.
- The agent edits `~/.claude/accounts.conf` only for the one line it adds, and never shows a Keychain value (the file holds none, only service names).
- Everything the user does with their own accounts (names, services) stays out of the repo: examples use placeholders.

## Steps

1. **Ask**, one decision at a time:
   - the name: lowercase letters, digits and dashes, 32 characters at most, no dash at either end (it becomes `claude-<name>` and `code-<name>`);
   - the kind: `oauth` for a subscription token from `claude setup-token`, `apikey` for an Anthropic API key.

   The Keychain service is `claude-<name>-<kind>` unless the user names another (letters, digits and `. _ @ -`, starting with a letter or digit). State it and go on; do not ask.
2. **Check the name is free.** Read `~/.claude/accounts.conf` if it exists. The user checks the commands in a new terminal, since a function is not visible to the agent and a shell opened before a removal keeps the old definitions: in a code block, `whence -w claude-<name> code-<name>`. Anything but `none` for either means the launcher would be skipped; pick another name or have the user remove the old definition.
3. **For `oauth`, the user creates the token.** Tell them to run `claude setup-token` in a terminal and keep its output on screen for the next step. It issues the token for the account the browser is signed in to: with more than one subscription account, sign in to the right one first. Never ask what it printed.
4. **Give the Keychain command**, for the user's own terminal window (the prompt needs a real terminal; `!` in the session does not give one):

   ```
   security add-generic-password -s <service> -a "$USER" -w
   ```

   `-w` as the last option makes `security` prompt for the secret, so it is never an argument. They paste the token or key there, and confirm. Wait for them to say it is done. If it fails with "already exists", an item with that service is there: ask whether to reuse it (go on to step 5) or pick another service. The agent does not look in the Keychain itself.
5. **Add the line.** In `~/.claude/accounts.conf`, one line, `<name> <kind> <service>`. If the file does not exist, create it owned by the user and not writable by anyone else, as one command, with `umask 077` first (`bash tools/install-copies.sh accounts` refuses a file others can write). Add to the end; never rewrite the other lines.
6. **Verify**, from the checkout: `bash tools/install-copies.sh status`. Wanted: `ok accounts.conf` and `ok account <name> (… Keychain item … found)`. A `STALE` line names the bad line and why; `MISSING` means step 4 did not store the item (re-run it).
7. **Tell the user** to open a new terminal: the commands exist only in shells that load `~/.claude/tools/shell-init.zsh` after the line was added. Then `claude-<name>` starts that account (arguments pass straight through, `claude-<name> --resume <id>` works; `/status` inside shows which account it runs on), and `code-<name> <folder>` opens VS Code with its own settings folder beside the main window, no need to quit it. Tell them the secret is in the environment of that program and of everything it starts (the Bash tool, hooks, MCP servers, extensions), and to keep `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` out of the shell they launch from, since an inherited one is not cleared. State what is unverified: whether the Claude Code extension inside a `code-<name>` window uses the account's variable.
