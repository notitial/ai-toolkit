# The shell-command parser the PreToolUse hooks share. Sourced after lib/hook-common.sh, never run. Bash 3.2.
#   . "${S%/*}/lib/shell-parse.sh" || exit 1      (S is the hook's real path, as for hook-common.sh)
# It reads a Bash command's text the way the shell would split it and tells the hook what it found. It judges nothing.
#
# INTERFACE
#   The hook sets CWD to the folder the command starts in, defines two callbacks, then calls `shell_parse "<command>"`:
#     on_command <word>...    one simple command: the words with quotes removed, after leading assignments, wrappers
#                             (env, sudo, nice, timeout, time, command, exec, nohup and the like) and shell keywords
#                             (if, then, do, !, { and the like) are skipped. $1 is the verb as written. `cd`, `pushd`
#                             and `popd` are not passed on: the parser applies them to CWD. `bash -c STRING` and
#                             `eval STRING` are read first (3 deep; a deeper string is not read), so their inner
#                             commands arrive before the `bash` or `eval` command itself, which is passed on like any.
#     on_redirect <target>    the target of an output redirect (> >> >| &> and N>). An input redirect or a here-string
#                             is dropped, a heredoc body is skipped.
#   CWD (global) is the tracked folder: the start folder, moved by cd/pushd/popd left to right, restored when a ( ),
#   $( ) or backtick group ends and after a nested string. It is empty when the folder is unknown (cd to a variable).
#   A hook that reads the words behind a command (xargs) hands them to `sp_command`, which treats them like a command
#   of their own, cd included: it moves CWD for the commands after it.
# It refuses what it cannot read safely with `deny` (hook-common.sh, which must be sourced first): a control byte in
# the text, or a tokenizer failure. HOME_R, the real path of $HOME, is set here; lexnorm is shared with the hook.
# Names it defines: HOME_R NEST lexnorm tokenise set_cwd sp_command read_nested shell_parse.

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

# sp_command <command words...>: one simple command, from its first word (a wrapper, an assignment or the verb).
sp_command() {
  local verb a w wb wv script takenext
  # Skip assignments, wrappers and shell keywords in front of the command.
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
  w=$1
  verb=${w##*/}
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
    sh | bash | zsh | dash | ksh)
      script="" takenext=0
      for a in "$@"; do
        if [ "$takenext" = 1 ]; then script=$a; break; fi
        case "$a" in -c | -[a-zA-Z]*c | -[a-zA-Z]*c[a-zA-Z]*) takenext=1 ;; esac
      done
      [ -n "$script" ] && read_nested "$script"
      ;;
    eval)
      [ "$#" -gt 0 ] && read_nested "$*"
      ;;
  esac
  on_command "$w" "$@"
}

# read_nested <string>: a bash -c or eval string, as a command of its own (3 deep; CWD is restored after).
NEST=0
read_nested() {
  local saved=$CWD
  [ "$NEST" -lt 3 ] || return 0
  NEST=$((NEST + 1))
  shell_parse "$1"
  NEST=$((NEST - 1))
  CWD=$saved
}

# shell_parse <command text>: read it, calling on_command and on_redirect as the interface above says.
shell_parse() {
  local cmd="$1" line w redir=0 tok n
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
        [ "${#SEG[@]}" -gt 0 ] && sp_command "${SEG[@]}"
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
          on_redirect "$w"
          redir=0
        elif [ "$redir" = 2 ]; then
          redir=0
        else
          SEG[${#SEG[@]}]=$w
        fi
        ;;
    esac
  done < <(printf '%s\n' "$tok")
  [ "${#SEG[@]}" -gt 0 ] && sp_command "${SEG[@]}"
  return 0
}

SHELL_PARSE_LOADED=1  # keep this the last line: the hook checks it to know the whole file was read
