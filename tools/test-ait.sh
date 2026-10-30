#!/bin/bash
# Tests for tools/ait.zsh and tools/shell-init.zsh. Run: bash tools/test-ait.sh
# The helpers run from a throwaway checkout with a bare origin, a scratch HOME holding the install-time settings, a temp
# dir standing in for /usr/local/libexec/mcp-github, and a fake sudo first on PATH that logs each call and runs it
# without its -o/-g. Nothing touches the real checkout, ~/.claude or /usr/local.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
command -v zsh >/dev/null 2>&1 || { echo "zsh required" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/ait-test-XXXXXX") && T=$(cd "$T" && pwd -P) || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
R="$T/repo"
INST="$T/inst"
CONF="$T/home/.claude/install.conf"
mkdir -p "$T/bin" "$T/home/.claude/tools" "$R/tools/github-mcp" "$INST"

write_conf() {  # write_conf <owners> <account>
  printf '%s\n' "github_write_owners=$1" "github_keychain_account=$2" > "$CONF"
  chmod 600 "$CONF"
}
write_conf 'notitial example-user' example-user
# The fixture files carry the placeholders the shipped ones do: the launcher's account on two lines, the guard's owners.
launch_v() { printf '%s\n' "launcher $1" 'tok=$(/usr/bin/security find-generic-password -s mcp-github -a __GITHUB_KEYCHAIN_ACCOUNT__ -w </dev/null)' 'echo "keychain item mcp-github/__GITHUB_KEYCHAIN_ACCOUNT__ missing"'; }
guard_v() { printf '%s\n' "guard $1" "WRITE_OWNERS='__GITHUB_WRITE_OWNERS__'"; }
render_fixture() { sed -e 's|__GITHUB_WRITE_OWNERS__|["notitial","example-user"]|g' -e 's|__GITHUB_KEYCHAIN_ACCOUNT__|example-user|g'; }

cp "$HERE/ait.zsh" "$HERE/shell-init.zsh" "$HERE/install-copies.sh" "$R/tools/"
launch_v v1 > "$R/tools/github-mcp/launch"
guard_v v1 > "$R/tools/github-mcp/guard.sh"
printf 'echo guard-suite\n' > "$R/tools/github-mcp/test-guard.sh"
printf 'echo update-suite\n' > "$R/tools/github-mcp/test-update-check.sh"
git init -q -b main "$R"
git init -q --bare -b main "$T/origin.git"
git -C "$R" remote add origin "$T/origin.git"
git -C "$R" add -A
git -C "$R" -c commit.gpgsign=false commit -q -m init
git -C "$R" push -q origin main
gc() { git -C "$R" -c commit.gpgsign=false "$@"; }

cat > "$T/bin/sudo" <<'EOF'
#!/bin/bash
echo "$*" >> "$SUDO_LOG"
args=()
while [ $# -gt 0 ]; do case $1 in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
exec "${args[@]}"
EOF
chmod 755 "$T/bin/sudo"
# Installed files take the group of their folder; the owner and mode ghm-status wants are the test user's.
chmod 755 "$INST"
PERM="$(id -un):$(stat -f '%Sg' "$INST") 755"

# z <zsh code> [stdin file]: run the code with the helpers loaded and pointed at the temp install dir.
z() {
  HOME="$T/home" PATH="$T/bin:$PATH" SUDO_LOG="$T/sudo-log" \
    zsh -f -c "source '$R/tools/ait.zsh'; AIT_MCP_DIR='$INST'; AIT_MCP_PERM='$PERM'; $1" < "${2:-/dev/null}" 2>&1
}
sync_inst() { local f; for f in launch guard.sh; do render_fixture < "$R/tools/github-mcp/$f" > "$INST/$f"; chmod 755 "$INST/$f"; done; }
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
expect_has() { case "$2" in *"$3"*) ok ;; *) bad "$1: wanted '$3' in: $2" ;; esac; }
expect_not() { case "$2" in *"$3"*) bad "$1: did not want '$3' in: $2" ;; *) ok ;; esac; }
no_sudo() { if [ -s "$T/sudo-log" ]; then bad "$1: sudo ran: $(cat "$T/sudo-log")"; else ok; fi; }
printf 'y\n' > "$T/yes"
printf 'n\n' > "$T/no"

# Loading: ~/.zshrc sources the ~/.claude/tools link, and the helpers come from the checkout it points at.
ln -s "$R/tools/shell-init.zsh" "$T/home/.claude/tools/shell-init.zsh"
out=$(HOME="$T/home" zsh -f -c "source '$T/home/.claude/tools/shell-init.zsh'; whence -w ait ait-status ghm-status ghm-test ghm-install; print -r -- \"root=\$AIT_ROOT\"" 2>&1)
expect_has "shell-init through the link loads ghm-install" "$out" "ghm-install: function"
expect_has "AIT_ROOT is the checkout the link points at" "$out" "root=$R"
expect_not "shell-init loads without errors" "$out" "no such file"
out=$(z 'ait; pwd')
expect_has "ait changes to the checkout" "$out" "$R"
out=$(z ghm-test)
expect_has "ghm-test runs the guard suite" "$out" "guard-suite"
expect_has "ghm-test runs the update-check suite" "$out" "update-suite"
out=$(z ait-status)
expect_has "ait-status runs install-copies.sh status" "$out" "links "

# ghm-status
out=$(z ghm-status)
expect_has "nothing installed: launch differs" "$out" "DIFFERS  launch"
expect_has "nothing installed: guard.sh differs" "$out" "DIFFERS  guard.sh"
expect_not "nothing installed: no error about the missing files" "$out" "no such file"
[ "$(z 'ghm-status >/dev/null; echo "rc=$?"' | grep '^rc=')" = rc=1 ] && ok || bad "ghm-status exits 1 when a file differs"
sync_inst
out=$(z 'ghm-status; echo "rc=$?"')
expect_has "installed copies equal to main rendered are ok" "$out" "ok       launch"
expect_has "the guard is ok" "$out" "ok       guard.sh"
expect_has "all ok exits 0" "$out" "rc=0"
chmod 644 "$INST/guard.sh"
out=$(z ghm-status)
expect_has "a wrong mode is reported" "$out" "DIFFERS  guard.sh (owner/mode is"
chmod 775 "$INST"
out=$(z ghm-status)
expect_has "a wrong folder mode is reported" "$out" "DIFFERS  folder $INST (owner/mode is"
chmod 755 "$INST"
sync_inst
printf '%s\n' 'guard v1' "WRITE_OWNERS='[\"someone\"]'" > "$INST/guard.sh"
out=$(z ghm-status)
expect_has "an edited guard differs" "$out" "DIFFERS  guard.sh"
expect_has "it shows the installed owners" "$out" "installed owners: [\"someone\"]"
expect_has "and main's, rendered" "$out" "main's, rendered: [\"notitial\",\"example-user\"]"
sync_inst
write_conf 'notitial example-user' other-user
out=$(z ghm-status)
expect_has "a changed account setting makes the launcher differ" "$out" "DIFFERS  launch"
expect_has "the guard stays ok" "$out" "ok       guard.sh"
write_conf 'notitial example-user' example-user
write_conf Not_An_Owner example-user
out=$(z ghm-status)
expect_has "invalid settings are STALE with the reason" "$out" "STALE    install settings (install settings invalid (github_write_owners: invalid value)"
rm "$CONF"
out=$(z ghm-status)
expect_has "no settings file is MISSING" "$out" "MISSING  install settings"
write_conf 'notitial example-user' example-user

# ghm-install refusals: nothing reaches sudo.
rm -f "$INST/launch" "$INST/guard.sh"
: > "$T/sudo-log"
gc checkout -q -b side
out=$(z ghm-install "$T/yes")
expect_has "refuses off main" "$out" "not on main"
gc checkout -q main
gc branch -q -D side
printf 'edited\n' >> "$R/tools/github-mcp/guard.sh"
out=$(z ghm-install "$T/yes")
expect_has "refuses uncommitted changes" "$out" "uncommitted changes"
gc checkout -q -- tools/github-mcp/guard.sh
gc commit -q --allow-empty -m local
out=$(z ghm-install "$T/yes")
expect_has "refuses main ahead of origin/main" "$out" "not equal to origin/main"
gc reset -q --hard origin/main
git clone -q "$T/origin.git" "$T/other" 2>/dev/null
git -C "$T/other" -c commit.gpgsign=false commit -q --allow-empty -m remote
git -C "$T/other" push -q origin main
out=$(z ghm-install "$T/yes")
expect_has "refuses main behind origin/main (the fetch is real)" "$out" "not equal to origin/main"
gc pull -q --ff-only origin main
printf 'guard without owners\n' > "$R/tools/github-mcp/guard.sh"
gc commit -q -am no-owners
gc push -q origin main
out=$(z ghm-install "$T/yes")
expect_has "refuses when the render reads back no owner list" "$out" "no owner list or no keychain account"
guard_v v1 > "$R/tools/github-mcp/guard.sh"
gc commit -q -am owners-back
gc push -q origin main
printf 'edited\n' > "$R/notes.txt"
out=$(z ghm-install "$T/no")
expect_not "an untracked file does not block the install" "$out" "uncommitted changes"
rm "$R/notes.txt"
rm "$CONF"
out=$(z ghm-install "$T/yes")
expect_has "refuses without the settings" "$out" "cannot render launch"
write_conf 'notitial example-user' example-user
out=$(z ghm-install "$T/no")
expect_has "shows the diff before asking" "$out" "+launcher v1"
expect_has "an n answer installs nothing" "$out" "not installed"
out=$(z ghm-install)
expect_has "no answer installs nothing" "$out" "not installed"
no_sudo "the refusals"
[ ! -e "$INST/guard.sh" ] && ok || bad "a refusal installed a file"

# ghm-install: a y answer makes sure of the folder and installs both files rendered, then shows the status.
out=$(z 'ghm-install; echo "rc=$?"' "$T/yes")
expect_has "shows the owners read back from the render" "$out" "write owners:     [\"notitial\",\"example-user\"]"
expect_has "shows the account read back from the render" "$out" "keychain account: example-user"
expect_has "the folder is set root-owned, mode 755, every time" "$(sed -n 1p "$T/sudo-log")" "/usr/bin/install -d -o root -g wheel -m 755 $INST"
expect_has "then one install of both files, root-owned, mode 755" "$(sed -n 2p "$T/sudo-log")" "/usr/bin/install -S -o root -g wheel -m 755 "
[ "$(wc -l < "$T/sudo-log" | tr -d ' ')" = 2 ] && ok || bad "two sudo calls: $(cat "$T/sudo-log")"
render_fixture < "$R/tools/github-mcp/guard.sh" | cmp -s - "$INST/guard.sh" && ok || bad "the installed guard is main's, rendered"
render_fixture < "$R/tools/github-mcp/launch" | cmp -s - "$INST/launch" && ok || bad "the installed launcher is main's, rendered"
expect_has "ends with ghm-status" "$out" "ok       guard.sh"
expect_has "and exits 0" "$out" "rc=0"
# A merged change: the diff shows exactly it.
guard_v v2 > "$R/tools/github-mcp/guard.sh"
gc commit -q -am v2
gc push -q origin main
out=$(z ghm-install "$T/yes")
expect_has "the diff shows the old line" "$out" "-guard v1"
expect_has "and the new one" "$out" "+guard v2"
expect_has "the update is installed" "$(cat "$INST/guard.sh")" "guard v2"
# An installed file that cannot be read: the whole new file is shown.
chmod 000 "$INST/guard.sh"
out=$(z ghm-install "$T/no")
expect_has "an unreadable installed file shows the whole new file" "$out" "+guard v2"
expect_has "as a diff from nothing" "$out" "--- /dev/null"
chmod 755 "$INST/guard.sh"
# The first install makes the folder.
: > "$T/sudo-log"
out=$(HOME="$T/home" PATH="$T/bin:$PATH" SUDO_LOG="$T/sudo-log" zsh -f -c "source '$R/tools/ait.zsh'; AIT_MCP_DIR='$T/new/mcp'; ghm-install" < "$T/yes" 2>&1)
expect_has "a missing folder is made first" "$(head -n 1 "$T/sudo-log")" "install -d -o root -g wheel -m 755 $T/new/mcp"
[ -f "$T/new/mcp/launch" ] && ok || bad "the first install put the launcher in the new folder: $out"

echo "ait: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
