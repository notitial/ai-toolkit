#!/bin/bash -p
# Pre-tool-use hook: guards the github MCP server (github/github-mcp-server) by argument, where tool-name permission
# rules cannot reach (v2 bundles reads and writes behind a `method` argument). Runs from the live checkout
# (tools/github-mcp/guard.sh), wired in ~/.claude/settings.json for PreToolUse on ^mcp__github__.*$.
#
# - Every call is denied unless the checkout this file sits in is reviewed code: on main with no tracked change, HEAD
#   on origin/main, and this file and launch equal to their committed blobs. A branch, a half-done edit or a local
#   commit of the guard would otherwise go live.
# - Reads pass. A tool in neither READ_TOOLS nor WRITE_TOOLS is denied, so a server upgrade stays shut until reviewed.
# - Every write must target a repo of WRITE_OWNERS; projects_write, which names a Project owner and no repo, must name
#   an owner of WRITE_OWNERS, and every item repo it names must be a repo of one.
# - actions_run_trigger: re-run, re-run failed jobs, cancel and dispatch ask; log deletion is denied.
# - update_pull_request may set only title, body and draft, and asks with the new text shown.
# - create_pull_request, add_issue_comment, add_reply_to_pull_request_comment and update_pull_request are allowed,
#   except that a mention of @claude (a paid review run), a body that is not text, or draft set to false asks;
#   create_pull_request also asks unless draft is true, since a ready PR starts the automatic paid review.
# - issue_write (create, update), sub_issue_write (add, reprioritize) and label_write (create, update) are allowed.
#   A state change (it closes or reopens an issue or a PR), assignees, @claude in a title or body, a sub-issue
#   removed or moved from another parent, and a label deletion ask. An argument the guard does not know, an unknown
#   method or a value of the wrong type denies.
# - projects_write is allowed for one item added or updated, and a status update, in a Project of the
#   github_projects install setting; a Project not listed there, a bulk update, deletes, view and field changes and
#   creating a Project ask.
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
# .git/config cannot redirect them, and no pager, lazy fetch or transport runs (a promisor remote named there would
# otherwise run its upload-pack command on a missing object). Only plain files are accepted; a symlink, a submodule
# or a conflict denies, and so does a grep that fails.
live_git() {
  [ -n "$ROOT" ] && [ -d "$ROOT/.git" ] || return 1
  /usr/bin/env GIT_DIR="$ROOT/.git" GIT_WORK_TREE="$ROOT" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null GIT_TRACE2=0 \
    GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none /usr/bin/git --no-pager \
    -c core.fsmonitor=false -c core.commitGraph=false \
    -c core.useReplaceRefs=false -c core.hooksPath=/dev/null -C "$ROOT" "$@" 2>/dev/null
}
live_main_ok() {
  [ "$(live_git symbolic-ref -q HEAD </dev/null)" = refs/heads/main ] || return 1
  live_git diff-index --cached --quiet --no-ext-diff --no-textconv HEAD -- </dev/null || return 1
  _idx=$(live_git ls-files -s </dev/null) && [ -n "$_idx" ] || return 1
  printf '%s\n' "$_idx" | /usr/bin/grep -Eqv '^100(644|755) [0-9a-f]{40,64} 0[[:blank:]]'
  [ $? -eq 1 ] || return 1
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
READ_TOOLS=" get_me pull_request_read list_pull_requests search_pull_requests issue_read list_issues search_issues get_file_contents get_commit list_commits list_branches actions_get actions_list get_job_logs list_label projects_list projects_get "
WRITE_TOOLS=" create_pull_request add_issue_comment add_reply_to_pull_request_comment actions_run_trigger update_pull_request issue_write sub_issue_write label_write projects_write "
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
# The Projects projects_write may change without a prompt (JSON array of {owner, number}): the optional
# github_projects install setting, space-separated <owner>/<number> entries, read from the same file at call time. An
# entry counts only while its owner is a write owner. A missing or invalid setting leaves no Project, so every
# projects_write asks (or denies, outside the write owners).
PROJECTS='[]'
PROJECTS_LINE=$(/usr/bin/sed -n 's/^github_projects=//p' "$HOME/.claude/install.conf" </dev/null 2>/dev/null | /usr/bin/head -n 1)
PROJECT_RE='[abcdefghijklmnopqrstuvwxyz0123456789][abcdefghijklmnopqrstuvwxyz0123456789-]*/[123456789][0123456789]{0,8}'
PROJECTS_RE="^$PROJECT_RE( $PROJECT_RE)*\$"
if [[ "$PROJECTS_LINE" =~ $PROJECTS_RE ]]; then
  PROJECTS=$(printf '%s\n' "$PROJECTS_LINE" | "$JQ" -R -c --argjson owners "$WRITE_OWNERS" '
    split(" ") | map(split("/") | {owner: .[0], number: (.[1] | tonumber)})
    | map(select(.owner as $o | any($owners[]; . == $o)))' 2>/dev/null) || PROJECTS='[]'
fi

# jq helpers for the write checks (prepended to a jq program). repo_ok: $o/$r is a repo of a write owner, with a
# plain GitHub repo name (needs --argjson owners). cut: a JSON-quoted value, its middle cut when long, for prompts.
# whole: a whole number above zero. opt(keys; f): each of the keys that is present (null included) passes f.
REPO_OK='def repo_ok($o; $r): ($o | type == "string") and ($r | type == "string")
  and (($o | ascii_downcase) as $lo | ($r | ascii_downcase) as $lr
    | any($owners[]; . == $lo)
      and ($lr | length > 0 and length <= 100 and (gsub("[^a-z0-9._-]"; "") == .) and (test("^[.]+$") | not)));'
CUT='def cut: tojson | if length > 600 then .[0:300] + "...(truncated)..." + .[-300:] + " [" + (length | tostring) + " characters of JSON in all]" else . end;'
WHOLE='def whole: type == "number" and . == floor and . > 0;
  def opt($ks; f): . as $o | all($ks[]; . as $k | ($o | has($k) | not) or ($o[$k] | f));'

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

# projects_write names a Project owner (a user or an org) and no repo, so it is judged here, before the repo check.
# Every branch below ends in a decision.
if [ "$TOOL" = projects_write ]; then
  PROJECT_METHODS='["add_project_item", "update_project_item", "update_project_items", "delete_project_item",
    "create_project_status_update", "create_project_view", "update_project_view", "delete_project_view",
    "create_project", "create_iteration_field"]'
  jqtest --argjson methods "$PROJECT_METHODS" "$WHOLE"'
    .tool_input | type == "object"
    and ((keys - ["method", "owner", "owner_type", "project_number", "item_type", "item_owner", "item_repo",
      "issue_number", "pull_request_number", "item_id", "items", "updated_field", "body", "status", "start_date",
      "target_date", "title", "name", "layout", "filter", "view_id", "visible_fields", "visible_field_names",
      "field_name", "iteration_duration", "iterations"]) | length == 0)
    and (.method as $m | any($methods[]; . == $m))
    and ((has("project_number") | not) or (.project_number | whole))
    and ((has("items") | not) or (.method == "update_project_items" and (.items | type == "array"
      and all(.[]; type == "object" and ((keys - ["node_id", "item_id", "item_owner", "item_repo", "issue_number"]) | length == 0)))))
    and opt(["title", "body"]; type == "string")' \
    || decide deny "projects_write needs a reviewed method, only the arguments the guard knows, a whole-number project_number above zero, items only on update_project_items (a list of item references), and text for title and body; blocked."
  jqtest --argjson owners "$WRITE_OWNERS" '.tool_input.owner | type == "string" and (ascii_downcase as $o | any($owners[]; . == $o))' \
    || decide deny "projects_write on the Project owner $(show '.tool_input.owner') is outside the github MCP write owners ($WRITE_OWNERS); blocked."
  jqtest --argjson owners "$WRITE_OWNERS" "$REPO_OK"'
    .tool_input | [., .items[]?] | all(.[]; ((has("item_owner") or has("item_repo")) | not) or repo_ok(.item_owner; .item_repo))' \
    || decide deny "projects_write names an item repo outside the github MCP write owners, or item_owner without item_repo; blocked."
  WHERE="$(show '.tool_input.owner') Project #$(show '.tool_input.project_number')"
  # What the method does decides its own answer, and its note goes into every prompt, the unlisted-Project one too.
  VERDICT=ask NOTE=""
  case $(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.method' 2>/dev/null) in
    add_project_item|update_project_item|create_project_status_update) VERDICT=allow NOTE="" ;;
    update_project_items)
      NOTE="It is a bulk update of $(show '.tool_input.items | length') items ($(showfull '.tool_input.items' 300)), setting $(showfull '.tool_input.updated_field' 300) on every one." ;;
    delete_project_item|delete_project_view)
      NOTE="It deletes item $(show '.tool_input.item_id') or view $(show '.tool_input.view_id'); a deleted item or view is not restored." ;;
    create_project_view|update_project_view|create_iteration_field)
      NOTE="It changes the Project's layout or fields for everyone who uses it." ;;
    create_project)
      decide ask "projects_write creates a new Project titled $(showfull '.tool_input.title' 200) under $(show '.tool_input.owner'). It is not in the github_projects install setting until you add it." ;;
    *) decide deny "projects_write: could not judge method $(show '.tool_input.method'); blocked (fail-closed)." ;;
  esac
  if ! jqtest --argjson p "$PROJECTS" '.tool_input | has("project_number")
      and ((.owner | ascii_downcase) as $o | .project_number as $n | any($p[]; .owner == $o and .number == $n))'; then
    decide ask "projects_write $(show '.tool_input.method') on $WHERE, which is not in the github_projects install setting. Approve only if this Project is meant.${NOTE:+ $NOTE}"
  fi
  if jqtest '[.tool_input.title, .tool_input.body | strings | test("@claude"; "i")] | any'; then
    decide ask "projects_write $(show '.tool_input.method') on $WHERE: the text mentions @claude. Body $(showfull '.tool_input.body' 600).${NOTE:+ $NOTE}"
  fi
  [ "$VERDICT" = allow ] && decide allow "projects_write $(show '.tool_input.method') on $WHERE, a Project of the github_projects install setting."
  decide ask "projects_write $(show '.tool_input.method') on $WHERE. $NOTE"
fi

if ! jqtest --argjson owners "$WRITE_OWNERS" "$REPO_OK"' repo_ok(.tool_input.owner; .tool_input.repo)'; then
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
    ASK=$(printf '%s' "$INPUT" | "$JQ" -r "$CUT"'
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
  issue_write)
    jqtest "$WHOLE"'.tool_input | type == "object"
      and ((keys - ["method", "owner", "repo", "issue_number", "title", "body", "labels", "assignees", "milestone",
        "type", "state", "state_reason", "duplicate_of", "issue_fields", "parent_issue_number", "parent_owner",
        "parent_repo"]) | length == 0)
      and (.method == "create" or .method == "update")
      and (if .method == "update" then (.issue_number | whole) else ((has("issue_number") | not) or (.issue_number | whole)) end)
      and opt(["title", "body"]; type == "string")
      and opt(["labels", "assignees"]; type == "array" and all(.[]; type == "string"))
      and opt(["milestone", "duplicate_of", "parent_issue_number"]; whole)
      and ((has("type") | not) or (.type | type == "string" or type == "null"))
      and ((has("state") | not) or (.state | IN("open", "closed")))
      and ((has("state_reason") | not) or (.state_reason | IN("completed", "not_planned", "duplicate")))
      and ((has("issue_fields") | not) or (.issue_fields | type == "array" and all(.[]; type == "object")))' \
      || decide deny "issue_write needs method create or update (update with a whole-number issue_number above zero), only the arguments the guard knows, text for title and body, lists of text for labels and assignees, and state open or closed; blocked."
    jqtest --argjson owners "$WRITE_OWNERS" "$REPO_OK"'
      .tool_input | ((has("parent_owner") or has("parent_repo")) | not) or repo_ok(.parent_owner; .parent_repo)' \
      || decide deny "issue_write attaches the issue to a parent outside the github MCP write owners, or gives parent_owner without parent_repo; blocked."
    # One jq call builds the whole prompt text, so an error denies instead of dropping a field or a warning.
    ASK=$(printf '%s' "$INPUT" | "$JQ" -r "$CUT"'
      .tool_input as $t
      | (($t.owner | tojson) + "/" + ($t.repo | tojson) + (if $t.method == "update" then " #" + ($t.issue_number | tojson) else "" end)) as $where
      | ($t | keys - ["method", "owner", "repo", "issue_number"] | map(. as $f | $f + " " + ($t[$f] | cut) + "; ") | join("")) as $set
      | "issue_write " + $t.method + " on " + $where + " sets " + $set + "nothing else."
        + (if $t | has("state") or has("state_reason") or has("duplicate_of") then " A state change closes or reopens the issue, and the same call closes or reopens a pull request." else "" end)
        + (if $t.method == "update" and ($t | has("parent_issue_number")) then " A parent on an update can move the issue away from its current parent." else "" end)
        + (if ($t.assignees // []) | length > 0 then " Assigning notifies the assignees, and assigning Copilot starts a paid coding-agent run." else "" end)
        + (if [$t.title, $t.body | strings | test("@claude"; "i")] | any then " The text mentions @claude, which can start a paid Claude run." else "" end)
        + " The title and body are shown to everyone who can see the repo."' 2>/dev/null) \
      && [ -n "$ASK" ] \
      || decide deny "issue_write: could not build the approval text; blocked (fail-closed)."
    if jqtest '.tool_input | ([has("state", "state_reason", "duplicate_of")] | any | not) and ((.assignees // []) | length == 0)
        and ((.method == "update" and has("parent_issue_number")) | not)
        and ([.title, .body | strings | test("@claude"; "i")] | any | not)'; then
      decide allow "issue_write on a write-owner repo, with no state change, assignee, parent move or @claude. ${ASK}"
    fi
    decide ask "${ASK}"
    ;;
  sub_issue_write)
    jqtest "$WHOLE"'.tool_input | type == "object"
      and ((keys - ["method", "owner", "repo", "issue_number", "sub_issue_id", "replace_parent", "after_id", "before_id"]) | length == 0)
      and (.method | IN("add", "remove", "reprioritize"))
      and ([.issue_number, .sub_issue_id] | all(whole))
      and opt(["after_id", "before_id"]; whole)
      and ((has("replace_parent") | not) or (.replace_parent | type == "boolean"))' \
      || decide deny "sub_issue_write needs method add, remove or reprioritize, whole-number issue_number and sub_issue_id above zero, and only the arguments the guard knows; blocked."
    WHAT="sub_issue_write $(show '.tool_input.method') of sub-issue id $(show '.tool_input.sub_issue_id') on $(show '[.tool_input.owner, .tool_input.repo]') #$(show '.tool_input.issue_number')"
    if jqtest '.tool_input.method == "remove"'; then
      decide ask "$WHAT: removes the sub-issue from its parent."
    fi
    if jqtest '.tool_input.replace_parent == true'; then
      decide ask "$WHAT with replace_parent: moves the sub-issue away from its current parent, which can be in another repo."
    fi
    decide allow "$WHAT."
    ;;
  label_write)
    jqtest "$WHOLE"'.tool_input | type == "object"
      and ((keys - ["method", "owner", "repo", "name", "new_name", "color", "description"]) | length == 0)
      and (.method | IN("create", "update", "delete"))
      and (.name | type == "string")
      and opt(["new_name", "color", "description"]; type == "string")' \
      || decide deny "label_write needs method create, update or delete, a label name as text, and only the arguments the guard knows; blocked."
    if jqtest '.tool_input.method == "delete"'; then
      decide ask "label_write deletes the label $(showfull '.tool_input.name' 120) from $(show '[.tool_input.owner, .tool_input.repo]'), and from every issue and pull request that carries it."
    fi
    decide allow "label_write $(show '.tool_input.method') of $(show '.tool_input.name') on a write-owner repo."
    ;;
esac

decide ask "$TOOL on $(show '[.tool_input.owner, .tool_input.repo]') writes to GitHub as the user."
