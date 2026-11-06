#!/bin/bash -p
# Pre-tool-use hook: guards the github MCP server (github/github-mcp-server) by argument, where tool-name permission
# rules cannot reach (v2 bundles reads and writes behind a `method` argument). Runs from the live checkout
# (tools/github-mcp/guard.sh), wired in ~/.claude/settings.json for PreToolUse on ^mcp__github__.*$.
#
# - Every call is denied unless the checkout this file sits in is reviewed code: on main with no tracked change, HEAD
#   on origin/main, and this file and launch equal to their committed blobs. A branch, a half-done edit or a local
#   commit of the guard would otherwise go live.
# - Reads pass. A tool in neither READ_TOOLS nor WRITE_TOOLS is denied, so a server upgrade stays shut until reviewed.
# - Every write must target a repo of WRITE_OWNERS.
# - actions_run_trigger: re-run, re-run failed jobs, cancel and dispatch ask; log deletion is denied.
# - update_pull_request may set only title, body and draft, and asks with the new text shown.
# - create_pull_request, add_issue_comment, add_reply_to_pull_request_comment and update_pull_request are allowed,
#   except that a mention of @claude (a paid review run), a body that is not text, or draft set to false asks;
#   create_pull_request also asks unless draft is true, since a ready PR starts the automatic paid review.
#   Every other write asks.
#
# Fails closed on what it handles (missing jq, unreadable input, odd argument types). A missing or crashed hook
# cannot fail closed: the writes then fall back to the default prompt. Runs under `bash -p` with a fixed PATH and an
# absolute jq. Reads JSON from stdin; prints a decision or nothing; exit 0 always (no set -e).

STATIC_DENY='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"github-mcp-guard: could not build a decision - github MCP call blocked (fail-closed)."}}'

PATH=/usr/bin:/bin
JQ=/usr/bin/jq
# The hook inherits the session's environment: drop what steers git (GIT_DIR, GIT_WORK_TREE, GIT_CONFIG_*, ...) and the
# developer-tools lookup behind /usr/bin/git, so the checkout test below reads the real checkout.
for _v in $(/usr/bin/env | /usr/bin/sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
unset DEVELOPER_DIR _v

if [ ! -x "$JQ" ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"github-mcp-guard: jq unavailable - github MCP calls blocked (fail-closed)."}}'
  exit 0
fi

INPUT=$(cat)

audit_deny() {
  local logger
  logger="$HOME/.claude/hooks/audit-logger.sh"
  [ -r "$logger" ] || return 0
  printf '%s' "$INPUT" \
    | "$JQ" -c --arg r "$1" --arg h "github-mcp-guard" \
        '. + {_audit_event:"deny",_deny_reason:$r,_deny_hook:$h}' 2>/dev/null \
    | /bin/bash -p "$logger" >/dev/null 2>&1 || true
}

# Print the decision first; the audit record runs detached afterwards, so a
# slow logger cannot push the hook past its timeout and lose the decision.
decide() {
  "$JQ" -n --arg d "$1" --arg reason "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: ("github-mcp-guard: " + $reason)
    }
  }' 2>/dev/null || printf '%s\n' "$STATIC_DENY"
  [ "$1" = deny ] && (audit_deny "$2" </dev/null >/dev/null 2>&1 &)
  exit 0
}

if ! printf '%s' "$INPUT" | "$JQ" -e 'type == "object" and (.tool_name | type == "string")' >/dev/null 2>&1; then
  decide deny "unreadable hook input; blocked (fail-closed)."
fi

# jq exit status is the test; -e makes false/null/error non-zero.
jqtest() { printf '%s' "$INPUT" | "$JQ" -e "$@" >/dev/null 2>&1; }
# A short, JSON-quoted view of an argument for reason strings.
show() { printf '%s' "$INPUT" | "$JQ" -r "$1 | tojson | .[0:80]" 2>/dev/null; }
# Like show, with a longer limit ($2) and an explicit marker when it cuts, for the fields an approver must read whole.
showfull() { printf '%s' "$INPUT" | "$JQ" -r --argjson n "$2" "$1 | tojson | if length > \$n then .[0:\$n] + \"...(truncated)\" else . end" 2>/dev/null; }

TOOL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name')
# Everything after the prefix is the tool name. Other MCP servers are not judged here.
case "$TOOL_NAME" in
  mcp__github__*) TOOL="${TOOL_NAME#mcp__github__}" ;;
  *) exit 0 ;;
esac

# The checkout this file sits in must be reviewed code: on main, every tracked file equal to its blob at HEAD, HEAD on
# origin/main (a commit made locally and never pushed does not count; main behind origin does). Anything else, git
# missing included, denies: the guard changes by merging and pulling, never by working in the live checkout.
DIR=$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
ROOT=$(cd "$DIR/../.." 2>/dev/null && pwd -P)
# This file must be the checkout's own tools/github-mcp/guard.sh: a copy elsewhere would pass on the real files.
[ -n "$DIR" ] && [ "$DIR" = "$ROOT/tools/github-mcp" ] || ROOT=
LIVE_FILES="tools/github-mcp/guard.sh tools/github-mcp/launch"
# >>> reviewed-code check: keep this block identical in guard.sh and launch (test-guard.sh compares them).
# git reads the checkout's own .git/config, which a file edit can change, so only commands that run no filter, hook,
# external diff or textconv are used: the index against HEAD (diff-index --cached) and each tracked file hashed with
# --no-filters against the index. The work tree, replace refs, grafts, the commit-graph and trace2 are pinned so that
# .git/config cannot redirect them. Only plain files are accepted; a symlink, a submodule or a conflict denies.
live_git() {
  [ -n "$ROOT" ] && [ -d "$ROOT/.git" ] || return 1
  /usr/bin/env GIT_DIR="$ROOT/.git" GIT_WORK_TREE="$ROOT" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null GIT_TRACE2=0 \
    GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 /usr/bin/git -c core.fsmonitor=false -c core.commitGraph=false \
    -c core.useReplaceRefs=false -c core.hooksPath=/dev/null -C "$ROOT" "$@" 2>/dev/null
}
live_main_ok() {
  [ "$(live_git symbolic-ref -q HEAD </dev/null)" = refs/heads/main ] || return 1
  live_git diff-index --cached --quiet --no-ext-diff --no-textconv HEAD -- </dev/null || return 1
  _idx=$(live_git ls-files -s </dev/null) && [ -n "$_idx" ] || return 1
  printf '%s\n' "$_idx" | /usr/bin/grep -Eqv '^100(644|755) [0-9a-f]{40,64} 0[[:blank:]]' && return 1
  _want=$(printf '%s\n' "$_idx" | /usr/bin/cut -d ' ' -f 2)
  _got=$(printf '%s\n' "$_idx" | /usr/bin/cut -f 2- | live_git hash-object --no-filters --stdin-paths) || return 1
  [ "$_want" = "$_got" ] || return 1
  live_git merge-base --is-ancestor HEAD refs/remotes/origin/main </dev/null || return 1
  for _f in $LIVE_FILES; do
    [ -n "$(live_git rev-parse -q --verify "HEAD:$_f" </dev/null)" ] || return 1
  done
}
# <<< reviewed-code check
if ! live_main_ok; then
  decide deny "the checkout this guard runs from is not reviewed code (not on main, a tracked file changed, HEAD not on origin/main, or git unavailable); github MCP calls are off until it is (work in a /tmp clone, then merge and pull)."
fi

# Must match the --tools list in tools/github-mcp/launch (beside this file).
READ_TOOLS=" get_me pull_request_read list_pull_requests search_pull_requests issue_read list_issues search_issues get_file_contents get_commit list_commits list_branches actions_get actions_list get_job_logs "
WRITE_TOOLS=" create_pull_request add_issue_comment add_reply_to_pull_request_comment actions_run_trigger update_pull_request "
# Owners whose repos the write tools may target (lowercase JSON array): the github_write_owners install setting,
# read from ~/.claude/install.conf at call time (/setup-claude writes it; the template denies edits of that file and
# asks on a shell command that names it). Only plain lowercase owner names are accepted. A missing or invalid
# setting leaves an empty list, so every owner-bearing write is denied. The repo name must be a plain GitHub name.
WRITE_OWNERS='[]'
OWNERS_LINE=$(/usr/bin/sed -n 's/^github_write_owners=//p' "$HOME/.claude/install.conf" </dev/null 2>/dev/null | /usr/bin/head -n 1)
OWNERS_RE='^[abcdefghijklmnopqrstuvwxyz0123456789][abcdefghijklmnopqrstuvwxyz0123456789-]*( [abcdefghijklmnopqrstuvwxyz0123456789][abcdefghijklmnopqrstuvwxyz0123456789-]*)*$'
if [[ "$OWNERS_LINE" =~ $OWNERS_RE ]]; then
  WRITE_OWNERS=$(printf '%s\n' "$OWNERS_LINE" | "$JQ" -R -c 'split(" ")' 2>/dev/null) || WRITE_OWNERS='[]'
fi

case "$TOOL" in
  ''|*[!a-z_]*) decide deny "$(show '.tool_name') is not a valid github MCP tool name; blocked." ;;
esac
case "$READ_TOOLS" in *" $TOOL "*) exit 0 ;; esac
case "$WRITE_TOOLS" in
  *" $TOOL "*) ;;
  *) decide deny "$(show '.tool_name') is not a reviewed github MCP tool; blocked. Add it to the guard and the launcher's --tools list by PR first." ;;
esac

DISPATCH_WARN="Approve only for a workflow you expect to run now. The ref decides which version of the workflow file runs, with the repo's own secrets, and a workflow that deploys or spends money (paid runners, API keys) does so as the user."
DEPLOY_WARN="Where a workflow deploys, re-running an old run can deploy an old version, and cancelling a run can stop a deploy halfway."

if ! jqtest --argjson owners "$WRITE_OWNERS" '
    (.tool_input.owner | type == "string") and (.tool_input.repo | type == "string")
    and ((.tool_input.owner | ascii_downcase) as $o | (.tool_input.repo | ascii_downcase) as $r
      | any($owners[]; . == $o)
        and ($r | length > 0 and length <= 100 and (gsub("[^a-z0-9._-]"; "") == .) and (test("^[.]+$") | not)))'; then
  decide deny "$TOOL on $(show '[.tool_input.owner, .tool_input.repo]') is outside the github MCP write owners ($WRITE_OWNERS); blocked."
fi

case "$TOOL" in
  actions_run_trigger)
    if jqtest '.tool_input.method | IN("rerun_workflow_run", "rerun_failed_jobs", "cancel_workflow_run")'; then
      decide ask "$(show '.tool_input.method') on $(show '[.tool_input.owner, .tool_input.repo]'). $DEPLOY_WARN"
    fi
    if jqtest '.tool_input.method == "run_workflow"'; then
      decide ask "workflow dispatch of $(showfull '.tool_input.workflow_id' 120) at ref $(showfull '.tool_input.ref' 120) with inputs $(showfull '.tool_input.inputs' 600) on $(show '[.tool_input.owner, .tool_input.repo]'). $DISPATCH_WARN"
    fi
    decide deny "actions_run_trigger method $(show '.tool_input.method') is not reviewed; blocked."
    ;;
  update_pull_request)
    jqtest '.tool_input | type == "object" and ((keys - ["owner", "repo", "pullNumber", "title", "body", "draft"]) | length == 0)' \
      || decide deny "update_pull_request may set only title, body and draft; input keys $(show '.tool_input | keys') blocked. Closing or reopening, the base branch, reviewers and maintainer_can_modify stay with the user."
    jqtest '.tool_input | (.pullNumber | type == "number" and . == floor and . > 0)
      and (has("title") or has("body") or has("draft"))
      and ((has("title") | not) or (.title | type == "string"))
      and ((has("body") | not) or (.body | type == "string"))
      and ((has("draft") | not) or (.draft | type == "boolean"))' \
      || decide deny "update_pull_request needs a whole-number pullNumber above zero and at least one of title, body or draft, with text for title and body and true or false for draft; blocked."
    # One jq call builds the whole prompt text, so an error denies instead of dropping a field or the draft warning.
    ASK=$(printf '%s' "$INPUT" | "$JQ" -r '
      def cut: tojson | if length > 600 then .[0:300] + "...(truncated)..." + .[-300:] + " [" + (length | tostring) + " characters of JSON in all]" else . end;
      .tool_input as $t
      | (($t.owner | tojson) + "/" + ($t.repo | tojson) + " #" + ($t.pullNumber | tojson)) as $pr
      | (["title", "body", "draft"] | map(select(. as $f | $t | has($f)) | . as $f | $f + " " + ($t[$f] | cut) + "; ") | join("")) as $set
      | "update_pull_request on " + $pr + " sets " + $set + "nothing else."
        + (if $t.draft == false then " Setting draft to false marks the PR ready for review, which starts the automatic paid Claude review." else "" end)
        + " The title and body are shown to everyone on the PR and read by its automatic reviewer."' 2>/dev/null) \
      && [ -n "$ASK" ] \
      || decide deny "update_pull_request: could not build the approval text; blocked (fail-closed)."
    if  jqtest '.tool_input | (.draft != false) and ([.title, .body | strings | test("@claude"; "i")] | any | not)'; then
      decide allow "update_pull_request on a write-owner repo sets only title, body or draft true. ${ASK}"
    fi
    decide ask "${ASK}"
    ;;
  add_issue_comment|add_reply_to_pull_request_comment)
    if jqtest '.tool_input | (has("body") and ((.body | type != "string") or (.body | test("@claude"; "i"))))'; then
      decide ask "this comment mentions @claude, which starts a paid Claude review run, or its body is not text. Approve only if a review is wanted now."
    fi
     decide allow "$TOOL on a write-owner repo, no @claude mention."
    ;;
  create_pull_request)
    if jqtest '.tool_input | [.title, .body | select(. != null) | (type != "string") or test("@claude"; "i")] | any'; then
      decide ask "this PR title or body mentions @claude or is not text. Approve only if that is meant."
    fi
    if jqtest '.tool_input.draft != true'; then
      decide ask "create_pull_request opens a PR ready for review (draft $(show '.tool_input.draft')), which starts the automatic paid Claude review in a repo that runs one. Approve only if a review is wanted now; otherwise create it with draft true."
    fi
    decide allow "create_pull_request of a draft PR on a write-owner repo."
    ;;
esac

decide ask "$TOOL on $(show '[.tool_input.owner, .tool_input.repo]') writes to GitHub as the user."
