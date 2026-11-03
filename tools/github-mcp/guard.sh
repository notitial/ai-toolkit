#!/bin/bash -p
# Pre-tool-use hook: guards the github MCP server (github/github-mcp-server) by argument, where tool-name permission
# rules cannot reach (v2 bundles reads and writes behind a `method` argument). Installed root-owned at
# /usr/local/libexec/mcp-github/guard.sh (source: tools/github-mcp/guard.sh), so no session can edit the live copy, and
# wired in ~/.claude/settings.json for PreToolUse on ^mcp__github__.*$.
#
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

# Must match the --tools list in tools/github-mcp/launch (installed beside this file).
READ_TOOLS=" get_me pull_request_read list_pull_requests search_pull_requests issue_read list_issues search_issues get_file_contents get_commit list_commits list_branches actions_get actions_list get_job_logs "
WRITE_TOOLS=" create_pull_request add_issue_comment add_reply_to_pull_request_comment actions_run_trigger update_pull_request "
# Owners whose repos the write tools may target (lowercase JSON array): the github_write_owners install setting
# (~/.claude/install.conf), filled in by ghm-install when it makes the root-owned copy and never read from disk at
# call time. An unrendered copy keeps the placeholder, which is not JSON, so every owner-bearing write is denied.
# The repo name must be a plain GitHub name.
WRITE_OWNERS='__GITHUB_WRITE_OWNERS__'

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
