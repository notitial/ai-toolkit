#!/bin/bash
# Post-tool-use hook: logs Bash commands and MCP tool calls.
# Writes to .archive/audit/audit-YYYY-MM.log (monthly rotation via filename).
# Also logs PreToolUse deny decisions (invoked from denying PreToolUse hooks).
# Configured in ~/.claude/settings.json for PostToolUse on Bash|mcp__.*
# and manually invoked from PreToolUse hooks.
#
# Non-blocking — always exits 0. Does not modify repo state.
# Tool inputs are redacted for common secret patterns (JWTs, API keys, tokens,
# DB connection passwords) before writing. Treat logs as sensitive regardless —
# redaction is best-effort and cannot catch every secret shape.

set -euo pipefail
# Fail open: whatever fails (unreadable input, a log folder it cannot write), the hook ends with exit 0 and the tool
# call goes on; only the record is lost.
trap 'exit 0' EXIT

# Convenience hook: observability only — fail open if jq is unavailable.
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

if [ -z "$CWD" ]; then
  exit 0
fi

# Resolve to git root so audits always land in the repo-level .archive/
PROJECT_DIR=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")

AUDIT_DIR="${PROJECT_DIR}/.archive/audit"
mkdir -p "$AUDIT_DIR"

# Warn if .archive/ is not gitignored
if [ -f "${PROJECT_DIR}/.gitignore" ]; then
  if ! grep -qE '^/?\.archive' "${PROJECT_DIR}/.gitignore" 2>/dev/null; then
    echo "audit-logger: .archive/ is not in .gitignore — audit logs may be committed accidentally" >&2
  fi
elif [ ! -f "${PROJECT_DIR}/.gitignore" ]; then
  echo "audit-logger: no .gitignore found — audit logs in .archive/ may be committed accidentally" >&2
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
LOG_FILE="${AUDIT_DIR}/audit-$(date +%Y-%m).log"

# PreToolUse deny events are routed here by the denying hooks (they re-emit
# their stdin tagged with _audit_event=deny). Capture the marker + hook + reason
# so the record carries the block; the tool-specific DETAIL below still applies.
AUDIT_EVENT=$(echo "$INPUT" | jq -r '._audit_event // empty')
DENY_HOOK=$(echo "$INPUT" | jq -r '._deny_hook // empty')
DENY_REASON=$(echo "$INPUT" | jq -r '._deny_reason // empty')

# Extract compact detail based on tool type
case "$TOOL_NAME" in
  Bash)
    # Extract full command; redaction + truncation happen in the final jq pass
    # so a secret near the 300-char boundary is masked before it is cut.
    DETAIL=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    ;;
  Write)
    # Include file path for Write operations
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    DETAIL="write: ${FILE_PATH}"
    ;;
  Edit)
    # Include file path for Edit operations
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    DETAIL="edit: ${FILE_PATH}"
    ;;
  NotebookEdit)
    # Include notebook path for NotebookEdit operations
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.notebook_path // empty')
    DETAIL="notebook-edit: ${FILE_PATH}"
    ;;
  mcp__git-mcp__git_push)
    # Include branch and force details for push operations
    PATH_ARG=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
    BRANCH=$(echo "$INPUT" | jq -r '.tool_input.branch // .tool_input.remoteBranch // empty')
    FORCE=$(echo "$INPUT" | jq -r '.tool_input.force // false')
    FORCE_LEASE=$(echo "$INPUT" | jq -r '.tool_input.forceWithLease // false')
    DELETE=$(echo "$INPUT" | jq -r '.tool_input.delete // false')
    FLAGS=""
    [ "$FORCE" = "true" ] && FLAGS="${FLAGS}+force"
    [ "$FORCE_LEASE" = "true" ] && FLAGS="${FLAGS}+lease"
    [ "$DELETE" = "true" ] && FLAGS="${FLAGS}+delete"
    DETAIL="git push${PATH_ARG:+ (${PATH_ARG})}${BRANCH:+ ${BRANCH}}${FLAGS:+ [${FLAGS}]}"
    ;;
  mcp__git-mcp__*)
    SUBCMD="${TOOL_NAME#mcp__git-mcp__git_}"
    PATH_ARG=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
    DETAIL="git ${SUBCMD}${PATH_ARG:+ (${PATH_ARG})}"
    ;;
  *)
    # Other MCP tools — log the first short string parameter as context
    DETAIL=$(echo "$INPUT" | jq -r '
      [.tool_input // {} | to_entries[]
        | select(.value | type == "string")
        | select((.value | length) < 200)
        | .value
      ] | first // empty' | cut -c1-200)
    ;;
esac

printf '%s\n' "$(jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sid "$SESSION_ID" \
  --arg tool "$TOOL_NAME" \
  --arg detail "$DETAIL" \
  --arg event "$AUDIT_EVENT" \
  --arg hook "$DENY_HOOK" \
  --arg reason "$DENY_REASON" \
  '
  # Best-effort masking of secrets that appear in the command text itself.
  # A PEM key cut before its END line loses its body too: the second PEM rule eats the PEM alphabet after the
  # header (base64, whitespace, `:,-`, a literal backslash-n/-r/-t).
  # Unbounded, because {n,m} is unusable here (see below); one match covers a run of headers. Both PEM rules run
  # first: a token rule that fired inside a key body would write a `[` into it and stop the eater.
  # NOTE: regex quantifiers use + (not {n,}) on purpose — a comma inside braces
  # is brace-expanded by the shell before jq sees the program, which silently
  # duplicates the whole record once per such quantifier.
  def redact:
    gsub("-----BEGIN[^-]*PRIVATE KEY-----[\\s\\S]*?-----END[^-]*PRIVATE KEY-----"; "[REDACTED_PEM]")
    | gsub("-----BEGIN[^-]*PRIVATE KEY-----(?:\\\\[nrt]|[A-Za-z0-9+/=:,\\s-])*"; "[REDACTED_PEM]")
    | gsub("eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; "[REDACTED_JWT]")
    | gsub("NR[A-Z][A-Z]-[A-Za-z0-9]+"; "[REDACTED_NRKEY]")
    | gsub("(AKIA|ASIA)[A-Z0-9]+"; "[REDACTED_AWSKEY]")
    | gsub("gh[pousr]_[A-Za-z0-9]+"; "[REDACTED_GHTOKEN]")
    | gsub("github_pat_[A-Za-z0-9_]+"; "[REDACTED_GHTOKEN]")
    | gsub("glpat-[A-Za-z0-9_-]+"; "[REDACTED_GLPAT]")
    | gsub("(?:(?<![A-Za-z0-9])|(?<=\\\\[nrt]))sk-(ant-)?[A-Za-z0-9_-]+"; "[REDACTED_APIKEY]")
    | gsub("(sk|rk)_live_[A-Za-z0-9_-]+"; "[REDACTED_STRIPE]")
    | gsub("AIza[A-Za-z0-9_-]+"; "[REDACTED_GOOGLE]")
    | gsub("xox[bpasr]-[A-Za-z0-9-]+"; "[REDACTED_SLACK]")
    | gsub("(?<u>(postgres|postgresql|mysql|mongodb|redis|amqp)://[^:@/\\s]+:)[^@/\\s]+@"; "\(.u)[REDACTED]@")
    | gsub("(?<k>(api[_-]?key|apikey|access[_-]?(token|key)|token|secret|password|passwd|[_-]pass|pwd|service_role[a-z_]*|client[_-]?secret)[A-Za-z0-9_]*\"?\\s*[=:]\\s*\"?)[^\\s\"&|;,]+"; "\(.k)[REDACTED]"; "i")
    | gsub("(?<b>[Bb]earer\\s+)[A-Za-z0-9._-]+"; "\(.b)[REDACTED]");
  {ts: $ts, session: $sid, tool: $tool, detail: ($detail | redact | .[0:300])}
  + (if $event == "" then {}
     else {event: $event, hook: $hook, reason: ($reason | redact | .[0:300])} end)
  ')" \
  >> "$LOG_FILE"

exit 0
