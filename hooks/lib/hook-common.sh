# The preamble the PreToolUse hooks share. Sourced, never run. The hook sets HOOK to its own name and finds this file
# beside its real path (the hooks are links in ~/.claude/hooks, so the lib stays in the protected checkout):
#   HOOK=<name>; S=${BASH_SOURCE[0]}; [ -L "$S" ] && S=$(readlink "$S"); . "${S%/*}/lib/hook-common.sh" && [ "${HOOK_COMMON_LOADED:-}" = 1 ] || exit 1
# (a bare `exit 1` is what the guards' `|| exit 2` wiring turns into a block; the marker catches an empty or cut-short
# file, which sources without error). Bash 3.2.
# It checks for jq (a hook that must fail open checks first and exits before it sources this), reads stdin into
# INPUT and defines field, decide, audit_deny and deny. The hook keeps its own checks of what INPUT holds.

command -v jq >/dev/null 2>&1 || {
  printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$HOOK: jq unavailable - blocked (fail-closed). Install jq or do it yourself.\"}}"
  exit 0
}

INPUT=$(cat) || true
HOOK_DIR=${BASH_SOURCE[0]%/lib/*}

field() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || true; }  # field <jq filter>: the value, or nothing

decide() {  # decide <deny|ask> <message shown to the agent>
  jq -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}' 2>/dev/null \
    || exit 1  # a jq that fails must not read as an allow: a guard's `|| exit 2` wiring blocks on it
}

audit_deny() {  # audit_deny <reason> [event, default deny]: a best-effort row in the audit log; never blocks
  [ -r "$HOOK_DIR/audit-logger.sh" ] || return 0
  printf '%s' "$INPUT" \
    | jq -c --arg e "${2:-deny}" --arg r "$1" --arg h "$HOOK" '. + {_audit_event: $e, _deny_reason: $r, _deny_hook: $h}' 2>/dev/null \
    | bash "$HOOK_DIR/audit-logger.sh" >/dev/null 2>&1 || true
}

deny() {  # deny <reason for the log> [message for the agent, default "<hook>: <reason>"]
  audit_deny "$1"
  decide deny "${2:-$HOOK: $1}"
  exit 0
}

HOOK_COMMON_LOADED=1  # keep this the last line: the hook checks it to know the whole file was read
