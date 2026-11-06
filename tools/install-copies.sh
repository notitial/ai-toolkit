#!/bin/bash
# What the toolkit installs outside the checkout, and whether it is current. Never writes anything.
#
#   bash tools/install-copies.sh status            one line per piece; exit 1 if any needs attention
#   bash tools/install-copies.sh roster            what /setup-claude links: the agents, hooks, rules and skills
#                                                  committed at HEAD, one repo path per line (never an untracked file)
#   bash tools/install-copies.sh automode [--valued | --for-cleanup]   the setup template's autoMode lists, filled in
#
# Pieces `status` checks (/setup-claude Step 8b, and the `ait-status` zsh helper):
#   install.conf   ~/.claude/install.conf, the install-time settings /setup-claude writes, one key=value line each,
#                  never sourced. Required: github_write_owners, github_keychain_account; optional:
#                  github_username, lan_host, router_ip. Any other well-formed key (lowercase letters and _) is
#                  skipped, so a file another installer added its own keys to still reads; `status` lists them.
#   github-mcp     the launcher and the guard run from this checkout: it is on a clean main, the pinned server binary
#                  is in tools/github-mcp/bin/, the `github` MCP server and the guard hook point at this checkout.
#   ~/.zshrc       sources ~/.claude/tools/shell-init.zsh, which loads the zsh helpers.
#   links          every agent, hook, rule, global skill and tool script with no link under ~/.claude, or a wrong one.
# Tests: bash tools/test-install-copies.sh. The ICOPIES_* overrides are honoured only when ICOPIES_TESTING=1.

set -u

if [ "${ICOPIES_TESTING:-0}" != 1 ]; then
  unset ICOPIES_ROOT ICOPIES_HOME ICOPIES_REF ICOPIES_ZDOTDIR
fi

SELF_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
ROOT="${ICOPIES_ROOT:-$(cd "$SELF_DIR/.." && pwd -P)}"
HOME_DIR="${ICOPIES_HOME:-$HOME}"
REF="${ICOPIES_REF:-main}"
CLAUDE_DIR="$HOME_DIR/.claude"
CONF="$CLAUDE_DIR/install.conf"
ZDOT="${ICOPIES_ZDOTDIR:-${ZDOTDIR:-$HOME_DIR}}"

BAD=0

# g: git on this checkout, pinned like the guard's live_git (tools/github-mcp/guard.sh): its .git/config is a file
# edit away, so no fsmonitor, hook, pager, lazy fetch, transport, replace ref, graft, commit-graph or trace2 target from it, and the work tree is
# this checkout whatever core.worktree says. Callers use only commands that run no filter or external diff.
g() {
  /usr/bin/env GIT_DIR="$ROOT/.git" GIT_WORK_TREE="$ROOT" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null GIT_TRACE2=0 \
    GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none /usr/bin/git --no-pager \
    -c core.fsmonitor=false -c core.commitGraph=false \
    -c core.useReplaceRefs=false -c core.hooksPath=/dev/null -C "$ROOT" "$@"
}
# tracked_changes: prints a line when any tracked file differs from HEAD (index against HEAD, then each file hashed
# with --no-filters against the index, as the guard checks it); prints nothing for a clean checkout.
tracked_changes() {
  local idx
  g diff-index --cached --quiet --no-ext-diff --no-textconv HEAD -- 2>/dev/null || echo "staged changes"
  idx=$(g ls-files -s 2>/dev/null) || { echo "index unreadable"; return; }
  [ -n "$idx" ] || return 0
  printf '%s\n' "$idx" | grep -Eqv '^100(644|755) [0-9a-f]{40,64} 0[[:blank:]]'
  [ $? -eq 1 ] || echo "a symlink, submodule or conflict"
  [ "$(printf '%s\n' "$idx" | cut -d ' ' -f 2)" = "$(printf '%s\n' "$idx" | cut -f 2- | g hash-object --no-filters --stdin-paths 2>/dev/null)" ] ||
    echo "a tracked file differs"
}
# redact: a token-shaped value in a printed command is hidden, so a status line never carries a secret
redact() { sed -E 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/[REDACTED]/g'; }
note() { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; }

# The commit the branch REF points at, and a repo path's blob there.
REF_SHA=$(g rev-parse --verify -q "refs/heads/$REF^{commit}" 2>/dev/null)
blob() { [ -n "$REF_SHA" ] && g cat-file blob "$REF_SHA:$1" 2>/dev/null; }

line() {  # line <ok|STALE|MISSING|UNLINKED|CONFLICT> <name> [fix]
  if [ "$1" = ok ]; then
    printf '%-9s %s\n' "$1" "$2"
  else
    BAD=$((BAD + 1))
    printf '%-9s %s%s\n' "$1" "$2" "${3:+  -> $3}"
  fi
}

# read_conf: 0 valid (CONF_OWNERS, CONF_ACCOUNT and the optional CONF_* set), 1 no file, 2 invalid (CONF_ERR is
# "<key>: <reason>"). Every value of a known key is checked against its pattern; a well-formed key this script does
# not use is skipped unread and named in CONF_SKIPPED; the file is never sourced. The account goes into a sed
# replacement and a shell line, so its pattern keeps out | & \ and every space and quote.
conf_ok() { printf '%s\n' "$1" | grep -Eqx -- "$2"; }
read_conf() {
  local line k v n=0 seen=" " oct='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  CONF_OWNERS="" CONF_ACCOUNT="" CONF_GITHUB_USERNAME="" CONF_LAN_HOST="" CONF_ROUTER_IP=""
  CONF_ERR="" CONF_SKIPPED=""
  [ -f "$CONF" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case $line in '' | '#'*) continue ;; *=*) ;; *) CONF_ERR="line $n: not key=value"; return 2 ;; esac
    k=${line%%=*} v=${line#*=}
    # The letters spelled out: a locale's [a-z] can take in capitals.
    case $k in '' | *[!abcdefghijklmnopqrstuvwxyz_]*) CONF_ERR="line $n: not a well-formed key"; return 2 ;; esac
    case $seen in *" $k "*) CONF_ERR="$k: given twice"; return 2 ;; esac
    seen="$seen$k "
    case $k in
      github_write_owners) conf_ok "$v" '[a-z0-9][a-z0-9-]*( [a-z0-9][a-z0-9-]*)*' && CONF_OWNERS=$v ;;
      github_keychain_account) conf_ok "$v" '[A-Za-z0-9._@-]+' && CONF_ACCOUNT=$v ;;
      github_username) conf_ok "$v" '[a-z0-9][a-z0-9-]*' && CONF_GITHUB_USERNAME=$v ;;
      lan_host) conf_ok "$v" '[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*\.(lan|local|home\.arpa)' && CONF_LAN_HOST=$v ;;
      router_ip) conf_ok "$v" "(10\\.$oct\\.$oct\\.$oct|172\\.(1[6-9]|2[0-9]|3[01])\\.$oct\\.$oct|192\\.168\\.$oct\\.$oct)" && CONF_ROUTER_IP=$v ;;
      *) CONF_SKIPPED="$CONF_SKIPPED${CONF_SKIPPED:+ }$k" ;;
    esac || { CONF_ERR="$k: invalid value"; return 2; }
  done < "$CONF"
  for k in github_write_owners github_keychain_account; do
    case $seen in *" $k "*) ;; *) CONF_ERR="$k: missing"; return 2 ;; esac
  done
  return 0
}

status_install_conf() {
  read_conf
  case $? in
    0) line ok "install.conf${CONF_SKIPPED:+ (skipped, not used here: $CONF_SKIPPED)}" ;;
    1) line MISSING "install.conf (the install-time settings)" "/setup-claude" ;;
    *) line STALE "install.conf ($CONF_ERR)" "/setup-claude" ;;
  esac
}

status_ref() {
  local o
  if [ -z "$REF_SHA" ]; then
    line STALE "branch '$REF' not found in $ROOT" "fix the checkout"
    return 1
  fi
  o=$(g rev-parse --verify -q "refs/remotes/origin/$REF^{commit}" 2>/dev/null) || return 0
  [ "$o" = "$REF_SHA" ] && return 0
  g merge-base --is-ancestor "$o" "$REF_SHA" >/dev/null 2>&1 && return 0
  line STALE "$REF is behind origin/$REF as of the last fetch" "fast-forward $REF, then re-run"
  return 0
}

BIN_REL=tools/github-mcp/bin/github-mcp-server

# The launcher and the guard run from this checkout: it must be reviewed code (on main, no tracked change, HEAD on
# origin/main), the pinned server binary must sit beside them, and the `github` MCP server and the guard hook must
# point here (a copy elsewhere, or the old root-owned folder, is stale).
status_github_mcp() {
  local br dirty want cfg have cmds nproj pin got
  # /setup-claude skips the guard hook for a path with other characters, and the launcher refuses one: name that cause
  # instead of sending the user to /setup-claude or to `claude mcp add`, which cannot fix it.
  case $ROOT in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._+-]*)
      line STALE "github-mcp checkout path ($ROOT has characters other than letters, digits and / . _ + -: /setup-claude writes no guard hook and the launcher refuses to start)" "move the checkout to a plain path, then run /setup-claude"
      return ;;
  esac
  br=$(g symbolic-ref -q HEAD 2>/dev/null)
  case $br in refs/heads/*) br=${br#refs/heads/} ;; '') ;; *) br="HEAD at $br" ;; esac
  dirty=$(tracked_changes)
  if [ "$br" != main ] || [ -n "$dirty" ]; then
    line STALE "github-mcp checkout (${br:-no branch}${dirty:+, with edits}: the guard and the launcher are off)" "work in a /tmp clone; put this checkout back on a clean main"
  elif [ -z "$(g rev-parse -q --verify HEAD:tools/github-mcp/server.sha256 2>/dev/null)" ]; then
    line STALE "github-mcp checkout (tools/github-mcp/server.sha256 is not committed on main yet: the launcher is off)" "record the binary's hash through a PR (tools/github-mcp/README.md, Install)"
  elif ! g merge-base --is-ancestor HEAD refs/remotes/origin/main >/dev/null 2>&1; then
    line STALE "github-mcp checkout (main holds commits that origin/main lacks, or origin/main is unknown: the guard and the launcher are off)" "push them through a PR, or reset main to origin/main"
  else
    line ok "github-mcp checkout is on a clean main"
  fi
  if [ -e "$ROOT/$BIN_REL" ] && [ ! -x "$ROOT/$BIN_REL" ]; then
    line STALE "github-mcp server binary (not executable)" "chmod 755 $BIN_REL"
  elif [ -x "$ROOT/$BIN_REL" ]; then
    pin=$(g cat-file blob HEAD:tools/github-mcp/server.sha256 2>/dev/null | sed -n 's/^\([0-9a-f]\{64\}\)  *github-mcp-server$/\1/p' | head -n 1)
    got=$(/usr/bin/shasum -a 256 "$ROOT/$BIN_REL" 2>/dev/null | sed -n 's/^\([0-9a-f]\{64\}\)  .*/\1/p')
    if [ -z "$pin" ]; then
      line STALE "github-mcp server binary (tools/github-mcp/server.sha256 at HEAD is missing or malformed: the launcher refuses to start it)" "tools/github-mcp/README.md, Install"
    elif [ "$pin" = "$got" ]; then
      line ok "github-mcp server binary"
    else
      line STALE "github-mcp server binary (does not match tools/github-mcp/server.sha256: the launcher refuses to start it)" "tools/github-mcp/README.md, Install"
    fi
  else
    line MISSING "github-mcp server binary ($BIN_REL)" "tools/github-mcp/README.md, Install"
  fi
  command -v jq >/dev/null 2>&1 || { line MISSING "github-mcp wiring (needs jq to read the settings)" "brew install jq"; return; }
  want="$ROOT/tools/github-mcp/launch"
  cfg="$HOME_DIR/.claude.json"
  # The registered command, with a note when it carries arguments or an environment (an argument such as --clean-env
  # skips the launcher's first stage).
  # A server with no command (an http or sse one) shows its URL and type, so it reads as STALE, never as unregistered.
  have=$(jq -r '.mcpServers.github as $s | if ($s | type) != "object" then ""
    elif ($s.command // "") == "" then (($s.url // "no command") | tostring) + " (type " + (($s.type // "unknown") | tostring) + ")"
    else $s.command + (if (($s.args // []) | length) > 0 or (($s.env // {}) | length) > 0 then " (with arguments or environment)" else "" end) end' "$cfg" 2>/dev/null | redact)
  if [ "$have" = "$want" ]; then
    line ok "github MCP server registered at this checkout"
  elif [ -z "$have" ]; then
    line MISSING "github MCP server (not registered in ~/.claude.json)" "claude mcp add --scope user github -- $want"
  else
    line STALE "github MCP server (registered at $have)" "claude mcp remove --scope user github, then claude mcp add --scope user github -- $want"
  fi
  # A project-scope server named github would outrank the user-scope one and skip the launcher and its tool list.
  nproj=$(jq -r '[.projects[]? | .mcpServers.github? | select(type == "object")] | length' "$cfg" 2>/dev/null)
  if [ "${nproj:-0}" != 0 ]; then
    line STALE "github MCP server (also defined at project scope in $nproj place(s) of ~/.claude.json)" "claude mcp remove --scope local github, in each project"
  fi
  want="/bin/bash -p '$ROOT/tools/github-mcp/guard.sh' || exit 2"
  cmds=$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "^mcp__github__.*$") | .hooks[]?.command | select(type == "string" and test("(github-mcp|mcp-github)/guard[.]sh"))] | .[]' "$CLAUDE_DIR/settings.json" 2>/dev/null | redact)
  if printf '%s\n' "$cmds" | grep -Fxq -- "$want"; then
    line ok "github MCP guard hook points at this checkout"
  elif [ -z "$cmds" ]; then
    line MISSING "github MCP guard hook (none in ~/.claude/settings.json)" "/setup-claude"
  else
    line STALE "github MCP guard hook (points at $(printf '%s' "$cmds" | head -n 1))" "/setup-claude"
  fi
}

status_zshrc() {
  local show="~/.zshrc"
  [ "$ZDOT" = "$HOME_DIR" ] || show="$ZDOT/.zshrc"
  if [ -f "$ZDOT/.zshrc" ] && grep -Eq "^[[:space:]]*(source|\\.)[[:space:]]+[^#]*\\.claude/tools/shell-init\\.zsh([[:space:]\"';]|\$)" "$ZDOT/.zshrc"; then
    line ok "$show loads the zsh helpers"
  else
    line MISSING "$show does not load the zsh helpers" "add: source ~/.claude/tools/shell-init.zsh"
  fi
}

# check_link <repo path> <link path>: counts into LINK_OK / LINK_NEW / LINK_CONFLICT and prints the problems.
check_link() {
  if [ -L "$2" ] && [ "$2" -ef "$ROOT/$1" ]; then
    LINK_OK=$((LINK_OK + 1))
  elif [ ! -e "$2" ] && [ ! -L "$2" ]; then
    LINK_NEW=$((LINK_NEW + 1))
    line UNLINKED "${2#$HOME_DIR/}" "/setup-claude"
  else
    LINK_CONFLICT=$((LINK_CONFLICT + 1))
    line CONFLICT "${2#$HOME_DIR/} (not a link to $1)" "/setup-claude reports it; resolve by hand"
  fi
}

# roster: what /setup-claude links, one repo path per line: the agents, hooks, rules and skills committed at HEAD (a
# skill as skills/<name>). A file that is only on disk (untracked, or on another branch) is never listed, so it is never
# linked into ~/.claude.
cmd_roster() {
  g ls-tree -r --name-only HEAD -- agents hooks rules skills 2>/dev/null |
    sed -n -e '/^agents\/[^/]*\.md$/p' -e '/^hooks\/[^/]*\.sh$/p' -e '/^rules\/[^/]*\.md$/p' \
      -e 's/^\(skills\/[^/]*\)\/SKILL\.md$/\1/p'
}

status_links() {
  local p
  LINK_OK=0 LINK_NEW=0 LINK_CONFLICT=0
  while IFS= read -r p; do
    [ -n "$p" ] && check_link "$p" "$CLAUDE_DIR/$p"
  done <<EOF
$(cmd_roster)
EOF
  check_link tools/statusline.sh "$CLAUDE_DIR/statusline.sh"
  check_link tools/workspace-lock/workspace-lock.sh "$CLAUDE_DIR/tools/workspace-lock.sh"
  check_link tools/shell-init.zsh "$CLAUDE_DIR/tools/shell-init.zsh"
  note "links     $LINK_OK linked, $LINK_NEW unlinked, $LINK_CONFLICT conflicting"
}

cmd_status() {
  status_ref
  status_install_conf
  status_github_mcp
  status_zshrc
  status_links
  if [ "$BAD" -eq 0 ]; then
    note "all current"
    return 0
  fi
  note "$BAD need attention"
  return 1
}

# automode [--valued | --for-cleanup]: the setup template's autoMode lists (keys starting with _ left out) as JSON, each
# <username>, <host> and <router.ip> filled from the github_username, lan_host and router_ip settings; an entry naming
# an unset one is dropped, so no placeholder is ever printed. No settings file: every such entry is dropped. A
# <username> entry widens what the classifier trusts, so it is kept only while github_username is among the
# github_write_owners of install.conf (what the guard reads); otherwise it is dropped and the reason goes to stderr.
# --valued: only the entries that carry an install.conf value (the ones /setup-claude adds only on the user's go).
# --for-cleanup: every placeholder filled without the guard check, to match lines for removal, never to add any.
# Exit 1 on an invalid settings file, 2 on an unknown option.
cmd_automode() {
  local tpl="$ROOT/.claude/skills/setup-claude/templates/safe-permissions.json" mode=${1:-} u
  case $mode in '' | --valued | --for-cleanup) ;; *) fail "automode: unknown option $mode"; return 2 ;; esac
  read_conf
  [ $? = 2 ] && { fail "install settings invalid ($CONF_ERR); run /setup-claude"; return 1; }
  command -v jq >/dev/null 2>&1 || { fail "automode needs jq"; return 1; }
  u=$CONF_GITHUB_USERNAME
  if [ -n "$u" ] && [ "$mode" != --for-cleanup ]; then
    case " $CONF_OWNERS " in
      *" $u "*) ;;
      *) echo "automode: the <username> entries are left out: github_username ($u) is not in github_write_owners in $CONF" >&2
         u="" ;;
    esac
  fi
  jq --arg u "$u" --arg h "$CONF_LAN_HOST" --arg r "$CONF_ROUTER_IP" --arg valued "$([ "$mode" = --valued ] && echo 1)" '
    def ph: test("<username>|<host>|<router[.]ip>");
    def unset_ref: (test("<username>") and $u == "") or (test("<host>") and $h == "") or (test("<router[.]ip>") and $r == "");
    def fill: gsub("<username>"; $u) | gsub("<host>"; $h) | gsub("<router[.]ip>"; $r);
    def keep: if type != "string" then $valued != "1" elif unset_ref then false elif $valued == "1" then ph else true end;
    .autoMode | with_entries(select(.key | startswith("_") | not))
    | map_values(if type == "array" then map(select(keep) | if type == "string" then fill else . end) else . end)
    | if $valued == "1" then with_entries(select((.value | type) == "array" and (.value | length) > 0)) else . end
  ' "$tpl" || { fail "cannot read autoMode from $tpl"; return 1; }
}

case "${1:-}" in
  status) cmd_status ;;
  roster) cmd_roster ;;
  automode) shift; cmd_automode "$@" ;;
  *) fail "usage: install-copies.sh status | roster | automode [--valued | --for-cleanup]"; exit 2 ;;
esac
