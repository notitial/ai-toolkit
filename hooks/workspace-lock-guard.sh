#!/bin/bash
# Pre-tool-use hook: enforces the workspace lock. In a lock-guarded workspace a session may mutate
# only while it holds the lock. Configured in ~/.claude/settings.json for PreToolUse with matcher:
#   Edit|Write|MultiEdit|NotebookEdit|Bash|mcp__git-mcp__.*
#
# The lock is cooperative (ADR 0012). This guard catches a session that forgot the protocol; it
# does not try to stop one that works around it. When in doubt it denies, and the deny reason says
# how to proceed (acquire in the background, or use the Read/Grep tools for a read).
#
# Which workspace: WORKSPACE_LOCK_DIR (absolute, and only when the target is inside its workspace
# or one of the lock's --repos), else the nearest .workspace-lock/ up from the target that holds
# lock.d/ (a lock is held there). None found: not guarded, allow.
#
# Who holds it: an `acquire --id <slug>` call registers this session (sessions/<session_id> holds
# the slug; a `release` whose id, --id or else WORKSPACE_LOCK_ID, is the holder's removes it). The
# session holds the lock when that slug, or WORKSPACE_LOCK_ID from the environment, equals
# lock.d/holder.
#
# What a non-holder may still do: read (a short allowlist of read commands, below), write under
# .archive/ or a temp dir (a quoted-heredoc `cat >` / `cat >>` into the workspace's own .archive/
# included), and run the lock script (but not acquire below the workspace root while WORKSPACE_LOCK_DIR
# is unset: the script would create a second lock there). A holder past its
# ETA is re-armed: its own mutations are denied until it runs `heartbeat --eta <new>`. Freeing someone else's long-dead lock
# goes through `clear`, which this guard turns into a permission prompt. Only the plain call is
# gated (a compound, redirected or cd-prefixed one is denied); a wrapped spelling (an env prefix,
# `bash -c`, a subshell) gets past it, a known gap outside ADR 0012's cooperative threat model.
#
# An owned team (lock.d/kind says "owned") is judged by the session id, never by a slug or a
# registration: the owner, or a member the owner added (lock.d/members/<sid>), mutates only while
# lock.d/turn.d/sid is its own id and the turn is within its ETA (the owner's own turn also needs
# the lock's ETA). One check, team_may_mutate, serves Bash, the file tools and git MCP. A session
# that is neither owner nor member is denied and never registered under the owned slug; a member never acquires. The
# member, turn and owner verbs and an owned acquire/release/heartbeat are checked against the
# calling session's id before the script runs; the force-give of a stale turn and an owner transfer
# go through the script's read-only --check and then a permission prompt, like `clear`. Plain
# writes into the lock folder, and a git clean that could remove it, are denied for every session while
# the lock is owned. The verbs run as one plain call spelled $HOME/.claude/tools/workspace-lock.sh (a
# pipe, a chain or another path to the script is denied in an owned team), and a value the shell
# expands or splits (a variable, a brace, a glob) is refused, because the guard could not read what
# the script receives. Cooperative, as the rest of ADR 0012: a wrapped spelling (bash -c, an env
# prefix) gets past.
#
# Reads JSON on stdin, prints a JSON decision or nothing, exits 0 always (no set -e). bash 3.2.

set -f   # word-splitting a command must never glob against the cwd

LOCK_SCRIPT_HINT='$HOME/.claude/tools/workspace-lock.sh'

static_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"workspace-lock-guard: %s"}}\n' "$1"
  exit 0
}

# A session that set WORKSPACE_LOCK_ID fails closed; anyone else gets a warning and a pass.
if ! command -v jq >/dev/null 2>&1; then
  [ -n "${WORKSPACE_LOCK_ID:-}" ] && static_deny "jq unavailable - mutation blocked. Install jq."
  echo "workspace-lock-guard: jq unavailable; allowing" >&2
  exit 0
fi
INPUT=$(cat)
if [ -z "$INPUT" ] || ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  [ -n "${WORKSPACE_LOCK_ID:-}" ] && static_deny "stdin empty or malformed - mutation blocked."
  echo "workspace-lock-guard: stdin empty or malformed; allowing" >&2
  exit 0
fi

jqin() { printf '%s' "$INPUT" | jq -r "$1"; }
TOOL=$(jqin '.tool_name // empty')
SID=$(jqin '.session_id // empty' | tr -cd 'A-Za-z0-9-')
CWD=$(jqin '.cwd // empty')
[ -n "$CWD" ] || CWD="$PWD"
PERMISSION_MODE=$(jqin '.permission_mode // empty')
REASON=""   # why a Bash call was not a read, for the log

decide() {  # decide <deny|ask> <reason>
  jq -n --arg d "$1" --arg r "workspace-lock-guard: $2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
  exit 0
}
deny() { decide deny "$1"; }

guard_log() {  # never creates the lock dir: logging a deny must not arm a workspace
  [ -n "${LOCK_DIR:-}" ] && [ -d "$LOCK_DIR" ] || return 0
  printf '%s  workspace-lock-guard  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOCK_DIR/workspace-lock.log" 2>/dev/null
}

# --- Which lock --------------------------------------------------------------------------------
abspath() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$CWD/$1" ;; esac; }

# The nearest held lock up from $1. A lock left inside .archive/ is old debris and is skipped,
# unless a .git between them marks a real project archived there.
walk_up() {
  _d=$(abspath "$1")
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    if [ -d "$_d/.workspace-lock/lock.d" ] && ! under_archive "$_d"; then
      printf '%s' "$_d/.workspace-lock"; return 0
    fi
    _d=$(dirname "$_d")
  done
  return 0
}
under_archive() {
  _p="$1"
  while [ "$_p" != "/" ] && [ -n "$_p" ]; do
    [ -e "$_p/.git" ] && return 1
    case "$_p" in */.archive) return 0 ;; esac
    _p=$(dirname "$_p")
  done
  return 1
}

# resolve_lock_dir <dir>: WORKSPACE_LOCK_DIR when <dir> is in its workspace or in one of the
# lock's --repos; otherwise the walk up. A stray WORKSPACE_LOCK_DIR is ignored.
resolve_lock_dir() {
  _start=$(abspath "$1")
  case "${WORKSPACE_LOCK_DIR:-}" in
    /*)
      _ews=$(dirname "$WORKSPACE_LOCK_DIR")
      case "$_start" in "$_ews"|"$_ews"/*) printf '%s' "$WORKSPACE_LOCK_DIR"; return 0 ;; esac
      _repos=$(head -n1 "$WORKSPACE_LOCK_DIR/lock.d/repos" 2>/dev/null)
      _oifs=$IFS; IFS=','
      for _r in $_repos; do
        # A hand-typed list may hold "a, b" or "a/": trim spaces, then trailing slashes.
        _r="${_r#"${_r%%[![:space:]]*}"}"; _r="${_r%"${_r##*[![:space:]]}"}"
        while [ "${#_r}" -gt 1 ] && [ "${_r%/}" != "$_r" ]; do _r=${_r%/}; done
        [ -n "$_r" ] || continue
        case "$_start" in "$_r"|"$_r"/*) IFS=$_oifs; printf '%s' "$WORKSPACE_LOCK_DIR"; return 0 ;; esac
      done
      IFS=$_oifs ;;
  esac
  walk_up "$_start"
}

# --- Holder and decision -----------------------------------------------------------------------
effective_id() {
  if [ -n "${WORKSPACE_LOCK_ID:-}" ]; then printf '%s' "$WORKSPACE_LOCK_ID"; return; fi
  [ -n "$SID" ] && head -n1 "$LOCK_DIR/sessions/$SID" 2>/dev/null
}
holder() { head -n1 "$LOCK_DIR/lock.d/holder" 2>/dev/null; }
lock_eta() { jq -r '.eta // empty' "$LOCK_DIR/status.json" 2>/dev/null; }
# The holder's free-text phase, safe to quote: printable characters only, no quotes or backslashes, 80 at most.
holder_note() {
  _n=$(head -n1 "$LOCK_DIR/lock.d/phase" 2>/dev/null | LC_ALL=C tr -cd '[:print:]' | LC_ALL=C tr -d '"\\' | cut -c1-80)
  [ -n "$_n" ] && printf " holder's note: \"%s\"." "$_n"
}
# below_root: WORKSPACE_LOCK_DIR is unset and the cwd is below the lock's workspace root, where the lock
# script would create a second lock instead of using this one.
below_root() {
  case "${WORKSPACE_LOCK_DIR:-}" in /*) return 1 ;; esac
  _root=$(dirname "$LOCK_DIR")
  case "$CWD" in "$_root"/*) return 0 ;; esac
  return 1
}
BELOW_ROOT_MSG='WORKSPACE_LOCK_DIR is unset and this cwd is below the workspace root, so the lock script would create a second lock here. Do not acquire here; tell the user the workspace is mis-armed.'
holder_expired() {
  _e=$(head -n1 "$LOCK_DIR/lock.d/eta_epoch" 2>/dev/null)
  case "$_e" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(date -u +%s)" -gt "$_e" ]
}
is_holder() {
  _me=$(effective_id)
  [ -d "$LOCK_DIR/lock.d" ] && [ -n "$_me" ] && [ "$(holder)" = "$_me" ]
}

# --- Owned team --------------------------------------------------------------------------------
# kind is written before holder, so a lock whose holder a reader sees is settled. A lock with no kind
# file is an open one and keeps today's rules.
lock_owned()  { [ -d "$LOCK_DIR/lock.d" ] && [ "$(head -n1 "$LOCK_DIR/lock.d/kind" 2>/dev/null)" = owned ]; }
team_owner()  { head -n1 "$LOCK_DIR/lock.d/owner" 2>/dev/null; }
turn_holder() { head -n1 "$LOCK_DIR/lock.d/turn.d/sid" 2>/dev/null; }
short8()      { printf '%s' "$1" | cut -c1-8; }
epoch_iso()   { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }
# The turn's ETA as an epoch, or nothing when missing or unreadable.
turn_eta() {
  _tv=$(head -n1 "$LOCK_DIR/lock.d/turn.d/eta_epoch" 2>/dev/null)
  case "$_tv" in ''|*[!0-9]*) ;; *) printf '%s' "$_tv" ;; esac
}
# A turn with no readable ETA counts as expired: the holder re-arms it with `turn beat --eta`.
turn_expired() {
  _te=$(turn_eta)
  [ -z "$_te" ] || [ "$(date -u +%s)" -gt "$_te" ]
}
# The owner or a member of the owned lock. An empty sid is never one (members/ with no name is the folder).
team_party() {
  [ -n "$SID" ] || return 1
  _po=$(team_owner)
  [ -n "$_po" ] || return 1
  [ "$SID" = "$_po" ] || [ -f "$LOCK_DIR/lock.d/members/$SID" ]
}
# The one check every tool shares. The lock's own ETA gates only the owner's own turn: an owner that
# waits on its members cannot be relied on to heartbeat, and members are gated by their turn alone.
team_may_mutate() {
  team_party || return 1
  _tt=$(turn_holder)
  [ -n "$_tt" ] && [ "$_tt" = "$SID" ] || return 1
  turn_expired && return 1
  [ "$SID" = "$(team_owner)" ] && holder_expired && return 1
  return 0
}
# The holder's task text, safe to quote: printable only, no quotes or backslashes, 80 at most.
turn_note() { head -n1 "$LOCK_DIR/lock.d/turn.d/task" 2>/dev/null | LC_ALL=C tr -cd '[:print:]' | LC_ALL=C tr -d '"\\' | cut -c1-80; }

# owned_mutation <label>: returns only when this session may mutate; otherwise denies, saying what to do.
owned_mutation() {
  _slug=$(holder); _own=$(team_owner)
  _rd=""
  case "$1" in Bash*) _rd=" If this command was read-only, use the Read/Grep tools or a simpler read-only form." ;; esac
  team_may_mutate && return 0
  if [ -z "$SID" ]; then
    guard_log "BLOCKED unknown wanted $1 - owned lock '$_slug', no session id"
    deny "an owned team holds this workspace's lock ('$_slug') and this call carries no session id, so no turn can be checked. Tell the user.$_rd"
  fi
  if [ -z "$_own" ]; then
    guard_log "BLOCKED $SID wanted $1 - owned lock '$_slug' has no owner"
    deny "the owned lock '$_slug' has no owner recorded. Ask a human to inspect $LOCK_DIR/lock.d; do not remove it yourself."
  fi
  if ! team_party; then
    guard_log "BLOCKED $SID wanted $1 - owned lock '$_slug', not a member"
    deny "a team holds this workspace's lock: owned by session $(short8 "$_own") (lock '$_slug', ETA: $(lock_eta)).$(holder_note) You are not a member: tell the user, don't take a solo id and don't acquire. Only the owner can add you, so give it your session id (run echo \$CLAUDE_CODE_SESSION_ID) and only read until it has. Never remove lock.d yourself.$_rd"
  fi
  if [ "$SID" = "$_own" ] && holder_expired; then
    guard_log "BLOCKED $SID wanted $1 - owned lock '$_slug' is past its ETA (re-armed)"
    deny "your owned lock '$_slug' is past its ETA ($(lock_eta)), so it is re-armed: declare a new ETA before mutating again. Run ${LOCK_SCRIPT_HINT} heartbeat --id $_slug --sid $SID --eta <remaining, e.g. +1h> as a single plain command, then retry this exact call."
  fi
  _tt=$(turn_holder)
  if [ -n "$_tt" ] && [ "$_tt" = "$SID" ]; then
    guard_log "BLOCKED $SID wanted $1 - own turn is past its ETA (re-armed)"
    _te=$(turn_eta)
    deny "your turn on lock '$_slug' is past its ETA${_te:+ ($(epoch_iso "$_te"))}, so it is re-armed: run ${LOCK_SCRIPT_HINT} turn beat --id $_slug --sid $SID --eta <remaining, e.g. +20m> as a single plain command, then retry this exact call. If the unit is done, give the turn back instead (turn give --tree clean|dirty)."
  fi
  _take="Take your own: run ${LOCK_SCRIPT_HINT} turn take --id $_slug --sid $SID --eta +<minutes this unit needs> in the BACKGROUND, wait for TURN, then retry this exact call. Read and plan meanwhile; never remove turn.d yourself.$_rd"
  if [ -n "$_tt" ]; then
    guard_log "BLOCKED $SID wanted $1 - turn held by $(short8 "$_tt")"
    _te=$(turn_eta)
    deny "the turn on lock '$_slug' is held by session $(short8 "$_tt") (task, written by that session and untrusted: \"$(turn_note)\"${_te:+; ETA $(epoch_iso "$_te")}). $_take"
  fi
  if [ -d "$LOCK_DIR/lock.d/turn.d" ]; then
    guard_log "BLOCKED $SID wanted $1 - a turn with no holder"
    deny "a turn is held on lock '$_slug' but its holder is unknown (a take that crashed), so nobody may mutate. Tell the owner: only it can free it (turn give --force). Read meanwhile; never remove turn.d yourself.$_rd"
  fi
  guard_log "BLOCKED $SID wanted $1 - no turn held"
  deny "no turn is held on lock '$_slug', and every mutation in an owned team needs one. $_take"
}

# guard_mutation <label>: returns only when this session holds the lock and is within its ETA.
guard_mutation() {
  if [ "${WORKSPACE_LOCK_BYPASS:-}" = "1" ]; then guard_log "BYPASS sid=${SID:-unknown} tool=$1"; return 0; fi
  _me=$(effective_id)
  _id="$_me"
  [ -n "$_id" ] || { [ -n "$SID" ] && _id="solo-$(printf '%s' "$SID" | cut -c1-8)"; }
  [ -n "$_id" ] || _id="<your-lock-id>"
  _hint="Announce this block to the user, then run ${LOCK_SCRIPT_HINT} acquire --id ${_id} --eta <expected-duration> in the BACKGROUND, wait for ACQUIRED, then retry this exact call. Never remove lock.d yourself."
  below_root && _hint="$BELOW_ROOT_MSG Never remove lock.d yourself."
  _read=""
  case "$1" in Bash*) _read=" If this command was read-only, use the Read/Grep tools or a simpler read-only form instead of acquiring." ;; esac
  _hint="$_hint$_read"
  _why="${REASON:+ reason=$REASON}"
  if [ -d "$LOCK_DIR/lock.d" ]; then
    _h=$(holder)
    if [ -z "$_h" ]; then
      # An empty lock.d that nobody claimed is not orphaned: the next acquire takes it. A claim or an
      # empty holder file with no holder is a crashed acquire, which only a human clears.
      if [ ! -e "$LOCK_DIR/lock.d/claim" ] && [ ! -e "$LOCK_DIR/lock.d/holder" ]; then
        guard_log "BLOCKED ${SID:-unknown} wanted $1 - lock.d is empty and unclaimed$_why"
        deny "this workspace is lock-guarded and its lock folder is empty (nobody holds it; the next acquire takes it), but this session has not acquired it: every session must hold the lock before mutating. $_hint"
      fi
      guard_log "BLOCKED ${SID:-unknown} wanted $1 - holder unknown$_why"
      deny "lock.d exists but the holder is unknown, so the lock is orphaned. Ask a human to inspect and clear $LOCK_DIR/lock.d; do not remove it yourself."
    fi
    if lock_owned; then owned_mutation "$1"; return 0; fi
    if [ -n "$_me" ] && [ "$_h" = "$_me" ]; then
      if holder_expired; then
        guard_log "BLOCKED ${SID:-unknown} wanted $1 - own lock '$_h' is past its ETA (re-armed)"
        deny "your workspace lock '$_h' is past its ETA ($(lock_eta)), so it is re-armed: declare a new ETA before mutating again. Run ${LOCK_SCRIPT_HINT} heartbeat --id $_h --eta <remaining, e.g. +30m> as a single plain command, then retry this exact call. Until you do, a long-silent lock can be cleared by another session (with the user's approval)."
      fi
      return 0
    fi
    guard_log "BLOCKED ${SID:-unknown} wanted $1 - held by $_h$_why"
    case "$_h" in
      solo-*) ;;
      *) [ -z "$_me" ] && ! below_root &&
           deny "a team run holds this workspace's lock: held by '$_h' (ETA: $(lock_eta)).$(holder_note) Tell the user. Don't take a solo id, and join with ${LOCK_SCRIPT_HINT} acquire --id $_h --eta <realistic> only if whoever started this team told you to. Never remove lock.d yourself.$_read" ;;
    esac
    deny "this workspace is lock-guarded and the lock is held by '$_h' (ETA: $(lock_eta)).$(holder_note) $_hint If that holder's ETA and last heartbeat are both long past, ${LOCK_SCRIPT_HINT} clear --id ${_id} --holder $_h asks the user to free it."
  fi
  guard_log "BLOCKED ${SID:-unknown} wanted $1 - lock free, session has not acquired it$_why"
  deny "this workspace is lock-guarded and the lock is FREE, but this session has not acquired it: every session must hold the lock before mutating. $_hint"
}

# Edit-tool targets under the workspace's .archive/ (or, outside the workspace, under any
# .archive/) are exempt: handovers and STATE.md are written by the lock protocol itself.
archive_exempt() {
  case "/$1/" in */../*) return 1 ;; esac
  _ws=$(dirname "$LOCK_DIR")
  case "$1" in
    "$_ws"/*) case "$1" in "$_ws"/.archive/*) return 0 ;; esac; return 1 ;;
    */.archive/*) return 0 ;;
  esac
  return 1
}

# norm_path <abs path>: . and .. collapsed on the text, the disk untouched (this hook runs with set -f).
norm_path() {
  _np_out=""; _np_ifs=$IFS; IFS=/
  for _np in $1; do
    case "$_np" in ''|.) ;; ..) _np_out="${_np_out%/*}" ;; *) _np_out="$_np_out/$_np" ;; esac
  done
  IFS=$_np_ifs
  printf '%s' "${_np_out:-/}"
}
# in_lock_folder <abs path>: the path is the workspace's lock folder or inside it.
in_lock_folder() {  # compared in lower case: the usual macOS file system ignores case
  _lp=$(norm_path "$1" | LC_ALL=C tr 'A-Z' 'a-z'); _ld=$(printf '%s' "$LOCK_DIR" | LC_ALL=C tr 'A-Z' 'a-z')
  case "$_lp" in "$_ld"|"$_ld"/*|*/.workspace-lock|*/.workspace-lock/*) return 0 ;; esac
  return 1
}
# strip_heredocs <text>: the text without the bodies (and end lines) of its heredocs, which are data, not
# words. A heredoc counts only when its <<TAG stands outside quotes and its end line exists; otherwise nothing
# is dropped.
strip_heredocs() {
  printf '%s' "$1" | awk -v q="'" '
    { line[NR] = $0 }
    function tagof(l,   p, pre, r, d) {
      p = index(l, "<<"); if (!p) return ""
      pre = substr(l, 1, p - 1)
      gsub("\"[^\"]*\"", "", pre); gsub(q "[^" q "]*" q, "", pre)
      if (pre ~ ("[\"" q "]")) return ""
      r = substr(l, p + 2)
      if (substr(r, 1, 1) == "<") return ""
      d = (substr(r, 1, 1) == "-"); sub(/^-?[ \t]*/, "", r); sub("^[\"" q "\\\\]", "", r)
      if (!match(r, /^[A-Za-z_][A-Za-z0-9_]*/)) return ""
      return (d ? "-" : "+") substr(r, 1, RLENGTH)
    }
    END {
      i = 1
      while (i <= NR) {
        print line[i]
        t = tagof(line[i]); j = 0
        if (t != "") {
          for (k = i + 1; k <= NR && !j; k++) {
            e = line[k]; if (substr(t, 1, 1) == "-") sub(/^\t+/, "", e)
            if (e == substr(t, 2)) j = k
          }
        }
        i = j ? j + 1 : i + 1
      }
    }'
}
# glob_hits_lock <word>: an unquoted glob in <word> could expand to the lock folder or a path inside it. The
# pattern is cut back one path part at a time and matched against the folder, as the shell would, except
# that a leading * ? or [ never matches the dot of a dot folder.
glob_hits_lock() {
  _gp=$(abspath "$1" | LC_ALL=C tr 'A-Z' 'a-z'); _gl=$(printf '%s' "$LOCK_DIR" | LC_ALL=C tr 'A-Z' 'a-z')
  _gdot=0; case "${_gl##*/}" in .*) _gdot=1 ;; esac
  while [ -n "$_gp" ]; do
    case "$_gl" in
      $_gp) case "${_gp##*/}" in '*'*|'?'*|'['*) [ "$_gdot" = 1 ] || return 0 ;; *) return 0 ;; esac ;;
    esac
    case "$_gp" in */*) _gp=${_gp%/*} ;; *) break ;; esac
  done
  return 1
}
# names_lock_folder: the Bash command runs from inside the lock folder, or one of its words is a path to the
# folder or into it (a quoted multi-word text, as in a commit message, is no path). Heredoc bodies are not
# words, and ; | ( ) split words. A word the shell expands (a variable, a brace, a glob) counts when it
# names the folder as text or could glob to it. A .workspace-lock/ right after a leading echo or
# printf is a .gitignore line, not a write.
names_lock_folder() {
  in_lock_folder "$CWD" && return 0
  _nf=""; _npv=""; _ni=0
  while IFS= read -r _nw; do
    [ "$_nw" != "!" ] || continue
    _nt=${_nw%"${_nw#?}"}; _nw=${_nw#?}
    _nprev=$_npv; _npv=$_nw; _ni=$((_ni + 1))
    case "$_nprev" in -e|-[!-]*e) continue ;; esac   # git clean -e <pattern> excludes it
    case "$_nw" in --exclude=*) continue ;; esac
    case "$_nw" in *[[:space:]]*) continue ;; esac
    case "$_nw" in *'>'*) _nw=${_nw##*>} ;; esac
    [ -n "$_nw" ] || continue
    [ -n "$_nf" ] || { _nf=$_nw; continue; }
    case "$_nw" in lock.d|lock.d/*) return 0 ;; esac
    case "$_ni:$_nf $_nw" in '2:echo .workspace-lock'|'2:echo .workspace-lock/'|'2:printf .workspace-lock'|'2:printf .workspace-lock/') continue ;; esac
    if [ "$_nt" = D ]; then
      _nl=$(printf '%s' "$_nw" | LC_ALL=C tr 'A-Z' 'a-z')
      case "$_nl" in *.workspace-lock*|*lock.d*) return 0 ;; esac
      case "$_nw" in *'*'*|*'?'*|*'['*) glob_hits_lock "$_nw" && return 0 ;; esac
      continue
    fi
    in_lock_folder "$(abspath "$_nw")" && return 0
  done <<EOT
$(qwords "$(strip_heredocs "$CMD" | tr ';|()' '    ')")
EOT
  return 1
}

# lock_script_segment: fails when a segment of $CMD runs a lock-script verb that takes a session's identity
# (any spelling of the script's path, quotes removed). status is a read.
lock_script_segment() {
  printf '%s\n' "$(split_command "$CMD")" | while IFS= read -r _seg; do
    set -- $(printf '%s' "$_seg" | tr -d "'\"\\\\")
    case "${1:-}" in bash|sh|zsh) shift ;; esac
    case "${1:-}" in *workspace-lock.sh) ;; *) continue ;; esac
    case "${2:-}" in member|turn|owner|release|heartbeat|acquire|clear) exit 1 ;; esac
  done
}
# git_clean_segment: fails on a git clean that could remove the lock folder: not a dry run and not
# excluding it. Reads the words the way git does: leading global options are skipped (those that take a
# value consume it), a short cluster is read letter by letter (n is a dry run, e takes the rest of the word
# or the next word as an exclude pattern), and only an exclude that is exactly the lock folder counts. A long
# option other than --dry-run, --exclude and --force is not understood, so it protects nothing.
git_clean_segment() {
  printf '%s\n' "$(split_command "$CMD")" | while IFS= read -r _seg; do
    set -- $(printf '%s' "$_seg" | tr -d "'\"\\\\")
    [ "${1:-}" = git ] || continue
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env) shift 2 ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    [ "${1:-}" = clean ] || continue
    shift
    _dry=0; _exc=0; _ex=0
    for _cw in "$@"; do
      if [ "$_ex" = 1 ]; then
        case "$_cw" in .workspace-lock|.workspace-lock/|/.workspace-lock|/.workspace-lock/) _exc=1 ;; esac
        _ex=0; continue
      fi
      case "$_cw" in
        --dry-run) _dry=1 ;;
        --exclude=*) case "${_cw#--exclude=}" in .workspace-lock|.workspace-lock/|/.workspace-lock|/.workspace-lock/) _exc=1 ;; esac ;;
        --exclude) _ex=1 ;;
        --*) ;;
        -*)
          _cl=${_cw#-}
          while [ -n "$_cl" ]; do
            _c1=${_cl%"${_cl#?}"}; _cl=${_cl#?}
            case "$_c1" in
              n) _dry=1 ;;
              e) case "$_cl" in
                   '') _ex=1 ;;
                   .workspace-lock|.workspace-lock/|/.workspace-lock|/.workspace-lock/) _exc=1 ;;
                 esac
                 break ;;
            esac
          done ;;
      esac
    done
    [ "$_dry" = 1 ] || [ "$_exc" = 1 ] || exit 1
  done
}

# --- Bash: what a non-holder may run -----------------------------------------------------------
# A temp dir or a .archive/ path, judged on the text: no `..`, no expansion, no glob. Inside the
# guarded workspace only its own .archive/ counts, even when the workspace itself sits in a temp dir.
# A leading ~ is refused: bash expands it to $HOME, which the text check can't see. After a cd in
# the same command a relative path no longer means $CWD/path, so only absolute paths count then.
scratch_path() {
  case "$1" in '~'*|*..*|*'$'*|*'`'*|*'*'*|*'?'*|*'['*|*"'"*|*'"'*) return 1 ;; esac
  [ "${CD_SEEN:-0}" = 1 ] && case "$1" in /*) ;; *) return 1 ;; esac
  _sp=$(abspath "$1")
  if [ -n "${LOCK_DIR:-}" ]; then
    _ws=$(dirname "$LOCK_DIR")
    case "$_sp" in "$_ws"/.archive/*) return 0 ;; "$_ws"|"$_ws"/*) return 1 ;; esac
  fi
  case "$_sp" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|*/.archive/*) return 0 ;; esac
  _td="${TMPDIR%/}"
  [ -n "$_td" ] && case "$_sp" in "$_td"/*) return 0 ;; esac
  return 1
}

# Commands that read whatever their arguments (no option writes a file or runs a program).
# cd only moves the subshell; every following segment is still checked on its own.
is_read_word() {
  case "$1" in
    ls|cat|head|tail|grep|egrep|fgrep|rg|find|wc|file|stat|pwd|echo|printf|which|diff|sleep|cd|date) return 0 ;;
    ps|du|cut|tr|jq|lsof|basename|dirname|realpath) return 0 ;;
  esac
  return 1
}

# Options of the read words above that write or execute: find's -delete/-exec family, git's
# --output, rg's --pre.
has_write_flag() {
  for _w in "$@"; do
    case "$_w" in
      -delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls|--output|--output=*|--pre|--pre=*) return 0 ;;
    esac
  done
  return 1
}

# git_shaped_read <subcommand> [args]: the git subcommands that read in one form and write in another.
# Each form is an allowlist of exact words, so an abbreviated long option (--upload for --upload-pack)
# is refused, not matched by a deny list.
git_shaped_read() {
  _gs="$1"; shift
  # all_reads strips quotes but not the $ of $'...', which the shell decodes into another word ($'--upload-pack=x',
  # $'a\x3ab'), a brace list expands to several ({,-}-upload-pack=x) and this hook runs with set -f, so it sees a glob
  # as text while the shell expands it to file names (a planted `--upload-pack=x` or `a:b` in .archive/): no word of
  # these forms may carry any of them. A quoted pattern is refused too, as the guard cannot tell it from a bare one.
  for _w in "$@"; do case "$_w" in *'$'*|*'`'*|*'{'*|*'*'*|*'?'*|*'['*) return 1 ;; esac; done
  case "$_gs" in
    fetch)  # writes .git (FETCH_HEAD, remote-tracking refs, tags, objects, maybe auto-gc): never the index or the tree
      _pos=0
      for _w in "$@"; do
        case "$_w" in
          -q|--quiet|-v|--verbose|--all|-p|--prune|-t|--tags|-n|--no-tags|--dry-run) ;;
          -*) return 1 ;;
          *) _pos=$((_pos + 1))
             if [ "$_pos" = 1 ]; then case "$_w" in *[!A-Za-z0-9._-]*) return 1 ;; esac  # a remote name (or local path), not a URL
             else case "$_w" in *:*|*+*) return 1 ;; esac; fi ;;  # a refspec with a destination or a force
        esac
      done ;;
    branch)  # listing only; a name outside --list is a create
      _list=0
      for _w in "$@"; do
        case "$_w" in
          --list) _list=1 ;;
          --show-current|-a|-r|-v) ;;
          -*) return 1 ;;
          *) [ "$_list" = 1 ] || return 1 ;;
        esac
      done ;;  # no words at all lists too
    remote)
      case "$*" in
        -v) ;;
        'get-url '*) [ $# = 2 ] && case "$2" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac || return 1 ;;
        *) return 1 ;;
      esac ;;
    worktree)
      [ "${1:-}" = list ] || return 1; shift
      for _w in "$@"; do case "$_w" in --porcelain|-v|-z) ;; *) return 1 ;; esac; done ;;
    config)  # one key only: --list, --add, --unset and the rest write or dump every key
      [ $# = 2 ] && [ "$1" = --get ] && case "$2" in ''|-*) return 1 ;; esac || return 1 ;;
    *) return 1 ;;
  esac
  return 0
}

# Reads of tools that also have a writing form, each with one plain rule.
is_shaped_read() {
  _t="$1"; shift
  case "$_t" in
    git)  # git status|log|diff|show, with -C <dir> or --no-pager in front
      while [ $# -gt 0 ]; do
        case "$1" in --no-pager) shift ;; -C) [ $# -ge 2 ] || return 1; shift 2 ;; *) break ;; esac
      done
      case "${1:-}" in
        status|log|diff|show|rev-parse|ls-files|merge-base) ;;
        fetch|branch|remote|worktree|config) git_shaped_read "$@" || return 1 ;;
        *) return 1 ;;
      esac
      has_write_flag "$@" && return 1 ;;
    sed)  # -n, option letters from nEr only, and one script (a single -e or the first operand) that only
          # prints: p, q, = with line, $ or /regex/ addresses. So never -i, -I, -f, w or s.
      _toks=$(printf '%s ' "$@" | xargs printf '%s\n' 2>/dev/null) || return 1
      _n=0; _have=0; _next=0; _script=""
      while IFS= read -r _w; do
        if [ "$_next" = 1 ]; then _script=$_w; _have=1; _next=0; continue; fi
        case "$_w" in
          -e) [ "$_have" = 0 ] || return 1; _next=1 ;;
          --*|-*[!nEr]*) return 1 ;;
          -*) case "$_w" in *n*) _n=1 ;; esac ;;
          *) [ "$_have" = 1 ] || { _script=$_w; _have=1; } ;;  # later operands are files
        esac
      done <<EOT
$_toks
EOT
      [ "$_n" = 1 ] && [ "$_have" = 1 ] && [ "$_next" = 0 ] || return 1
      _rest=$(printf '%s' "$_script" | sed -E 's#/[^/]*/##g')
      case "$_rest" in *[!0-9,\$\!pq=\;[:space:]]*) return 1 ;; esac ;;
    sort) # never an output file, temp dir or compress program, however the long option is abbreviated
      for _w in "$@"; do
        case "$_w" in --o*|--t*|--c*) return 1 ;; --*) ;; -*[oT]*) return 1 ;; esac
      done ;;
    uniq) # a second file operand is the output file
      _ops=0
      for _w in "$@"; do case "$_w" in -*) ;; *) _ops=$((_ops + 1)) ;; esac; done
      [ "$_ops" -le 1 ] || return 1 ;;
    sysctl) # reading only: no -w, no -f, no name=value
      for _w in "$@"; do case "$_w" in *=*|-*w*|-*f*) return 1 ;; esac; done ;;
    log|/usr/bin/log) [ "${1:-}" = show ] || return 1 ;;
    ulimit) for _w in "$@"; do case "$_w" in -[A-Za-z]*) ;; *) return 1 ;; esac; done ;;
    curl) # an http(s) GET to stdout: no file written, nothing uploaded or posted
      _method=0  # the next word is the -X / --request value
      for _u in "$@"; do
        if [ "$_method" = 1 ]; then [ "$_u" = GET ] || return 1; _method=0; continue; fi
        case "$_u" in
          *://*) case "$_u" in http://*|https://*) ;; *) return 1 ;; esac ;;
          --request) _method=1 ;;
          --request=*) [ "$_u" = --request=GET ] || return 1 ;;
          --output*|--remote-name*|--upload-file*|--data*|--form*|--json*|--config*|--cookie-jar*|--dump-header*|--trace*|--stderr*|--output-dir*|--etag-save*|--hsts*|--alt-svc*|--libcurl*) return 1 ;;
          --*) ;;
          -*X*)  # -X in a cluster: the letters before it are flags, the rest (or the next word) the method
            case "${_u%%X*}" in *[oOTdFKcDJ]*) return 1 ;; esac
            if [ -n "${_u#*X}" ]; then [ "${_u#*X}" = GET ] || return 1; else _method=1; fi ;;
          -*[oOTdFKcDJ]*) return 1 ;;
        esac
      done
      [ "$_method" = 0 ] || return 1 ;;
    *) return 1 ;;
  esac
  return 0
}

# The keep-awake and lights-out commands, as the whole command: none touches the working copy, and
# a session that does not hold the lock may need them to keep the machine awake through a long run.
is_exact_read() {
  case "$*" in
    'launchctl list'|'crontab -l'|'pgrep -x caffeinate'|'pmset -g assertions'|'pmset displaysleepnow'|'pkill -x caffeinate') return 0 ;;
  esac
  [ "${1:-}" = launchctl ] && [ "${2:-}" = list ] && [ $# -eq 3 ] && case "$3" in -*|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac
  return 1
}
is_keep_awake() {  # $1 = the raw command
  if [[ "$1" =~ ^nohup\ caffeinate\ -dims\ -t\ ([1-9][0-9]{0,4})\ \>/dev/null\ 2\>\&1\ \&$ ]]; then
    [ "${BASH_REMATCH[1]}" -le 86400 ]; return
  fi
  [[ "$1" =~ ^kill(\ [1-9][0-9]{0,6})+$ ]] || return 1
  for _pid in ${1#kill }; do  # only a running caffeinate
    [ "$(ps -o ucomm= -p "$_pid" 2>/dev/null | tr -d ' ')" = caffeinate ] || return 1
  done
  return 0
}

# Commands that may write when every path they name is a scratch path.
SCRATCH_CMDS=' mkdir cp mv rm rmdir touch tee cat echo printf : true pdftotext '
scratch_only() {
  _first=1; _saw=0
  for _w in $1; do
    if [ "$_first" = 1 ]; then
      _first=0; _cmd=$_w
      case "$SCRATCH_CMDS" in *" $_w "*) continue ;; *) return 1 ;; esac
    fi
    case "$_w" in
      '&&'|'||'|';') _first=1; continue ;;
      *[!A-Za-z0-9/._+,:=@%~-]*) return 1 ;;  # quotes, operators, expansion: not a plain path
      -t*|-T*) case "$_cmd" in cp|mv) return 1 ;; esac; continue ;;  # a target-directory option
      -*=*) scratch_path "${_w#*=}" || return 1; _saw=1; continue ;;
      -*) continue ;;
    esac
    scratch_path "$_w" || return 1
    _saw=1
  done
  [ "$_saw" = 1 ]
}

# The installed lock script, spelled with $HOME, ${HOME}, ~ or as the path.
is_lock_script() {
  case "$1" in
    '$HOME/.claude/tools/workspace-lock.sh'|'${HOME}/.claude/tools/workspace-lock.sh'|'~/.claude/tools/workspace-lock.sh'|"$HOME/.claude/tools/workspace-lock.sh")
      LS_PATH="$HOME/.claude/tools/workspace-lock.sh"; return 0 ;;
  esac
  return 1
}

# split_command <text>: one segment per line, cut at | ; & and newlines outside quotes and comments. Prints a
# last line "!subst" when the text runs a command substitution ($( or a backtick outside single
# quotes, <( or >( outside quotes) and "!redirect" for a > outside quotes.
split_command() {
  printf '%s' "$1" | awk -v q="'" '
    { s = (NR == 1) ? $0 : s "\n" $0 }
    END {
      n = length(s); st = 0; seg = ""; subst = 0; redir = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); nx = substr(s, i + 1, 1)
        if (st == 1) { if (c == q) st = 0; seg = seg c; continue }
        if (st == 3) { if (c == "\\") { seg = seg c nx; i++ } else { if (c == q) st = 0; seg = seg c }; continue }
        if (c == "\\") { seg = seg c nx; i++; continue }
        if (c == "`" || (c == "$" && nx == "(")) subst = 1
        if (st == 2) { if (c == "\"") st = 0; seg = seg (c == "\n" ? " " : c); continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t\n;|&(]/)) {  # a comment, to the end of the line
          while (i < n && substr(s, i + 1, 1) != "\n") i++
          continue
        }
        if (c == "$" && nx == q) { st = 3; seg = seg c q; i++; continue }
        if (c == q) st = 1
        else if (c == "\"") st = 2
        else if ((c == "<" || c == ">") && nx == "(") subst = 1
        else if (c == ">") redir = 1
        else if (c == "|" || c == ";" || c == "&" || c == "\n") { print seg; seg = ""; continue }
        seg = seg c
      }
      print seg
      if (subst) print "!subst"
      if (redir) print "!redirect"
    }'
}

# strip_redirects <text>: the text without fd duplications (2>&1) and redirects to /dev/null or a
# scratch path, which write nothing in the workspace. Any other redirect is left for split_command.
strip_redirects() {
  _s="$1"
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    # Digits before > are a file descriptor only as a whole word: in team2>&1 the word is team2.
    _pre="${_r%%>*}"
    case "$_pre" in *[!0-9]*) _r=">${_r#*>}" ;; esac
    _t="${_r#*>}"; _t="${_t#>}"; _t="${_t#"${_t%%[![:space:]]*}"}"
    case "$_t" in
      '&'[0-9]|/dev/null) ;;
      *) scratch_path "$_t" || continue ;;
    esac
    _s="${_s/"$_r"/ }"
  done <<EOF
$(printf '%s' "$1" | grep -oE '[^[:space:];|&<>()]*>>?[[:space:]]*(&[0-9]|[^[:space:];|&<>()]+)')
EOF
  printf '%s' "$_s"
}

# need_prompt <verb> <what to surface>: returns only in a session with someone at the permission prompt.
need_prompt() {
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    cli|claude-vscode|claude-desktop) ;;
    *) deny "$1 needs a human at the permission prompt, and this session has none (entrypoint '${CLAUDE_CODE_ENTRYPOINT:-unset}'). Surface $2 to the user." ;;
  esac
  case "$PERMISSION_MODE" in
    default|acceptEdits|auto|plan) ;;
    *) deny "$1 needs a permission prompt, and permission mode '${PERMISSION_MODE:-unset}' may not show one. Surface $2 to the user." ;;
  esac
}
# run_lock_check <verb> <gerund> <script args…>: the lock script's read-only --check, from the call's cwd,
# at most 5 s. Sets _res to its output.
run_lock_check() {
  _cv=$1; _cg=$2; shift 2
  _out=$(mktemp "${TMPDIR:-/tmp}/wlg-clear.XXXXXX" 2>/dev/null) || deny "$_cv --check could not run; not $_cg."
  ( cd "$CWD" 2>/dev/null && "$LS_PATH" "$@" ) >"$_out" 2>/dev/null &
  _pid=$!; _n=0
  while kill -0 "$_pid" 2>/dev/null; do  # a hung check must not stall the session
    if [ "$_n" -ge 20 ]; then kill "$_pid" 2>/dev/null; rm -f "$_out"; deny "$_cv --check timed out; not $_cg."; fi
    sleep 0.25; _n=$((_n + 1))
  done
  _res=$(cat "$_out" 2>/dev/null); rm -f "$_out"
}

clear_usage() {
  deny "clear must be run as: ${LOCK_SCRIPT_HINT} clear --id <your-lock-id> --holder <holder-id> (plain [A-Za-z0-9._-] values, a single plain command). It asks the user before clearing."
}
# clear_gate: a plain `clear` call becomes a permission prompt, after the lock script's own
# `clear --check` says the lock may be cleared. Needs a session with someone at the prompt.
clear_gate() {
  _cid=""; _ch=""; _check=0
  case "$CMD" in *'#'*) clear_usage ;; esac
  set -- $CMD_WORDS
  case "$1" in bash|sh|zsh) shift ;; esac
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --id)     [ $# -ge 2 ] && [ -z "$_cid" ] || clear_usage; _cid="$2"; shift 2 ;;
      --holder) [ $# -ge 2 ] && [ -z "$_ch" ] || clear_usage; _ch="$2"; shift 2 ;;
      --check)  [ "$_check" = 0 ] || clear_usage; _check=1; shift ;;
      *) clear_usage ;;
    esac
  done
  case "$_cid" in ''|-*|*[!A-Za-z0-9._-]*) clear_usage ;; esac
  case "$_ch" in ''|-*|*[!A-Za-z0-9._-]*) clear_usage ;; esac
  [ "$_check" = 1 ] && exit 0
  need_prompt clear "the stuck lock"
  run_lock_check clear clearing clear --check --id "$_cid" --holder "$_ch"
  case "$_res" in
    *'
'*) deny "clear --check failed; not clearing." ;;
    'CLEARABLE '*) guard_log "CLEAR-ASK sid=${SID:-unknown} id=$_cid holder=$_ch"; decide ask "${_res#CLEARABLE }" ;;
    'NOT-CLEARABLE '*) deny "not clearable: ${_res#NOT-CLEARABLE }" ;;
    *) deny "clear --check failed; not clearing." ;;
  esac
}

# --- The lock script's own verbs ---------------------------------------------------------------
# qwords <text>: the words of a plain shell command as the shell splits them, one per line, tagged "L"
# (literal) or "D" (the shell expands or splits it and the guard cannot read the result: a $ or backtick
# outside single quotes, or an unquoted brace, glob or leading ~). A last line "!" means a quote was left
# open or a backslash ended the text. A newline inside a quoted word becomes a space, a backslash-newline
# is dropped, an unquoted # starts a comment and an unquoted & (a background call) is not a word.
qwords() {
  printf '%s' "$1" | awk -v q="'" '
    { s = (NR == 1) ? $0 : s "\n" $0 }
    END {
      n = length(s); st = 0; w = ""; has = 0; dyn = 0; bad = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (st == 1) { if (c == q) st = 0; else w = w (c == "\n" ? " " : c); continue }
        if (c == "\\") {
          i++
          if (i > n) { bad = 1; continue }
          if (substr(s, i, 1) == "\n") continue
          has = 1; w = w substr(s, i, 1); continue
        }
        if (st == 2) {
          if (c == "\"") { st = 0; continue }
          if (c == "$" || c == "`") dyn = 1
          w = w (c == "\n" ? " " : c); continue
        }
        if (c == q) { st = 1; has = 1; continue }
        if (c == "\"") { st = 2; has = 1; continue }
        if (c == " " || c == "\t" || c == "\n" || c == "&") {
          if (has) { print (dyn ? "D" : "L") w; w = ""; has = 0; dyn = 0 }
          continue
        }
        if (c == "#" && !has) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
        if (c == "$" || c == "`" || c == "{" || c == "*" || c == "?" || c == "[" || (c == "~" && !has)) dyn = 1
        has = 1; w = w c
      }
      if (st != 0) bad = 1
      if (has) print (dyn ? "D" : "L") w
      if (bad) print "!"
    }'
}

# lock_args <words to skip> <value flags> <switches>: reads $CMD the way the script reads its flags (a value
# flag takes the next word, whatever it is; any other word is unexpected). Sets A_ID A_SID A_BY A_TO A_TREE
# (empty when absent), A_OWNED A_FORCE A_CHECK (0 or 1), A_DYN (the identity flags whose value the shell
# expands) and A_ERR (empty when the call parses). An identity flag given twice is an error: the script
# takes the last one, and this guard must not read another.
lock_args() {
  _skip=$1; _vf=" $2 "; _sw=" $3 "
  A_ID=""; A_SID=""; A_BY=""; A_TO=""; A_TREE=""; A_OWNED=0; A_FORCE=0; A_CHECK=0; A_ERR=""; A_DYN=""
  _seen=" "; _exp=""; _i=0
  while IFS= read -r _tw; do
    if [ "$_tw" = "!" ]; then A_ERR="a quote is left open or the text ends in a backslash"; continue; fi
    _i=$((_i + 1))
    [ "$_i" -gt "$_skip" ] || continue
    _tag=${_tw%"${_tw#?}"}; _tv=${_tw#?}
    if [ -n "$_exp" ]; then
      # Any value the shell expands or splits may hold more flags, so it is refused wherever it stands.
      [ "$_tag" != D ] || A_DYN="$A_DYN $_exp"
      case "$_exp" in
        --id|--sid|--by|--to|--tree)
          case "$_seen" in *" $_exp "*) A_ERR="${A_ERR:-$_exp is given twice}" ;; esac
          _seen="$_seen$_exp "
          case "$_exp" in --id) A_ID=$_tv ;; --sid) A_SID=$_tv ;; --by) A_BY=$_tv ;; --to) A_TO=$_tv ;; --tree) A_TREE=$_tv ;; esac ;;
      esac
      _exp=""; continue
    fi
    if [ "$_tag" != L ]; then A_ERR="${A_ERR:-a flag the shell expands}"; continue; fi
    case "$_tv" in *' '*) A_ERR="${A_ERR:-a flag with a space in it}"; continue ;; esac
    case "$_vf" in *" $_tv "*) _exp=$_tv; continue ;; esac
    case "$_sw" in
      *" $_tv "*) case "$_tv" in --owned) A_OWNED=1 ;; --force) A_FORCE=1 ;; --check) A_CHECK=1 ;; esac; continue ;;
    esac
    A_ERR="${A_ERR:-unexpected argument '$(printf '%s' "$_tv" | tr -cd 'A-Za-z0-9._=-' | cut -c1-24)'}"
  done <<EOT
$(qwords "$(strip_redirects "$CMD")")
EOT
  [ -z "$_exp" ] || A_ERR="${A_ERR:-$_exp needs a value}"
}

# A session id is a lowercase UUID, spelled out as the script does (a range can match uppercase in some locales).
_H='[0123456789abcdef]'
SID_GLOB="$_H$_H$_H$_H$_H$_H$_H$_H-$_H$_H$_H$_H-$_H$_H$_H$_H-$_H$_H$_H$_H-$_H$_H$_H$_H$_H$_H$_H$_H$_H$_H$_H$_H"
sid_ok() { case "$1" in $SID_GLOB) return 0 ;; *) return 1 ;; esac; }

no_dyn() {
  [ -z "$A_DYN" ] || deny "the value of${A_DYN} is something the shell expands or splits (a variable, a substitution, a brace or a glob), and this guard cannot read it: pass the literal value (run echo \$CLAUDE_CODE_SESSION_ID, then paste the result into the call), never a variable or a substitution."
}
own_sid() {  # own_sid <flag> <value>: the value is this session's own id
  [ -n "$SID" ] || deny "this call carries no session id, so $1 cannot be checked; a lock verb that names a session does not run without one."
  [ "$2" = "$SID" ] || deny "$1 must be this session's own id ($SID): pass the literal value of echo \$CLAUDE_CODE_SESSION_ID${2:+ (got '$(short8 "$(printf '%s' "$2" | tr -cd 'A-Za-z0-9-')")')}."
}
sid_shape() {  # sid_shape <flag> <value>: a session id, as the script requires
  sid_ok "$2" || deny "$1 must be a session id: a lowercase UUID, the literal value of echo \$CLAUDE_CODE_SESSION_ID."
}
is_owner() { lock_owned && [ -n "$SID" ] && [ "$SID" = "$(team_owner)" ]; }
only_owner() {  # only_owner <what>
  is_owner || deny "$1 is for the session that owns this workspace's team lock (owner: $(short8 "$(team_owner)")); this session ($SID) is not it. Ask the owner."
}
# owner_call <verb>: release or heartbeat of an owned lock: its owner only, naming itself with --sid.
owner_call() {
  [ -z "$A_ERR" ] || deny "$1: $A_ERR. Run it as a single plain command: ${LOCK_SCRIPT_HINT} $1 --id <slug> --sid <your session id> [flags]."
  no_dyn
  own_sid --sid "$A_SID"
  only_owner "$1"
}
# The registrations naming <slug> go when its owner releases it: a left-over one would pass as the holder
# of a later lock that reuses the slug. ls, not a glob: this hook runs with set -f.
drop_registrations() {
  for _rn in $(ls "$LOCK_DIR/sessions" 2>/dev/null); do
    [ "$(head -n1 "$LOCK_DIR/sessions/$_rn" 2>/dev/null)" = "$1" ] && rm -f "$LOCK_DIR/sessions/$_rn" 2>/dev/null
  done
}

# force_gate / transfer_gate: the script's read-only --check says what the call would do; a stale turn
# or a transfer then becomes a permission prompt, a turn whose session ended is freed at once.
force_gate() {
  run_lock_check "turn give --force" freeing turn give --id "$A_ID" --sid "$A_SID" --by "$A_BY" --force --check
  case "$_res" in
    *'
'*) deny "turn give --force --check failed; not freeing the turn." ;;
    'FORCEABLE-NOW '*) guard_log "FORCE-NOW sid=${SID:-unknown} member=$(short8 "$A_SID")"; exit 0 ;;
    'FORCEABLE '*) need_prompt "turn give --force" "the stuck turn"
                   guard_log "FORCE-ASK sid=${SID:-unknown} member=$(short8 "$A_SID")"; decide ask "${_res#FORCEABLE } Asked by session $(short8 "$SID") (the owner)." ;;
    'NOT-FORCEABLE '*) deny "the turn cannot be freed: ${_res#NOT-FORCEABLE }" ;;
    *) deny "turn give --force --check failed; not freeing the turn." ;;
  esac
}
transfer_gate() {
  run_lock_check "owner transfer" transferring owner transfer --id "$A_ID" --to "$A_TO" --check
  case "$_res" in
    *'
'*) deny "owner transfer --check failed; not transferring." ;;
    'TRANSFERABLE '*) need_prompt "owner transfer" "the lost owner"
                      guard_log "TRANSFER-ASK sid=${SID:-unknown} to=$(short8 "$A_TO")"
                      if is_owner; then _who="the current owner"; elif team_party; then _who="a member"; else _who="a session that is neither owner nor member"; fi
                      decide ask "${_res#TRANSFERABLE } Asked by session $(short8 "$SID"), $_who." ;;
    'NOT-TRANSFERABLE '*) deny "ownership cannot move: ${_res#NOT-TRANSFERABLE }" ;;
    *) deny "owner transfer --check failed; not transferring." ;;
  esac
}

# team_call: member, turn and owner, each checked against the calling session, then run by the script.
team_call() {
  below_root && deny "WORKSPACE_LOCK_DIR is unset and this cwd is below the workspace root, so the lock script would not find this workspace's lock from here. Run the call from the workspace root ($(dirname "$LOCK_DIR"))."
  case "$SUB $ACT" in
    'member add'|'member remove') _vf='--id --sid --by'; _sw='' ;;
    'member list') _vf='--id'; _sw='' ;;
    'turn take') _vf='--id --sid --eta --task'; _sw='' ;;
    'turn give') _vf='--id --sid --tree --by'; _sw='--force --check' ;;
    'turn beat') _vf='--id --sid --eta'; _sw='' ;;
    'owner transfer') _vf='--id --to'; _sw='--check' ;;
    *) deny "usage: ${LOCK_SCRIPT_HINT} {member add|remove|list | turn take|give|beat | owner transfer} --id <slug> [flags]; each runs as a single plain command." ;;
  esac
  lock_args $((VERB_AT + 1)) "$_vf" "$_sw"
  [ -z "$A_ERR" ] || deny "$SUB $ACT: $A_ERR. Run it as a single plain command with plain flags: ${LOCK_SCRIPT_HINT} $SUB $ACT --id <slug> ..."
  no_dyn
  case "$A_ID" in ''|-*|*[!A-Za-z0-9._-]*) deny "$SUB $ACT: --id <slug> is required (a plain [A-Za-z0-9._-] value)." ;; esac
  case "$SUB $ACT" in
    'member list') ;;
    'member add'|'member remove') own_sid --by "$A_BY"; only_owner "member $ACT"; sid_shape --sid "$A_SID" ;;
    'turn take'|'turn beat') own_sid --sid "$A_SID" ;;
    'turn give')
      if [ "$A_FORCE" = 1 ]; then
        [ -z "$A_TREE" ] || deny "turn give --force: --tree does not go with --force (a forced give records 'unknown')."
        own_sid --by "$A_BY"; only_owner "turn give --force"; sid_shape --sid "$A_SID"
        [ "$A_CHECK" = 1 ] || force_gate
      else
        [ -z "$A_BY" ] && [ "$A_CHECK" = 0 ] || deny "turn give: --by and --check go with --force."
        own_sid --sid "$A_SID"
      fi ;;
    'owner transfer')
      sid_shape --to "$A_TO"
      [ "$A_CHECK" = 1 ] || transfer_gate ;;
  esac
  exit 0
}

acquire_call() {
  lock_args "$VERB_AT" '--id --sid --repos --phase --task --reason --eta' '--owned --after-clear'
  # The slug is the --id the flags carry (a quoted --task that mentions --id is text). A call that does not
  # parse falls back to the first --id word; while the lock is owned it is judged as an owned call below, so
  # the guard's reading and the script's can never differ.
  _slug=$A_ID
  if [ -n "$A_ERR" ]; then
    _slug=""; _prev=""
    for _w in $CMD_WORDS; do [ "$_prev" = --id ] && { _slug=$_w; break; }; _prev=$_w; done
  fi
  case "$_slug" in
    '') deny "acquire must be run as: ${LOCK_SCRIPT_HINT} acquire --id <slug> [--eta ...]; the --id is how the guard registers this session." ;;
    *[!A-Za-z0-9._-]*) deny "acquire --id must match [A-Za-z0-9._-]+." ;;
  esac
  below_root && deny "$BELOW_ROOT_MSG"
  _ctx=0; lock_owned && [ "$_slug" = "$(holder)" ] && _ctx=1
  if [ "$A_OWNED" = 1 ] || [ "$_ctx" = 1 ] || { [ -n "$A_ERR$A_DYN" ] && lock_owned; }; then
    [ -z "$A_ERR" ] || deny "acquire: $A_ERR. Run it as a single plain command: ${LOCK_SCRIPT_HINT} acquire --id <slug> --owned --sid <your session id> --eta <duration>."
    no_dyn
    if [ "$_ctx" = 1 ]; then
      # The lock is owned and this call names it: only its owner re-enters, and by saying --owned. Never
      # registered: an owned lock is judged by session id, and a refused acquire leaves nothing behind.
      if ! is_owner || [ "$A_OWNED" != 1 ] || [ "$A_SID" != "$SID" ]; then
        guard_log "BLOCKED ${SID:-unknown} acquire of owned lock '$_slug' - not its owner"
        if team_party; then
          deny "a member never acquires the team lock: '$_slug' is owned by session $(short8 "$(team_owner)"). Take turns instead: ${LOCK_SCRIPT_HINT} turn take --id $_slug --sid $SID --eta +<minutes> in the BACKGROUND."
        fi
        deny "this workspace's lock '$_slug' is an owned team lock and is closed: only its owner (session $(short8 "$(team_owner)")) adds members. Tell the user; don't join, and don't take a solo id. Give the owner your session id (run echo \$CLAUDE_CODE_SESSION_ID) and only read until it has added you."
      fi
    else
      own_sid --sid "$A_SID"
    fi
    exit 0
  fi
  # Registered before the script runs: the guard cannot see whether the acquire succeeds. Not into an owned
  # lock (above), so a refused acquire of one never leaves a registration. A plain acquire of another slug
  # registers as it always did, even when the parser dislikes a flag the script accepts.
  if [ -n "$SID" ]; then
    mkdir -p "$LOCK_DIR/sessions" 2>/dev/null && printf '%s\n' "$_slug" > "$LOCK_DIR/sessions/$SID" 2>/dev/null \
      || echo "workspace-lock-guard: could not register this session" >&2
  fi
  exit 0
}

release_call() {
  lock_args "$VERB_AT" '--id --sid' '--force'
  _rs="${A_ID:-${WORKSPACE_LOCK_ID:-}}"
  # On an owned lock a call the parser cannot read fails closed: it is judged as the owner's release.
  if lock_owned && { [ -n "$A_ERR$A_DYN" ] || [ "$_rs" = "$(holder)" ]; }; then
    owner_call release
    drop_registrations "$(holder)"   # at the owner's call, not its result: owned locks ignore registrations, so a refused release costs nothing
    exit 0
  fi
  case "$A_DYN" in *--sid*) no_dyn ;; esac
  [ -n "$SID" ] || exit 0
  # Only a release the script carries out (its --id is the holder's): a refused one must not
  # drop the registration, or a holder that mistyped its id is locked out of its own lock.
  # Read the words after `release` the way cmd_release does: --id <value> and --sid <session id> pairs,
  # the last --id wins, quotes and backslashes removed, else WORKSPACE_LOCK_ID. Any other word (--id=x,
  # --bogus, --force on an open lock) or a flag with no value makes the script refuse, so the registration
  # stays. Redirects the guard already allows (2>&1, > scratch log) are not words to the script: strip
  # them first. An id the shell expands ($VAR, backticks) cannot be read here, so the registration is
  # dropped (a change: the old code compared the unexpanded text, which never matched, and kept it).
  _rid=""; _prev=""; _seen=0; _bad=0; _dyn=0
  for _w in $(strip_redirects "$CMD" | tr -d "'\"\\\\"); do
    if [ "$_seen" = 0 ]; then [ "$_w" = "release" ] && _seen=1; continue; fi
    case "$_w" in *'$'*|*'`'*) _dyn=1 ;; esac
    if [ "$_prev" = "--id" ]; then _rid="$_w"; _prev=""; continue; fi
    if [ "$_prev" = "--sid" ]; then sid_ok "$_w" || _bad=1; _prev=""; continue; fi
    case "$_w" in --id) _prev="--id" ;; --sid) _prev="--sid" ;; *) _bad=1 ;; esac
  done
  [ -z "$_prev" ] || _bad=1
  [ -n "$_rid" ] || _rid="${WORKSPACE_LOCK_ID:-}"
  if [ "$_dyn" = 1 ]; then
    rm -f "$LOCK_DIR/sessions/$SID" 2>/dev/null
  elif [ "$_bad" = 0 ] && [ -n "$_rid" ] && [ "$_rid" = "$(holder)" ]; then
    rm -f "$LOCK_DIR/sessions/$SID" 2>/dev/null
  fi
  exit 0
}

heartbeat_call() {
  lock_args "$VERB_AT" '--id --sid --eta --phase' ''
  _hs="${A_ID:-${WORKSPACE_LOCK_ID:-}}"
  if lock_owned && { [ -n "$A_ERR$A_DYN" ] || [ "$_hs" = "$(holder)" ]; }; then owner_call heartbeat; fi
  exit 0
}

# lock_call: the lock script run as a single plain command (an interpreter in front is fine).
# Always allowed: a non-holder must be able to acquire. acquire registers the session, except into an
# owned lock, which is judged by session id.
lock_call() {  # LOCK_DIR: the lock this call acts on (set by handle_bash)
  case "$SUB" in
    status) exit 0 ;;
    acquire) acquire_call ;;
    release) release_call ;;
    heartbeat) heartbeat_call ;;
    clear) clear_gate ;;
    member|turn|owner) team_call ;;
    '') deny "usage: ${LOCK_SCRIPT_HINT} {acquire|release|status|heartbeat|clear|member|turn|owner} --id <slug> [flags]" ;;
    *) deny "unknown lock verb '$SUB'; the verbs are acquire|release|status|heartbeat|clear|member|turn|owner, each run as a single plain command." ;;
  esac
}

# all_reads: every segment is a read, and nothing is substituted or redirected into the workspace.
all_reads() {
  _segs=$(split_command "$(strip_redirects "$CMD")")
  case "$_segs" in *'!subst'*) REASON=subst; return 1 ;; *'!redirect'*) REASON=redirect; return 1 ;; esac
  while IFS= read -r _seg; do
    # Words as the tool receives them, quotes and backslashes removed, so `"-delete"` is -delete.
    set -- $(printf '%s' "$_seg" | tr -d "'\"\\")
    [ $# -gt 0 ] || continue
    is_exact_read "$@" && continue
    case "$1" in
      sed) set -- $_seg; is_shaped_read "$@" && continue; REASON="shape:sed"; return 1 ;;  # sed reads its quoted script itself
      git|sort|uniq|sysctl|log|/usr/bin/log|ulimit|curl)
        is_shaped_read "$@" && continue
        REASON="shape:$1"; return 1 ;;
    esac
    if ! is_read_word "$1"; then REASON="word:$(redact "$1")"; return 1; fi
    if has_write_flag "$@"; then REASON="write-flag:$1"; return 1; fi
  done <<EOF
$_segs
EOF
  return 0
}
redact() { case "$1" in [A-Za-z_]*=*) printf '%s=<redacted>' "${1%%=*}" ;; *) printf '%s' "$1" ;; esac; }

# archive_heredoc: the whole command is one heredoc written into the workspace's own .archive/, and nothing
# else. Accepted: a first line `cat >> <path> <<'TAG'` (or `cat >`) with a single-quoted delimiter, a body, the
# first line equal to TAG, and nothing after it. Everything the first line may hold is one plain word per slot,
# so no second redirect, `&&`, `;`, `|`, expansion or backslash-newline fits. An unquoted delimiter, `<<-` and
# `<<<` never match (the body would expand or the tabs would change). A body line `\` is literal under a quoted
# delimiter, so the body is free text. Symlinks inside .archive/ are not followed: the ADR 0012 residual.
archive_heredoc() {
  _c=$CMD   # command substitution already dropped any trailing newlines
  case "$_c" in *$'\n'*) ;; *) return 1 ;; esac
  _re="^cat (>>|>) ([A-Za-z0-9/._+,@%-]+) <<'([A-Za-z0-9_]+)'\$"
  [[ "${_c%%$'\n'*}" =~ $_re ]] || return 1
  _hd_path=${BASH_REMATCH[2]}; _hd_tag=${BASH_REMATCH[3]}
  case "$_hd_path" in *..*|*/) return 1 ;; esac
  _hd_path=$(abspath "$_hd_path")
  case "$_hd_path" in "$(dirname "$LOCK_DIR")"/.archive/?*) ;; *) return 1 ;; esac
  _hd_body=${_c#*$'\n'}
  _hd_end=0
  while IFS= read -r _hd_line; do
    [ "$_hd_end" = 0 ] || return 1   # a line after the terminator, blank or not
    [ "$_hd_line" = "$_hd_tag" ] && _hd_end=1
  done <<EOT
$_hd_body
EOT
  [ "$_hd_end" = 1 ]
}

handle_bash() {
  CMD=$(jqin '.tool_input.command // empty')
  CMD_WORDS=$(printf '%s' "$CMD" | tr '\n\t' '  ')
  CD_SEEN=0
  printf '%s' "$CMD" | grep -qE '(^|[;&|(])[[:space:]]*(cd|pushd|popd)([[:space:]]|$)' && CD_SEEN=1
  set -- $CMD_WORDS
  FIRST="${1:-}"; SUB="${2:-}"; ACT="${3:-}"; VERB_AT=2   # VERB_AT: the words up to and with the verb
  case "$FIRST" in bash|sh|zsh) is_lock_script "$SUB" && { FIRST=$SUB; SUB="${3:-}"; ACT="${4:-}"; VERB_AT=3; } ;; esac
  if is_lock_script "$FIRST"; then
    case "${WORKSPACE_LOCK_DIR:-}" in /*) LOCK_DIR=$WORKSPACE_LOCK_DIR ;; *) LOCK_DIR=$(walk_up "$CWD") ;; esac
    [ -n "$LOCK_DIR" ] || LOCK_DIR="$CWD/.workspace-lock"   # the script's own default
    # Only a single plain call: no second command, substitution or redirect into the workspace.
    _segs=$(split_command "$(strip_redirects "$CMD")")
    [ "$(printf '%s\n' "$_segs" | grep -c .)" = 1 ] && lock_call
  fi
  # A heredoc into this workspace's own .archive/ is judged on its text before anything lexes the body.
  if [ "$FIRST" = cat ]; then
    LOCK_DIR=$(resolve_lock_dir "$CWD")
    [ -z "$LOCK_DIR" ] || ! archive_heredoc || exit 0
  fi
  # Any other call of a prompted verb (clear, owner transfer, a force-give; compound, redirected, behind cd)
  # would skip the prompt.
  case "$CMD" in
    *workspace-lock.sh*) printf '%s\n' "$(split_command "$CMD")" | while IFS= read -r _seg; do
        set -- $_seg
        case "${1:-}" in bash|sh|zsh) shift ;; esac
        is_lock_script "${1:-}" || continue
        case "${2:-}" in clear|owner) exit 1 ;; esac
        if [ "${2:-}" = turn ]; then case "$_seg" in *--force*) exit 1 ;; esac; fi
      done || deny "run clear, owner transfer and turn give --force each as a single plain command (${LOCK_SCRIPT_HINT} clear --id <your-lock-id> --holder <holder-id>): they ask the user first." ;;
  esac

  LOCK_DIR=$(resolve_lock_dir "$CWD")
  [ -n "$LOCK_DIR" ] || exit 0
  if lock_owned; then
    # The lock folder holds the members, turns and end markers a force rests on: no session writes it
    # by hand, the turn holder included. Reads of it pass like any read.
    if [ "${WORKSPACE_LOCK_BYPASS:-}" != 1 ]; then
      if names_lock_folder && ! all_reads; then
        guard_log "BLOCKED ${SID:-unknown} wanted a write into the lock folder"
        deny "the lock folder is the team lock's own state (members, turns, end markers): no session changes it by hand, whoever holds the turn. Use the lock script's verbs (member, turn, owner). For a .gitignore line, use the Edit tool."
      fi
      # Reaching here, a segment that runs the lock script is not the single plain call lock_call judged
      # (a pipe, a chain, a quoted or repo path): its identity could not be checked.
      lock_script_segment || deny "run the lock script's verbs as a single plain call, spelled ${LOCK_SCRIPT_HINT} <verb> ...: in an owned team a pipe, a chain, a redirect or another path skips the check of who is calling."
      git_clean_segment || deny "git clean would delete the lock folder (members, turns) unless it is ignored: preview with git clean -n, or exclude it with -e .workspace-lock."
    fi
    team_may_mutate && exit 0
  else
    is_holder && ! holder_expired && exit 0
  fi
  if [ "${#CMD}" -gt 8192 ]; then
    REASON=size  # too long to classify quickly: the lock decides
  else
    is_keep_awake "$CMD" && exit 0
    all_reads && exit 0
    case "$CMD" in
      *'$'*|*'`'*|*'<('*|*'>('*|*$'\n'*|*$'\t'*|*$'\r'*) ;;  # expansion or a second line: not plain words
      *) scratch_only "$CMD_WORDS" && exit 0 ;;
    esac
  fi
  guard_mutation "Bash($(redact "$FIRST"))"
  exit 0
}

# git-mcp: reads pass; anything else is guarded by the repo path it targets.
guard_git_mcp() {
  _p=$(jqin '.tool_input.path // empty')
  [ -n "$_p" ] && [ "$_p" != "." ] || _p=$CWD
  LOCK_DIR=$(resolve_lock_dir "$_p")
  [ -n "$LOCK_DIR" ] || exit 0
  if [ "$TOOL" = mcp__git-mcp__git_clean ] && lock_owned && [ "${WORKSPACE_LOCK_BYPASS:-}" != 1 ]; then
    deny "git_clean would delete the lock folder (members, turns) unless it is ignored, and this tool cannot exclude it: run git clean -n to preview, or git clean with -e .workspace-lock in Bash."
  fi
  guard_mutation "$TOOL"
  exit 0
}
MODE=$(jqin '.tool_input.mode // empty')

case "$TOOL" in
  Bash) handle_bash ;;
  Edit|Write|MultiEdit|NotebookEdit)
    TARGET=$(jqin '.tool_input.file_path // .tool_input.notebook_path // empty')
    [ -n "$TARGET" ] || TARGET="$CWD/x"
    TARGET=$(abspath "$TARGET")
    LOCK_DIR=$(resolve_lock_dir "$(dirname "$TARGET")")
    [ -n "$LOCK_DIR" ] || exit 0
    if lock_owned && [ "${WORKSPACE_LOCK_BYPASS:-}" != 1 ] && in_lock_folder "$TARGET"; then
      guard_log "BLOCKED ${SID:-unknown} wanted $TOOL into the lock folder"
      deny "the lock folder is the team lock's own state (members, turns, end markers): no session changes it by hand, whoever holds the turn. Use the lock script's verbs (member, turn, owner)."
    fi
    archive_exempt "$TARGET" && exit 0
    guard_mutation "$TOOL" ;;
  mcp__git-mcp__git_status|mcp__git-mcp__git_log|mcp__git-mcp__git_diff|mcp__git-mcp__git_show|mcp__git-mcp__git_blame|mcp__git-mcp__git_reflog) ;;
  mcp__git-mcp__git_remote) case "$MODE" in ''|list|get-url) ;; *) guard_git_mcp ;; esac ;;
  mcp__git-mcp__git_branch) case "$MODE" in list|show-current) ;; *) guard_git_mcp ;; esac ;;  # an empty mode may carry a name: create
  mcp__git-mcp__git_fetch)  # no refspec in its schema; only these keys pass, so a new option is guarded until reviewed (depth can shallow the repo)
    [ "$(jqin '(.tool_input // {}) | keys - ["path","remote","prune","tags"] | length')" = 0 ] || guard_git_mcp
    _r=$(jqin '.tool_input.remote // empty')  # a remote name, as on the Bash path: not an option, a URL or a path with a colon
    case "$_r" in -*|*[!A-Za-z0-9._-]*) guard_git_mcp ;; esac ;;
  mcp__git-mcp__git_tag)    case "$MODE" in ''|list|verify) ;; *) guard_git_mcp ;; esac ;;
  mcp__git-mcp__git_stash)  case "$MODE" in list) ;; *) guard_git_mcp ;; esac ;;  # the default mode pushes
  mcp__git-mcp__*) guard_git_mcp ;;
esac
exit 0
