#!/bin/bash
# Pre-tool-use hook (PreToolUse on Bash): in a project that opted into build-kit (a .build-kit.json at the project
# directory or above it), sends direct builds, tests and lints to tools/build-kit/build.py, which runs the same tools
# with the project's allow-lists, a timeout and a structured result. Anywhere else it does nothing.
#   xcodebuild   denied when it builds or tests (an action, or none: the default is build). Passes: questions
#                (-version, -list, -showsdks, -showdestinations, -showBuildSettings, -showTestPlans, -help),
#                package and toolchain chores (-resolvePackageDependencies, -exportArchive, -create-xcframework,
#                -runFirstLaunch, -downloadPlatform, -license) and a bare `clean`
#   gradlew      denied for build-like tasks (assemble*, build*, bundle*, compile*, package*,
#                test*, *Test, check, lint*, detekt*, ktlint*, spotless*, connected*, verify*, jacoco*); tasks,
#                help, --version, clean and the rest pass
#   swiftlint    denied unless it is version, rules, docs, generate-docs, help, reporters, --version, --help, or
#                a --fix or autocorrect run (those change files and are not lints)
# A command counts only in command position (lib/shell-parse.sh reads the text): at the start of a line or after a
# separator or shell keyword (if, then, do, ...), behind VAR=value and the wrappers the parser knows (env, sudo, command,
# xcrun, time, nohup, nice, `timeout <duration>`, ...), after `sh` or `bash` (a script), and inside a `bash -c` or
# `eval` string or a $( ). The tool inside a string or an argument is left alone, also when the string holds | ; & ( )
# or braces, spans several lines, sits in a heredoc body or in a # comment.
# This is an advisory redirect: without jq, or on input that is not a JSON object, it lets the call through.
# Exit 0 always, also when lib/hook-common.sh or lib/shell-parse.sh is missing or cut short, and when the parser refuses the
# text (a control byte): this hook never denies on a parse failure.
#
# Known gaps, kept on purpose so the hook stays simple. These shapes pass:
#   - a variable as the task or an argument (./gradlew $TASK), Gradle's camel-case task abbreviations (./gradlew aD),
#     the system `gradle`, and names spliced with quotes or backslashes inside the word;
#   - a gradle option with a value that is not in the list the hook knows, and an xcodebuild option whose value is
#     the word clean (-derivedDataPath clean), which reads as a clean action;
#   - a script that runs the tool for the agent (make, fastlane, ./ci.sh);
#   - what the parser leaves unread (the header of lib/shell-parse.sh): a $( ) inside a heredoc body, a shell fed by a
#     pipe, a string nested more than 3 deep.
# The redirect is a convenience, not a sandbox: the allow-lists in build-kit protect the calls that go through it.

command -v jq >/dev/null 2>&1 || exit 0
HOOK=build-redirect
# Sourced before `set -e`: under it bash 3.2 exits 1 on a missing file even with `|| exit 0`.
S=${BASH_SOURCE[0]}; [ -L "$S" ] && S=$(readlink "$S")
. "${S%/*}/lib/hook-common.sh" 2>/dev/null || exit 0
. "${S%/*}/lib/shell-parse.sh" 2>/dev/null && [ "${SHELL_PARSE_LOADED:-}" = 1 ] || exit 0
set -euo pipefail

printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
COMMAND=$(field '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

# Opt-in: .build-kit.json at the call's working directory or above it (an absolute directory only). The input's cwd
# comes first, so a clone of another repo is judged by its own folder (a `cd /project && xcodebuild` from outside the
# project passes, as the cwd decides); CLAUDE_PROJECT_DIR is the fallback when the input has no absolute cwd.
DIR=$(field '(.cwd | strings | select(startswith("/"))) // empty')
[ -n "$DIR" ] || DIR=${CLAUDE_PROJECT_DIR:-}
case "$DIR" in /*) ;; *) exit 0 ;; esac
while [ -n "$DIR" ] && [ "$DIR" != / ] && [ ! -f "$DIR/.build-kit.json" ]; do DIR=$(dirname "$DIR"); done
[ -n "$DIR" ] && [ -f "$DIR/.build-kit.json" ] || exit 0

redirect() {  # redirect <tool> <platform> <action>
  deny "redirect Bash $1 -> build-kit $2 $3" "This project uses build-kit. Run \`python3 tools/build-kit/build.py $2 $3\` (or the MCP tool mcp__$2__$3) instead of $1 directly: it applies the allow-lists in .build-kit.json, a timeout and a lock, and returns structured results. Read-only queries (xcodebuild -list, -version, -showsdks; xcrun simctl list; gradlew tasks, --version) are not redirected."
}

# The parser hands each simple command here; a build, test or lint prints "<tool> <platform> <action>", a command it
# cannot classify "unclassifiable <tool>". The first line printed wins (see the end).
on_command() {
  local tool=${1##*/} tok skip=0 class="" first="" acts=0 test=0 query=0 clean=0
  case "$tool" in
    sh | bash) case "${2:-}" in "" | -*) ;; *) shift; on_command "$@" ;; esac; return 0 ;;
    xargs) shift; sp_xargs "$@"; return 0 ;;
    xcodebuild | gradlew | swiftlint) ;;
    *) return 0 ;;
  esac
  shift
  # A substitution inside the invocation hides what it really runs.
  case "$*" in *'$('*) echo "unclassifiable $tool"; return 0 ;; esac
  case "$tool" in
    xcodebuild)
      for tok in "$@"; do
        case "$tok" in
          test | test-without-building) acts=1 test=1 ;;
          build | build-for-testing | archive | analyze | install | installsrc | docbuild) acts=1 ;;
          clean) clean=1 ;;
          -version | -list | -showsdks | -showdestinations | -showBuildSettings | -showTestPlans | -help | -usage | -license | -runFirstLaunch | -checkFirstLaunchStatus | -downloadPlatform | -resolvePackageDependencies | -exportArchive | -create-xcframework) query=1 ;;
        esac
      done
      if [ "$acts" = 1 ]; then
        if [ "$test" = 1 ]; then echo "xcodebuild ios test"; else echo "xcodebuild ios build"; fi
      fi
      [ "$query" = 1 ] || [ "$clean" = 1 ] || echo "xcodebuild ios build" ;;
    gradlew)
      for tok in "$@"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$tok" in
          -p | --project-dir | -g | --gradle-user-home | -I | --init-script | -c | --settings-file | -b | --build-file | --project-cache-dir | --max-workers | -x | --exclude-task | --console | --warning-mode) skip=1; continue ;;
          -*) continue ;;
        esac
        case "${tok##*:}" in
          lint | lint[A-Z]* | detekt* | ktlint* | spotless* | check) class=${class:-lint} ;;
          test | test[A-Z]* | *Test | allTests | connected* | verify* | jacoco*) class=${class:-test} ;;
          assemble* | build | build[A-Z]* | bundle* | compile* | package*) class=${class:-build} ;;
        esac
      done
      [ -z "$class" ] || echo "gradlew android $class" ;;
    swiftlint)
      first=${1:-}
      case "$first" in
        version | rules | docs | generate-docs | help | reporters | --version | --help | -h | --fix | autocorrect) ;;
        *) echo "swiftlint ios lint" ;;
      esac ;;
  esac
  return 0
}
on_redirect() { :; }

# Only a command that names one of the tools is parsed. A parser refusal (deny) ends the subshell and nothing
# else: this hook stays advisory, so what it cannot read passes.
case "$COMMAND" in *xcodebuild* | *gradlew* | *swiftlint*) ;; *) exit 0 ;; esac
CWD=""
HITS=$(set +e; deny() { exit 0; }; shell_parse "$COMMAND") || true
HIT=$(printf '%s\n' "$HITS" | grep -m1 -E '^(xcodebuild|gradlew|swiftlint|unclassifiable) ' || true)
[ -n "$HIT" ] || exit 0
set -- $HIT
if [ "$1" = unclassifiable ]; then
  deny "unclassifiable Bash $2" "This $2 command contains a command substitution and cannot be classified. Run \`python3 tools/build-kit/build.py <ios|android> <build|test|lint|build_test>\` instead."
fi
redirect "$@"
