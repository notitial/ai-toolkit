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
#   - A git MCP git_push whose target remote resolves to a local path inside a protected place:
#     the push writes refs and objects there. A clone made from the live checkout's folder has that path as its
#     origin. A network URL is not judged.
#   Exceptions: <root>/.archive/** is writable; the git MCP git_pull with fastForwardOnly is allowed (it moves a
#   checkout to a reviewed commit and nothing else).
#   Bash git is not judged here: hooks/git-mcp-redirect.sh is its one owner and denies all of it but read-only plumbing.
#
# NEVER ASKS. Every decision is a deny or silence. It names no repository or tool of any project.
# FAIL-CLOSED without jq (as git-mcp-guard): the input cannot be read, so the call is denied. Without lib/hook-common.sh
# or lib/shell-parse.sh (or finds it empty or cut short) it exits 1, which the `|| exit 2` wiring turns into a block.
#
# WHAT COUNTS AS A WRITE (reads are never denied)
#   - Edit, Write, MultiEdit, NotebookEdit: the target's real path (symlinks followed, case-insensitive compare).
#   - git MCP tools: every tool except the read ones (status, log, diff, show, blame, reflog, fetch, working
#     directory tools, git_push (judged by its remote, below), and the list/show modes of branch, tag, remote, stash). The folder is the
#     call's `path` (git-mcp-guard denies a missing or relative one before this hook matters).
#   - Bash and Monitor, one simple rule (lib/shell-parse.sh reads the text, this file judges what it finds): the command is split into segments (; && || | & newline, and the insides of
#     $( ), backticks and ( )), `cd <dir>` is tracked left to right, and a segment is denied when it is a write
#     shape and a target resolves into a protected place. Write shapes: a > >> >| &> redirect; rm rmdir unlink shred
#     touch mkdir chmod chown chgrp truncate tee mv cp install ln rsync dd patch; sed -i and perl -i; tar x, unzip,
#     curl -o/-O, wget; find with -delete, -fprint or -exec of a write verb; xargs of those.
#     `bash -c STRING` and `eval STRING` are read recursively.
#     Relative operands resolve against the tracked folder; a glob is judged by its directory prefix.
#     A text that holds a substitution ($( ), backticks, <( ), >( ), =( ), anywhere, in a nested string too) is not trusted to the
#     parse: it is denied when it names a protected place (absolute, ~ or $HOME spelling) or runs in one with a write verb or
#     a redirect in it (sub_guard). That also denies a read of a protected file, or a heredoc that only names one, in the same text.
#
# KNOWN LIMITS (this is a guard against mistakes and the classifier is a second line, not a sandbox)
#   Not read: for a git MCP push, a remote changed earlier, submodule pushes, a bare word that is no configured
#   remote (read as a name, not a folder), a percent-encoded file:// URL, a repo with no readable config, an alias or a
#   remote helper
#   that maps to a local path; the program text of an interpreter (python -c, node -e, a script file), make/npm/other tools that
#   write on their own, paths built at run time ($VAR, $(...) output), a `cd` to a variable or glob (the folder is
#   then unknown and only absolute operands are judged), file names fed to xargs on stdin, $(...) inside a heredoc,
#   hard links, the target of a find -exec, programs that write on their own (archive creators, compressors,
#   formatters with an in-place flag), env -C, a < or > inside a standalone (( )) arithmetic command. A
#   recursive delete or move of a folder that contains a protected root is caught only for the session's own root
#   and for ~/.claude. A `~user`, `~+` or `~-` spelling is read as no path. A glob in a settings file name (settings.js?n) is
#   judged by its folder, not as the file. At most 80 words are judged in one call, and a text with a substitution and over
#   150 distinct path-like words is denied: each word costs about 40 ms and a hook past its 10 s timeout lets the call through.
#   On bash 3.2 a `< <(cmd)` leaks a descriptor, and the hook crashed (exit 133, the call goes through) after about 250 of them:
#   none are left in the guard or in lib/shell-parse.sh; a here-document does not leak (and a probe denies when one cannot be
#   written). A call whose parse takes over 6 s is denied (lib/shell-parse.sh sp_budget); a path over 1024 characters is denied.
#   Not read, single calls: a recursive copy or extract of a folder that holds a protected place into an ancestor of it
#   (cp -R /tmp/x/ ~ with /tmp/x/.claude/settings.json made earlier; rsync, tar -xf -C ~, unzip -d ~), brace expansion
#   (~/.claude{,}/settings.json), a leading $VAR other than $HOME ($PWD/hooks/x, ${HOME%/}/..), ~+, a bundled option with its
#   value attached (curl -so/path, tar -xC/path).
#
# Reads JSON from stdin. Returns a JSON deny decision or nothing; exit 0 always (but `exit 1` when a lib file is
# missing: the `|| exit 2` wiring blocks the call). No `set -e`: it would break the exit-0-always contract. Runs on bash 3.2.

MARKER=.protected-checkout

HOOK=protected-paths-guard
S=${BASH_SOURCE[0]}; [ -L "$S" ] && S=$(readlink "$S")
. "${S%/*}/lib/hook-common.sh" && [ "${HOOK_COMMON_LOADED:-}" = 1 ] || exit 1
. "${S%/*}/lib/shell-parse.sh" && [ "${SHELL_PARSE_LOADED:-}" = 1 ] || exit 1
TOOL=$(field '.tool_name // empty')

if [ -z "$TOOL" ]; then
  deny "could not read the tool call (empty or malformed stdin) - blocked (fail-closed)."
fi

ti() { field "(.tool_input${1}) // empty"; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---- paths -------------------------------------------------------------------------------------------------------

LHOME=$(lower "$HOME")
LHOME_R=$(lower "$HOME_R")

SESSION_CWD=$(field '.cwd // empty')
[ -n "$SESSION_CWD" ] || SESSION_CWD=$PWD
CWD=$SESSION_CWD

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
# Each word judged costs about 40 ms (several forks) and the hook has a 10 s timeout, past which the call goes through unchecked
# (bash 3.2 also crashed, with the same result, after about 250 executions of `< <(...)`). So the work is bounded here, for every
# caller: the 81st distinct word judged in one call is denied, never cut short. The same word in the same folder is judged once
# (mv and cp judge their operands twice, sub_guard and the parse judge the same words), and /dev/ targets cost nothing. The
# words seen are kept in arrays and compared whole: a string of them would let one word that holds the separator hide another.
# A path over 1024 characters is denied (a ${p//..} on a long one is quadratic), and the clock budget of lib/shell-parse.sh applies.
JUDGED=0
JC=()
JA=()
JP=()
judge_target() {
  local p="$1" verb="$2" c k
  [ -n "$p" ] || return 0
  case "$p" in /dev/*) return 0 ;; esac
  for ((k = 0; k < JUDGED; k++)); do  # a judgement with the ancestor check (ANC=1) covers one without
    if [ "${JP[k]}" = "$p" ] && [ "${JC[k]}" = "$CWD" ] && { [ "${JA[k]}" = 1 ] || [ "$ANC" != 1 ]; }; then return 0; fi
  done
  JC[JUDGED]=$CWD
  JA[JUDGED]=$ANC
  JP[JUDGED]=$p
  JUDGED=$((JUDGED + 1))
  sp_budget
  [ "${#p}" -le 1024 ] || deny "a path of more than 1024 characters cannot be read within the hook's time limit - blocked (fail-closed)."
  [ "$JUDGED" -le 80 ] || deny "this call names more than 80 distinct paths to judge, which cannot be done within the hook's time limit (a call past it would go through unchecked). Split it into several calls."
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
  done <<EOF
$(candidates "$p")
EOF
  return 0
}

# ---- Bash -------------------------------------------------------------------------------------------------------

on_redirect() { judge_target "$1" "a redirect"; }

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

# on_command <command words...>: judge one simple command. The parser has skipped assignments, wrappers and keywords,
# applied cd, pushd and popd to CWD, and read bash -c and eval strings.
on_command() {
  local verb a i n w idx start
  sp_lc "$1"  # a case-insensitive file system runs RM too
  verb=$SP_LC
  shift
  case "$verb" in
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
          sp_lc "$a"
          case "$SP_LC" in
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
    xargs) sp_xargs "$@" ;;
  esac
  return 0
}

# judge_push <repo dir> <remote name or url, may be empty>: a git MCP push whose target resolves to a local path inside
# a protected place writes refs and objects there, so it is judged like any other write. The target is the call's
# remote, else the repo's push remote (branch pushRemote, remote.pushDefault, branch remote, origin). A configured
# remote is read as its push URL (rewrites applied); anything else is taken as written. A network URL (scheme://,
# or host:path) is not judged. A relative path resolves against the repo dir.
judge_push() {
  local dir=$1 rem=$2 cur top
  # A folder that does not exist (yet) or is unknown has no config to read: only an explicit target can be judged.
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    push_target "" "" "$rem"
    return 0
  fi
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || top=$dir
  if [ -z "$rem" ]; then
    cur=$(git -C "$dir" symbolic-ref -q HEAD 2>/dev/null)
    cur=${cur#refs/heads/}
    [ -z "$cur" ] || rem=$(git -C "$dir" config --get "branch.$cur.pushRemote" 2>/dev/null)
    [ -n "$rem" ] || rem=$(git -C "$dir" config --get remote.pushDefault 2>/dev/null)
    [ -z "$cur" ] || [ -n "$rem" ] || rem=$(git -C "$dir" config --get "branch.$cur.remote" 2>/dev/null)
    [ -n "$rem" ] || rem=origin
  fi
  push_target "$dir" "$top" "$rem"
}

# push_target <repo dir> <work tree top> <remote name or url, may be empty>: judge one push target.
push_target() {
  local dir=$1 top=$2 rem=$3 urls url p
  [ -n "$rem" ] || return 0
  if [ -z "$dir" ] || ! urls=$(git -C "$dir" remote get-url --push --all -- "$rem" 2>/dev/null); then
    case "$rem" in */* | . | ..) ;; *) return 0 ;; esac
    urls=$rem
  fi
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    case "$url" in
      file://localhost/*) p=${url#file://localhost} ;;
      file://*) p=${url#file://} ;;
      *://*) continue ;;
      /* | '~' | '~/'* | '$HOME' | '$HOME/'* | '${HOME}' | '${HOME}/'*) p=$url ;;
      *)
        case "${url%%/*}" in *:*) continue ;; esac
        [ -n "$top" ] || continue
        p="$top/$url"
        ;;
    esac
    judge_target "$p" "git push"
  done <<EOF
$urls
EOF
}

# ---- git MCP ----------------------------------------------------------------------------------------------------

git_tool() {
  local name=${TOOL#mcp__git-mcp__} mode path
  mode=$(ti .mode)
  case "$name" in
    git_status | git_log | git_diff | git_show | git_blame | git_reflog | git_changelog_analyze | git_wrapup_instructions | git_fetch | git_set_working_dir | git_clear_working_dir) return 0 ;;
    git_branch) case "${mode:-list}" in list | show-current) return 0 ;; esac ;;
    git_tag) case "${mode:-list}" in list | verify) return 0 ;; esac ;;
    git_remote) case "${mode:-list}" in list | get-url) return 0 ;; esac ;;
    git_stash) case "${mode:-push}" in list) return 0 ;; esac ;;
    git_clean) [ "$(ti .dryRun)" = "true" ] && return 0 ;;
    git_pull)
      [ "$(ti .fastForwardOnly)" = "true" ] && [ "$(ti .rebase)" != "true" ] && return 0
      ;;
  esac
  path=$(ti .path)
  case "$path" in
    /*) ;;
    *) path="$SESSION_CWD/$path" ;;
  esac
  if [ "$name" = git_push ]; then
    judge_push "$path" "$(ti .remote)"
    return 0
  fi
  case "$name" in
    git_clone | git_init) ;;
    *) path=$(git_top "$path") ;;
  esac
  judge_target "$path" "$name"
  return 0
}

# ---- substitutions ----------------------------------------------------------------------------------------------

# sub_guard <command text>: a substitution ($( ), backticks, <( ), >( ), =( ), in a string or a nested -c string too) runs a
# command the text does not show, and where its group ends is a guess the parser can get wrong on text bash itself reads
# differently (a `)` in a case pattern, a quote or paren inside backticks). So the parse is not trusted around one: the text
# is denied when it could touch a protected place, whatever the parser made of its words. The text is read with quotes,
# backslashes and line continuations dropped first (`$''(`, `$\<newline>(` still open a substitution). Could touch, read
# fail-closed: a word names a protected place in a spelling judge_target resolves (absolute, ~, $HOME, also behind a short
# option as in -C/dir, or relative with `..`), or the session runs in a protected folder (or in ~/.claude) and the text holds
# a write verb or a redirect. With a write verb in the text every word is judged, as a path from the session folder and as
# something removed or moved (`rm -rf ~/.claude`, `cp f ~/.claude/` after a substitution). Cost: such a text that only
# reads a protected file, a heredoc or string that only names one or a word that is a verb name ("find the cause"), a
# redirect sign anywhere (`->`, `$((a>b))`), a write verb from a protected folder, and a write verb next to a bare `~` or `/`
# are denied too. A quoted path with spaces is judged too (a quoted string that holds a space and starts like a path); a bare
# word is judged when a write verb is in the text and it names something in the session folder (`cd live`). A text with more
# than 150 distinct path-like words is denied (the scan itself slows down with them), and every word judged counts toward the
# limit in judge_target. Not read: ${ cmd; }, a path assembled at run time, a bare relative
# word without a write verb, and a `cd` chain from an unprotected folder when the verb itself comes from a substitution
# (`$(which rm) -rf hooks`).
sub_guard() {
  local t=$1 rd w c s r wr=0 inprot=0 pw=() bw=() seen="|" quoted=0 big=0
  case "$t" in *'('* | *'`'*) ;; *) return 0 ;; esac  # every opener has a ( or a backtick
  case "$t" in *[\"\'\\]*) quoted=1 ;; esac
  # One awk pass drops line continuations and empty quote pairs and bares `$'` and `$"`, then tr drops the quotes and backslashes. Not
  # ${t//...}: bash 3.2 is quadratic in the matches (35 s for the bracket class on 9 KB, 11 s for 900 `2>&1`).
  t=$(printf '%s' "$t" | awk 'BEGIN { RS = "\001"; ORS = "" } { gsub(/\\\n/, ""); gsub(/\047\047/, ""); gsub(/""/, ""); gsub(/\$\047/, "\047"); gsub(/\$"/, "\""); print }' | tr -d "\"'\\\\")
  case "$t" in *'$('* | *'`'* | *'<('* | *'>('* | *'=('*) ;; *) return 0 ;; esac
  rd=$(printf '%s' "$t" | sed -E 's#>&[0-9-]##g; s#>{1,2} ?/dev/null##g')
  case "$rd" in *'>'*) wr=1 ;; esac
  t=$(printf '%s' "$t" | sed 's#\$(# #g')  # `rm$(x)` and `$(x)rm` still show their verb
  if [ "$quoted" = 1 ]; then  # a quoted path may hold spaces: judge each quoted string that holds one and starts like a path
    while IFS= read -r s; do
      s=${s#?}
      s=${s%?}
      case "$s" in /* | '~'* | '$HOME'* | '${HOME}'*) pw[${#pw[@]}]=$s ;; esac
    done <<EOF
$(printf '%s' "$1" | grep -oE "\"[/~\$][^\"]* [^\"]*\"|'[/~\$][^']* [^']*'")
EOF
  fi
  t=$(printf '%s' "$t" | tr ' \t;|&<>()`=:' '\n')
  while IFS= read -r w; do
    case "$w" in
      -[A-Za-z]/* | -[A-Za-z]'~'* | -[A-Za-z]'$HOME'* | -[A-Za-z]'${HOME}'*) w=${w#-?} ;;
      -* | "") continue ;;
    esac
    sp_lc "$w"
    case "$SP_LC" in
      rm | rmdir | unlink | shred | touch | mkdir | mkfifo | mknod | chmod | chown | chgrp | truncate | tee | mv | cp | install | ln | rsync | dd | patch | sed | perl | tar | unzip | curl | wget | find | xargs) wr=1 ;;
    esac
    case "$w" in  # a word with a / or .., or in ~ or $HOME spelling, is judged; a bare word only when it is a name in the session folder (a cd target)
      / | '~') continue ;;
      */* | '~'* | '$HOME'* | '${HOME}'* | ..) ;;
      *) [ -e "$SESSION_CWD/$w" ] && bw[${#bw[@]}]=$w; continue ;;
    esac
    case "$seen" in *"|$w|"*) continue ;; esac  # (only path-like words: bare ones in the string made the scan quadratic)
    seen="$seen$w|"
    [ "${#pw[@]}" -lt 150 ] || { big=1; break; }  # the scan itself slows with the words it keeps (5000 paths: 11 s)
    pw[${#pw[@]}]=$w
  done <<EOF
$t
EOF
  if [ "$wr" = 1 ]; then  # a protected session folder denies, so the words need no further look
    c=$(phys_any "$SESSION_CWD")
    [ "$(lower "$c")" = "$LHOME_R/.claude" ] && deny "a command that holds a substitution and writes (or may) would run in ~/.claude, and the substitution is not read reliably. Run it from a clone under /tmp, or put the substitution in its own call and write with plain paths."
    while IFS= read -r c; do
      prot_check "$c" && inprot=1
    done <<EOF
$(candidates "$c")
EOF
    [ "$inprot" = 1 ] && deny "a command that holds a substitution and writes (or may) would run in $PROT_WHAT, and the substitution is not read reliably. Run it from a clone under /tmp, or put the substitution in its own call and write with plain paths."
  fi
  [ "$big" = 1 ] && deny "a command that holds a substitution and more than 150 path-like words is too long to read reliably. Split it, or keep the substitution out of the call that writes."
  for w in "${pw[@]}"; do
    case "$w" in
      //*[!/]*) ;;
      //*) continue ;;
    esac
    ANC=0
    case "$w" in
      /* | '~'* | '$HOME'* | '${HOME}'*) ANC=$wr ;;  # with a write verb it may also be removed or moved (rm -rf ~/.claude)
      .. | ../* | */.. | */../*) ;;
      *) [ "$wr" = 1 ] || continue ;;  # a relative word is judged only with a write verb in the text
    esac
    judge_target "$w" "a command that holds a substitution (not read reliably)"
    ANC=0
  done
  if [ "$wr" = 1 ]; then
    for w in "${bw[@]}"; do judge_target "$w" "a command that holds a substitution and a write verb (not read reliably)"; done
  fi
  return 0
}

# ---- dispatch ---------------------------------------------------------------------------------------------------

find_session_root
sp_probe

case "$TOOL" in
  Edit | Write | MultiEdit) judge_target "$(ti .file_path)" "$TOOL" ;;
  NotebookEdit) judge_target "$(ti .notebook_path)" "$TOOL" ;;
  Bash | Monitor) CMDTEXT=$(ti .command); sub_guard "$CMDTEXT"; shell_parse "$CMDTEXT" ;;
  mcp__git-mcp__*) git_tool ;;
esac

exit 0
