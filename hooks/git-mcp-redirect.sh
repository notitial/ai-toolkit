#!/bin/bash
# Pre-tool-use hook (PreToolUse on Bash): sends Bash git commands to the MCP git tools, whose guard checks
# pushes and resets. Read-only plumbing with no MCP equivalent (rev-parse, ls-files, config --get, ...) passes.
# git counts only in command position: at the start of a line or after a separator, behind VAR=value, env, sudo,
# command or `timeout <duration>`. git inside a string or an argument is left alone.
# This is an advisory redirect: without jq, or on input that is not a JSON object, it lets the call through.
# Exit 0 always.
#
# Known gaps, kept on purpose so the hook stays simple. These shapes pass unredirected:
#   - wrappers other than env, sudo, command and timeout: time, nohup, exec, nice, xargs;
#   - options after a wrapper (sudo -u x, env -i, timeout -s KILL 5), and git inside a shell -c string;
#   - a leading `!` (negation), and git behind a shell keyword (if, then, while, do, ...);
#   - a leading redirect, as in `>/dev/null git push`;
#   - a -c or -C value with a backslash-escaped space (git -c x.y=1\ rev-parse push ...): the value is cut at the
#     space, so the word after it is read as the subcommand.
# And one false deny: a -c value that holds a `;` (git -c 'a=b;c' status) is cut at the `;` and denied as
# unclassifiable.
# The backstops for a call that slips past: the setup template allows no Bash git, so it still needs approval (a
# permission prompt, or the classifier in auto mode) unless the user allowed it; hooks/destructive-blocker.sh blocks
# the long spellings (push --force, reset --hard, clean -f, branch -D) wherever they appear in the command, though
# not every short flag behind these wrappers; and branch protection on the remote refuses a push to a protected
# branch. The MCP route itself is guarded by hooks/git-mcp-guard.sh.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

# Best-effort record of a deny in the audit log (never blocks this hook).
audit_deny() {
  local logger
  logger="$(dirname "${BASH_SOURCE[0]}")/audit-logger.sh"
  [ -r "$logger" ] || return 0
  printf '%s' "$INPUT" \
    | jq -c --arg r "$1" --arg h "git-mcp-redirect" \
        '. + {_audit_event:"deny",_deny_reason:$r,_deny_hook:$h}' 2>/dev/null \
    | bash "$logger" >/dev/null 2>&1 || true
}

deny() {
  audit_deny "$1"
  jq -n --arg r "$2" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# Turn /usr/bin/git and \git into plain git.
SCAN=$(printf '%s' "$COMMAND" | sed -E -e 's#[^[:space:]]*/git([[:space:]]|$)#git\1#g' -e 's#\\git([[:space:]]|$)#git\1#g')

# A command starts after a line start, | ; & ( { $( or a backtick, and may be led by assignments, env, sudo,
# command or `timeout <duration>`. Each git invocation runs to the end of its segment.
ANCHOR="(^|[|;&(\`{])"
LEADER="([A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|'[^']*'|[^[:space:]'\"])*|env|sudo|command|timeout[[:space:]]+[0-9][0-9.]*[smhd]?)[[:space:]]+"
INVOCATIONS=$(printf '%s\n' "$SCAN" | grep -oE "${ANCHOR}[[:space:]]*(${LEADER})*['\"]?git['\"]?[[:space:]]+[^|;&)\`]*" || true)
[ -n "$INVOCATIONS" ] || exit 0

# Read-only plumbing with no MCP equivalent, allowed as Bash.
is_plumbing() {
  local sub="$1" args="$2" tok positionals=0
  case "$sub" in
    rev-parse|ls-files|describe|show-ref|var|help|check-ignore|cat-file|name-rev|merge-base|count-objects|shortlog) return 0 ;;
    --version|--help|--exec-path|--html-path) return 0 ;;
    config)
      # Read forms only, with the read flag first.
      case "$args" in --get-all|--get-all\ *|--get|--get\ *|--list|--list\ *) return 0 ;; esac
      return 1 ;;
    symbolic-ref)
      # Reading HEAD only: no delete flag, and a second ref would retarget it.
      set -f
      for tok in $args; do
        case "$tok" in
          -d|--delete) set +f; return 1 ;;
          -*) ;;
          *) positionals=$((positionals + 1)) ;;
        esac
      done
      set +f
      [ "$positionals" -le 1 ] ;;
    *) return 1 ;;
  esac
}

BAD=""
while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  # A substitution inside the invocation (`git -C "$(pwd)" push`) hides the real subcommand.
  case "$LINE" in *'$('*|*'`'*) BAD="__unclassifiable__"; break ;; esac
  REST=$(printf '%s' "$LINE" | sed -E "s/^[|;&(\`{]?[[:space:]]*(${LEADER})*['\"]?git['\"]?[[:space:]]+//")
  # Skip the global options that come before the subcommand.
  while :; do
    PREV="$REST"
    REST=$(printf '%s' "$REST" | sed -E \
      -e 's/^-[Cc][[:space:]]+[^[:space:]]+[[:space:]]+//' \
      -e 's/^--(git-dir|work-tree)(=|[[:space:]]+)[^[:space:]]+[[:space:]]+//' \
      -e 's/^(--no-pager|--paginate|-P|-p)[[:space:]]+//')
    [ "$REST" = "$PREV" ] && break
  done
  SUBCMD=$(printf '%s' "$REST" | awk '{print $1}')
  ARGS=$(printf '%s' "$REST" | awk '{$1=""; sub(/^ /,""); print}')
  [ -n "$SUBCMD" ] || continue
  is_plumbing "$SUBCMD" "$ARGS" || { BAD="$SUBCMD"; break; }
done <<EOF
$INVOCATIONS
EOF

[ -n "$BAD" ] || exit 0

case "$BAD" in
  __unclassifiable__|-*)
    deny "unclassifiable Bash git command" "This Bash git command cannot be safely classified (a command substitution, or a global option before the subcommand that this hook does not know). Use the MCP git tools (mcp__git-mcp__git_*) with an explicit path parameter instead." ;;
esac

case "$BAD" in
  status|diff|log|show|blame|add|commit|push|pull|fetch|branch|checkout|merge|rebase|stash|tag|reset|remote|reflog|clean|worktree|clone|init)
    MCP_TOOL="mcp__git-mcp__git_$BAD" ;;
  cherry-pick) MCP_TOOL="mcp__git-mcp__git_cherry_pick" ;;
  *) MCP_TOOL="" ;;
esac

if [ -n "$MCP_TOOL" ]; then
  deny "redirect Bash git $BAD -> $MCP_TOOL" "Use $MCP_TOOL instead of Bash git $BAD. Always pass the path parameter on every call — the server has one global cwd and does not inherit the working directory."
fi
deny "blocked Bash git $BAD (no MCP equivalent)" "Bash git $BAD is blocked and has no MCP equivalent — ask the user or use a mapped subcommand."
