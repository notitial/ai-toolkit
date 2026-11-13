#!/usr/bin/env bash
# test-guard.sh: behaviour tests for hooks/workspace-lock-guard.sh.
#
# The guard runs on every Edit, Write, Bash and git-mcp call, so a parse error in it would block
# every session on the machine. Each case feeds it one hook input and checks the decision: the
# guard prints nothing to allow and a JSON permissionDecision of deny or ask otherwise, and it
# always exits 0.
#
#   GUARD=<path>   hook under test (default: the one beside this checkout)
#
# The sandbox lives under $TMPDIR, which the guard treats as scratch for Bash, so cases that must
# hit the workspace use relative paths.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
GUARD="${GUARD:-$HERE/../../hooks/workspace-lock-guard.sh}"
GUARD_BASH="${GUARD_BASH:-/bin/bash}"   # the hook runs under macOS's bash 3.2
LOCKNAME=.workspace-lock
[ -r "$GUARD" ] || { echo "no guard at $GUARD" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

PASS=0; FAIL=0
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/lockguard-XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

# run <allow|deny|ask> <label> <json>. The environment the guard reads is scrubbed, so the caller's
# shell cannot change a result; a case that needs a value sets EXTRA_ENV.
run() {
  _out=$(printf '%s' "$3" | env -u WORKSPACE_LOCK_DIR -u WORKSPACE_LOCK_ID -u WORKSPACE_LOCK_BYPASS \
    -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_ENTRYPOINT -u WORKSPACE_LOCK_WEDGE_GRACE ${EXTRA_ENV:+$EXTRA_ENV} \
    "$GUARD_BASH" "$GUARD" 2>/dev/null)
  _status=$?
  if [ "$_status" != 0 ]; then echo "FAIL  $2 - guard exited $_status"; FAIL=$((FAIL + 1)); return; fi
  case "$_out" in
    *'"permissionDecision": "deny"'*|*'"permissionDecision":"deny"'*) _got=deny ;;
    *'"permissionDecision": "ask"'*|*'"permissionDecision":"ask"'*) _got=ask ;;
    *) _got=allow ;;
  esac
  if [ "$_got" = "$1" ]; then PASS=$((PASS + 1))
  else echo "FAIL  $2 - expected $1, got $_got"; [ -n "$_out" ] && echo "      $_out"; FAIL=$((FAIL + 1)); fi
}
has_reason() {
  case "$_out" in *"$1"*) PASS=$((PASS + 1)) ;; *) echo "FAIL  $2 - '$1' not in the reason"; FAIL=$((FAIL + 1)) ;; esac
}
logline_has() {  # <lock-dir> <text> <label>
  if grep -qF -- "$2" "$1/workspace-lock.log" 2>/dev/null; then PASS=$((PASS + 1)); else echo "FAIL  $3 - '$2' not in the log"; FAIL=$((FAIL + 1)); fi
}
logline_absent() {
  if grep -qF -- "$2" "$1/workspace-lock.log" 2>/dev/null; then echo "FAIL  $3 - '$2' in the log"; FAIL=$((FAIL + 1)); else PASS=$((PASS + 1)); fi
}

# mkws <name> [holder] [sid]: a workspace, optionally with a held lock and a registered session.
mkws() {
  _w="$SANDBOX/$1"; mkdir -p "$_w"
  if [ -n "${2:-}" ]; then
    mkdir -p "$_w/$LOCKNAME/lock.d" "$_w/$LOCKNAME/sessions"
    printf '%s\n' "$2" > "$_w/$LOCKNAME/lock.d/holder"
    [ -n "${3:-}" ] && printf '%s\n' "$2" > "$_w/$LOCKNAME/sessions/$3"
  fi
  printf '%s' "$_w"
}
bashjson() { jq -nc --arg c "$1" --arg cmd "$2" --arg s "${3:-sess1}" \
  '{tool_name:"Bash",cwd:$c,session_id:$s,permission_mode:"default",tool_input:{command:$cmd}}'; }
bashjsonm() { jq -nc --arg c "$1" --arg cmd "$2" --arg m "$3" \
  '{tool_name:"Bash",cwd:$c,session_id:"sess1",permission_mode:$m,tool_input:{command:$cmd}}'; }
writejson() { jq -nc --arg c "$1" --arg f "$2" --arg s "${3:-sess1}" \
  '{tool_name:"Write",cwd:$c,session_id:$s,tool_input:{file_path:$f,content:"x"}}'; }
gmcpjson() { jq -nc --arg t "$1" --arg p "$2" --arg m "${3:-}" \
  '{tool_name:$t,cwd:$p,session_id:"s",tool_input:({path:$p}+(if $m=="" then {} else {mode:$m} end))}'; }

LS='$HOME/.claude/tools/workspace-lock.sh'

# --- Which workspace is guarded
W=$(mkws plain)
run allow "unarmed: Write"                 "$(writejson "$W" "$W/f.txt")"
run allow "unarmed: mutating Bash"         "$(bashjson "$W" "rm -rf ./f.txt")"
W="$SANDBOX/debris"; mkdir -p "$W/$LOCKNAME"; printf '{"state":"free"}\n' > "$W/$LOCKNAME/status.json"
run allow "a lock folder without lock.d does not arm" "$(bashjson "$W" "touch ./f.txt")"
W=$(mkws armed_solo solo-other)
run deny  "armed: Write by a non-holder"   "$(writejson "$W" "$W/f.txt" 0123456789abcdef)"
has_reason "acquire --id solo-01234567 " "the deny names the session's own solo id"
run deny  "armed: mutating Bash"           "$(bashjson "$W" "touch ./f.txt")"
run deny  "armed: nested target"           "$(writejson "$W" "$W/deep/f.txt")"
W=$(mkws armed_other other-team sessA); printf 'someone-else\n' > "$W/$LOCKNAME/sessions/sessA"
run deny  "held by another id"             "$(writejson "$W" "$W/f.txt" sessA)"
has_reason "held by 'other-team'" "the deny names the holder"
# A team holder and a session that never acquired: tell the user, join only as a named member.
W=$(mkws armed_team team-x-20261101)
run deny  "team run: Write by an unregistered session" "$(writejson "$W" "$W/f.txt")"
has_reason "a team run holds this workspace's lock" "the deny says a team run holds it"
has_reason "Tell the user. Don't take a solo id" "the deny says to tell the user, not take a solo id"
has_reason "only if your spawn prompt names you a member" "the deny limits joining to named members"
# The holder's phase text is quoted as its note: printable only, no quotes, 80 characters at most.
printf 'build \033[31mred\033[0m "quoted" %s\n' "$(printf 'x%.0s' $(seq 1 120))" > "$W/$LOCKNAME/lock.d/phase"
run deny  "team run: a noisy phase"        "$(writejson "$W" "$W/f.txt")"
has_reason "holder's note: \\\"build [31mred[0m quoted xxx" "the note keeps printable text without quotes"
case "$_out" in *$'\033'*|*'\u001b'*) echo "FAIL  the note drops control characters"; FAIL=$((FAIL + 1)) ;; *) PASS=$((PASS + 1)) ;; esac
_note=$(printf '%s' "$_out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | sed -n "s/.*holder's note: \"\([^\"]*\)\".*/\1/p")
[ "${#_note}" -le 80 ] && [ -n "$_note" ] && PASS=$((PASS + 1)) || { echo "FAIL  the note is cut to 80 characters (${#_note})"; FAIL=$((FAIL + 1)); }
# Below the workspace root with WORKSPACE_LOCK_DIR unset, the lock script would make a second lock.
W=$(mkws armed_sub solo-other); mkdir -p "$W/sub"
run deny  "below root: mutating Bash"      "$(bashjson "$W/sub" "touch ./f.txt")"
has_reason "WORKSPACE_LOCK_DIR is unset" "the deny says the env var is unset"
has_reason "Do not acquire here" "the deny says not to acquire from here"
run deny  "below root: acquire"            "$(bashjson "$W/sub" "$LS acquire --id solo-abc --eta 30m" sessS)"
has_reason "Do not acquire here" "acquire below the root is refused"
[ -e "$W/$LOCKNAME/sessions/sessS" ] && { echo "FAIL  a refused acquire does not register"; FAIL=$((FAIL + 1)); } || PASS=$((PASS + 1))
run allow "at the root: acquire"           "$(bashjson "$W" "$LS acquire --id solo-abc --eta 30m" sessS)"
EXTRA_ENV="WORKSPACE_LOCK_DIR=$W/$LOCKNAME"
run allow "below root with the env set: acquire" "$(bashjson "$W/sub" "$LS acquire --id solo-abc --eta 30m" sessT)"
EXTRA_ENV=""
W=$(mkws armed_mine mine-1 sessB)
run allow "the holder may Write"           "$(writejson "$W" "$W/f.txt" sessB)"
run allow "the holder may run anything"    "$(bashjson "$W" "npm test" sessB)"
EXTRA_ENV="WORKSPACE_LOCK_ID=mine-1"
run allow "WORKSPACE_LOCK_ID names the holder" "$(writejson "$W" "$W/f.txt" nobody)"
EXTRA_ENV=""
W=$(mkws armed_orphan ""); mkdir -p "$W/$LOCKNAME/lock.d"; : > "$W/$LOCKNAME/lock.d/holder"
run deny  "an empty holder denies everyone" "$(writejson "$W" "$W/f.txt")"
has_reason "orphaned" "the orphan deny says so"
# A lock inside .archive/ is debris, unless a .git marks a project archived there.
W=$(mkws arch_root); mkdir -p "$W/.archive/OLD/$LOCKNAME/lock.d"; echo x > "$W/.archive/OLD/$LOCKNAME/lock.d/holder"
run allow "a lock under .archive/ is skipped" "$(bashjson "$W/.archive/OLD" "touch ./f.txt")"
mkdir -p "$W/.archive/PROJ/$LOCKNAME/lock.d" "$W/.archive/PROJ/.git"; echo x > "$W/.archive/PROJ/$LOCKNAME/lock.d/holder"
run deny  "an archived project keeps its lock" "$(bashjson "$W/.archive/PROJ" "touch ./f.txt")"
# WORKSPACE_LOCK_DIR arms its own workspace, even while free, and is ignored elsewhere.
W=$(mkws env_ws); mkdir -p "$W/$LOCKNAME"
EXTRA_ENV="WORKSPACE_LOCK_DIR=$W/$LOCKNAME"
run deny  "env lock dir arms its workspace" "$(writejson "$W" "$W/f.txt")"
run allow "env lock dir ignores other trees" "$(writejson "$SANDBOX/plain" "$SANDBOX/plain/f.txt")"
EXTRA_ENV=""
# --repos entries are trimmed of spaces and trailing slashes, so a hand-typed list still guards each repo,
# and an empty entry (a,,b) is skipped, not read as a prefix of every path.
W=$(mkws team_ws team-r-20261103); R2=$(mkws repo2); R3=$(mkws repo3)
printf '%s\n' "$W,,$R2 ,$R3/" > "$W/$LOCKNAME/lock.d/repos"
EXTRA_ENV="WORKSPACE_LOCK_DIR=$W/$LOCKNAME"
run deny  "a --repos entry after a space guards its repo" "$(writejson "$R2" "$R2/f.txt")"
run deny  "a --repos entry with a trailing slash guards its repo" "$(writejson "$R3" "$R3/f.txt")"
run allow "--repos does not reach a repo it does not list" "$(writejson "$SANDBOX/plain" "$SANDBOX/plain/f.txt")"
EXTRA_ENV=""

# --- Reads a non-holder may run
W=$(mkws armed_read holder-x)
for c in "ls -la" "cat README.md" "head -n 20 f" "tail -f log" "grep -rn foo src" "rg -n 'a|b' src" "find . -name '*.md'" \
  "wc -l f" "stat f" "pwd" "echo hi" "printf '%s\n' x" "which jq" "diff a b" "sleep 1" "date" "ps aux" "du -sh ." \
  "cut -d, -f1 f.csv" "tr a-z A-Z < f" "jq -r .name f.json" "lsof -nP -iTCP" "basename a/b" "realpath ." \
  "git status" "git -C sub log --oneline" "git --no-pager diff" "git show HEAD" \
  "sed -n '1,20p' f" "sed -n -e '/error/p' log" "sed -En '\$p' f" "sort -u f" "sort -k2 -n f" "uniq -c f" \
  "sysctl hw.ncpu" "log show --last 5m" "ulimit -n" "curl -fsSL https://example.com/a.json" "curl -s -X GET https://example.com" \
  "curl -sX GET https://example.com" "curl -sXGET https://example.com" "ls # a comment; rm -rf x" \
  "ls | wc -l" "cd src && ls" "git log | head -5" "grep -n 'x;y' f" "grep x f 2>/dev/null | head" "ls > /dev/null 2>&1" \
  "cat f > /tmp/out.txt" "launchctl list" "launchctl list com.example.job" "crontab -l" "pgrep -x caffeinate" \
  "pmset -g assertions" "pmset displaysleepnow" "pkill -x caffeinate" "nohup caffeinate -dims -t 3600 >/dev/null 2>&1 &"; do
  run allow "read: $c" "$(bashjson "$W" "$c")"
done
for c in "touch f" "rm f" "npm test" "make" "ls | xargs rm" "echo \$(id)" "echo \`id\`" "cat <(ls)" "ls > out.txt" \
  "ls 2>&1 > out.txt" "find . -delete" "find . -exec rm {} ;" "git log --output=f" "rg --pre cat x" "git commit -m x" \
  "git -c core.pager=x log" "sed -i 's/a/b/' f" "sed -n 's/a/b/w out' f" "sed 's/a/b/' f" "sort -o out f" "sort -no out f" \
  "uniq in out" "sysctl -w kern.x=1" "sysctl kern.x=1" "log erase" "ulimit -n 10" "curl -o f https://example.com" \
  "curl -sO https://example.com/f" "curl -d x https://example.com" "curl --data-binary @f https://example.com" \
  "curl -F a=@f https://example.com" "curl -X POST https://example.com" "curl file:///etc/hosts" "curl https://example.com > f" \
  "FOO=1 ls" "pmset sleepnow" "launchctl unload x" "crontab -r" "kill 1" "nohup caffeinate -dims -t 999999 >/dev/null 2>&1 &" \
  "sed -n -e p -e 'w f' x" "sed -ni '' p f" "sed -I p f" "sed -n -ep f" "sed -n --expression=p f" "sort --out=x f" "sort --comp=gzip f" \
  "curl -sX POST https://example.com" "curl -sXPOST https://example.com" "curl -X" "find src \"-delete\"" "sort '-o' README.md x" \
  "sed -n '-i' 1q f" $'cd app  # the app\'s root\ncd .. && npm install'; do
  run deny "not a read: $c" "$(bashjson "$W" "$c")"
done
has_reason "use the Read/Grep tools" "a Bash deny points at the read tools"
run deny  "a read over 8 KB goes to the lock"     "$(bashjson "$W" "echo '$(head -c 9000 /dev/zero | tr '\0' a)'")"

# --- Wider git reads: each writing form of the same command is refused
for c in "git fetch" "git fetch origin" "git fetch --all --prune" "git fetch -p -t origin" "git fetch origin main" \
  "git fetch origin refs/heads/main" "git -C sub fetch --dry-run" "git fetch \"origin\"" \
  "git branch" "git branch --show-current" "git branch --list" "git branch --list feat/x" "git ls-files *.sh" "git rev-parse HEAD~1" "git branch -a" "git branch -r" "git branch -v" \
  "git branch -a -v" "git branch -v --list main" "git -C sub branch --show-current" \
  "git rev-parse HEAD" "git rev-parse --show-toplevel" "git ls-files" "git ls-files --others" "git merge-base main HEAD" \
  "git remote -v" "git remote get-url origin" "git worktree list" "git worktree list --porcelain" "git config --get remote.origin.url"; do
  run allow "git read: $c" "$(bashjson "$W" "$c")"
done
for c in "git fetch origin x:main" "git fetch origin +main" "git fetch origin +x:y" "git fetch origin refs/heads/*:refs/heads/*" \
  "git fetch origin \"x:main\"" "git fetch -u origin" "git fetch --update-head-ok" "git fetch --upload-pack=x origin" \
  "git fetch --upload-pack x origin" "git fetch --upload x origin" "git fetch --update-h origin" "git fetch --refmap= origin" \
  "git fetch --recurse-submodules" "git fetch -o x" "git fetch --config x=y" "git fetch --prune-tags" "git fetch --set-upstream origin" \
  "git fetch --depth=1" "git fetch -- origin" "git fetch ext::sh" "git fetch https://example.com/r.git" "git fetch ../other" \
  "git branch foo" "git branch -v foo" "git branch -D foo" "git branch -d foo" "git branch -m a b" "git branch -c a b" \
  "git branch --list -D foo" "git branch --show-current foo" "git branch -vv" "git branch --set-upstream-to=origin/x" \
  "git branch --unset-upstream" "git branch --edit-description" "git branch -f foo HEAD" "git branch --delete foo" \
  "git remote" "git remote add x y" "git remote remove x" "git remote get-url" "git remote get-url -v origin" "git remote get-url a b" \
  "git remote set-url origin x" "git remote -v add x y" "git worktree add ../w" "git worktree list --lock" "git worktree remove w" \
  "git config --list" "git config --get" "git config --get a b" "git config --global user.name x" "git config user.name x" \
  "git config --unset a" "git config --get --add a b" "git fetch . \$'--upload-pack=x'" "git fetch origin \$'main\\x3amain'" "git fetch origin *" "git fetch origin x?main" "git fetch origin [a]" "git fetch origin 'refs/heads/*'" "git branch --list *" "git branch --list 'feat/*'" "git config --get *" "git config --get [a]" "git fetch origin {,-}-upload-pack=x" "git branch --list {,-D}" "git fetch origin \$BR" "git fetch origin \`id\`" "git rev-parse --output=f HEAD" "git ls-files --output=f"; do
  run deny "git write form: $c" "$(bashjson "$W" "$c")"
done

# --- Heredoc into the workspace's own .archive/
mkdir -p "$W/.archive/NOTES" "$SANDBOX/elsewhere/.archive"
hd() {  # hd <first line> [body lines...]: the command text, no trailing newline
  local first=$1; shift
  printf '%s' "$first"; local l; for l in "$@"; do printf '\n%s' "$l"; done
}
HA="cat >> $W/.archive/NOTES/log.md <<'EOF'"
run allow "heredoc: append to .archive/"            "$(bashjson "$W" "$(hd "$HA" '# note' 'cd /x && rm -rf y' 'EOF')")"
run allow "heredoc: a trailing newline (the hook input never has one)" "$(bashjson "$W" "$(hd "$HA" 'text' 'EOF')"$'\n')"
run allow "heredoc: overwrite with >"               "$(bashjson "$W" "$(hd "cat > $W/.archive/NOTES/new.md <<'END_1'" 'a' 'END_1')")"
run allow "heredoc: relative path from the root"    "$(bashjson "$W" "$(hd "cat >> .archive/NOTES/log.md <<'EOF'" 'a' 'EOF')")"
run allow "heredoc: body with a backslash-newline, \$(..) and a lock call" "$(bashjson "$W" "$(hd "$HA" 'a \' 'b $(id) `id`' "$LS clear --id a --holder b" 'EOF')")"
run allow "heredoc: empty body"                     "$(bashjson "$W" "$(hd "$HA" 'EOF')")"
run deny  "heredoc: early terminator, then a command" "$(bashjson "$W" "$(hd "$HA" 'a' 'EOF' 'rm -rf src')")"
run allow "heredoc: trailing blank lines never reach the guard" "$(bashjson "$W" "$(hd "$HA" 'a' 'EOF')"$'\n\n')"
run deny  "heredoc: a command after the terminator" "$(bashjson "$W" "$(hd "$HA" 'a' 'EOF' 'touch src/x')")"
run deny  "heredoc: no terminator"                  "$(bashjson "$W" "$(hd "$HA" 'a' 'b')")"
run deny  "heredoc: terminator with trailing space" "$(bashjson "$W" "$(hd "$HA" 'a' 'EOF ')")"
run allow "heredoc: a bare first line is the old scratch-redirect rule" "$(bashjson "$W" "$HA")"
run deny  "heredoc: unquoted delimiter"             "$(bashjson "$W" "$(hd "cat >> $W/.archive/NOTES/log.md <<EOF" 'a' 'EOF')")"
run deny  "heredoc: unquoted delimiter with \$(..)" "$(bashjson "$W" "$(hd "cat >> $W/.archive/NOTES/log.md <<EOF" '$(touch src/x)' 'EOF')")"
run deny  "heredoc: double-quoted delimiter"        "$(bashjson "$W" "$(hd "cat >> $W/.archive/NOTES/log.md <<\"EOF\"" 'a' 'EOF')")"
run deny  "heredoc: <<-"                            "$(bashjson "$W" "$(hd "cat >> $W/.archive/NOTES/log.md <<-'EOF'" 'a' 'EOF')")"
run deny  "heredoc: here-string"                    "$(bashjson "$W" "$(hd "cat >> $W/.archive/NOTES/log.md <<<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: backslash-newline on the first line" "$(bashjson "$W" "$(hd "cat >> $W/.archive/NOTES/log.md \\" "<<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: a trailing backslash after the delimiter" "$(bashjson "$W" "$(hd "$HA \\" 'a' 'EOF')")"
run deny  "heredoc: a second redirect"              "$(bashjson "$W" "$(hd "cat >> $W/.archive/NOTES/log.md > $W/src/x <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: a redirect to src"              "$(bashjson "$W" "$(hd "cat >> $W/src/x.md <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: && on the first line"           "$(bashjson "$W" "$(hd "$HA && touch src/x" 'a' 'EOF')")"
run deny  "heredoc: ; on the first line"            "$(bashjson "$W" "$(hd "$HA; touch src/x" 'a' 'EOF')")"
run deny  "heredoc: | on the first line"            "$(bashjson "$W" "$(hd "$HA | sh" 'a' 'EOF')")"
run deny  "heredoc: a command in front"             "$(bashjson "$W" "$(hd "cd src && cat >> $W/.archive/NOTES/log.md <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: a command after the redirect"   "$(bashjson "$W" "$(hd "cat >> $W/.archive/NOTES/log.md <<'EOF' x" 'a' 'EOF')")"
run deny  "heredoc: tee"                            "$(bashjson "$W" "$(hd "tee -a $W/.archive/NOTES/log.md <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: a blank line before the cat"    "$(bashjson "$W" $'\n'"$(hd "$HA" 'a' 'EOF')")"
run deny  "heredoc: target in /tmp"                 "$(bashjson "$W" "$(hd "cat >> /tmp/log.md <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: another repo's .archive/"       "$(bashjson "$W" "$(hd "cat >> $SANDBOX/elsewhere/.archive/log.md <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: a src file inside the workspace" "$(bashjson "$W" "$(hd "cat >> $W/src/.archive/log.md <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: .. out of .archive/"            "$(bashjson "$W" "$(hd "cat >> $W/.archive/../src/x <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: .. in the middle"               "$(bashjson "$W" "$(hd "cat >> $W/.archive/NOTES/../../src/x <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: expansion in the path"          "$(bashjson "$W" "$(hd "cat >> $W/.archive/\$X <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: a backtick in the path"         "$(bashjson "$W" "$(hd "cat >> $W/.archive/\`id\` <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: a glob in the path"             "$(bashjson "$W" "$(hd "cat >> $W/.archive/*.md <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: ~ in the path"                  "$(bashjson "$W" "$(hd "cat >> ~/.archive/x <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: .archive/ itself"               "$(bashjson "$W" "$(hd "cat >> $W/.archive/ <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: a relative path from a subfolder" "$(bashjson "$W/src" "$(hd "cat >> .archive/log.md <<'EOF'" 'a' 'EOF')")"
run deny  "heredoc: a sibling named .archive-x"     "$(bashjson "$W" "$(hd "cat >> $W/.archive-x/log.md <<'EOF'" 'a' 'EOF')")"
run allow "heredoc: a plain cat redirect into .archive/ (old scratch rule)" "$(bashjson "$W" "cat f >> $W/.archive/NOTES/log.md")"

# --- Scratch writes a non-holder may run
mkdir -p "$SANDBOX/elsewhere"
run allow "scratch: touch in a temp dir outside the workspace" "$(bashjson "$W" "touch $SANDBOX/elsewhere/f.txt")"
run deny  "scratch: a temp path inside the guarded workspace" "$(bashjson "$W" "touch $W/f.txt")"
run deny  "scratch: a second line"                "$(bashjson "$W" $'touch .archive/scratch\n.archive/STATE.md')"
run allow "scratch: mkdir under .archive/"        "$(bashjson "$W" "mkdir -p .archive/scratch")"
run allow "scratch: cp between temp paths"        "$(bashjson "$W" "cp /tmp/a /tmp/b")"
run deny  "scratch: cp into the workspace"        "$(bashjson "$W" "cp /tmp/a src/b")"
run deny  "scratch: .. is never scratch"          "$(bashjson "$W" "touch /tmp/../$W/x")"
run deny  "scratch: cp -t names a target dir"     "$(bashjson "$W" "cp -tsrc /tmp/a")"
run deny  "scratch: an interpreter is not scratch" "$(bashjson "$W" "bash /tmp/x.sh")"
run deny  "scratch: no path at all"               "$(bashjson "$W" "rm -rf")"
run deny  "scratch: expansion"                    "$(bashjson "$W" "rm -rf /tmp/\$X")"
run deny  "scratch: a leading ~ is home, not cwd"  "$(bashjson "$W/.archive" "cp /tmp/a ~/ws/src/app.py")"
run deny  "scratch: a redirect to ~"              "$(bashjson "$W/.archive" "echo x > ~/ws/src/app.py")"
mkdir -p "$W/.archive/NOTES" "$W/src"
run deny  "scratch: a relative redirect after cd"  "$(bashjson "$W/.archive/NOTES" "cd $W/src && echo x > main.c")"
run deny  "scratch: a relative path after cd"      "$(bashjson "$W/.archive/NOTES" "cd $W/src && touch main.c")"
run allow "scratch: an absolute redirect after cd" "$(bashjson "$W/.archive/NOTES" "cd $W/src && ls > /tmp/x.txt")"
run allow "scratch: a relative redirect, no cd"    "$(bashjson "$W/.archive/NOTES" "ls > out.txt")"
run deny  "$'..\'..' does not hide a &&"         "$(bashjson "$W" "echo \$'it\\'s done' && git commit -am wip")"
run deny  "$'..\'..' does not hide a redirect"   "$(bashjson "$W" "echo \$'don\\'t' > src/main.c")"
run allow "$'\\t' in a read"                       "$(bashjson "$W" "cut -d \$'\\t' -f1 f.txt")"

# --- The lock script: always allowed as a single plain call; acquire registers the session
W=$(mkws armed_script holder-x)
run allow "lock script: acquire"                 "$(bashjson "$W" "$LS acquire --id solo-abc --eta 30m" sessR)"
[ "$(cat "$W/$LOCKNAME/sessions/sessR" 2>/dev/null)" = solo-abc ] && PASS=$((PASS + 1)) || { echo "FAIL  acquire registers the session"; FAIL=$((FAIL + 1)); }
run allow "lock script: release, not the holder's id" "$(bashjson "$W" "$LS release --id solo-abc" sessR)"
[ "$(cat "$W/$LOCKNAME/sessions/sessR" 2>/dev/null)" = solo-abc ] && PASS=$((PASS + 1)) || { echo "FAIL  a refused release keeps the registration"; FAIL=$((FAIL + 1)); }
W2=$(mkws armed_release solo-abc sessH)
run allow "lock script: the holder's release with a wrong id" "$(bashjson "$W2" "$LS release --id solo-wrong" sessH)"
[ "$(cat "$W2/$LOCKNAME/sessions/sessH" 2>/dev/null)" = solo-abc ] && PASS=$((PASS + 1)) || { echo "FAIL  a wrong-id release keeps the holder's registration"; FAIL=$((FAIL + 1)); }
run allow "the holder still mutates after a wrong-id release" "$(writejson "$W2" "$W2/f.txt" sessH)"
run allow "lock script: release"                 "$(bashjson "$W2" "$LS release --id solo-abc" sessH)"
[ -e "$W2/$LOCKNAME/sessions/sessH" ] && { echo "FAIL  release removes the registration"; FAIL=$((FAIL + 1)); } || PASS=$((PASS + 1))
W2=$(mkws armed_release_q solo-q sessQ)
run allow "lock script: release with a quoted id" "$(bashjson "$W2" "$LS release --id \"solo-q\"" sessQ)"
[ -e "$W2/$LOCKNAME/sessions/sessQ" ] && { echo "FAIL  a quoted-id release removes the registration"; FAIL=$((FAIL + 1)); } || PASS=$((PASS + 1))
W2=$(mkws armed_release_e solo-e sessE)
EXTRA_ENV="WORKSPACE_LOCK_ID=solo-e"
run allow "lock script: release by WORKSPACE_LOCK_ID" "$(bashjson "$W2" "$LS release" sessE)"
EXTRA_ENV=""
[ -e "$W2/$LOCKNAME/sessions/sessE" ] && { echo "FAIL  an env-id release removes the registration"; FAIL=$((FAIL + 1)); } || PASS=$((PASS + 1))
# The script refuses a release with any argument but --id <value>, and takes the last --id: the guard reads it alike.
# Each case has its own workspace, so one dropped registration cannot decide the next case.
rel_case() {  # rel_case <keep|drop> <label> <command> [env assignment]
  local want=$1 label=$2 cmd=$3 renv=${4:-} wsr
  REL_N=$((${REL_N:-0} + 1))
  wsr=$(mkws "armed_rel_$REL_N" solo-x sessZ)
  EXTRA_ENV="$renv"
  run allow "lock script: release $label" "$(bashjson "$wsr" "$cmd" sessZ)"
  EXTRA_ENV=""
  if [ "$want" = keep ]; then
    [ "$(cat "$wsr/$LOCKNAME/sessions/sessZ" 2>/dev/null)" = solo-x ] && PASS=$((PASS + 1)) || { echo "FAIL  a release $label keeps the registration"; FAIL=$((FAIL + 1)); }
  else
    [ -e "$wsr/$LOCKNAME/sessions/sessZ" ] && { echo "FAIL  a release $label drops the registration"; FAIL=$((FAIL + 1)); } || PASS=$((PASS + 1))
  fi
}
rel_case keep "with an unknown argument"                 "$LS release --id solo-x --bogus"
rel_case keep "with --id and no value (env id is the holder's)" "$LS release --id" "WORKSPACE_LOCK_ID=solo-x"
rel_case keep "with --id=x (env id is the holder's)"     "$LS release --id=solo-x" "WORKSPACE_LOCK_ID=solo-x"
rel_case drop "with an id the shell expands (the old guard kept it)" "$LS release --id solo-\${CLAUDE_CODE_SESSION_ID:0:1}"
rel_case drop "where the last --id is the holder's"      "$LS release --id wrong --id solo-x"
rel_case drop "redirected to a scratch log"              "$LS release --id solo-x > /tmp/rel.log 2>&1"
run allow "lock script: status > /dev/null"      "$(bashjson "$W" "$LS status > /dev/null")"
run allow "lock script: acquire > scratch log"   "$(bashjson "$W" "$LS acquire --id solo-abc --eta 30m > /tmp/acq.log 2>&1")"
run allow "lock script: via ~ and \${HOME}"      "$(bashjson "$W" "~/.claude/tools/workspace-lock.sh status")"
run allow "lock script: \${HOME}"                "$(bashjson "$W" "\${HOME}/.claude/tools/workspace-lock.sh status")"
run allow "lock script: absolute"                "$(bashjson "$W" "$HOME/.claude/tools/workspace-lock.sh status")"
run allow "lock script: bash in front"           "$(bashjson "$W" "bash $LS status")"
run allow "acquire in an unarmed workspace"      "$(bashjson "$SANDBOX/plain" "$LS acquire --id solo-abc --eta 30m")"
run deny  "lock script: redirect into the workspace" "$(bashjson "$W" "$LS status > src/main.py")"
run deny  "lock script: compound falls under the lock" "$(bashjson "$W" "$LS status; touch f")"
run deny  "lock script: a copy elsewhere"        "$(bashjson "$W" "/tmp/workspace-lock.sh status")"
run deny  "lock script: acquire without --id"    "$(bashjson "$W" "$LS acquire --eta 30m")"
run deny  "lock script: unknown verb"            "$(bashjson "$W" "$LS takeover --id x")"
run deny  "lock script: no verb"                 "$(bashjson "$W" "$LS")"

# --- Edit tools under .archive/ and git-mcp
W=$(mkws armed_archive holder-x)
run allow "a .archive/ write is exempt"          "$(writejson "$W" "$W/.archive/notes.md")"
run deny  "a sibling of .archive/ is not"        "$(writejson "$W" "$W/archive-notes.md")"
run deny  ".. out of .archive/ is not"           "$(writejson "$W" "$W/.archive/STATE.md/../../src/x")"
W=$(mkws armed_git holder-x)
run allow "git_status is a read"                 "$(gmcpjson mcp__git-mcp__git_status "$W")"
run allow "git_reflog is a read"                 "$(gmcpjson mcp__git-mcp__git_reflog "$W")"
run deny  "git_commit is guarded"                "$(gmcpjson mcp__git-mcp__git_commit "$W")"
run allow "git_branch list"                      "$(gmcpjson mcp__git-mcp__git_branch "$W" list)"
run deny  "git_branch delete"                    "$(gmcpjson mcp__git-mcp__git_branch "$W" delete)"
run allow "git_branch show-current"              "$(gmcpjson mcp__git-mcp__git_branch "$W" show-current)"
run deny  "git_branch create"                    "$(gmcpjson mcp__git-mcp__git_branch "$W" create)"
run deny  "git_branch with an empty mode is guarded" "$(gmcpjson mcp__git-mcp__git_branch "$W")"
run allow "git_fetch"                            "$(gmcpjson mcp__git-mcp__git_fetch "$W")"
run allow "git_fetch with a remote, prune and tags" "$(jq -nc --arg p "$W" '{tool_name:"mcp__git-mcp__git_fetch",cwd:$p,session_id:"s",tool_input:{path:$p,remote:"origin",prune:true,tags:true}}')"
run deny  "git_fetch with a depth shallows the repo" "$(jq -nc --arg p "$W" '{tool_name:"mcp__git-mcp__git_fetch",cwd:$p,session_id:"s",tool_input:{path:$p,depth:1}}')"
run deny  "git_fetch with a refspec key" "$(jq -nc --arg p "$W" '{tool_name:"mcp__git-mcp__git_fetch",cwd:$p,session_id:"s",tool_input:{path:$p,refspec:"x:main"}}')"
run deny  "git_fetch from a URL" "$(jq -nc --arg p "$W" '{tool_name:"mcp__git-mcp__git_fetch",cwd:$p,session_id:"s",tool_input:{path:$p,remote:"git@host"}}')"
run deny  "git_fetch with a remote that is an option" "$(jq -nc --arg p "$W" '{tool_name:"mcp__git-mcp__git_fetch",cwd:$p,session_id:"s",tool_input:{path:$p,remote:"-u"}}')"
run allow "git_tag verify"                       "$(gmcpjson mcp__git-mcp__git_tag "$W" verify)"
run deny  "git_tag delete"                       "$(gmcpjson mcp__git-mcp__git_tag "$W" delete)"
run allow "git_remote get-url"                   "$(gmcpjson mcp__git-mcp__git_remote "$W" get-url)"
run deny  "git_remote add"                       "$(gmcpjson mcp__git-mcp__git_remote "$W" add)"
run allow "git_stash list"                       "$(gmcpjson mcp__git-mcp__git_stash "$W" list)"
run deny  "git_stash with no mode pushes"        "$(gmcpjson mcp__git-mcp__git_stash "$W")"
run allow "git-mcp on an unarmed repo"           "$(gmcpjson mcp__git-mcp__git_commit "$SANDBOX/plain")"

# --- The log: a reason tag, never an inline secret
W=$(mkws armed_log holder-x)
run deny "log: touch"                            "$(bashjson "$W" "touch f.txt")"
logline_has "$W/$LOCKNAME" "reason=word:touch" "the log carries the reason"
W=$(mkws armed_log2 holder-x)
run deny "log: env prefix"                       "$(bashjson "$W" "SECRET=hidden-value-123 make")"
logline_absent "$W/$LOCKNAME" "hidden-value-123" "an inline env value never reaches the log"
logline_has "$W/$LOCKNAME" "SECRET=<redacted>" "the env name is kept"

# --- Bad input never crashes; a registered session fails closed
run allow "no tool_input"                        "$(jq -nc --arg c "$SANDBOX" '{tool_name:"Bash",cwd:$c,session_id:"s"}')"
run allow "an unknown tool"                      "$(jq -nc --arg c "$SANDBOX" '{tool_name:"WebFetch",cwd:$c,tool_input:{url:"x"}}')"
run allow "malformed input, no lock id"          "not json"
EXTRA_ENV="WORKSPACE_LOCK_ID=solo-x"
run deny  "malformed input with a lock id"       "not json"
EXTRA_ENV=""

# --- ETA re-arm and clear. The clear gate runs the lock script's own `clear --check`, so these cases
#     give the guard a HOME whose ~/.claude/tools/workspace-lock.sh is the script under test.
WL_SCRIPT="${WL_SCRIPT:-$HERE/workspace-lock.sh}"
CH="$SANDBOX/clearhome"; mkdir -p "$CH/.claude/tools"
ln -s "$WL_SCRIPT" "$CH/.claude/tools/workspace-lock.sh"
NOW=$(date -u +%s)
mkclr() {  # mkclr <name> <holder> <eta-age-s> <heartbeat-age-s|none> [sid]
  _c=$(mkws "$1" "$2" "${5:-}")
  printf '%s\n' $((NOW - $3)) > "$_c/$LOCKNAME/lock.d/eta_epoch"
  [ "$4" = none ] || printf '%s\n' $((NOW - $4)) > "$_c/$LOCKNAME/lock.d/heartbeat_epoch"
  printf 'fix "x"\001 now\n' > "$_c/$LOCKNAME/lock.d/task"
  printf '%s' "$_c"
}
CL="$LS clear --id solo-me --holder solo-old"
EXTRA_ENV="HOME=$CH CLAUDE_CODE_ENTRYPOINT=cli"
W=$(mkclr clr_ok solo-old 4000 4000)
run ask  "clear: expired and silent asks"        "$(bashjson "$W" "$CL")"
has_reason "Holder solo-old" "the ask names the holder"
has_reason "last heartbeat" "the ask names the heartbeat"
logline_has "$W/$LOCKNAME" "CLEAR-ASK" "the ask is logged"
run ask  "clear: bash in front"                  "$(bashjson "$W" "bash $CL")"
run allow "clear --check is a read"              "$(bashjson "$W" "$LS clear --check --id solo-me --holder solo-old")"
W=$(mkclr clr_young solo-old 1000 4000)
run deny "clear: ETA within the grace"           "$(bashjson "$W" "$CL")"
has_reason "not clearable" "the script's reason is relayed"
W=$(mkclr clr_alive solo-old 4000 100)
run deny "clear: fresh heartbeat"                "$(bashjson "$W" "$CL")"
W=$(mkclr clr_mismatch solo-other 4000 4000)
run deny "clear: --holder mismatch"              "$(bashjson "$W" "$CL")"
W=$(mkclr clr_self solo-me 4000 4000)
run deny "clear: own lock"                       "$(bashjson "$W" "$LS clear --id solo-me --holder solo-me")"
W=$(mkclr clr_who solo-old 4000 4000)
EXTRA_ENV="HOME=$CH CLAUDE_CODE_ENTRYPOINT=sdk-cli"
run deny "clear: headless entrypoint"            "$(bashjson "$W" "$CL")"
run allow "clear --check, headless"              "$(bashjsonm "$W" "$LS clear --check --id solo-me --holder solo-old" bypassPermissions)"
run deny "clear: --check in a value slot"        "$(bashjsonm "$W" "$LS clear --id --check --id solo-me --holder solo-old" bypassPermissions)"
run deny "clear: --check after a comment"        "$(bashjsonm "$W" "$CL # --check" bypassPermissions)"
EXTRA_ENV="HOME=$CH CLAUDE_CODE_ENTRYPOINT=cli"
run deny "clear: bypassPermissions"              "$(bashjsonm "$W" "$CL" bypassPermissions)"
run deny "clear: no permission mode"             "$(bashjsonm "$W" "$CL" "")"
run ask  "clear: auto mode asks"                 "$(bashjsonm "$W" "$CL" auto)"
run deny "clear: a redirect"                     "$(bashjson "$W" "$CL > /tmp/clear.log 2>&1")"
run deny "clear: compound"                       "$(bashjson "$W" "$CL; echo ok")"
run deny "clear: bash -c"                        "$(bashjson "$W" "bash -c '$CL'")"
run deny "clear: quoted verb"                    "$(bashjson "$W" "$LS 'clear' --id solo-me --holder solo-old")"
run deny "clear: duplicate --id"                 "$(bashjson "$W" "$LS clear --id a --id b --holder solo-old")"
run deny "clear: missing --holder"               "$(bashjson "$W" "$LS clear --id solo-me")"
run deny "clear: --holder with a slash"          "$(bashjson "$W" "$LS clear --id solo-me --holder a/b")"
W=$(mkws clr_text solo-old)
run allow "acquire whose --task says clear"      "$(bashjson "$W" "$LS acquire --id solo-me --task \"clear old caches\"")"
run allow "heartbeat --phase clear"              "$(bashjson "$W" "$LS heartbeat --id solo-me --phase clear")"
run allow "grep for clear in the script"         "$(bashjson "$W" "grep -n clear tools/workspace-lock/workspace-lock.sh")"
run allow "git log of the script, grep clear"    "$(bashjson "$W" "git log -p tools/workspace-lock/workspace-lock.sh | grep -n clear")"
run allow "cat the script, grep clear, unarmed"  "$(bashjson "$SANDBOX/plain" "cat ~/.claude/tools/workspace-lock.sh | grep -n clear")"
W=$(mkws clr_commit solo-me sessC)
run allow "holder commits a message naming clear" "$(bashjson "$W" "git commit -m \"fix: workspace-lock.sh clear gate\"" sessC)"
run deny "clear: compound from an unarmed cwd"   "$(bashjson "$SANDBOX/plain" "cd $W && $CL")"
stubhome() {  # a HOME whose lock script is a stub
  mkdir -p "$SANDBOX/$1/.claude/tools"
  printf '#!/bin/bash\n%s\n' "$2" > "$SANDBOX/$1/.claude/tools/workspace-lock.sh"
  chmod +x "$SANDBOX/$1/.claude/tools/workspace-lock.sh"
  printf '%s' "$SANDBOX/$1"
}
W=$(mkclr clr_stub solo-old 4000 4000)
EXTRA_ENV="HOME=$(stubhome stub_fail 'exit 1') CLAUDE_CODE_ENTRYPOINT=cli"
run deny "clear: --check fails"                  "$(bashjson "$W" "$CL")"
EXTRA_ENV="HOME=$(stubhome stub_two 'echo "CLEARABLE a"; echo "CLEARABLE b"') CLAUDE_CODE_ENTRYPOINT=cli"
run deny "clear: --check prints two lines"       "$(bashjson "$W" "$CL")"
EXTRA_ENV="HOME=$(stubhome stub_slow 'sleep 15; echo "CLEARABLE late"') CLAUDE_CODE_ENTRYPOINT=cli"
run deny "clear: --check times out"              "$(bashjson "$W" "$CL")"
EXTRA_ENV=""

# A holder past its ETA is denied its own mutations until it heartbeats with a new --eta; the
# retake, reads and .archive/ writes still pass.
W=$(mkclr rearm solo-me 10 10 sess1)
run deny  "re-arm: holder Write past its ETA"    "$(writejson "$W" "$W/f.txt")"
has_reason "heartbeat --id solo-me" "the re-arm names the retake"
logline_has "$W/$LOCKNAME" "re-armed" "the re-arm is logged"
run deny  "re-arm: holder mutating Bash"         "$(bashjson "$W" "touch ./f.txt")"
run allow "re-arm: the retake"                   "$(bashjson "$W" "$LS heartbeat --id solo-me --eta +30m")"
run allow "re-arm: reads"                        "$(bashjson "$W" "ls")"
run allow "re-arm: .archive/ writes"             "$(writejson "$W" "$W/.archive/STATE.md")"
W=$(mkclr rearm_git solo-me 10 10 s)
run deny  "re-arm: git-mcp commit"               "$(gmcpjson mcp__git-mcp__git_commit "$W")"
W=$(mkclr rearm_future solo-me -600 10 sess1)
run allow "a holder within its ETA"              "$(writejson "$W" "$W/f.txt")"

echo "workspace-lock-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
