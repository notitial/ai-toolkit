#!/bin/bash
# Tests for hooks/destructive-blocker.sh (HOOK=<path> tests another copy). Run: bash tools/destructive-blocker/test-destructive-blocker.sh
# The hook and its sibling audit-logger.sh run from a temp copy under HOOK_SHELL (default /bin/bash, 3.2) with HOME
# pointed at a temp folder and a clean environment (env -i), so a deny never writes to the live audit log and the
# caller's CLAUDE_CODE_ENTRYPOINT cannot change a result.
# Each case expects deny, ask or pass (no output). Nothing here runs the commands under test; they are only text.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../../hooks/destructive-blocker.sh}"
LOGGER="$HERE/../../hooks/audit-logger.sh"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
SH="${HOOK_SHELL:-/bin/bash}"
T=$(mktemp -d "${TMPDIR:-/tmp}/destructive-blocker-XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/hooks" "$T/work"
cp "$HOOK" "$T/hooks/destructive-blocker.sh"
cp "$LOGGER" "$T/hooks/audit-logger.sh"
PASS=0
FAIL=0

decision() {  # decision <stdin json> [VAR=value ...]
  local in=$1 out
  shift
  out=$(printf '%s' "$in" | env -i PATH="$PATH" HOME="$T" "$@" "$SH" "$T/hooks/destructive-blocker.sh" 2>/dev/null)
  [ -z "$out" ] && { echo pass; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed
}
bash_in() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }
result() {  # result <want> <got> <label>
  if [ "$2" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $3: want $1, got $2"; fi
}
check() {  # check <deny|ask|pass> <label> <command> [VAR=value ...]
  local want=$1 label=$2 cmd=$3
  shift 3
  result "$want" "$(decision "$(bash_in "$cmd")" "$@")" "$label"
}
raw() { result "$1" "$(decision "$3")" "$2"; }  # raw <deny|ask|pass> <label> <stdin>

# The literal patterns
check deny "rm -rf"                    'rm -rf /some/dir'
check deny "rm -fr"                    'rm -fr build '
check deny "drop table"                'psql -c "DROP TABLE users"'
check deny "drop table lower case"     'psql -c "drop table users"'
check deny "drop database"             'psql -c "DROP DATABASE app"'
check deny "delete without where"      'psql -c "DELETE FROM users;"'
check deny "delete at end of command"  'sqlite3 a.db "DELETE FROM users"'
check deny "delete, then a db argument" 'psql -c "DELETE FROM users" app_db'
check deny "delete, then a chain"      'sqlite3 a.db "DELETE FROM users" && echo done'
check pass "delete with where"         'psql -c "DELETE FROM users WHERE id = 3" app_db'
check pass "delete with where, quoted value" "psql -c \"DELETE FROM users WHERE name = 'x'\""
check pass "commit message naming a reset" 'git commit -m "docs: explain why git reset --hard is blocked"'
check pass "search for a force push"   'grep -rn "git push --force" docs/'
check pass "untrack a folder"          'git rm -rf --cached build/'
check deny "git rm -rf of a folder"    'git rm -rf build/'
check pass "delete with a quoted table" "psql -c 'DELETE FROM \"User\" WHERE id = 1'"
check deny "delete from a quoted table" "psql -c 'DELETE FROM \"User\"'"
check deny "delete after another statement" "mysql -e 'SELECT 1; DELETE FROM users' app"
check deny "delete on a heredoc line"  $'psql app <<SQL\nDELETE FROM users;\nSQL'
check pass "prose naming a delete"     'echo "rows delete from the cache"'
check pass "PR body naming a delete"   'gh pr create --title "fix: retries" --body "Failed jobs delete from the queue after 3 tries"'
check pass "commit message naming branch -D" 'git commit -m "explain why git branch -D is blocked"'
check pass "search for branch -D"      'grep -rn "git branch -D" docs/'
check deny "commit, then a hard reset" 'git commit -m "wip" && git reset --hard HEAD~1'
check deny "commit, then rm -rf"       "git commit -m 'x' && rm -rf build "
check deny "truncate table"            'psql -c "TRUNCATE TABLE users"'
check deny "force push"                'git push origin feature --force'
check deny "short force push"          'git push origin feature -f'
check deny "hard reset"                'git reset --hard HEAD~1'
check deny "force clean"               'git clean -fd'
check deny "discard all changes"       'git checkout -- .'
check deny "discard all, no --"        'git checkout .'
check deny "restore all"               'git restore .'
check deny "discard all in a chain"    'git checkout . && echo done'
check pass "restore one dotfile"       'git checkout -- .gitignore'
check pass "restore a dot path"        'git checkout -- ./src/app.ts'
check pass "restore a dot folder"      'git restore .github/workflows/ci.yml'
check deny "force delete branch"       'git branch -D old'
check pass "branch -d, a merged-only delete" 'git branch -d x'
check pass "branch -d in a chain"      'git fetch && git branch -d topic'
check deny "branch -D in a chain"      'git fetch && git branch -D topic'
check deny "branch -d with -f"         'git branch -d -f topic'
check deny "disk overwrite zero"       'dd if=/dev/zero of=/dev/disk2'
check deny "disk overwrite urandom"    'dd if=/dev/urandom of=/dev/disk2'
check deny "image onto a disk"         'dd if=image.iso of=/dev/sda bs=4M'
check pass "random bytes to stdout"    'dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64'
check pass "zeroed test file"          'dd if=/dev/zero of=test.img bs=1M count=10'
check pass "dd to /dev/null"           'dd if=big.bin of=/dev/null bs=1M'
check deny "mkfs"                      'mkfs.ext4 /dev/sdb1'
check deny "recursive 777"             'chmod -R 777 /srv'

# Force and delete pushes the literal patterns miss: global options, prefixes, refspecs, sh -c
check deny "path-prefixed git force"   '/usr/bin/git push --force-with-lease origin x'
check deny "quoted git force"          "'git' push --force origin x"
check deny "git -C force push"         'git -C /repo push --force origin x'
check deny "-c, -C then --no-pager"    'git -c a=b -C /r --no-pager push --force origin x'
check deny "plus refspec"              'git push origin +feature'
check deny "mirror push"               'git push --mirror origin'
check deny "delete push"               'git push --delete origin feature'
check deny "prune push"                'git push --prune origin'
check deny "colon-refspec delete"      'git -C . push origin :main'
check deny "bundled short force"       'git -C . push -fv origin x'
check deny "force push after chain"    'cd /repo && git -C . push -f origin x'
check deny "sh -c git -C force push"   "sh -c 'git -C /r push --force'"
check deny "sh -c plus refspec"        "sh -c 'git push origin +main'"
check deny "env git, delete push"      'env git --bare -C /r -c a=b push --delete origin x'
check deny "backslash git, force"      '\git push --force'
check deny "force in a subshell"       '(cd x && git -C . push --force)'
check pass "plain push"                'git push origin feature'
check pass "git -C plain push"         'git -C /r push origin feature'
check pass "sh -c plain push"          "sh -c 'git -C /r push origin feature'"
check pass "a source:destination refspec" 'git push origin HEAD:refs/heads/x'
check pass "--dry-run is not --delete" 'git -C . push --dry-run origin x'
check pass "--follow-tags is not --force" 'git -C . push --follow-tags origin main'
check pass "push then unrelated delete" 'git push origin x && rsync --delete a/ b/'
check pass "force flag after a separator" 'git status; echo push --force'
check pass "push, then a later --force"  'git push origin main && docker compose up -d --force-recreate'
check pass "push, then a later -f"       'git push -u origin feat; ls -f'
check deny "force after a redirect"     'git push origin main 2>&1 --force'
check deny "-f after a redirect"        'git push origin main 2>&1 -f'
check deny "force after a substitution" 'git push $(git remote | head -1) --force'
check pass "commit message with push"  'git commit -m "+1 add push support"'

# reset --hard, clean -f and branch -D behind global options, sh -c, or flags in any order
check deny "sh -c git -C reset --hard"  "sh -c 'git -C /r reset --hard'"
check deny "reset, --hard after the ref" 'git reset HEAD~3 --hard'
check deny "reset --hard behind -c"     'git -c core.x=y reset --hard'
check deny "reset --hard, prefixed -C"  '/usr/bin/git -C /x reset --hard'
check deny "clean -d -f"                'git clean -d -f'
check deny "clean --force"              'git clean --force'
check deny "git -C clean -fd"           'git -C /x clean -fd'
check deny "bash -lc git clean -fdx"    'bash -lc "git -C /r clean -fdx"'
check deny "git -C branch -D"           'git -C /x branch -D topic'
check deny "branch --delete --force"    'git branch --delete --force topic'
check deny "if git reset --hard"        'if git -C /r reset --hard; then :; fi'
check deny "timeout git reset --hard"   'timeout 5 git -C /r reset --hard'
check deny "sudo -u USER rm -r -f"       'sudo -u www-data rm -r -f /var/www/cache'
check deny "sudo -g GROUP rm -r -f"      'sudo -g staff rm -r -f build'
check deny "timeout -s KILL 30 rm -r -f" 'timeout -s KILL 30 rm -r -f dir'
check deny "timeout -k 5 10 git reset"   'timeout -k 5 10 git -C /r reset --hard'
check deny "sudo -u, then timeout -s"    'sudo -u x timeout -s TERM 5 rm -r -f dir'
check pass "sudo -u USER rm one file"    'sudo -u www-data rm cache.tmp'
check pass "timeout -s KILL 30 ls"       'timeout -s KILL 30 ls -la'
check pass "sudo -u USER git status"     'sudo -u x git -C /r status'
check pass "reset --soft"               'git reset --soft HEAD~1'
check pass "git -C reset --mixed"       'git -C /x reset --mixed HEAD~1'
check pass "clean -n"                   'git clean -n'
check pass "git -C clean -n -d"         'git -C /x clean -n -d'
check pass "git -C branch -d"           'git -C /x branch -d topic'
check pass "branch -f moves, no delete" 'git branch -f topic HEAD'
check pass "commit message naming reset --hard" "git commit -m 'reset --hard docs'"
check pass "log grep naming clean -f"   "git log --grep 'clean -f'"

# Recursive forced rm in any flag order, and through a wrapper
check deny "rm -f -r"                  'rm -f -r build'
check deny "rm -r -f"                  'rm -r -f build'
check deny "rm -R -f"                  'rm -R -f build'
check deny "rm long flags"             'rm --force --recursive build'
check deny "rm flags after the path"   'rm build -r -f'
check deny "rm -rv -f cluster"         'rm -rv -f build'
check deny "rm by absolute path"       '/bin/rm -r -f build'
check deny "backslash rm"              '\rm -r -f build'
check deny "quoted rm, flags apart"    "'rm' -r -f build"
check deny "sudo rm -rf"               'sudo rm -rf build'
check deny "env rm -r -f"              'env X=1 rm -r -f build'
check deny "command rm"                'command rm -r -f build'
check deny "xargs rm -rf"              'ls | xargs rm -rf'
check deny "xargs rm -r -f"            'ls | xargs rm -r -f'
check deny "rm in a later segment"     'cd x && rm -r -f build'
check deny "if rm -r -f"               'if rm -r -f build; then :; fi'
check deny "rm in a subshell"          '(rm -r -f build)'
check deny "rm in command substitution" 'x=$(rm -r -f build)'
check deny "sh -c quoted rm flags"     "sh -c 'rm -r -f build'"
check deny "bash -lc long flags"       'bash -lc "rm --recursive --force /data"'
check deny "docker exec sh -c rm"      "docker exec c sh -c 'rm -r -f /x'"
check deny "su -c rm"                  "su -c 'rm -R -f x'"
check deny "find -exec sh -c rm"       "find . -exec sh -c 'rm -r -f \"\$0\"' {} \;"
check deny "sh -c, rm after a semicolon" "bash -c 'echo hi; rm -r -f x'"
check deny "eval, rm after a semicolon" "eval 'true; rm -r -f x'"
check deny "rm after a quoted semicolon" 'echo "a;b"; rm -r -f x'
check pass "rm a file"                 'rm file.txt'
check pass "rm -f a file"              'rm -f build.log'
check pass "rm -f -- absolute"         'rm -f -- /tmp/x'
check pass "rm -r alone"               'rm -r -v build'
check pass "force flag on another cmd" 'rm -r build && git commit -f x'
check pass "recursive flag on another" 'rm build.log; cp -r a b'
check pass "grep for rm -rf"           'grep -rn "rm -rf" hooks/'
check pass "rg for DROP TABLE"         'rg -n "DROP TABLE" db/migrations/'
check pass "rg for truncate table"     "rg -il 'truncate table' sql/"
check pass "git grep for DROP DATABASE" 'git grep -n "DROP DATABASE"'
check deny "search, then a real drop"  'rg -n "x" db/; psql -c "DROP TABLE users"'
check pass "grep alternation with rm -rf" 'grep -nE "sudo|rm -rf" hooks/'
check pass "rg alternation rm flags"   "rg -n \"rm -r -f|rm -fr\" hooks/"
check pass "jq arg holding rm -r -f"   "jq --arg c 'rm -r -f x' ."
check pass "echo naming rm -r -f"      'echo "never run rm -r -f"'
check pass "git rm --cached"           'git rm -r --cached build'
check pass "docker rm -f"              'docker rm -f web'
check pass "npm rm"                    'npm rm left-pad'

# Python one-liners and heredocs that delete files
check deny "python -c rmtree"          'python3 -c "import shutil; shutil.rmtree(\"x\")"'
check deny "python -c os.remove"       "python -c 'import os; os.remove(\"f\")'"
check deny "python -Bc unlink"         "python3 -Bc 'import pathlib; pathlib.Path(\"f\").unlink()'"
check deny "python -I -c rmtree"       "python3 -I -c 'import shutil; shutil.rmtree(\"x\")'"
check deny "python heredoc rmtree"     $'python3 - <<\'EOF\'\nimport shutil\nshutil.rmtree("x")\nEOF'
check pass "python -c print"           'python3 -c "print(1)"'
check pass "python script"             'python3 tools/run.py'
check pass "python -m pytest"          'python3 -m pytest tests'
check pass "python heredoc, no delete" $'python3 - <<\'EOF\'\nprint(1)\nEOF'

# The soft entries: ask in an interactive session, deny where nobody can answer
check ask  "rm -f /abs, interactive cli"       'rm -f /tmp/x'        CLAUDE_CODE_ENTRYPOINT=cli
check ask  "rm -f /abs, vscode"                'rm -f /tmp/x'        CLAUDE_CODE_ENTRYPOINT=claude-vscode
check ask  "rm -f /abs, desktop"               'rm -f /tmp/x'        CLAUDE_CODE_ENTRYPOINT=claude-desktop
check ask  "truncate /abs, interactive cli"    ': > /etc/hosts'      CLAUDE_CODE_ENTRYPOINT=cli
check deny "rm -f /abs, headless sdk-cli"      'rm -f /tmp/x'        CLAUDE_CODE_ENTRYPOINT=sdk-cli
check deny "rm -f /abs, entrypoint unset"      'rm -f /tmp/x'
check deny "rm -f /abs, unknown entrypoint"    'rm -f /tmp/x'        CLAUDE_CODE_ENTRYPOINT=mystery
check deny "truncate /abs, entrypoint unset"   ': > /etc/hosts'
check deny "soft plus hard in one command"     'rm -f /tmp/x; rm -rf y'  CLAUDE_CODE_ENTRYPOINT=cli
check deny "hard first, soft later"            'git reset --hard && rm -f /tmp/x'  CLAUDE_CODE_ENTRYPOINT=cli

# Bulk deletes: find -delete, find -exec rm, xargs rm
check ask  "find -delete, cli"         'find . -name "*.tmp" -delete'            CLAUDE_CODE_ENTRYPOINT=cli
check ask  "find -exec rm, cli"        'find /tmp/x -type f -exec rm {} \;'      CLAUDE_CODE_ENTRYPOINT=cli
check ask  "find -exec /bin/rm, cli"   'find . -exec /bin/rm -- {} +'            CLAUDE_CODE_ENTRYPOINT=cli
check ask  "find -execdir rm, cli"     'find . -execdir rm {} +'                 CLAUDE_CODE_ENTRYPOINT=cli
check ask  "xargs rm, cli"             'ls | xargs rm'                           CLAUDE_CODE_ENTRYPOINT=cli
check ask  "xargs -0 rm, cli"          'find . -print0 | xargs -0 rm'            CLAUDE_CODE_ENTRYPOINT=cli
check ask  "xargs -n 1 rm, cli"        'ls | xargs -n 1 rm'                      CLAUDE_CODE_ENTRYPOINT=cli
check ask  "xargs -I {} rm, cli"       'ls | xargs -I {} rm {}'                  CLAUDE_CODE_ENTRYPOINT=cli
check ask  "xargs sudo rm, cli"        'ls | xargs sudo rm'                      CLAUDE_CODE_ENTRYPOINT=cli
check ask  "find -delete behind sudo"  'sudo find . -delete'                     CLAUDE_CODE_ENTRYPOINT=cli
check ask  "sh -c with find -delete"   "sh -c 'find . -delete'"                  CLAUDE_CODE_ENTRYPOINT=cli
check deny "find -delete, headless"    'find . -name "*.tmp" -delete'            CLAUDE_CODE_ENTRYPOINT=sdk-cli
check deny "find -delete, unset"       'find . -name "*.tmp" -delete'
check deny "find -delete beside rm -rf" 'find . -delete; rm -rf x'               CLAUDE_CODE_ENTRYPOINT=cli
check pass "find by name"              'find . -name "*.tmp"'
check pass "find -exec grep"           'find . -exec grep foo {} +'
check pass "find name ending -delete"  'find . -name build-delete'
check pass "find -print0 to xargs grep" 'find . -print0 | xargs -0 grep foo'
check pass "xargs echo"                'ls | xargs echo rm'
check pass "xargs -0 git rm"           'git ls-files -z --deleted | xargs -0 git rm'  CLAUDE_CODE_ENTRYPOINT=cli
check pass "xargs -r docker rm -f"     'docker ps -aq | xargs -r docker rm -f'        CLAUDE_CODE_ENTRYPOINT=cli
check pass "commit message naming find -delete" 'git commit -m "fix: ask on find -delete"'  CLAUDE_CODE_ENTRYPOINT=cli
check pass "rg for xargs rm"           'rg "xargs rm" hooks/'                    CLAUDE_CODE_ENTRYPOINT=cli

# Ordinary commands and odd input
check pass "ls"                        'ls -la'
check pass "git status"                'git status'
check pass "delete with where"         'psql -c "DELETE FROM users WHERE id = 1;"'
check pass "select"                    'psql -c "SELECT * FROM users"'
check pass "chmod without -R"          'chmod 777 file'
check pass "dd to a file"              'dd if=a of=b'
check pass "a glob is not expanded"    'ls *'
check pass "empty command"             ''
raw pass "no command field"            '{"tool_name":"Bash","tool_input":{}}'
raw pass "non-Bash tool, no command"   '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
raw deny "malformed input"             'not json'
raw deny "JSON that is not an object"  '["ls"]'
raw pass "empty input"                 ''
raw pass "whitespace-only input"       ' '

# Deny output shape: JSON, deny decision, the reason names the problem.
out=$(bash_in 'git reset --hard' | env -i PATH="$PATH" HOME="$T" "$SH" "$T/hooks/destructive-blocker.sh" 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny" and (.permissionDecisionReason | contains("Git hard reset"))' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: deny output shape (rc=$rc): $out"
fi

# Fail closed without jq: static deny JSON, exit 0.
out=$(printf '%s' "$(bash_in 'ls')" | env -i PATH=/nonexistent HOME="$T" "$SH" "$T/hooks/destructive-blocker.sh" 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: no jq should deny (rc=$rc): $out"; fi

# A deny and an ask are recorded in the audit log under the input's cwd, tagged with this hook; an allowed call
# writes nothing.
audit_case() {  # audit_case <label> <command> <jq test on the log> [VAR=value ...]
  local label=$1 cmd=$2 test=$3 log
  shift 3
  rm -rf "$T/work/.archive"
  jq -nc --arg d "$T/work" --arg c "$cmd" '{tool_name: "Bash", cwd: $d, session_id: "s1", tool_input: {command: $c}}' \
    | env -i PATH="$PATH" HOME="$T" "$@" "$SH" "$T/hooks/destructive-blocker.sh" >/dev/null 2>&1
  log=$(ls "$T"/work/.archive/audit/audit-*.log 2>/dev/null | head -1)
  if [ -n "$log" ] && jq -e "$test" "$log" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $label"; fi
}
audit_case "a deny is logged" 'git clean -fd' 'select(.event == "deny" and .hook == "destructive-blocker" and .reason == "Git force clean")'
audit_case "an ask is logged" 'rm -f /tmp/x' 'select(.event == "ask" and .hook == "destructive-blocker")' CLAUDE_CODE_ENTRYPOINT=cli
rm -rf "$T/work/.archive"
jq -nc --arg d "$T/work" '{tool_name: "Bash", cwd: $d, tool_input: {command: "ls"}}' \
  | env -i PATH="$PATH" HOME="$T" "$SH" "$T/hooks/destructive-blocker.sh" >/dev/null 2>&1
if [ ! -e "$T/work/.archive" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: an allowed call wrote an audit record"; fi

echo "destructive-blocker: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
