# The shell-command parser the PreToolUse hooks share. Sourced after lib/hook-common.sh, never run. Bash 3.2.
#   . "${S%/*}/lib/shell-parse.sh" && [ "${SHELL_PARSE_LOADED:-}" = 1 ] || exit 1   (S is the hook's real path, as for
#   hook-common.sh; sourcing an empty or cut-short file succeeds, so the marker proves the whole file was read)
# It reads a Bash command's text the way the shell would split it and tells the hook what it found. It judges nothing.
#
# INTERFACE
#   The hook sets CWD to the folder the command starts in, defines two callbacks, then calls `shell_parse "<command>"`:
#     on_command <word>...    one simple command: the words with quotes removed, after leading assignments, wrappers
#                             (env, sudo, nice, timeout, time, command, exec, nohup and the like) and shell keywords
#                             (if, then, do, !, { and the like) are skipped; wrapper and shell names match in any case,
#                             as a case-insensitive file system runs SUDO. $1 is the verb as written. `cd`, `pushd`
#                             and `popd` are not passed on: the parser applies them to CWD. `bash -c STRING` and
#                             `eval STRING` (also su --command, env -S, trap) are read first (3 deep; a deeper string is
#                             not read), so their inner commands arrive before the command itself, which is passed on
#                             like any. A shell with no -c string reads its heredoc or here-string as a script.
#     on_redirect <target>    the target of an output redirect (> >> >| &> and N>). An input redirect or a here-string
#                             is dropped, a heredoc body is skipped.
#   CWD (global) is the tracked folder: the start folder, moved by cd/pushd/popd left to right, restored when a ( ),
#   $( ) or backtick group ends and after a nested string. It is empty when the folder is unknown (cd to a variable).
#   A hook that reads the words behind xargs hands them to `sp_xargs`, which skips xargs's own options and treats the
#   rest like a command of their own (`sp_command`, cd included: it moves CWD for the commands after it).
# Not read (a guard against mistakes, not a sandbox): a shell fed by a pipe (echo cmd | sh), a heredoc named before its
# shell (<<EOF bash) or opened after a quote that spans a newline, a here-string or body for a group ({ bash; } <<EOF),
# a string nested more than 3 deep, `watch -x`, `su --session-command`, an attached `-c'cmd'`, `env -iS`, `$( )` and
# backticks inside a heredoc body, and `\c` escapes in $'..'.
# It refuses what it cannot read safely with `deny` (hook-common.sh, which must be sourced first): a control byte in
# the text, or a tokenizer failure. HOME_R, the real path of $HOME, is set here; lexnorm is shared with the hook.
# Names it defines: HOME_R NEST SP_LC SP_STDIN lexnorm tokenise set_cwd sp_lc sp_command sp_watch sp_xargs read_nested shell_parse.

command -v deny >/dev/null 2>&1 || return 1

HOME_R=$(cd -P -- "$HOME" 2>/dev/null && pwd -P) || HOME_R=$HOME

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

# tokenise: the command on stdin as lines: Wword, S (a segment ends), O and C (a ( $( or ` group opens and closes),
# R (the next word is a redirect target), I (the next word is an input and is dropped), H (the next word is a here-string),
# Y then Zline... (the body of the heredoc that opens here, only when a shell name is in the segment). Quotes are removed, $'..' escapes decoded (\xHH
# and octal, printable ASCII only), heredoc bodies are skipped, `<<` and `>` inside $(( )) are plain characters.
tokenise() {
  awk 'BEGIN { RS = "\001" }
function sep() { print "S"; segsh = 0 }
function flush(   b) {
  if (inw) {
    gsub(/\n/, ";", w); print "W" w
    b = tolower(w); sub(/.*\//, "", b)
    if (b ~ /^(sh|bash|zsh|dash|ksh|su)$/) segsh = 1
  }
  w = ""; inw = 0; wq = 0
}
function hdscan(p, emit,   e, line, l2) {
  while (p <= n) {
    e = index(substr(s, p), "\n")
    if (e == 0) { line = substr(s, p); p = n + 1 } else { line = substr(s, p, e - 1); p += e }
    l2 = line
    if (hdash) sub(/^\t+/, "", l2)
    if (l2 == hd) break
    if (emit) print "Z" line
  }
  hdend = p
}
function ansic(   t, d, v, k, m, ch, cut) {
  t = ""; cut = 0
  while (i <= n) {
    d = substr(s, i, 1)
    if (d == "\047") { i++; return t }
    if (d != "\\") { if (!cut) t = t d; i++; continue }
    d = substr(s, i + 1, 1)
    v = -1; k = 0
    if (d == "t") { v = 9; k = 1 }
    else if (d == "n") { v = 10; k = 1 }
    else if (d == "x" || d == "u" || d == "U") {
      v = 0
      while (k < (d == "x" ? 2 : d == "u" ? 4 : 8) && (ch = substr(s, i + 2 + k, 1)) != "" && (m = index("0123456789abcdef", tolower(ch))) > 0) { v = v * 16 + m - 1; k++ }
      if (k == 0) v = -1
      k++
    } else if (d ~ /^[0-7]$/) {
      v = 0
      while (k < 3 && (ch = substr(s, i + 1 + k, 1)) ~ /^[0-7]$/) { v = v * 8 + ch; k++ }
      v = v % 256
    } else if (d == "\047" || d == "\\" || d == "\"") { if (!cut) t = t d; i += 2; continue }
    if (v == 0) { cut = 1; i += 1 + k; continue }  # a NUL ends the string in bash
    if ((v >= 32 && v <= 126) || v == 9 || v == 10) { if (!cut) t = t sprintf("%c", v); i += 1 + k; continue }
    if (!cut) t = t "\\" d
    i += 2
  }
  return t
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
      if (c == "$" && substr(s, i + 1, 1) == "(") { flush(); sep(); print "O"; sp++; st[sp] = (substr(s, i + 2, 1) == "(") ? "A" : "S"; pd[sp] = 0; i += 2; continue }
      if (c == "`") { flush(); sep(); print "O"; sp++; st[sp] = "B"; i++; continue }
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
      if (nx == "(") { flush(); sep(); print "O"; sp++; st[sp] = (substr(s, i + 2, 1) == "(") ? "A" : "S"; pd[sp] = 0; i += 2; continue }
      if (nx == "\047") { i += 2; w = w ansic(); inw = 1; wq = 1; continue }
      if (nx == "\"") { i++; continue }
      if (nx == "$") { w = w "$$"; inw = 1; i += 2; continue }
      w = w c; inw = 1; i++; continue
    }
    if (c == "`") {
      flush(); sep()
      if (top == "B") { sp--; print "C" } else { sp++; st[sp] = "B"; print "O" }
      i++; continue
    }
    if (c == " " || c == "\t") { flush(); i++; continue }
    if (c == "\n") { flush(); sep(); i++; if (hd != "") { hdscan(i); i = hdend; hd = "" }; continue }
    if (c == "#" && !inw) {
      j = index(substr(s, i), "\n")
      if (j == 0) i = n + 1; else i += j - 1
      continue
    }
    if (c == ";") { flush(); sep(); i++; continue }
    if (c == "|") { flush(); sep(); i++; if (substr(s, i, 1) == "|" || substr(s, i, 1) == "&") i++; continue }
    if (c == "&") {
      if (substr(s, i + 1, 1) == ">") { flush(); print "R"; i += 2; if (substr(s, i, 1) == ">") i++; continue }
      flush(); sep(); i++; if (substr(s, i, 1) == "&") i++; continue
    }
    if (c == "(") {
      flush(); sep(); print "O"
      if (top == "S" || top == "A") pd[sp]++
      if (substr(s, i + 1, 1) == "(") { sep(); print "O"; sp++; st[sp] = "A"; pd[sp] = 0; i++ }  # (( )): << is a shift
      i++; continue
    }
    if (c == ")") {
      flush(); sep(); print "C"
      if (top == "S" || top == "A") { if (pd[sp] > 0) pd[sp]--; else sp-- }
      i++; continue
    }
    if (c == "<" && top == "A" && substr(s, i + 1, 1) == "<" && substr(s, i + 2, 1) != "<") { w = w "<<"; inw = 1; i += 2; continue }
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
        if (substr(s, i + 2, 1) == "<") { flush(); i += 3; print "H"; continue }
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
        hd = dl
        if (hd != "" && segsh && (j = index(substr(s, i), "\n")) > 0) { print "Y"; hdscan(i + j, 1) }
        continue
      }
      if (nx == "(") { flush(); sep(); print "O"; sp++; st[sp] = "S"; pd[sp] = 0; i += 2; continue }
      flush(); print "I"; i++
      if (substr(s, i, 1) == "&") i++
      continue
    }
    w = w c; inw = 1; i++
  }
  flush()
}'
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

# sp_lc <word>: SP_LC = the word's last path component in lower case (a case-insensitive file system runs SUDO and Bash).
sp_lc() {
  SP_LC=${1##*/}
  case "$SP_LC" in *[[:upper:]]*) SP_LC=$(printf '%s' "$SP_LC" | tr '[:upper:]' '[:lower:]') ;; esac
}

# sp_command <command words...>: one simple command, from its first word (a wrapper, an assignment or the verb). A shell
# with no -c string reads its script from SP_STDIN, the heredoc or here-string shell_parse found for this command.
sp_command() {
  local verb vl a w wb wv sv script takenext stdin=${SP_STDIN:-}
  # Skip assignments, wrappers and shell keywords in front of the command.
  while [ "$#" -gt 0 ]; do
    w=$1
    case "$w" in
      [A-Za-z_]*=*) shift ;;
      *)
        sp_lc "$w"
        wb=$SP_LC
        case "$wb" in
          if | then | else | elif | do | while | until | '{' | '}' | '!' | builtin | noglob | nocorrect)
            shift
            ;;
          nohup | setsid)
            shift
            while :; do
              case "${1:-}" in -*) shift ;; *) break ;; esac
            done
            ;;
          function) shift; [ "$#" -gt 0 ] && shift ;;
          coproc) shift; [ "${2:-}" = '{' ] && shift ;;
          direnv) [ "${2:-}" = exec ] && [ "$#" -ge 3 ] || break; shift 3 ;;
          op)
            [ "${2:-}" = run ] || break
            shift 2
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --) shift; break ;;
                --env-file | --account | --session) shift; shift ;;
                -*) shift ;;
                *) break ;;
              esac
            done
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
          env | sudo | doas | nice | stdbuf | ionice | caffeinate | timeout | xcrun | arch)
            shift
            case "$wb" in
              env) wv=" -u -C --unset --chdir " ;;
              sudo) wv=" -u -g -h -p -C -r -t -U -D --user --group --host --prompt --chdir --role --type --other-user --close-from " ;;
              doas) wv=" -u -C -a " ;;
              caffeinate) wv=" -t -w " ;;
              xcrun) wv=" -sdk --sdk -toolchain --toolchain " ;;
              arch) wv=" -arch -e -d " ;;
              nice) wv=" -n --adjustment " ;;
              timeout) wv=" -s -k --signal --kill-after " ;;
              stdbuf) wv=" -i -o -e " ;;
              *) wv=" -c -n -p -t " ;;
            esac
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -*)
                  if [ "$wb" = env ]; then  # env -S STRING splits it and appends the rest: they are one command line
                    case "$1" in
                      -S | --split-string | -S?* | --split-string=*)
                        case "$1" in
                          -S | --split-string) sv=${2-}; [ "$#" -gt 1 ] && shift ;;
                          -S*) sv=${1#-S} ;;
                          *) sv=${1#--split-string=} ;;
                        esac
                        shift
                        read_nested "$sv $*"
                        set --
                        break
                        ;;
                    esac
                  fi
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
  w=$1
  verb=${w##*/}
  sp_lc "$w"
  vl=$SP_LC
  shift

  case "$verb" in
    cd | pushd)
      set_cwd "$@"
      return 0
      ;;
    popd)
      CWD=""
      return 0
      ;;
    eval)
      [ "$#" -gt 0 ] && read_nested "$*" keep
      ;;
    watch) sp_watch "$@" ;;
    trap)  # trap 'commands' SIGNAL: the first word that is not an option is the command string
      for a in "$@"; do
        case "$a" in -*) ;; *) read_nested "$a"; break ;; esac
      done
      ;;
  esac
  case "$vl" in
    sh | bash | zsh | dash | ksh | su)
      script="" takenext=0
      for a in "$@"; do
        if [ "$takenext" = 1 ]; then script=$a; break; fi
        case "$a" in
          -c | -[a-zA-Z]*c | -[a-zA-Z]*c[a-zA-Z]*) takenext=1 ;;
          --c*=*) script=${a#*=}; break ;;
          --c*) takenext=1 ;;
        esac
      done
      if [ -n "$script" ]; then read_nested "$script"; elif [ -n "$stdin" ]; then read_nested "$stdin"; fi
      ;;
  esac
  on_command "$w" "$@"
}

# sp_watch <words after watch>: watch joins its command words and runs them with sh -c.
sp_watch() {
  while :; do
    case "${1:-}" in
      -n | --interval) shift; shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] && read_nested "$*"
  return 0
}

# sp_xargs <words after xargs>: skip xargs's options (and the values of the ones that take a separate one), then the
# rest is a command of its own.
sp_xargs() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -I | -J | -n | -P | -L | -d | -E | -s | -a | -R | -S | --arg-file | --delimiter | --max-args | --max-procs | --max-lines | --max-chars | --process-slot-var) shift; shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] && sp_command "$@"
  return 0
}

# read_nested <string> [keep]: a bash -c or eval string, as a command of its own (3 deep; CWD is restored after, unless
# the string runs in the current shell, as eval's does: the caller passes `keep`).
NEST=0
read_nested() {
  local saved=$CWD
  [ "$NEST" -lt 3 ] || return 0
  NEST=$((NEST + 1))
  shell_parse "$1"
  NEST=$((NEST - 1))
  [ -n "${2:-}" ] || CWD=$saved
}

# shell_parse <command text>: read it, calling on_command and on_redirect as the interface above says.
shell_parse() {
  local cmd="$1" line w redir=0 tok n sin=""
  local SEG=() STK=()
  if [ "$NEST" -eq 0 ]; then
    declare -F on_command on_redirect >/dev/null 2>&1 || deny "the hook defines no on_command or on_redirect - blocked (fail-closed)."
    tok=$(printf '%s' "$cmd" | LC_ALL=C tr -d '\011\012\040-\176\200-\377')
    [ -z "$tok" ] || deny "the command holds control characters the hook cannot read safely - blocked (fail-closed)."
  fi
  tok=$(printf '%s' "$cmd" | tokenise) || deny "could not read the command text - blocked (fail-closed)."
  while IFS= read -r line; do
    case "$line" in
      S)
        SP_STDIN=$sin
        [ "${#SEG[@]}" -gt 0 ] && sp_command "${SEG[@]}"
        SEG=() sin=""
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
      H) redir=3 ;;
      Y) sin="" ;;
      Z*) sin=$sin${line#Z}$'\n' ;;
      W*)
        w=${line#W}
        if [ "$redir" = 1 ]; then
          on_redirect "$w"
          redir=0
        elif [ "$redir" = 2 ]; then
          redir=0
        elif [ "$redir" = 3 ]; then
          sin=$w redir=0
        else
          SEG[${#SEG[@]}]=$w
        fi
        ;;
    esac
  done < <(printf '%s\n' "$tok")
  SP_STDIN=$sin
  [ "${#SEG[@]}" -gt 0 ] && sp_command "${SEG[@]}"
  return 0
}

SHELL_PARSE_LOADED=1  # keep this the last line: the hook checks it to know the whole file was read
