#!/bin/bash
# Runs every test suite under tools/ and prints one pass/fail row per suite.
#   bash tools/test-all.sh                run all suites
#   bash tools/test-all.sh --quick        skip the slow ones (workspace-lock acquire, ~1.5 min)
#   bash tools/test-all.sh NAME [NAME…]   run only the named suites (names are the first column)
# A suite whose tool or install is missing (zsh, node_modules) shows as skip, never as pass. Exit 1 if any suite fails,
# 2 on an unknown option or suite name (checked before anything runs).
# Adding a suite: add one `suite` line below and the same name to the Build / Test list in CLAUDE.md.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
QUICK=0
ONLY=" "
for a in "$@"; do
  case $a in
    --quick) QUICK=1 ;;
    -h | --help) sed -n '2,8p' "$0"; exit 0 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) ONLY="$ONLY$a " ;;
  esac
done
LOG=$(mktemp -d "${TMPDIR:-/tmp}/test-all-XXXXXX") || exit 2
[ -n "$LOG" ] && [ -d "$LOG" ] || exit 2
trap 'rm -rf "$LOG"' EXIT

RAN=0 FAILS="" PASSED=0 SKIPPED=0 LISTING=0 NAMES=" "
suite() {  # suite <name> <slow:0|1> <needs> <command>; needs is a command on PATH or dir:<path under the repo>
  local name=$1 slow=$2 needs=$3 cmd=$4 start rc
  if [ "$LISTING" = 1 ]; then NAMES="$NAMES$name "; return; fi
  if [ "$ONLY" != " " ]; then case $ONLY in *" $name "*) ;; *) return ;; esac; fi
  RAN=$((RAN + 1))
  if [ "$slow" = 1 ] && [ "$QUICK" = 1 ]; then
    printf '%-24s skip  (--quick)\n' "$name"; SKIPPED=$((SKIPPED + 1)); return
  fi
  case $needs in
    dir:*) [ -d "$ROOT/${needs#dir:}" ] || { printf '%-24s skip  (missing %s: run npm install there)\n' "$name" "${needs#dir:}"; SKIPPED=$((SKIPPED + 1)); return; } ;;
    *) command -v "$needs" >/dev/null 2>&1 || { printf '%-24s skip  (needs %s)\n' "$name" "$needs"; SKIPPED=$((SKIPPED + 1)); return; } ;;
  esac
  start=$SECONDS
  (cd "$ROOT" && bash -c "$cmd") > "$LOG/$name.log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%-24s pass  %4ss\n' "$name" $((SECONDS - start)); PASSED=$((PASSED + 1))
  else
    printf '%-24s FAIL  %4ss  (exit %s)\n' "$name" $((SECONDS - start)) "$rc"; FAILS="$FAILS $name"
  fi
}

suites() {
  suite audit-logger         0 bash                                  'bash tools/audit-logger/test-audit-logger.sh'
  suite destructive-blocker  0 bash                                  'bash tools/destructive-blocker/test-destructive-blocker.sh'
  suite gh-block             0 bash                                  'bash tools/gh-block/test-gh-block.sh'
  suite git-mcp-guard        0 bash                                  'bash tools/git-mcp-guard/test-git-mcp-guard.sh'
  suite git-mcp-redirect     0 bash                                  'bash tools/git-mcp-redirect/test-git-mcp-redirect.sh'
  suite github-mcp-guard     0 bash                                  'bash tools/github-mcp/test-guard.sh'
  suite github-mcp-update    0 bash                                  'bash tools/github-mcp/test-update-check.sh'
  suite install-copies       0 bash                                  'bash tools/test-install-copies.sh'
  suite secret-detector      0 bash                                  'bash tools/secret-detector/test-secret-detector.sh'
  suite secret-redact-output 0 bash                                  'bash tools/secret-redact-output/test-secret-redact-output.sh'
  suite session-name         0 bash                                  'bash tools/session-name/test-restore.sh'
  suite cleanup-claude       0 jq                                    'bash tools/cleanup-claude/test-cleanup.sh'
  suite statusline           0 jq                                    'bash tools/test-statusline.sh'
  suite workspace-lock-guard 0 bash                                  'bash tools/workspace-lock/test-guard.sh'
  suite workspace-lock-wait  1 bash                                  'bash tools/workspace-lock/test-acquire.sh'
  suite ait                  0 zsh                                   'bash tools/test-ait.sh'
}

LISTING=1
suites
LISTING=0
UNKNOWN=0
for n in $ONLY; do
  case $NAMES in *" $n "*) ;; *) echo "unknown suite: $n (known:${NAMES% })" >&2; UNKNOWN=1 ;; esac
done
[ "$UNKNOWN" = 0 ] || exit 2

suites

echo
echo "$PASSED passed, $(echo $FAILS | wc -w | tr -d ' ') failed, $SKIPPED skipped of $RAN"
for f in $FAILS; do
  echo
  echo "--- $f (last 20 lines) ---"
  tail -n 20 "$LOG/$f.log"
done
[ -z "$FAILS" ]
