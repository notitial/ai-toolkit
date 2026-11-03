#!/bin/bash
# Pre-tool-use hook: blocks the gh CLI for every agent. Configured in ~/.claude/settings.json for PreToolUse on Bash
# and Monitor (Monitor runs its command in a shell too).
#
# Why: gh runs with the machine's full-scope login. Agents read GitHub through the github MCP, whose guard limits what
# they can write; anything the MCP can't do goes to the user as a markdown block of gh commands that they run
# themselves (rules/security.md).
#
# It denies any command in which `gh` appears as a word, in any case, as typed or with quotes and backslashes removed
# (`"g"h`, `g\h`). `gh-pages`, `GH_TOKEN` and `ghost` do not match. It over-matches on purpose: a search for the word
# also denies, and the reason says to use the Read or Grep tool. Known gaps, kept on purpose to keep the check
# simple: a line continuation inside the word (g, a backslash and a newline, then h), ANSI-C quoting (g$'h'), `env -S`
# with the command attached (`env -Sgh ...`) and a name built at run time all get past it. This is the normal-route
# fence, not a sandbox.
#
# Fails closed: without jq, or on input that isn't a JSON object, any mention of gh in the raw input denies. Reads
# JSON from stdin; exit 0 always (no set -e). bash 3.2.

REASON='gh-block: the gh CLI is blocked for every agent. Read GitHub through the github MCP tools instead (pull_request_read for checks, reviews and comments; list_pull_requests, search_pull_requests, issue_read, actions_list, actions_get, get_job_logs). For anything they cannot do, stop and give the user the gh commands in a markdown code block to run themselves. If this command does not run gh (a search or a path that contains the word gh), use the Read or Grep tool instead.'
WORD_RE='(^|[^A-Za-z0-9_.-])gh([^A-Za-z0-9_.-]|$)'
# In raw JSON a newline or tab inside the command is the escape \n or \t, so an escape also counts as a boundary.
RAW_RE='(^|[^A-Za-z0-9_.-]|\\[nrt])gh([^A-Za-z0-9_.-]|$)'
JQ_FALLBACK=/usr/bin/jq

INPUT=$(cat) || true

deny_raw() {
  if printf '%s' "$INPUT" | LC_ALL=C grep -Eiq "$RAW_RE"; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"gh-block: jq unavailable or the input is not a JSON object, and it mentions gh, so it is blocked (fail-closed). Give the user the gh commands in a markdown code block to run themselves."}}'
  fi
  exit 0
}

JQ=$(command -v jq 2>/dev/null)
[ -n "$JQ" ] || { [ -x "$JQ_FALLBACK" ] && JQ=$JQ_FALLBACK; }
[ -n "$JQ" ] || deny_raw
# Exactly one document: with two, .tool_name prints two lines, never equals Bash, and the call would pass.
printf '%s' "$INPUT" | "$JQ" -es 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || deny_raw

TOOL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty | strings' 2>/dev/null)
[ "$TOOL" = Bash ] || [ "$TOOL" = Monitor ] || exit 0
COMMAND=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty | strings' 2>/dev/null)
if [ -z "$COMMAND" ]; then
  printf '%s' "$INPUT" | "$JQ" -e '.tool_input.command | type == "string"' >/dev/null 2>&1 || deny_raw
  exit 0
fi

# Best-effort record of a deny into the audit log, detached so it never delays the decision.
audit_deny() {
  local logger
  logger="$(dirname "${BASH_SOURCE[0]}")/audit-logger.sh"
  [ -r "$logger" ] || return 0
  printf '%s' "$INPUT" \
    | "$JQ" -c --arg r "$1" --arg h "gh-block" \
        '. + {_audit_event:"deny",_deny_reason:$r,_deny_hook:$h}' 2>/dev/null \
    | bash "$logger" >/dev/null 2>&1 || true
}

strip() { printf '%s' "$1" | tr -d "'\"\\\\"; }
STRIPPED=$(strip "$COMMAND")
if printf '%s\n%s' "$COMMAND" "$STRIPPED" | LC_ALL=C grep -Eiq "$WORD_RE"; then
  # A static string, so the deny doesn't depend on jq (REASON holds no quote or backslash).
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$REASON"
  (audit_deny "gh in a Bash command" </dev/null >/dev/null 2>&1 &)
fi
exit 0
