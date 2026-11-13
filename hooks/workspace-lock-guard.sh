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
      guard_log "BLOCKED ${SID:-unknown} wanted $1 - holder unknown$_why"
      deny "lock.d exists but the holder is unknown, so the lock is orphaned. Ask a human to inspect and clear $LOCK_DIR/lock.d; do not remove it yourself."
    fi
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
           deny "a team run holds this workspace's lock: held by '$_h' (ETA: $(lock_eta)).$(holder_note) Tell the user. Don't take a solo id, and join with ${LOCK_SCRIPT_HINT} acquire --id $_h --eta <realistic> only if your spawn prompt names you a member of that run. Never remove lock.d yourself.$_read" ;;
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
  # $'a\x3ab'), and a brace list expands to several ({,-}-upload-pack=x): no word of these forms may carry either.
  for _w in "$@"; do case "$_w" in *'$'*|*'`'*|*'{'*) return 1 ;; esac; done
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
    _t="${_r#*>}"; _t="${_t#>}"; _t="${_t#"${_t%%[![:space:]]*}"}"
    case "$_t" in
      '&'[0-9]|/dev/null) ;;
      *) scratch_path "$_t" || continue ;;
    esac
    _s="${_s/"$_r"/ }"
  done <<EOF
$(printf '%s' "$1" | grep -oE '[0-9]*>>?[[:space:]]*(&[0-9]|[^[:space:];|&<>()]+)')
EOF
  printf '%s' "$_s"
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
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    cli|claude-vscode|claude-desktop) ;;
    *) deny "clear needs a human at the permission prompt, and this session has none (entrypoint '${CLAUDE_CODE_ENTRYPOINT:-unset}'). Surface the stuck lock to the user." ;;
  esac
  case "$PERMISSION_MODE" in
    default|acceptEdits|auto|plan) ;;
    *) deny "clear needs a permission prompt, and permission mode '${PERMISSION_MODE:-unset}' may not show one. Surface the stuck lock to the user." ;;
  esac
  _out=$(mktemp "${TMPDIR:-/tmp}/wlg-clear.XXXXXX" 2>/dev/null) || deny "clear --check could not run; not clearing."
  ( cd "$CWD" 2>/dev/null && "$LS_PATH" clear --check --id "$_cid" --holder "$_ch" ) >"$_out" 2>/dev/null &
  _pid=$!; _n=0
  while kill -0 "$_pid" 2>/dev/null; do  # at most 5 s: a hung check must not stall the session
    if [ "$_n" -ge 20 ]; then kill "$_pid" 2>/dev/null; rm -f "$_out"; deny "clear --check timed out; not clearing."; fi
    sleep 0.25; _n=$((_n + 1))
  done
  _res=$(cat "$_out" 2>/dev/null); rm -f "$_out"
  case "$_res" in
    *'
'*) deny "clear --check failed; not clearing." ;;
    'CLEARABLE '*) guard_log "CLEAR-ASK sid=${SID:-unknown} id=$_cid holder=$_ch"; decide ask "${_res#CLEARABLE }" ;;
    'NOT-CLEARABLE '*) deny "not clearable: ${_res#NOT-CLEARABLE }" ;;
    *) deny "clear --check failed; not clearing." ;;
  esac
}

# lock_call: the lock script run as a single plain command (an interpreter in front is fine).
# Always allowed: a non-holder must be able to acquire. acquire registers the session.
lock_call() {  # LOCK_DIR: the lock this call acts on (set by handle_bash)
  case "$SUB" in
    acquire|release|status|heartbeat) ;;
    clear) clear_gate ;;
    '') deny "usage: ${LOCK_SCRIPT_HINT} {acquire|release|status|heartbeat|clear} --id <slug> [flags]" ;;
    *) deny "unknown lock verb '$SUB'; the verbs are acquire|release|status|heartbeat|clear, each run as a single plain command." ;;
  esac
  if [ "$SUB" = acquire ]; then
    _slug=""; _prev=""
    for _w in $CMD_WORDS; do [ "$_prev" = --id ] && { _slug=$_w; break; }; _prev=$_w; done
    case "$_slug" in
      '') deny "acquire must be run as: ${LOCK_SCRIPT_HINT} acquire --id <slug> [--eta ...]; the --id is how the guard registers this session." ;;
      *[!A-Za-z0-9._-]*) deny "acquire --id must match [A-Za-z0-9._-]+." ;;
    esac
    below_root && deny "$BELOW_ROOT_MSG"
    if [ -n "$SID" ]; then
      mkdir -p "$LOCK_DIR/sessions" 2>/dev/null && printf '%s\n' "$_slug" > "$LOCK_DIR/sessions/$SID" 2>/dev/null \
        || echo "workspace-lock-guard: could not register this session" >&2
    fi
  elif [ "$SUB" = release ] && [ -n "$SID" ]; then
    # Only a release the script carries out (its --id is the holder's): a refused one must not
    # drop the registration, or a holder that mistyped its id is locked out of its own lock.
    # Read the words after `release` the way cmd_release does: --id <value> pairs only, the last
    # one wins, quotes and backslashes removed, else WORKSPACE_LOCK_ID. Any other word (--id=x,
    # --bogus) or a --id with no value makes the script refuse, so the registration stays. Redirects
    # the guard already allows (2>&1, > scratch log) are not words to the script: strip them first.
    # An id the shell expands ($VAR, backticks) cannot be read here, so the registration is dropped
    # (a change: the old code compared the unexpanded text, which never matched, and kept it).
    _rid=""; _prev=""; _seen=0; _bad=0; _dyn=0
    for _w in $(strip_redirects "$CMD" | tr -d "'\"\\\\"); do
      if [ "$_seen" = 0 ]; then [ "$_w" = "release" ] && _seen=1; continue; fi
      case "$_w" in *'$'*|*'`'*) _dyn=1 ;; esac
      if [ "$_prev" = "--id" ]; then _rid="$_w"; _prev=""; continue; fi
      case "$_w" in --id) _prev="--id" ;; *) _bad=1 ;; esac
    done
    [ -z "$_prev" ] || _bad=1
    [ -n "$_rid" ] || _rid="${WORKSPACE_LOCK_ID:-}"
    if [ "$_dyn" = 1 ]; then
      rm -f "$LOCK_DIR/sessions/$SID" 2>/dev/null
    elif [ "$_bad" = 0 ] && [ -n "$_rid" ] && [ "$_rid" = "$(holder)" ]; then
      rm -f "$LOCK_DIR/sessions/$SID" 2>/dev/null
    fi
  fi
  exit 0
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
  FIRST="${1:-}"; SUB="${2:-}"
  case "$FIRST" in bash|sh|zsh) is_lock_script "$SUB" && { FIRST=$SUB; SUB="${3:-}"; } ;; esac
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
  # Any other call of the lock script's clear verb (compound, redirected, behind cd) would skip the prompt.
  case "$CMD" in
    *workspace-lock.sh*) printf '%s\n' "$(split_command "$CMD")" | while IFS= read -r _seg; do
        set -- $_seg
        case "${1:-}" in bash|sh|zsh) shift ;; esac
        if is_lock_script "${1:-}" && [ "${2:-}" = clear ]; then exit 1; fi
      done || deny "run clear as a single plain command: ${LOCK_SCRIPT_HINT} clear --id <your-lock-id> --holder <holder-id>. It asks the user before clearing." ;;
  esac

  LOCK_DIR=$(resolve_lock_dir "$CWD")
  [ -n "$LOCK_DIR" ] || exit 0
  is_holder && ! holder_expired && exit 0
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
