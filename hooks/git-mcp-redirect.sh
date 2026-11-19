#!/bin/bash
# Pre-tool-use hook (PreToolUse on Bash and Monitor, which runs its command in a shell): the one owner of Bash git
# (ADR 0010). It denies every Bash git command except read-only plumbing with no MCP equivalent (rev-parse, ls-files, config --get, ...), and sends the rest to the MCP git
# tools, whose guard (hooks/git-mcp-guard.sh) checks pushes and resets. A subcommand nobody listed is denied.
# lib/shell-parse.sh reads the command text, so git is found behind assignments, env, sudo, time, nohup, exec, xargs,
# shell keywords, redirects, `!`, ( ), $( ), backticks, find -exec and a nested `bash -c`/`sh -c`/`eval` string (3 deep).
# FAIL-CLOSED: without jq, on input that is not a JSON object, or without lib/hook-common.sh or lib/shell-parse.sh (or with
# either empty or cut short) it denies or exits 1, which the `|| exit 2` wiring turns into a block. Runs on bash 3.2.
#
# THE NET: every `git` word, in the raw text and among the words of the commands the parser read, must have been read as
# a git command, else deny (see the end of this file). So a shape the parser misreads or a wrapper it does not know is
# denied when git is named; the price is a deny for git named as plain text (grep git, which git, ls ~/git, a heredoc or
# message that says git). Residual: a git word the raw text does not show whole (g''it, $'g\x69t', a variable) behind
# a shape the parser misses passes. The word count stops such a word from padding the command count and hiding another.
#
# Known gaps (a guard against mistakes, not a sandbox; the net narrows these to shapes that do not name git as a word): a git name built at run time ($g push, an alias), a script or
# interpreter that runs git (python -c, make), a shell fed by a pipe (echo git push | sh), a wrapper the parser does
# not know (chronic, ...), ssh, a string nested more than 3 bash -c deep, a git binary called by its dashed name (git-push), and config that runs a program set through
# the environment or a config file (GIT_CONFIG_*) in front of help, cat-file or describe.
# A command that holds a substitution where the subcommand should be (git $(echo push)) has no readable subcommand and is
# denied; a quoted substitution as an option's value (git -C "$(pwd)" rev-parse) is just a word, an unquoted one (it
# can split into more options: git -C $(echo . -c x=y) help) is denied. git -c is denied too: it can set a config that
# runs a program.

HOOK=git-mcp-redirect
S=${BASH_SOURCE[0]}; [ -L "$S" ] && S=$(readlink "$S")
. "${S%/*}/lib/hook-common.sh" && [ "${HOOK_COMMON_LOADED:-}" = 1 ] || exit 1
. "${S%/*}/lib/shell-parse.sh" && [ "${SHELL_PARSE_LOADED:-}" = 1 ] || exit 1

printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || deny "could not read the tool call (not a JSON object) - blocked (fail-closed)."
COMMAND=$(field '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

# Read-only plumbing with no MCP equivalent, allowed as Bash: is_plumbing <subcommand> <args after it...>
is_plumbing() {
  local sub="$1" tok positionals=0
  shift
  case "$sub" in
    rev-parse|ls-files|describe|show-ref|var|help|check-ignore|cat-file|name-rev|merge-base|count-objects|shortlog) return 0 ;;
    --version|--help|--exec-path|--html-path) return 0 ;;
    config) case "${1:-}" in --get-all|--get|--list) return 0 ;; esac; return 1 ;;  # read forms only, with the read flag first
    symbolic-ref)
      # Reading HEAD only: read flags only (git accepts abbreviated and bundled options, so a delete flag is not looked
      # for), and a second ref would retarget it.
      for tok in "$@"; do
        case "$tok" in
          -q|--quiet|--short|--no-recurse) ;;
          -*) return 1 ;;
          *) positionals=$((positionals + 1)) ;;
        esac
      done
      [ "$positionals" -le 1 ] ;;
    *) return 1 ;;
  esac
}

unclassifiable() {
  deny "unclassifiable Bash git command" "This Bash git command cannot be safely classified (no readable subcommand: a command substitution, or a global option before the subcommand that this hook does not know). Use the MCP git tools (mcp__git-mcp__git_*) with an explicit path parameter instead."
}

# gitword <word>: the word is git, in any case (see the net at the end).
gitword() { case "$1" in [gG][iI][tT] | */[gG][iI][tT] | [-+=][gG][iI][tT]) return 0 ;; esac; return 1; }

# A git command: the global options before the subcommand are skipped, then the subcommand is judged. xargs hands the
# words behind it back to the parser as a command of their own.
on_command() {
  local verb w
  verb=$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')  # a case-insensitive file system runs GIT and XARGS too
  case "$verb" in
    git) ;;
    xargs) shift; sp_xargs "$@"; return 0 ;;
    find)  # the words after each -exec/-execdir/-ok/-okdir are a command of their own
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -exec|-execdir|-ok|-okdir)
            shift; sp_command "$@"
            while [ "$#" -gt 0 ] && [ "$1" != ';' ] && [ "$1" != '+' ]; do shift; done  # past its terminator: no second count
            ;;
        esac
        shift
      done
      return 0 ;;
    *) ;;
  esac
  # xargs and find hand their words on, and eval's are read as a string, so their own are not counted again
  [ "${1##*/}" = eval ] || for w in "$@"; do gitword "$w" && WORDS=$((WORDS + 1)); done
  [ "$verb" = git ] || return 0
  GITS=$((GITS + 1))
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C|--git-dir|--work-tree) case "${2:-}" in *'$(..)'*) unclassifiable ;; esac; shift; shift ;;
      --git-dir=*|--work-tree=*) case "$1" in *'$(..)'*) unclassifiable ;; esac; shift ;;
      --no-pager|--paginate|-P|-p) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || unclassifiable
  is_plumbing "$@" && return 0
  case "$1" in
    -*) unclassifiable ;;
    status|diff|log|show|blame|add|commit|push|pull|fetch|branch|checkout|merge|rebase|stash|tag|reset|remote|reflog|clean|worktree|clone|init)
      deny "redirect Bash git $1 -> mcp__git-mcp__git_$1" "Use mcp__git-mcp__git_$1 instead of Bash git $1. Always pass the path parameter on every call — the server has one global cwd and does not inherit the working directory." ;;
    cherry-pick)
      deny "redirect Bash git cherry-pick -> mcp__git-mcp__git_cherry_pick" "Use mcp__git-mcp__git_cherry_pick instead of Bash git cherry-pick. Always pass the path parameter on every call — the server has one global cwd and does not inherit the working directory." ;;
  esac
  deny "blocked Bash git $1 (no MCP equivalent)" "Bash git $1 is blocked and has no MCP equivalent — ask the user or use a mapped subcommand."
}
on_redirect() { :; }

CWD=""
GITS=0
WORDS=0
shell_parse "$COMMAND"

# The net: the parser can lose its place (<< inside a standalone (( )), a shell fed by a pipe) or not know a wrapper
# (chronic, a script of your own), and then it reports no git command. So every `git` word in the raw
# text (a whole token `git`, or a path ending in /git; .git, git-notes and gitk are not one) must have been read as a
# git command. More words than commands means one was not: deny. The words of the commands the parser read are counted
# too (WORDS, with the quotes removed): a split word such as g''it counts as a command, and without this count it would
# pad the total and hide a git the parser missed. It also denies a git word that is only text (grep git, which git,
# ls ~/git, echo "run git push", a heredoc naming git); the reason says what to use instead.
SHOWN=$(printf '%s' "$COMMAND" | LC_ALL=C tr -d "'\"\\\\" | LC_ALL=C tr -cs '[:alnum:]_./+-' '\n' | grep -ciE '(^|/|^[-+])git$')
# Inverted so that a count that cannot be read (no grep) denies instead of passing.
[ "$SHOWN" -le "$GITS" ] 2>/dev/null && [ "$WORDS" -le "$GITS" ] || deny "a git word the parser did not read as a git command" "This command names git ($SHOWN times in the text, $WORDS as words) but only $GITS of them were read as a git command, so it cannot be checked. Use the MCP git tools (mcp__git-mcp__git_*) for git (git --version passes); for a search use the Grep or Read tools; do not name git in other commands, heredocs or messages."
exit 0
