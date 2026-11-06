#!/bin/bash
# Tests for tools/github-mcp/guard.sh and launch. Run: bash tools/github-mcp/test-guard.sh
# Hook cases expect deny, ask, or pass (no output = defer to the permission rules).
# Writes the guard lets through return ask; reads pass.

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/guard.sh"
# Run a copy with HOME pointed away, so its deny path never writes to the live audit log.
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
# The guard checks the checkout it sits in (a clean main) and reads its owners from $HOME/.claude/install.conf, so
# the copy under test sits in a throwaway checkout on main, with a fixture install.conf under the fake HOME.
CO="$TMP/co"
mkdir -p "$CO/tools/github-mcp" "$TMP/.claude"
cp "$SRC" "$CO/tools/github-mcp/guard.sh"
cp "$HERE/launch" "$CO/tools/github-mcp/launch"
printf 'tracked\n' > "$CO/README"
GIT_Q=(git -C "$CO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false)
"${GIT_Q[@]}" init -q -b main && "${GIT_Q[@]}" add -A && "${GIT_Q[@]}" commit -q -m init && "${GIT_Q[@]}" update-ref refs/remotes/origin/main HEAD || { echo "ABORT: cannot build the throwaway checkout"; exit 1; }
write_conf() { printf '%s\n' "$@" > "$TMP/.claude/install.conf"; }
write_conf 'github_write_owners=notitial example-user' 'github_keychain_account=test-account'
HOOK="$CO/tools/github-mcp/guard.sh"
PASS=0
FAIL=0

decision() {
  local out
  out=$(printf '%s' "$1" | HOME="$TMP" bash "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then echo pass; return; fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed
}

check() {
  local want="$1" name="$2" input="$3" got
  got=$(decision "$input")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name: want $want, got $got"
  fi
}

call() {
  jq -n -c --arg t "mcp__github__$1" --argjson i "$2" '{tool_name: $t, tool_input: $i}'
}

acall() {
  jq -n -c --arg t "mcp__github__$1" --argjson i "$2" '{tool_name: $t, tool_input: ({owner: "notitial", repo: "toolkit-repo"} + $i)}'
}

check pass "read tool" "$(acall pull_request_read '{"method":"get_check_runs","pullNumber":1}')"
check pass "read tool on another repo" "$(call list_pull_requests '{"owner":"notitial","repo":"some-other-repo"}')"
check pass "get_me" "$(call get_me '{}')"
check allow "create PR in toolkit-repo" "$(acall create_pull_request '{"title":"t","head":"b","base":"main","draft":true}')"
check allow "owner case-insensitive" "$(call create_pull_request '{"owner":"Notitial","repo":"Toolkit-Repo","title":"t","head":"b","base":"main","draft":true}')"
for r in notitial/app-one notitial/app-two notitial/web-site notitial/infra-config example-user/repo-one example-user/repo-two example-user/repo-three; do
  check allow "create PR in $r" "$(call create_pull_request "$(jq -n -c --arg o "${r%/*}" --arg r "${r#*/}" '{owner: $o, repo: $r, title: "t", head: "b", base: "main", draft: true}')")"
done
check deny "create PR in a repo of another owner" "$(call create_pull_request '{"owner":"github","repo":"github-mcp-server","title":"t","head":"b","base":"main","draft":true}')"
for r in notitial/new-project notitial/a-repo-created-later example-user/a-repo-created-later Example-User/Mixed.Case_repo-1; do
  check allow "create PR in $r (owner wildcard)" "$(call create_pull_request "$(jq -n -c --arg o "${r%/*}" --arg r "${r#*/}" '{owner: $o, repo: $r, title: "t", head: "b", base: "main", draft: true}')")"
done
check deny "create PR under an owner that only contains a write owner" "$(call create_pull_request '{"owner":"notitial-evil","repo":"toolkit-repo","title":"t","head":"b","base":"main","draft":true}')"
check deny "create PR under an owner with a write owner as prefix" "$(call create_pull_request '{"owner":"example-user2","repo":"toolkit-repo","title":"t","head":"b","base":"main","draft":true}')"
check deny "create PR in a repo of another owner with a write-owner repo name" "$(call create_pull_request '{"owner":"someone-else","repo":"toolkit-repo","title":"t","head":"b","base":"main","draft":true}')"
check deny "empty repo name" "$(call create_pull_request '{"owner":"notitial","repo":"","title":"t","head":"b","base":"main","draft":true}')"
check deny "repo name with a slash" "$(call create_pull_request '{"owner":"notitial","repo":"toolkit-repo/x","title":"t","head":"b","base":"main","draft":true}')"
check deny "repo name with a space" "$(call create_pull_request '{"owner":"notitial","repo":"toolkit repo","title":"t","head":"b","base":"main","draft":true}')"
check deny "repo name that is dots" "$(call create_pull_request '{"owner":"notitial","repo":"..","title":"t","head":"b","base":"main","draft":true}')"
check deny "repo name that is one dot" "$(call create_pull_request '{"owner":"notitial","repo":".","title":"t","head":"b","base":"main","draft":true}')"
check deny "repo name that is three dots" "$(call create_pull_request '{"owner":"notitial","repo":"...","title":"t","head":"b","base":"main","draft":true}')"
check deny "repo name with a non-ASCII letter" "$(call create_pull_request '{"owner":"notitial","repo":"toolkİt-repo","title":"t","head":"b","base":"main","draft":true}')"
check deny "repo name with a tab" "$(call create_pull_request '{"owner":"notitial","repo":"toolkit\trepo","title":"t","head":"b","base":"main","draft":true}')"
check deny "repo null" "$(call create_pull_request '{"owner":"notitial","repo":null,"title":"t","head":"b","base":"main","draft":true}')"
check deny "repo a number" "$(call create_pull_request '{"owner":"notitial","repo":5,"title":"t","head":"b","base":"main","draft":true}')"
check allow "repo name of exactly 100 characters" "$(call create_pull_request "$(jq -n -c --arg r "$(printf 'a%.0s' $(seq 1 100))" '{owner: "notitial", repo: $r, title: "t", head: "b", base: "main", draft: true}')")"
check deny "repo name over 100 characters" "$(call create_pull_request "$(jq -n -c --arg r "$(printf 'a%.0s' $(seq 1 101))" '{owner: "notitial", repo: $r, title: "t", head: "b", base: "main", draft: true}')")"
check deny "owner with a trailing newline" "$(call create_pull_request '{"owner":"notitial\n","repo":"toolkit-repo","title":"t","head":"b","base":"main","draft":true}')"
check deny "repo not a string" "$(call create_pull_request '{"owner":"notitial","repo":["toolkit-repo"],"title":"t","head":"b","base":"main","draft":true}')"
check deny "merge stays denied in a write-owner repo" "$(call merge_pull_request '{"owner":"notitial","repo":"new-project","pullNumber":1}')"
check deny "ruleset stays denied in a write-owner repo" "$(call create_repository_ruleset '{"owner":"example-user","repo":"a-repo-created-later"}')"
check deny "write tool, no owner" "$(call add_issue_comment '{"repo":"toolkit-repo","issue_number":1,"body":"x"}')"
check allow "plain comment" "$(acall add_issue_comment '{"issue_number":1,"body":"looks good"}')"
check ask "@claude comment" "$(acall add_issue_comment '{"issue_number":1,"body":"@claude review --comments"}')"
check ask "@Claude, leading space" "$(acall add_issue_comment '{"issue_number":1,"body":"  @Claude review"}')"
check ask "@claude mid-body" "$(acall add_issue_comment '{"issue_number":1,"body":"done; @claude review"}')"
check ask "@claude in thread reply" "$(acall add_reply_to_pull_request_comment '{"commentId":5,"pullNumber":1,"body":"@claude"}')"
check allow "reaction-only reply" "$(acall add_reply_to_pull_request_comment '{"commentId":5,"reaction":"+1"}')"
check ask "rerun" "$(acall actions_run_trigger '{"method":"rerun_workflow_run","run_id":1}')"
check ask "rerun failed" "$(acall actions_run_trigger '{"method":"rerun_failed_jobs","run_id":1}')"
check ask "cancel" "$(acall actions_run_trigger '{"method":"cancel_workflow_run","run_id":1}')"
check ask "rerun in another write repo" "$(call actions_run_trigger '{"owner":"notitial","repo":"app-one","method":"rerun_workflow_run","run_id":1}')"
check ask "dispatch" "$(acall actions_run_trigger '{"method":"run_workflow","workflow_id":"x.yml","ref":"main"}')"
check deny "delete logs" "$(acall actions_run_trigger '{"method":"delete_workflow_run_logs","run_id":1}')"
check deny "unknown method" "$(acall actions_run_trigger '{"method":"something_new"}')"
check deny "no method" "$(acall actions_run_trigger '{"run_id":1}')"
check deny "method with a trailing newline" "$(acall actions_run_trigger '{"method":"rerun_workflow_run\n","run_id":1}')"
check deny "method not a string" "$(acall actions_run_trigger '{"method":["rerun_workflow_run"],"run_id":1}')"
check ask "comment body not a string" "$(acall add_issue_comment '{"issue_number":1,"body":{"text":"x"}}')"
check deny "owner not a string" "$(call create_pull_request '{"owner":["notitial"],"repo":"toolkit-repo","title":"t","head":"b","base":"main","draft":true}')"
check deny "repo with a trailing newline" "$(call create_pull_request '{"owner":"notitial","repo":"toolkit-repo\n","title":"t","head":"b","base":"main","draft":true}')"
check deny "rerun in a repo of another owner" "$(call actions_run_trigger '{"owner":"github","repo":"github-mcp-server","method":"rerun_workflow_run","run_id":1}')"
check ask "rerun in a new write-owner repo" "$(call actions_run_trigger '{"owner":"notitial","repo":"new-project","method":"rerun_workflow_run","run_id":1}')"
for t in merge_pull_request push_files create_or_update_file delete_file create_branch fork_repository create_repository delete_repository update_issue_comment update_pull_request_branch pull_request_review_write add_comment_to_pending_review issue_write create_gist create_issue update_issue run_workflow get_gist some_future_tool foo__bar; do
  check deny "unexposed $t" "$(acall "$t" '{}')"
done
check deny "github, empty tool name" '{"tool_name":"mcp__github__","tool_input":{}}'
check pass "other server untouched" '{"tool_name":"mcp__git-mcp__git_status","tool_input":{}}'

check deny "dispatch in a repo of another owner" "$(call actions_run_trigger '{"owner":"github","repo":"github-mcp-server","method":"run_workflow","workflow_id":"x.yml","ref":"main"}')"
check ask "dispatch with non-string workflow_id, ref and inputs" "$(acall actions_run_trigger '{"method":"run_workflow","workflow_id":["x"],"ref":{"a":1},"inputs":5}')"
reason=$(printf '%s' "$(acall actions_run_trigger '{"method":"run_workflow","workflow_id":"e2e.yml","ref":"feat/x","inputs":{"k":"v"}}')" | HOME="$TMP" bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason" in
  *'workflow dispatch of "e2e.yml" at ref "feat/x" with inputs {"k":"v"}'*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL: dispatch ask does not show workflow, ref and inputs: $reason" ;;
esac
dispatch_reason() {
  printf '%s' "$(acall actions_run_trigger "$1")" | HOME="$TMP" bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason'
}
long=$(printf '%0100d' 0 | tr 0 n)
reason=$(dispatch_reason "$(jq -n -c --arg n "$long" '{method:"run_workflow",workflow_id:"e2e.yml",ref:"main",inputs:{notes:$n,environment:"production"}}')")
case "$reason" in
  *'"environment":"production"'*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL: dispatch ask hides an input key past the old 80-char cut: $reason" ;;
esac
huge=$(printf '%0800d' 0 | tr 0 n)
reason=$(dispatch_reason "$(jq -n -c --arg n "$huge" '{method:"run_workflow",workflow_id:"e2e.yml",ref:"main",inputs:{notes:$n}}')")
case "$reason" in
  *'...(truncated)'*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL: a cut dispatch input carries no truncation marker: $reason" ;;
esac
check allow "retitle a PR" "$(acall update_pull_request '{"pullNumber":202,"title":"fix: shorter title"}')"
check allow "edit a PR body" "$(acall update_pull_request '{"pullNumber":202,"body":"text"}')"
check allow "mark a PR draft" "$(acall update_pull_request '{"pullNumber":202,"draft":true}')"
check ask "title, body and draft false together" "$(acall update_pull_request '{"pullNumber":202,"title":"t","body":"b","draft":false}')"
check allow "update a PR in a new write-owner repo" "$(call update_pull_request '{"owner":"notitial","repo":"new-project","pullNumber":1,"title":"t"}')"
check ask "create PR with @claude in the body" "$(acall create_pull_request '{"title":"t","body":"@Claude review","head":"b","base":"main","draft":true}')"
check ask "create PR with @claude in the title" "$(acall create_pull_request '{"title":"@claude","head":"b","base":"main","draft":true}')"
check ask "create PR with a body that is not text" "$(acall create_pull_request '{"title":"t","body":5,"head":"b","base":"main","draft":true}')"
check ask "create PR with draft left out" "$(acall create_pull_request '{"title":"t","head":"b","base":"main"}')"
check ask "create PR with draft false" "$(acall create_pull_request '{"title":"t","head":"b","base":"main","draft":false}')"
check ask "create PR with draft the string true" "$(acall create_pull_request '{"title":"t","head":"b","base":"main","draft":"true"}')"
check ask "create PR with draft null" "$(acall create_pull_request '{"title":"t","head":"b","base":"main","draft":null}')"
check allow "create draft PR" "$(acall create_pull_request '{"title":"t","head":"b","base":"main","draft":true}')"
check ask "comment with body false" "$(acall add_issue_comment '{"issue_number":1,"body":false}')"
check ask "comment with body null" "$(acall add_issue_comment '{"issue_number":1,"body":null}')"
check ask "@claude in a PR title stays ask" "$(acall update_pull_request '{"pullNumber":202,"title":"@Claude please"}')"
check ask "draft false alone stays ask" "$(acall update_pull_request '{"pullNumber":202,"draft":false}')"
check allow "thread reply without @claude" "$(acall add_reply_to_pull_request_comment '{"commentId":5,"pullNumber":1,"body":"fixed in abc123"}')"
check ask "workflow dispatch stays ask" "$(acall actions_run_trigger '{"method":"run_workflow","workflow_id":"x.yml","ref":"main"}')"
check ask "body that mentions @claude stays ask" "$(acall update_pull_request '{"pullNumber":202,"body":"@claude review"}')"
check deny "update PR: state (close)" "$(acall update_pull_request '{"pullNumber":202,"title":"t","state":"closed"}')"
check deny "update PR: state next to a title" "$(acall update_pull_request '{"pullNumber":202,"title":"t","state":"open"}')"
check deny "update PR: base" "$(acall update_pull_request '{"pullNumber":202,"title":"t","base":"release"}')"
check deny "update PR: reviewers" "$(acall update_pull_request '{"pullNumber":202,"title":"t","reviewers":["x"]}')"
check deny "update PR: maintainer_can_modify" "$(acall update_pull_request '{"pullNumber":202,"title":"t","maintainer_can_modify":false}')"
check deny "update PR: key in another case" "$(acall update_pull_request '{"pullNumber":202,"title":"t","State":"closed"}')"
check deny "update PR: unknown key" "$(acall update_pull_request '{"pullNumber":202,"title":"t","assignees":["x"]}')"
check deny "update PR: nothing to set" "$(acall update_pull_request '{"pullNumber":202}')"
check deny "update PR: no pullNumber" "$(acall update_pull_request '{"title":"t"}')"
check deny "update PR: pullNumber a string" "$(acall update_pull_request '{"pullNumber":"202","title":"t"}')"
check deny "update PR: title not a string" "$(acall update_pull_request '{"pullNumber":202,"title":["t"]}')"
check deny "update PR: title null" "$(acall update_pull_request '{"pullNumber":202,"title":null}')"
check deny "update PR: body not a string" "$(acall update_pull_request '{"pullNumber":202,"body":5}')"
check deny "update PR: draft a string" "$(acall update_pull_request '{"pullNumber":202,"draft":"false"}')"
check deny "update PR: outside the write owners" "$(call update_pull_request '{"owner":"github","repo":"github-mcp-server","pullNumber":1,"title":"t"}')"
check deny "update PR: no owner" "$(call update_pull_request '{"repo":"toolkit-repo","pullNumber":1,"title":"t"}')"
check deny "update PR: pullNumber zero" "$(acall update_pull_request '{"pullNumber":0,"title":"t"}')"
check deny "update PR: pullNumber negative" "$(acall update_pull_request '{"pullNumber":-5,"title":"t"}')"
check deny "update PR: pullNumber fractional" "$(acall update_pull_request '{"pullNumber":202.5,"title":"t"}')"
check deny "update PR: draft null" "$(acall update_pull_request '{"pullNumber":202,"draft":null}')"
check allow "update PR: empty title" "$(acall update_pull_request '{"pullNumber":202,"title":""}')"
check allow "update PR: body with newlines and accents" "$(acall update_pull_request '{"pullNumber":202,"body":"line one\n\nlíne two ✓"}')"
update_reason() {
  printf '%s' "$(acall update_pull_request "$1")" | HOME="$TMP" bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason'
}
reason=$(update_reason '{"pullNumber":202,"title":"fix: a new title"}')
case "$reason" in
  *'"notitial"/"toolkit-repo" #202 sets title "fix: a new title"'*'nothing else'*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL: update PR ask does not show the PR and the new title: $reason" ;;
esac
case "$reason" in
  '') FAIL=$((FAIL + 1)); echo "FAIL: update PR ask returned no reason" ;;
  *'body "'*|*'paid Claude review'*) FAIL=$((FAIL + 1)); echo "FAIL: update PR ask shows a field that was not set, or warns without draft false: $reason" ;;
  *) PASS=$((PASS + 1)) ;;
esac
reason=$(update_reason '{"pullNumber":202,"draft":false}')
case "$reason" in
  *'draft false'*'paid Claude review'*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL: draft false carries no paid-review warning: $reason" ;;
esac
reason=$(update_reason '{"pullNumber":202,"draft":true}')
case "$reason" in
  '') FAIL=$((FAIL + 1)); echo "FAIL: update PR draft true ask returned no reason" ;;
  *'paid Claude review'*) FAIL=$((FAIL + 1)); echo "FAIL: draft true carries the paid-review warning: $reason" ;;
  *) PASS=$((PASS + 1)) ;;
esac
reason=$(update_reason "$(jq -n -c --arg b "HEADMARK$huge" --arg t "TAILMARK" '{pullNumber:202,body:($b + $t)}')")
case "$reason" in
  *'HEADMARK'*'...(truncated)'*'TAILMARK'*'characters of JSON in all'*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL: a cut update PR body carries no truncation marker" ;;
esac
reason=$(update_reason '{"pullNumber":202,"title":"a\"; body \"(unchanged)","body":"x\u001b[31my"}')
case "$reason" in
  *'a\"; body \"(unchanged)'*'x\u001b[31my'*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL: update PR ask does not show quotes and an escape code in escaped form: $reason" ;;
esac
reason=$(update_reason '{"pullNumber":202,"state":"closed"}')
case "$reason" in
  *'"state"'*'stay with the user'*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL: update PR deny does not name the rejected key: $reason" ;;
esac

# The template's hook matcher: every tool of the github server, nothing else.
TEMPLATE="$HERE/../../.claude/skills/setup-claude/templates/safe-permissions.json"
matcher=$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command == "/bin/bash -p '"'"'<checkout>/tools/github-mcp/guard.sh'"'"' || exit 2") | .matcher' "$TEMPLATE")
if [ "$matcher" = '^mcp__github__.*$' ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: template matcher is $matcher, want ^mcp__github__.*\$"
fi
if jq -e '.permissions.deny | index("Bash(*mcp-github*)")' "$TEMPLATE" >/dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: template deny list lacks the mcp-github tripwire"
fi
check deny "malformed JSON" 'not json'
check deny "tool_name missing" '{"tool_input":{}}'

# The hook's known tools must equal the launcher's --tools list.
launch_tools=$(sed -n 's/^TOOLS=//p' "$HERE/launch" | tr ',' '\n' | sort)
hook_tools=$(sed -n -E 's/^(READ|WRITE)_TOOLS="(.*)"$/\2/p' "$SRC" | tr ' ' '\n' | sed '/^$/d' | sort)
if [ -n "$launch_tools" ] && [ "$launch_tools" = "$hook_tools" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: launcher --tools and hook known tools differ"
  diff <(printf '%s\n' "$launch_tools") <(printf '%s\n' "$hook_tools")
fi

# Audit: a deny reaches the logger at $HOME/.claude/hooks/audit-logger.sh (detached, after the decision).
mkdir -p "$TMP/.claude/hooks"
printf '#!/bin/bash\ncat > "%s/out-audit"\n' "$TMP" > "$TMP/.claude/hooks/audit-logger.sh"
printf '%s' '{"tool_name":"mcp__github__merge_pull_request","tool_input":{}}' | HOME="$TMP" bash "$HOOK" > /dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/out-audit" ] && break; sleep 0.2; done
if jq -e '._audit_event == "deny" and ._deny_hook == "github-mcp-guard"' "$TMP/out-audit" > /dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: a deny did not reach the audit logger"
fi
rm -f "$TMP/.claude/hooks/audit-logger.sh"
rmdir "$TMP/.claude/hooks"

# The guard runs from the live checkout: it must sit on a clean main, or every github call is denied, reads included.
READ_CALL=$(acall pull_request_read '{"method":"get","pullNumber":1}')
WRITE_CALL=$(acall create_pull_request '{"title":"t","head":"b","base":"main","draft":true}')
check pass "clean main: a read passes" "$READ_CALL"
check allow "clean main: a draft PR in a write-owner repo is allowed" "$WRITE_CALL"
printf 'untracked\n' > "$CO/untracked-file"
check pass "an untracked file does not turn the guard off" "$READ_CALL"
rm -f "$CO/untracked-file"
printf 'edited\n' >> "$CO/README"
check deny "a tracked file with an edit turns the guard off (read)" "$READ_CALL"
check deny "a tracked file with an edit turns the guard off (write)" "$WRITE_CALL"
"${GIT_Q[@]}" checkout -q -- README
check pass "edit undone: the read passes again" "$READ_CALL"
"${GIT_Q[@]}" checkout -q -b topic
check deny "a branch other than main turns the guard off (read)" "$READ_CALL"
check deny "a branch other than main turns the guard off (write)" "$WRITE_CALL"
"${GIT_Q[@]}" checkout -q main
check pass "back on main: the read passes" "$READ_CALL"
# HEAD must be on origin/main: a commit made locally and never pushed is not reviewed code; main behind origin is.
printf 'local\n' >> "$CO/README"
"${GIT_Q[@]}" commit -q -am local
check deny "a local commit on main that origin/main lacks turns the guard off (read)" "$READ_CALL"
check deny "a local commit on main that origin/main lacks turns the guard off (write)" "$WRITE_CALL"
"${GIT_Q[@]}" update-ref refs/remotes/origin/main HEAD
check pass "the same commit once it is on origin/main: the read passes" "$READ_CALL"
AHEAD=$("${GIT_Q[@]}" commit-tree 'HEAD^{tree}' -p HEAD -m ahead)
"${GIT_Q[@]}" update-ref refs/remotes/origin/main "$AHEAD"
check pass "main behind origin/main (not pulled yet): the read passes" "$READ_CALL"
"${GIT_Q[@]}" update-ref -d refs/remotes/origin/main
check deny "no origin/main ref: the guard is off" "$READ_CALL"
"${GIT_Q[@]}" update-ref refs/remotes/origin/main HEAD
check pass "origin/main back: the read passes" "$READ_CALL"
# The two files that execute must equal their committed blobs, even when git is told to ignore the change.
for f in guard.sh launch; do
  "${GIT_Q[@]}" update-index --skip-worktree "tools/github-mcp/$f"
  printf '# edited\n' >> "$CO/tools/github-mcp/$f"
  check deny "an edit of $f hidden by skip-worktree turns the guard off" "$READ_CALL"
  "${GIT_Q[@]}" update-index --no-skip-worktree "tools/github-mcp/$f"
  "${GIT_Q[@]}" checkout -q -- "tools/github-mcp/$f"
done
check pass "edits undone: the read passes" "$READ_CALL"
# The hook's own environment must not steer the check: GIT_DIR and friends point nowhere.
out=$(printf '%s' "$READ_CALL" | env GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=/bin/false DEVELOPER_DIR=/nonexistent HOME="$TMP" bash "$HOOK" 2>/dev/null)
if [ -z "$out" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: GIT_* and DEVELOPER_DIR in the hook's environment steered the checkout test: $out"; fi
# .git/config is one file edit away: a clean filter, an fsmonitor or a work tree planted there must neither run nor
# redirect the check. The harness's own git calls would run them, so the plant is removed before the next one.
plant_config() {  # plant_config <checkout>: a filter that would make an edited README look committed, and friends
  cp "$1/.git/config" "$TMP/config.saved"
  cp "$1/README" "$TMP/readme.saved"
  mkdir -p "$1/.git/info" "$TMP/elsewhere"
  printf '[filter "x"]\n\tclean = touch %s/filter-ran; cat %s/readme.saved\n[core]\n\tfsmonitor = touch %s/fsmonitor-ran\n\tworktree = %s/elsewhere\n' \
    "$TMP" "$TMP" "$TMP" "$TMP" >> "$1/.git/config"
  printf '* filter=x\n' > "$1/.git/info/attributes"
  rm -f "$TMP/filter-ran" "$TMP/fsmonitor-ran"
}
unplant_config() {  # unplant_config <checkout>
  cp "$TMP/config.saved" "$1/.git/config"
  rm -f "$1/.git/info/attributes"
  cp "$TMP/readme.saved" "$1/README"
}
noexec() { [ ! -e "$TMP/filter-ran" ] && [ ! -e "$TMP/fsmonitor-ran" ]; }
plant_config "$CO"
cat "$TMP/readme.saved" > "$CO/README"
check pass "planted filter, fsmonitor and work tree: an unchanged (stat-dirty) file still passes" "$READ_CALL"
if noexec; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: the guard ran a filter or fsmonitor from .git/config"; fi
printf 'edited behind a filter\n' >> "$CO/README"
check deny "an edit a planted clean filter would hide still denies" "$READ_CALL"
if noexec; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: the guard ran a filter or fsmonitor from .git/config (edited file)"; fi
unplant_config "$CO"
check pass "plant removed: the read passes" "$READ_CALL"
# A replace ref could make HEAD read as a commit holding an edit, while HEAD and origin/main keep their real ids.
printf 'forged\n' >> "$CO/README"
"${GIT_Q[@]}" add README
FORGED=$("${GIT_Q[@]}" commit-tree "$("${GIT_Q[@]}" write-tree)" -m forged)
"${GIT_Q[@]}" replace HEAD "$FORGED"
check deny "an edit hidden behind a replace ref of HEAD denies" "$READ_CALL"
"${GIT_Q[@]}" replace -d HEAD >/dev/null
"${GIT_Q[@]}" reset -q --hard HEAD
check pass "replace ref removed: the read passes" "$READ_CALL"
# A promisor remote in .git/config would make git fetch a missing object from inside a read command, running the
# remote's upload-pack command: no lazy fetch and no transport may run.
plant_promisor() {  # plant_promisor <checkout>: main points at a missing object, origin is a promisor
  cp "$1/.git/config" "$TMP/config.saved"
  MAIN_SAVED=$(cat "$1/.git/refs/heads/main" 2>/dev/null || git -C "$1" rev-parse refs/heads/main)
  git init -q --bare "$TMP/promisor.git" 2>/dev/null
  printf '[core]\n\trepositoryformatversion = 1\n[extensions]\n\tpartialClone = origin\n[remote "origin"]\n\turl = %s/promisor.git\n\tpromisor = true\n\tuploadpack = touch %s/fetch-ran; git-upload-pack\n' \
    "$TMP" "$TMP" >> "$1/.git/config"
  printf '1234567890123456789012345678901234567890\n' > "$1/.git/refs/heads/main"
  rm -f "$TMP/fetch-ran"
}
unplant_promisor() {  # unplant_promisor <checkout>
  printf '%s\n' "$MAIN_SAVED" > "$1/.git/refs/heads/main"
  cp "$TMP/config.saved" "$1/.git/config"
}
plant_promisor "$CO"
check deny "a promisor remote and a missing object: denies" "$READ_CALL"
if [ ! -e "$TMP/fetch-ran" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: the guard ran a lazy fetch's upload-pack command from .git/config"; fi
unplant_promisor "$CO"
check pass "promisor removed: the read passes" "$READ_CALL"
# A copy of the guard elsewhere in the checkout must not pass on the real files.
mkdir -p "$CO/.archive/x"
cp "$CO/tools/github-mcp/guard.sh" "$CO/.archive/x/guard.sh"
out=$(printf '%s' "$READ_CALL" | HOME="$TMP" bash "$CO/.archive/x/guard.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$out" = deny ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: a guard copy two folders below the checkout root passed: '$out'"; fi
rm -rf "$CO/.archive"
# The check is one block, kept identical in the guard and the launcher.
if diff <(sed -n '/^# >>> reviewed-code check/,/^# <<< reviewed-code check/p' "$SRC") \
        <(sed -n '/^# >>> reviewed-code check/,/^# <<< reviewed-code check/p' "$HERE/launch") >/dev/null \
   && [ -n "$(sed -n '/^# >>> reviewed-code check/p' "$SRC")" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: the reviewed-code check differs between guard.sh and launch"
fi
mkdir -p "$TMP/nogit/a/b" && cp "$SRC" "$TMP/nogit/a/b/guard.sh"
HOOK_REAL=$HOOK
HOOK="$TMP/nogit/a/b/guard.sh"
check deny "a guard outside any git checkout is off (read)" "$READ_CALL"
HOOK=$HOOK_REAL

# The owners come from ~/.claude/install.conf at call time; a missing or invalid setting denies owner-bearing writes.
write_conf 'github_write_owners=notitial' 'github_keychain_account=test-account'
check deny "an owner missing from install.conf is denied" "$(call create_pull_request '{"owner":"example-user","repo":"r","title":"t","head":"b","base":"main","draft":true}')"
check allow "an owner listed in install.conf passes" "$WRITE_CALL"
for bad in 'github_write_owners=' 'github_write_owners=Notitial' 'github_write_owners=notitial;x' 'github_write_owners=notitial  example-user' \
  'github_write_owners=-notitial' 'github_write_owners=["notitial"]' 'github_write_owners=notitial/x'; do
  write_conf "$bad"
  check deny "invalid owners ($bad): an owner-bearing write is denied" "$WRITE_CALL"
  check pass "invalid owners ($bad): a read still passes" "$READ_CALL"
done
write_conf 'github_keychain_account=test-account'
check deny "no owners line: an owner-bearing write is denied" "$WRITE_CALL"
rm -f "$TMP/.claude/install.conf"
check deny "no install.conf: an owner-bearing write is denied" "$WRITE_CALL"
check pass "no install.conf: a read still passes" "$READ_CALL"
write_conf 'github_write_owners=evil-owner' 'github_write_owners=notitial'
check deny "only the first owners line counts" "$WRITE_CALL"
write_conf 'github_write_owners=notitial example-user' 'github_keychain_account=test-account'

# Launcher: run a copy inside a throwaway checkout, with stand-ins for security and the server, under a hostile
# environment. Each stand-in records what it saw; the keychain call and the settings path are swapped for the temp folder.
LC="$TMP/lc"
L="$LC/tools/github-mcp"
mkdir -p "$L/bin"
# The launcher is macOS-only (dscl, getconf DARWIN_USER_TEMP_DIR, the keychain, /var/empty). Elsewhere (the Linux CI
# job) the copy also swaps the first, second and last for stand-ins, so the rest of the launcher is still tested; on
# macOS they stay real. PLATFORM_OVERRIDE=Linux on a Mac tries the swapped copy locally.
PLATFORM=${PLATFORM_OVERRIDE:-$(uname -s)}
SWAPS=(-e "s|/usr/bin/security find-generic-password -s mcp-github -a \"\$acct\" -w|\"\$DIR/fake-security\" \"\$acct\"|"
       -e "s|\"\$HOME/.claude/install.conf\"|\"$LC/install.conf\"|")
if [ "$PLATFORM" = Darwin ]; then
  EXPECT_HOME=$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | sed -n "s/^NFSHomeDirectory: //p")
  EXPECT_TMPDIR=$(getconf DARWIN_USER_TEMP_DIR)
  EMPTY_DIRS=(/var/empty /private/var/empty)
else
  EXPECT_HOME="$TMP/fakehome"
  EXPECT_TMPDIR="$TMP/faketmp"
  mkdir -p "$TMP/empty"
  EMPTY_DIRS=("$(cd -P "$TMP/empty" && pwd -P)")
  SWAPS+=(-e "s|/usr/bin/dscl . -read \"/Users/\$user\" NFSHomeDirectory|\"\$DIR/fake-dscl\"|"
          -e "s|/usr/bin/getconf DARWIN_USER_TEMP_DIR|\"\$DIR/fake-getconf\"|"
          -e "s|cd /var/empty|cd \"$TMP/empty\"|")
fi
sed "${SWAPS[@]}" "$HERE/launch" > "$L/launch"
printf '#!/bin/sh\nprintf "NFSHomeDirectory: %%s\\n" "%s"\n' "$EXPECT_HOME" > "$L/fake-dscl"
printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$EXPECT_TMPDIR" > "$L/fake-getconf"
printf '#!/bin/sh\nprintf %%s "$1" > "%s/out-account"\nprintf %%s tok-FAKE-123\n' "$TMP" > "$L/fake-security"
printf '#!/bin/sh\n/usr/bin/env > "%s/out-vars"\npwd > "%s/out-cwd"\nprintf "%%s\\n" "$@" > "%s/out-args"\n' "$TMP" "$TMP" "$TMP" > "$L/bin/github-mcp-server"
chmod 755 "$L/launch" "$L/fake-security" "$L/fake-dscl" "$L/fake-getconf" "$L/bin/github-mcp-server"
printf 'github_keychain_account=test-account\n' > "$LC/install.conf"
printf 'tracked\n' > "$LC/README"
cp "$SRC" "$L/guard.sh"
# The pin the launcher checks: one shasum line for the (untracked) fake server, committed like the real one.
(cd "$L/bin" && /usr/bin/shasum -a 256 github-mcp-server) > "$L/server.sha256"
GIT_L=(git -C "$LC" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false)
"${GIT_L[@]}" init -q -b main && "${GIT_L[@]}" add README tools/github-mcp/launch tools/github-mcp/guard.sh tools/github-mcp/server.sha256 && "${GIT_L[@]}" commit -q -m init && "${GIT_L[@]}" update-ref refs/remotes/origin/main HEAD || { echo "ABORT: cannot build the launcher checkout"; exit 1; }
# Abort unless both swaps took: otherwise the copy would read the real keychain or the real settings file.
if ! grep -q 'fake-security' "$L/launch" || ! grep -q "$LC/install.conf" "$L/launch" || grep -q -e /usr/bin/security -e '"$HOME/.claude/install.conf"' "$L/launch"; then
  echo "ABORT: the launcher copy still points at the real keychain or settings file; fix the sed in this test"
  exit 1
fi
if [ "$PLATFORM" != Darwin ] && { ! grep -q 'fake-dscl' "$L/launch" || ! grep -q 'fake-getconf' "$L/launch" || grep -q -e /usr/bin/dscl -e DARWIN_USER_TEMP_DIR -e /var/empty "$L/launch"; }; then
  echo "ABORT: the launcher copy still calls dscl, getconf or /var/empty; fix the sed in this test"
  exit 1
fi
lcheck() {
  if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: launcher: $1"; fi
}
run_launch() { rm -f "$TMP"/out-*; (cd / && "$L/launch") > /dev/null 2> "$TMP/out-stderr"; }
(cd / && env SHELLOPTS=xtrace 'BASH_FUNC_cd%%=() { builtin cd /tmp; }' IFS=x GITHUB_HOST=evil.example \
  GITHUB_TOOLS=all GITHUB_TOOLSETS=all GITHUB_MCP_TOOL_GET_ME_DESCRIPTION=injected BASH_ENV=/dev/null \
  ENV=/dev/null HOME=/nonexistent TMPDIR=/nonexistent "$L/launch") > "$TMP/out-stdout" 2> "$TMP/out-stderr"
lcheck "exit status 0" '[ $? -eq 0 ]'
lcheck "no token or trace on stderr" '! grep -q -e tok-FAKE -e "^+" "$TMP/out-stderr"'
lcheck "server cwd is the empty root-owned folder" '[ "$(cat "$TMP/out-cwd" 2>/dev/null)" = "${EMPTY_DIRS[0]}" ] || [ "$(cat "$TMP/out-cwd" 2>/dev/null)" = "${EMPTY_DIRS[1]:-${EMPTY_DIRS[0]}}" ]'
lcheck "keychain account read from the settings file" '[ "$(cat "$TMP/out-account" 2>/dev/null)" = test-account ]'
lcheck "token passed in the environment" 'grep -qx "GITHUB_PERSONAL_ACCESS_TOKEN=tok-FAKE-123" "$TMP/out-vars"'
lcheck "no other GITHUB_ or shell-injection vars" '! grep -v "^GITHUB_PERSONAL_ACCESS_TOKEN=" "$TMP/out-vars" | grep -q -E "^(GITHUB_|SHELLOPTS=|BASH_FUNC|BASH_ENV=|ENV=|IFS=)"'
lcheck "HOME from the user record" '[ "$(sed -n "s/^HOME=//p" "$TMP/out-vars")" = "$EXPECT_HOME" ]'
lcheck "TMPDIR from getconf" '[ "$(sed -n "s/^TMPDIR=//p" "$TMP/out-vars")" = "$EXPECT_TMPDIR" ]'
lcheck "PATH fixed" 'grep -qx "PATH=/usr/bin:/bin" "$TMP/out-vars"'
lcheck "server args fixed" '[ "$(tr "\n" " " < "$TMP/out-args")" = "stdio --tools $(sed -n "s/^TOOLS=//p" "$HERE/launch") " ]'
printf 'untracked\n' > "$LC/untracked-file"
run_launch
lcheck "an untracked file does not stop it" '[ $? -eq 0 ] && [ -e "$TMP/out-vars" ]'
rm -f "$LC/untracked-file"
printf '#!/bin/sh\nexit 44\n' > "$L/fake-security"
run_launch
lcheck "no token: refuses to start" '[ $? -ne 0 ] && grep -q "refusing to start" "$TMP/out-stderr" && [ ! -e "$TMP/out-vars" ]'
printf '#!/bin/sh\nprintf %%s "$1" > "%s/out-account"\nprintf %%s tok-FAKE-123\n' "$TMP" > "$L/fake-security"
for bad in 'a b' 'x;y' '' '$(id)'; do
  printf 'github_keychain_account=%s\n' "$bad" > "$LC/install.conf"
  run_launch
  lcheck "invalid account ($bad): refuses to start" '[ $? -ne 0 ] && grep -q "github_keychain_account" "$TMP/out-stderr" && [ ! -e "$TMP/out-vars" ] && [ ! -e "$TMP/out-account" ]'
done
rm -f "$LC/install.conf"
run_launch
lcheck "no settings file: refuses to start" '[ $? -ne 0 ] && grep -q "github_keychain_account" "$TMP/out-stderr" && [ ! -e "$TMP/out-vars" ]'
printf 'github_keychain_account=test-account\n' > "$LC/install.conf"
printf 'edited\n' >> "$LC/README"
run_launch
lcheck "a tracked file with an edit: refuses to start" '[ $? -ne 0 ] && grep -q "not reviewed code" "$TMP/out-stderr" && [ ! -e "$TMP/out-vars" ]'
"${GIT_L[@]}" checkout -q -- README
"${GIT_L[@]}" checkout -q -b topic
run_launch
lcheck "a branch other than main: refuses to start" '[ $? -ne 0 ] && grep -q "not reviewed code" "$TMP/out-stderr" && [ ! -e "$TMP/out-vars" ]'
"${GIT_L[@]}" checkout -q main
run_launch
lcheck "back on a clean main: starts again" '[ $? -eq 0 ] && [ -e "$TMP/out-vars" ]'
# HEAD must be on origin/main.
printf 'local\n' >> "$LC/README"
"${GIT_L[@]}" commit -q -am local
run_launch
lcheck "a local commit that origin/main lacks: refuses to start" '[ $? -ne 0 ] && grep -q "not reviewed code" "$TMP/out-stderr" && [ ! -e "$TMP/out-vars" ]'
"${GIT_L[@]}" update-ref refs/remotes/origin/main HEAD
run_launch
lcheck "the same commit on origin/main: starts" '[ $? -eq 0 ] && [ -e "$TMP/out-vars" ]'
# The files that execute, and the pin, must equal their committed blobs even when git is told to ignore a change.
for f in launch guard.sh server.sha256; do
  "${GIT_L[@]}" update-index --skip-worktree "tools/github-mcp/$f"
  cp "$L/$f" "$TMP/saved-$f"
  printf '# edited\n' >> "$L/$f"
  run_launch
  lcheck "an edit of $f hidden by skip-worktree: refuses to start" '[ $? -ne 0 ] && [ ! -e "$TMP/out-vars" ]'
  cp "$TMP/saved-$f" "$L/$f"
  "${GIT_L[@]}" update-index --no-skip-worktree "tools/github-mcp/$f"
done
run_launch
lcheck "edits undone: starts again" '[ $? -eq 0 ] && [ -e "$TMP/out-vars" ]'
# The server binary must match the pinned hash: a swap is caught before anything runs with the token.
cp "$L/bin/github-mcp-server" "$TMP/saved-server"
printf '#!/bin/sh\ntouch "%s/evil-ran"\n' "$TMP" > "$L/bin/github-mcp-server"
chmod 755 "$L/bin/github-mcp-server"
run_launch
lcheck "a swapped server binary: refuses to start, never runs it" '[ $? -ne 0 ] && grep -q "does not match" "$TMP/out-stderr" && [ ! -e "$TMP/evil-ran" ] && [ ! -e "$TMP/out-vars" ]'
rm -f "$L/bin/github-mcp-server"
run_launch
lcheck "no server binary: refuses to start" '[ $? -ne 0 ] && grep -q "does not match" "$TMP/out-stderr"'
cp "$TMP/saved-server" "$L/bin/github-mcp-server"
chmod 755 "$L/bin/github-mcp-server"
# A malformed pin that is committed and on origin/main: only the pin check can refuse.
printf 'not-a-hash  github-mcp-server\n' > "$L/server.sha256"
"${GIT_L[@]}" commit -q -am badpin
"${GIT_L[@]}" update-ref refs/remotes/origin/main HEAD
run_launch
lcheck "a malformed committed pin: refuses to start at the pin check" '[ $? -ne 0 ] && grep -q "does not match" "$TMP/out-stderr" && [ ! -e "$TMP/out-vars" ]'
(cd "$L/bin" && /usr/bin/shasum -a 256 github-mcp-server) > "$L/server.sha256"
"${GIT_L[@]}" commit -q -am goodpin
"${GIT_L[@]}" update-ref refs/remotes/origin/main HEAD
run_launch
lcheck "pin restored: starts again" '[ $? -eq 0 ] && [ -e "$TMP/out-vars" ]'
# A tool on the caller's PATH must not decide where the launcher looks for itself.
mkdir -p "$TMP/evilbin"
printf '#!/bin/sh\ntouch "%s/evil-dirname"\nprintf /tmp/evil\n' "$TMP" > "$TMP/evilbin/dirname"
chmod 755 "$TMP/evilbin/dirname"
rm -f "$TMP"/out-*
(cd / && env PATH="$TMP/evilbin:$PATH" "$L/launch") > /dev/null 2> "$TMP/out-stderr"
lcheck "a dirname earlier on PATH is not used" '[ $? -eq 0 ] && [ ! -e "$TMP/evil-dirname" ] && [ -e "$TMP/out-vars" ]'
# The launcher's check runs no filter or fsmonitor planted in .git/config either.
plant_config "$LC"
printf 'edited behind a filter\n' >> "$LC/README"
run_launch
lcheck "an edit a planted clean filter would hide: refuses to start, runs nothing from .git/config" '[ $? -ne 0 ] && noexec && [ ! -e "$TMP/out-vars" ]'
cat "$TMP/readme.saved" > "$LC/README"
rm -f "$TMP/filter-ran" "$TMP/fsmonitor-ran"
run_launch
lcheck "planted config, unchanged file: starts, runs nothing from .git/config" '[ $? -eq 0 ] && noexec && [ -e "$TMP/out-vars" ]'
unplant_config "$LC"
plant_promisor "$LC"
run_launch
lcheck "a promisor remote and a missing object: refuses to start, runs no fetch" '[ $? -ne 0 ] && [ ! -e "$TMP/fetch-ran" ] && [ ! -e "$TMP/out-vars" ]'
unplant_promisor "$LC"
run_launch
lcheck "promisor removed: starts again" '[ $? -eq 0 ] && [ -e "$TMP/out-vars" ]'
# A copy of the launcher elsewhere in the checkout refuses: it would read the pin and binary beside itself.
mkdir -p "$LC/.archive/x/bin"
cp "$L/launch" "$L/server.sha256" "$LC/.archive/x/"
cp "$L/bin/github-mcp-server" "$LC/.archive/x/bin/"
rm -f "$TMP"/out-*
(cd / && "$LC/.archive/x/launch") > /dev/null 2> "$TMP/out-stderr"
lcheck "a launcher copy two folders below the root: refuses to start" '[ $? -ne 0 ] && [ ! -e "$TMP/out-vars" ]'
rm -rf "$LC/.archive"
# A checkout path with a space gets no guard hook from /setup-claude, so the launcher refuses to start from it.
mkdir -p "$TMP/with space"
cp -R "$LC" "$TMP/with space/lc"
rm -f "$TMP"/out-*
(cd / && "$TMP/with space/lc/tools/github-mcp/launch") > /dev/null 2> "$TMP/out-stderr"
lcheck "a checkout path with a space: refuses to start" '[ $? -ne 0 ] && grep -q "not a plain path" "$TMP/out-stderr" && [ ! -e "$TMP/out-vars" ]'

# Nothing is rendered or root-installed any more: no placeholder, no install path left in either file.
if ! grep -q '__[A-Z][A-Z0-9_]*__' "$SRC" "$HERE/launch"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: a placeholder is left in guard.sh or launch"
fi
if ! grep -q 'libexec' "$SRC" "$HERE/launch"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: guard.sh or launch still names the root install folder"
fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
