#!/bin/bash
# Removes what this repo installed on this machine, so /setup-claude can start from nothing. Dry run by default.
#   bash tools/cleanup-claude/cleanup.sh [--apply] [--purge-ask] [--keep-ambiguous] [--remove-guard-hook] [--include-security] [--verbose]
#   --apply             do it (without it, nothing is changed: the report is the dry run)
#   --purge-ask         also remove the items classed ASK (user-authored or history: the ETA log)
#   --keep-ambiguous    leave permission allow entries, plugins and autoMode context lines the template also lists,
#                       and a promptCacheTtl or subagentPromptCacheTtl of "1h" (the opt-in /setup-claude asks about)
#   --remove-guard-hook also remove the github MCP guard hook (kept by default: without it a still-registered server
#                       runs unguarded; /cleanup-claude asks the user before passing this)
#   --include-security  also remove the security entries the template lists: permission ask and deny, deniedMcpServers,
#                       ENABLE_CLAUDEAI_MCP_SERVERS, enableAllProjectMcpServers, autoMode soft_deny, and the guard hook
#                       (kept by default; /setup-claude puts them back). --include-deny is the same flag, old name
#   --verbose           list every settings value path that goes (paths only, never values)
# Never touched: login, Keychain items, transcripts, session registry, CLAUDE.md, settings backups, the checkout.
# Never run for you: sudo, `claude mcp remove`, npm -g, Keychain deletes. Those are printed as commands.
# Test hooks, honoured only with CLEANUP_TESTING=1: CLEANUP_HOME (instead of $HOME), CLEANUP_LIBEXEC (instead of
# /usr/local/libexec), CLEANUP_ZDOTDIR (instead of $ZDOTDIR, which is then ignored), CLEANUP_NO_LAUNCHCTL=1. Without
# it they are unset, so a stray exported variable cannot retarget a run.

set -u
umask 077
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P) || exit 2
TEMPLATE="$ROOT/.claude/skills/setup-claude/templates/safe-permissions.json"

APPLY=0 PURGE=0 KEEP_AMB=0 SEC=0 RMGUARD=0 VERBOSE=0 KEPT_ROOT_GUARD=0
usage() { sed -n '2,15p' "$0" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --apply) APPLY=1 ;;
    --purge-ask) PURGE=1 ;;
    --keep-ambiguous) KEEP_AMB=1 ;;
    --remove-guard-hook) RMGUARD=1 ;;
    --include-security | --include-deny) SEC=1 ;;
    --verbose) VERBOSE=1 ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) usage ;;
  esac
  shift
done
# --include-security covers the guard hook too: passing it is the user's go in advance.
[ "$SEC" = 1 ] && RMGUARD=1

[ "${CLEANUP_TESTING:-0}" = 1 ] || unset CLEANUP_HOME CLEANUP_LIBEXEC CLEANUP_ZDOTDIR CLEANUP_NO_LAUNCHCTL

command -v jq >/dev/null 2>&1 || { echo "cleanup: needs jq" >&2; exit 3; }
[ -d "$ROOT/hooks" ] && [ -f "$TEMPLATE" ] || { echo "cleanup: $ROOT is not the ai-toolkit checkout" >&2; exit 3; }

HOME_DIR=${CLEANUP_HOME:-$HOME}
case $HOME_DIR in /?*) ;; *) echo "cleanup: home must be an absolute path, got '$HOME_DIR'" >&2; exit 2 ;; esac
[ -d "$HOME_DIR" ] || { echo "cleanup: $HOME_DIR is not a directory" >&2; exit 2; }
HOME_DIR=$(cd -P "$HOME_DIR" && pwd -P)
LIBEXEC=${CLEANUP_LIBEXEC:-/usr/local/libexec}

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cleanup-claude-XXXXXX") || exit 2
trap 'rm -rf "$SCRATCH"' EXIT

phys() { (cd -P "$1" 2>/dev/null && pwd -P); }

# The one config dir to clean, ~/.claude, physical. The loops below still read it from CFGS, one line per dir.
CFGS=$(phys "$HOME_DIR/.claude") || CFGS=""
[ -n "$CFGS" ] || { echo "cleanup: no Claude config dir found under $HOME_DIR" >&2; exit 2; }
CFGS="$CFGS"$'\n'

N_REMOVE=0 N_EDIT=0 N_MANUAL=0 N_ASK=0 N_FAIL=0
say() { printf '%-7s %s\n' "$1" "$2"; }

# in_roots <dir-or-path> <strict>: under the home dir or a config dir being cleaned (strict: not the root itself).
in_roots() {
  local x=$1 strict=$2 c
  if [ "$strict" = 1 ]; then case $x in "$HOME_DIR"/?*) return 0 ;; esac
  else case $x in "$HOME_DIR" | "$HOME_DIR"/*) return 0 ;; esac; fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [ "$strict" = 1 ]; then case $x in "$c"/?*) return 0 ;; esac
    else case $x in "$c" | "$c"/*) return 0 ;; esac; fi
  done <<EOF
$CFGS
EOF
  return 1
}
# Anything removed must sit under the home dir or a config dir, with no '..', and so must the folder it is in once symlinks
# are resolved (a symlinked folder can lead out of both).
allowed() {
  local p=$1 d
  case $p in *..*) return 1 ;; esac
  in_roots "$p" 1 || return 1
  d=$(phys "$(dirname "$p")")
  [ -z "$d" ] || in_roots "$d" 0
}

# remove_path <path> <why>: a link or file is unlinked; a real directory is removed with its contents.
remove_path() {
  local p=$1 why=$2
  [ -e "$p" ] || [ -L "$p" ] || return 0
  if ! allowed "$p"; then say SKIP "$p (outside the home and config dirs)"; return 0; fi
  N_REMOVE=$((N_REMOVE + 1))
  if [ "$APPLY" = 1 ]; then
    if [ -d "$p" ] && [ ! -L "$p" ]; then rm -r "$p"; else rm "$p"; fi || { N_FAIL=$((N_FAIL + 1)); say FAIL "$p"; return 0; }
  fi
  say REMOVE "$p  ($why)"
}

# A link is the toolkit's when it resolves into this checkout, or dangles at a path through /ai-toolkit/.
link_is_toolkit() {
  local l=$1 raw tgt td
  [ -L "$l" ] || return 1
  raw=$(readlink "$l") || return 1
  case $raw in /*) tgt=$raw ;; *) tgt=$(dirname "$l")/$raw ;; esac
  td=$(phys "$(dirname "$tgt")")
  [ -n "$td" ] && tgt="$td/$(basename "$tgt")"
  case $tgt in "$ROOT"/*) return 0 ;; esac
  if [ ! -e "$l" ]; then case $raw in */ai-toolkit/*) return 0 ;; esac; fi
  return 1
}

# One path per line. A folder that is itself a symlink is a single candidate and is never entered.
toolkit_links() {
  local cfg sub f
  while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue
    for sub in agents hooks rules skills tools commands; do
      if [ -L "$cfg/$sub" ]; then
        link_is_toolkit "$cfg/$sub" && printf '%s\n' "$cfg/$sub"
        continue
      fi
      for f in "$cfg/$sub"/* "$cfg/$sub"/.[!.]*; do
        link_is_toolkit "$f" && printf '%s\n' "$f"
      done
    done
    link_is_toolkit "$cfg/statusline.sh" && printf '%s\n' "$cfg/statusline.sh"
  done <<EOF
$CFGS
EOF
}

# ---- 1. links into the checkout (only ever unlinked: a path that is not a link is left alone)
echo "== links into the checkout"
LINKS=$(toolkit_links)
if [ -n "$LINKS" ]; then
  while IFS= read -r l; do
    if [ -L "$l" ] && link_is_toolkit "$l" && allowed "$l"; then
      N_REMOVE=$((N_REMOVE + 1))
      if [ "$APPLY" = 1 ]; then rm -- "$l" || { N_FAIL=$((N_FAIL + 1)); say FAIL "$l"; continue; }; fi
      say REMOVE "$l  (link into the checkout)"
    else
      say SKIP "$l (not a toolkit link; left alone)"
    fi
  done <<EOF
$LINKS
EOF
fi
if [ "$APPLY" = 1 ]; then
  while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue
    for sub in agents hooks rules skills tools commands; do [ -L "$cfg/$sub" ] || rmdir "$cfg/$sub" 2>/dev/null; done
  done <<EOF
$CFGS
EOF
fi
[ -n "$LINKS" ] || say OK "no links into the checkout"

# ---- 2. settings.json: toolkit-managed keys only
echo "== settings"
# /setup-claude wrote the template's autoMode lines rendered from ~/.claude/install.conf, so match against the same
# render (tools/install-copies.sh automode --for-cleanup: every placeholder filled, for matching only). No settings
# file, or an unusable one: the raw template.
RTEMPLATE=$TEMPLATE
if [ -f "$HOME_DIR/.claude/install.conf" ]; then
  if AM=$(HOME="$HOME_DIR" bash "$ROOT/tools/install-copies.sh" automode --for-cleanup 2>/dev/null) &&
    jq --argjson am "$AM" '.autoMode = ((.autoMode // {}) + $am)' "$TEMPLATE" > "$SCRATCH/template.json" 2>/dev/null; then
    RTEMPLATE="$SCRATCH/template.json"
  else
    say SKIP "autoMode lines filled from install.conf (it is unusable): only the template's own lines are matched"
  fi
fi
# The hook scripts the repo ships, minus any name that is a real (non-link) file in a config dir: that one is the user's.
HOOK_NAMES=$({
  for f in "$ROOT"/hooks/*.sh; do [ -e "$f" ] && basename "$f"; done
  jq -r '[.hooks[]? | arrays | .[] | .hooks[]? | .command | strings | select(contains("/.claude/hooks/"))] | .[] | split("/") | last' "$TEMPLATE"
} | sort -u | while IFS= read -r n; do
  mine=0
  while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue
    [ -f "$cfg/hooks/$n" ] && [ ! -L "$cfg/hooks/$n" ] && mine=1
  done <<EOF
$CFGS
EOF
  [ "$mine" = 1 ] || printf '%s\n' "$n"
done | jq -R . | jq -s .)
CFG_JSON=$(printf '%s' "$CFGS" | jq -R . | jq -s 'map(select(. != ""))')
# The deny entries /setup-claude writes from this checkout's real path (not in the template): security entries, so
# they go only with --include-security, like the template's own deny entries.
LIVE_DENY=$(jq -n --arg r "$ROOT" '[".git/**", "hooks/**", "rules/**", "agents/**", "skills/**", "tools/github-mcp/**", "tools/workspace-lock/**", "tools/statusline.sh", "tools/shell-init.zsh", "tools/ait.zsh", "tools/accounts.zsh", "tools/install-copies.sh"] | map("Edit(/" + $r + "/" + . + ")")')

JQ_CLEAN='
def tl: $t[0];
def prune(k): if has(k) and (.[k] == {} or .[k] == []) then del(.[k]) else . end;
def rm_eq(k): if has(k) and .[k] == tl[k] then del(.[k]) else . end;
def sec_env: ["ENABLE_CLAUDEAI_MCP_SERVERS"];
# The github MCP guard hook of this checkout or the retired root-owned install: a security entry, removed only with
# --remove-guard-hook or --include-security (without it a still-registered server would run unguarded).
def guard_cmd:
  (type == "string") and (
    . == "/usr/local/libexec/mcp-github/guard.sh" or . == $guard or . == ("/bin/bash -p '"'"'" + $guard + "'"'"' || exit 2"));
# A hook command of the toolkit: the script path alone or with arguments, optionally under bash, never a chained command.
def toolkit_cmd:
  (type == "string") and (
    (guard_cmd and $rmguard == 1)
    or (sub("^bash +"; "") as $c
        | ($c | split(" ")[0] // "") as $w
        | (($c | test("&&|;|\\|")) | not)
          and any($names[]; . as $n
            | ($w | endswith("/.claude/hooks/" + $n))
              or any($cfgs[]; . as $d | $w == ($d + "/hooks/" + $n)))));
(if (.env | type) == "object" then
    .env |= with_entries(select(.key as $k | ((tl.env | has($k)) and ($sec == 1 or (sec_env | index($k) | not))) | not)) | prune("env")
  else . end)
| rm_eq("attribution") | rm_eq("autoCompactWindow")
# The cache TTL keys are not in the template: /setup-claude writes "1h" only when the user says yes. The value alone
# marks them, so they are ambiguous like an allow entry the user may have set themselves.
| (if $amb == 1 then
    (if .promptCacheTtl == "1h" then del(.promptCacheTtl) else . end)
    | (if .subagentPromptCacheTtl == "1h" then del(.subagentPromptCacheTtl) else . end)
  else . end)
| (if $sec == 1 then rm_eq("enableAllProjectMcpServers") else . end)
| (if $sec == 1 and (.deniedMcpServers | type) == "array" then
    .deniedMcpServers |= map(select(. as $e | ([tl.deniedMcpServers[]? | select(.serverUrl == ($e | try .serverUrl catch null))] | length) == 0))
    | prune("deniedMcpServers")
  else . end)
| (if (.skillOverrides | type) == "object" and .skillOverrides["auto-mode-setup"] == tl.skillOverrides["auto-mode-setup"]
   then del(.skillOverrides["auto-mode-setup"]) | prune("skillOverrides") else . end)
| (if (.statusLine | type) == "object" and .statusLine.command == tl.statusLine.command then del(.statusLine) else . end)
| (if (.hooks | type) == "object" then
    .hooks |= (with_entries(
        .value |= (if type == "array" then
            map(if type == "object" and (.hooks | type) == "array" then .hooks |= map(select(((.command? // "") | toolkit_cmd) | not)) else . end)
            | map(select(type != "object" or (.hooks | type) != "array" or (.hooks | length) > 0))
          else . end)
        | select((.value | type) != "array" or (.value | length) > 0))
      | if ([.[] | select(type == "array")] | length) == 0 then {} else . end)
    | prune("hooks")
  else . end)
| (if (.permissions | type) == "object" then
    reduce (((if $amb == 1 then ["allow"] else [] end) + (if $sec == 1 then ["ask", "deny"] else [] end))[]) as $k (.;
      if (.permissions[$k] | type) == "array" then
        .permissions[$k] |= map(select(. as $e | (any((tl.permissions[$k] // [])[]; . == $e) or ($k == "deny" and ($live | index($e)) != null)) | not))
        | (if .permissions[$k] == [] then del(.permissions[$k]) else . end)
      else . end)
    | prune("permissions")
  else . end)
| (if $amb == 1 and (.enabledPlugins | type) == "object" then
    .enabledPlugins |= with_entries(select(.key as $k | (tl.enabledPlugins | has($k)) | not)) | prune("enabledPlugins")
  else . end)
| (if (.autoMode | type) == "object" then
    reduce ([tl.autoMode | keys[] | select(startswith("_") | not)
             | select((. == "soft_deny" and $sec == 1) or (. != "soft_deny" and $amb == 1))][]) as $k (.;
      if (.autoMode[$k] | type) == "array" then
        .autoMode[$k] |= map(select(. as $e | any((tl.autoMode[$k])[] | select(. != "$defaults"); . == $e) | not))
        | (if .autoMode[$k] == [] or .autoMode[$k] == ["$defaults"] then del(.autoMode[$k]) else . end)
      else . end)
    | prune("autoMode")
  else . end)'

realfile() {
  local f=$1 n i=0
  while [ -L "$f" ] && [ "$i" -lt 20 ]; do
    n=$(readlink "$f")
    case $n in /*) f=$n ;; *) f=$(dirname "$f")/$n ;; esac
    i=$((i + 1))
  done
  printf '%s\n' "$f"
}
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
# A settings file this run leaves holding the root-owned guard hook keeps that folder: with guard.sh gone the bare hook
# command is a non-blocking error and github MCP calls run unguarded. A file not parsed is matched as text.
ROOT_GUARD=/usr/local/libexec/mcp-github/guard.sh
keep_if_root_guard() {  # keep_if_root_guard <file> <why it keeps its content>
  [ -f "$1" ] && grep -Fq "$ROOT_GUARD" "$1" 2>/dev/null || return 0
  KEPT_ROOT_GUARD=1
  say KEEP "$1: names the root-owned guard hook and $2"
}

SEEN_SETTINGS=""
while IFS= read -r cfg; do
  [ -n "$cfg" ] || continue
  sf="$cfg/settings.json"
  [ -e "$sf" ] || continue
  rf=$(realfile "$sf")
  [ -f "$rf" ] || { say SKIP "$sf (not a regular file)"; continue; }
  rf="$(phys "$(dirname "$rf")")/$(basename "$rf")"
  case $'\n'"$SEEN_SETTINGS" in *$'\n'"$rf"$'\n'*) say OK "$sf (same file as one already handled)"; continue ;; esac
  SEEN_SETTINGS="$SEEN_SETTINGS$rf"$'\n'
  if ! jq -e 'type == "object"' "$rf" >/dev/null 2>&1; then
    N_FAIL=$((N_FAIL + 1)); say FAIL "$rf (not valid JSON; left alone)"; keep_if_root_guard "$rf" "is left alone"; continue
  fi
  jq -S . "$rf" > "$SCRATCH/old.json"
  jq -S --slurpfile t "$RTEMPLATE" --argjson names "$HOOK_NAMES" --argjson cfgs "$CFG_JSON" \
    --arg guard "$ROOT/tools/github-mcp/guard.sh" --argjson live "$LIVE_DENY" \
    --argjson amb $((1 - KEEP_AMB)) --argjson sec "$SEC" --argjson rmguard "$RMGUARD" "$JQ_CLEAN" "$rf" > "$SCRATCH/new.json" 2>/dev/null
  if [ ! -s "$SCRATCH/new.json" ]; then
    N_FAIL=$((N_FAIL + 1)); say FAIL "$rf (the clean-up filter failed; left alone)"; keep_if_root_guard "$rf" "is left alone"; continue
  fi
  if [ "$RMGUARD" = 0 ] && jq -e --arg guard "$ROOT/tools/github-mcp/guard.sh" '[.hooks? // {} | .[]? | arrays | .[] | objects | .hooks? // [] | .[]? | .command? | strings
      | select(. == "/usr/local/libexec/mcp-github/guard.sh" or . == $guard or . == ("/bin/bash -p '"'"'" + $guard + "'"'"' || exit 2"))] | length > 0' \
      "$SCRATCH/new.json" >/dev/null 2>&1; then
    say KEEP "$rf: the github MCP guard hook (a security entry; --remove-guard-hook or --include-security removes it)"
    jq -e '[.. | objects | .command? | strings | select(. == "/usr/local/libexec/mcp-github/guard.sh")] | length > 0' \
      "$SCRATCH/new.json" >/dev/null 2>&1 && KEPT_ROOT_GUARD=1
  fi
  if cmp -s "$SCRATCH/old.json" "$SCRATCH/new.json"; then say OK "$rf (nothing of the toolkit's in it)"; continue; fi
  N_EDIT=$((N_EDIT + 1))
  say EDIT "$rf  (toolkit keys; a backup is written first)"
  jq -rn --slurpfile a "$SCRATCH/old.json" --slurpfile b "$SCRATCH/new.json" '
    ($a[0] | keys[] | select(. as $k | ($b[0] | has($k)) | not)) as $k | "        removed  \($k)"'
  jq -rn --slurpfile a "$SCRATCH/old.json" --slurpfile b "$SCRATCH/new.json" '
    ($a[0] | keys[] | select(. as $k | ($b[0] | has($k)) and $a[0][$k] != $b[0][$k])) as $k | "        trimmed  \($k)"'
  if [ "$VERBOSE" = 1 ]; then
    jq -rn --slurpfile a "$SCRATCH/old.json" --slurpfile b "$SCRATCH/new.json" '
      def leaves: [paths(scalars) | map(tostring) | join(".")];
      (($a[0] | leaves) - ($b[0] | leaves))[] | "          gone   " + .'
  fi
  if [ "$APPLY" = 1 ]; then
    bak="$rf.bak-$(date +%Y%m%d-%H%M%S)-cleanup"
    mode=$(fmode "$rf")
    if cp -n "$rf" "$bak" && chmod 600 "$bak"; then
      tmp="$rf.cleanup-tmp.$$"
      if cp "$SCRATCH/new.json" "$tmp" && jq -e . "$tmp" >/dev/null 2>&1 && chmod "${mode:-600}" "$tmp" && mv "$tmp" "$rf"; then
        say DONE "$rf  (backup: $bak)"
      else
        rm -f "$tmp"; N_FAIL=$((N_FAIL + 1)); say FAIL "$rf (write failed; backup kept at $bak)"
        keep_if_root_guard "$rf" "was not written"
      fi
    else
      N_FAIL=$((N_FAIL + 1)); say FAIL "$rf (no backup written; left alone)"; keep_if_root_guard "$rf" "was not written"
    fi
  fi
done <<EOF
$CFGS
EOF

# ---- 3. shell rc lines: whole lines that only source the toolkit; anything riskier is printed for the user
echo "== shell rc files"
RC_LOOSE='\.claude/tools/shell-init\.zsh'
RC_STRICT1="^[[:space:]]*(source|\\.)[[:space:]]+[\"']?[^#;&|\"']*\\.claude/tools/shell-init\\.zsh[\"']?[[:space:]]*\$"
RC_OPEN='(then|do|else|\{)[[:space:]]*$'
RC_CLOSE='^[[:space:]]*(fi|done|\}|else|elif)([[:space:]]|;|$)'
RC_CONT='(&&|\|\||\||\\)[[:space:]]*$'

# rc_scan <file> <out>: writes the lines to keep to <out>. Sets RC_REMOVED (count), RC_MANUAL (text).
rc_scan() {
  local f=$1 out=$2 n=0 i j k l
  local -a lines kinds
  RC_REMOVED=0 RC_MANUAL=""
  : > "$out"
  while IFS= read -r l || [ -n "$l" ]; do lines[$n]=$l; kinds[$n]=0; n=$((n + 1)); done < "$f"
  for ((i = 0; i < n; i++)); do
    l=${lines[$i]}
    [[ $l =~ ^[[:space:]]*# ]] && continue
    [[ $l =~ $RC_LOOSE ]] || continue
    if [[ $l =~ $RC_STRICT1 ]]; then
      kinds[$i]=1
    else
      kinds[$i]=2
    fi
  done
  # A removed line that is the whole body of an if/while/function would leave a syntax error, and one that continues
  # the line before it (which ends in &&, ||, | or a backslash) would join that line to the next command or leave it
  # dangling: keep it and say so.
  for ((i = 0; i < n; i++)); do
    [ "${kinds[$i]}" = 1 ] || continue
    j=$((i - 1))
    while [ "$j" -ge 0 ] && { [ "${kinds[$j]}" = 1 ] || [ -z "${lines[$j]//[[:space:]]/}" ]; }; do j=$((j - 1)); done
    k=$((i + 1))
    while [ "$k" -lt "$n" ] && { [ "${kinds[$k]}" = 1 ] || [ -z "${lines[$k]//[[:space:]]/}" ]; }; do k=$((k + 1)); done
    if [ "$j" -ge 0 ] && [ "$k" -lt "$n" ] && [[ ${lines[$j]} =~ $RC_OPEN ]] && [[ ${lines[$k]} =~ $RC_CLOSE ]]; then kinds[$i]=2; fi
    if [ "$j" -ge 0 ] && [[ ${lines[$j]} =~ $RC_CONT ]]; then kinds[$i]=2; fi
  done
  for ((i = 0; i < n; i++)); do
    case ${kinds[$i]} in
      1) RC_REMOVED=$((RC_REMOVED + 1)) ;;
      2) RC_MANUAL="$RC_MANUAL$((i + 1)): ${lines[$i]}"$'\n'; printf '%s\n' "${lines[$i]}" >> "$out" ;;
      *) printf '%s\n' "${lines[$i]}" >> "$out" ;;
    esac
  done
}
# zsh reads .zshrc and .zprofile from ZDOTDIR when it is set (tools/install-copies.sh checks ${ZDOTDIR:-$HOME}/.zshrc
# too). Under CLEANUP_TESTING only CLEANUP_ZDOTDIR counts, so a test never reads the real one.
if [ "${CLEANUP_TESTING:-0}" = 1 ]; then ZDOT=${CLEANUP_ZDOTDIR:-}; else ZDOT=${ZDOTDIR:-}; fi
case $ZDOT in /?*) ZDOT=$(phys "$ZDOT") ;; *) ZDOT="" ;; esac
[ "$ZDOT" != "$HOME_DIR" ] || ZDOT=""
for f in "$HOME_DIR/.zshrc" "$HOME_DIR/.bashrc" "$HOME_DIR/.bash_profile" "$HOME_DIR/.zprofile" "$HOME_DIR/.profile" \
  ${ZDOT:+"$ZDOT/.zshrc" "$ZDOT/.zprofile"}; do
  rc=${f##*/}
  [ -f "$f" ] || continue
  grep -Eaq "$RC_LOOSE" "$f" || continue
  rc_scan "$f" "$SCRATCH/rc.out"
  if [ -n "$RC_MANUAL" ]; then
    N_MANUAL=$((N_MANUAL + 1))
    say RUN "$f: these lines mention the toolkit but are not a plain source line (a chained command, the only line of an if/while, or the next line of a command continued with &&, ||, | or a backslash). Edit by hand:"
    printf '%s' "$RC_MANUAL" | sed 's/^/        /'
  fi
  [ "$RC_REMOVED" -gt 0 ] || continue
  N_EDIT=$((N_EDIT + 1))
  say EDIT "$f  ($RC_REMOVED plain source line(s); the file is copied to $rc.cleanup-bak-<time> first)"
  diff "$f" "$SCRATCH/rc.out" | grep '^<' | sed 's/^< /        - /'
  if [ "$APPLY" = 1 ]; then
    bak="$f.cleanup-bak-$(date +%Y%m%d-%H%M%S)"
    if cp -n "$f" "$bak" && cat "$SCRATCH/rc.out" > "$f"; then
      say DONE "$f  (copy: $bak)"
    else
      N_FAIL=$((N_FAIL + 1)); say FAIL "$f (not written; a copy may be at $bak)"
    fi
  fi
done

# ---- 4. state the toolkit made while running
echo "== runtime state"
remove_path "$HOME_DIR/.cache/mcp-github" "github MCP update-check state"
remove_path "$HOME_DIR/.local/state/claude-statusline" "statusline readings"
# The install-time settings /setup-claude wrote. Keys another installer added to the file go with it.
CONF="$HOME_DIR/.claude/install.conf"
if [ ! -e "$CONF" ] && [ ! -L "$CONF" ]; then :
elif [ -L "$CONF" ]; then
  say SKIP "$CONF  (a symlink, not the settings file)"
elif [ ! -f "$CONF" ] || [ ! -O "$CONF" ]; then
  say SKIP "$CONF  (not a regular file you own)"
else
  remove_path "$CONF" "install-time settings"
fi
while IFS= read -r cfg; do
  [ -n "$cfg" ] || continue
  for a in "$cfg/.eta"; do
    [ -e "$a" ] || continue
    if [ "$PURGE" = 1 ]; then remove_path "$a" "ASK item (--purge-ask)"
    else N_ASK=$((N_ASK + 1)); say ASK "$a  (kept; --purge-ask removes it)"; fi
  done
done <<EOF
$CFGS
EOF

# ---- 5. what is only printed: any leftover root-owned install, credentials, other tools' own commands
echo "== for you to run (never run by this script)"
manual() { N_MANUAL=$((N_MANUAL + 1)); say RUN "$1"; [ -z "${2:-}" ] || printf '        %s\n' "$2"; }
if [ -e "$LIBEXEC/mcp-github" ] && [ "$KEPT_ROOT_GUARD" = 1 ]; then
  say KEEP "root-owned install in $LIBEXEC/mcp-github: a settings file named above keeps a guard hook that runs its guard.sh, so no rm is printed"
elif [ -e "$LIBEXEC/mcp-github" ]; then
  cmd="sudo rm -r"
  [ -e "$LIBEXEC/mcp-github" ] && cmd="$cmd $(printf '%q' "$LIBEXEC/mcp-github")"
  manual "root-owned install left from the earlier setup (github MCP launcher, guard and binary; the launcher and guard now run from the checkout)" "$cmd"
fi
mcp_check() {  # mcp_check <.claude.json>: reads only whether a server of that name exists
  local s
  [ -f "$1" ] || return 0
  for s in git-mcp github; do
    if jq -e --arg s "$s" '(.mcpServers // {}) | has($s)' "$1" >/dev/null 2>&1; then
      manual "MCP server '$s' in ${1#$HOME_DIR/}" "claude mcp remove --scope user $s"
    fi
  done
}
mcp_check "$HOME_DIR/.claude.json"
if command -v git-mcp-server >/dev/null 2>&1; then
  manual "git-mcp-server global npm package" "npm rm -g @cyanheads/git-mcp-server"
fi
manual "optional, credentials: the toolkit's Keychain items are left alone. Delete only if you want them gone" "security delete-generic-password -s mcp-github"

echo "== never touched"
say KEEP "login, Keychain items, transcripts (projects/), session registry, CLAUDE.md, settings backups, .archive/, this checkout"

echo
if [ "$APPLY" = 1 ]; then
  LEFT=$(toolkit_links | grep -c .)
  echo "done: $N_REMOVE removed, $N_EDIT edited, $N_ASK kept for you to decide, $N_MANUAL commands for you, $N_FAIL problems; $LEFT toolkit links left"
  [ "$N_FAIL" -eq 0 ] && [ "$LEFT" -eq 0 ]
else
  echo "dry run, nothing changed: $N_REMOVE to remove, $N_EDIT to edit, $N_ASK kept for you to decide, $N_MANUAL commands for you, $N_FAIL problems"
  echo "run again with --apply to do it"
  [ "$N_FAIL" -eq 0 ]
fi
