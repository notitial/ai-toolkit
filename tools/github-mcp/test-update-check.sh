#!/bin/bash
# Tests for hooks/github-mcp-update-check.sh (HOOK=<path> tests another copy). Run: bash tools/github-mcp/test-update-check.sh
# The hook runs under HOOK_SHELL (default /bin/bash, 3.2). A copy points at stand-ins for the server binary and
# curl, and its state lives in a temp XDG_CACHE_HOME, so no test touches the network or the real install.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="${HOOK:-$HERE/../../hooks/github-mcp-update-check.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
SH="${HOOK_SHELL:-/bin/bash}"
T=$(mktemp -d "${TMPDIR:-/tmp}/mcp-update-XXXXXX")
# A background check from the last test may still be writing: retry the cleanup once.
trap 'rm -rf "$T" 2>/dev/null || { sleep 1; rm -rf "$T"; }' EXIT
PASS=0
FAIL=0

sed -e "s|^BIN=.*|BIN=$T/github-mcp-server|" -e "s|^ROOT=.*|ROOT=$T/repo|" -e "s|^CURL=.*|CURL=$T/curl|" "$SRC" > "$T/hook.sh"
if ! grep -q "^BIN=$T/" "$T/hook.sh" || ! grep -q "^ROOT=$T/" "$T/hook.sh" || ! grep -q "^CURL=$T/" "$T/hook.sh"; then
  echo "ABORT: the hook copy still points at the real binary or curl; fix the sed in this test"
  exit 1
fi
printf '#!/bin/sh\n[ "$1" = --version ] || exit 2\nprintf "GitHub MCP Server\\nVersion: %%s\\nCommit: abc\\nBuild Date: 2026-10-21T09:49:01Z\\n" "$(cat "%s/ver")"\n' \
  "$T" > "$T/github-mcp-server"
printf '#!/bin/sh\nfor a; do u=$a; done\necho "$u" >> "%s/curl-log"\n[ -e "%s/curl-fail" ] && exit 22\ncase $u in\n  */releases/latest) cat "%s/rel.json" ;;\n  */advisories*) cat "%s/adv.json" ;;\n  *) exit 22 ;;\nesac\n' \
  "$T" "$T" "$T" "$T" > "$T/curl"
chmod 755 "$T/github-mcp-server" "$T/curl"
# The hook runs the binary only when it matches the hash committed in its checkout at a HEAD on origin/main, so a
# throwaway checkout pins the fake one.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
RG=(git -C "$T/repo" -c commit.gpgsign=false)
mkdir -p "$T/repo/tools/github-mcp"
GOODPIN=$(cd "$T" && /usr/bin/shasum -a 256 github-mcp-server)
printf '%s\n' "$GOODPIN" > "$T/repo/tools/github-mcp/server.sha256"
"${RG[@]}" init -q -b main && "${RG[@]}" add -A && "${RG[@]}" commit -q -m init &&
  "${RG[@]}" update-ref refs/remotes/origin/main HEAD || { echo "ABORT: cannot build the throwaway checkout"; exit 1; }
# setpin <line or ""> [--local]: commit a pin ("" removes the file); with --local, origin/main is not moved to it.
setpin() {
  if [ -n "$1" ]; then printf '%s\n' "$1" > "$T/repo/tools/github-mcp/server.sha256"
  else rm -f "$T/repo/tools/github-mcp/server.sha256"; fi
  "${RG[@]}" add -A && "${RG[@]}" commit -q --allow-empty -m pin
  [ "${2:-}" = --local ] || "${RG[@]}" update-ref refs/remotes/origin/main HEAD
}

C="$T/cache/mcp-github"
INPUT='{"tool_name":"mcp__github__get_me","tool_input":{}}'
hook() { printf '%s' "$INPUT" | XDG_CACHE_HOME="$T/cache" "$SH" "$T/hook.sh" "$@" 2>/dev/null; }
check() { XDG_CACHE_HOME="$T/cache" "$SH" "$T/hook.sh" --check </dev/null >/dev/null 2>&1; }
reset() { rm -rf "$T/cache" "$T/curl-fail" "$T/curl-log"; }
rel() { jq -nc --arg t "$1" --argjson p "${2:-false}" '{tag_name: $t, draft: false, prerelease: $p}' > "$T/rel.json"; }
adv() { printf '%s\n' "${1:-[]}" > "$T/adv.json"; }
a1() {  # a1 <ghsa> <severity> <first patched version or null> <published_at> [range] [withdrawn_at] [package]
  jq -nc --arg id "$1" --arg s "$2" --argjson f "$3" --arg p "$4" --arg r "${5:-}" --arg w "${6:-}" \
    --arg pkg "${7:-github.com/github/github-mcp-server}" \
    '{ghsa_id: $id, severity: $s, published_at: $p, withdrawn_at: (if $w == "" then null else $w end),
      vulnerabilities: [{package: {ecosystem: "go", name: $pkg}, first_patched_version: $f,
        vulnerable_version_range: (if $r == "" then null else $r end)}]}'
}
ok() {
  if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}
msg() { printf '%s' "$1" | jq -r '.systemMessage // empty' 2>/dev/null; }
days_ago() { touch -t "$(date -v-"$2"d +%Y%m%d%H%M.%S)" "$1"; }
retrying() { [ -n "$(find "$C/checked" -mmin +7199 2>/dev/null)" ] && [ -z "$(find "$C/checked" -mmin +10079 2>/dev/null)" ]; }
fresh() { [ -e "$C/checked" ] && [ -z "$(find "$C/checked" -mmin +5 2>/dev/null)" ]; }
wait_for() { for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$1" ] && return 0; sleep 0.2; done; return 1; }

echo 2.0.3 > "$T/ver"

# Up to date: a check writes no notice, stamps the time, and a call prints nothing.
reset; rel v2.0.3; adv
check
ok "up to date: no notice" '[ ! -e "$C/notice.json" ]'
ok "up to date: stamped now" 'fresh'
ok "up to date: release and advisory urls" 'grep -q "/repos/github/github-mcp-server/releases/latest$" "$T/curl-log" &&
  grep -q "/advisories?type=reviewed&ecosystem=go&affects=github.com/github/github-mcp-server&per_page=100$" "$T/curl-log"'
out=$(hook); st=$?
ok "up to date: exit 0" '[ $st -eq 0 ]'
ok "up to date: no output" '[ -z "$out" ]'

# A newer release: the notice names it, the next call shows it once, and a second call the same day is quiet.
reset; rel v2.1.0; adv
check
ok "newer release: notice written" '[ "$(jq -r .latest "$C/notice.json")" = 2.1.0 ]'
out=$(hook)
ok "newer release: shown" 'msg "$out" | grep -q "2.0.3 is installed; 2.1.0 is released"'
ok "newer release: no permission decision" '! printf "%s" "$out" | jq -e ".hookSpecificOutput" >/dev/null 2>&1'
out=$(hook)
ok "same day: quiet" '[ -z "$out" ]'
touch -t "$(date -v-2H +%Y%m%d%H%M.%S)" "$C/shown"
out=$(hook)
ok "shown 2 hours ago: quiet" '[ -z "$out" ]'
days_ago "$C/shown" 2
out=$(hook)
ok "next day: shown again" 'msg "$out" | grep -q "2.1.0 is released"'

# Versions compare as numbers, not text; a v prefix on the installed version is read; other formats are not.
reset; echo 2.9.0 > "$T/ver"; rel v2.10.0; adv
check
ok "2.10.0 is newer than 2.9.0" '[ "$(jq -r .latest "$C/notice.json" 2>/dev/null)" = 2.10.0 ]'
reset; echo 2.10.0 > "$T/ver"; rel v2.9.0; adv
check
ok "2.9.0 is not newer than 2.10.0" '[ ! -e "$C/notice.json" ]'
reset; echo v2.0.3 > "$T/ver"; rel v2.1.0; adv
check
ok "installed v2.0.3 is read as 2.0.3" '[ "$(jq -r .installed "$C/notice.json" 2>/dev/null)" = 2.0.3 ]'
reset; echo dev > "$T/ver"; rel v2.1.0; adv
check
ok "installed dev: no notice, no api call, retry soon" '[ ! -e "$C/notice.json" ] && [ ! -e "$T/curl-log" ] && retrying'
echo 2.0.3 > "$T/ver"

# Prereleases and non-version tags are ignored.
reset; rel v2.1.0-rc.1 true; adv
check
ok "prerelease ignored" '[ ! -e "$C/notice.json" ]'
reset; rel nightly; adv
check
ok "non-version tag ignored" '[ ! -e "$C/notice.json" ] && fresh'

# Advisories: only those that apply to the installed version.
reset; rel v2.0.3
adv "[$(a1 GHSA-old high '"1.1.0"' 2026-07-28T00:00:00Z '< 1.1.0'),
      $(a1 GHSA-new critical '"2.0.4"' 2026-10-24T00:00:00Z '>= 2.0.0, < 2.0.4'),
      $(a1 GHSA-obj medium '{"identifier":"2.0.5"}' 2026-10-24T00:00:00Z),
      $(a1 GHSA-later high '"3.0.0"' 2026-10-24T00:00:00Z '>= 2.5.0, < 3.0.0'),
      $(a1 GHSA-oddrange high '"2.0.6"' 2026-10-24T00:00:00Z 'all versions'),
      $(a1 GHSA-withdrawn high '"2.0.7"' 2026-10-24T00:00:00Z '< 2.0.7' 2026-10-25T00:00:00Z),
      $(a1 GHSA-nofix-after low null 2026-10-22T00:00:00Z),
      $(a1 GHSA-nofix-before low null 2026-10-01T00:00:00Z),
      $(a1 'GHSA-bad id' high '"2.0.8"' 2026-10-24T00:00:00Z),
      $(a1 GHSA-nullsev high '"2.0.9"' 2026-10-24T00:00:00Z | jq -c '.ghsa_id = null'),
      $(a1 GHSA-other high '"9.9.9"' 2026-10-24T00:00:00Z '' '' github.com/someone/else)]"
check
ids=$(jq -r '[.advisories[].id] | sort | join(" ")' "$C/notice.json" 2>/dev/null)
ok "advisories: the applicable ones" '[ "$ids" = "GHSA-new GHSA-nofix-after GHSA-obj GHSA-oddrange" ]'
ok "advisories: no release named" '[ "$(jq -r .latest "$C/notice.json")" = "" ]'
out=$(hook)
ok "advisories: shown with severity and fix" 'msg "$out" | grep -q "GHSA-new (critical, fixed in 2.0.4)"'
ok "advisories: unpatched shown as none" 'msg "$out" | grep -q "GHSA-nofix-after (low, fixed in none)"'
ok "advisories: no release clause" '! msg "$out" | grep -q "is released"'

# An API failure or an unexpected answer keeps the old notice and retries in about a day.
reset; rel v2.1.0; adv
check
touch "$T/curl-fail"
check
ok "api failure: old notice kept" '[ "$(jq -r .latest "$C/notice.json")" = 2.1.0 ]'
ok "api failure: retry soon" 'retrying'
rm -f "$T/curl-fail"
touch "$C/checked"; printf '[]' > "$T/rel.json"
check
ok "release not an object: old notice kept, retry soon" '[ "$(jq -r .latest "$C/notice.json")" = 2.1.0 ] && retrying'
touch "$C/checked"; rel v2.1.0; printf '{"message":"rate limited"}' > "$T/adv.json"
check
ok "advisories not an array: old notice kept, retry soon" '[ "$(jq -r .latest "$C/notice.json")" = 2.1.0 ] && retrying'
reset; touch "$T/curl-fail"
check
ok "api failure, first run: no notice" '[ ! -e "$C/notice.json" ]'
rm -f "$T/curl-fail"
printf 'not json' > "$T/rel.json"
reset; check
ok "bad api json: no notice, retry soon" '[ ! -e "$C/notice.json" ] && retrying'

# An upgrade clears the notice and re-arms the check, even when it was shown today.
reset; rel v2.1.0; adv
check
hook >/dev/null
echo 2.1.0 > "$T/ver"
out=$(hook)
ok "upgraded: quiet" '[ -z "$out" ]'
ok "upgraded: notice cleared, check re-armed" '[ ! -e "$C/notice.json" ] && [ ! -e "$C/checked" ]'
echo 2.0.3 > "$T/ver"

# An unreadable --version keeps a pending notice.
reset; rel v2.1.0; adv
check
echo dev > "$T/ver"
hook >/dev/null
ok "unreadable version: notice kept" '[ "$(jq -r .latest "$C/notice.json" 2>/dev/null)" = 2.1.0 ]'
echo 2.0.3 > "$T/ver"

# A corrupt notice clears itself.
reset; rel v2.0.3; adv
check
printf 'garbage' > "$C/notice.json"
out=$(hook)
ok "corrupt notice: quiet and cleared" '[ -z "$out" ] && [ ! -e "$C/notice.json" ]'

# A due call starts the check in the background; a fresh stamp does not call the API.
reset; rel v2.1.0; adv
out=$(hook)
ok "first call: quiet" '[ -z "$out" ]'
wait_for "$C/notice.json"
ok "first call: background check wrote the notice" '[ -s "$C/notice.json" ]'
sleep 0.3
ok "first call: stamped now after the check" 'fresh'
rm -f "$T/curl-log"
hook >/dev/null
sleep 0.5
ok "fresh stamp: no api call" '[ ! -e "$T/curl-log" ]'
days_ago "$C/checked" 8
hook >/dev/null
wait_for "$T/curl-log"
ok "stale stamp: api called again" '[ -s "$T/curl-log" ]'

# One check at a time: a held lock stops a second one, and a due call that cannot check retries in about a day.
reset; rel v2.1.0; adv
mkdir -p "$C/lock.d"
hook >/dev/null
sleep 1
ok "lock held: no api call" '[ ! -e "$T/curl-log" ]'
ok "lock held: retry soon" 'retrying'
rmdir "$C/lock.d"; rm -f "$T/curl-log"
touch -t "$(date -v-6d -v-1H +%Y%m%d%H%M.%S)" "$C/checked"
hook >/dev/null
sleep 0.5
ok "stamp 6 days 1 hour old: no new check" '[ ! -e "$T/curl-log" ]'
mkdir "$C/lock.d"
days_ago "$C/lock.d" 1
check
ok "stale lock: removed and the check ran" '[ -s "$T/curl-log" ] && [ ! -e "$C/lock.d" ] && [ -s "$C/notice.json" ]'

# No installed binary: nothing happens.
reset; mv "$T/github-mcp-server" "$T/gone"
out=$(hook); st=$?
ok "no binary: exit 0, no output, no state" '[ $st -eq 0 ] && [ -z "$out" ] && [ ! -e "$C" ]'
mv "$T/gone" "$T/github-mcp-server"

# A binary that does not match the pinned hash is never run: the hook would hand it the session's environment.
reset; cp "$T/github-mcp-server" "$T/pinned-copy"
printf '#!/bin/sh\ntouch "%s/ran"\n' "$T" > "$T/github-mcp-server"
chmod 755 "$T/github-mcp-server"
out=$(hook); st=$?
ok "a binary that does not match the pin: not run, no output, no state" '[ $st -eq 0 ] && [ -z "$out" ] && [ ! -e "$T/ran" ] && [ ! -e "$C" ]'
cp "$T/pinned-copy" "$T/github-mcp-server"
setpin 'not-a-hash  github-mcp-server'
reset
out=$(hook); st=$?
ok "a malformed pin: nothing runs, no state" '[ $st -eq 0 ] && [ -z "$out" ] && [ ! -e "$C" ] && [ ! -e "$T/curl-log" ]'
setpin ""
reset
out=$(hook); st=$?
ok "no pin file: nothing runs, no state" '[ $st -eq 0 ] && [ -z "$out" ] && [ ! -e "$C" ] && [ ! -e "$T/curl-log" ]'
# Only the committed, reviewed pin counts: a work-tree edit or a commit origin/main lacks is not trusted.
setpin 'not-a-hash  github-mcp-server'
printf '%s\n' "$GOODPIN" > "$T/repo/tools/github-mcp/server.sha256"
reset
out=$(hook); st=$?
ok "a matching pin only in the work tree: nothing runs" '[ $st -eq 0 ] && [ -z "$out" ] && [ ! -e "$C" ]'
setpin "$GOODPIN" --local
reset
out=$(hook); st=$?
ok "a matching pin on a commit origin/main lacks: nothing runs" '[ $st -eq 0 ] && [ -z "$out" ] && [ ! -e "$C" ]'
"${RG[@]}" update-ref refs/remotes/origin/main HEAD
reset
out=$(hook); st=$?
ok "the same pin once on origin/main: the hook works again" '[ $st -eq 0 ] && [ -e "$C" ]'
# The session's environment does not steer the pin lookup.
reset
out=$(printf '%s' "$INPUT" | GIT_DIR=/nonexistent GIT_INDEX_FILE=/nonexistent XDG_CACHE_HOME="$T/cache" "$SH" "$T/hook.sh" 2>/dev/null); st=$?
ok "GIT_DIR in the session's environment: the pin is still read from the checkout" '[ $st -eq 0 ] && [ -e "$C" ]'

# Garbage on stdin changes nothing.
reset; rel v2.0.3; adv
out=$(printf 'not json' | XDG_CACHE_HOME="$T/cache" "$SH" "$T/hook.sh" 2>/dev/null); st=$?
ok "garbage input: exit 0, no output" '[ $st -eq 0 ] && [ -z "$out" ]'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
