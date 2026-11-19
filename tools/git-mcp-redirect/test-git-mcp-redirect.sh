#!/bin/bash
# Tests for hooks/git-mcp-redirect.sh (HOOK=<path> tests another copy). Run: bash tools/git-mcp-redirect/test-git-mcp-redirect.sh
# The hook and its sibling audit-logger.sh run from a temp copy under HOOK_SHELL (default /bin/bash, 3.2) with HOME
# pointed at a temp folder, so a deny never writes to the live audit log. Each case expects deny or pass (no output);
# the commands under test are only text, nothing here runs them. The hook is the one owner of Bash git, fail-closed. Without audit-logger.sh beside the hook (it is
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
cp -R "${HOOK%/*}/lib" "$T/hooks/lib"
HAVE_LOGGER=0
[ -f "$LOGGER" ] && cp "$LOGGER" "$T/hooks/audit-logger.sh" && HAVE_LOGGER=1
PASS=0
FAIL=0

run() {  # run <stdin json>: prints the hook's stdout, or "crash" for a non-zero exit with no output (a block under || exit 2)
  local out rc
  out=$(printf '%s' "$1" | HOME="$T" "$SH" "$T/hooks/git-mcp-redirect.sh" 2>/dev/null); rc=$?
  if [ -z "$out" ] && [ "$rc" != 0 ]; then echo crash; else printf '%s' "$out"; fi
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

# Git behind what the shell lets stand in front of it: wrappers and their options, keywords, redirects, nested strings.
check deny "time wrapper"                  'time git push'
check deny "nohup wrapper"                 'nohup git push'
check deny "exec wrapper"                  'exec git push'
check deny "xargs wrapper"                 'echo x | xargs git push'
check deny "xargs with options"            'echo x | xargs -n 1 -I {} git push {}'
check deny "option after sudo"             'sudo -u x git push'
check deny "option after env"              'env -i git push'
check deny "option after timeout"          'timeout -s KILL 5 git push'
check deny "nice wrapper"                  'nice -n 5 git push'
check deny "find -exec"                    'find . -name x -exec git reset --hard \;'
check deny "find -execdir after another -exec" 'find . -exec echo {} \; -execdir git clean -fd {} +'
check pass "find -exec of a plain command" 'find . -name x -exec grep git {} +'
check pass "find -exec of plumbing"        'find . -maxdepth 2 -exec git -C {} rev-parse HEAD \;'
check deny "doas wrapper"                  'doas -u x git push'
check deny "caffeinate wrapper"            'caffeinate -i -t 60 git push'
check deny "su -c string"                  "su -c 'git reset --hard' x"
check deny "xargs option with a value (BSD -J)" 'echo x | xargs -J % git push %'
check deny "xargs long option with a value" 'echo x | xargs --max-args 1 git push'
check deny "upper-case GIT (case-insensitive file system)" 'GIT push'
check deny "upper-case XARGS"              'echo x | XARGS git push'
check deny "shell -c string"               "bash -c 'git push'"
check deny "sh -c string"                  "sh -c 'git -C /r push origin feature'"
check deny "bash -lc string"               'bash -lc "git -C /r clean -fdx"'
check deny "nested shell -c strings"       "sh -c \"bash -c 'git push'\""
check deny "eval string"                   'eval "git push"'
check deny "leading !"                     '! git push'
check deny "if, then, fi"                  'if true; then git push; fi'
check deny "if on git itself"              'if git -C /r reset --hard; then :; fi'
check deny "while loop"                    'while true; do git fetch; done'
check deny "leading redirect"              '>/dev/null git push'
check deny "git after a heredoc body"      $'cat <<EOF\ntext\nEOF\ngit push'
check deny "git in a subshell, cd first"   '(cd x && git -C . push --force)'
check deny "git in a quoted-arg command substitution" 'echo "$(git status)"'
check deny "git in a variable assignment"  'D=$(git status)'
check pass "git in a heredoc body"         $'cat <<EOF\ngit push\nEOF'
check pass "git in a comment"              'ls # git push'
check pass "git as xargs data"             'echo git | xargs echo'
check deny "-c is not skipped (it can run a command)" "git -c core.fsmonitor=x rev-parse HEAD"
check deny "-c with ; in the value"        "git -c 'a=b;c' status"
check deny "git alone"                     'git'
check deny "only global options"           'git -C /repo'

# Every Bash git write that the other guards used to judge on their own: the redirect denies all of it.
while IFS= read -r c; do
  check deny "bash git: $c" "$c"
done <<'EOF'
git commit -m x
git add .
git checkout main
git checkout -b feat
git checkout -- .
git checkout .
git restore .
git reset --hard
git reset HEAD~3 --hard
git reset --soft HEAD~1
git -c core.x=y reset --hard
/usr/bin/git -C /x reset --hard
git clean -fd
git clean -d -f
git clean --force
git clean -n
git -C /x clean -fd
git stash
git stash pop
git rebase main
git merge feat
git merge --ff-only origin/main
git pull
git pull --ff-only
git config core.hooksPath /tmp/h
git config -f /r/.git/config user.name x
git config --file /r/x k v
git tag v1
git tag -d v1
git branch newb
git branch -D old
git branch -d x
git branch -f topic HEAD
git branch --delete --force topic
git -C /x branch -D topic
git remote add x https://example.invalid/r.git
git worktree add ../w
git -C /r commit -m x
git --git-dir=/r/.git commit -m x
git --work-tree=/r checkout .
git --work-tree=sub checkout .
git -C ../live commit -m x
cd /r && git commit -m x
git clone https://example.invalid/r.git /r/sub
git clone -b main https://example.invalid/r.git /x
git init /r/sub
git init -b main /x
git push origin feature
git push origin feature --force
git push origin feature -f
git push origin +feature
git push --mirror origin
git push --delete origin feature
git push --prune origin
git -C . push origin :main
git -C . push -fv origin x
git push --repo=/r
git push -o ci.skip /r feat
git push -fooci /r feat
git push --dry-run origin x
git push origin main 2>&1 --force
git push $(git remote | head -1) --force
git push origin x && rsync --delete a/ b/
git -c a=b -C /r --no-pager push --force origin x
env git --bare -C /r -c a=b push --delete origin x
'git' push --force origin x
\git push --force
timeout 5 git -C /r reset --hard
timeout -k 5 10 git -C /r reset --hard
sudo -u x git -C /r status
git status; echo push --force
git rm -rf build/
git rm -r --cached build
git mv a b
git switch main
git revert HEAD
git am x.patch
git cherry-pick abc
git update-ref -d refs/heads/x
git submodule update --init
git gc
git hash-object -w f
git hash-object f
git apply x.diff
git apply --check x.diff
git notes add -m x
git notes list
git bisect start
git bisect log
git sparse-checkout set a
git sparse-checkout list
git symbolic-ref HEAD refs/heads/x
git config --global user.name x
git ls-files -z --deleted | xargs -0 git rm
EOF

# The reads that stay Bash: plumbing in every position the parser reaches.
check pass "plumbing behind sudo -u"       'sudo -u x git -C /r rev-parse HEAD'
check pass "plumbing behind time"          'time git rev-parse HEAD'
check pass "plumbing in a sh -c string"    "sh -c 'git -C /r rev-parse HEAD'"
check pass "plumbing through xargs"        'echo x | xargs git rev-parse'
check pass "symbolic-ref --short"          'git symbolic-ref --short HEAD'
check deny "symbolic-ref abbreviated delete" 'git symbolic-ref --del refs/remotes/origin/HEAD'
check deny "symbolic-ref bundled delete"   'git symbolic-ref -qd refs/remotes/origin/HEAD'
check pass "config --list with more flags" 'git config --list --show-origin'
check deny "config --get-regexp is not on the list" 'git config --get-regexp x'
check deny "plumbing with a substitution before it" 'git -C "$(pwd)" rev-parse HEAD'

# Fail-closed: input that is not a JSON object is denied, like a missing lib or no jq.
want() {  # want <deny|pass> <label> <stdin json>
  local got
  got=$(decision "$3")
  if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $2: want $1, got $got"; fi
}
want deny "not JSON"                       '{"tool_name": "Bash", "tool_input": {'
want deny "JSON array, not an object"      '[]'
want deny "whitespace-only input"          $'  \t '
want deny "empty input"                    ''
want pass "no command field"               '{"tool_name":"Bash","tool_input":{}}'
want deny "Monitor runs its command in a shell" '{"tool_name":"Monitor","tool_input":{"command":"git push"}}'
want deny "a control byte in the command"  "$(jq -nc --arg c $'echo \001; git status' '{tool_name: "Bash", tool_input: {command: $c}}')"

# Deny output shape: JSON, deny decision, exit 0.
out=$(bash_in 'git push' | HOME="$T" "$SH" "$T/hooks/git-mcp-redirect.sh" 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny"' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: deny output shape (rc=$rc): $out"
fi

# Fails closed without jq: a static deny, exit 0.
out=$(bash_in 'ls' | HOME="$T" PATH=/nonexistent "$SH" "$T/hooks/git-mcp-redirect.sh" 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: no-jq should deny (rc=$rc): $out"; fi

# A lib that is missing, empty or cut short must not let a call through: the hook exits 1, which the `|| exit 2` wiring
# blocks. An empty or cut file sources without error, so only the marker on its last line tells.
lib_case() {  # lib_case <label> <lib file> <content or MISSING or CUT>
  local dir="$T/libcase" rc out
  rm -rf "$dir"; mkdir -p "$dir/hooks"
  cp "$T/hooks/git-mcp-redirect.sh" "$dir/hooks/"
  cp -R "$T/hooks/lib" "$dir/hooks/lib"
  case "$3" in
    MISSING) rm "$dir/hooks/lib/$2" ;;
    EMPTY) : > "$dir/hooks/lib/$2" ;;
    CUT) head -n 5 "$T/hooks/lib/$2" > "$dir/hooks/lib/$2" ;;
  esac
  out=$(bash_in 'git push' | HOME="$T" "$SH" "$dir/hooks/git-mcp-redirect.sh" 2>/dev/null)
  rc=$?
  if [ "$rc" = 1 ] && [ -z "$out" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (rc=$rc): $out"; fi
}
for lib in hook-common.sh shell-parse.sh; do
  for how in MISSING EMPTY CUT; do lib_case "$lib $how exits 1" "$lib" "$how"; done
done

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
