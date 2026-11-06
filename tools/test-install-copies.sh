#!/bin/bash
# Tests for tools/install-copies.sh. Run: bash tools/test-install-copies.sh
# Each case builds a throwaway repo (branch main plus a bare origin) with the files the script reads, and runs its copy
# of the script against a temp HOME. Nothing touches the real checkout or ~/.claude.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/icopies-test-XXXXXX") && T=$(cd "$T" && pwd -P) || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0
CASES=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset CLAUDE_CONFIG_DIR
for v in $(env | sed -n 's/^\(ICOPIES_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done

SCRIPT_SRC="$HERE/install-copies.sh"
[ -f "$SCRIPT_SRC" ] || { echo "install-copies.sh is missing" >&2; exit 2; }

mkdir -p "$T/fakehome"

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
expect_has() {  # expect_has <name> <haystack> <needle>
  case "$2" in *"$3"*) ok ;; *) bad "$1: wanted '$3' in: $2" ;; esac
}
expect_not() {  # expect_not <name> <haystack> <needle>
  case "$2" in *"$3"*) bad "$1: did not want '$3' in: $2" ;; *) ok ;; esac
}
expect_re() {  # expect_re <name> <haystack> <egrep regex, matched per line>
  if printf '%s\n' "$2" | grep -Eq -- "$3"; then ok; else bad "$1: wanted /$3/ in: $2"; fi
}
expect_rc() {  # expect_rc <name> <want>   (checks RC from the last ic call)
  if [ "$RC" = "$2" ]; then ok; else bad "$1: exit $RC, wanted $2; output: $OUT"; fi
}
expect_true() {  # expect_true <name> <command...>
  local n=$1
  shift
  if "$@"; then ok; else bad "$n"; fi
}

case_start() { CASES=$((CASES + 1)); echo "-- $1"; }

# The install-time settings the script reads, written into each case's HOME: the fixture owners and account,
# mode 0600.
seed_conf() {
  mkdir -p "$H/.claude"
  printf '%s\n' 'github_write_owners=notitial example-user' 'github_keychain_account=example-user' > "$H/.claude/install.conf"
  chmod 600 "$H/.claude/install.conf"
}
# conf_with <key=value>: the fixture settings with that line in place of its key's line, or added after them.
conf_with() {
  seed_conf
  grep -v "^${1%%=*}=" "$H/.claude/install.conf" > "$H/.claude/install.conf.new"
  printf '%s\n' "$1" >> "$H/.claude/install.conf.new"
  mv "$H/.claude/install.conf.new" "$H/.claude/install.conf"
  chmod 600 "$H/.claude/install.conf"
}
N=0
# new_case: fresh repo clone R (branch main, origin O), a HOME H holding the settings.
new_case() {
  N=$((N + 1))
  C="$T/c$N"
  R="$C/repo"
  O="$C/origin.git"
  H="$C/home"
  mkdir -p "$C" "$H"
  seed_conf
  cp -R "$T/base.git" "$O"
  git clone -q "$O" "$R" 2>/dev/null
  IC_ZDOT=""
}

gc() { git -C "$R" -c commit.gpgsign=false "$@"; }

# commit_main <path> <content> [push]: commit a file on main, optionally push it.
commit_main() {
  mkdir -p "$(dirname "$R/$1")"
  printf '%s\n' "$2" > "$R/$1"
  gc add "$1"
  gc commit -q -m "change $1"
  [ "${3:-}" = push ] && gc push -q origin main
  return 0
}

# ic <args...>: run the script from the case repo; sets OUT (stdout+stderr) and RC.
ic() {
  OUT=$(
    unset ZDOTDIR
    export HOME="$T/fakehome"
    export ICOPIES_TESTING=1 ICOPIES_ROOT="$R" ICOPIES_HOME="$H"
    [ -n "$IC_ZDOT" ] && export ICOPIES_ZDOTDIR="$IC_ZDOT"
    /bin/bash "$R/tools/install-copies.sh" "$@" 2>&1
  )
  RC=$?
}

make_links() {
  local cd="$H/.claude"
  mkdir -p "$cd/agents" "$cd/hooks" "$cd/rules" "$cd/skills" "$cd/tools"
  ln -s "$R/agents/a.md" "$cd/agents/a.md"
  ln -s "$R/hooks/h.sh" "$cd/hooks/h.sh"
  ln -s "$R/rules/r.md" "$cd/rules/r.md"
  ln -s "$R/skills/s" "$cd/skills/s"
  ln -s "$R/tools/statusline.sh" "$cd/statusline.sh"
  ln -s "$R/tools/workspace-lock/workspace-lock.sh" "$cd/tools/workspace-lock.sh"
  ln -s "$R/tools/shell-init.zsh" "$cd/tools/shell-init.zsh"
}
# wire_mcp: the github MCP wired at the checkout: the server binary beside the launcher, the `github` server
# registered at the launcher, the guard hook pointing at the guard.
wire_mcp() {
  mkdir -p "$R/tools/github-mcp/bin"
  printf '#!/bin/sh\n' > "$R/tools/github-mcp/bin/github-mcp-server"
  chmod 755 "$R/tools/github-mcp/bin/github-mcp-server"
  jq -n --arg c "$R/tools/github-mcp/launch" '{mcpServers: {github: {type: "stdio", command: $c, args: []}}}' > "$H/.claude.json"
  jq -n --arg c "$R/tools/github-mcp/guard.sh" '{hooks: {PreToolUse: [{matcher: "^mcp__github__.*$", hooks: [{type: "command", command: $c}]}]}}' > "$H/.claude/settings.json"
}
# everything installed and current
setup_current() {
  make_links
  wire_mcp
  printf 'source ~/.claude/tools/shell-init.zsh\n' > "$H/.zshrc"
}
# Seed: the files the script reads, committed on main and pushed to a bare base origin.
SEED="$T/seed"
mkdir -p "$SEED/tools/github-mcp" "$SEED/agents" "$SEED/hooks" "$SEED/rules" "$SEED/skills/s" "$SEED/tools/workspace-lock"
cp "$SCRIPT_SRC" "$SEED/tools/install-copies.sh"
printf 'launcher v1\n' > "$SEED/tools/github-mcp/launch"
printf 'guard v1\n' > "$SEED/tools/github-mcp/guard.sh"
printf '# agent\n' > "$SEED/agents/a.md"
printf '#!/bin/sh\n' > "$SEED/hooks/h.sh"
printf '# rule\n' > "$SEED/rules/r.md"
printf '# skill\n' > "$SEED/skills/s/SKILL.md"
printf '#!/bin/sh\n' > "$SEED/tools/statusline.sh"
printf '#!/bin/sh\n' > "$SEED/tools/workspace-lock/workspace-lock.sh"
printf '# init\n' > "$SEED/tools/shell-init.zsh"
git init -q -b main "$SEED"
git init -q --bare -b main "$T/base.git"
git -C "$SEED" remote add origin "$T/base.git"
git -C "$SEED" add -A
git -C "$SEED" -c commit.gpgsign=false commit -q -m seed
git -C "$SEED" push -q origin main

# ---------------------------------------------------------------- status
case_start "status 1: nothing installed"
new_case
ic status
expect_rc "status exits 1 with nothing installed" 1
expect_re "install.conf ok" "$OUT" '^ok +install\.conf$'
expect_re "a clean main is ok" "$OUT" '^ok +github-mcp checkout is on a clean main$'
expect_re "github-mcp binary MISSING" "$OUT" '^MISSING +github-mcp server binary \(tools/github-mcp/bin/github-mcp-server\)  -> tools/github-mcp/README\.md, Install$'
expect_re "github MCP server MISSING" "$OUT" '^MISSING +github MCP server \(not registered in ~/\.claude\.json\)  -> claude mcp add --scope user github -- '"$R"'/tools/github-mcp/launch$'
expect_re "github MCP guard hook MISSING" "$OUT" '^MISSING +github MCP guard hook \(none in ~/\.claude/settings\.json\)  -> /setup-claude$'
expect_re "a .zshrc that does not load the helpers is MISSING" "$OUT" '^MISSING +~/\.zshrc does not load the zsh helpers  -> add: source ~/\.claude/tools/shell-init\.zsh$'
expect_re "UNLINKED agent" "$OUT" '^UNLINKED +\.claude/agents/a\.md'
expect_re "UNLINKED shell-init.zsh" "$OUT" '^UNLINKED +\.claude/tools/shell-init\.zsh'
expect_has "links summary" "$OUT" "links     0 linked, 7 unlinked, 0 conflicting"
expect_has "count of items needing attention" "$OUT" "11 need attention"
expect_not "no root-owned folder is mentioned" "$OUT" "libexec"

case_start "status 2: everything installed and linked"
new_case
setup_current
ic status
expect_rc "status exits 0 when all current" 0
expect_has "all current" "$OUT" "all current"
expect_re "the binary is ok" "$OUT" '^ok +github-mcp server binary$'
expect_re "the server registration is ok" "$OUT" '^ok +github MCP server registered at this checkout$'
expect_re "the guard hook is ok" "$OUT" '^ok +github MCP guard hook points at this checkout$'
expect_re "the .zshrc line is ok" "$OUT" '^ok +~/\.zshrc loads the zsh helpers$'
expect_has "links summary" "$OUT" "links     7 linked, 0 unlinked, 0 conflicting"

case_start "status 3: the checkout is not a clean main"
new_case
setup_current
printf 'edited\n' >> "$R/tools/github-mcp/guard.sh"
ic status
expect_rc "status exits 1 for an edited tracked file" 1
expect_re "an edit is STALE" "$OUT" '^STALE +github-mcp checkout \(main, with edits: the guard and the launcher are off\)  -> work in a /tmp clone; put this checkout back on a clean main$'
expect_has "one item needs attention" "$OUT" "1 need attention"
gc checkout -q -- tools/github-mcp/guard.sh
printf 'untracked\n' > "$R/untracked-file"
ic status
expect_re "an untracked file is fine" "$OUT" '^ok +github-mcp checkout is on a clean main$'
gc checkout -q -b topic
ic status
expect_re "a branch other than main is STALE" "$OUT" '^STALE +github-mcp checkout \(topic: the guard and the launcher are off\)'

case_start "status 4: the server and the hook must point at this checkout"
new_case
setup_current
jq -n '{mcpServers: {github: {type: "stdio", command: "/elsewhere/launch"}}}' > "$H/.claude.json"
jq -n '{hooks: {PreToolUse: [{matcher: "^mcp__github__.*$", hooks: [{type: "command", command: "/elsewhere/guard.sh"}]}]}}' > "$H/.claude/settings.json"
ic status
expect_rc "status exits 1 when they point elsewhere" 1
expect_re "a server registered elsewhere is STALE" "$OUT" '^STALE +github MCP server \(registered at /elsewhere/launch\)'
expect_re "a hook elsewhere is STALE" "$OUT" '^STALE +github MCP guard hook \(points at /elsewhere/guard\.sh\)  -> /setup-claude$'
jq -n '{mcpServers: {other: {command: "x"}}}' > "$H/.claude.json"
ic status
expect_re "another server name does not count" "$OUT" '^MISSING +github MCP server'

case_start "status 5: the .zshrc line"
new_case
setup_current
printf '%s\n' 'export A=1' '  . "$HOME/.claude/tools/shell-init.zsh"' > "$H/.zshrc"
ic status
expect_re "a dot-sourced, indented line counts" "$OUT" '^ok +~/\.zshrc loads the zsh helpers$'
printf '%s\n' '# source ~/.claude/tools/shell-init.zsh' > "$H/.zshrc"
ic status
expect_re "a commented-out line does not count" "$OUT" '^MISSING +~/\.zshrc does not load'
printf '%s\n' 'source ~/.claude/tools/shell-init.zsh.bak' > "$H/.zshrc"
ic status
expect_re "another file whose name only starts the same does not count" "$OUT" '^MISSING +~/\.zshrc does not load'
mkdir -p "$C/zdot"
printf 'source ~/.claude/tools/shell-init.zsh\n' > "$C/zdot/.zshrc"
IC_ZDOT="$C/zdot"
ic status
expect_re "ZDOTDIR's .zshrc is the one read" "$OUT" "^ok +$C/zdot/\\.zshrc loads the zsh helpers\$"

case_start "status 6: conflicting link and a new unlinked hook"
new_case
setup_current
rm "$H/.claude/agents/a.md"
ln -s "$R/rules/r.md" "$H/.claude/agents/a.md"
commit_main hooks/new.sh '#!/bin/sh'
ic status
expect_rc "status exits 1" 1
expect_re "CONFLICT for the link pointing elsewhere" "$OUT" '^CONFLICT +\.claude/agents/a\.md \(not a link to agents/a\.md\)'
expect_re "UNLINKED for the new hook" "$OUT" '^UNLINKED +\.claude/hooks/new\.sh'
expect_has "links summary" "$OUT" "links     6 linked, 1 unlinked, 1 conflicting"

case_start "status 7: a regular file or a dangling link where a link belongs is a conflict"
new_case
setup_current
rm "$H/.claude/rules/r.md"
printf 'mine\n' > "$H/.claude/rules/r.md"
rm "$H/.claude/hooks/h.sh"
ln -s "$C/does-not-exist" "$H/.claude/hooks/h.sh"
ic status
expect_re "regular file is a CONFLICT" "$OUT" '^CONFLICT +\.claude/rules/r\.md'
expect_re "dangling link is a CONFLICT" "$OUT" '^CONFLICT +\.claude/hooks/h\.sh'
expect_has "links summary" "$OUT" "links     5 linked, 0 unlinked, 2 conflicting"

case_start "status 8: missing ref"
new_case
OUT=$(
  export HOME="$T/fakehome" ICOPIES_TESTING=1 ICOPIES_ROOT="$R" ICOPIES_HOME="$H"
  export ICOPIES_REF=no-such-branch
  /bin/bash "$R/tools/install-copies.sh" status 2>&1
)
RC=$?
expect_rc "status exits 1 for a missing ref" 1
expect_re "STALE names the ref" "$OUT" "^STALE +branch 'no-such-branch' not found"

case_start "status 9: main behind origin/main is STALE; main ahead is not"
new_case
setup_current
other="$C/other"
git clone -q "$O" "$other" 2>/dev/null
git -C "$other" -c commit.gpgsign=false commit -q --allow-empty -m v2
git -C "$other" push -q origin main
gc fetch -q origin
ic status
expect_rc "behind exits 1" 1
expect_re "behind is flagged" "$OUT" '^STALE +main is behind origin/main'
new_case
setup_current
commit_main notes.txt 'local only'
ic status
expect_not "ahead is not flagged as behind" "$OUT" "is behind origin"

case_start "overrides: ICOPIES_* are ignored without ICOPIES_TESTING=1"
new_case
OUT=$(
  export HOME="$T/fakehome" ICOPIES_ROOT="$C/nowhere" ICOPIES_HOME="$H" ICOPIES_REF=no-such-branch
  /bin/bash "$R/tools/install-copies.sh" status 2>&1
)
expect_not "ref override ignored" "$OUT" "no-such-branch"
expect_not "home override ignored" "$OUT" "$H"

case_start "usage: an unknown command"
new_case
ic install
expect_rc "an unknown command exits 2" 2
expect_has "usage names the commands" "$OUT" "usage: install-copies.sh status | automode"

# ---------------------------------------------------------------- install-time settings
case_start "settings 1: no install.conf"
new_case
rm "$H/.claude/install.conf"
make_links
wire_mcp
printf 'source ~/.claude/tools/shell-init.zsh\n' > "$H/.zshrc"
ic status
expect_rc "status exits 1 without the settings file" 1
expect_re "install.conf MISSING" "$OUT" '^MISSING +install\.conf \(the install-time settings\)  -> /setup-claude$'
expect_has "only the settings line needs attention" "$OUT" "1 need attention"

case_start "settings 2: an invalid value is STALE, with the reason"
new_case
make_links
wire_mcp
for bad_conf in 'github_write_owners=Not_An_Owner|github_write_owners: invalid value' \
  'github_keychain_account=a b|github_keychain_account: invalid value' \
  'github_keychain_account=a|b|github_keychain_account: invalid value' \
  'github_username=$(id)|github_username: invalid value' \
  'lan_host=nas.example.com|lan_host: invalid value' \
  'router_ip=8.8.8.8|router_ip: invalid value' \
  'Colour=blue|line 3: not a well-formed key' \
  'colour-name=blue|line 3: not a well-formed key' \
  'just text|line 3: not key=value'; do
  conf_with "${bad_conf%|*}"
  ic status
  expect_re "invalid settings ${bad_conf%|*}: STALE with the reason" "$OUT" "^STALE +install\\.conf \\(${bad_conf##*|}\\)"
done
seed_conf
printf '%s\n' 'github_write_owners=notitial' >> "$H/.claude/install.conf"
ic status
expect_re "a key given twice is STALE" "$OUT" '^STALE +install\.conf \(github_write_owners: given twice\)'
printf '%s\n' 'github_write_owners=notitial' > "$H/.claude/install.conf"
ic status
expect_re "a missing required key is STALE" "$OUT" '^STALE +install\.conf \(github_keychain_account: missing\)'
printf '%s\n' 'github_write_owners=notitial example-user' 'github_keychain_account=first.last@example' > "$H/.claude/install.conf"
ic status
expect_re "the optional keys may be left out, and an account may carry . and @" "$OUT" '^ok +install\.conf$'
seed_conf
printf '%s\n' 'github_username=example-user' 'lan_host=nas.lan' 'router_ip=10.0.0.1' >> "$H/.claude/install.conf"
ic status
expect_re "valid optional keys are ok" "$OUT" '^ok +install\.conf$'
seed_conf
printf '%s\n' 'other_tool_label=com.example' 'other_tool_note=Any Value | $(id) & "quotes"' >> "$H/.claude/install.conf"
ic status
expect_re "keys this script does not use are skipped, not an error, and listed" "$OUT" '^ok +install\.conf \(skipped, not used here: other_tool_label other_tool_note\)$'
expect_not "a skipped key is not STALE" "$OUT" "STALE    install.conf"
printf '%s\n' 'other_tool_label=again' >> "$H/.claude/install.conf"
ic status
expect_re "a skipped key given twice is still STALE" "$OUT" '^STALE +install\.conf \(other_tool_label: given twice\)'
conf_with 'github_username=Bad_User'
printf '%s\n' 'other_tool_label=x' >> "$H/.claude/install.conf"
ic status
expect_re "a known key's value is still checked when other keys are skipped" "$OUT" '^STALE +install\.conf \(github_username: invalid value\)'
for good_conf in 'lan_host=nas.home.arpa' 'lan_host=box.local' 'router_ip=172.16.0.1' 'router_ip=192.168.0.254'; do
  conf_with "$good_conf"
  ic status
  expect_re "valid setting $good_conf is ok" "$OUT" '^ok +install\.conf$'
done

case_start "settings 3: automode follows the write owners in install.conf"
new_case
mkdir -p "$R/.claude/skills/setup-claude/templates"
printf '%s\n' '{"autoMode": {"_note": "x <username>", "environment": ["$defaults", "User <username>", "Host <host>", "Router <router.ip>", "Plain"], "soft_deny": ["$defaults", "Deploys to <host> or <router.ip>"]}}' \
  > "$R/.claude/skills/setup-claude/templates/safe-permissions.json"
full_conf() {  # full_conf <owners> <github_username>
  printf '%s\n' "github_write_owners=$1" 'github_keychain_account=example-user' "github_username=$2" 'lan_host=nas.lan' 'router_ip=10.0.0.1' > "$H/.claude/install.conf"
}
json_of() { printf '%s\n' "$OUT" | grep -v '^automode: ' | jq -c .; }
NO_USER='{"environment":["$defaults","Host nas.lan","Router 10.0.0.1","Plain"],"soft_deny":["$defaults","Deploys to nas.lan or 10.0.0.1"]}'
ALL='{"environment":["$defaults","User example-user","Host nas.lan","Router 10.0.0.1","Plain"],"soft_deny":["$defaults","Deploys to nas.lan or 10.0.0.1"]}'
ic automode
expect_rc "automode exits 0 with no optional key" 0
expect_true "automode drops every entry whose setting is unset" test "$(printf '%s' "$OUT" | jq -c .)" = '{"environment":["$defaults","Plain"],"soft_deny":["$defaults"]}'
full_conf 'notitial' example-user
ic automode
expect_rc "automode exits 0 when github_username is not a write owner" 0
expect_true "github_username not in the write owners: the <username> entries are dropped, the host and router filled" test "$(json_of)" = "$NO_USER"
expect_has "automode says why" "$OUT" "automode: the <username> entries are left out: github_username (example-user) is not in github_write_owners"
full_conf 'notitial example-user2' example-user
ic automode
expect_has "an owner that only starts with github_username does not count" "$OUT" "is not in github_write_owners"
full_conf 'notitial example-user' example-user
ic automode
expect_not "github_username a write owner: no reason printed" "$OUT" "automode: "
expect_true "automode fills every placeholder" test "$(json_of)" = "$ALL"
expect_not "automode leaves out the notes" "$OUT" "_note"
ic automode --valued
expect_true "automode --valued prints only the entries carrying an install.conf value" test "$(json_of)" = '{"environment":["User example-user","Host nas.lan","Router 10.0.0.1"],"soft_deny":["Deploys to nas.lan or 10.0.0.1"]}'
full_conf 'notitial' example-user
ic automode --valued
expect_true "automode --valued follows the owner check" test "$(json_of)" = '{"environment":["Host nas.lan","Router 10.0.0.1"],"soft_deny":["Deploys to nas.lan or 10.0.0.1"]}'
ic automode --for-cleanup
expect_not "automode --for-cleanup skips the owner check, and says nothing" "$OUT" "automode: "
expect_true "automode --for-cleanup fills every placeholder" test "$(json_of)" = "$ALL"
ic automode --everything
expect_rc "automode refuses an unknown option" 2
rm "$H/.claude/install.conf"
ic automode
expect_rc "automode with no settings file exits 0" 0
expect_not "automode with no settings file prints no placeholder" "$OUT" "<"
conf_with 'router_ip=nope'
ic automode
expect_rc "automode refuses an invalid settings file" 1

case_start "usage: render is gone"
new_case
ic render
expect_rc "render is an unknown command" 2

echo "cases=$CASES"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
