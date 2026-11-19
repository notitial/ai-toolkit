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
mkdir -p "$T/sp ace/r/tools"
: >"$T/sp ace/r/.protected-checkout"
mkdir -p "$LIVE/.git" "$CLONE/.git" "$LIVE/.archive/c1/.git" "$H/.claude/hooks" "$LIVE/tools" "$LIVE/hooks" "$LIVE/.archive/task" "$CLONE/tools" "$STATE/sub" "$T/other"
mkdir -p "$T/many"; for k in $(seq 1 90); do : >"$T/many/f$k"; done
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

# ---- case-folded verbs ----
bash_ $d "RM -f $LIVE/tools/a.ts"
bash_ $d "Cp /tmp/x $LIVE/tools/a.ts"
bash_ $d "find $LIVE/tools -exec RM {} +"
# ---- one name repeated tens of thousands of times: each word was cheap alone, and 100 KB of them took 5 s, 400 KB passed the 10 s timeout ----
# (the text goes in on stdin: it is too long for an argument). A name that exists in the session folder counts once; the clock is checked per word.
# Only the time is pinned: the decision (a deny at the 6 s budget, or a pass on a quick machine) depends on the machine.
t0=$SECONDS
got=$(awk 'BEGIN { printf "echo $(date) "; for (i = 0; i < 60000; i++) printf "tools "; print "; touch x" }' \
  | jq -Rs --arg w "$CLONE" '{tool_name: "Bash", tool_input: {command: .}, cwd: $w}' | HOME="$H" "$SH" "$T/hooks/protected-paths-guard.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "pass"')
if [ $((SECONDS - t0)) -lt 9 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: 60000 repeated names took $((SECONDS - t0)) s (limit 9; got $got)"; fi
# ---- ~+ and ~user, and a glob in the last component of a name in ~/.claude ----
bash_ $d "cp /tmp/x ~+/a.ts" "$LIVE/tools"
bash_ $p "cp /tmp/x ~+/a.ts" "$CLONE/tools"
bash_ $d "cp /tmp/x ~+/../hooks/guard.sh" "$LIVE/tools"
bash_ $p "cp /tmp/x ~-/a.ts" "$LIVE/tools"
bash_ $p "cp /tmp/x ~nosuchaccount-zz/.claude/settings.json"
bash_ $p "cp /tmp/x ~'a b'/x"
bash_ $d "cp /tmp/x ~/.claude/settings.js?n"
bash_ $d "cp /tmp/x ~/./.claude/settings.js?n"
bash_ $d "cp /tmp/x ~//.claude/settings.*"
bash_ $d "cp /tmp/settings.json ~/.claude/"
bash_ $d "cp /tmp/x ~/.claude/settings.*"
bash_ $d "rm -f ~/.claude/settings*"
bash_ $d "rm -f ~/.claude/*"
bash_ $d "touch \"$H\"/.claude/settings.local.js?n"
bash_ $p "touch ~/.claude/settings.json.bak-*"
bash_ $p "rm -f ~/.claude/hooks/*"
bash_ $p "touch ~/.claude/nosuchfile*"
bash_ $d "touch ~/.claude/*a*a*a*b"
bash_ $d "touch ~/.claude/$(printf 'a%.0s' $(seq 1 65))*"
bash_ $d "touch ~/.claude/\"x *a*a*a*a*a*a*a*a*a*a*a*b\"; cp /tmp/x ~/.claude/settings.json"
bash_ $p "cp /tmp/x ~0/a"
bash_ $p "cp /tmp/x ~+2/a"
bash_ $p "cp /tmp/x $CLONE/tools/*.ts"
# ~user: the shell looks the account up, so these run with HOME set to the current account's own home (no audit log is in the test copy)
ME=$(id -un)
MYHOME=$(eval "echo ~$ME")
if [ -d "$MYHOME" ] && [ "$MYHOME" != "/" ]; then
  H_SAVE=$H
  H=$MYHOME
  bash_ $d "cp /tmp/x ~$ME/.claude/settings.json"
  bash_ $d "cp /tmp/x ~$ME/.claude/settings.js?n"
  bash_ $d "cp /tmp/settings.json ~$ME/.claude/"
  bash_ $p "cp /tmp/x ~$ME/.claude/nosuchfile-zz"
  H=$H_SAVE
fi
# ---- substitutions: the text is denied when it could touch a protected place, whatever the parse says ----
# (many of the shapes below are also denied by the parser alone, so they pin that the deny stays; the ones only sub_guard
# denies are the read-only, glued-continuation, $''(, =( ), ~/.claude, relative and cwd ones near the end of this block)
bash_ $d "cp \"\$(mktemp)\" $LIVE/tools/a.ts"
bash_ $d "cp \$(mktemp) $LIVE/tools/a.ts"
bash_ $d "cp \`mktemp\` $LIVE/tools/a.ts"
bash_ $d "Cp \"\$(mktemp)\" $LIVE/tools/a.ts"
bash_ $d "mv \"\$(mktemp)\" $LIVE/tools/a.ts"
bash_ $d "touch \"\$(mktemp)\" $LIVE/tools/a.ts"
bash_ $d "echo x | tee \"\$(mktemp)\" $LIVE/tools/a.ts"
bash_ $d "echo x > $LIVE/tools/a.ts \$(date)"
bash_ $d "echo$(printf '\044')(case x in x) rm -f $LIVE/tools/a.ts;; esac)"
bash_ $d "echo\$(case x in x) rm -f $LIVE/tools/a.ts;; esac)"
bash_ $d "cat<(case x in x) rm -f $LIVE/tools/a.ts;; esac)"
bash_ $d "x>(case x in x) rm -f $LIVE/tools/a.ts;; esac)"
bash_ $d "echo \"\$(case x in x) rm -f $LIVE/tools/a.ts;; esac)\""
bash_ $d "(echo \$(case x in x) rm -f $LIVE/tools/a.ts;; esac))"
bash_ $d "cd /tmp; (echo \`case x in x) rm -f $LIVE/tools/a.ts;; esac\`)"
bash_ $d "bash -c 'cp /tmp/x \`)\` ~/.claude/settings.json'"
bash_ $d "bash -c 'cp /tmp/x \`)\` $H/.claude/settings.json'"
bash_ $d "bash -c 'cp /tmp/x \`: '\"'\"'\` $LIVE/tools/a.ts \`: '\"'\"'\`'"
bash_ $d "bash -c 'cp /tmp/x \`(\` \$HOME/.claude/settings.json'"
bash_ $d "sh -c 'echo \$(date); rm -f \${HOME}/.claude/settings.json'"
bash_ $d "echo \$(a) ; r\"\"m -f $LIVE/tools/a.ts"
bash_ $d "echo \$(a) ; rm -f $LIVE/tools/\"a\".ts"
bash_ $d "echo \$(a) ; rm -f '$LIVE/tools/a.ts'"
bash_ $d "env -S 'cp /tmp/x' $LIVE/tools/a.ts"
bash_ $d "env -S 'cp /tmp/x' ~/.claude/settings.json"
bash_ $d "echo \$(date) ; rm -f \$(ls)" "$LIVE"
bash_ $d "rm -f \$(ls)" "$LIVE/tools"
bash_ $d "echo \`date\` > out.txt" "$LIVE"
bash_ $d "rm\$(x) a.ts" "$LIVE/tools"
bash_ $d "\$(x)rm a.ts" "$LIVE/tools"
bash_ $d "Rm \$(x) a.ts" "$LIVE/tools"
bash_ $d "echo \$(date); /bin/rm hooks/guard.sh" "$LIVE"
bash_ $d "echo \$(date); /bin/RM hooks/guard.sh" "$LIVE"
bash_ $d "echo \$(case x in x) :;; esac); tar -xf a.tar -C$LIVE/tools"
bash_ $d "echo \$(case x in x) :;; esac); unzip a.zip -d$STATE/sub"
bash_ $d "echo \$(case x in x) :;; esac); cp /tmp/x settings.json" "$H/.claude"
bash_ $d "echo \$(case x in x) :;; esac); cd $LIVE/../live; rm hooks/x.sh"
bash_ $d "echo \$(case x in x) :;; esac); cd ../live; rm hooks/x.sh" "$T/other"
bash_ $d "echo \$(date) >>/dev/null; rm -f a.ts" "$LIVE/tools"
bash_ $d "echo =(date) > x" "$LIVE"
bash_ $d "cat =(date) $LIVE/tools/a.ts"
bash_ $d "git commit -m \"\$(cat <<'EOF'
fix: say rm tools/a.ts and echo x > b
EOF
)\" --allow-empty" "$LIVE"
bash_ $p "echo \$(date) >>/dev/null" "$LIVE"
bash_ $p "echo \$(date) > /dev/null" "$LIVE"
bash_ $p "echo \$(date) 2>> /dev/null" "$LIVE"
bash_ $p "echo \$(date); cat settings.json" "$H/.claude"
bash_ $p "echo \$(date); cp /tmp/x ../clone/a.ts" "$CLONE/tools"
NL=$'\n'
bash_ $d "echo \"\$\\${NL}(rm -f $LIVE/tools/a.ts)\""
bash_ $d "eval 'echo \"\$''(case x in x) rm -f $LIVE/tools/a.ts;; esac)\"'"
bash_ $d "cat $LIVE/tools/a.ts; eval 'echo \"\$''(date)\"'"
bash_ $d "cat \$(ls) $LIVE/tools/a.ts"
bash_ $p "cat $LIVE/tools/a.ts"
bash_ $p "echo \"Done... \$(date)\"" "$LIVE"
bash_ $p "cd .. && cp \$(x) y" "$H/proj"
bash_ $p "find . -name a \$(x)" "$CLONE"
bash_ $p "curl -s https://\$(cat /tmp/h)/api"
bash_ $d "cd .. && cp \$(x) y" "$LIVE/tools"
bash_ $d "cp \"\$(mktemp)\" \$'$LIVE/tools/a.ts'"
bash_ $d "curl -fsSL \"\$(cat /tmp/u)\" -o$LIVE/tools/a.ts"
bash_ $d "cp \"\$(git rev-parse --show-toplevel)/.claude/settings.json\" ~/.claude/"
bash_ $d "cp \"\$(pwd)/settings.json\" $H/.claude/"
bash_ $d "ln -sf \"\$(pwd)/settings.json\" \$HOME/.claude/"
bash_ $d "rm -rf \"\$(mktemp -d)\" ~/.claude"
bash_ $d "echo \$(date); cp /tmp/x ../live/tools/b.ts" "$CLONE"
bash_ $d "echo \$(date); cp /tmp/x live/tools/b.ts" "$T"
bash_ $p "echo \$(date); cp /tmp/x clone/tools/b.ts" "$T"
bash_ $p "cp \"\$(mktemp)\" ~/notes.txt"
bash_ $p "ls -la \$(pwd) ~/.claude"
bash_ $p "sed -i '' \"s/0\\.1\\.0/\$(cat VERSION)/\" package.json" "$CLONE"
bash_ $p "cp build.log \"\$(mktemp -d)/\"" "$CLONE"
bash_ $p "echo \$((n / 2)) > half.txt" "$CLONE"
bash_ $p "cat <<'EOF' > $CLONE/n.txt
$(printf 'word%s /tmp/a/b ' $(seq 1 300))
\$(date)
EOF" "$CLONE"
# the work is bounded by the words judged (80 a call, about 40 ms each; past the hook's 10 s timeout a call goes through): the 81st is denied
bash_ $p "cp \$(x) y; $(printf ' /tmp/a%s' $(seq 1 60))" "$CLONE"
bash_ $d "cp \$(x) y; $(printf ' /tmp/a%s' $(seq 1 85))" "$CLONE"
bash_ $d "cp \$(x) y; $(printf ' /tmp/a%s' $(seq 1 320))" "$CLONE"
bash_ $p "cp \$(x) y; $(printf ' "/tmp/a b/%s"' $(seq 1 30))" "$CLONE"
bash_ $d "cp \$(x) y; $(printf ' "/tmp/a b/%s"' $(seq 1 100))" "$CLONE"
bash_ $d "cp \$(x) y; $(printf ' "/tmp/a b/%s"' $(seq 1 45)) $(printf ' /tmp/c%s' $(seq 1 45))" "$CLONE"
bash_ $d "cp \$(x) y; $(printf ' f%s' $(seq 1 90))" "$T/many"
bash_ $p "cp \$(x) y; $(printf ' f%s' $(seq 1 40))" "$T/many"
bash_ $d "chmod 600 $(printf ' /tmp/a%s' $(seq 1 85))" "$CLONE"
bash_ $p "chmod 600 $(printf ' /tmp/a%s' $(seq 1 60))" "$CLONE"
# the limit counts distinct words: a word judged twice (sub_guard and the parse) or a /dev/ target costs nothing extra
bash_ $p "chmod 600 \$(x) $(printf ' /tmp/a%s' $(seq 1 45))" "$CLONE"
bash_ $p "chmod 600 $(printf ' /tmp/a%s' $(seq 1 80))" "$CLONE"
bash_ $d "chmod 600 $(printf ' /tmp/a%s' $(seq 1 81))" "$CLONE"
bash_ $p "echo hi $(printf ' 2>/dev/null%.0s' $(seq 1 90))" "$CLONE"
# a word that holds the separator of a string of seen words must not hide a later target (the seen words are compared whole)
bash_ $d "touch '/tmp/x|$LIVE|0|hooks/g.sh'; cd $LIVE; touch hooks/g.sh" "$CLONE"
bash_ $d "touch /tmp/$(printf 'a/%.0s' $(seq 1 600))x" "$CLONE"
bash_ $p "echo \$(x) $(printf ' 2>&1%.0s' $(seq 1 900))" "$CLONE"
# many capitalised bare words plus a substitution, then a write to a protected path: denied well inside the hook's 10 s timeout
# (a fork per capitalised word took 13 s, and a call past the timeout goes through)
t0=$SECONDS
bash_ $d "echo \$(date) $(printf 'A %.0s' $(seq 1 4500)); cp /tmp/x $LIVE/tools/a.ts" "$CLONE"
if [ $((SECONDS - t0)) -lt 8 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: 4500 capitalised words took $((SECONDS - t0)) s (limit 8)"; fi
# the same for a find with many -exec of a capitalised word (a fork each): the clock budget denies it
t0=$SECONDS
bash_ $d "find /tmp $(printf -- '-exec Ab {} \\; %.0s' $(seq 1 3000)); cp /tmp/x $LIVE/tools/a.ts" "$CLONE"
if [ $((SECONDS - t0)) -lt 8 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: 3000 find -exec words took $((SECONDS - t0)) s (limit 8)"; fi
# mkfifo and mknod are write verbs for a text with a substitution too
bash_ $d "mkfifo \$(mktemp -u)" "$LIVE"
bash_ $d "echo \$(date); mknod x p" "$LIVE"
bash_ $p "mkfifo \$(mktemp -u)" "$CLONE"
bash_ $d "bash -c 'cd live; cp /tmp/x \`: '\"'\"'\` tools/a.ts \`: '\"'\"'\`'" "$T"
bash_ $d "tar -xf a.tar \`: '\"'\"'\` -C live \`: '\"'\"'\`" "$T"
bash_ $d "bash -c 'cp /tmp/x \`: '\"'\"'\` \"$T/sp ace/r/tools/a.ts\" \`: '\"'\"'\`'" "$T"
bash_ $d "cp \"\$(mktemp)\" \"$T/sp ace/r/tools/a.ts\" /tmp/y" "$T"
bash_ $p "bash -c 'cd other; cp /tmp/x \`: '\"'\"'\` tools/a.ts \`: '\"'\"'\`'" "$T"
bash_ $p "cd live; echo \$(date)" "$T"
bash_ $p "cp \"\$(mktemp)\" \"$T/sp ace/x y\"" "$T"
bash_ $p "echo \$(date)"
bash_ $p "ls \$(pwd) | head"
bash_ $p "cp \"\$(mktemp)\" $CLONE/tools/b.ts"
bash_ $p "rm -f \$(ls) $CLONE/tools/b.ts"
bash_ $p "echo \`date\` > $CLONE/out.txt"
bash_ $p "bash -c 'echo \$(date); cp /tmp/x $CLONE/tools/b.ts'"
bash_ $p "cp \"\$(mktemp)\" $LIVE/.archive/x.md"
bash_ $p "rm -f \$(ls)" "$CLONE"
bash_ $p "cat \$(ls)" "$LIVE"
bash_ $p "echo \$(date) 2>&1 | head" "$LIVE"
bash_ $p "ls \$(pwd) >/dev/null" "$LIVE"
bash_ $p "rm -f \$(ls)" "$LIVE/.archive/task"
bash_ $p "rm -f \$(ls) ~/.claude/state-new/x" "$CLONE"

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
bash_ $d "mkfifo $LIVE/hooks/x.sh"
bash_ $d "mkfifo -m 600 $LIVE/hooks/x.sh"
bash_ $d "mkfifo --mode=600 $LIVE/hooks/x.sh"
bash_ $d "mkfifo --mode 600 $LIVE/hooks/x.sh"
bash_ $d "mkfifo $CLONE/tools/ok $LIVE/hooks/x.sh"
bash_ $d "mknod $LIVE/hooks/x.sh p"
bash_ $d "mknod -m 600 $LIVE/hooks/x.sh c 1 3"
bash_ $d "MKFIFO $LIVE/hooks/x.sh"
bash_ $d "Mknod $LIVE/hooks/x.sh p"
bash_ $d "mkfifo '$LIVE/hooks/x.sh'"
bash_ $d "mkfifo \"$LIVE/hooks/x.sh\""
bash_ $d "mkfifo $LIVE/hooks/x.sh \"\$(mktemp -u)\""
bash_ $d "mkfifo \"\$(mktemp -u)\" $LIVE/hooks/x.sh"
bash_ $d "mkfifo $LIVE/hooks/x.sh \`mktemp -u\`"
bash_ $d "mkfifo -Z $LIVE/hooks/x.sh"
bash_ $d "mkfifo --context $LIVE/hooks/x.sh"
bash_ $d "mkfifo --context=u:object_r:tmp_t $LIVE/hooks/x.sh"
bash_ $d "mkfifo -- $LIVE/hooks/x.sh"
bash_ $d "mkfifo -Zm 600 $LIVE/hooks/x.sh"
bash_ $d "mknod -Z $LIVE/hooks/x.sh p"
bash_ $d "mknod -Zm 600 $LIVE/hooks/x.sh p"
bash_ $d "mknod -g 0 $LIVE/hooks/x.sh p"
bash_ $d "mknod -u 0 -g 0 $LIVE/hooks/x.sh c 1 3"
bash_ $d "mknod p $LIVE/hooks/x.sh"
bash_ $d "mkfifo /tmp/a -m $LIVE/hooks/x.sh"
bash_ $d "mkfifo /tmp/a --mode $LIVE/hooks/x.sh"
bash_ $d "mkfifo /tmp/a --target-directory $LIVE/hooks/x.sh"
bash_ $d "mknod /tmp/a -m $LIVE/hooks/x.sh"
bash_ $d "mknod p p" "$LIVE"
bash_ $d "mknod 0 p" "$LIVE"
bash_ $d "mknod -m 600 1 p" "$LIVE"
bash_ $d "mknod -Zm 600 12 p" "$LIVE"
bash_ $d "mknod /tmp/x 12x" "$LIVE"
bash_ $d "mkfifo -- -x" "$LIVE"
bash_ $d "mkfifo -" "$LIVE"
bash_ $d "mknod - p" "$LIVE"
bash_ $d "mknod 12x $LIVE/hooks/x.sh"
bash_ $d "cd $CLONE && mkfifo $LIVE/hooks/x.sh"
bash_ $d "mkfifo hooks/x.sh" "$LIVE"
bash_ $d "mknod hooks/x.sh p" "$LIVE"
bash_ $d "sudo mkfifo $LIVE/hooks/x.sh"
bash_ $d "env X=1 mknod $LIVE/hooks/x.sh p"
bash_ $d "bash -c 'mkfifo $LIVE/hooks/x.sh'"
bash_ $d "cd $LIVE && mkfifo hooks/x.sh"
bash_ $d "find $LIVE/hooks -name '*.sh' -exec mkfifo {} +"
bash_ $d "xargs mkfifo $LIVE/hooks/x.sh"
bash_ $p "mkfifo $CLONE/tools/pipe" "$LIVE"
bash_ $p "mkfifo -Z $CLONE/tools/pipe" "$LIVE"
bash_ $p "mkfifo /tmp/pipe"
bash_ $p "mknod /tmp/x p"
bash_ $p "mkfifo -m 600 /tmp/x"
bash_ $p "mkfifo --mode 600 /tmp/x"
bash_ $p "mknod -m 600 /tmp/x p"
bash_ $p "mknod -Zm 600 /tmp/x p"
bash_ $p "mknod -F native /tmp/x c 1 2"
bash_ $p "mknod $CLONE/tools/node p"
bash_ $p "mknod -Z $CLONE/tools/node c 1 3"
bash_ $p "mknod -g 0 $CLONE/tools/node c 1 3"
# every operand word is judged, so from the protected folder a mode value or a type word counts as a name in it (a false deny)
bash_ $d "mknod /tmp/x p" "$LIVE"
bash_ $d "mkfifo -m 600 /tmp/x" "$LIVE"
bash_ $d "mknod -F native /tmp/x c 1 2" "$LIVE"
# an option with its value attached, or a long option cut short, must not hide the target
bash_ $d "mkfifo -m=u $LIVE/hooks/x.sh"
bash_ $d "mkfifo -mo=u $LIVE/hooks/x.sh"
bash_ $d "mknod -mo=u $LIVE/hooks/x.sh p"
bash_ $d "mknod --mo 600 $LIVE/hooks/x.sh p"
bash_ $d "M=600; mknod --mo \"\$M\" p p" "$LIVE"
bash_ $d "mknod --mo \"\$(printf 600)\" 12 p" "$LIVE"
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
bash_ $d "env -S 'rm -f' $LIVE/tools/a.ts"
bash_ $d "env -S'rm -f' $LIVE/tools/a.ts"
bash_ $d "env --split-string='rm -f' $LIVE/tools/a.ts"
bash_ $p "env -S 'rm -f' $CLONE/tools/a.ts"
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
# the words around a substitution stay with their command: a write verb is judged on all its operands
bash_ $d "cp \"\$(mktemp)\" $H/.claude/settings.json"
bash_ $d "cp \`mktemp\` $H/.claude/settings.json"
bash_ $d "cp -a /tmp/x \"\$(mktemp -d)/sub\" $LIVE/tools/a.ts"
# regression guards: a redirect after a substitution was already judged
bash_ $d "echo \"\$(date)\" >> $LIVE/tools/a.ts"
bash_ $d "rm -f \"\$(mktemp)\" $LIVE/tools/a.ts"
bash_ $d "mv \"\$(pwd)/x\" $LIVE/tools/a.ts"
bash_ $d "tee \"\$(mktemp)\" $LIVE/tools/a.ts </dev/null"
bash_ $d "cp <(mktemp) $LIVE/tools/a.ts"
bash_ $d "touch \"\$(mktemp -d)/x\" $LIVE/tools/new"
bash_ $d "RM $LIVE/tools/a.ts"
bash_ $d "Cp x $LIVE/tools/a.ts"
# a group's end is exact or the text is refused (a case pattern's ) and a paren inside ${ } are no group end): all of these deny
# either way, and the first three also pin that a plain substitution's inner command is judged
bash_ $d "echo \$(rm -f $LIVE/tools/a.ts)"
bash_ $d "echo \`rm -f $LIVE/tools/a.ts\` x"
bash_ $d "x=\$(cat f; rm -f $LIVE/tools/a.ts)"
bash_ $d "echo \`case x in x) rm -f $LIVE/tools/a.ts;; esac\`"
bash_ $d "echo \$(case x in y) echo esac;; x) rm -f $LIVE/tools/a.ts;; esac)"
bash_ $d "echo \$(\"case\" x in x) rm -f $LIVE/tools/a.ts;; esac)"
bash_ $d "echo \$(time case x in x) rm -f $LIVE/tools/a.ts;; esac)"
bash_ $d "echo\$(case x in x) rm -f $LIVE/tools/a.ts;; esac)"
bash_ $d "cat<(case x in x) rm -f $LIVE/tools/a.ts;; esac)"
bash_ $d "x>(case x in x) rm -f $LIVE/tools/a.ts;; esac)"
bash_ $d "echo \"\$(case x in x) rm -f $LIVE/tools/a.ts;; esac)\""
bash_ $d "cd /tmp; (cd $LIVE/tools; case x in x) rm -f a.ts;; esac)"
bash_ $d "\$(true)rm -rf $LIVE/tools/a.ts"
bash_ $d "\`:\`rm -f $LIVE/tools/a.ts"
bash_ $d "\"\$(:)\"rm -f $LIVE/tools/a.ts"
bash_ $d "sudo \$(:)rm -f $LIVE/tools/a.ts"
bash_ $d "\$(:)bash -c 'rm -f $LIVE/tools/a.ts'"
bash_ $d "eval \$(:)rm -f $LIVE/tools/a.ts"
bash_ $d "\$(:)cd $LIVE/tools; rm -f a.ts"
bash_ $d "echo \$(eval \"\${x:+\")\"}\" rm -f $LIVE/tools/a.ts)"
bash_ $d "echo \`#\` ; rm -f $LIVE/tools/a.ts"
bash_ $p "\$(true)rm -f $CLONE/tools/a.ts" "$CLONE"
bash_ $d "\$(true)rm -f $CLONE/tools/a.ts" "$LIVE"
bash_ $d "cd /tmp; (cd $LIVE/tools; echo \$(echo \${x:-a )}); rm -f a.ts)"
bash_ $d "rm\$(echo \${x#(}) -rf $LIVE/tools/a.ts"
bash_ $d "echo \`echo \\\`case x in x) rm -f $LIVE/tools/a.ts;; esac\\\`\`"
bash_ $d "(echo \$(case x in x) rm -f $LIVE/tools/a.ts;; esac); cd /tmp)"
bash_ $d "echo \$(echo \${x/)/} rm -f $LIVE/tools/a.ts)"
bash_ $p "echo \$(date) && rm -f $CLONE/tools/a.ts" "$CLONE"
bash_ $d "echo \$(date) && rm -f $CLONE/tools/a.ts" "$LIVE"
bash_ $p "case x in x) rm -f $CLONE/tools/a.ts;; esac" "$LIVE"
bash_ $p "echo \$(echo \${x:-a} b) c; touch $CLONE/x" "$CLONE"
bash_ $d "echo \$(echo \${x:-a} b) c; touch $CLONE/x" "$LIVE"
bash_ $p "cp \"\$(mktemp)\" $CLONE/tools/a.ts"
bash_ $p "rm \"\$(mktemp)\""
bash_ $p "rm -f \"\$(mktemp)\" \"\$(mktemp)\""
bash_ $p "echo \"\$(date)\" > $CLONE/n.txt"
bash_ $p "cp \"\$(mktemp)\" /tmp/out.txt"
bash_ $p "mkdir -p \"\$(mktemp -d)/a\" \"\$(date +%s)\""
bash_ $d "ls \"\$(pwd)\" $LIVE/tools"
bash_ $p "ls \"\$(pwd)\" $CLONE/tools"
bash_ $d "cat \"\$(mktemp)\" $LIVE/tools/a.ts | wc -l"
bash_ $p "cat $LIVE/tools/a.ts | wc -l"
bash_ $p "RM -f $CLONE/tools/a.ts"
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
bash_ $d "git commit -m \"\$(cat <<'EOF'
fix: say rm $LIVE/tools/a.ts and echo x > $LIVE/b
EOF
)\" --allow-empty" "$CLONE"
bash_ $p "git commit -m \"\$(cat <<'EOF'
fix: say rm tools/a.ts and echo x > b
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
bash_ $d "D=\$(cd $CLONE && pwd); touch $CLONE/y" "$LIVE"
bash_ $p "D=\$(cd $CLONE && pwd); touch $CLONE/y" "$CLONE"

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
