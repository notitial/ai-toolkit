#!/bin/bash
# Pre-tool-use hook: guards the MCP git write tools against irreversible operations.
# Configured in ~/.claude/settings.json for PreToolUse with matcher:
#   mcp__git-mcp__git_push|mcp__git-mcp__git_reset|mcp__git-mcp__git_clean|mcp__git-mcp__git_worktree
#
# FAIL-CLOSED: unlike the convenience hooks (git-mcp-redirect, audit-logger,
# secret-detector, destructive-blocker), this hook blocks when its dependencies
# are missing. Fail-open cost is irreversible history mutation; fail-closed cost
# is one blocked call.
#
# The git-mcp server has its own protected-branch check, but it trusts the
# caller's `confirmed: true` flag — an agent can set that flag itself, so it is
# not trusted here.
#
# Out of scope (deliberate): this guard blocks remote/history-destroying or
# unrecoverable operations only. git_rebase / amend publish rewritten history
# only via a force-push (blocked here); git_checkout discards and git_branch
# deletion are reflog-recoverable, and their Bash forms remain covered by
# destructive-blocker.sh.
#
# Reads JSON from stdin. Returns JSON deny decision; exit 0 always.
# No `set -e` — it would break the exit-0-always contract.

# Fail-closed preamble: without jq the input cannot be inspected, so block.
# Static literal JSON (no jq available to build it).
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"git-mcp-guard: jq unavailable - push/reset/clean blocked (fail-closed). Install jq or run the operation manually."}}'
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

# Best-effort record of a deny into the audit log (never blocks this hook).
audit_deny() {
  local logger
  logger="$(dirname "${BASH_SOURCE[0]}")/audit-logger.sh"
  [ -r "$logger" ] || return 0
  printf '%s' "$INPUT" \
    | jq -c --arg r "$1" --arg h "git-mcp-guard" \
        '. + {_audit_event:"deny",_deny_reason:$r,_deny_hook:$h}' 2>/dev/null \
    | bash "$logger" >/dev/null 2>&1 || true
}

deny() {
  audit_deny "$1"
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("git-mcp-guard: " + $reason)
    }
  }'
  exit 0
}

jqin() { printf '%s' "$INPUT" | jq -r "$1"; }

# Normalize a ref to a plain branch name: refs/heads/main, heads/main -> main.
# Applied to every value before the protected-branch match so qualified-ref
# inputs cannot bypass it. A leading '+' (force-refspec marker) is stripped
# first, so branch:"+main" / "+refs/heads/main" cannot slip a force push past the
# protected-branch check.
norm_ref() {
  local r="$1"
  r="${r#+}"
  r="${r#refs/heads/}"
  r="${r#heads/}"
  printf '%s' "$r"
}

# Fail-closed on unparseable input. jq is present here (checked above), so
# an empty tool name means empty or malformed stdin — the guarded operation cannot
# be verified safe, so block rather than sliding to the *) allow branch below.
if [ -z "$TOOL_NAME" ]; then
  deny "could not determine the git operation from input (empty or malformed stdin) — blocked (fail-closed)."
fi

case "$TOOL_NAME" in
  mcp__git-mcp__git_push)
    # 1. Dry runs are always safe.
    [ "$(jqin '.tool_input.dryRun // false')" = "true" ] && exit 0

    # 2. Force / delete pushes are never agent work.
    if [ "$(jqin '.tool_input.force // false')" = "true" ] \
      || [ "$(jqin '.tool_input.forceWithLease // false')" = "true" ] \
      || [ "$(jqin '.tool_input.delete // false')" = "true" ]; then
      deny "force/delete push blocked; a human runs these."
    fi

    # 3. Require an absolute repo path — checked BEFORE any git invocation so
    #    this hook never resolves against its own cwd (the git MCP server has
    #    one global cwd and concurrent agents race on it, and resolves a
    #    relative path such as ./ or a subfolder against that cwd, not this one).
    PATH_ARG=$(jqin '.tool_input.path // empty')
    case "$PATH_ARG" in
      /*) ;;
      *) deny "pass an absolute repo path — the git MCP has one global cwd and concurrent agents race on it." ;;
    esac

    # Ground truth for remote-prefix stripping: the repo's actual remote names.
    # A blind prefix strip can't distinguish origin/main (remote-qualified main)
    # from release/production (a real slashed branch name) — only the configured
    # remote list can. Empty if the path isn't a repo (strip becomes a no-op).
    REMOTES=$(git -C "$PATH_ARG" remote 2>/dev/null || true)
    strip_remote() {
      local r="$1" rem
      # Newline-split: git permits remote names containing spaces.
      while IFS= read -r rem; do
        [ -n "$rem" ] || continue
        case "$r" in
          "$rem"/*) printf '%s' "${r#"$rem"/}"; return ;;
        esac
      done <<< "$REMOTES"
      printf '%s' "$r"
    }

    # 4. Explicit protected-branch targets — normalized (refs/heads/main,
    #    heads/main) AND remote-prefix-stripped against the real remote list
    #    (origin/main), so qualified forms cannot bypass the match.
    BRANCH=$(jqin '.tool_input.branch // empty')
    REMOTE_BRANCH=$(jqin '.tool_input.remoteBranch // empty')
    # HEAD and @ name the current branch: treat them as no branch, so step 5 resolves the real destination.
    case "$(norm_ref "$BRANCH")" in HEAD|@) BRANCH="" ;; esac
    case "$(norm_ref "$REMOTE_BRANCH")" in HEAD|@) REMOTE_BRANCH="" ;; esac
    for B in "$BRANCH" "$REMOTE_BRANCH"; do
      case "$(strip_remote "$(norm_ref "$B")")" in
        main|master|production) deny "direct push to protected branch '$B' blocked — land via PR." ;;
      esac
    done

    # 5. No branch param → resolve the actual push destination. @{push} catches
    #    upstream-to-main mappings (push.default=upstream); fall back to the
    #    current branch. Indeterminate = deny.
    if [ -z "$BRANCH" ] && [ -z "$REMOTE_BRANCH" ]; then
      DEST=$(git -C "$PATH_ARG" rev-parse --abbrev-ref '@{push}' 2>/dev/null)
      # @{push} yields a remote-tracking form (<remote>/<branch>); the fallback
      # is a plain local branch name. strip_remote handles both correctly.
      [ -n "$DEST" ] || DEST=$(git -C "$PATH_ARG" branch --show-current 2>/dev/null)
      DEST=$(strip_remote "$(norm_ref "$DEST")")
      case "$DEST" in
        ""|HEAD) deny "push destination could not be resolved (detached HEAD or unknown repo) — indeterminate targets are blocked; pass an explicit feature branch." ;;
        main|master|production) deny "push destination resolves to protected branch '$DEST' — land via PR." ;;
      esac
    fi
    exit 0
    ;;

  mcp__git-mcp__git_reset)
    MODE=$(jqin '.tool_input.mode // empty')
    case "$MODE" in
      hard|merge) deny "git reset --$MODE discards work; blocked — a human runs these." ;;
    esac
    exit 0
    ;;

  mcp__git-mcp__git_clean)
    [ "$(jqin '.tool_input.dryRun // false')" = "true" ] && exit 0
    deny "git clean deletes untracked files; blocked — preview with dryRun:true, a human runs the real clean."
    ;;

  mcp__git-mcp__git_worktree)
    deny "git worktree operations create concurrent checkouts of the locked workspace; blocked — a human runs these."
    ;;

  *)
    exit 0
    ;;
esac

exit 0
