#!/bin/bash
# Pre-tool-use hook: hard-denies writes to protected folders and to the global settings files.
# Configured in ~/.claude/settings.json for PreToolUse with matcher:
#   Edit|Write|MultiEdit|NotebookEdit|Bash|Monitor|mcp__git-mcp__.*
#
# WHAT IS PROTECTED
#   - Any folder that holds a file named .protected-checkout, and everything under it. The marker is untracked
#     (git-ignore it) and a person creates it with `touch`; a write to an existing marker is itself denied, so it
#     cannot be removed or moved (a call that creates one only widens the protection). The hook finds a root by walking up from the target's real path, so a clone made elsewhere (no marker
#     in it) stays editable, and a non-repository folder can be protected the same way.
#   - ~/.claude/settings*.json (any such file directly under ~/.claude).
#   Exceptions: <root>/.archive/** is writable; `git pull --ff-only`, `git merge --ff-only` and the git MCP
#   git_pull with fastForwardOnly are allowed (they move a checkout to a reviewed commit and nothing else).
#
# NEVER ASKS. Every decision is a deny or silence. It names no repository or tool of any project.
# FAIL-CLOSED without jq (as git-mcp-guard): the input cannot be read, so the call is denied.
#
# WHAT COUNTS AS A WRITE (reads are never denied)
#   - Edit, Write, MultiEdit, NotebookEdit: the target's real path (symlinks followed, case-insensitive compare).
#   - git MCP tools: every tool except the read ones (status, log, diff, show, blame, reflog, fetch, push, working
#     directory tools, and the list/show modes of branch, tag, remote, stash, worktree). The folder is the call's
#     `path`; a missing or relative `path` is read against the session's folder.
#   - Bash and Monitor, one simple rule: the command is split into segments (; && || | & newline, and the insides of
#     $( ), backticks and ( )), `cd <dir>` is tracked left to right, and a segment is denied when it is a write
#     shape and a target resolves into a protected place. Write shapes: a > >> >| &> redirect; rm rmdir unlink shred
#     touch mkdir chmod chown chgrp truncate tee mv cp install ln rsync dd patch; sed -i and perl -i; tar x, unzip,
#     curl -o/-O, wget; find with -delete, -fprint or -exec of a write verb; xargs of those; git subcommands that
#     change a work tree, refs or config (checkout, reset, clean, restore, commit, add, rm, mv, merge, rebase, pull,
#     stash, config, tag, branch, remote, worktree, clone, init and the like), judged by the folder git runs in
#     (`git -C`, `--work-tree`, or the tracked cd). `bash -c STRING` and `eval STRING` are read recursively.
#     Relative operands resolve against the tracked folder; a glob is judged by its directory prefix.
#
# KNOWN LIMITS (this is a guard against mistakes and the classifier is a second line, not a sandbox)
#   Not read: the program text of an interpreter (python -c, node -e, a script file), make/npm/other tools that
#   write on their own, paths built at run time ($VAR, $(...) output), a `cd` to a variable or glob (the folder is
#   then unknown and only absolute operands are judged), file names fed to xargs on stdin, $(...) inside a heredoc,
#   hard links, the target of a find -exec, programs that write on their own (archive creators, compressors,
#   formatters with an in-place flag), env -C and env -S, a < or > inside (( )) arithmetic, and a git MCP call with no `path` when
#   the server's own folder differs from the session's. A
#   recursive delete or move of a folder that contains a protected root is caught only for the session's own root
#   and for ~/.claude.
#
# Reads JSON from stdin. Returns a JSON deny decision or nothing; exit 0 always.
# No `set -e`: it would break the exit-0-always contract. Runs on bash 3.2.

MARKER=.protected-checkout

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"protected-paths-guard: jq unavailable - writes blocked (fail-closed). Install jq or make the change yourself."}}'
  exit 0
fi

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

audit_deny() {
  local logger
  logger="$(dirname "${BASH_SOURCE[0]}")/audit-logger.sh"
  [ -r "$logger" ] || return 0
  printf '%s' "$INPUT" \
    | jq -c --arg r "$1" --arg h "protected-paths-guard" \
        '. + {_audit_event:"deny",_deny_reason:$r,_deny_hook:$h}' 2>/dev/null \
    | bash "$logger" >/dev/null 2>&1 || true
}

deny() {
  audit_deny "$1"
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("protected-paths-guard: " + $reason)
    }
  }'
  exit 0
}

if [ -z "$TOOL" ]; then
  deny "could not read the tool call (empty or malformed stdin) - blocked (fail-closed)."
fi

ti() { printf '%s' "$INPUT" | jq -r "(.tool_input${1}) // empty" 2>/dev/null; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---- paths -------------------------------------------------------------------------------------------------------

HOME_R=$(cd -P -- "$HOME" 2>/dev/null && pwd -P) || HOME_R=$HOME
LHOME=$(lower "$HOME")
LHOME_R=$(lower "$HOME_R")

SESSION_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[ -n "$SESSION_CWD" ] || SESSION_CWD=$PWD
CWD=$SESSION_CWD

# lexnorm <abs path>: drop ., empty and .. components without touching the file system.
lexnorm() {
  local p="$1" out="" part
  local IFS=/
  set -f
  local parts=($p)
  set +f
  for part in "${parts[@]}"; do
    case "$part" in
      "" | .) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$part" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# phys_any <abs dir>: the real path of the longest existing ancestor, with the rest appended as written.
phys_any() {
  local a="$1" tail="" r
  while [ -n "$a" ] && [ ! -d "$a" ]; do
    case "$a" in */*) ;; *) tail="/$a$tail"; a=""; break ;; esac
    tail="/${a##*/}$tail"
    a=${a%/*}
  done
  [ -n "$a" ] || a=/
  r=$(cd -P -- "$a" 2>/dev/null && pwd -P) || r=$a
  printf '%s' "${r%/}$tail"
}

# follow <abs path>: resolve a chain of symbolic links in the last component (at most 10).
follow() {
  local cur="$1" i=0 t d
  while [ -L "$cur" ] && [ "$i" -lt 10 ]; do
    t=$(readlink "$cur") || break
    case "$t" in
      /*) cur=$t ;;
      *) cur="${cur%/*}/$t" ;;
    esac
    d=${cur%/*}
    [ -n "$d" ] || d=/
    cur="$(phys_any "$d")/${cur##*/}"
    i=$((i + 1))
  done
  printf '%s' "$cur"
}

# candidates <abs path>: one real-path reading per line. The parent's real path with the name as written (so a
# link that is removed or replaced counts as its own place), the same with a final link followed, and the
# lexical reading (which covers .. in a part of the path that does not exist yet).
candidates() {
  local p="$1" dir name rp rf lx
  lx=$(lexnorm "$p")
  p=${p%/}
  [ -n "$p" ] || p=/
  if [ -d "$p" ]; then
    rp=$(cd -P -- "$p" 2>/dev/null && pwd -P) || rp=$lx
    printf '%s\n' "$rp"
    printf '%s\n' "$lx"
    return
  fi
  name=${p##*/}
  dir=${p%/*}
  [ -n "$dir" ] || dir=/
  case "$name" in
    . | ..)
      printf '%s\n' "$lx"
      return
      ;;
  esac
  rp="$(phys_any "$dir")/$name"
  rp=${rp//\/\//\/}
  rf=$(follow "$rp")
  printf '%s\n' "$rp"
  [ "$rf" = "$rp" ] || printf '%s\n' "$rf"
  [ "$lx" = "$rp" ] || printf '%s\n' "$lx"
}

PROT_WHAT=""

# prot_check <real path>: 0 when the path is protected (and not excepted); sets PROT_WHAT.
prot_check() {
  local c="$1" lc rest root d rel lrel pre
  lc=$(lower "$c")
  for pre in "$LHOME_R" "$LHOME"; do
    case "$lc" in
      "$pre"/.claude/settings*.json)
        rest=${lc#"$pre"/.claude/settings}
        case "$rest" in
          */*) ;;
          *)
            PROT_WHAT="a global settings file"
            return 0
            ;;
        esac
        ;;
    esac
  done
  root=""
  d=$c
  while :; do
    if [ -n "$d" ] && [ -e "$d/$MARKER" ]; then
      root=$d
      break
    fi
    [ -n "$d" ] && [ "$d" != "/" ] || break
    d=${d%/*}
  done
  [ -n "$root" ] || { [ -e "/$MARKER" ] && root=/; }
  [ -n "$root" ] || return 1
  rel=${c#"$root"}
  lrel=$(lower "$rel")
  case "$lrel" in
    /.archive | /.archive/*) return 1 ;;
  esac
  PROT_WHAT="the protected folder $root (it holds a $MARKER file)"
  return 0
}

# anc_check <real path>: 0 when the path is a proper ancestor of the session's own protected root or of ~/.claude.
SESSION_ROOT=""
find_session_root() {
  local d c
  c=$(phys_any "$SESSION_CWD")
  d=$c
  while :; do
    if [ -n "$d" ] && [ -e "$d/$MARKER" ]; then
      SESSION_ROOT=$d
      return
    fi
    [ -n "$d" ] && [ "$d" != "/" ] || return
    d=${d%/*}
  done
}
anc_check() {
  local c="$1" lc
  lc=$(lower "$c")
  [ "$lc" = "/" ] && { PROT_WHAT="the file system root, which holds protected places"; return 0; }
  case "$(lower "$HOME_R")/.claude/" in
    "$lc"/*)
      PROT_WHAT="a folder that holds ~/.claude"
      return 0
      ;;
  esac
  if [ -n "$SESSION_ROOT" ]; then
    case "$(lower "$SESSION_ROOT")/" in
      "$lc"/*)
        PROT_WHAT="a folder that holds the protected folder $SESSION_ROOT"
        return 0
        ;;
    esac
  fi
  return 1
}

# git_top <abs dir>: the folder git acts on from there, the nearest one at or above it holding a .git (the folder
# itself when there is none). A run from a subfolder changes the whole work tree, whatever the subfolder's status.
git_top() {
  local d
  case "$1" in *'$'* | *'`'* | *[\*\?\[]*) printf '%s' "$1"; return ;; esac
  case "$1" in /*) ;; *) printf '%s' "$1"; return ;; esac
  d=$(phys_any "$1")
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -e "$d/.git" ]; then printf '%s' "$d"; return; fi
    d=${d%/*}
  done
  printf '%s' "$1"
}

# judge_into <verb> <target dir or empty> <operands...>: a copy, move or link into an existing folder creates a
# file inside it, so each source's name in that folder is judged too. The destination is the target dir when
# given, else the last operand.
judge_into() {
  local verb=$1 dest=$2 s b n d i=0 last
  shift 2
  local srcs=("$@")
  n=${#srcs[@]}
  last=$n
  if [ -z "$dest" ]; then
    [ "$n" -ge 2 ] || return 0
    dest=${srcs[$((n - 1))]}
    last=$((n - 1))
  fi
  case "$dest" in
    '$HOME' | '${HOME}') d=$HOME_R ;;
    '$HOME/'*) d="$HOME_R/${dest#\$HOME/}" ;;
    '${HOME}/'*) d="$HOME_R/${dest#\$\{HOME\}/}" ;;
    "~") d=$HOME_R ;;
    "~/"*) d="$HOME_R/${dest#\~/}" ;;
    *'$'* | *'`'* | *[\*\?\[]*) return 0 ;;
    /*) d=$dest ;;
    *) [ -n "$CWD" ] || return 0; d="$CWD/$dest" ;;
  esac
  [ -d "$d" ] || return 0
  while [ "$i" -lt "$last" ]; do
    s=${srcs[$i]}
    b=${s##*/}
    case "$b" in "" | . | "..") ;; *) judge_target "$d/$b" "$verb" ;; esac
    i=$((i + 1))
  done
}

ANC=0
# judge_target <path> <what the call does>: deny when the path lands in a protected place.
judge_target() {
  local p="$1" verb="$2" c
  [ -n "$p" ] || return 0
  case "$p" in
    /dev/*) return 0 ;;
    '$HOME' | '${HOME}') p=$HOME_R ;;
    '$HOME/'*) p="$HOME_R/${p#\$HOME/}" ;;
    '${HOME}/'*) p="$HOME_R/${p#\$\{HOME\}/}" ;;
    "~") p=$HOME_R ;;
    "~/"*) p="$HOME_R/${p#\~/}" ;;
    "~"*) return 0 ;;
  esac
  case "$p" in
    *'$'* | *'`'*)
      p=${p%%[\$\`]*}
      case "$p" in */*) p=${p%/*}; [ -n "$p" ] || p=/ ;; *) return 0 ;; esac
      ;;
  esac
  case "$p" in
    /*) ;;
    *)
      [ -n "$CWD" ] || return 0
      p="$CWD/$p"
      ;;
  esac
  case "$p" in
    *[\*\?\[]*)
      p=${p%%[*?[]*}
      p=${p%/*}
      [ -n "$p" ] || p=/
      ;;
  esac
  while IFS= read -r c; do
    if prot_check "$c"; then
      deny "$verb would change $p, which is inside $PROT_WHAT. Make the change in a clone under /tmp and point the call at it; a person changes a protected place themselves."
    fi
    if [ "$ANC" = 1 ] && anc_check "$c"; then
      deny "$verb would remove or move $p, $PROT_WHAT. A person does that themselves."
    fi
  done < <(candidates "$p")
  return 0
}

# ---- Bash -------------------------------------------------------------------------------------------------------

# tokenise: the command on stdin as lines: Wword, S (a segment ends), O and C (a ( $( or ` group opens and closes),
# R (the next word is a redirect target), I (the next word is an input and is dropped). Quotes are removed, heredoc bodies are skipped.
tokenise() {
  awk 'BEGIN { RS = "\001" }
function flush() {
  if (inw) { gsub(/\n/, " ", w); print "W" w }
  w = ""; inw = 0; wq = 0
}
function skiphd(   e, line, l2) {
  while (i <= n) {
    e = index(substr(s, i), "\n")
    if (e == 0) { line = substr(s, i); i = n + 1 } else { line = substr(s, i, e - 1); i += e }
    l2 = line
    if (hdash) sub(/^\t+/, "", l2)
    if (l2 == hd) break
  }
  hd = ""
}
{
  s = $0; n = length(s); i = 1; w = ""; inw = 0; wq = 0
  sp = 1; st[1] = "N"; pd[1] = 0; hd = ""; hdash = 0
  while (i <= n) {
    c = substr(s, i, 1); top = st[sp]
    if (top == "D") {
      if (c == "\\") {
        nx = substr(s, i + 1, 1)
        if (nx == "\n") { i += 2; continue }
        if (nx ~ /[$`"\\]/) { w = w nx; i += 2; continue }
        w = w c; i++; continue
      }
      if (c == "\"") { sp--; i++; continue }
      if (c == "$" && substr(s, i + 1, 1) == "(") { flush(); print "S"; print "O"; sp++; st[sp] = "S"; pd[sp] = 0; i += 2; continue }
      if (c == "`") { flush(); print "S"; print "O"; sp++; st[sp] = "B"; i++; continue }
      w = w c; inw = 1; i++; continue
    }
    if (c == "\\") {
      nx = substr(s, i + 1, 1)
      if (nx == "\n") { i += 2; continue }
      w = w nx; inw = 1; wq = 1; i += 2; continue
    }
    if (c == "\047") {
      j = index(substr(s, i + 1), "\047")
      if (j == 0) { w = w substr(s, i + 1); i = n + 1 } else { w = w substr(s, i + 1, j - 1); i += j + 1 }
      inw = 1; wq = 1; continue
    }
    if (c == "\"") { sp++; st[sp] = "D"; inw = 1; wq = 1; i++; continue }
    if (c == "$") {
      nx = substr(s, i + 1, 1)
      if (nx == "(") { flush(); print "S"; print "O"; sp++; st[sp] = "S"; pd[sp] = 0; i += 2; continue }
      if (nx == "\047") {
        j = index(substr(s, i + 2), "\047")
        if (j == 0) { w = w substr(s, i + 2); i = n + 1 } else { w = w substr(s, i + 2, j - 1); i += j + 2 }
        inw = 1; wq = 1; continue
      }
      w = w c; inw = 1; i++; continue
    }
    if (c == "`") {
      flush(); print "S"
      if (top == "B") { sp--; print "C" } else { sp++; st[sp] = "B"; print "O" }
      i++; continue
    }
    if (c == " " || c == "\t") { flush(); i++; continue }
    if (c == "\n") { flush(); print "S"; i++; if (hd != "") skiphd(); continue }
    if (c == "#" && !inw) {
      j = index(substr(s, i), "\n")
      if (j == 0) i = n + 1; else i += j - 1
      continue
    }
    if (c == ";") { flush(); print "S"; i++; continue }
    if (c == "|") { flush(); print "S"; i++; if (substr(s, i, 1) == "|" || substr(s, i, 1) == "&") i++; continue }
    if (c == "&") {
      if (substr(s, i + 1, 1) == ">") { flush(); print "R"; i += 2; if (substr(s, i, 1) == ">") i++; continue }
      flush(); print "S"; i++; if (substr(s, i, 1) == "&") i++; continue
    }
    if (c == "(") { flush(); print "S"; print "O"; if (top == "S") pd[sp]++; i++; continue }
    if (c == ")") {
      flush(); print "S"; print "C"
      if (top == "S") { if (pd[sp] > 0) pd[sp]--; else sp-- }
      i++; continue
    }
    if (c == ">") {
      if (inw && !wq && w ~ /^[0-9]+$/) { w = ""; inw = 0 } else flush()
      i++; nx = substr(s, i, 1)
      if (nx == ">" || nx == "|") i++
      else if (nx == "&") {
        d = substr(s, i + 1, 1)
        if (d ~ /[0-9-]/) { i += 2; continue }
        i++
      }
      print "R"; continue
    }
    if (c == "<") {
      nx = substr(s, i + 1, 1)
      if (nx == "<") {
        if (substr(s, i + 2, 1) == "<") { flush(); i += 3; print "I"; continue }
        flush(); i += 2; hdash = 0
        if (substr(s, i, 1) == "-") { hdash = 1; i++ }
        while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
        dl = ""
        while (i <= n) {
          d = substr(s, i, 1)
          if (d == "\047" || d == "\"") { i++; continue }
          if (d ~ /[ \t\n;|&()<>]/) break
          if (d == "\\") { i++; continue }
          dl = dl d; i++
        }
        hd = dl; continue
      }
      if (nx == "(") { flush(); print "S"; print "O"; sp++; st[sp] = "S"; pd[sp] = 0; i += 2; continue }
      flush(); print "I"; i++
      if (substr(s, i, 1) == "&") i++
      continue
    }
    w = w c; inw = 1; i++
  }
  flush()
}'
}

# parse_args <option names that take a value> <args...>: NONOPT gets the operands, TDIR the -t/--target-directory
# value, OPTS the options seen.
NONOPT=()
TDIR=""
OPTS=" "
parse_args() {
  local vo=" $1 " a pend="" dd=0
  shift
  NONOPT=()
  TDIR=""
  OPTS=" "
  for a in "$@"; do
    if [ -n "$pend" ]; then
      if [ "$pend" = "-t" ] || [ "$pend" = "--target-directory" ]; then TDIR=$a; fi
      pend=""
      continue
    fi
    if [ "$dd" = 1 ]; then
      NONOPT[${#NONOPT[@]}]=$a
      continue
    fi
    case "$a" in
      --) dd=1 ;;
      --target-directory) pend=$a; OPTS="$OPTS$a " ;;
      --target-directory=*) TDIR=${a#*=}; OPTS="$OPTS$a " ;;
      -t?*) TDIR=${a#-t}; OPTS="$OPTS$a " ;;
      -*)
        OPTS="$OPTS$a "
        case "$vo" in *" $a "*) pend=$a ;; esac
        ;;
      *) NONOPT[${#NONOPT[@]}]=$a ;;
    esac
  done
}

set_cwd() {
  while :; do
    case "${1:-}" in
      -P | -L | -e | -@ | --) shift ;;
      *) break ;;
    esac
  done
  local a="${1:-}"
  case "$a" in
    "") CWD=$HOME_R ;;
    -) CWD="" ;;
    '$HOME' | '${HOME}') CWD=$HOME_R ;;
    '$HOME/'*) CWD="$HOME_R/${a#\$HOME/}" ;;
    '${HOME}/'*) CWD="$HOME_R/${a#\$\{HOME\}/}" ;;
    *'$'* | *'`'* | *[\*\?\[]*) CWD="" ;;
    "~") CWD=$HOME_R ;;
    "~/"*) CWD="$HOME_R/${a#\~/}" ;;
    "~"*) CWD="" ;;
    /*) CWD=$a ;;
    *) if [ -n "$CWD" ]; then CWD="$CWD/$a"; else CWD=""; fi ;;
  esac
  [ -n "$CWD" ] || return 0
  if [ -d "$CWD" ]; then CWD=$(cd -P -- "$CWD" 2>/dev/null && pwd -P) || CWD=$(lexnorm "$CWD"); else CWD=$(lexnorm "$CWD"); fi
}

# curl_bundle_O <-letters>: 0 when the bundle holds -O before any option that takes a value.
curl_bundle_O() {
  local b=${1#-} ch
  while [ -n "$b" ]; do
    ch=${b%"${b#?}"}
    b=${b#?}
    case "$ch" in
      O) return 0 ;;
      [AbcCdDeEFHKmoPQrTuUwxXyYz]) return 1 ;;
    esac
  done
  return 1
}

# git_is_write <subcommand> <args after it...>
git_is_write() {
  local sub="$1" a has_ff=0 has_rebase=0 has_read=0 pos=0
  shift
  case "$sub" in
    add | rm | mv | commit | checkout | switch | restore | reset | cherry-pick | revert | am | init | clone | update-ref | filter-branch | gc | prune | repack | maintenance | read-tree | checkout-index | write-tree | commit-tree | fast-import | merge-file | update-index | pack-refs | rerere | submodule)
      case "$sub" in submodule) case "${1:-}" in status | summary | foreach) return 1 ;; esac ;; esac
      return 0
      ;;
    merge | pull)
      for a in "$@"; do
        case "$a" in
          --ff-only) has_ff=1 ;;
          --rebase | -r | --rebase=* | --no-ff | --squash) has_rebase=1 ;;
        esac
      done
      [ "$has_ff" = 1 ] && [ "$has_rebase" = 0 ] && return 1
      return 0
      ;;
    rebase) return 0 ;;
    clean)
      for a in "$@"; do
        case "$a" in --dry-run | -n | -[a-zA-Z]*n*) return 1 ;; esac
      done
      return 0
      ;;
    symbolic-ref)
      for a in "$@"; do
        case "$a" in -d | --delete) return 0 ;; -*) ;; *) pos=$((pos + 1)) ;; esac
      done
      [ "$pos" -ge 2 ] && return 0
      return 1
      ;;
    hash-object)
      for a in "$@"; do
        case "$a" in -w) return 0 ;; esac
      done
      return 1
      ;;
    notes)
      case "${1:-list}" in add | append | edit | remove | merge | prune | copy) return 0 ;; esac
      return 1
      ;;
    apply)
      for a in "$@"; do
        case "$a" in --check | --stat | --numstat | --summary) return 1 ;; esac
      done
      return 0
      ;;
    bisect)
      case "${1:-}" in log | view | visualize | replay) return 1 ;; esac
      return 0
      ;;
    sparse-checkout)
      case "${1:-}" in list) return 1 ;; esac
      return 0
      ;;
    replace)
      [ "$#" -eq 0 ] && return 1
      for a in "$@"; do
        case "$a" in -l | --list) return 1 ;; esac
      done
      return 0
      ;;
    stash)
      case "${1:-push}" in list | show) return 1 ;; esac
      return 0
      ;;
    config)
      for a in "$@"; do
        case "$a" in --global | --system | --file | --file=* | -f) return 1 ;; esac
      done
      for a in "$@"; do
        case "$a" in
          --unset | --unset-all | --add | --replace-all | --edit | -e | --rename-section | --remove-section) return 0 ;;
          --get | --get-all | --get-regexp | --list | -l | --show-origin | --get-urlmatch | --default) has_read=1 ;;
          -*) ;;
          *) pos=$((pos + 1)) ;;
        esac
      done
      [ "$has_read" = 1 ] && return 1
      [ "$pos" -ge 2 ] && return 0
      return 1
      ;;
    tag)
      for a in "$@"; do
        case "$a" in
          -l | --list | -v | --verify | --contains | --no-contains | --points-at | --merged | --no-merged) return 1 ;;
          -d | --delete | -f | --force | -a | -s | -m | -F | -u) return 0 ;;
          -*) ;;
          *) pos=$((pos + 1)) ;;
        esac
      done
      [ "$pos" -ge 1 ] && return 0
      return 1
      ;;
    branch)
      for a in "$@"; do
        case "$a" in
          -l | --list | --show-current | -a | -r | -v | -vv | --merged | --no-merged | --contains | --no-contains | --points-at) has_read=1 ;;
          -d | -D | --delete | -m | -M | --move | -c | -C | --copy | -f | --force | -u | --set-upstream-to* | --unset-upstream | --edit-description) return 0 ;;
          -*) ;;
          *) pos=$((pos + 1)) ;;
        esac
      done
      [ "$pos" -ge 1 ] && [ "$has_read" = 0 ] && return 0
      return 1
      ;;
    remote)
      case "${1:-}" in add | remove | rm | rename | set-url | set-head | set-branches | prune) return 0 ;; esac
      return 1
      ;;
    worktree)
      case "${1:-}" in add | remove | move | prune | lock | unlock | repair) return 0 ;; esac
      return 1
      ;;
  esac
  return 1
}

# analyse <command words...>: judge one simple command.
analyse() {
  local verb a i n w idx start
  # Skip assignments, wrappers and shell keywords in front of the command.
  local wv wb
  while [ "$#" -gt 0 ]; do
    w=$1
    wb=${w##*/}
    case "$w" in
      [A-Za-z_]*=*) shift ;;
      *)
        case "$wb" in
          if | then | else | elif | do | while | until | '{' | '}' | '!' | builtin | nohup | setsid | caffeinate)
            shift
            ;;
          time)
            shift
            while :; do
              case "${1:-}" in
                -p | -v | -l | --portability | --verbose) shift ;;
                -o | -f | --output | --format) shift; shift ;;
                *) break ;;
              esac
            done
            ;;
          command)
            shift
            while [ "${1:-}" = -p ] || [ "${1:-}" = -- ]; do shift; done
            ;;
          exec)
            shift
            while :; do
              case "${1:-}" in
                -a) shift; shift ;;
                -c | -l | --) shift ;;
                *) break ;;
              esac
            done
            ;;
          env | sudo | nice | stdbuf | ionice | timeout)
            shift
            case "$wb" in
              env) wv=" -u -C -S --unset --chdir --split-string " ;;
              sudo) wv=" -u -g -h -p -C -r -t -U -D --user --group --host --prompt --chdir --role --type --other-user --close-from " ;;
              nice) wv=" -n --adjustment " ;;
              timeout) wv=" -s -k --signal --kill-after " ;;
              stdbuf) wv=" -i -o -e " ;;
              *) wv=" -c -n -p -t " ;;
            esac
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -*)
                  case "$wv" in *" $1 "*) shift ;; esac
                  shift
                  ;;
                [A-Za-z_]*=*) shift ;;
                *) break ;;
              esac
            done
            [ "$wb" = timeout ] && [ "$#" -gt 0 ] && shift
            ;;
          *) break ;;
        esac
        ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  verb=${1##*/}
  shift

  case "$verb" in
    cd | pushd)
      set_cwd "$@"
      ;;
    popd)
      CWD=""
      ;;
    rm | rmdir | unlink | shred)
      parse_args "" "$@"
      ANC=1
      for a in "${NONOPT[@]}"; do judge_target "$a" "$verb"; done
      ANC=0
      ;;
    touch)
      parse_args "-t -d -r" "$@"
      for a in "${NONOPT[@]}"; do judge_target "$a" "$verb"; done
      ;;
    mkdir)
      parse_args "-m" "$@"
      for a in "${NONOPT[@]}"; do judge_target "$a" "$verb"; done
      ;;
    tee)
      parse_args "" "$@"
      for a in "${NONOPT[@]}"; do judge_target "$a" "$verb"; done
      ;;
    chmod | chown | chgrp)
      local gotmode=0 dd=0
      for a in "$@"; do
        if [ "$dd" = 0 ]; then
          case "$a" in
            --) dd=1; continue ;;
            --reference=*) gotmode=1; continue ;;
          esac
          if [ "$gotmode" = 0 ] && [[ "$a" =~ ^-[rwxXstugo]+$ ]]; then gotmode=1; continue; fi
          case "$a" in -*) continue ;; esac
        fi
        if [ "$gotmode" = 0 ]; then gotmode=1; continue; fi
        judge_target "$a" "$verb"
      done
      ;;
    truncate)
      parse_args "-s -r --size --reference" "$@"
      for a in "${NONOPT[@]}"; do judge_target "$a" "$verb"; done
      ;;
    mv)
      parse_args "-t -S" "$@"
      ANC=1
      [ -n "$TDIR" ] && judge_target "$TDIR" "$verb"
      for a in "${NONOPT[@]}"; do judge_target "$a" "$verb"; done
      ANC=0
      judge_into "$verb" "$TDIR" "${NONOPT[@]}"
      ;;
    cp | install)
      parse_args "-t -m -o -g -S" "$@"
      if [ "$verb" = install ] && case "$OPTS" in *" -d "*) true ;; *) false ;; esac; then
        for a in "${NONOPT[@]}"; do judge_target "$a" "$verb"; done
      else
        [ -n "$TDIR" ] && judge_target "$TDIR" "$verb"
        n=${#NONOPT[@]}
        [ "$n" -ge 1 ] && judge_target "${NONOPT[$((n - 1))]}" "$verb"
        judge_into "$verb" "$TDIR" "${NONOPT[@]}"
      fi
      ;;
    ln)
      parse_args "-t -S" "$@"
      [ -n "$TDIR" ] && judge_target "$TDIR" "$verb"
      n=${#NONOPT[@]}
      if [ "$n" -ge 2 ]; then
        judge_target "${NONOPT[$((n - 1))]}" "$verb"
      elif [ "$n" -eq 1 ] && [ -n "$CWD" ]; then
        judge_target "$CWD/${NONOPT[0]##*/}" "$verb"
      fi
      judge_into "$verb" "$TDIR" "${NONOPT[@]}"
      ;;
    rsync)
      parse_args "-e --rsh -f --filter --exclude --include --exclude-from --include-from --files-from --rsync-path --log-file --backup-dir" "$@"
      n=${#NONOPT[@]}
      [ "$n" -ge 1 ] && judge_target "${NONOPT[$((n - 1))]}" "$verb"
      judge_into "$verb" "" "${NONOPT[@]}"
      ;;
    dd)
      for a in "$@"; do
        case "$a" in of=*) judge_target "${a#of=}" "$verb" ;; esac
      done
      ;;
    patch)
      local pd="" nextd=0
      for a in "$@"; do
        if [ "$nextd" = 1 ]; then pd=$a; nextd=0; continue; fi
        case "$a" in
          -d) nextd=1 ;;
          -d?*) pd=${a#-d} ;;
          --directory=*) pd=${a#*=} ;;
        esac
      done
      if [ -n "$pd" ]; then judge_target "$pd" "$verb"; elif [ -n "$CWD" ]; then judge_target "$CWD" "$verb"; fi
      ;;
    sed | perl)
      local inplace=0 hasexpr=0 takes=0 filt=()
      for a in "$@"; do
        if [ "$takes" = 1 ]; then takes=0; continue; fi
        if [ "$verb" = perl ]; then
          case "$a" in -[MmIdDVxX]*) filt[${#filt[@]}]=$a; continue ;; esac
        fi
        if [[ "$a" =~ ^-[a-zA-Z]*i ]] || [[ "$a" == --in-place* ]]; then inplace=1; fi
        case "$a" in
          -e | -f | --expression | --file) takes=1; hasexpr=1 ;;
          --expression=* | --file=*) hasexpr=1 ;;
          -[a-zA-Z]*e) takes=1; hasexpr=1 ;;
          *) filt[${#filt[@]}]=$a ;;
        esac
      done
      if [ "$inplace" = 1 ]; then
        parse_args "-l --line-length" "${filt[@]}"
        if [ "${#NONOPT[@]}" -gt 0 ] && [ -z "${NONOPT[0]}" ]; then NONOPT=("${NONOPT[@]:1}"); fi
        start=1
        [ "$hasexpr" = 1 ] && start=0
        idx=0
        for a in "${NONOPT[@]}"; do
          [ "$idx" -ge "$start" ] && judge_target "$a" "$verb -i"
          idx=$((idx + 1))
        done
      fi
      ;;
    tar)
      local extract=0 dest="" nextc=0
      i=0
      for a in "$@"; do
        if [ "$nextc" = 1 ]; then dest=$a; nextc=0; continue; fi
        case "$a" in
          --extract | --get) extract=1 ;;
          --directory=*) dest=${a#*=} ;;
          --directory | -C) nextc=1 ;;
          -C?*) dest=${a#-C} ;;
          --*) ;;
          -*) case "$a" in *x*) extract=1 ;; esac ;;
          *) if [ "$i" -eq 0 ]; then case "$a" in *x*) extract=1 ;; esac; fi ;;
        esac
        i=$((i + 1))
      done
      if [ "$extract" = 1 ]; then
        if [ -n "$dest" ]; then judge_target "$dest" "tar extract"; elif [ -n "$CWD" ]; then judge_target "$CWD" "tar extract"; fi
      fi
      ;;
    unzip)
      local dest="" nextd=0 ro=0
      for a in "$@"; do
        if [ "$nextd" = 1 ]; then dest=$a; nextd=0; continue; fi
        case "$a" in
          -d) nextd=1 ;;
          -d?*) dest=${a#-d} ;;
          -l | -p | -t | -Z | -v | -c) ro=1 ;;
        esac
      done
      if [ "$ro" = 0 ]; then
        if [ -n "$dest" ]; then judge_target "$dest" unzip; elif [ -n "$CWD" ]; then judge_target "$CWD" unzip; fi
      fi
      ;;
    curl)
      local nexto=0 remote=0 outdir=""
      for a in "$@"; do
        if [ "$nexto" = 2 ]; then outdir=$a; nexto=0; continue; fi
        if [ "$nexto" = 1 ]; then [ "$a" = - ] || judge_target "$a" "curl -o"; nexto=0; continue; fi
        case "$a" in
          -o | --output | -[a-zA-Z]*o) nexto=1 ;;
          -o?*) [ "${a#-o}" = - ] || judge_target "${a#-o}" "curl -o" ;;
          --output=*) [ "${a#*=}" = - ] || judge_target "${a#*=}" "curl -o" ;;
          -O | --remote-name) remote=1 ;;
          --output-dir) nexto=2 ;;
          --output-dir=*) outdir=${a#*=} ;;
          -[a-zA-Z]*) curl_bundle_O "$a" && remote=1 ;;
        esac
      done
      if [ "$remote" = 1 ]; then
        if [ -n "$outdir" ]; then judge_target "$outdir" "curl -O"; elif [ -n "$CWD" ]; then judge_target "$CWD" "curl -O"; fi
      fi
      ;;
    wget)
      local nexto=0 dest=""
      for a in "$@"; do
        if [ "$nexto" = 1 ]; then dest=$a; nexto=0; continue; fi
        case "$a" in
          -O | -P | -[a-zA-Z]*[OP] | --directory-prefix | --output-document) nexto=1 ;;
          -O?*) dest=${a#-O} ;;
          -P?*) dest=${a#-P} ;;
          -[a-zA-Z]*[OP]?*) dest=${a#*[OP]} ;;
          --output-document=*) dest=${a#*=} ;;
          --directory-prefix=*) dest=${a#*=} ;;
        esac
      done
      if [ "$dest" = - ]; then :; elif [ -n "$dest" ]; then judge_target "$dest" wget; elif [ -n "$CWD" ]; then judge_target "$CWD" wget; fi
      ;;
    find)
      local starts=() writes=0 inx=0 xsed=0
      for a in "$@"; do
        case "$a" in
          -H | -L | -P) ;;
          -* | '(' | ')' | '!') break ;;
          *) starts[${#starts[@]}]=$a ;;
        esac
      done
      for a in "$@"; do
        if [ "$inx" = 1 ]; then
          case "${a##*/}" in
            rm | rmdir | unlink | shred | touch | mkdir | chmod | chown | chgrp | truncate | tee | mv | cp | install | ln | rsync | dd | patch) writes=1 ;;
            sed | perl) xsed=1 ;;
          esac
          inx=0
          continue
        fi
        case "$a" in
          -delete | -fprint | -fprint0 | -fprintf | -fls) writes=1 ;;
          -exec | -execdir | -ok | -okdir) inx=1 ;;
          -i* | -[a-zA-Z]*i | --in-place*) [ "$xsed" = 1 ] && writes=1 ;;
        esac
      done
      if [ "$writes" = 1 ]; then
        if [ "${#starts[@]}" -eq 0 ]; then
          [ -n "$CWD" ] && judge_target "$CWD" "find (delete or exec)"
        else
          for a in "${starts[@]}"; do judge_target "$a" "find (delete or exec)"; done
        fi
      fi
      local nextf=0
      for a in "$@"; do
        if [ "$nextf" = 1 ]; then judge_target "$a" "find -fprint"; nextf=0; continue; fi
        case "$a" in -fprint | -fprint0 | -fprintf | -fls) nextf=1 ;; esac
      done
      ;;
    xargs)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -I | -n | -P | -L | -d | -E | -s | -a) shift; shift ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      [ "$#" -gt 0 ] && analyse "$@"
      ;;
    sh | bash | zsh | dash | ksh)
      local script="" takenext=0
      for a in "$@"; do
        if [ "$takenext" = 1 ]; then script=$a; break; fi
        case "$a" in -c | -[a-zA-Z]*c | -[a-zA-Z]*c[a-zA-Z]*) takenext=1 ;; esac
      done
      [ -n "$script" ] && read_nested "$script"
      ;;
    eval)
      [ "$#" -gt 0 ] && read_nested "$*"
      ;;
    git)
      analyse_git "$@"
      ;;
  esac
  return 0
}

NEST=0
read_nested() {
  local saved=$CWD
  [ "$NEST" -lt 3 ] || return 0
  NEST=$((NEST + 1))
  check_command "$1"
  NEST=$((NEST - 1))
  CWD=$saved
}

analyse_git() {
  local wt=$CWD gd="" a sub="" subargs=() next="" base
  for a in "$@"; do
    if [ -n "$next" ]; then
      case "$next" in
        -C)
          case "$a" in
            /*) wt=$a ;;
            *) if [ -n "$wt" ]; then wt="$wt/$a"; fi ;;
          esac
          ;;
        --work-tree) wt=$a ;;
        --git-dir) gd=$a ;;
      esac
      next=""
      continue
    fi
    if [ -n "$sub" ]; then
      subargs[${#subargs[@]}]=$a
      continue
    fi
    case "$a" in
      -C | --work-tree | --git-dir) next=$a ;;
      -C?*)
        a=${a#-C}
        case "$a" in /*) wt=$a ;; *) if [ -n "$wt" ]; then wt="$wt/$a"; fi ;; esac
        ;;
      --work-tree=*) wt=${a#*=} ;;
      --git-dir=*) gd=${a#*=} ;;
      -c | --exec-path | --namespace) next=skip ;;
      -*) ;;
      *) sub=$a ;;
    esac
  done
  [ -n "$sub" ] || return 0
  if [ "$sub" = config ]; then
    local cf=0
    for a in "${subargs[@]}"; do
      if [ "$cf" = 1 ]; then judge_target "$a" "git config"; cf=0; continue; fi
      case "$a" in
        -f | --file) cf=1 ;;
        --file=*) judge_target "${a#*=}" "git config" ;;
      esac
    done
  fi
  git_is_write "$sub" "${subargs[@]}" || return 0
  case "$sub" in
    clone)
      local pos=() s skipn=0
      for s in "${subargs[@]}"; do
        if [ "$skipn" = 1 ]; then skipn=0; continue; fi
        case "$s" in
          -b | --branch | --depth | -o | --origin | -c | --config | --filter | --reference | --separate-git-dir | --template | -j | --jobs | -u | --upload-pack) skipn=1 ;;
          -*) ;;
          *) pos[${#pos[@]}]=$s ;;
        esac
      done
      if [ "${#pos[@]}" -ge 2 ]; then
        judge_target "${pos[1]}" "git clone"
      elif [ "${#pos[@]}" -eq 1 ] && [ -n "$wt" ]; then
        base=${pos[0]##*/}
        base=${base%.git}
        judge_target "$wt/$base" "git clone"
      fi
      return 0
      ;;
    init)
      local pos=() s skipn=0
      for s in "${subargs[@]}"; do
        if [ "$skipn" = 1 ]; then skipn=0; continue; fi
        case "$s" in
          -b | --initial-branch | --template | --separate-git-dir | --object-format) skipn=1 ;;
          -*) ;;
          *) pos[${#pos[@]}]=$s ;;
        esac
      done
      if [ "${#pos[@]}" -ge 1 ]; then
        case "${pos[0]}" in /*) judge_target "${pos[0]}" "git init" ;; *) [ -n "$wt" ] && judge_target "$wt/${pos[0]}" "git init" ;; esac
      elif [ -n "$wt" ]; then
        judge_target "$wt" "git init"
      fi
      return 0
      ;;
  esac
  [ -n "$wt" ] && judge_target "$(git_top "$wt")" "git $sub"
  [ -n "$gd" ] && judge_target "$gd" "git $sub"
  return 0
}

check_command() {
  local cmd="$1" line w redir=0 tok n
  local SEG=() STK=()
  if [ "$NEST" -eq 0 ]; then
    tok=$(printf '%s' "$cmd" | LC_ALL=C tr -d '\011\012\040-\176\200-\377')
    [ -z "$tok" ] || deny "the command holds control characters the hook cannot read safely - blocked (fail-closed)."
  fi
  tok=$(printf '%s' "$cmd" | tokenise) || deny "could not read the command text - blocked (fail-closed)."
  while IFS= read -r line; do
    case "$line" in
      S)
        [ "${#SEG[@]}" -gt 0 ] && analyse "${SEG[@]}"
        SEG=()
        redir=0
        ;;
      O) STK[${#STK[@]}]=$CWD ;;
      C)
        n=${#STK[@]}
        if [ "$n" -gt 0 ]; then
          CWD=${STK[$((n - 1))]}
          unset "STK[$((n - 1))]"
        fi
        ;;
      R) redir=1 ;;
      I) redir=2 ;;
      W*)
        w=${line#W}
        if [ "$redir" = 1 ]; then
          judge_target "$w" "a redirect"
          redir=0
        elif [ "$redir" = 2 ]; then
          redir=0
        else
          SEG[${#SEG[@]}]=$w
        fi
        ;;
    esac
  done < <(printf '%s\n' "$tok")
  [ "${#SEG[@]}" -gt 0 ] && analyse "${SEG[@]}"
  return 0
}

# ---- git MCP ----------------------------------------------------------------------------------------------------

git_tool() {
  local name=${TOOL#mcp__git-mcp__} mode path
  mode=$(ti .mode)
  case "$name" in
    git_status | git_log | git_diff | git_show | git_blame | git_reflog | git_changelog_analyze | git_wrapup_instructions | git_fetch | git_push | git_set_working_dir | git_clear_working_dir) return 0 ;;
    git_branch) case "${mode:-list}" in list | show-current) return 0 ;; esac ;;
    git_tag) case "${mode:-list}" in list | verify) return 0 ;; esac ;;
    git_remote) case "${mode:-list}" in list | get-url) return 0 ;; esac ;;
    git_stash) case "${mode:-push}" in list) return 0 ;; esac ;;
    git_worktree) case "${mode:-list}" in list) return 0 ;; esac ;;
    git_clean) [ "$(ti .dryRun)" = "true" ] && return 0 ;;
    git_pull)
      [ "$(ti .fastForwardOnly)" = "true" ] && [ "$(ti .rebase)" != "true" ] && return 0
      ;;
  esac
  path=$(ti .path)
  [ -n "$path" ] || path=$SESSION_CWD
  case "$path" in
    /*) ;;
    *) path="$SESSION_CWD/$path" ;;
  esac
  case "$name" in
    git_clone | git_init) ;;
    *) path=$(git_top "$path") ;;
  esac
  judge_target "$path" "$name"
  if [ "$name" = git_worktree ]; then
    judge_target "$(ti .worktreePath)" "$name"
    judge_target "$(ti .newPath)" "$name"
  fi
  return 0
}

# ---- dispatch ---------------------------------------------------------------------------------------------------

find_session_root

case "$TOOL" in
  Edit | Write | MultiEdit) judge_target "$(ti .file_path)" "$TOOL" ;;
  NotebookEdit) judge_target "$(ti .notebook_path)" "$TOOL" ;;
  Bash | Monitor) check_command "$(ti .command)" ;;
  mcp__git-mcp__*) git_tool ;;
esac

exit 0
