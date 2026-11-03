#!/bin/bash
# Tests for tools/github-mcp/guard.sh and launch. Run: bash tools/github-mcp/test-guard.sh
# Hook cases expect deny, ask, or pass (no output = defer to the permission rules).
# Writes the guard lets through return ask; reads pass.

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/guard.sh"
# Run a copy with HOME pointed away, so its deny path never writes to the live audit log.
TMP=$(mktemp -d)
cleanup() {
  rm -f "$TMP"/L/* "$TMP"/github-mcp-guard.sh "$TMP"/out-*
  rmdir "$TMP/L" "$TMP" 2>/dev/null
}
trap cleanup EXIT
# The guard carries a placeholder owner list that ghm-install fills from ~/.claude/install.conf; the copy under test is
# rendered with the fixture owners notitial and example-user.
sed 's|__GITHUB_WRITE_OWNERS__|["notitial","example-user"]|' "$SRC" > "$TMP/github-mcp-guard.sh"
HOOK="$TMP/github-mcp-guard.sh"
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
check ask "create PR with @claude in the body" "$(acall create_pull_request '{"title":"t","body":"@Claude review","head":"b","base":"main"}')"
check ask "create PR with @claude in the title" "$(acall create_pull_request '{"title":"@claude","head":"b","base":"main"}')"
check ask "create PR with draft left out" "$(acall create_pull_request '{"title":"t","head":"b","base":"main"}')"
check ask "create PR with draft false" "$(acall create_pull_request '{"title":"t","head":"b","base":"main","draft":false}')"
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
matcher=$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command == "/usr/local/libexec/mcp-github/guard.sh") | .matcher' "$TEMPLATE")
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
rmdir "$TMP/.claude/hooks" "$TMP/.claude"

# Launcher: run a copy with stand-ins for security and the server, under a hostile environment.
# Each stand-in records what it saw; the real paths are swapped for the temp folder.
mkdir "$TMP/L"
L="$TMP/L"
sed -e "s|^DIR=.*|DIR=$L|" \
    -e "s|/usr/bin/security find-generic-password -s mcp-github -a __GITHUB_KEYCHAIN_ACCOUNT__ -w|\"\$DIR/fake-security\"|" \
    "$HERE/launch" > "$L/launch"
printf '#!/bin/sh\nprintf %%s tok-FAKE-123\n' > "$L/fake-security"
printf '#!/bin/sh\n/usr/bin/env > "%s/out-vars"\npwd > "%s/out-cwd"\nprintf "%%s\\n" "$@" > "%s/out-args"\n' "$TMP" "$TMP" "$TMP" > "$L/github-mcp-server"
chmod 755 "$L/launch" "$L/fake-security" "$L/github-mcp-server"
# Abort unless both swaps took: otherwise the copy would read the real keychain or exec the installed launcher.
if ! grep -q 'fake-security' "$L/launch" || grep -q -e /usr/bin/security -e '^DIR=/usr/local' "$L/launch"; then
  echo "ABORT: the launcher copy still points at the real keychain or install path; fix the sed in this test"
  exit 1
fi
lcheck() {
  if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: launcher: $1"; fi
}
(cd / && env SHELLOPTS=xtrace 'BASH_FUNC_cd%%=() { builtin cd /tmp; }' IFS=x GITHUB_HOST=evil.example \
  GITHUB_TOOLS=all GITHUB_TOOLSETS=all GITHUB_MCP_TOOL_GET_ME_DESCRIPTION=injected BASH_ENV=/dev/null \
  ENV=/dev/null HOME=/nonexistent TMPDIR=/nonexistent "$L/launch") > "$TMP/out-stdout" 2> "$TMP/out-stderr"
lcheck "exit status 0" '[ $? -eq 0 ]'
lcheck "no token or trace on stderr" '! grep -q -e tok-FAKE -e "^+" "$TMP/out-stderr"'
lcheck "server cwd is its own folder" '[ "$(cat "$TMP/out-cwd" 2>/dev/null)" = "$(cd "$L" && pwd -P)" ] || [ "$(cat "$TMP/out-cwd" 2>/dev/null)" = "$L" ]'
lcheck "token passed in the environment" 'grep -qx "GITHUB_PERSONAL_ACCESS_TOKEN=tok-FAKE-123" "$TMP/out-vars"'
lcheck "no other GITHUB_ or shell-injection vars" '! grep -v "^GITHUB_PERSONAL_ACCESS_TOKEN=" "$TMP/out-vars" | grep -q -E "^(GITHUB_|SHELLOPTS=|BASH_FUNC|BASH_ENV=|ENV=|IFS=)"'
lcheck "HOME from the user record" '[ "$(sed -n "s/^HOME=//p" "$TMP/out-vars")" = "$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | sed -n "s/^NFSHomeDirectory: //p")" ]'
lcheck "TMPDIR from getconf" '[ "$(sed -n "s/^TMPDIR=//p" "$TMP/out-vars")" = "$(getconf DARWIN_USER_TEMP_DIR)" ]'
lcheck "PATH fixed" 'grep -qx "PATH=/usr/bin:/bin" "$TMP/out-vars"'
lcheck "server args fixed" '[ "$(tr "\n" " " < "$TMP/out-args")" = "stdio --lockdown-mode --tools $(sed -n "s/^TOOLS=//p" "$HERE/launch") " ]'
printf '#!/bin/sh\nexit 44\n' > "$L/fake-security"
rm -f "$TMP"/out-*
(cd / && "$L/launch") > /dev/null 2> "$TMP/out-stderr"
lcheck "no token: refuses to start" '[ $? -ne 0 ] && grep -q "refusing to start" "$TMP/out-stderr" && [ ! -e "$TMP/out-vars" ]'

# Install-time settings: the shipped guard and launcher hold placeholders that ghm-install fills from
# ~/.claude/install.conf. An unrendered guard fails closed; each placeholder sits only where the render expects it.
HOOK_RENDERED=$HOOK
cp "$SRC" "$TMP/out-unrendered-guard.sh"
HOOK="$TMP/out-unrendered-guard.sh"
check deny "unrendered guard: an owner-bearing write is denied" "$(acall create_pull_request '{"title":"t","head":"b","base":"main","draft":true}')"
check pass "unrendered guard: a read still passes" "$(acall pull_request_read '{"method":"get","pullNumber":1}')"
HOOK=$HOOK_RENDERED
rm -f "$TMP/out-unrendered-guard.sh"
if [ "$(grep -c '__GITHUB_WRITE_OWNERS__' "$SRC")" = 1 ] && grep -qx "WRITE_OWNERS='__GITHUB_WRITE_OWNERS__'" "$SRC"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: guard.sh does not hold its owner placeholder exactly once, as WRITE_OWNERS"
fi
if [ "$(grep -c '__GITHUB_KEYCHAIN_ACCOUNT__' "$HERE/launch")" = 2 ] && grep -q -- '-a __GITHUB_KEYCHAIN_ACCOUNT__ -w' "$HERE/launch"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: launch does not hold its account placeholder on exactly its two lines (the keychain read and its error)"
fi
if ! grep -q '__[A-Z][A-Z0-9_]*__' "$HOOK"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: the rendered copy under test still holds a placeholder"
fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
