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
# A command counts only in command position: at the start of a line or after a separator or shell keyword (if,
# then, do, ...), behind VAR=value, env, sudo, command, xcrun, sh, bash or `timeout <duration>`. The tool inside a
# string or an argument is left alone, also when the string holds | ; & ( ) or braces, spans several lines, sits in a
# heredoc body or in a # comment.
# This is an advisory redirect: without jq, or on input that is not a JSON object, it lets the call through.
# Exit 0 always.
#
# Known gaps, kept on purpose so the hook stays simple (same family as git-mcp-redirect.sh). These shapes pass:
#   - wrappers other than the ones above (time, nohup, exec, nice, xargs), options after a wrapper (sudo -u x),
#     and a tool inside a shell -c string;
#   - a variable as the task or an argument (./gradlew $TASK), Gradle's camel-case task abbreviations (./gradlew aD),
#     the system `gradle`, and names spliced with quotes or backslashes inside the word;
#   - a gradle option with a value that is not in the list the hook knows, and an xcodebuild option whose value is
#     the word clean (-derivedDataPath clean), which reads as a clean action;
#   - a script that runs the tool for the agent (make, fastlane, ./ci.sh);
#   - a $(...) or backtick inside an unquoted heredoc body (bash runs it, the hook skips the body), and a heredoc
#     fed to anything but a shell on its own line (ssh host <<EOF, source /dev/stdin <<EOF);
#   - shell arithmetic such as $((1<<n)), which reads as a heredoc start (its lines are dropped up to a line n, or
#     scanned again at the end when none comes).
# The redirect is a convenience, not a sandbox: the allow-lists in build-kit protect the calls that go through it.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

# Opt-in: .build-kit.json at the call's working directory or above it (an absolute directory only). The input's cwd
# comes first, so a clone of another repo is judged by its own folder (a `cd /project && xcodebuild` from outside the
# project passes, as the cwd decides); CLAUDE_PROJECT_DIR is the fallback when the input has no absolute cwd.
DIR=$(printf '%s' "$INPUT" | jq -r '(.cwd | strings | select(startswith("/"))) // empty')
[ -n "$DIR" ] || DIR=${CLAUDE_PROJECT_DIR:-}
case "$DIR" in /*) ;; *) exit 0 ;; esac
while [ -n "$DIR" ] && [ "$DIR" != / ] && [ ! -f "$DIR/.build-kit.json" ]; do DIR=$(dirname "$DIR"); done
[ -n "$DIR" ] && [ -f "$DIR/.build-kit.json" ] || exit 0

# Best-effort record of a deny in the audit log (never blocks this hook).
audit_deny() {
  local logger
  logger="$(dirname "${BASH_SOURCE[0]}")/audit-logger.sh"
  [ -r "$logger" ] || return 0
  printf '%s' "$INPUT" \
    | jq -c --arg r "$1" --arg h "build-redirect" \
        '. + {_audit_event:"deny",_deny_reason:$r,_deny_hook:$h}' 2>/dev/null \
    | bash "$logger" >/dev/null 2>&1 || true
}

deny() {
  audit_deny "$1"
  jq -n --arg r "$2" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

redirect() {  # redirect <tool> <platform> <action>
  deny "redirect Bash $1 -> build-kit $2 $3" "This project uses build-kit. Run \`python3 tools/build-kit/build.py $2 $3\` (or the MCP tool mcp__$2__$3) instead of $1 directly: it applies the allow-lists in .build-kit.json, a timeout and a lock, and returns structured results. Read-only queries (xcodebuild -list, -version, -showsdks; xcrun simctl list; gradlew tasks, --version) are not redirected."
}

# Continuation lines are joined, and each whole quoted string that holds a separator character (and no substitution)
# becomes Q, so `grep "gradlew|xcodebuild" .` is not read as a command after a pipe. Quote state runs across lines
# (a newline inside a string becomes a space, so a line of a multi-line commit message is not at line start), the
# lines of a heredoc body are dropped (<<WORD, <<-WORD, <<'WORD' up to the WORD line) unless a shell reads them
# (a line with sh, bash, zsh, dash or ksh on it), and a # comment is skipped. A heredoc with no end line is not
# dropped: its lines are scanned at the end, so a missed terminator never hides a command.
SCAN=${COMMAND//\\$'\n'/ }
SCAN=$(printf '%s' "$SCAN" | awk '
  BEGIN { sq = "\047"; hdre = "^-?[ \t]*(" sq "[^" sq "]*" sq "|\"[^\"]*\"|\\\\?[A-Za-z_][A-Za-z0-9_.-]*)" }
  hd_n > 0 {
    line = $0
    if (hd_dash[1]) sub(/^\t+/, "", line)
    if (line == hd_word[1]) { for (k = 1; k < hd_n; k++) { hd_word[k] = hd_word[k + 1]; hd_dash[k] = hd_dash[k + 1]; hd_scan[k] = hd_scan[k + 1] } hd_n--; hd_buf = "" }
    else if (hd_scan[1]) print $0
    else hd_buf = hd_buf $0 "\n"
    next
  }
  { n = length($0); first = hd_n + 1; esc = 0
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1); e = esc; esc = 0
      if (c == "\\" && (q != sq || ansi)) { if (q == "") out = out c substr($0, i + 1, 1); else buf = buf c substr($0, i + 1, 1); i++; esc = 1; continue }
      if (q == "") {
        if (c == "\"" || c == sq) { q = c; buf = ""; ansi = (c == sq && out ~ /\$$/) }
        else if (c == "#" && !e && (out == "" || out ~ /[[:space:];&|(]$/)) break
        else if (substr($0, i, 3) == "<<<") { out = out "<<<"; i += 2 }
        else if (substr($0, i, 2) == "<<" && match(substr($0, i + 2), hdre)) {
          w = substr($0, i + 2, RLENGTH); hd_n++; hd_dash[hd_n] = (substr(w, 1, 1) == "-"); hd_scan[hd_n] = 0
          sub(/^-?[ \t]*/, "", w); gsub("[" sq "\"\\\\]", "", w); hd_word[hd_n] = w
          out = out "<<H"; i += 1 + RLENGTH
        }
        else out = out c
      }
      else if (c == q) { if (buf ~ /[|;&(){}]/ && buf !~ /[$`]/) out = out "Q"; else out = out q buf q; q = ""; ansi = 0 }
      else buf = buf c
    }
    if (q != "") { buf = buf " "; hd_n = first - 1 }
    else {
      if (hd_n >= first && out ~ /(^|[[:space:];&|(\/])(ba|z|da|k)?sh([[:space:]]|$)/) for (k = first; k <= hd_n; k++) hd_scan[k] = 1
      print out; out = ""
    }
  }
  END { if (q != "") print out q buf; if (hd_n > 0) printf "%s", hd_buf }')
ANCHOR="(^|[|;&(\`{])"
LEADER="([A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|'[^']*'|[^[:space:]'\"])*|([^[:space:]]*/)?(env|sudo|command|xcrun|sh|bash)|!|then|do|else|elif|if|while|until|timeout[[:space:]]+[0-9][0-9.]*[smhd]?)[[:space:]]+"
INVOCATIONS=$(printf '%s\n' "$SCAN" | grep -oE "${ANCHOR}[[:space:]]*(${LEADER})*['\"]?[^[:space:]'\"|;&()\`]*(xcodebuild|gradlew|swiftlint)['\"]?([[:space:]][^|;&)\`]*)?" || true)
[ -n "$INVOCATIONS" ] || exit 0

while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  REST=$(printf '%s' "$LINE" | sed -E "s#^[|;&(\`{]?[[:space:]]*(${LEADER})*['\"]?##")
  WORD=${REST%%[[:space:]]*}
  ARGS=${REST#"$WORD"}
  TOOL=${WORD##*/}
  TOOL=${TOOL%[\'\"]}
  TOOL=${TOOL#\\}
  case "$TOOL" in xcodebuild | gradlew | swiftlint) ;; *) continue ;; esac

  # A substitution inside the invocation hides what it really runs.
  case "$ARGS" in
    *'$('* | *'`'*) deny "unclassifiable Bash $TOOL" "This $TOOL command contains a command substitution and cannot be classified. Run \`python3 tools/build-kit/build.py <ios|android> <build|test|lint|build_test>\` instead." ;;
  esac

  set -f
  case "$TOOL" in
    xcodebuild)
      acts=0 test=0 query=0 clean=0
      for tok in $ARGS; do
        tok=${tok//[\'\"]/}
        case "$tok" in
          test | test-without-building) acts=1 test=1 ;;
          build | build-for-testing | archive | analyze | install | installsrc | docbuild) acts=1 ;;
          clean) clean=1 ;;
          -version | -list | -showsdks | -showdestinations | -showBuildSettings | -showTestPlans | -help | -usage | -license | -runFirstLaunch | -checkFirstLaunchStatus | -downloadPlatform | -resolvePackageDependencies | -exportArchive | -create-xcframework) query=1 ;;
        esac
      done
      set +f
      if [ "$acts" = 1 ]; then
        if [ "$test" = 1 ]; then redirect xcodebuild ios test; else redirect xcodebuild ios build; fi
      fi
      [ "$query" = 1 ] || [ "$clean" = 1 ] || redirect xcodebuild ios build ;;
    gradlew)
      skip=0 class=""
      for tok in $ARGS; do
        tok=${tok//[\'\"]/}
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
      set +f
      [ -z "$class" ] || redirect gradlew android "$class" ;;
    swiftlint)
      first=""
      for tok in $ARGS; do first=${tok//[\'\"]/}; break; done
      set +f
      case "$first" in
        version | rules | docs | generate-docs | help | reporters | --version | --help | -h | --fix | autocorrect) ;;
        *) redirect swiftlint ios lint ;;
      esac ;;
  esac
done <<EOF
$INVOCATIONS
EOF
exit 0
