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

cp "$HERE/ait.zsh" "$HERE/accounts.zsh" "$HERE/shell-init.zsh" "$HERE/install-copies.sh" "$R/tools/"
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
expect_not "shell-init loads accounts.zsh in silence when there is no accounts.conf" "$out" "accounts"
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
# install.conf is read by the launcher and the guard at run time: a missing one is not "all ok".
mv "$CONF" "$CONF.away"
out=$(z 'ghm-status; echo "rc=$?"')
expect_has "a missing install.conf is shown" "$out" "install.conf"
expect_has "a missing install.conf fails ghm-status" "$out" "rc=1"
mv "$CONF.away" "$CONF"

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

# ---- accounts.zsh: the account launchers. A fake `security` (the Keychain is a directory of files), a fake `claude`
# and a fake `code` sit first on PATH and record what they got; nothing here touches the real Keychain, VS Code or ~/.claude.
FB="$T/fakebin"
export FAKE_SEC_LOG="$T/sec.log" FAKE_KEYCHAIN="$T/keychain" FAKE_REC="$T/rec"
mkdir -p "$FB" "$FAKE_KEYCHAIN"
cat > "$FB/security" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_SEC_LOG"
[ "$1" = find-generic-password ] || exit 1
shift; svc=""; want=0
while [ $# -gt 0 ]; do case $1 in -s) svc=$2; shift ;; -w | -g) want=1 ;; esac; shift; done
f="$FAKE_KEYCHAIN/$svc"
[ -f "$f" ] || { echo "security: the item could not be found" >&2; exit 44; }
if [ $want = 1 ]; then cat "$f"; else printf 'keychain: "login.keychain-db"\n    "svce"<blob>="%s"\n' "$svc"; fi
EOF
for prog in claude code; do
  cat > "$FB/$prog" <<EOF
#!/bin/sh
{
  echo "prog=$prog"
  for a in "\$@"; do echo "arg=\$a"; done
  echo "oauth=\${CLAUDE_CODE_OAUTH_TOKEN-UNSET}"
  echo "apikey=\${ANTHROPIC_API_KEY-UNSET}"
  echo "aitaccount=\${AIT_ACCOUNT-UNSET}"
} > "\$FAKE_REC.$prog"
echo "fake $prog ran"
EOF
done
chmod 755 "$FB/security" "$FB/claude" "$FB/code"
for svc in svc-work svc-batch; do printf 'SECRET-%s-VALUE\n' "$svc" > "$FAKE_KEYCHAIN/$svc"; done
: > "$FAKE_KEYCHAIN/svc-empty"
ACCTS="$T/home/.claude/accounts.conf"
chmod 755 "$T/home/.claude"
MAIN="$T/home/Library/Application Support/Code/User"
mkdir -p "$MAIN/snippets"
printf '{"main":true}\n' > "$MAIN/settings.json"
printf '[]\n' > "$MAIN/keybindings.json"
printf '{}\n' > "$MAIN/snippets/a.code-snippets"

# za <zsh code>: accounts.zsh loaded (after ZA_PRE, when set), the fakes first on PATH (or ZA_PATH), no auth variable
# inherited. Every output is kept in all.out, which must never hold a secret.
za() {
  env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u AIT_ACCOUNT HOME="$T/home" PATH="${ZA_PATH:-$FB:$PATH}" \
    zsh -f -c "${ZA_PRE:-:}; source '$R/tools/accounts.zsh'; $1" < /dev/null > "$T/last.out" 2>&1
  cat "$T/last.out"; cat "$T/last.out" >> "$T/all.out"
}
: > "$T/all.out"

# No accounts.conf: nothing defined, nothing said.
out=$(za 'whence -w claude-work code-work')
expect_not "no accounts.conf: no function" "$out" "function"
expect_not "no accounts.conf: no complaint" "$out" "accounts"

# No accounts.conf: the loader starts no bash and no git (a fake bash first on PATH would leave a marker).
mkdir -p "$T/nobash"; printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$T/bash-ran" > "$T/nobash/bash"; chmod 755 "$T/nobash/bash"
ZA_PATH="$T/nobash:$FB:$PATH" za 'true' > /dev/null
[ ! -e "$T/bash-ran" ] && ok || bad "no accounts.conf: the loader still started bash"

# A valid file, with comments and one bad line of each kind.
cat > "$ACCTS" <<'EOF'
# the accounts
work    oauth   svc-work
batch   apikey  svc-batch   # a trailing comment
gone    oauth   svc-gone
empty   oauth   svc-empty
Bad_Name oauth  svc-work
work    oauth   svc-other
what    token   svc-work
dash    oauth   -svc
five    oauth   svc-work extra
EOF
chmod 600 "$ACCTS"
out=$(za 'whence -w claude-work code-work claude-batch code-batch claude-Bad_Name claude-what claude-dash claude-five')
for f in claude-work code-work claude-batch code-batch; do expect_has "$f is generated" "$out" "$f: function"; done
for f in claude-Bad_Name claude-what claude-dash claude-five; do expect_has "$f is not generated" "$out" "$f: none"; done
expect_has "a bad name is reported with its line" "$out" "accounts.conf line 6: name: lowercase letters, digits and dashes only"
expect_has "a repeated name is reported" "$out" "accounts.conf line 7: name work given twice; skipped"
expect_has "a bad kind is reported" "$out" "accounts.conf line 8: kind: oauth or apikey; skipped"
expect_has "a bad service is reported" "$out" "accounts.conf line 9: service: letters, digits and . _ @ - only, starting with a letter or digit; skipped"
expect_has "a fourth field is reported" "$out" "accounts.conf line 10: more than three fields; skipped"

# An oauth account: arguments pass through untouched, the right variable gets the secret, nothing else does.
rm -f "$T/rec.claude" "$FAKE_SEC_LOG"
out=$(za 'claude-work --resume ABC "two  words" "$HOME" ""; echo "rc=$?"; echo "after=${CLAUDE_CODE_OAUTH_TOKEN-unset}/${ANTHROPIC_API_KEY-unset}"')
rec=$(cat "$T/rec.claude" 2>/dev/null)
expect_has "claude-work ran claude" "$out" "fake claude ran"
expect_has "claude-work exits with the program's status" "$out" "rc=0"
want=$(printf 'prog=claude\narg=--resume\narg=ABC\narg=two  words\narg=%s\narg=\noauth=SECRET-svc-work-VALUE\napikey=UNSET\naitaccount=UNSET' "$T/home")
[ "$rec" = "$want" ] && ok || bad "claude-work: arguments and variables: got: $rec"
expect_has "the secret is in the shell afterwards: not at all" "$out" "after=unset/unset"
expect_has "the Keychain is asked by service, for the value, with no account" "$(cat "$FAKE_SEC_LOG")" "find-generic-password -s svc-work -w"
expect_not "the Keychain is never asked with -a" "$(cat "$FAKE_SEC_LOG")" " -a "

# An apikey account: the other variable.
rm -f "$T/rec.claude"
za 'claude-batch -p hi' > /dev/null
rec=$(cat "$T/rec.claude" 2>/dev/null)
expect_has "claude-batch sets ANTHROPIC_API_KEY" "$rec" "apikey=SECRET-svc-batch-VALUE"
expect_has "claude-batch leaves the token variable alone" "$rec" "oauth=UNSET"
expect_has "claude-batch passes -p hi" "$rec" "$(printf 'arg=-p\narg=hi')"
expect_has "AIT_ACCOUNT is never set" "$rec" "aitaccount=UNSET"

# The program's own exit status comes back.
printf '#!/bin/sh\nexit 7\n' > "$FB/claude-exit7"; chmod 755 "$FB/claude-exit7"
cp "$FB/claude" "$T/claude.keep"; printf '#!/bin/sh\nexit 7\n' > "$FB/claude"
out=$(za 'claude-work; echo "rc=$?"')
expect_has "the program's exit status is returned" "$out" "rc=7"
cp "$T/claude.keep" "$FB/claude"; rm -f "$FB/claude-exit7" "$T/claude.keep"; chmod 755 "$FB/claude"

# A Keychain item that is missing, or empty: nothing runs, the error names the service, never a secret.
rm -f "$T/rec.claude"
out=$(za 'claude-gone; echo "rc=$?"')
expect_has "a missing item: the error names the service" "$out" "accounts: no usable Keychain item for gone (service svc-gone)"
expect_has "a missing item: rc 1" "$out" "rc=1"
out=$(za 'claude-empty; echo "rc=$?"')
expect_has "an empty item: the error names the service" "$out" "accounts: no usable Keychain item for empty (service svc-empty)"
[ ! -e "$T/rec.claude" ] && ok || bad "claude ran although the item is missing or empty"

# A reload does not trip over its own functions; a name something else holds is never replaced.
out=$(za "source '$R/tools/accounts.zsh'; whence -w claude-work")
expect_not "a reload says nothing about its own functions" "$out" "skipped claude-"
cat > "$ACCTS" <<'EOF'
fn      oauth   svc-work
clash   oauth   svc-work
al      oauth   svc-work
fine    oauth   svc-work
EOF
mkdir -p "$T/collide"; printf '#!/bin/sh\necho clash-binary\n' > "$T/collide/code-clash"; chmod 755 "$T/collide/code-clash"
out=$(ZA_PATH="$T/collide:$FB:$PATH" ZA_PRE='claude-fn() { echo mine }; alias claude-al="echo myalias"' za 'claude-fn; whence -w claude-clash code-clash code-fine')
expect_has "an existing function is skipped, with the reason" "$out" "accounts.zsh: skipped claude-fn: a command, function or alias with that name already exists"
expect_has "the existing function still runs" "$out" "mine"
expect_has "an existing alias is skipped" "$out" "accounts.zsh: skipped claude-al:"
expect_has "an existing command on PATH is skipped" "$out" "accounts.zsh: skipped code-clash:"
expect_has "the other launcher of a clashing account is still made" "$out" "claude-clash: function"
expect_has "a clean account is made" "$out" "code-fine: function"

# code-<name>: its own user-data dir, linked to the main settings; the main folder is never written.
cat > "$ACCTS" <<'EOF'
work oauth svc-work
EOF
before=$(cd "$MAIN" && find . | LC_ALL=C sort; cat settings.json keybindings.json snippets/a.code-snippets)
rm -f "$T/rec.code"
out=$(za 'code-work /some/dir; echo "rc=$?"')
rec=$(cat "$T/rec.code" 2>/dev/null)
UD="$T/home/.vscode-accounts/work"
expect_has "code-work ran code" "$out" "fake code ran"
want=$(printf 'prog=code\narg=--user-data-dir\narg=%s\narg=/some/dir\noauth=SECRET-svc-work-VALUE\napikey=UNSET\naitaccount=UNSET' "$UD")
[ "$rec" = "$want" ] && ok || bad "code-work: arguments and variables: got: $rec"
[ -d "$UD/User" ] && ok || bad "code-work: no User folder"
for f in settings.json keybindings.json snippets; do
  [ -L "$UD/User/$f" ] && [ "$(readlink "$UD/User/$f")" = "$MAIN/$f" ] && ok || bad "code-work: $f is not a link to the main one"
done
[ ! -e "$UD/User/mcp.json" ] && [ ! -L "$UD/User/mcp.json" ] && ok || bad "code-work: mcp.json linked although the main one has none"
[ "$(find "$UD/User" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 3 ] && ok || bad "code-work: something besides the three links in User"
after=$(cd "$MAIN" && find . | LC_ALL=C sort; cat settings.json keybindings.json snippets/a.code-snippets)
[ "$before" = "$after" ] && ok || bad "code-work changed the main User folder"
# a later launch links what has appeared since, and never replaces a file the account already has
printf '{"servers":{}}\n' > "$MAIN/mcp.json"
rm "$UD/User/keybindings.json"; printf '[1]\n' > "$UD/User/keybindings.json"
za 'code-work' > /dev/null
[ -L "$UD/User/mcp.json" ] && ok || bad "code-work: mcp.json not linked once it exists"
[ ! -L "$UD/User/keybindings.json" ] && [ "$(cat "$UD/User/keybindings.json")" = "[1]" ] && ok || bad "code-work replaced the account's own keybindings.json"
# a user-data dir that is a link is refused: it could lead into the main folder
mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$T/home/.vscode-accounts/evil"
printf 'evil oauth svc-work\n' > "$ACCTS"
rm -f "$T/rec.code"
out=$(za 'code-evil; echo "rc=$?"')
expect_has "a linked user-data dir is refused" "$out" "is a symlink; refusing"
[ ! -e "$T/rec.code" ] && [ -z "$(ls -A "$T/elsewhere")" ] && ok || bad "code-evil ran or wrote through the link"
# the folders it makes are private, and a linked ~/.vscode-accounts is refused too
[ -n "$(find "$UD" "$T/home/.vscode-accounts" -maxdepth 0 -perm 700 2>/dev/null)" ] && [ "$(find "$UD" "$T/home/.vscode-accounts" -maxdepth 0 -perm 700 2>/dev/null | wc -l | tr -d ' ')" = 2 ] && ok || bad "the account folders are not mode 700"
mv "$T/home/.vscode-accounts" "$T/va.away"; mkdir -p "$T/elsewhere2"; ln -s "$T/elsewhere2" "$T/home/.vscode-accounts"
printf 'work oauth svc-work\n' > "$ACCTS"
rm -f "$T/rec.code"
out=$(za 'code-work; echo "rc=$?"')
expect_has "a linked ~/.vscode-accounts is refused" "$out" "is a symlink; refusing"
[ ! -e "$T/rec.code" ] && [ -z "$(ls -A "$T/elsewhere2")" ] && ok || bad "code-work ran or wrote through a linked ~/.vscode-accounts"
rm "$T/home/.vscode-accounts"; mv "$T/va.away" "$T/home/.vscode-accounts"
printf 'evil oauth svc-work\n' > "$ACCTS"
# a missing item stops code-<name> before VS Code starts
printf 'gone oauth svc-gone\n' > "$ACCTS"
rm -f "$T/rec.code"
out=$(za 'code-gone; echo "rc=$?"')
expect_has "code-gone: the error names the service" "$out" "accounts: no usable Keychain item for gone (service svc-gone): missing, empty, locked or access denied"
[ ! -e "$T/rec.code" ] && ok || bad "code ran although the item is missing"
[ ! -e "$T/home/.vscode-accounts/gone" ] && ok || bad "code-gone made a folder although the item is missing"

# The file is read only if it is safe: group- or world-writable is refused whole.
printf 'work oauth svc-work\n' > "$ACCTS"; chmod 666 "$ACCTS"
out=$(za 'whence -w claude-work')
expect_has "a writable accounts.conf loads no launcher" "$out" "claude-work: none"
expect_has "and says why" "$out" "accounts.conf: writable by group or others (or its folder is); no account launchers are loaded"
chmod 600 "$ACCTS"
# a link is judged by its target, in both directions
mkdir -p "$T/dotfiles"; printf 'work oauth svc-work\n' > "$T/dotfiles/accounts.conf"; chmod 600 "$T/dotfiles/accounts.conf"
rm -f "$ACCTS"; ln -s "$T/dotfiles/accounts.conf" "$ACCTS"
out=$(za 'whence -w claude-work')
expect_has "a linked accounts.conf with a private target loads" "$out" "claude-work: function"
chmod 666 "$T/dotfiles/accounts.conf"
out=$(za 'whence -w claude-work')
expect_has "a linked accounts.conf with a writable target is refused" "$out" "claude-work: none"
expect_has "and says why" "$out" "writable by group or others"
chmod 600 "$T/dotfiles/accounts.conf"; rm -f "$ACCTS"
# ~/.claude itself must not be writable by group or others
printf 'work oauth svc-work\n' > "$ACCTS"; chmod 600 "$ACCTS"; chmod 775 "$T/home/.claude"
out=$(za 'whence -w claude-work')
expect_has "a group-writable ~/.claude loads no launcher" "$out" "claude-work: none"
chmod 755 "$T/home/.claude"
# an unreadable file is refused with its reason, not read as empty (root reads it anyway: skipped there)
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$ACCTS"
  out=$(HOME="$T/home" PATH="$FB:$PATH" bash "$R/tools/install-copies.sh" status 2>&1 < /dev/null)
  expect_has "status: an unreadable accounts.conf is STALE" "$out" "STALE     accounts.conf (not readable by you: no account launcher is loaded)"
  expect_not "status: and is not read as empty" "$out" "no accounts"
  chmod 600 "$ACCTS"
fi
# shell-init.zsh loads the launchers too, through the ~/.claude/tools link
out=$(HOME="$T/home" PATH="$FB:$PATH" zsh -f -c "source '$T/home/.claude/tools/shell-init.zsh'; whence -w claude-work code-work" 2>&1 < /dev/null)
expect_has "shell-init loads claude-work" "$out" "claude-work: function"
expect_has "shell-init loads code-work" "$out" "code-work: function"

# ait-status: one line for the file, one per account, the Keychain asked without the secret.
cat > "$ACCTS" <<'EOF'
work    oauth   svc-work
gone    oauth   svc-gone
EOF
: > "$FAKE_SEC_LOG"
out=$(HOME="$T/home" PATH="$FB:$PATH" bash "$R/tools/install-copies.sh" status 2>&1 < /dev/null)
expect_has "status: the file is ok" "$out" "ok        accounts.conf (2 accounts)"
expect_has "status: an account with an item is ok" "$out" "ok        account work (oauth; Keychain item svc-work found)"
expect_has "status: an account with no item is MISSING, with the command" "$out" 'MISSING   account gone (Keychain item svc-gone not found)  -> security add-generic-password -s svc-gone -a "$USER" -w'
expect_has "status: the Keychain was asked" "$(cat "$FAKE_SEC_LOG")" "find-generic-password -s svc-work"
expect_not "status never asks the Keychain for the secret (-w)" "$(cat "$FAKE_SEC_LOG")" " -w"
expect_not "status never asks the Keychain for the secret (-g)" "$(cat "$FAKE_SEC_LOG")" " -g"
expect_not "status prints no secret" "$out" "SECRET-"
printf 'work oauth svc-work\nbad name here and more\n' > "$ACCTS"
out=$(HOME="$T/home" PATH="$FB:$PATH" bash "$R/tools/install-copies.sh" status 2>&1 < /dev/null)
expect_has "status: a bad line is STALE, with its reason" "$out" "STALE     accounts.conf (line 2: more than three fields; skipped)"
expect_has "status: the good account is still listed" "$out" "ok        account work (oauth; Keychain item svc-work found)"
chmod 666 "$ACCTS"
out=$(HOME="$T/home" PATH="$FB:$PATH" bash "$R/tools/install-copies.sh" status 2>&1 < /dev/null)
expect_has "status: a writable file is STALE and lists no account" "$out" "STALE     accounts.conf (writable by group or others (or its folder is): no account launcher is loaded)"
expect_not "status: no account line for a refused file" "$out" "account work"
chmod 600 "$ACCTS"
rm -f "$ACCTS"
out=$(HOME="$T/home" PATH="$FB:$PATH" bash "$R/tools/install-copies.sh" status 2>&1 < /dev/null)
expect_not "status: no accounts.conf, no account line" "$out" "account"
[ "$(grep -c 'SECRET-' "$T/all.out")" = 0 ] && ok || bad "a secret reached the output of a launcher"

echo "ait: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
