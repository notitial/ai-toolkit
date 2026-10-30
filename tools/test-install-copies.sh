#!/bin/bash
# Tests for tools/install-copies.sh. Run: bash tools/test-install-copies.sh
# Each case builds a throwaway repo (branch main plus a bare origin) with the files the script reads, and runs its copy
# of the script against a temp HOME and a temp MCP dir. Nothing touches the real checkout, ~/.claude or /usr/local.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
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
# mode 0600. render_fixture fills a github-mcp blob the way the script does with those values.
seed_conf() {
  mkdir -p "$H/.claude"
  printf '%s\n' 'github_write_owners=notitial example-user' 'github_keychain_account=example-user' > "$H/.claude/install.conf"
  chmod 600 "$H/.claude/install.conf"
}
render_fixture() { sed -e 's|__GITHUB_WRITE_OWNERS__|["notitial","example-user"]|g' -e 's|__GITHUB_KEYCHAIN_ACCOUNT__|example-user|g'; }
# conf_with <key=value>: the fixture settings with that line in place of its key's line, or added after them.
conf_with() {
  seed_conf
  grep -v "^${1%%=*}=" "$H/.claude/install.conf" > "$H/.claude/install.conf.new"
  printf '%s\n' "$1" >> "$H/.claude/install.conf.new"
  mv "$H/.claude/install.conf.new" "$H/.claude/install.conf"
  chmod 600 "$H/.claude/install.conf"
}
N=0
# new_case: fresh repo clone R (branch main, origin O), a HOME H holding the settings, an MCP dir path M (not created).
new_case() {
  N=$((N + 1))
  C="$T/c$N"
  R="$C/repo"
  O="$C/origin.git"
  H="$C/home"
  M="$C/mcp"
  mkdir -p "$C" "$H"
  seed_conf
  cp -R "$T/base.git" "$O"
  git clone -q "$O" "$R" 2>/dev/null
  IC_SKIP_PERM=1 IC_ZDOT=""
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
    export ICOPIES_TESTING=1 ICOPIES_ROOT="$R" ICOPIES_HOME="$H" ICOPIES_MCP_DIR="$M"
    [ "$IC_SKIP_PERM" = 1 ] && export ICOPIES_SKIP_PERM_CHECK=1
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
# sync_mcp: the root-owned github MCP pair current (main's blobs rendered with the fixture settings).
sync_mcp() {
  mkdir -p "$M"
  git -C "$R" show main:tools/github-mcp/launch | render_fixture > "$M/launch"
  git -C "$R" show main:tools/github-mcp/guard.sh | render_fixture > "$M/guard.sh"
}
# everything installed and current
setup_current() {
  make_links
  sync_mcp
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
expect_re "github-mcp MISSING for an absent dir" "$OUT" "^MISSING +github-mcp \\($M does not exist\\)  -> ghm-install \\(needs sudo\\)$"
expect_re "a .zshrc that does not load the helpers is MISSING" "$OUT" '^MISSING +~/\.zshrc does not load the zsh helpers  -> add: source ~/\.claude/tools/shell-init\.zsh$'
expect_re "UNLINKED agent" "$OUT" '^UNLINKED +\.claude/agents/a\.md'
expect_re "UNLINKED shell-init.zsh" "$OUT" '^UNLINKED +\.claude/tools/shell-init\.zsh'
expect_has "links summary" "$OUT" "links     0 linked, 7 unlinked, 0 conflicting"
expect_has "count of items needing attention" "$OUT" "9 need attention"

case_start "status 2: everything installed and linked"
new_case
setup_current
ic status
expect_rc "status exits 0 when all current" 0
expect_has "all current" "$OUT" "all current"
expect_re "github-mcp launch ok" "$OUT" '^ok +github-mcp launch$'
expect_re "github-mcp guard ok" "$OUT" '^ok +github-mcp guard\.sh$'
expect_re "the .zshrc line is ok" "$OUT" '^ok +~/\.zshrc loads the zsh helpers$'
expect_has "links summary" "$OUT" "links     7 linked, 0 unlinked, 0 conflicting"

case_start "status 3: github-mcp guard.sh differs"
new_case
setup_current
printf 'guard edited\n' > "$M/guard.sh"
ic status
expect_rc "status exits 1 for a stale guard" 1
expect_re "guard.sh STALE" "$OUT" '^STALE +github-mcp guard\.sh \(differs from main\)  -> ghm-install \(needs sudo\)$'
expect_re "launch still ok" "$OUT" '^ok +github-mcp launch$'
expect_has "one item needs attention" "$OUT" "1 need attention"

case_start "status 4: github-mcp owner and mode are checked"
new_case
setup_current
IC_SKIP_PERM=0
ic status
expect_rc "status exits 1 when the files are not root-owned" 1
expect_re "launch STALE for owner/mode" "$OUT" "^STALE +github-mcp launch \\(owner/mode is '[^']*', want 'root:wheel 755'\\)"
expect_re "the folder STALE for owner/mode" "$OUT" "^STALE +github-mcp folder \\(owner/mode is '[^']*', want 'root:wheel 755'\\)"

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
  export HOME="$T/fakehome" ICOPIES_TESTING=1 ICOPIES_ROOT="$R" ICOPIES_HOME="$H" ICOPIES_MCP_DIR="$M"
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
expect_has "usage names the commands" "$OUT" "usage: install-copies.sh status | render"

# ---------------------------------------------------------------- install-time settings
case_start "settings 1: no install.conf"
new_case
rm "$H/.claude/install.conf"
make_links
sync_mcp
printf 'source ~/.claude/tools/shell-init.zsh\n' > "$H/.zshrc"
ic status
expect_rc "status exits 1 without the settings file" 1
expect_re "install.conf MISSING" "$OUT" '^MISSING +install\.conf \(the install-time settings\)  -> /setup-claude$'
expect_re "github-mcp MISSING for the settings" "$OUT" '^MISSING +github-mcp \(install settings; run /setup-claude\)$'
expect_not "no github-mcp file is compared without the settings" "$OUT" "github-mcp launch"
expect_has "the two settings lines need attention" "$OUT" "2 need attention"

case_start "settings 2: an invalid value is STALE, with the reason"
new_case
make_links
sync_mcp
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
conf_with 'github_write_owners=Not_An_Owner'
ic status
expect_re "github-mcp is STALE for unusable settings" "$OUT" '^STALE +github-mcp \(install settings: github_write_owners: invalid value; run /setup-claude\)$'
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
ic render --show
expect_rc "render works beside skipped keys" 0
expect_has "render still reads the known keys beside skipped ones" "$OUT" "github_write_owners: notitial example-user"
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

case_start "settings 3: the root copies are compared rendered"
new_case
commit_main tools/github-mcp/launch 'security -a __GITHUB_KEYCHAIN_ACCOUNT__ -w'
commit_main tools/github-mcp/guard.sh "WRITE_OWNERS='__GITHUB_WRITE_OWNERS__'"
make_links
sync_mcp
expect_has "the fixture render fills the account" "$(cat "$M/launch")" "security -a example-user -w"
ic status
expect_re "a rendered launch is ok" "$OUT" '^ok +github-mcp launch$'
expect_re "a rendered guard is ok" "$OUT" '^ok +github-mcp guard\.sh$'
printf '%s\n' 'github_write_owners=notitial example-user' 'github_keychain_account=other-user' > "$H/.claude/install.conf"
ic status
expect_re "a changed account setting makes the launcher STALE" "$OUT" '^STALE +github-mcp launch \(differs from main\)'
expect_re "the guard stays ok" "$OUT" '^ok +github-mcp guard\.sh$'

case_start "settings 4: render and automode"
new_case
printf '%s\n' "WRITE_OWNERS='__GITHUB_WRITE_OWNERS__'" 'tok -a __GITHUB_KEYCHAIN_ACCOUNT__ -w' > "$C/in"
ic render < "$C/in"
expect_rc "render exits 0" 0
expect_has "render fills the owners as a JSON array" "$OUT" "WRITE_OWNERS='[\"notitial\",\"example-user\"]'"
expect_has "render fills the account" "$OUT" "tok -a example-user -w"
ic render --show < /dev/null
expect_has "render --show prints the owners" "$OUT" "github_write_owners: notitial example-user"
expect_has "render --show prints the account" "$OUT" "github_keychain_account: example-user"
printf '%s\n' 'x __SOMETHING_ELSE__' > "$C/in2"
ic render < "$C/in2"
expect_rc "render refuses a left-over placeholder" 1
expect_not "render prints nothing on a refusal" "$OUT" "__SOMETHING_ELSE__"
expect_has "render says why" "$OUT" "a placeholder is left; not rendered"
mkdir -p "$R/.claude/skills/setup-claude/templates"
printf '%s\n' '{"autoMode": {"_note": "x <username>", "environment": ["$defaults", "User <username>", "Host <host>", "Router <router.ip>", "Plain"], "soft_deny": ["$defaults", "Deploys to <host> or <router.ip>"]}}' \
  > "$R/.claude/skills/setup-claude/templates/safe-permissions.json"
if command -v jq >/dev/null 2>&1; then
  ic automode
  expect_rc "automode exits 0 with no optional key" 0
  expect_true "automode drops every entry whose setting is unset" test "$(printf '%s' "$OUT" | jq -c .)" = '{"environment":["$defaults","Plain"],"soft_deny":["$defaults"]}'
  printf '%s\n' 'github_username=example-user' 'lan_host=nas.lan' 'router_ip=10.0.0.1' >> "$H/.claude/install.conf"
  json_of() { printf '%s\n' "$OUT" | grep -v '^automode: ' | jq -c .; }
  ic automode
  expect_rc "automode exits 0 with no installed guard" 0
  expect_true "no installed guard: the <username> entries are dropped, the host and router filled" test "$(json_of)" = '{"environment":["$defaults","Host nas.lan","Router 10.0.0.1","Plain"],"soft_deny":["$defaults","Deploys to nas.lan or 10.0.0.1"]}'
  expect_has "no installed guard: automode says why" "$OUT" "automode: the <username> entries are left out: github_username (example-user) is not a write owner in the installed guard"
  mkdir -p "$M"
  printf '%s\n' '# guard' "WRITE_OWNERS='[\"notitial\"]'" > "$M/guard.sh"
  ic automode
  expect_true "a guard without github_username among its owners: the <username> entries are dropped" test "$(json_of)" = '{"environment":["$defaults","Host nas.lan","Router 10.0.0.1","Plain"],"soft_deny":["$defaults","Deploys to nas.lan or 10.0.0.1"]}'
  printf '%s\n' '# guard' "WRITE_OWNERS='[\"notitial\",\"example-user2\"]'" > "$M/guard.sh"
  ic automode
  expect_has "an owner that only starts with github_username does not count" "$OUT" "is not a write owner in the installed guard"
  printf '%s\n' '# guard' "WRITE_OWNERS='[\"notitial\",\"example-user\"]'" > "$M/guard.sh"
  ic automode
  expect_not "github_username a write owner in the installed guard: no reason printed" "$OUT" "automode: "
  expect_true "automode fills every placeholder" test "$(json_of)" = '{"environment":["$defaults","User example-user","Host nas.lan","Router 10.0.0.1","Plain"],"soft_deny":["$defaults","Deploys to nas.lan or 10.0.0.1"]}'
  expect_not "automode leaves out the notes" "$OUT" "_note"
  ic automode --valued
  expect_true "automode --valued prints only the entries carrying an install.conf value" test "$(json_of)" = '{"environment":["User example-user","Host nas.lan","Router 10.0.0.1"],"soft_deny":["Deploys to nas.lan or 10.0.0.1"]}'
  rm "$M/guard.sh"
  ic automode --valued
  expect_true "automode --valued follows the guard check" test "$(json_of)" = '{"environment":["Host nas.lan","Router 10.0.0.1"],"soft_deny":["Deploys to nas.lan or 10.0.0.1"]}'
  ic automode --for-cleanup
  expect_not "automode --for-cleanup skips the guard check, and says nothing" "$OUT" "automode: "
  expect_true "automode --for-cleanup fills every placeholder" test "$(json_of)" = '{"environment":["$defaults","User example-user","Host nas.lan","Router 10.0.0.1","Plain"],"soft_deny":["$defaults","Deploys to nas.lan or 10.0.0.1"]}'
  ic automode --everything
  expect_rc "automode refuses an unknown option" 2
  rm "$H/.claude/install.conf"
  ic automode
  expect_rc "automode with no settings file exits 0" 0
  expect_not "automode with no settings file prints no placeholder" "$OUT" "<"
  conf_with 'router_ip=nope'
  ic automode
  expect_rc "automode refuses an invalid settings file" 1
else
  echo "SKIP: jq is missing; the automode cases are not run"
fi
conf_with 'router_ip=nope'
ic render < "$C/in"
expect_rc "render refuses an invalid settings file" 1
rm "$H/.claude/install.conf"
ic render < "$C/in"
expect_rc "render exits 3 with no settings file" 3
expect_has "render names the settings step" "$OUT" "run /setup-claude"

echo "cases=$CASES"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
