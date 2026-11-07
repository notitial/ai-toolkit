# Account launchers for Claude Code and VS Code, on macOS only (they read the Keychain and use VS Code's macOS paths).
# ~/.claude/tools/shell-init.zsh loads this file beside ait.zsh. The stored login in ~/.claude stays the default: `claude`
# and `code` are not touched. An alternate account runs on a token or a key that lives in the Keychain and goes into the
# environment of that one command (and so of what it starts), never of your shell. There is never a second config dir.
#
# ~/.claude/accounts.conf, one account per line (`#` starts a comment):
#   <name> <kind> <keychain-service>
#   work   oauth  example-work-oauth     # kind oauth: a subscription token from `claude setup-token`
#   batch  apikey example-batch-api      # kind apikey: an Anthropic API key
# For each valid line two commands exist in new shells:
#   claude-<name> [args]   runs `claude [args]` with CLAUDE_CODE_OAUTH_TOKEN (oauth) or ANTHROPIC_API_KEY (apikey) set
#   code-<name> [args]     the same for `code --user-data-dir ~/.vscode-accounts/<name> [args]`: its own VS Code instance
#                          beside your main one. Its User/ folder links to the main settings.json, keybindings.json,
#                          snippets/ and mcp.json (these are links: a change made in the account's window goes through
#                          them into the main folder, and the MCP servers of mcp.json start with the account's secret
#                          in their environment; the launcher itself writes only under ~/.vscode-accounts/<name>);
#                          extensions are shared, since VS Code keeps them in ~/.vscode/extensions whatever the data dir.
# Arguments pass straight through. The secret is read in a subshell, goes into that one variable and then `exec`
# replaces the subshell: your shell never holds it and nothing prints it. The program and everything it starts (the
# Bash tool, hooks, MCP servers, extensions) inherit it, as with any environment variable. Only that variable is set:
# an ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN already exported in your shell is inherited too and may outrank it, so
# keep both out of the shell these run in. A command, function or alias that already has the name is never replaced:
# that one launcher is skipped, with the reason on stderr.
# The file is read by `bash tools/install-copies.sh accounts` (the one parser: never sourced, each field checked, a
# bad line reported and skipped, a file you do not own or others can write refused). `ait-status` shows the file and
# whether each Keychain item exists. Add or remove an account: .claude/skills/add-account/SKILL.md in the toolkit.
# Tests: bash tools/test-ait.sh

_ait_acct_dir=${${(%):-%x}:A:h}
typeset -gA _ait_acct_kind _ait_acct_svc _ait_acct_own

# _ait_acct_run <account> <program> [args...]: the program with the account's secret in its one variable.
_ait_acct_run() {
  emulate -L zsh
  setopt no_xtrace no_verbose no_allexport
  local name=$1 prog=$2 var svc=${_ait_acct_svc[$1]-}
  shift 2
  case ${_ait_acct_kind[$name]-} in
    oauth)  var=CLAUDE_CODE_OAUTH_TOKEN ;;
    apikey) var=ANTHROPIC_API_KEY ;;
    *) print -u2 "accounts: unknown account $name (open a new shell after editing accounts.conf)"; return 2 ;;
  esac
  [[ -n $svc ]] || { print -u2 "accounts: no Keychain service for $name"; return 2 }
  command -v security >/dev/null 2>&1 || { print -u2 "accounts: no security tool (the launchers need the macOS Keychain)"; return 1 }
  (
    local secret
    secret=$(security find-generic-password -s "$svc" -w 2>/dev/null) && [[ -n $secret ]] || {
      print -u2 "accounts: no usable Keychain item for $name (service $svc): missing, empty, locked or access denied"; exit 1 }
    export "$var=$secret"
    unset secret
    exec "$prog" "$@"
  )
}

# _ait_acct_prep_code <dir>: the account's VS Code user folder, with links to the main settings. Writes only under <dir>.
_ait_acct_prep_code() {
  emulate -L zsh
  local dir=$1 src="$HOME/Library/Application Support/Code/User" f
  if [[ -L ${dir:h} || -L $dir || -L $dir/User ]]; then print -u2 "accounts: ${dir:h}, $dir or its User folder is a symlink; refusing"; return 1; fi
  mkdir -p -m 700 "${dir:h}" "$dir" "$dir/User" || return 1
  for f in settings.json keybindings.json snippets mcp.json; do
    [[ -e $src/$f ]] || continue
    [[ -e $dir/User/$f || -L $dir/User/$f ]] && continue
    ln -s "$src/$f" "$dir/User/$f" || print -u2 "accounts: could not link $f"
  done
  return 0
}

# _ait_acct_code <account> [code args...]
_ait_acct_code() {
  emulate -L zsh
  local name=$1 dir=$HOME/.vscode-accounts/$1 svc=${_ait_acct_svc[$1]-}
  shift
  # No folder is made for an account whose item is not there (existence only, no -w).
  if [[ -n $svc ]] && command -v security >/dev/null 2>&1 && ! security find-generic-password -s "$svc" >/dev/null 2>&1; then
    print -u2 "accounts: no usable Keychain item for $name (service $svc): missing, empty, locked or access denied"
    return 1
  fi
  _ait_acct_prep_code "$dir" || return 1
  _ait_acct_run "$name" code --user-data-dir "$dir" "$@"
}

# _ait_acct_define <function name> <body>: never replaces something this loader did not define itself.
_ait_acct_define() {
  emulate -L zsh
  local fn=$1 body=$2
  if (( ! ${+_ait_acct_own[$fn]} )) && whence -- "$fn" >/dev/null 2>&1; then
    print -u2 "accounts.zsh: skipped $fn: a command, function or alias with that name already exists"
    return 1
  fi
  functions[$fn]=$body
  _ait_acct_own[$fn]=1
}

_ait_acct_load() {
  emulate -L zsh
  local parser=$_ait_acct_dir/install-copies.sh out line name kind svc
  _ait_acct_kind=() _ait_acct_svc=()
  [[ -e $HOME/.claude/accounts.conf ]] || return 0   # no accounts: no bash, no git, nothing said
  [[ -r $parser ]] || { print -u2 "accounts.zsh: cannot read $parser; no account launchers are loaded"; return 0 }
  # stdout: one name<TAB>kind<TAB>service per valid line. stderr (a bad line, a refused file) passes through.
  out=$(bash "$parser" accounts </dev/null) || return 0
  for line in ${(f)out}; do
    IFS=$'\t' read -r name kind svc <<< $line
    [[ -n $name && -n $kind && -n $svc ]] || continue
    # The parser has checked these; they become function code, so check again here.
    case $name in *[!abcdefghijklmnopqrstuvwxyz0123456789-]* | -* | *-) continue ;; esac
    case $kind in oauth | apikey) ;; *) continue ;; esac
    _ait_acct_kind[$name]=$kind _ait_acct_svc[$name]=$svc
    _ait_acct_define claude-$name "_ait_acct_run $name claude \"\$@\""
    _ait_acct_define code-$name "_ait_acct_code $name \"\$@\""
  done
  return 0
}

_ait_acct_load
