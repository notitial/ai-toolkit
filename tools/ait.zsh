# zsh helpers for the toolkit. ~/.zshrc loads them through tools/shell-init.zsh:
#   source ~/.claude/tools/shell-init.zsh
#   ait          cd to the checkout
#   ait-status   everything /setup-claude checks (bash tools/install-copies.sh status)
#   ghm-status   the github MCP lines of ait-status: the checkout on a clean main, the server binary, the server
#                registration and the guard hook, all pointing at this checkout
#   ghm-test     the github MCP suites; run them in your /tmp clone before you merge
# The launcher and the guard run from the live checkout (it stays on main and only moves with a fast-forward pull
# after a merge), so there is nothing to install: a merge plus the pull is the install.
# Tests: bash tools/test-ait.sh

AIT_ROOT=${${(%):-%x}:A:h:h}

ait() { builtin cd "$AIT_ROOT" }

ait-status() { bash "$AIT_ROOT/tools/install-copies.sh" status }

ghm-test() {
  bash "$AIT_ROOT/tools/github-mcp/test-guard.sh" && bash "$AIT_ROOT/tools/github-mcp/test-update-check.sh"
}

# Read-only: the github lines of the status. Fails unless every one of them is ok.
ghm-status() {
  emulate -L zsh
  local out
  out=$(bash "$AIT_ROOT/tools/install-copies.sh" status 2>&1 </dev/null | grep -i 'github')
  print -r -- "$out"
  [[ -n $out && -z $(print -r -- "$out" | grep -v '^ok ') ]]
}
