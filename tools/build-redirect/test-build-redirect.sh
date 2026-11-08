#!/bin/bash
# Tests for hooks/build-redirect.sh (HOOK=<path> tests another copy). Run: bash tools/build-redirect/test-build-redirect.sh
# The hook and its sibling audit-logger.sh run from a temp copy under HOOK_SHELL (default /bin/bash, 3.2) with HOME
# pointed at a temp folder, so a deny never writes to the live audit log. Each case expects deny or pass (no output);
# the commands under test are only text, nothing here runs them. $T/work holds a .build-kit.json (opted in),
# $T/other does not. Without audit-logger.sh beside the hook, the audit case is skipped and says so.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../../hooks/build-redirect.sh}"
LOGGER="${LOGGER:-$(dirname "$HOOK")/audit-logger.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
SH="${HOOK_SHELL:-/bin/bash}"
T=$(mktemp -d "${TMPDIR:-/tmp}/build-redirect-XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/hooks" "$T/work/sub/dir" "$T/other"
echo '{}' > "$T/work/.build-kit.json"
cp "$HOOK" "$T/hooks/build-redirect.sh"
HAVE_LOGGER=0
[ -f "$LOGGER" ] && cp "$LOGGER" "$T/hooks/audit-logger.sh" && HAVE_LOGGER=1
PASS=0
FAIL=0

run() {  # run <stdin json>: prints the hook's stdout
  printf '%s' "$1" | env -u CLAUDE_PROJECT_DIR HOME="$T" "$SH" "$T/hooks/build-redirect.sh" 2>/dev/null
}
bash_in() {  # bash_in <command> [cwd]
  jq -nc --arg c "$1" --arg d "${2:-$T/work}" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}'
}
decision() {
  local out
  out=$(run "$1")
  [ -z "$out" ] && { echo pass; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed
}
check() {  # check <deny|pass> <label> <command> [cwd]
  local got
  got=$(decision "$(bash_in "$3" "${4:-}")")
  if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $2: want $1, got $got"; fi
}
reason_has() {  # reason_has <label> <command> <substring of the deny reason>
  local out
  out=$(run "$(bash_in "$2")")
  if printf '%s' "$out" | jq -e --arg s "$3" '.hookSpecificOutput.permissionDecisionReason | contains($s)' >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: reason lacks '$3': $out"; fi
}

# xcodebuild: builds and tests are denied, questions pass.
check deny "xcodebuild build"              'xcodebuild -scheme App build'
check deny "xcodebuild default action"     'xcodebuild -scheme App -configuration Debug'
check deny "xcodebuild test"               'xcodebuild test -scheme App -destination "platform=iOS Simulator,name=iPhone 16"'
check deny "xcodebuild build-for-testing"  'xcodebuild build-for-testing -scheme App'
check deny "xcodebuild test-without-building" 'xcodebuild test-without-building -scheme App'
check deny "xcodebuild archive"            'xcodebuild archive -scheme App'
check deny "xcodebuild clean build"        'xcodebuild clean build -scheme App'
check deny "xcrun xcodebuild"              'xcrun xcodebuild -scheme App build'
check deny "path-qualified xcodebuild"     '/usr/bin/xcodebuild -scheme App build'
check deny "query flag with a build action" 'xcodebuild -list build'
check pass "xcodebuild -version"           'xcodebuild -version'
check pass "xcodebuild -list"              'xcodebuild -list -project App.xcodeproj'
check pass "xcodebuild -showsdks"          'xcodebuild -showsdks'
check pass "xcodebuild -showBuildSettings" 'xcodebuild -scheme App -showBuildSettings'
check pass "xcodebuild -showdestinations"  'xcodebuild -scheme App -showdestinations'
check deny "xcodebuild clean install"      'xcodebuild clean install -scheme App'
check deny "xcodebuild docbuild"           'xcodebuild docbuild -scheme App'
check pass "xcodebuild resolve packages"   'xcodebuild -resolvePackageDependencies -project App.xcodeproj'
check pass "xcodebuild exportArchive"      'xcodebuild -exportArchive -archivePath a -exportPath b'
check pass "xcodebuild clean alone"        'xcodebuild clean -scheme App'
check pass "xcrun simctl list"             'xcrun simctl list devices'
check pass "xcrun simctl boot"             'xcrun simctl boot 1234'

# gradlew: build-like tasks are denied, questions pass.
for task in assembleDebug build bundleRelease compileDebugKotlin test testDebugUnitTest check lint lintDebug detekt ktlintCheck connectedDebugAndroidTest verifyPaparazziDebug :app:assembleDebug; do
  check deny "gradlew $task"               "./gradlew $task"
done
check deny "gradlew with options"          './gradlew --no-daemon -p apps/android assembleDebug --stacktrace'
check deny "gradlew path"                  'apps/android/gradlew testDebugUnitTest'
check deny "bare gradlew"                  'gradlew assembleRelease'
check deny "sh gradlew"                    'sh ./gradlew assembleDebug'
check deny "excluded task does not hide the build" './gradlew assembleDebug -x test'
for task in packageRelease spotlessCheck jvmTest allTests jacocoTestReport; do
  check deny "gradlew $task"               "./gradlew $task"
done
check deny "gradlew over a continuation line" $'./gradlew \\\n  assembleDebug'
check pass "gradlew installDebug (deploys, not a build)" './gradlew installDebug'
check pass "gradlew publish"             './gradlew publishToMavenLocal'
check pass "gradlew tasks"                 './gradlew tasks'
check pass "gradlew --version"             './gradlew --version'
check pass "gradlew help"                  './gradlew help'
check pass "gradlew clean"                 './gradlew clean'
check pass "gradlew -x value is not a task" './gradlew clean -x test'
check pass "gradlew -p value is not a task" './gradlew -p testapp tasks'
check pass "gradlew --console value"       './gradlew --console plain tasks'

# swiftlint: lint and autocorrect are denied, information passes.
check deny "swiftlint lint"                'swiftlint lint --strict'
check deny "swiftlint bare"                'swiftlint'
check pass "swiftlint --fix is not a lint" 'swiftlint --fix'
check pass "swiftlint autocorrect"         'swiftlint autocorrect'
check deny "swiftlint analyze"             'swiftlint analyze'
check deny "swiftlint with options first"  'swiftlint --config .swiftlint.yml lint'
check pass "swiftlint version"             'swiftlint version'
check pass "swiftlint --version"           'swiftlint --version'
check pass "swiftlint rules"               'swiftlint rules'

# Command position.
check deny "after &&"                      'cd apps/ios && xcodebuild -scheme App build'
check deny "after ;"                       'ls; ./gradlew assembleDebug'
check deny "after a pipe"                  'echo x | swiftlint lint'
check deny "in a subshell"                 '(./gradlew test)'
check deny "second line"                   $'ls\nxcodebuild -scheme App build'
check deny "assignment prefix"             'FOO=1 xcodebuild -scheme App build'
check deny "env wrapper"                   'env ./gradlew assembleDebug'
check deny "timeout wrapper"               'timeout 600 xcodebuild -scheme App test'
check deny "in a command substitution"     'echo $(./gradlew assembleDebug)'
check deny "substitution in the arguments" 'xcodebuild -scheme "$(cat scheme.txt)" build'
check deny "backtick in the arguments"     'swiftlint lint `pwd`'
check deny "quoted tool"                   '"xcodebuild" -scheme App build'
check deny "after if"                      'if xcodebuild -scheme App build; then echo ok; fi'
check deny "after do"                      'for s in A B; do xcodebuild -scheme "$s" build; done'
check deny "after then"                    'if true; then ./gradlew assembleDebug; fi'
check deny "after a negation"              '! swiftlint lint'
check deny "path-qualified env"            '/usr/bin/env xcodebuild -scheme App build'
check deny "path-qualified xcrun"          '/usr/bin/xcrun xcodebuild -scheme App build'
check deny "backslash-escaped tool"        '\xcodebuild -scheme App build'
check deny "tool between two quoted strings" 'echo "a" && ./gradlew assembleDebug && echo "b"'
check deny "tool between quoted strings: cd" 'cd "apps/ios" && xcodebuild -scheme "App" test'
check deny "tool between single-quoted strings" "echo 'x'; xcodebuild build; echo 'y'"
check deny "apostrophe in a double-quoted string" "echo \"don't\" && ./gradlew test; echo 'x'"
check deny "tool after a quoted string with a separator" 'echo "a|b" && xcodebuild -scheme App build'
check deny "escaped quote does not end the string" 'echo "a\"|b" && ./gradlew assembleDebug'
check pass "separators inside a quoted grep pattern" 'grep -rn "gradlew|xcodebuild" .github/'
check pass "separators inside single quotes" "grep -rn 'xcodebuild; ./gradlew' ."
check pass "parentheses inside a quoted message" 'echo "fix: drop (xcodebuild build) retry"'
check pass "keyword inside a quoted string" 'grep -n "if xcodebuild build" ci.sh'
check pass "tool name in an echo string"   'echo "run xcodebuild build later"'
check pass "tool name as an argument"      'grep xcodebuild README.md'
check pass "a log file named after it"     'cat xcodebuild.log'
check pass "a path containing the name"    'ls docs/gradlew-notes'
check pass "the kit's own CLI"             'python3 tools/build-kit/build.py ios build'
check pass "multi-line commit body line"   $'git commit -m "fix hook\n\nxcodebuild -scheme App build now fails"'
check pass "multi-line single-quoted body" $'git commit -m \'fix hook\n\nswiftlint lint is slow\''
check pass "multi-line string with a separator" $'git commit -m "fix\n\n./gradlew test; xcodebuild build"'
check pass "unquoted heredoc body"         $'cat > notes.md <<EOF\nswiftlint lint\nxcodebuild -scheme App build\nEOF'
check pass "quoted heredoc body"           $'cat > notes.md <<\'EOF\'\nswiftlint lint\ndon\'t run it\nEOF'
check pass "dash heredoc with tabbed end"  $'cat <<-EOF\n\tswiftlint lint\n\tEOF'
check pass "two heredocs on one line"      $'cat <<A; cat <<B\nxcodebuild build\nA\n./gradlew test\nB'
check pass "tool in a comment"             $'ls # xcodebuild -scheme App build\nls'
check pass "tool on a comment line"        $'# xcodebuild -scheme App build\nls'
check deny "after a closed multi-line string" $'git commit -m "a\nb"\nxcodebuild -scheme App build'
check deny "after a closed multi-line single-quoted string" $'git commit -m \'a\nb\'\nswiftlint lint'
check deny "same line after a multi-line string" $'echo "a\nb" && ./gradlew test'
check deny "after a heredoc"               $'cat <<EOF\nnotes\nEOF\nxcodebuild -scheme App build'
check deny "after a quoted heredoc with an apostrophe" $'cat <<\'EOF\'\ndon\'t\nEOF\nswiftlint lint'
check deny "after a dash heredoc"          $'cat <<-EOF\n\tnotes\n\tEOF\n./gradlew assembleDebug'
check deny "after two heredocs"            $'cat <<A; cat <<B\nx\nA\ny\nB\nxcodebuild build'
check deny "on the heredoc line"           $'cat <<EOF && ./gradlew test\nnotes\nEOF'
check deny "after a here-string"           $'cat <<< "x"\nxcodebuild -scheme App build'
check deny "after a comment with an apostrophe" $'# don\'t clean\nxcodebuild -scheme App build'
check deny "after a comment line"          $'# build it\nxcodebuild -scheme App build'
check pass "separator inside a comment"    $'ls # run; xcodebuild build\nls'
check deny "heredoc fed to bash"           $'bash <<\'EOF\'\n./gradlew assembleDebug\nEOF'
check deny "heredoc fed to sh with options" $'sh -s -- x <<EOF\nxcodebuild -scheme App build\nEOF'
check deny "heredoc piped to bash"         $'cat <<EOF | bash\nswiftlint lint\nEOF'
check pass "heredoc body after the shell one" $'bash <<A\nls\nA\ncat <<B\nswiftlint lint\nB'
check deny "escaped space then a hash is not a comment" $'cd My\\ #1 && xcodebuild -scheme App build'
check deny "ANSI-C string with an escaped quote" $'echo $\'it\\\'s\'\nxcodebuild -scheme App build'
check deny "heredoc body ending in a backslash does not hide the rest" $'cat <<\'EOF\' > f\nrun \\\nEOF\nxcodebuild -scheme App build'
check deny "heredoc with no end line is scanned" $'cat <<EOF\nxcodebuild -scheme App build'
check pass "no build tool at all"          'ls -la'
check pass "empty command"                 ''

# The reason names the matching build-kit line.
reason_has "xcodebuild build -> ios build"  'xcodebuild -scheme App build' 'python3 tools/build-kit/build.py ios build'
reason_has "xcodebuild test -> ios test"    'xcodebuild test -scheme App' 'python3 tools/build-kit/build.py ios test'
reason_has "gradlew lint -> android lint"   './gradlew lintDebug' 'python3 tools/build-kit/build.py android lint'
reason_has "gradlew detekt -> android lint" './gradlew detekt' 'python3 tools/build-kit/build.py android lint'
reason_has "gradlew test -> android test"   './gradlew testDebugUnitTest' 'python3 tools/build-kit/build.py android test'
reason_has "gradlew assemble -> android build" './gradlew assembleDebug' 'python3 tools/build-kit/build.py android build'
reason_has "swiftlint -> ios lint"          'swiftlint lint' 'python3 tools/build-kit/build.py ios lint'
reason_has "reason names the MCP tool"      'swiftlint lint' 'mcp__ios__lint'
reason_has "substitution deny says cannot classify" 'swiftlint lint $(pwd)' 'cannot be classified'

# Opt-in: only a project with .build-kit.json at or above the cwd is affected.
check pass "no .build-kit.json: xcodebuild" 'xcodebuild -scheme App build' "$T/other"
check pass "no .build-kit.json: gradlew"    './gradlew assembleDebug' "$T/other"
check pass "no .build-kit.json: swiftlint"  'swiftlint lint' "$T/other"
check deny "cwd below the project"          'xcodebuild -scheme App build' "$T/work/sub/dir"
withproj() {  # withproj <stdin json>: the hook's stdout with CLAUDE_PROJECT_DIR set to the opted-in project
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$T/work" HOME="$T" "$SH" "$T/hooks/build-redirect.sh" 2>/dev/null
}
out=$(withproj "$(bash_in 'xcodebuild -scheme App build' "$T/other")")
if [ -z "$out" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: CLAUDE_PROJECT_DIR beats the call's cwd: $out"; fi
out=$(withproj '{"tool_name":"Bash","tool_input":{"command":"xcodebuild -scheme App build"}}')
if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: no cwd falls back to CLAUDE_PROJECT_DIR: $out"; fi
out=$(withproj '{"tool_name":"Bash","cwd":".","tool_input":{"command":"xcodebuild -scheme App build"}}')
if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: relative cwd falls back to CLAUDE_PROJECT_DIR: $out"; fi

# The gaps the hook header names, pinned so the header stays true: change both together.
check pass "known gap: time wrapper"       'time xcodebuild -scheme App build'
check pass "known gap: nohup wrapper"      'nohup ./gradlew assembleDebug'
check pass "known gap: xargs wrapper"      'echo x | xargs swiftlint lint'
check pass "known gap: shell -c string"    "bash -c './gradlew assembleDebug'"
check pass "known gap: option value named clean" 'xcodebuild -scheme App -derivedDataPath clean'
check pass "known gap: variable as the task" './gradlew $TASK'
check pass "known gap: task abbreviation"  './gradlew aD'
check pass "known gap: system gradle"      'gradle assembleDebug'
check pass "known gap: spliced name"       'x"code"build -scheme App build'
check pass "known gap: option after sudo"  'sudo -u x xcodebuild -scheme App build'
check pass "known gap: substitution in an unquoted heredoc" $'cat <<EOF\n$(xcodebuild -scheme App build)\nEOF'
check pass "known gap: arithmetic shift as a heredoc" $'echo $((1<<n))\nxcodebuild -scheme App build\nn'

# Input that is not a JSON object passes, like empty input: the redirect is advisory.
want() {  # want <deny|pass> <label> <stdin json>
  local got
  got=$(decision "$3")
  if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $2: want $1, got $got"; fi
}
want pass "not JSON"                       '{"tool_name": "Bash", "tool_input": {'
want pass "JSON array, not an object"      '[]'
want pass "whitespace-only input"          $'  \t '
want pass "relative cwd"                   '{"tool_name":"Bash","cwd":".","tool_input":{"command":"xcodebuild -scheme App build"}}'
want pass "no cwd and no project dir"      '{"tool_name":"Bash","tool_input":{"command":"xcodebuild -scheme App build"}}'
[ "$(decision '')" = pass ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: empty input"; }
[ "$(decision '{"tool_name":"Bash","tool_input":{}}')" = pass ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: no command field"; }

# Deny output shape: JSON, deny decision, exit 0.
out=$(bash_in 'xcodebuild -scheme App build' | env -u CLAUDE_PROJECT_DIR HOME="$T" "$SH" "$T/hooks/build-redirect.sh" 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny"' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: deny output shape (rc=$rc): $out"
fi

# Fails open without jq: no output, exit 0.
out=$(bash_in 'xcodebuild -scheme App build' | env -u CLAUDE_PROJECT_DIR HOME="$T" PATH=/nonexistent "$SH" "$T/hooks/build-redirect.sh" 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: no-jq fail-open (rc=$rc): $out"; fi

# A deny is recorded in the audit log under the input's cwd, tagged with this hook (only with the logger present).
if [ "$HAVE_LOGGER" = 1 ]; then
  bash_in './gradlew assembleDebug' | env -u CLAUDE_PROJECT_DIR HOME="$T" "$SH" "$T/hooks/build-redirect.sh" >/dev/null 2>&1
  LOG=$(ls "$T"/work/.archive/audit/audit-*.log 2>/dev/null | head -1)
  if [ -n "$LOG" ] && jq -e 'select(.event == "deny" and .hook == "build-redirect" and (.reason | contains("android build")))' "$LOG" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: deny is not audited (log: ${LOG:-none})"; fi
else
  echo "skip: deny is audited (no audit-logger.sh beside the hook)"
fi

# An allowed call writes nothing.
rm -rf "$T/work/.archive"
bash_in 'xcodebuild -version' | env -u CLAUDE_PROJECT_DIR HOME="$T" "$SH" "$T/hooks/build-redirect.sh" >/dev/null 2>&1
if [ ! -e "$T/work/.archive" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: an allowed call wrote an audit record"; fi

echo "build-redirect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
