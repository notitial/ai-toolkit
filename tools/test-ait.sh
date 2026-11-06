#!/bin/bash
# Tests for tools/ait.zsh and tools/shell-init.zsh. Run: bash tools/test-ait.sh
# The helpers run from a throwaway checkout with a bare origin and a scratch HOME that holds the install-time
# settings, the MCP registration and the settings.json hook. Nothing touches the real checkout or ~/.claude.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
command -v zsh >/dev/null 2>&1 || { echo "zsh required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/ait-test-XXXXXX") && T=$(cd "$T" && pwd -P) || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
R="$T/repo"
CONF="$T/home/.claude/install.conf"
mkdir -p "$T/home/.claude/tools" "$R/tools/github-mcp"

printf '%s\n' 'github_write_owners=notitial example-user' 'github_keychain_account=example-user' > "$CONF"
chmod 600 "$CONF"

cp "$HERE/ait.zsh" "$HERE/shell-init.zsh" "$HERE/install-copies.sh" "$R/tools/"
printf 'launcher\n' > "$R/tools/github-mcp/launch"
printf 'guard\n' > "$R/tools/github-mcp/guard.sh"
printf '#!/bin/sh\n' > "$T/github-mcp-server"
(cd "$T" && /usr/bin/shasum -a 256 github-mcp-server) > "$R/tools/github-mcp/server.sha256"
printf 'echo guard-suite\n' > "$R/tools/github-mcp/test-guard.sh"
printf 'echo update-suite\n' > "$R/tools/github-mcp/test-update-check.sh"
git init -q -b main "$R"
git init -q --bare -b main "$T/origin.git"
git -C "$R" remote add origin "$T/origin.git"
git -C "$R" add -A
git -C "$R" -c commit.gpgsign=false commit -q -m init
git -C "$R" push -q origin main
gc() { git -C "$R" -c commit.gpgsign=false "$@"; }

# z <zsh code>: run the code with the helpers loaded, HOME pointed at the scratch home.
z() { HOME="$T/home" zsh -f -c "source '$R/tools/ait.zsh'; $1" < /dev/null 2>&1; }
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
expect_has() { case "$2" in *"$3"*) ok ;; *) bad "$1: wanted '$3' in: $2" ;; esac; }
expect_not() { case "$2" in *"$3"*) bad "$1: did not want '$3' in: $2" ;; *) ok ;; esac; }

# Loading: ~/.zshrc sources the ~/.claude/tools link, and the helpers come from the checkout it points at.
ln -s "$R/tools/shell-init.zsh" "$T/home/.claude/tools/shell-init.zsh"
out=$(HOME="$T/home" zsh -f -c "source '$T/home/.claude/tools/shell-init.zsh'; whence -w ait ait-status ghm-status ghm-test ghm-install; print -r -- \"root=\$AIT_ROOT\"" 2>&1)
expect_has "shell-init through the link loads ghm-status" "$out" "ghm-status: function"
expect_has "shell-init through the link loads ghm-test" "$out" "ghm-test: function"
expect_has "ghm-install is gone" "$out" "ghm-install: none"
expect_has "AIT_ROOT is the checkout the link points at" "$out" "root=$R"
expect_not "shell-init loads without errors" "$out" "no such file"
out=$(z 'ait; pwd')
expect_has "ait changes to the checkout" "$out" "$R"
out=$(z ghm-test)
expect_has "ghm-test runs the guard suite" "$out" "guard-suite"
expect_has "ghm-test runs the update-check suite" "$out" "update-suite"
out=$(z ait-status)
expect_has "ait-status runs install-copies.sh status" "$out" "links "

# ghm-status: the github lines of the status. Nothing wired yet.
out=$(z ghm-status)
expect_has "a clean main is ok" "$out" "ok        github-mcp checkout is on a clean main"
expect_has "no binary is MISSING" "$out" "MISSING   github-mcp server binary"
expect_has "no registration is MISSING" "$out" "MISSING   github MCP server (not registered"
expect_has "no hook is MISSING" "$out" "MISSING   github MCP guard hook"
[ "$(z 'ghm-status >/dev/null; echo "rc=$?"' | grep '^rc=')" = rc=1 ] && ok || bad "ghm-status exits 1 while something is missing"

# Wire everything at the checkout: binary, registration, hook.
mkdir -p "$R/tools/github-mcp/bin"
printf '#!/bin/sh\n' > "$R/tools/github-mcp/bin/github-mcp-server"
chmod 755 "$R/tools/github-mcp/bin/github-mcp-server"
jq -n --arg c "$R/tools/github-mcp/launch" '{mcpServers: {github: {type: "stdio", command: $c, args: []}}}' > "$T/home/.claude.json"
jq -n --arg c "/bin/bash -p '$R/tools/github-mcp/guard.sh' || exit 2" '{hooks: {PreToolUse: [{matcher: "^mcp__github__.*$", hooks: [{type: "command", command: $c}]}]}}' > "$T/home/.claude/settings.json"
out=$(z 'ghm-status; echo "rc=$?"')
expect_has "the binary is ok" "$out" "ok        github-mcp server binary"
expect_has "the registration is ok" "$out" "ok        github MCP server registered at this checkout"
expect_has "the hook is ok" "$out" "ok        github MCP guard hook points at this checkout"
expect_has "all ok exits 0" "$out" "rc=0"
expect_not "no root-owned copy is mentioned" "$out" "libexec"

# The checkout must be a clean main, or the guard and the launcher are off.
printf 'edit\n' >> "$R/tools/github-mcp/guard.sh"
out=$(z 'ghm-status; echo "rc=$?"')
expect_has "an edited tracked file is STALE" "$out" "STALE     github-mcp checkout (main, with edits: the guard and the launcher are off)"
expect_has "and exits 1" "$out" "rc=1"
gc checkout -q -- tools/github-mcp/guard.sh
printf 'untracked\n' > "$R/untracked-file"
out=$(z ghm-status)
expect_has "an untracked file is fine" "$out" "ok        github-mcp checkout is on a clean main"
rm -f "$R/untracked-file"
gc checkout -q -b topic
out=$(z ghm-status)
expect_has "a branch other than main is STALE" "$out" "STALE     github-mcp checkout (topic"
gc checkout -q main

# A registration or a hook elsewhere is stale.
jq -n '{mcpServers: {github: {type: "stdio", command: "/elsewhere/launch"}}}' > "$T/home/.claude.json"
out=$(z ghm-status)
expect_has "a server registered elsewhere is STALE" "$out" "STALE     github MCP server (registered at /elsewhere/launch)"
jq -n '{hooks: {PreToolUse: [{matcher: "^mcp__github__.*$", hooks: [{type: "command", command: "/elsewhere/tools/github-mcp/guard.sh"}]}]}}' > "$T/home/.claude/settings.json"
out=$(z ghm-status)
expect_has "a hook elsewhere is STALE" "$out" "STALE     github MCP guard hook (points at /elsewhere/tools/github-mcp/guard.sh)"

echo "ait: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
