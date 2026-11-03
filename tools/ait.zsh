# zsh helpers for the toolkit pieces that live outside the checkout. ~/.zshrc loads them through tools/shell-init.zsh:
#   source ~/.claude/tools/shell-init.zsh
#   ait          cd to the checkout
#   ait-status   everything /setup-claude checks (bash tools/install-copies.sh status)
#   ghm-status   the installed github MCP launcher and guard against main, rendered with ~/.claude/install.conf
#   ghm-test     the github MCP suites; run them before ghm-install
#   ghm-install  install the launcher and guard root-owned, after showing what changes
# The launcher and guard are root-owned so that no agent session can edit the live guard. ghm-install installs only
# merged code: main's committed files, with main clean and equal to origin/main.
# Tests: bash tools/test-ait.sh

AIT_ROOT=${${(%):-%x}:A:h:h}
AIT_MCP_DIR=/usr/local/libexec/mcp-github
AIT_MCP_PERM='root:wheel 755'

ait() { builtin cd "$AIT_ROOT" }

ait-status() { bash "$AIT_ROOT/tools/install-copies.sh" status }

ghm-test() {
  bash "$AIT_ROOT/tools/github-mcp/test-guard.sh" && bash "$AIT_ROOT/tools/github-mcp/test-update-check.sh"
}

# The owner list of a guard on stdin.
_ait_owners() { sed -n "s/^WRITE_OWNERS='\(.*\)'\$/\1/p" }

# main's copy of a github-mcp file, filled in from the install-time settings.
_ait_render() { git -C "$AIT_ROOT" show "main:tools/github-mcp/$1" | bash "$AIT_ROOT/tools/install-copies.sh" render }

# Owner, group and mode of a path. /usr/bin/stat: the flags are BSD's, and a GNU stat earlier on PATH reads them
# differently.
_ait_perm() { /usr/bin/stat -f '%Su:%Sg %Lp' "$1" 2>/dev/null }

# Read-only, no sudo: the folder's owner and mode, then each file's content, owner and mode.
ghm-status() {
  emulate -L zsh
  local f perm why rc=0
  why=$(bash "$AIT_ROOT/tools/install-copies.sh" render </dev/null 2>&1 >/dev/null)
  case $? in
    0) ;;
    3) print "MISSING  install settings (~/.claude/install.conf; run /setup-claude)"; return 1 ;;
    *) print -r -- "STALE    install settings ($why)"; return 1 ;;
  esac
  perm=$(_ait_perm "$AIT_MCP_DIR")
  [[ $perm == "$AIT_MCP_PERM" ]] || { print "DIFFERS  folder $AIT_MCP_DIR (owner/mode is '$perm', want '$AIT_MCP_PERM')"; rc=1 }
  for f in launch guard.sh; do
    perm=$(_ait_perm "$AIT_MCP_DIR/$f")
    if ! _ait_render "$f" | cmp -s - "$AIT_MCP_DIR/$f"; then
      print "DIFFERS  $f"; rc=1
      if [[ $f == guard.sh && -f $AIT_MCP_DIR/guard.sh ]]; then
        print -r -- "         installed owners: $(_ait_owners < "$AIT_MCP_DIR/guard.sh")"
        print -r -- "         main's, rendered: $(_ait_render guard.sh 2>/dev/null | _ait_owners)"
      fi
    elif [[ $perm != "$AIT_MCP_PERM" ]]; then
      print "DIFFERS  $f (owner/mode is '$perm', want '$AIT_MCP_PERM')"; rc=1
    else
      print "ok       $f"
    fi
  done
  return $rc
}

ghm-install() {
  emulate -L zsh
  local d=$AIT_ROOT f tmp reply owners acct
  [[ $(git -C "$d" branch --show-current) == main ]] || { print -u2 "ghm-install: the checkout is not on main"; return 1 }
  [[ -z $(git -C "$d" status --porcelain --untracked-files=no) ]] ||
    { print -u2 "ghm-install: the checkout has uncommitted changes"; return 1 }
  git -C "$d" fetch -q origin main || { print -u2 "ghm-install: git fetch failed"; return 1 }
  [[ $(git -C "$d" rev-parse main) == $(git -C "$d" rev-parse origin/main) ]] ||
    { print -u2 "ghm-install: main is not equal to origin/main; pull or push first"; return 1 }
  tmp=$(mktemp -d) || return 1
  {
    for f in launch guard.sh; do
      _ait_render "$f" > "$tmp/$f" || { print -u2 "ghm-install: cannot render $f"; return 1 }
    done
    owners=$(_ait_owners < "$tmp/guard.sh")
    acct=$(sed -n 's/.* -a \([^ ]*\) -w.*/\1/p' "$tmp/launch" | head -n 1)
    [[ -n $owners && -n $acct ]] || { print -u2 "ghm-install: the rendered files hold no owner list or no keychain account"; return 1 }
    print -r -- "Installing main ($(git -C "$d" rev-parse --short main)) into $AIT_MCP_DIR"
    print -r -- "  write owners:     $owners"
    print -r -- "  keychain account: $acct"
    for f in launch guard.sh; do
      diff -u "$AIT_MCP_DIR/$f" "$tmp/$f" 2>/dev/null
      (( $? == 2 )) && diff -u /dev/null "$tmp/$f"
    done
    read -r "reply?Install these root-owned? [y/N] "
    [[ $reply == [yY]* ]] || { print -u2 "ghm-install: not installed"; return 1 }
    sudo /usr/bin/install -d -o root -g wheel -m 755 "$AIT_MCP_DIR" &&
      sudo /usr/bin/install -S -o root -g wheel -m 755 "$tmp/launch" "$tmp/guard.sh" "$AIT_MCP_DIR/" ||
      { print -u2 "ghm-install: sudo install failed"; return 1 }
  } always {
    rm -rf "$tmp"
  }
  ghm-status
}
