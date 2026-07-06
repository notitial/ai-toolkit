#!/bin/bash
# Tests for hooks/git-mcp-guard.sh (HOOK=<path> tests another copy). Run: bash tools/git-mcp-guard/test-git-mcp-guard.sh
# The hook and its sibling audit-logger.sh run from a temp copy under HOOK_SHELL (default /bin/bash, 3.2) with HOME
# pointed at a temp folder, so a deny never writes to the live audit log. The push cases that resolve a branch use
# throwaway repos created under the temp folder (no network; the "remote" is a name with an unreachable URL, and the
# commit identity is a placeholder). Each case expects deny or pass (no output). Without audit-logger.sh beside the
# hook (it is installed with the audit hooks), the audit case is skipped and says so.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../../hooks/git-mcp-guard.sh}"
LOGGER="${LOGGER:-$(dirname "$HOOK")/audit-logger.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required" >&2; exit 2; }
SH="${HOOK_SHELL:-/bin/bash}"
T=$(mktemp -d "${TMPDIR:-/tmp}/git-mcp-guard-XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/hooks" "$T/work"
cp "$HOOK" "$T/hooks/git-mcp-guard.sh"
HAVE_LOGGER=0
[ -f "$LOGGER" ] && cp "$LOGGER" "$T/hooks/audit-logger.sh" && HAVE_LOGGER=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
PASS=0
FAIL=0

mkrepo() {  # mkrepo <dir> <branch>: a repo with one commit on <branch>
  git init -q -b "$2" "$1" && git -C "$1" commit -q --allow-empty -m init || { echo "repo setup failed: $1" >&2; exit 2; }
}
mkrepo "$T/feat" feature
mkrepo "$T/onmain" main
mkrepo "$T/remote" feature
git -C "$T/remote" remote add origin "$T/unreachable-remote"
mkrepo "$T/detached" feature
git -C "$T/detached" checkout -q --detach
mkrepo "$T/upstream" feature
git -C "$T/upstream" remote add origin "$T/unreachable-remote"
git -C "$T/upstream" update-ref refs/remotes/origin/main HEAD
git -C "$T/upstream" config push.default upstream
git -C "$T/upstream" config branch.feature.remote origin
git -C "$T/upstream" config branch.feature.merge refs/heads/main
mkdir -p "$T/notrepo"

decision() {  # decision <stdin json>
  local out
  out=$(printf '%s' "$1" | HOME="$T" "$SH" "$T/hooks/git-mcp-guard.sh" 2>/dev/null)
  [ -z "$out" ] && { echo pass; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed
}
expect() {  # expect <deny|pass> <label> <stdin json>
  local got
  got=$(decision "$3")
  if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $2: want $1, got $got"; fi
}
tool() {  # tool <name> <tool_input json>
  jq -nc --arg n "$1" --argjson i "$2" '{tool_name: $n, tool_input: $i}'
}
push() { expect "$1" "push: $2" "$(tool mcp__git-mcp__git_push "$3")"; }  # push <deny|pass> <label> <tool_input json>

push pass "dry run needs no path"                '{"dryRun":true}'
push pass "dry run even when forced"             '{"dryRun":true,"force":true}'
push deny "force"                                "{\"path\":\"$T/feat\",\"branch\":\"feature\",\"force\":true}"
push deny "force with lease"                     "{\"path\":\"$T/feat\",\"branch\":\"feature\",\"forceWithLease\":true}"
push deny "delete"                               "{\"path\":\"$T/feat\",\"branch\":\"feature\",\"delete\":true}"
push deny "no path"                              '{"branch":"feature"}'
push deny "dot path"                             '{"path":".","branch":"feature"}'
push deny "empty path"                           '{"path":"","branch":"feature"}'
push deny "dot-slash path"                       '{"path":"./","branch":"feature"}'
push deny "parent path"                          '{"path":"..","branch":"feature"}'
push deny "relative subfolder"                   '{"path":"subdir","branch":"feature"}'
push pass "feature branch"                       "{\"path\":\"$T/feat\",\"branch\":\"feature\"}"
push pass "feature via remoteBranch"             "{\"path\":\"$T/feat\",\"remoteBranch\":\"feature\"}"
push pass "no branch, current branch is feature" "{\"path\":\"$T/feat\"}"
push deny "main"                                 "{\"path\":\"$T/feat\",\"branch\":\"main\"}"
push deny "master"                               "{\"path\":\"$T/feat\",\"branch\":\"master\"}"
push deny "production"                           "{\"path\":\"$T/feat\",\"branch\":\"production\"}"
push deny "refs/heads/main"                      "{\"path\":\"$T/feat\",\"branch\":\"refs/heads/main\"}"
push deny "heads/main"                           "{\"path\":\"$T/feat\",\"branch\":\"heads/main\"}"
push deny "+main"                                "{\"path\":\"$T/feat\",\"branch\":\"+main\"}"
push deny "+refs/heads/main"                     "{\"path\":\"$T/feat\",\"branch\":\"+refs/heads/main\"}"
push deny "remoteBranch main"                    "{\"path\":\"$T/feat\",\"branch\":\"feature\",\"remoteBranch\":\"main\"}"
push deny "origin/main with a real remote"       "{\"path\":\"$T/remote\",\"branch\":\"origin/main\"}"
push deny "refs/heads/origin/main"               "{\"path\":\"$T/remote\",\"branch\":\"refs/heads/origin/main\"}"
push deny "origin/production remote-qualified"   "{\"path\":\"$T/remote\",\"remoteBranch\":\"origin/production\"}"
push pass "origin/feature with a real remote"    "{\"path\":\"$T/remote\",\"branch\":\"origin/feature\"}"
push pass "release/production is a real branch"  "{\"path\":\"$T/remote\",\"branch\":\"release/production\"}"
push deny "no branch, current branch is main"    "{\"path\":\"$T/onmain\"}"
push deny "no branch, upstream maps to main"     "{\"path\":\"$T/upstream\"}"
push deny "no branch, detached HEAD"             "{\"path\":\"$T/detached\"}"
push deny "no branch, not a repo"                "{\"path\":\"$T/notrepo\"}"
push deny "no branch, path does not exist"       "{\"path\":\"$T/missing\"}"
push pass "branch given for a main checkout"     "{\"path\":\"$T/onmain\",\"branch\":\"feature\"}"
push deny "branch HEAD on a main checkout"       "{\"path\":\"$T/onmain\",\"branch\":\"HEAD\"}"
push deny "branch @ on a main checkout"          "{\"path\":\"$T/onmain\",\"branch\":\"@\"}"
push deny "branch +HEAD on a main checkout"      "{\"path\":\"$T/onmain\",\"branch\":\"+HEAD\"}"
push deny "remoteBranch HEAD on a main checkout" "{\"path\":\"$T/onmain\",\"remoteBranch\":\"HEAD\"}"
push deny "branch HEAD, upstream maps to main"   "{\"path\":\"$T/upstream\",\"branch\":\"HEAD\"}"
push pass "branch HEAD on a feature checkout"    "{\"path\":\"$T/feat\",\"branch\":\"HEAD\"}"

reset() { expect "$1" "reset: $2" "$(tool mcp__git-mcp__git_reset "$3")"; }  # reset <deny|pass> <label> <tool_input json>
reset deny "hard"                    '{"path":"/x","mode":"hard"}'
reset deny "merge"                   '{"path":"/x","mode":"merge"}'
reset pass "soft"                    '{"path":"/x","mode":"soft"}'
reset pass "mixed"                   '{"path":"/x","mode":"mixed"}'
reset pass "no mode"                 '{"path":"/x"}'

expect pass "clean dry run"          "$(tool mcp__git-mcp__git_clean '{"path":"/x","dryRun":true}')"
expect deny "clean for real"         "$(tool mcp__git-mcp__git_clean '{"path":"/x","dryRun":false}')"
expect deny "clean with no dryRun"   "$(tool mcp__git-mcp__git_clean '{"path":"/x"}')"
expect deny "worktree add"           "$(tool mcp__git-mcp__git_worktree '{"path":"/x","mode":"add"}')"
expect deny "worktree list"          "$(tool mcp__git-mcp__git_worktree '{"path":"/x","mode":"list"}')"

expect pass "git_status is not guarded"  "$(tool mcp__git-mcp__git_status '{"path":"/x"}')"
expect pass "git_commit is not guarded"  "$(tool mcp__git-mcp__git_commit '{"path":"/x","message":"m"}')"
expect pass "Bash is not guarded"        '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}'

expect deny "empty input"                ''
expect deny "malformed input"            'not json'
expect deny "no tool name"               '{"tool_input":{"path":"/x"}}'
expect deny "empty object"               '{}'

# Deny output shape: JSON, deny decision, the reason is prefixed with the hook name.
out=$(tool mcp__git-mcp__git_worktree '{"path":"/x"}' | HOME="$T" "$SH" "$T/hooks/git-mcp-guard.sh" 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny" and (.permissionDecisionReason | startswith("git-mcp-guard: "))' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: deny output shape (rc=$rc): $out"
fi

# Fail closed without jq: static deny JSON, exit 0.
out=$(printf '%s' "$(tool mcp__git-mcp__git_status '{"path":"/x"}')" | HOME="$T" PATH=/nonexistent "$SH" "$T/hooks/git-mcp-guard.sh" 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: no-jq fail-closed (rc=$rc): $out"; fi

# A deny is recorded in the audit log under the input's cwd, tagged with this hook (only with the logger present).
if [ "$HAVE_LOGGER" = 1 ]; then
  printf '%s' "$(jq -nc --arg d "$T/work" '{tool_name: "mcp__git-mcp__git_clean", cwd: $d, session_id: "s1", tool_input: {path: "/x"}}')" \
    | HOME="$T" "$SH" "$T/hooks/git-mcp-guard.sh" >/dev/null 2>&1
  LOG=$(ls "$T"/work/.archive/audit/audit-*.log 2>/dev/null | head -1)
  if [ -n "$LOG" ] && jq -e 'select(.event == "deny" and .hook == "git-mcp-guard" and .tool == "mcp__git-mcp__git_clean")' "$LOG" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: deny is not audited (log: ${LOG:-none})"; fi
else
  echo "skip: deny is audited (no audit-logger.sh beside the hook)"
fi

# An allowed call writes nothing.
rm -rf "$T/work/.archive"
printf '%s' "$(jq -nc --arg d "$T/work" '{tool_name: "mcp__git-mcp__git_status", cwd: $d, tool_input: {path: "/x"}}')" \
  | HOME="$T" "$SH" "$T/hooks/git-mcp-guard.sh" >/dev/null 2>&1
if [ ! -e "$T/work/.archive" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: an allowed call wrote an audit record"; fi

echo "git-mcp-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
