---
description: "Remove an alternate Claude Code account launcher (claude-<name>, code-<name>), or all of them: the agent drops the line from ~/.claude/accounts.conf, the user deletes the Keychain item and the account's VS Code folder. Run from the ai-toolkit repo. To add one: /add-account."
disable-model-invocation: true
---

# Remove Account

Undoes `/add-account`: an account is a line in `~/.claude/accounts.conf`, a Keychain item it names, and, once `code-<name>` has run, a folder `~/.vscode-accounts/<name>`. macOS only.

## Rules

- The agent edits `~/.claude/accounts.conf` only to remove the lines asked for, and never shows a Keychain value (the file holds none, only service names). It never runs `security find-generic-password` with `-w` or `-g`.
- The agent runs no `security delete-…` and no `rm` outside the checkout. It gives the user the commands in a code block with no comment, and the user runs them in their own terminal.
- Deleting a Keychain item does not revoke the token or key: it still works wherever it was copied. If it should stop working, the user revokes it where it was issued.

## One account

1. Read `~/.claude/accounts.conf` and remove that account's line, only that line. Note its service.
2. Give the user the commands to run themselves: `security delete-generic-password -s <service>` (only if no other line uses that service), and `rm -r ~/.vscode-accounts/<name>` if that folder exists (it holds links to the main VS Code settings, which `rm -r` does not follow, and the account's own window state).
3. Tell the user to open a new terminal: `claude-<name>` and `code-<name>` live on in shells opened before.
4. Verify, from the checkout: `bash tools/install-copies.sh status` no longer lists the account.

## All accounts

1. Read `~/.claude/accounts.conf` and note each distinct service.
2. Give the user the commands to run themselves: one `security delete-generic-password -s <service>` per service, then `rm ~/.claude/accounts.conf` and `rm -r ~/.vscode-accounts` (links inside are not followed).
3. Tell the user to open a new terminal, then verify: `bash tools/install-copies.sh status` shows no `accounts.conf` line.
