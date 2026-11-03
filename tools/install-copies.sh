#!/bin/bash
# What the toolkit installs outside the checkout, and whether it is current. Never writes anything.
#
#   bash tools/install-copies.sh status            one line per piece; exit 1 if any needs attention
#   bash tools/install-copies.sh render [--show]   a github-mcp file on stdin, filled in from the settings
#   bash tools/install-copies.sh automode [--valued | --for-cleanup]   the setup template's autoMode lists, filled in
#
# Pieces `status` checks (/setup-claude Step 8b, and the `ait-status` zsh helper):
#   install.conf   ~/.claude/install.conf, the install-time settings /setup-claude writes, one key=value line each,
#                  never sourced. Required: github_write_owners, github_keychain_account; optional:
#                  github_username, lan_host, router_ip. Any other well-formed key (lowercase letters and _) is
#                  skipped, so a file another installer added its own keys to still reads; `status` lists them.
#   github-mcp     the root-owned launcher and guard (/usr/local/libexec/mcp-github): main rendered with the settings,
#                  then the owner and mode of the folder and both files. `ghm-install` (tools/ait.zsh) installs them.
#   ~/.zshrc       sources ~/.claude/tools/shell-init.zsh, which loads the zsh helpers.
#   links          every agent, hook, rule, global skill and tool script with no link under ~/.claude, or a wrong one.
# Tests: bash tools/test-install-copies.sh. The ICOPIES_* overrides are honoured only when ICOPIES_TESTING=1.

set -u

if [ "${ICOPIES_TESTING:-0}" != 1 ]; then
  unset ICOPIES_ROOT ICOPIES_HOME ICOPIES_REF ICOPIES_MCP_DIR ICOPIES_ZDOTDIR ICOPIES_SKIP_PERM_CHECK
fi

SELF_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
ROOT="${ICOPIES_ROOT:-$(cd "$SELF_DIR/.." && pwd -P)}"
HOME_DIR="${ICOPIES_HOME:-$HOME}"
REF="${ICOPIES_REF:-main}"
MCP_DIR="${ICOPIES_MCP_DIR:-/usr/local/libexec/mcp-github}"
MCP_PERM='root:wheel 755'
CLAUDE_DIR="$HOME_DIR/.claude"
CONF="$CLAUDE_DIR/install.conf"
ZDOT="${ICOPIES_ZDOTDIR:-${ZDOTDIR:-$HOME_DIR}}"
STAT=/usr/bin/stat  # BSD stat flags; a GNU stat earlier on PATH reads them differently

BAD=0

g() { command git -C "$ROOT" "$@"; }
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

# render_mcp: a github-mcp file on stdin with its placeholders filled from the settings read by read_conf (the owners
# as a compact lowercase JSON array, in the order given), on stdout.
render_mcp() {
  local o json=""
  for o in $CONF_OWNERS; do json="$json${json:+,}\"$o\""; done
  sed -e "s|__GITHUB_WRITE_OWNERS__|[$json]|g" -e "s|__GITHUB_KEYCHAIN_ACCOUNT__|$CONF_ACCOUNT|g"
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
  g merge-base --is-ancestor "$o" "$REF_SHA" 2>/dev/null && return 0
  line STALE "$REF is behind origin/$REF as of the last fetch" "fast-forward $REF, then re-run"
  return 0
}

# perm_ok <path>: owner, group and mode are MCP_PERM (always true with ICOPIES_SKIP_PERM_CHECK=1). Sets PERM.
perm_ok() {
  PERM=$("$STAT" -f '%Su:%Sg %Lp' "$1" 2>/dev/null)
  [ "${ICOPIES_SKIP_PERM_CHECK:-0}" = 1 ] || [ "$PERM" = "$MCP_PERM" ]
}

status_github_mcp() {
  local f fix="ghm-install (needs sudo)"
  [ -n "$REF_SHA" ] || return
  if [ ! -d "$MCP_DIR" ]; then
    line MISSING "github-mcp ($MCP_DIR does not exist)" "$fix"
    return
  fi
  perm_ok "$MCP_DIR" || line STALE "github-mcp folder (owner/mode is '$PERM', want '$MCP_PERM')" "$fix"
  read_conf
  case $? in
    0) ;;
    1) line MISSING "github-mcp (install settings; run /setup-claude)"; return ;;
    *) line STALE "github-mcp (install settings: $CONF_ERR; run /setup-claude)"; return ;;
  esac
  for f in launch guard.sh; do
    if ! blob "tools/github-mcp/$f" | render_mcp | cmp -s - "$MCP_DIR/$f"; then
      line STALE "github-mcp $f (differs from $REF)" "$fix"
    elif ! perm_ok "$MCP_DIR/$f"; then
      line STALE "github-mcp $f (owner/mode is '$PERM', want '$MCP_PERM')" "$fix"
    else
      line ok "github-mcp $f"
    fi
  done
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

status_links() {
  local f n d
  LINK_OK=0 LINK_NEW=0 LINK_CONFLICT=0
  for f in "$ROOT"/agents/*.md; do [ -e "$f" ] && check_link "agents/${f##*/}" "$CLAUDE_DIR/agents/${f##*/}"; done
  for f in "$ROOT"/hooks/*.sh; do [ -e "$f" ] && check_link "hooks/${f##*/}" "$CLAUDE_DIR/hooks/${f##*/}"; done
  for f in "$ROOT"/rules/*.md; do [ -e "$f" ] && check_link "rules/${f##*/}" "$CLAUDE_DIR/rules/${f##*/}"; done
  for d in "$ROOT"/skills/*/; do
    n=${d%/}; n=${n##*/}
    [ -f "$ROOT/skills/$n/SKILL.md" ] && check_link "skills/$n" "$CLAUDE_DIR/skills/$n"
  done
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

# render [--show]: a github-mcp file on stdin, filled in from the settings, on stdout (--show: the two values instead).
# Exit 3 with no settings file, 1 when it is invalid or a placeholder is left (nothing printed then).
cmd_render() {
  local out rc
  read_conf
  rc=$?
  [ "$rc" = 1 ] && { fail "no install settings (~/.claude/install.conf); run /setup-claude"; return 3; }
  [ "$rc" = 0 ] || { fail "install settings invalid ($CONF_ERR); run /setup-claude"; return 1; }
  if [ "${1:-}" = --show ]; then
    printf 'github_write_owners: %s\ngithub_keychain_account: %s\n' "$CONF_OWNERS" "$CONF_ACCOUNT"
    return 0
  fi
  out=$(render_mcp) || { fail "the render failed"; return 1; }
  if printf '%s' "$out" | grep -Eq '__[A-Z][A-Z0-9_]*__'; then fail "a placeholder is left; not rendered"; return 1; fi
  printf '%s\n' "$out"
}

# installed_owners: the owner list of the installed guard, or nothing when there is none.
installed_owners() { sed -n "s/^WRITE_OWNERS='\(\[[^']*\]\)'\$/\1/p" "$MCP_DIR/guard.sh" 2>/dev/null | head -n 1; }

# automode [--valued | --for-cleanup]: the setup template's autoMode lists (keys starting with _ left out) as JSON, each
# <username>, <host> and <router.ip> filled from the github_username, lan_host and router_ip settings; an entry naming
# an unset one is dropped, so no placeholder is ever printed. No settings file: every such entry is dropped. A
# <username> entry widens what the classifier trusts, so it is kept only while github_username is among the write
# owners of the installed guard; otherwise it is dropped and the reason goes to stderr.
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
    case $(installed_owners) in
      *"\"$u\""*) ;;
      *) echo "automode: the <username> entries are left out: github_username ($u) is not a write owner in the installed guard ($MCP_DIR/guard.sh); run ghm-install first" >&2
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
  render) shift; cmd_render "$@" ;;
  automode) shift; cmd_automode "$@" ;;
  *) fail "usage: install-copies.sh status | render [--show] | automode [--valued | --for-cleanup]"; exit 2 ;;
esac
