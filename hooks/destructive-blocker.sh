#!/bin/bash
# Pre-tool-use hook: blocks destructive Bash commands.
# Configured in ~/.claude/settings.json for PreToolUse on Bash.
#
# Hard matches (rm -rf, SQL drops, disk writes, ...) deny. Bash git is not judged here: hooks/git-mcp-redirect.sh
# owns it and denies all of it but read-only plumbing. Two soft matches, a forced delete
# (`rm -f /abs`) and a truncation (`: > /abs`) of an absolute path, and the bulk deletes (`find -delete`,
# `find -exec rm`, `xargs rm`) ask the user in an interactive session (CLAUDE_CODE_ENTRYPOINT cli, claude-vscode
# or claude-desktop). Every other entrypoint, a headless `claude -p` (sdk-cli) included, gets the deny, since
# nobody may be there to answer an ask. Hard matches are checked first, so a soft one never hides a hard one.
#
# This catches the commands an agent types by mistake, not a command built to slip past it. Decisions are
# recorded through the sibling audit-logger.sh when it is present. Reads JSON from stdin; exit 0 always (`exit 1` if
# lib/hook-common.sh or lib/shell-parse.sh is missing or cut short, which the `|| exit 2` wiring blocks). A control byte in
# the command text, or a shape the parser cannot read exactly (lib/shell-parse.sh lists them), is denied. Every heredoc body is read as a script (`ssh host <<EOF` and the like).

HOOK=destructive-blocker
S=${BASH_SOURCE[0]}; [ -L "$S" ] && S=$(readlink "$S")
. "${S%/*}/lib/hook-common.sh" && [ "${HOOK_COMMON_LOADED:-}" = 1 ] || exit 1
. "${S%/*}/lib/shell-parse.sh" && [ "${SHELL_PARSE_LOADED:-}" = 1 ] || exit 1

case $INPUT in
  *[![:space:]]*)
    printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || { decide deny "destructive-blocker: unreadable hook input — Bash command blocked (fail-closed)."; exit 0; } ;;
esac

COMMAND=$(field '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

blocked() { deny "$1" "Destructive command blocked: $1. If this is intentional, ask the user to run it manually."; }

# grep's own status, not the pipeline's: grep -q may quit early and leave printf a broken pipe.
matches() { printf '%s\n' "$2" | grep -qiE -- "$1"; return "${PIPESTATUS[1]}"; }

# ask_or_deny <short reason> <message>: ask in an interactive session; every other entrypoint gets the deny,
# since nobody may be there to answer an ask.
ask_or_deny() {
  # The user decides in the permission prompt, if one can be shown.
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    cli | claude-vscode | claude-desktop)
      decide ask "$2"
      audit_deny "$1" ask
      exit 0 ;;
  esac
  blocked "$1"
}

PATTERNS=(
  'rm[[:space:]]+(-rf|-fr)[[:space:]]|Recursive forced deletion'
  'DROP[[:space:]]+TABLE|SQL table drop'
  'DROP[[:space:]]+DATABASE|SQL database drop'
  'TRUNCATE[[:space:]]+TABLE|SQL table truncate'
  '(^|[^[:alnum:]_-])dd[[:space:]]([^;&|]*[[:space:]])?of=/dev/(sd|hd|vd|xvd|nvme|mmcblk|disk|rdisk|loop|md|dm-|mapper/)|Disk overwrite'
  'mkfs\.|Filesystem format'
  'chmod[[:space:]]+-R[[:space:]]+777|Recursive world-writable permissions'
)
SOFT_PATTERNS=(
  'rm[[:space:]]+(-f)[[:space:]]+/|Forced deletion from root'
  ':[[:space:]]*>[[:space:]]*/|Truncate system file'
)

# Text that only names a command is not running it. The patterns are checked with two things blanked: the
# first quoted pattern after grep, egrep, fgrep, rg, ag or ack (and its options), and a quoted -m/--message value
# (a one-line commit message). A double-quoted string holding $ or a backtick is never blanked: it may run a command.
# So `rg -n "DROP TABLE" db/` passes, while `psql -c "DROP TABLE users"` is still denied. A real rm in the same
# command is still seen here, and by the segment checks below.
PATTEXT=$(printf '%s\n' "$COMMAND" | sed -E \
  -e "s/(^|[;&|(\`[:space:]])(grep|egrep|fgrep|rg|ag|ack)(([[:space:]]+-[^[:space:]\"']+)*)[[:space:]]+(\"[^\"\$\`]*\"|'[^']*')/\1\2\3 Q/g" \
  -e "s/(^|[[:space:]])(-m|--message)([[:space:]]+|=)(\"[^\"\$\`]*\"|'[^']*')/\1\2 Q/g")
for entry in "${PATTERNS[@]}"; do
  matches "${entry%|*}" "$PATTEXT" && blocked "${entry##*|}"
done
# A DELETE with no WHERE in the same statement (up to a ; or a quote after the table name) empties the table,
# whatever follows it. The DELETE must start a statement (a line, a quoted string, or after ; or a parenthesis),
# so prose such as "rows delete from the cache" is no SQL. The table name may be quoted ("User").
while IFS= read -r stmt; do
  [ -n "$stmt" ] && ! matches '[[:space:]]WHERE([[:space:]]|$)' "$stmt" && blocked "SQL delete without WHERE clause"
done < <(printf '%s\n' "$PATTEXT" | grep -oiE "(^|[\"';(])[[:space:]]*DELETE[[:space:]]+FROM[[:space:]]+[^[:space:];]+[^;\"']*" || true)

check_rm() {  # check_rm <words after rm>: -r and -f in any order
  local w r=0 f=0
  for w in "$@"; do
    case "$w" in
      --recursive) r=1 ;;
      --force) f=1 ;;
      --*) ;;
      -*) case "$w" in *[rR]*) r=1 ;; esac; case "$w" in *f*) f=1 ;; esac ;;
    esac
  done
  [ "$r$f" = 11 ] && blocked "Recursive forced deletion (flags in any order)"
}

# lib/shell-parse.sh reads the command text and hands each simple command, quotes removed and wrappers (sudo, env,
# timeout, ...) and shell keywords skipped, to on_command: a `sh -c` or `eval` string and a $( ) are read too.
# Hard checks deny here; the bulk deletes (xargs rm, find -delete, find -exec rm) set ASK_CLASS for the ask below.
ASK_CLASS="" FROM=""
on_command() {
  local verb
  sp_lc "${1##*/}"; verb=$SP_LC
  shift
  case "$verb" in
    rm) check_rm "$@"; [ -z "$FROM" ] || ASK_CLASS=$FROM ;;
    xargs) FROM="xargs rm"; sp_xargs "$@"; FROM="" ;;
    find)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -delete) ASK_CLASS="find with -delete or -exec rm" ;;
          -exec | -execdir | -ok | -okdir) FROM="find with -delete or -exec rm"; sp_command "${@:2}"; FROM="" ;;
        esac
        shift
      done ;;
    *)  # a shell further along (docker exec c sh -c 'rm -rf x') runs its string too
      while [ "$#" -gt 0 ]; do
        case "${1##*/}" in [Ss][Hh] | [Bb][Aa][Ss][Hh] | [Zz][Ss][Hh] | [Dd][Aa][Ss][Hh] | [Kk][Ss][Hh] | [Ss][Uu]) sp_command "$@"; break ;; esac
        shift
      done ;;
  esac
}
on_redirect() { :; }
SP_ALL_HEREDOCS=1  # a heredoc body may reach a shell the parser cannot see (ssh host <<EOF, sudo -s, source /dev/stdin)
shell_parse "$COMMAND"
# A python one-liner or heredoc that deletes files is rm by another name.
if matches 'python[0-9.]*([[:space:]]+-[A-Za-z]*)*[[:space:]]+(-[A-Za-z]*c|<<)' "$COMMAND" &&
  matches 'rmtree|os\.(remove|unlink|rmdir|removedirs)|\.unlink\(' "$COMMAND"; then
  blocked "Python file deletion"
fi

# No hard match. The soft entries: forced delete or truncation of an absolute path.
for entry in "${SOFT_PATTERNS[@]}"; do
  matches "${entry%|*}" "$COMMAND" || continue
  ask_or_deny "${entry##*|}" "Destructive command: ${entry##*|}. It deletes or empties a file by absolute path. Approve only if you meant to."
done

# Bulk deletes: the same prompt, the same deny where nobody can answer.
[ -n "$ASK_CLASS" ] && ask_or_deny "$ASK_CLASS" "Destructive command: $ASK_CLASS. It deletes files in bulk. The user must run it or approve it."
exit 0
