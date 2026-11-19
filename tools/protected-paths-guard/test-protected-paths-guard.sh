#!/bin/bash
# Tests for hooks/protected-paths-guard.sh (HOOK=<path> tests another copy). Run: bash tools/protected-paths-guard/test-protected-paths-guard.sh
# The hook runs from a temp copy under HOOK_SHELL (default /bin/bash, 3.2) with HOME pointed at a temp folder, so a
# deny never writes to the live audit log. The tree built below: a protected folder (with the marker), a clone with no
# marker, a second protected folder standing for a state folder under HOME, and settings files. Each case expects deny
# or pass (no output).

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../../hooks/protected-paths-guard.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
SH="${HOOK_SHELL:-/bin/bash}"
T=$(mktemp -d "${TMPDIR:-/tmp}/protected-paths-guard-XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/hooks"
cp "$HOOK" "$T/hooks/protected-paths-guard.sh"
cp -R "${HOOK%/*}/lib" "$T/hooks/lib"

H="$T/home"
LIVE="$T/live"
CLONE="$T/clone"
STATE="$H/.claude/state"
mkdir -p "$LIVE/.git" "$CLONE/.git" "$LIVE/.archive/c1/.git" "$H/.claude/hooks" "$LIVE/tools" "$LIVE/hooks" "$LIVE/.archive/task" "$CLONE/tools" "$STATE/sub" "$T/other"
: >"$LIVE/.protected-checkout"
: >"$STATE/.protected-checkout"
echo '{}' >"$H/.claude/settings.json"
echo '{}' >"$H/.claude/settings.local.json"
echo '{}' >"$H/.claude/settings.json.bak-1"
echo x >"$LIVE/tools/a.ts"
echo x >"$LIVE/hooks/guard.sh"
echo x >"$CLONE/tools/a.ts"
ln -s "$LIVE/hooks/guard.sh" "$H/.claude/hooks/guard.sh"
ln -s "$LIVE/tools" "$T/other/tools-link"
ln -s "$LIVE/tools/a.ts" "$LIVE/.archive/task/sneaky"
ln -s "$T/other" "$LIVE/.archive/outside"
ln -s "$H/.claude/settings.json" "$T/other/settings-link"
ln -s "$LIVE" "$T/livelink"

PASS=0
FAIL=0
decision() {  # decision <stdin json>
  local out
  out=$(printf '%s' "$1" | HOME="$H" "$SH" "$T/hooks/protected-paths-guard.sh" 2>/dev/null)
  [ -z "$out" ] && { echo pass; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed
}
expect() {  # expect <deny|pass> <label> <stdin json>
  local got
  got=$(decision "$3")
  if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $2: want $1, got $got"; fi
}
call() {  # call <tool> <tool_input json> <cwd>
  jq -nc --arg n "$1" --argjson i "$2" --arg c "$3" '{tool_name: $n, tool_input: $i, cwd: $c}'
}
file() { expect "$1" "$3: $2" "$(call "$3" "$(jq -nc --arg p "$2" '{file_path: $p}')" "${4:-$CLONE}")"; }  # file <d|p> <path> <tool> [cwd]
bash_() { expect "$1" "bash: $2" "$(call Bash "$(jq -nc --arg c "$2" '{command: $c}')" "${3:-$CLONE}")"; }  # bash_ <d|p> <command> [cwd]
gitmcp() { expect "$1" "git: $2 $3" "$(call "mcp__git-mcp__$2" "$3" "${4:-$CLONE}")"; }  # gitmcp <d|p> <tool> <input> [cwd]
d=deny
p=pass

# ---- file tools ----
for tool in Write Edit MultiEdit; do
  file $d "$LIVE/tools/a.ts" $tool
  file $d "$LIVE/new/deep/file.ts" $tool
  file $d "$LIVE/.protected-checkout" $tool
  file $p "$CLONE/tools/a.ts" $tool
  file $p "$LIVE/.archive/task/notes.md" $tool
  file $p "$LIVE/.archive/x/y/z.md" $tool
done
expect $d "NotebookEdit under the root" "$(call NotebookEdit "$(jq -nc --arg p "$LIVE/n.ipynb" '{notebook_path: $p}')" "$CLONE")"
expect $p "NotebookEdit in a clone" "$(call NotebookEdit "$(jq -nc --arg p "$CLONE/n.ipynb" '{notebook_path: $p}')" "$CLONE")"
file $d "$LIVE/.archive/../tools/a.ts" Write
file $d "$LIVE/.archive/task/sneaky" Write
file $p "$LIVE/.archive/outside/new.txt" Write
file $d "$T/other/tools-link/a.ts" Write
file $d "$T/livelink/tools/a.ts" Write
file $d "$H/.claude/hooks/guard.sh" Write
file $p "$H/.claude/hooks/other-new.sh" Write
file $d "tools/a.ts" Write "$LIVE"
file $p "tools/a.ts" Write "$CLONE"
file $d "$LIVE" Write
file $d "$STATE/data/x.json" Write
file $p "$STATE/.archive/x.json" Write
file $d "$STATE/sub/y" Edit "$CLONE"

# ---- settings files ----
for tool in Write Edit MultiEdit; do
  file $d "$H/.claude/settings.json" $tool
  file $d "$H/.claude/settings.local.json" $tool
  file $d "$H/.claude/SETTINGS.JSON" $tool
  file $p "$H/.claude/settings.json.bak-1" $tool
  file $p "$H/.claude/settings.jsonx" $tool
  file $p "$H/.claude/projects/settings.json" $tool
done
file $d "$T/other/settings-link" Write
file $d "~/.claude/settings.json" Write
file $p "$CLONE/.claude/settings.json" Write

# ---- case-insensitive file systems ----
if [ -e "$T/LIVE" ]; then
  file $d "$T/LIVE/tools/a.ts" Write
  file $d "$LIVE/.ARCHIVE/../TOOLS/a.ts" Write
  file $p "$LIVE/.ARCHIVE/x.md" Write
fi

# ---- redirects and write verbs ----
bash_ $d "echo x > $LIVE/tools/a.ts"
bash_ $d "echo x >> $LIVE/tools/a.ts"
bash_ $d "echo x >| $LIVE/tools/a.ts"
bash_ $d "echo x &> $LIVE/tools/a.ts"
bash_ $d "echo x 2> $LIVE/tools/err"
bash_ $p "echo x > $CLONE/a.txt"
bash_ $p "echo x > /dev/null 2>&1"
bash_ $p "echo x 2>&1 >/dev/null"
bash_ $p "cat $LIVE/tools/a.ts"
bash_ $p "cat $LIVE/tools/a.ts > $CLONE/copy"
bash_ $p "cat < $LIVE/tools/a.ts"
bash_ $p "grep -rn x $LIVE/tools"
bash_ $p "ls -la $LIVE"
bash_ $d "rm $LIVE/tools/a.ts"
bash_ $d "rm -r $LIVE/tools"
bash_ $d "rmdir $LIVE/tools"
bash_ $d "touch $LIVE/x"
bash_ $d "mkdir -p $LIVE/new/dir"
bash_ $d "chmod +x $LIVE/tools/a.ts"
bash_ $d "chmod 755 $LIVE/tools/a.ts"
bash_ $p "chmod +x $CLONE/tools/a.ts" "$LIVE"
bash_ $d "mv $LIVE/tools/a.ts $CLONE/b"
bash_ $d "mv $CLONE/tools/a.ts $LIVE/b"
bash_ $p "mv $CLONE/tools/a.ts $CLONE/b"
bash_ $d "cp $CLONE/tools/a.ts $LIVE/tools/b"
bash_ $d "cp -t $LIVE/tools $CLONE/tools/a.ts"
bash_ $p "cp $LIVE/tools/a.ts $CLONE/b"
bash_ $p "cp -n $H/.claude/settings.json $H/.claude/settings.json.bak-2"
bash_ $d "cp $CLONE/tools/a.ts $H/.claude/settings.json"
bash_ $d "install -m 755 $CLONE/tools/a.ts $LIVE/tools/b"
bash_ $d "ln -s $CLONE/tools $LIVE/link"
bash_ $p "ln -s $LIVE/tools $CLONE/link"
bash_ $d "rsync -a $CLONE/tools/ $LIVE/tools/"
bash_ $p "rsync -a $LIVE/tools/ $CLONE/tools/"
bash_ $d "dd if=/dev/zero of=$LIVE/tools/a.ts count=1"
bash_ $d "truncate -s 0 $LIVE/tools/a.ts"
bash_ $p "truncate -s 0 $CLONE/tools/a.ts" "$LIVE"
bash_ $d "echo x | tee $LIVE/tools/a.ts"
bash_ $d "echo x | tee -a $LIVE/tools/a.ts"
bash_ $p "echo x | tee $CLONE/a.txt" "$LIVE"
bash_ $d "sed -i 's/a/b/' $LIVE/tools/a.ts"
bash_ $d "sed -i.bak -e 's/a/b/' $LIVE/tools/a.ts"
bash_ $d "sed -i '' 's/a/b/' $LIVE/tools/a.ts"
bash_ $p "sed -i 's/a/b/' $CLONE/tools/a.ts" "$LIVE"
bash_ $p "sed -n 's/a/b/p' $LIVE/tools/a.ts"
bash_ $d "perl -pi -e 's/a/b/' $LIVE/tools/a.ts"
bash_ $p "perl -pi -e 's/a/b/' $CLONE/tools/a.ts" "$LIVE"
bash_ $d "curl -o $LIVE/tools/a.ts https://example.invalid/x"
bash_ $p "curl -o $CLONE/a https://example.invalid/x" "$LIVE"
bash_ $d "curl -O https://example.invalid/x" "$LIVE"
bash_ $p "curl -s https://example.invalid/x" "$LIVE"
bash_ $d "wget -O $LIVE/x https://example.invalid/x"
bash_ $d "wget https://example.invalid/x" "$LIVE"
bash_ $d "tar xf a.tar -C $LIVE/tools"
bash_ $d "tar -xzf a.tgz" "$LIVE"
bash_ $p "tar -xzf a.tgz -C $CLONE" "$LIVE"
bash_ $p "tar tf a.tar" "$LIVE"
bash_ $d "unzip a.zip -d $LIVE/tools"
bash_ $d "unzip a.zip" "$LIVE"
bash_ $p "unzip -l a.zip" "$LIVE"
bash_ $d "patch -p1 < a.diff" "$LIVE"
bash_ $d "find $LIVE/tools -name '*.ts' -delete"
bash_ $d "find $LIVE/tools -name '*.ts' -exec rm {} +"
bash_ $d "find . -name '*.ts' -delete" "$LIVE"
bash_ $p "find $LIVE/tools -name '*.ts' -exec grep -l x {} +"
bash_ $p "find $CLONE -name '*.ts' -delete" "$LIVE"
bash_ $d "find $LIVE -name x -fprint $LIVE/list"
bash_ $d "xargs rm $LIVE/tools/a.ts"
bash_ $p "xargs grep x $LIVE/tools/a.ts"

# ---- segments, cd tracking, wrappers, nesting ----
bash_ $d "ls && echo x > $LIVE/tools/a.ts"
bash_ $d "ls; rm $LIVE/tools/a.ts"
bash_ $d "ls || rm $LIVE/tools/a.ts"
bash_ $d "ls | tee $LIVE/tools/a.ts"
bash_ $d "ls &
rm $LIVE/tools/a.ts"
bash_ $d "echo \$(rm $LIVE/tools/a.ts)"
bash_ $d "echo \"\$(rm $LIVE/tools/a.ts)\""
bash_ $d "echo \`rm $LIVE/tools/a.ts\`"
bash_ $d "(rm $LIVE/tools/a.ts)"
bash_ $d "{ rm $LIVE/tools/a.ts; }"
bash_ $d "if true; then rm $LIVE/tools/a.ts; fi"
bash_ $d "for f in a; do rm $LIVE/tools/\$f; done"
bash_ $d "cd $LIVE && touch x"
bash_ $d "cd $LIVE/tools && echo x > a.ts" "$CLONE"
bash_ $p "cd $CLONE && echo x > a.ts" "$LIVE"
bash_ $p "cd $CLONE && touch x && cd $T/other && touch y" "$LIVE"
bash_ $d "cd $CLONE && cd $LIVE && touch x"
bash_ $d "cd $T/other/tools-link && touch x"
bash_ $d "cd ../live && touch x" "$CLONE"
bash_ $p "cd \$X && touch x" "$LIVE"
bash_ $p "cd \$X && touch $CLONE/x" "$LIVE"
bash_ $d "cd \$X && touch $LIVE/x" "$CLONE"
bash_ $d "touch tools/new" "$LIVE"
bash_ $d "touch ./tools/new" "$LIVE"
bash_ $p "touch new" "$CLONE"
bash_ $d "env FOO=1 rm $LIVE/tools/a.ts"
bash_ $d "FOO=1 rm $LIVE/tools/a.ts"
bash_ $d "sudo rm $LIVE/tools/a.ts"
bash_ $d "nohup rm $LIVE/tools/a.ts"
bash_ $d "command rm $LIVE/tools/a.ts"
bash_ $d "timeout 5 rm $LIVE/tools/a.ts"
bash_ $d "/bin/rm $LIVE/tools/a.ts"
bash_ $d "'rm' $LIVE/tools/a.ts"
bash_ $d "bash -c 'rm $LIVE/tools/a.ts'"
bash_ $d "sh -c \"echo x > $LIVE/tools/a.ts\""
bash_ $d "bash -lc 'cd $LIVE && touch x'"
bash_ $d "eval 'rm $LIVE/tools/a.ts'"
bash_ $p "bash -c 'echo hi'"
bash_ $d "rm $LIVE/tools/*.ts"
bash_ $d "rm -- $LIVE/tools/a.ts"
bash_ $d "rm ~/.claude/settings.json"
bash_ $d "echo x > ~/.claude/settings.json"
bash_ $d "echo x > ~/.claude/settings.local.json"
bash_ $p "echo x > ~/.claude/other.json"
bash_ $d "rm $H/.claude/hooks/guard.sh"
bash_ $d "echo x > $STATE/data/y"
bash_ $d "touch $STATE/.protected-checkout"
bash_ $d "rm $LIVE/.protected-checkout"
bash_ $p "touch $LIVE/.archive/task/notes.md"
bash_ $p "echo done >> $LIVE/.archive/task/notes.md"
bash_ $p "cat <<'EOF' > $CLONE/note.md
rm $LIVE/tools/a.ts
EOF"
bash_ $d "cat <<'EOF' > $LIVE/tools/note.md
text
EOF"
bash_ $d "cat <<EOF >$LIVE/tools/note.md
text
EOF
rm $LIVE/tools/a.ts"
bash_ $p "git commit -m \"\$(cat <<'EOF'
fix: say rm $LIVE/tools/a.ts and echo x > $LIVE/b
EOF
)\" --allow-empty" "$CLONE"
bash_ $p "echo 'rm $LIVE/tools/a.ts'"
bash_ $p "echo \"x > $LIVE/tools/a.ts\""
bash_ $p "# rm $LIVE/tools/a.ts"

# ---- recursive removal or move of a folder that holds a protected root ----
bash_ $d "rm -r $T" "$LIVE"
bash_ $d "mv $T $T.moved" "$LIVE"
bash_ $d "rm -r $H/.claude" "$CLONE"
bash_ $d "rm -r /" "$LIVE"
bash_ $p "rm -r $T/other" "$LIVE"
bash_ $p "rm -r $CLONE" "$LIVE"

# ---- git MCP ----
for t in git_add git_commit git_checkout git_reset git_rebase git_merge git_cherry_pick git_init git_clone; do
  gitmcp $d $t "{\"path\":\"$LIVE\"}"
  gitmcp $p $t "{\"path\":\"$CLONE\"}" "$LIVE"
done
gitmcp $d git_add '{}' "$LIVE"
gitmcp $d git_commit '{"path":"."}' "$LIVE"
gitmcp $d git_commit '{"path":"tools"}' "$LIVE"
gitmcp $p git_commit '{}' "$CLONE"
gitmcp $d git_pull "{\"path\":\"$LIVE\"}"
gitmcp $d git_pull "{\"path\":\"$LIVE\",\"fastForwardOnly\":false}"
gitmcp $d git_pull "{\"path\":\"$LIVE\",\"fastForwardOnly\":true,\"rebase\":true}"
gitmcp $p git_pull "{\"path\":\"$LIVE\",\"fastForwardOnly\":true}"
gitmcp $p git_pull "{\"path\":\"$LIVE\",\"fastForwardOnly\":true,\"branch\":\"main\"}"
gitmcp $p git_pull "{\"path\":\"$CLONE\"}" "$LIVE"
gitmcp $d git_stash "{\"path\":\"$LIVE\"}"
gitmcp $d git_stash "{\"path\":\"$LIVE\",\"mode\":\"pop\"}"
gitmcp $p git_stash "{\"path\":\"$LIVE\",\"mode\":\"list\"}"
gitmcp $d git_branch "{\"path\":\"$LIVE\",\"mode\":\"create\",\"branchName\":\"x\"}"
gitmcp $d git_branch "{\"path\":\"$LIVE\",\"mode\":\"delete\",\"branchName\":\"x\"}"
gitmcp $p git_branch "{\"path\":\"$LIVE\",\"mode\":\"list\"}"
gitmcp $p git_branch "{\"path\":\"$LIVE\"}"
gitmcp $p git_branch "{\"path\":\"$LIVE\",\"mode\":\"show-current\"}"
gitmcp $d git_tag "{\"path\":\"$LIVE\",\"mode\":\"create\",\"tagName\":\"v1\"}"
gitmcp $p git_tag "{\"path\":\"$LIVE\",\"mode\":\"list\"}"
gitmcp $d git_remote "{\"path\":\"$LIVE\",\"mode\":\"add\",\"name\":\"x\",\"url\":\"https://example.invalid/r.git\"}"
gitmcp $p git_remote "{\"path\":\"$LIVE\",\"mode\":\"list\"}"
gitmcp $p git_remote "{\"path\":\"$LIVE\",\"mode\":\"get-url\",\"name\":\"origin\"}"
gitmcp $d git_worktree "{\"path\":\"$LIVE\",\"mode\":\"add\",\"worktreePath\":\"$T/w\"}"
gitmcp $d git_clean "{\"path\":\"$LIVE\"}"
gitmcp $p git_clean "{\"path\":\"$LIVE\",\"dryRun\":true}"
for t in git_status git_log git_diff git_show git_blame git_reflog git_fetch git_set_working_dir git_clear_working_dir git_changelog_analyze; do
  gitmcp $p $t "{\"path\":\"$LIVE\"}" "$LIVE"
done
gitmcp $d git_something_new "{\"path\":\"$LIVE\"}"
gitmcp $p git_something_new "{\"path\":\"$CLONE\"}" "$LIVE"

# ---- a push whose remote is a local path inside a protected folder ----
PC="$T/pclone"
PO="$T/porigin-live"
PN="$T/pnet"
for r in "$PC" "$PO" "$PN"; do git init -q "$r"; done
git -C "$PC" remote add toLive "$LIVE"
git -C "$PC" remote add toLiveFile "file://$LIVE"
git -C "$PC" remote add toLiveGit "$LIVE/.git"
git -C "$PC" remote add toLiveRel "../live"
git -C "$PC" remote add toNet "https://example.invalid/r.git"
git -C "$PC" remote add toScp "git@example.invalid:o/r.git"
git -C "$PC" remote add toOther "$T/other"
git -C "$PC" remote add toArchive "$LIVE/.archive/c1"
git -C "$PO" remote add origin "$LIVE"
git -C "$PN" remote add origin "https://example.invalid/r.git"
for r in toLive toLiveFile toLiveGit toLiveRel; do
  gitmcp $d git_push "{\"path\":\"$PC\",\"remote\":\"$r\"}"
done
gitmcp $d git_push "{\"path\":\"$PO\"}"
gitmcp $d git_push "{\"path\":\"$PO\",\"branch\":\"feat\",\"setUpstream\":true}"
gitmcp $d git_push "{\"path\":\"$PC\",\"remote\":\"$LIVE\"}"
gitmcp $d git_push "{\"path\":\"$PC\",\"remote\":\"file://$LIVE\"}"
gitmcp $d git_push "{\"path\":\"$PC\",\"remote\":\"../live\"}"
gitmcp $d git_push "{\"path\":\"$PC\",\"remote\":\"file://localhost$LIVE\"}"
gitmcp $p git_push "{\"path\":\"$PC\",\"remote\":\"toNet\"}"
gitmcp $p git_push "{\"path\":\"$PC\",\"remote\":\"toScp\"}"
gitmcp $p git_push "{\"path\":\"$PC\",\"remote\":\"toOther\"}"
gitmcp $p git_push "{\"path\":\"$PC\",\"remote\":\"toArchive\"}"
gitmcp $p git_push "{\"path\":\"$PC\",\"remote\":\"$T/other\"}"
gitmcp $p git_push "{\"path\":\"$PC\",\"remote\":\"https://example.invalid/r.git\"}"
gitmcp $p git_push "{\"path\":\"$PC\",\"remote\":\"git@example.invalid:o/r.git\"}"
gitmcp $p git_push "{\"path\":\"$PN\"}"
gitmcp $p git_push "{\"path\":\"$T/other\",\"remote\":\"origin\"}"
gitmcp $d git_push "{\"path\":\"$T/not-yet-made\",\"remote\":\"$LIVE\"}"
gitmcp $d git_push "{\"path\":\"$T/not-yet-made\",\"remote\":\"file://$LIVE\"}"
gitmcp $p git_push "{\"path\":\"$T/not-yet-made\",\"remote\":\"toNet\"}"
gitmcp $p git_push "{\"path\":\"$T/not-yet-made\",\"remote\":\"https://example.invalid/r.git\"}"
gitmcp $p git_push "{\"path\":\"$T/not-yet-made\",\"remote\":\"../live\"}"
gitmcp $p git_push "{\"path\":\"$T/not-yet-made\"}"
PT="$T/ptag"
git init -q "$PT"
git -C "$PT" -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false commit -q --allow-empty -m x
git -C "$PT" checkout -q -b feat
git -C "$PT" -c tag.gpgSign=false tag feat
git -C "$PT" remote add origin "https://example.invalid/r.git"
git -C "$PT" remote add toLive "$LIVE"
git -C "$PT" config branch.feat.pushRemote toLive
gitmcp $d git_push "{\"path\":\"$PT\"}"
mkdir -p "$PC/sub"
gitmcp $d git_push "{\"path\":\"$PC/sub\",\"remote\":\"toLiveRel\"}"
gitmcp $d git_push "{\"path\":\"$PC/sub\",\"remote\":\"../live\"}"
gitmcp $p git_push "{\"path\":\"$PC/sub\",\"remote\":\"toNet\"}"
git -C "$PC" remote add toMulti "https://example.invalid/r.git"
git -C "$PC" remote set-url --add --push toMulti "https://example.invalid/r.git"
git -C "$PC" remote set-url --add --push toMulti "$LIVE"
gitmcp $d git_push "{\"path\":\"$PC\",\"remote\":\"toMulti\"}"
HLIVE="$H/livehome"
ln -s "$LIVE" "$HLIVE"
gitmcp $d git_push "{\"path\":\"$PC\",\"remote\":\"~/livehome\"}"
gitmcp $d git_push "{\"path\":\"$PC\",\"remote\":\"\$HOME/livehome\"}"
gitmcp $d git_push "{\"path\":\"$LIVE\",\"remote\":\".\"}"
gitmcp $p git_push "{\"path\":\"$PC\",\"remote\":\".\"}"
gitmcp $p git_push "{\"path\":\"$CLONE\"}"
gitmcp $p git_push "{\"path\":\"$LIVE\"}" "$LIVE"

# ---- Monitor and other tools ----
expect $d "Monitor with a write" "$(call Monitor "$(jq -nc --arg c "echo x > $LIVE/tools/a.ts" '{command: $c}')" "$CLONE")"
expect $p "Monitor with a read" "$(call Monitor "$(jq -nc --arg c "tail -f $LIVE/tools/a.ts" '{command: $c}')" "$CLONE")"
expect $p "Read is not matched" "$(call Read "$(jq -nc --arg p "$LIVE/tools/a.ts" '{file_path: $p}')" "$CLONE")"
expect $p "an unrelated tool" "$(call mcp__github__get_file_contents '{"owner":"o","repo":"r","path":"a"}' "$LIVE")"

# ---- known limits: these pass and the header says so ----
bash_ $p "python3 -c \"open('$LIVE/tools/a.ts','w').write('x')\""
bash_ $p "node -e \"require('fs').writeFileSync('$LIVE/tools/a.ts','x')\""
bash_ $p "touch \$SOMEVAR/x"
bash_ $p "make -C $LIVE"
bash_ $p "echo $LIVE/tools/a.ts | xargs rm"

# ---- $HOME forms ----
bash_ $d "jq . x > \"\$HOME/.claude/settings.json\""
bash_ $d "echo x > \"\${HOME}/.claude/settings.local.json\""
bash_ $d "cd \"\$HOME/.claude\" && sed -i '' s/a/b/ settings.json"
bash_ $d "touch \$HOME/../live/x"
bash_ $p "cp -n \"\$HOME/.claude/settings.json\" \"\$HOME/.claude/settings.json.bak-3\""
bash_ $p "echo x > \$HOME/.claude/settings.json.new-1"

# ---- git MCP from below the work tree's top ----
gitmcp $d git_reset "{\"path\":\"$LIVE/.archive\",\"mode\":\"hard\"}"
gitmcp $p git_clone "{\"url\":\"u\",\"path\":\"$LIVE/.archive/newclone\"}"
gitmcp $d git_clone "{\"url\":\"u\",\"path\":\"$LIVE/sub\"}"

# ---- chmod modes that start with a dash, sed and perl in place, patch, curl and wget ----
bash_ $d "chmod -x $LIVE/hooks/guard.sh"
bash_ $d "chmod -R a-w $LIVE/tools"
bash_ $d "chmod -R -x $LIVE/tools"
bash_ $p "chmod -x $CLONE/tools/a.ts" "$LIVE"
bash_ $p "sed -i '' 's/a/b/' $CLONE/tools/a.ts" "$LIVE"
bash_ $d "sed -i '' 's/a/b/' $LIVE/tools/a.ts" "$CLONE"
bash_ $p "perl -i.bak -pe 's/a/b/' $CLONE/tools/a.ts" "$LIVE"
bash_ $d "perl -i.bak -pe 's/a/b/' $LIVE/tools/a.ts" "$CLONE"
bash_ $p "perl -Mstrict -ne print $LIVE/tools/a.ts" "$CLONE"
bash_ $p "perl -Mstrict -ne print a.ts" "$LIVE"
bash_ $d "patch -p1 -d $LIVE < x.diff" "$CLONE"
bash_ $p "patch -d $CLONE -p1 < x.diff" "$LIVE"
bash_ $d "curl -fsSLo $LIVE/tools/x https://example.invalid/x" "$CLONE"
bash_ $d "wget -qO $LIVE/x https://example.invalid/x" "$CLONE"
bash_ $p "wget -qO- https://example.invalid/x" "$LIVE"
bash_ $p "wget -O - https://example.invalid/x" "$LIVE"
bash_ $p "curl -fsSLo - https://example.invalid/x" "$LIVE"

# ---- find with exec ----
bash_ $p "find . -name '*.sh' -exec sed -n 1p {} +" "$LIVE"
bash_ $p "find . -exec bash -n {} \\;" "$LIVE"
bash_ $d "find $LIVE -name '*.sh' -exec rm {} \\;"
bash_ $d "find -L $LIVE -delete"
bash_ $d "find . -name '*.sh' -exec sed -i s/a/b/ {} +" "$LIVE"

# ---- wrappers that take an option value, and cd options ----
bash_ $d "sudo -u u rm $LIVE/tools/a.ts"
bash_ $d "env -u NAME rm $LIVE/tools/a.ts"
bash_ $d "timeout -s KILL 5 rm $LIVE/tools/a.ts"
bash_ $d "/usr/bin/env rm $LIVE/tools/a.ts"
bash_ $d "command -p rm $LIVE/tools/a.ts"
bash_ $d "cd -- $LIVE && touch x"
bash_ $d "cd -P $LIVE && touch x"
bash_ $p "cd -P $CLONE && touch x" "$LIVE"

# ---- a file created inside an existing folder ----
bash_ $d "cp $CLONE/settings.json $H/.claude/"
bash_ $d "cp $CLONE/settings.json ~/.claude/"
bash_ $d "mv $CLONE/settings.local.json $H/.claude"
bash_ $d "cp -t $H/.claude $CLONE/settings.json"
bash_ $d "cp --target-directory $H/.claude $CLONE/settings.json"
bash_ $d "cp --target-directory $LIVE/hooks $CLONE/x.sh"
bash_ $d "install -m 755 $CLONE/guard.sh $LIVE/hooks/"
bash_ $d "rsync -a $CLONE/settings.json $H/.claude/"
bash_ $d "ln -s $CLONE/settings.json $H/.claude/"
bash_ $d "cp x.json $LIVE/tools" "$CLONE"
bash_ $p "cp $CLONE/other.json $H/.claude/"
bash_ $p "cp $CLONE/settings.json $CLONE/tools/"
bash_ $p "mv $LIVE/.archive/task/settings.json $LIVE/.archive/"

# ---- a cd inside a group does not outlive it ----
bash_ $d "D=\$(cd $CLONE && pwd); touch y" "$LIVE"
bash_ $d "(cd /tmp); rm hooks/guard.sh" "$LIVE"
bash_ $d "x=\`cd $CLONE; pwd\`; touch y" "$LIVE"
bash_ $p "(cd $CLONE && touch x); echo ok" "$LIVE"
bash_ $p "D=\$(cd $CLONE && pwd); touch $CLONE/y" "$LIVE"

# ---- a control character in the command ----
ctl=$(printf '\001')
bash_ $d "echo '${ctl}'; touch $LIVE/x"
bash_ $d "echo \"${ctl}\"; rm $LIVE/.protected-checkout"
bash_ $p "echo 'a	b'
echo c"

# ---- long options with a separate value, wrapper options ----
bash_ $d "curl --output-dir $LIVE/tools -O https://example.invalid/x" "$CLONE"
bash_ $d "wget --directory-prefix $LIVE/tools https://example.invalid/y" "$CLONE"
bash_ $d "wget --output-document $LIVE/tools/x https://example.invalid/y" "$CLONE"
bash_ $d "curl -fsSLO https://example.invalid/x" "$LIVE"
bash_ $p "curl -XPOST -d a=1 https://example.invalid" "$LIVE"
bash_ $p "curl -fsSL -HOST:x https://example.invalid" "$LIVE"
bash_ $d "time -p rm $LIVE/tools/a.ts"
bash_ $d "time -p rm $LIVE/.protected-checkout"
bash_ $d "exec -a NAME rm $LIVE/tools/a.ts"
bash_ $d "sudo --user root rm $LIVE/tools/a.ts"
bash_ $d "env --unset X rm $LIVE/tools/a.ts"

# ---- the marker is what protects: a folder with no marker stays editable ----
file $p "$T/other/anything.txt" Write
bash_ $p "rm $T/other/anything.txt"

# ---- failure modes ----
expect $d "empty tool name" '{"tool_input":{}}'
expect $d "malformed input" 'not json'
SAVED_PATH=$PATH
NOJQ="$T/nojq"
mkdir -p "$NOJQ"
for b in cat dirname bash env; do p_=$(command -v $b) && ln -sf "$p_" "$NOJQ/$b"; done
out=$(printf '%s' "$(call Write "{\"file_path\":\"$CLONE/a\"}" "$CLONE")" | PATH="$NOJQ" HOME="$H" "$SH" "$T/hooks/protected-paths-guard.sh" 2>/dev/null)
if printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && printf '%s' "$out" | grep -q 'fail-closed'; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: no jq must deny (fail-closed): $out"; fi
PATH=$SAVED_PATH

# ---- the deny is valid JSON with a reason and names nothing project specific ----
out=$(printf '%s' "$(call Write "{\"file_path\":\"$LIVE/tools/a.ts\"}" "$CLONE")" | HOME="$H" "$SH" "$T/hooks/protected-paths-guard.sh" 2>/dev/null)
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
case "$reason" in
  protected-paths-guard:*"$LIVE"*".protected-checkout"*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL: deny reason shape: $reason" ;;
esac

# ---- a deny reaches the audit log when the logger sits beside the hook ----
if [ -f "$HERE/../../hooks/audit-logger.sh" ]; then
  cp "$HERE/../../hooks/audit-logger.sh" "$T/hooks/audit-logger.sh"
  printf '%s' "$(call Write "{\"file_path\":\"$LIVE/tools/a.ts\"}" "$CLONE")" | HOME="$H" "$SH" "$T/hooks/protected-paths-guard.sh" >/dev/null 2>&1
  LOG=$(ls "$CLONE"/.archive/audit/audit-*.log 2>/dev/null | head -1)
  if [ -n "$LOG" ] && jq -e 'select(.event == "deny" and .hook == "protected-paths-guard")' "$LOG" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: deny is not audited (log: ${LOG:-none})"; fi
else
  echo "skip: audit case (no audit-logger.sh beside the hook)"
fi

# ---- the settings command is fail-closed: a guard that cannot run blocks (exit 2), a deny or pass still exits 0 ----
TPL="$HERE/../../.claude/skills/setup-claude/templates/safe-permissions.json"
CMD=$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command | select(type == "string" and test("protected-paths-guard[.]sh"))] | first // empty' "$TPL" 2>/dev/null)
mkhome() {  # mkhome <name> <install: link|nolib|crash|none>: a HOME whose hooks/protected-paths-guard.sh links to the guard (nolib: a copy with no lib beside it), a crashing stub, or absent
  mkdir -p "$T/$1/.claude/hooks"
  case $2 in
    link) ln -s "$T/hooks/protected-paths-guard.sh" "$T/$1/.claude/hooks/protected-paths-guard.sh" ;;
    nolib) mkdir -p "$T/$1/bare" && cp "$HOOK" "$T/$1/bare/" && ln -s "$T/$1/bare/protected-paths-guard.sh" "$T/$1/.claude/hooks/protected-paths-guard.sh" ;;
    crash) printf '#!/bin/bash\nexit 1\n' >"$T/$1/.claude/hooks/protected-paths-guard.sh" ;;
  esac
}
runcmd() {  # runcmd <home name> <stdin json>: sets RC and OUT from the template's command run under sh
  OUT=$(printf '%s' "$2" | HOME="$T/$1" /bin/sh -c "$CMD" 2>/dev/null)
  RC=$?
}
check() {  # check <label> <want rc> <want deny: yes|no>
  local got=no
  [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = deny ] && got=yes
  if [ "$RC" = "$2" ] && [ "$got" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: rc $RC (want $2), deny $got (want $3)"; fi
}
if [ -z "$CMD" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: the template has no protected-paths-guard.sh hook command"
else
  mkhome hw link
  runcmd hw "$(call Write "{\"file_path\":\"$LIVE/tools/a.ts\"}" "$CLONE")"
  check "settings command: a deny still reaches Claude Code with exit 0" 0 yes
  runcmd hw "$(call Write "{\"file_path\":\"$CLONE/tools/a.ts\"}" "$CLONE")"
  check "settings command: a pass exits 0 with no deny" 0 no
  [ -z "$OUT" ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: settings command: a pass prints nothing: $OUT"; }
  mkhome hm none
  runcmd hm "$(call Write "{\"file_path\":\"$CLONE/tools/a.ts\"}" "$CLONE")"
  check "settings command: a missing hook link blocks with exit 2" 2 no
  mkhome hl nolib
  runcmd hl "$(call Write "{\"file_path\":\"$CLONE/tools/a.ts\"}" "$CLONE")"
  check "settings command: a missing lib beside the linked hook blocks with exit 2" 2 no
  mkhome hc crash
  runcmd hc "$(call Write "{\"file_path\":\"$CLONE/tools/a.ts\"}" "$CLONE")"
  check "settings command: a hook that exits non-zero blocks with exit 2" 2 no
fi

echo "protected-paths-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
