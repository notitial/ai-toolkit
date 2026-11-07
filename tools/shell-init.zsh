# The one line ~/.zshrc needs to load the toolkit's zsh helpers:
#   source ~/.claude/tools/shell-init.zsh
# /setup-claude links that path to this file, and the helpers are read from beside it in the checkout. Add a new
# helper as one more line below.
# Tests: bash tools/test-ait.sh

_shell_init_dir=${${(%):-%x}:A:h}
if [[ -r $_shell_init_dir/ait.zsh ]]; then source "$_shell_init_dir/ait.zsh"
else print -u2 "shell-init.zsh: cannot read $_shell_init_dir/ait.zsh; the ait helpers are not loaded"; fi
if [[ -r $_shell_init_dir/accounts.zsh ]]; then source "$_shell_init_dir/accounts.zsh"
else print -u2 "shell-init.zsh: cannot read $_shell_init_dir/accounts.zsh; the account launchers are not loaded"; fi
unset _shell_init_dir
