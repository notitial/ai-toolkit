#!/bin/bash
# Tests for hooks/lib/shell-parse.sh (HOOK_LIB=<dir> tests another copy). Run: bash tools/shell-parse/test-shell-parse.sh
# A runner script sources the lib under HOOK_SHELL (default /bin/bash, 3.2) with HOME at a temp folder, defines the two
# callbacks to print what they get, and parses one command from the start folder /s. Each case lists the lines it
# expects, in order: a redirect target arrives when the parser reads it, a command when its segment ends.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="${HOOK_LIB:-$HERE/../../hooks/lib}"
GUARD="${HOOK:-$HERE/../../hooks/protected-paths-guard.sh}"
SH="${HOOK_SHELL:-/bin/bash}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/shell-parse-XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/hooks" "$T/home"
cp -R "$LIB" "$T/hooks/lib"
HR=$(cd -P "$T/home" && pwd -P)

cat >"$T/run.sh" <<RUN
HOOK=runner
HOME="$T/home"
. "$T/hooks/lib/hook-common.sh" </dev/null
. "$T/hooks/lib/shell-parse.sh"
on_command() { local o="C[\$CWD]" w; for w in "\$@"; do o="\$o <\$w>"; done; echo "\$o"; if [ "\$1" = xargs ]; then shift; sp_command "\$@"; fi; }
on_redirect() { echo "R[\$CWD] <\$1>"; }
CWD=/s
shell_parse "\$1"
RUN

PASS=0
FAIL=0
expect() {  # expect <label> <command> <expected line>...: the callbacks' output, one line each
  local label=$1 cmd=$2 want got
  shift 2
  want=$(printf '%s\n' "$@")
  got=$("$SH" "$T/run.sh" "$cmd" 2>&1)
  if [ "$got" = "$want" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n--- want\n%s\n--- got\n%s\n' "$label" "$want" "$got"; fi
}
check() {  # check <label> <0|1: did the condition hold>
  if [ "$2" = 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

# words and quotes
expect "plain words" 'echo a b' 'C[/s] <echo> <a> <b>'
expect "quotes and escapes" "echo \"a b\" 'c d' e\\ f" 'C[/s] <echo> <a b> <c d> <e f>'
expect "escaped quote in double quotes" 'echo "a\"b"' 'C[/s] <echo> <a"b>'
expect "ANSI-C quote kept as written" "echo \$'x\\ty'" 'C[/s] <echo> <x\ty>'
expect "# inside a word is not a comment" 'echo a#b' 'C[/s] <echo> <a#b>'
expect "comment to end of line" $'a # c; b\nd' 'C[/s] <a>' 'C[/s] <d>'

# assignments, wrappers, keywords
expect "assignments and wrappers skipped" 'FOO=1 env -u X BAR=2 sudo -u me nice -n 5 timeout 5 time -p command -p exec -a n rm -f x' 'C[/s] <rm> <-f> <x>'
expect "the verb keeps the path as written" '/usr/bin/env FOO=1 /bin/rm x' 'C[/s] </bin/rm> <x>'
expect "keywords skipped" 'if a; then b' 'C[/s] <a>' 'C[/s] <b>'
expect "negation and braces" '! c; { d; }' 'C[/s] <c>' 'C[/s] <d>'
expect "nohup" 'nohup a b' 'C[/s] <a> <b>'

# separators
expect "separators" $'a | b && c || d & e\nf' 'C[/s] <a>' 'C[/s] <b>' 'C[/s] <c>' 'C[/s] <d>' 'C[/s] <e>' 'C[/s] <f>'

# redirects and heredocs
expect "output redirects" 'a >o 2>&1 >>p >|q &>r 3>s k' 'R[/s] <o>' 'R[/s] <p>' 'R[/s] <q>' 'R[/s] <r>' 'R[/s] <s>' 'C[/s] <a> <k>'
expect "input redirects dropped" 'a <in <<<"h" k' 'C[/s] <a> <k>'
expect "heredoc body skipped" $'cat <<EOF\n> not a cmd\nEOF\nafter' 'C[/s] <cat>' 'C[/s] <after>'
expect "heredoc with tab strip and quoted delimiter" $'cat <<-"EOT"\n\tbody > x\n\tEOT\nafter' 'C[/s] <cat>' 'C[/s] <after>'

# the tracked folder
expect "cd absolute" 'cd /x/y; a' 'C[/x/y] <a>'
expect "cd relative and .." 'cd /x; cd y; cd ../z; a' 'C[/x/z] <a>'
expect "cd with no argument is home" 'cd; a' "C[$HR] <a>"
expect "cd ~/dir" 'cd ~/t; a' "C[$HR/t] <a>"
expect "cd \$HOME/dir" 'cd $HOME/u; a' "C[$HR/u] <a>"
expect "cd option skipped" 'cd -P /x; a' 'C[/x] <a>'
expect "cd to a variable: folder unknown" 'cd "$V"; a; cd /q; b' 'C[] <a>' 'C[/q] <b>'
expect "cd to a glob: folder unknown" 'cd /x/*; a' 'C[] <a>'
expect "cd - and ~user: folder unknown" 'cd /q; cd -; a; cd ~root; b' 'C[] <a>' 'C[] <b>'
expect "pushd and popd" 'pushd /y; a; popd; b' 'C[/y] <a>' 'C[] <b>'
expect "cd is not passed on" 'cd /x' ''
expect "subshell scopes cd" 'cd /x; a; (cd /z; b); c' 'C[/x] <a>' 'C[/z] <b>' 'C[/x] <c>'
expect "\$( ) and backticks scope cd" 'cd /x; echo $(cd /w; d); e `cd /v; f`; g' 'C[/x] <echo>' 'C[/w] <d>' 'C[/x] <e>' 'C[/v] <f>' 'C[/x] <g>'
expect "braces do not scope cd" '{ cd /q; a; }; b' 'C[/q] <a>' 'C[/q] <b>'

# nested strings
expect "bash -c" 'bash -c "cd /n; a > f"; b' 'R[/n] <f>' 'C[/n] <a>' 'C[/s] <bash> <-c> <cd /n; a > f>' 'C[/s] <b>'
expect "sh -ec and bash -lc" "sh -ec \"a\"; bash -lc 'b'" 'C[/s] <a>' 'C[/s] <sh> <-ec> <a>' 'C[/s] <b>' 'C[/s] <bash> <-lc> <b>'
expect "eval" 'eval "x; y > z" w' 'C[/s] <x>' 'R[/s] <z>' 'C[/s] <y> <w>' 'C[/s] <eval> <x; y > z> <w>'
expect "three levels are read, the fourth is not" 'bash -c "bash -c \"bash -c \\\"bash -c a\\\"\""' \
  'C[/s] <bash> <-c> <a>' 'C[/s] <bash> <-c> <bash -c a>' 'C[/s] <bash> <-c> <bash -c "bash -c a">' 'C[/s] <bash> <-c> <bash -c "bash -c \"bash -c a\"">'

expect "eval restores the folder" 'eval "cd /n"; a' 'C[/s] <eval> <cd /n>' 'C[/s] <a>'

# sp_command: the runner's on_command hands the words behind xargs to it
expect "xargs: wrappers skipped" 'xargs env FOO=1 rm x' 'C[/s] <xargs> <env> <FOO=1> <rm> <x>' 'C[/s] <rm> <x>'
expect "xargs cd moves the folder" 'xargs cd /x; a' 'C[/s] <xargs> <cd> </x>' 'C[/x] <a>'
expect "xargs bash -c is read" 'xargs bash -c "a > f"' 'C[/s] <xargs> <bash> <-c> <a > f>' 'R[/s] <f>' 'C[/s] <a>' 'C[/s] <bash> <-c> <a > f>'

# refusals
for c in $'a\001b' $'a\033b' $'a\177b'; do
  out=$("$SH" "$T/run.sh" "$c" 2>&1)
  check "control byte denied ($(printf '%s' "$c" | od -An -c | tr -d ' '))" "$([ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ] && echo 1 || echo 0)"
done
out=$(sed 's/^on_redirect.*//' "$T/run.sh" >"$T/norun.sh"; "$SH" "$T/norun.sh" 'a' 2>&1)
check "a hook without on_redirect is denied" "$([ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ] && echo 1 || echo 0)"
out=$("$SH" "$T/run.sh" $'a\tb\nc' 2>&1)
check "tab and newline are not refused" "$([ "$(printf '%s\n' "$out" | head -1)" = 'C[/s] <a> <b>' ] && echo 1 || echo 0)"

# fail-closed: sourcing succeeds on an empty or cut-short file, so each lib ends by setting a marker and the guard's
# source line checks it. A guard with a lib file missing, empty or cut short (its last line dropped) exits 1, which the
# `|| exit 2` wiring blocks, for a Bash, an Edit and a git MCP call alike.
GIN='{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}'
EIN='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"},"cwd":"/tmp"}'
MIN='{"tool_name":"mcp__git-mcp__git_add","tool_input":{"path":"/tmp/x"},"cwd":"/tmp"}'
rc_of() {  # rc_of <hook file> <input>: the hook's exit code
  printf '%s' "$2" | HOME="$T/home" "$SH" "$1" >/dev/null 2>&1
  echo $?
}
damage() {  # damage <lib name> <ok|missing|empty|cut>: lay out $T/part with that lib file in that state
  rm -r "$T/part" 2>/dev/null
  mkdir -p "$T/part/lib"
  cp "$GUARD" "${GUARD%/*}/destructive-blocker.sh" "$T/part/"
  cp "$T/hooks/lib/hook-common.sh" "$T/hooks/lib/shell-parse.sh" "$T/part/lib/"
  case "$2" in
    missing) rm "$T/part/lib/$1.sh" ;;
    empty) : >"$T/part/lib/$1.sh" ;;
    cut) sed '$d' "$T/hooks/lib/$1.sh" >"$T/part/lib/$1.sh" ;;
  esac
}
damage shell-parse ok
check "guard with both lib files exits 0" "$([ "$(rc_of "$T/part/protected-paths-guard.sh" "$GIN")" = 0 ] && echo 1 || echo 0)"
for lib in hook-common shell-parse; do
  for state in missing empty cut; do
    damage $lib $state
    for in in "$GIN" "$EIN" "$MIN"; do
      check "guard with $state lib/$lib.sh exits 1 ($(printf '%s' "$in" | jq -r .tool_name))" "$([ "$(rc_of "$T/part/protected-paths-guard.sh" "$in")" = 1 ] && echo 1 || echo 0)"
    done
  done
done
for state in empty cut; do
  damage hook-common $state
  check "destructive-blocker with $state lib/hook-common.sh exits 1" "$([ "$(rc_of "$T/part/destructive-blocker.sh" "$GIN")" = 1 ] && echo 1 || echo 0)"
done

echo "shell-parse: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
