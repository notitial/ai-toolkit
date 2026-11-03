#!/bin/bash
# Tests for hooks/git-mcp-redirect.sh (HOOK=<path> tests another copy). Run: bash tools/git-mcp-redirect/test-git-mcp-redirect.sh
# The hook and its sibling audit-logger.sh run from a temp copy under HOOK_SHELL (default /bin/bash, 3.2) with HOME
# pointed at a temp folder, so a deny never writes to the live audit log. Each case expects deny or pass (no output);
# the commands under test are only text, nothing here runs them. Without audit-logger.sh beside the hook (it is
# installed with the audit hooks), the audit case is skipped and says so.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../../hooks/git-mcp-redirect.sh}"
LOGGER="${LOGGER:-$(dirname "$HOOK")/audit-logger.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
SH="${HOOK_SHELL:-/bin/bash}"
T=$(mktemp -d "${TMPDIR:-/tmp}/git-mcp-redirect-XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/hooks" "$T/work"
cp "$HOOK" "$T/hooks/git-mcp-redirect.sh"
HAVE_LOGGER=0
[ -f "$LOGGER" ] && cp "$LOGGER" "$T/hooks/audit-logger.sh" && HAVE_LOGGER=1
PASS=0
FAIL=0

run() {  # run <stdin json>: prints the hook's stdout
  printf '%s' "$1" | HOME="$T" "$SH" "$T/hooks/git-mcp-redirect.sh" 2>/dev/null
}
bash_in() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }
decision() {
  local out
  out=$(run "$1")
  [ -z "$out" ] && { echo pass; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed
}
check() {  # check <deny|pass> <label> <command>
  local got
  got=$(decision "$(bash_in "$3")")
  if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $2: want $1, got $got"; fi
}
reason_has() {  # reason_has <label> <command> <substring of the deny reason>
  local out
  out=$(run "$(bash_in "$2")")
  if printf '%s' "$out" | jq -e --arg s "$3" '.hookSpecificOutput.permissionDecisionReason | contains($s)' >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: reason lacks '$3': $out"; fi
}

for sub in status diff log show blame add commit push pull fetch branch checkout merge rebase stash tag reset remote reflog clean worktree cherry-pick clone init; do
  check deny "mapped subcommand: $sub" "git $sub"
  reason_has "reason names the MCP tool: $sub" "git $sub" "mcp__git-mcp__git_$(printf '%s' "$sub" | tr - _)"
done
check deny "unmapped subcommand: bisect" 'git bisect start'
check deny "unmapped subcommand: gc"     'git gc'
reason_has "unmapped subcommand says so" 'git gc' "no MCP equivalent"

for sub in rev-parse ls-files describe show-ref var help check-ignore cat-file name-rev merge-base count-objects shortlog; do
  check pass "plumbing: $sub" "git $sub HEAD"
done
check pass "plumbing: --version"           'git --version'
check pass "plumbing: --exec-path"         'git --exec-path'
check pass "config --get"                  'git config --get user.name'
check pass "config --get-all"              'git config --get-all remote.origin.url'
check pass "config --list"                 'git config --list'
check deny "config write"                  'git config user.name someone'
check deny "config --unset"                'git config --unset user.name'
check deny "config --global write"         'git config --global core.editor vim'
check pass "symbolic-ref read"             'git symbolic-ref HEAD'
check pass "symbolic-ref -q read"          'git symbolic-ref -q HEAD'
check deny "symbolic-ref retarget"         'git symbolic-ref HEAD refs/heads/other'
check deny "symbolic-ref delete"           'git symbolic-ref -d HEAD'

check pass "no git at all"                 'ls -la'
check pass "git inside an echo string"     'echo "run git push later"'
check pass "git as an echo argument"       'echo git push'
check pass "git in a --reason value"       'tool --reason "why git push is blocked"'
check pass "git as a grep argument"        'grep git README.md'
check pass "gitk is not git"               'gitk --all'
check pass "a path containing git"         'ls docs/git-notes'
check pass "empty command"                 ''

check deny "after &&"                      'cd repo && git push'
check deny "after ;"                       'ls; git status'
check deny "after a pipe"                  'echo x | git apply'
check deny "in a subshell"                 '(git status)'
check deny "in a brace group"              '{ git status; }'
check deny "in a command substitution"     'echo $(git status)'
check deny "in backticks"                  'echo `git status`'
check deny "second line"                   $'ls\ngit status'
check deny "env wrapper"                   'env git push'
check deny "assignment prefix"             'FOO=1 git push'
check deny "quoted assignment prefix"      'FOO="a b" git push'
check deny "sudo wrapper"                  'sudo git push'
check deny "command wrapper"               'command git push'
check deny "env and an assignment"         'env FOO=1 git commit'
check deny "path-qualified git"            '/usr/bin/git push'
check deny "backslash-escaped git"         '\git push'
check deny "quoted git"                    '"git" push'
check deny "timeout wrapper"               'timeout 5 git push'
check deny "timeout with a unit"           'timeout 30s git push'
check deny "global -C option"              'git -C /repo status'
check deny "global -c option"              'git -c a=b log'
check deny "global --no-pager option"      'git --no-pager diff'
check deny "global --git-dir= option"      'git --git-dir=/x/.git status'
check pass "plumbing behind -C"            'git -C /repo rev-parse HEAD'
check pass "plumbing behind --no-pager"    'git --no-pager rev-parse HEAD'
check deny "plumbing then a write"         'git rev-parse HEAD && git push'
check deny "write then plumbing"           'git push && git rev-parse HEAD'
check pass "two plumbing calls"            'git rev-parse HEAD && git describe --tags'

check deny "substitution inside -C"        'git -C "$(git rev-parse --show-toplevel)" push'
check deny "backtick inside -C"            'git -C "`pwd`" push'
check deny "unrecognized global option"    'git --bare status'
reason_has "substitution deny says cannot classify" 'git -C "$(pwd)" push' "cannot be safely classified"
reason_has "unrecognized option deny says cannot classify" 'git --bare status' "cannot be safely classified"
check pass "plumbing, quoted argument"     "git rev-parse 'HEAD'"
check pass "plumbing, then a later command" "git describe 'v1'; echo done"

# The gaps the hook header names, pinned so the header stays true: change both together.
check pass "known gap: time wrapper"       'time git push'
check pass "known gap: nohup wrapper"      'nohup git push'
check pass "known gap: xargs wrapper"      'echo x | xargs git push'
check pass "known gap: option after sudo"  'sudo -u x git push'
check pass "known gap: option after env"   'env -i git push'
check pass "known gap: shell -c string"    "bash -c 'git push'"
check pass "known gap: leading !"          '! git push'
check pass "known gap: shell keyword"      'if true; then git push; fi'
check pass "known gap: leading redirect"   '>/dev/null git push'
check deny "known false deny: -c with ;"   "git -c 'a=b;c' status"

# Input that is not a JSON object passes, like empty input: the redirect is advisory.
want() {  # want <deny|pass> <label> <stdin json>
  local got
  got=$(decision "$3")
  if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $2: want $1, got $got"; fi
}
want pass "not JSON"                       '{"tool_name": "Bash", "tool_input": {'
want pass "JSON array, not an object"      '[]'
want pass "whitespace-only input"          $'  \t '
[ "$(decision '')" = pass ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: empty input"; }
[ "$(decision '{"tool_name":"Bash","tool_input":{}}')" = pass ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: no command field"; }

# Deny output shape: JSON, deny decision, exit 0.
out=$(bash_in 'git push' | HOME="$T" "$SH" "$T/hooks/git-mcp-redirect.sh" 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny"' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: deny output shape (rc=$rc): $out"
fi

# Fails open without jq: no output, exit 0.
out=$(bash_in 'git push' | HOME="$T" PATH=/nonexistent "$SH" "$T/hooks/git-mcp-redirect.sh" 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: no-jq fail-open (rc=$rc): $out"; fi

# A deny is recorded in the audit log under the input's cwd, tagged with this hook (only with the logger present).
if [ "$HAVE_LOGGER" = 1 ]; then
  printf '%s' "$(jq -nc --arg d "$T/work" '{tool_name: "Bash", cwd: $d, session_id: "s1", tool_input: {command: "git push"}}')" \
    | HOME="$T" "$SH" "$T/hooks/git-mcp-redirect.sh" >/dev/null 2>&1
  LOG=$(ls "$T"/work/.archive/audit/audit-*.log 2>/dev/null | head -1)
  if [ -n "$LOG" ] && jq -e 'select(.event == "deny" and .hook == "git-mcp-redirect" and (.reason | contains("mcp__git-mcp__git_push")))' "$LOG" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: deny is not audited (log: ${LOG:-none})"; fi
else
  echo "skip: deny is audited (no audit-logger.sh beside the hook)"
fi

# An allowed call writes nothing.
rm -rf "$T/work/.archive"
printf '%s' "$(jq -nc --arg d "$T/work" '{tool_name: "Bash", cwd: $d, tool_input: {command: "git rev-parse HEAD"}}')" \
  | HOME="$T" "$SH" "$T/hooks/git-mcp-redirect.sh" >/dev/null 2>&1
if [ ! -e "$T/work/.archive" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: an allowed call wrote an audit record"; fi

echo "git-mcp-redirect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
