#!/usr/bin/env bash
# test-update-check.sh: behavioural tests for hooks/update-check.sh. Runs the hook under /bin/bash (3.2) or
# HOOK_SHELL=<bash>; HOOK=<path> tests another copy. A stub curl on the PATH stands in for GitHub, HOME is a temp
# dir, and the "checkout" is a temp git repo with a github.com origin URL (nothing is fetched or pushed).

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../../hooks/update-check.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required" >&2; exit 2; }
PASS=0; FAIL=0
T=$(mktemp -d "${TMPDIR:-/tmp}/updcheck-XXXXXX")
trap 'rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H" "$T/bin"
SF="$H/.local/state/claude-update-check/acme__widget.json"
STARTUP='{"hook_event_name":"SessionStart","source":"startup"}'

cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "$CURL_LOG"
[ -f "$CURL_FAIL" ] && exit 22
cat "$CURL_BODY"
EOF
chmod +x "$T/bin/curl"

mkrepo() {  # mkrepo <dir> <origin url> [tag]
  git init -q "$1" && git -C "$1" remote add origin "$2" || return 1
  addtag "$1" "${3:-}"
}
addtag() {  # addtag <dir> [tag]: a new empty commit, annotated-tagged when a tag is given
  git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m c || return 1
  [ -z "${2:-}" ] || git -C "$1" -c user.name=t -c user.email=t@t -c tag.gpgSign=false tag -a -m release "$2"
}
mkrepo "$T/repo" https://github.com/acme/widget.git v1.2.0
mkrepo "$T/repo9" git@github.com:acme/widget.git v1.9.0
mkrepo "$T/notags" https://github.com/acme/widget.git
mkrepo "$T/rc" https://github.com/acme/widget.git v1.2.0-rc1
mkrepo "$T/other" https://example.com/acme/widget.git v1.2.0
mkrepo "$T/ssh" git@github.com-work:acme/widget.git v1.2.0
mkrepo "$T/deceit" https://example.com/github.com/x/y v1.2.0
# Tags that are not plain versions, or sit nearer to HEAD, must not hide the highest real one.
mkrepo "$T/shadow" https://github.com/acme/widget.git v1.9.0
addtag "$T/shadow" v1.10.0; addtag "$T/shadow" backup; addtag "$T/shadow" v1.11.0-rc1

hook() {  # hook <stdin> [args...]: sets OUT and ST
  local in=$1; shift
  OUT=$(printf '%s' "$in" | HOME="$H" PATH="$T/bin:$PATH" CURL_LOG="$T/curl.log" CURL_BODY="$T/body" CURL_FAIL="$T/fail" \
    "${HOOK_SHELL:-/bin/bash}" "$HOOK" "$@" 2>/dev/null); ST=$?
}
# No-argument runs go through a link to a copy of the hook inside the "checkout", as ai-toolkit's own wiring does.
mkdir -p "$T/repo/hooks" "$T/links"; cp "$HOOK" "$T/repo/hooks/update-check.sh"
ln -s "$T/repo/hooks/update-check.sh" "$T/links/update-check.sh"
own() {  # own <stdin> [args...]: like hook, but with no checkout and no --update argument
  local in=$1; shift
  OUT=$(printf '%s' "$in" | HOME="$H" PATH="$T/bin:$PATH" CURL_LOG="$T/curl.log" CURL_BODY="$T/body" CURL_FAIL="$T/fail" \
    "${HOOK_SHELL:-/bin/bash}" "$T/links/update-check.sh" "$@" 2>/dev/null); ST=$?
}
SELF=$(cd -P "$(dirname "$HOOK")" && pwd -P)/$(basename "$HOOK")  # how the script names itself when given arguments
REPOP=$(cd -P "$T/repo" && pwd -P)
body() { printf '{"tag_name":"%s"}' "$1" > "$T/body"; }
fetches() { [ -f "$T/curl.log" ] && wc -l < "$T/curl.log" | tr -d ' ' || echo 0; }
msg() { printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null; }
reset() { rm -rf "$H/.local" "$T/curl.log" "$T/fail"; }
seed() {  # seed <checked epoch> <latest> <skipped> <disabled true|false>
  mkdir -p "$(dirname "$SF")"
  jq -nc --argjson c "$1" --arg l "$2" --arg s "$3" --argjson d "$4" '{checked:$c,latest:$l,skipped:$s,disabled:$d}' > "$SF"
}
t() {  # t <label> <condition>
  if eval "$2"; then PASS=$((PASS + 1)); else echo "FAIL  $1"; FAIL=$((FAIL + 1)); fi
}
NOW=$(date +%s)
DAY=86400

# With no arguments the text names ai-toolkit's own skills; it is this exact text, nothing else.
reset; body v1.2.2
own "$STARTUP"
t "default reminder names the skills"       '[ "$(msg)" = "Update available for \"widget\" (1.2.0->1.2.2). Run /update-claude in the checkout to install it, /skip-update there to skip it or /disable-update to turn these notices off." ]'
own "" --toggle
t "default toggle names the skill"          '[ "$OUT" = "Update notifications for widget are off. Run /disable-update again to turn them on." ]'

# First run: fetches once, reminds, caches. With a checkout argument the text names the script's own commands.
reset; body v1.2.2
hook "$STARTUP" "$T/repo"
t "first run exits 0"                       '[ "$ST" = 0 ]'
t "first run fetches once"                  '[ "$(fetches)" = 1 ]'
t "first run asks the repo of the origin"   'grep -q "repos/acme/widget/releases/latest" "$T/curl.log"'
t "first run sends no identity header"      '! grep -qi "user\|token\|authorization" "$T/curl.log"'
t "message text"                            '[ "$(msg)" = "Update available for \"widget\" (1.2.0->1.2.2). Run /update-claude in the checkout to install it, bash $SELF --skip $REPOP to skip it or bash $SELF --toggle $REPOP to turn these notices off." ]'
t "state caches the latest and the time"    '[ "$(jq -r .latest "$SF")" = v1.2.2 ] && [ "$(jq -r .checked "$SF")" -ge "$NOW" ]'
t "state file is private"                   '[ "$(ls -l "$SF" | cut -c1-10)" = -rw------- ]'

# Inside the week: no fetch, still reminds from the cache.
hook "$STARTUP" "$T/repo"
t "within a week: no second fetch"          '[ "$(fetches)" = 1 ]'
t "within a week: reminds from the cache"   '[ -n "$(msg)" ]'

# Stale: fetches again and picks up a newer release.
seed $((NOW - 8 * DAY)) v1.2.2 "" false; body v1.3.0
hook "$STARTUP" "$T/repo"
t "stale: fetches again"                    '[ "$(fetches)" = 2 ]'
t "stale: the new latest is reported"       'printf %s "$(msg)" | grep -q "(1.2.0->1.3.0)"'

# Not newer: silent.
reset; body v1.2.0; hook "$STARTUP" "$T/repo"
t "equal release is silent"                 '[ -z "$OUT" ] && [ "$ST" = 0 ]'
reset; body v1.1.0; hook "$STARTUP" "$T/repo"
t "older release is silent"                 '[ -z "$OUT" ]'
reset; body v1.10.0; hook "$STARTUP" "$T/repo9"
t "1.10.0 is newer than 1.9.0"              'printf %s "$(msg)" | grep -q "(1.9.0->1.10.0)"'

# Skip.
reset; body v1.2.2; hook "$STARTUP" "$T/repo"
hook "" --skip "$T/repo"
t "skip says what it did"                   '[ "$OUT" = "Skipped widget 1.2.2. You'"'"'ll hear about the next release." ] && [ "$ST" = 0 ]'
hook "$STARTUP" "$T/repo"
t "skipped release is silent"               '[ -z "$OUT" ] && [ "$(fetches)" = 1 ]'
seed $((NOW - 1)) v1.3.0 v1.2.2 false; hook "$STARTUP" "$T/repo"
t "a release newer than the skipped one reminds again" 'printf %s "$(msg)" | grep -q "(1.2.0->1.3.0)"'
reset; body v1.2.0; hook "$STARTUP" "$T/repo"; hook "" --skip "$T/repo"
t "skip with nothing newer"                 '[ "$OUT" = "Nothing to skip: widget 1.2.0 is the latest release known." ]'
reset; hook "" --skip "$T/repo"
t "skip with no cache at all"               '[ "$OUT" = "Nothing to skip: widget 1.2.0 is the latest release known." ]'

# Disable and enable.
reset; body v1.2.2
hook "" --toggle "$T/repo"
t "toggle turns the notices off"            '[ "$OUT" = "Update notifications for widget are off. Run the same command again to turn them on." ]'
hook "$STARTUP" "$T/repo"
t "disabled: silent and no fetch"           '[ -z "$OUT" ] && [ "$(fetches)" = 0 ]'
hook "" --toggle "$T/repo"
t "toggle again turns them on"              '[ "$OUT" = "Update notifications for widget are on. Run the same command again to turn them off." ]'
hook "$STARTUP" "$T/repo"
t "enabled again: reminds"                  '[ -n "$(msg)" ]'

# The printed commands work as printed.
# Both the script and the checkout sit in folders with a space, so the printed paths must be escaped.
mkdir "$T/my dir"; cp "$HOOK" "$T/my dir/update-check.sh"; mkrepo "$T/my repo" https://github.com/acme/widget.git v1.2.0
reset; body v1.2.2; HOOK_SAVE=$HOOK; HOOK="$T/my dir/update-check.sh"; hook "$STARTUP" "$T/my repo"; HOOK=$HOOK_SAVE
text=$(msg)
cmd=$(printf '%s' "$text" | sed -n 's/.*install it, \(bash .*\) to skip it or .*/\1/p')
OUT=$(HOME="$H" PATH="$T/bin:$PATH" CURL_LOG="$T/curl.log" CURL_BODY="$T/body" CURL_FAIL="$T/fail" /bin/bash -c "$cmd" 2>&1)
t "the printed --skip command skips the release" '[ -n "$cmd" ] && [ "$OUT" = "Skipped widget 1.2.2. You'"'"'ll hear about the next release." ] && [ "$(jq -r .skipped "$SF")" = v1.2.2 ]'
cmd=$(printf '%s' "$text" | sed -n 's/.*to skip it or \(bash .*\) to turn these.*/\1/p')
OUT=$(HOME="$H" PATH="$T/bin:$PATH" CURL_LOG="$T/curl.log" CURL_BODY="$T/body" CURL_FAIL="$T/fail" /bin/bash -c "$cmd" 2>&1)
t "the printed --toggle command turns the notices off" '[ -n "$cmd" ] && printf %s "$OUT" | grep -q "are off" && [ "$(jq -r .disabled "$SF")" = true ]'

# The other repo's own update command.
reset; body v1.2.2; hook "$STARTUP" --update /update-manager "$T/repo"
t "--update names the repo's command"       'printf %s "$(msg)" | grep -q "Run /update-manager in the checkout"'

# Failures stay quiet.
reset; : > "$T/fail"; hook "$STARTUP" "$T/repo"
t "curl failure is silent, exit 0"          '[ -z "$OUT" ] && [ "$ST" = 0 ]'
hook "$STARTUP" "$T/repo"
t "a failed attempt is not retried at once" '[ "$(fetches)" = 1 ]'
t "a failed attempt is stamped to retry in a day" '[ "$(jq -r .checked "$SF")" -gt $((NOW - 7 * DAY)) ] && [ "$(jq -r .checked "$SF")" -lt $((NOW - 5 * DAY)) ]'
rm -f "$T/fail"; seed $((NOW - 7 * DAY)) "" "" false; body v1.2.2; hook "$STARTUP" "$T/repo"
t "after a failure, the next check comes a day later" '[ "$(fetches)" = 2 ] && [ -n "$(msg)" ]'
reset; printf '<html>rate limited</html>' > "$T/body"; hook "$STARTUP" "$T/repo"
t "a non-JSON answer is silent"             '[ -z "$OUT" ] && [ "$ST" = 0 ]'
reset; printf '{"tag_name":"nightly"}' > "$T/body"; hook "$STARTUP" "$T/repo"
t "a non-version tag is ignored"            '[ -z "$OUT" ] && [ -f "$SF" ] && [ "$(jq -r .latest "$SF")" = "" ]'
reset; seed $((NOW - 8 * DAY)) v1.2.2 "" false; : > "$T/fail"; hook "$STARTUP" "$T/repo"
t "a failed fetch keeps the cached latest"  'printf %s "$(msg)" | grep -q "(1.2.0->1.2.2)"'
reset; mkdir -p "$(dirname "$SF")"; printf 'not json' > "$SF"; body v1.2.2; hook "$STARTUP" "$T/repo"
t "a damaged state file is rebuilt"         '[ -n "$(msg)" ] && jq -e . "$SF" >/dev/null'

# Not a startup, nothing to compare, or not GitHub.
reset; body v1.2.2
hook '{"source":"resume"}' "$T/repo";  t "resume is silent"   '[ -z "$OUT" ] && [ "$(fetches)" = 0 ]'
hook '{"source":"fork"}' "$T/repo";    t "fork is silent"     '[ -z "$OUT" ] && [ "$(fetches)" = 0 ]'
hook 'not json' "$T/repo";             t "malformed input"    '[ -z "$OUT" ] && [ "$ST" = 0 ]'
hook '' "$T/repo";                     t "empty input"        '[ -z "$OUT" ] && [ "$ST" = 0 ]'
hook '[]' "$T/repo";                   t "array input"        '[ -z "$OUT" ] && [ "$ST" = 0 ]'
hook "$STARTUP" "$T/other";            t "a non-github origin is silent" '[ -z "$OUT" ] && [ "$(fetches)" = 0 ]'
hook "$STARTUP" "$T/nowhere";          t "a missing checkout is silent" '[ -z "$OUT" ] && [ "$ST" = 0 ]'

# A checkout with no release tag (every install made before the first release) is behind any release.
reset; body v0.1.0; hook "$STARTUP" "$T/notags"
t "no tag in the checkout: the first release is announced" '[ "$(fetches)" = 1 ] && printf %s "$(msg)" | grep -q "(none->0.1.0)"'
reset; body v0.1.0; hook "$STARTUP" "$T/rc"
t "only a pre-release tag counts as no tag"  'printf %s "$(msg)" | grep -q "(none->0.1.0)"'
hook "" --skip "$T/notags"
t "skip works without a local tag"           '[ "$OUT" = "Skipped widget 0.1.0. You'"'"'ll hear about the next release." ]'
hook "$STARTUP" "$T/notags"
t "a skipped first release stays silent"     '[ -z "$OUT" ]'
reset; hook "" --skip "$T/notags"
t "skip with no tag and no cache"            '[ "$OUT" = "Nothing to skip: no release is known for widget yet." ] && [ "$ST" = 0 ]'
hook "" --toggle "$T/notags"
t "toggle works without a local tag"         '[ "$ST" = 0 ] && printf %s "$OUT" | grep -q "are off"'

reset; body v1.10.1; hook "$STARTUP" "$T/shadow"
t "the highest plain tag counts, not the nearest or a pre-release" 'printf %s "$(msg)" | grep -q "(1.10.0->1.10.1)"'
reset; body v1.2.2; hook "$STARTUP" "$T/ssh"
t "an ssh alias origin (github.com-work) works" 'printf %s "$(msg)" | grep -q "(1.2.0->1.2.2)" && grep -q "repos/acme/widget/" "$T/curl.log"'
reset; hook "$STARTUP" "$T/deceit"
t "github.com inside another host's path is not GitHub" '[ -z "$OUT" ] && [ "$(fetches)" = 0 ]'
reset; mkdir -p "$H/.local/state"; chmod 555 "$H/.local/state"; body v1.2.2; hook "$STARTUP" "$T/repo"
t "an unwritable state dir still reminds, exit 0" '[ "$ST" = 0 ] && [ -n "$(msg)" ]'
chmod 755 "$H/.local/state"

# The default checkout is the repo of the script, found through a link.
reset; body v1.2.2
OUT=$(printf '%s' "$STARTUP" | HOME="$H" PATH="$T/bin:$PATH" CURL_LOG="$T/curl.log" CURL_BODY="$T/body" CURL_FAIL="$T/fail" \
  "${HOOK_SHELL:-/bin/bash}" "$T/links/update-check.sh" 2>/dev/null)
t "no argument: the script's own repo, through a link" 'printf %s "$OUT" | jq -r .systemMessage | grep -q "(1.2.0->1.2.2)"'
reset; ln -s ../repo/hooks/update-check.sh "$T/links/rel.sh"
OUT=$(printf '%s' "$STARTUP" | HOME="$H" PATH="$T/bin:$PATH" CURL_LOG="$T/curl.log" CURL_BODY="$T/body" CURL_FAIL="$T/fail" \
  "${HOOK_SHELL:-/bin/bash}" "$T/links/rel.sh" 2>/dev/null)
t "no argument: through a relative link"    'printf %s "$OUT" | jq -r .systemMessage | grep -q "(1.2.0->1.2.2)"'

echo "update-check: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
