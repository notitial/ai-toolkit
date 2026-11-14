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
has_reason "only if whoever started this team told you to" "the deny limits joining to whoever started the team"
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


# --- An empty lock.d nobody claimed is not orphaned: the next acquire takes it
W=$(mkws unclaimed ""); mkdir -p "$W/$LOCKNAME/lock.d"
run deny  "an empty, unclaimed lock.d denies a session that has not acquired" "$(writejson "$W" "$W/f.txt")"
has_reason "nobody holds it" "the unclaimed deny says the next acquire takes it"
case "$_out" in *orphaned*) echo "FAIL  an unclaimed lock.d is not called orphaned"; FAIL=$((FAIL + 1)) ;; *) PASS=$((PASS + 1)) ;; esac
has_reason "acquire --id" "the unclaimed deny says how to acquire"
W=$(mkws claimed_only ""); mkdir -p "$W/$LOCKNAME/lock.d"; : > "$W/$LOCKNAME/lock.d/claim"
run deny  "a claim with no holder is a crashed acquire" "$(writejson "$W" "$W/f.txt")"
has_reason "orphaned" "a claim with no holder stays orphaned"

# --- Owned team: judged by session id and the turn, on every tool
OWN=aaaaaaaa-0000-4000-8000-000000000001
M1=bbbbbbbb-0000-4000-8000-000000000002
M2=cccccccc-0000-4000-8000-000000000003
STR=dddddddd-0000-4000-8000-000000000004
bashjsone() { jq -nc --arg c "$1" --arg cmd "$2" --arg s "$3" --arg m "${4:-default}" \
  '{tool_name:"Bash",cwd:$c,session_id:$s,permission_mode:$m,tool_input:{command:$cmd}}'; }   # <cwd> <cmd> <sid, may be empty> [mode]
gmcpjsons() { jq -nc --arg t "$1" --arg p "$2" --arg s "$3" --arg m "${4:-}" \
  '{tool_name:$t,cwd:$p,session_id:$s,tool_input:({path:$p}+(if $m=="" then {} else {mode:$m} end))}'; }
mkowned() {  # mkowned <name> [slug] [lock ETA offset s]: an owned lock held by OWN, members M1 and M2, no turn
  _o=$(mkws "$1"); mkdir -p "$_o/$LOCKNAME/lock.d/members" "$_o/$LOCKNAME/lock.d/ended" "$_o/$LOCKNAME/sessions"
  printf 'owned\n' > "$_o/$LOCKNAME/lock.d/kind"; printf '%s\n' "$OWN" > "$_o/$LOCKNAME/lock.d/owner"
  printf '%s\n' "${2:-team-o}" > "$_o/$LOCKNAME/lock.d/holder"
  printf '%s\n' $((NOW + ${3:-3600})) > "$_o/$LOCKNAME/lock.d/eta_epoch"; printf '%s\n' "$NOW" > "$_o/$LOCKNAME/lock.d/heartbeat_epoch"
  printf '%s\n' "$NOW" > "$_o/$LOCKNAME/lock.d/members/$M1"; printf '%s\n' "$NOW" > "$_o/$LOCKNAME/lock.d/members/$M2"
  printf '%s' "$_o"
}
giveturn() {  # giveturn <ws> <sid> [ETA offset s] [heartbeat age s] [task]
  _t="$1/$LOCKNAME/lock.d/turn.d"; rm -rf "$_t"; mkdir -p "$_t"
  printf '%s\n' "$2" > "$_t/sid"; printf '%s\n' $((NOW + ${3:-600})) > "$_t/eta_epoch"
  printf '%s\n' $((NOW - ${4:-0})) > "$_t/heartbeat_epoch"; printf '%s\n' "${5:-build the api}" > "$_t/task"
}
NL=$'\n'
BRC="{a,--sid,$M1}"
RMF="r""m -r""f"
GCF="-f""d"
registered() { [ -e "$1/$LOCKNAME/sessions/$2" ]; }

W=$(mkowned own_a); giveturn "$W" $M1
run allow "owned: the turn holder runs a build"      "$(bashjson "$W" "npm test" $M1)"
run allow "owned: the turn holder switches branch"   "$(bashjson "$W" "git checkout main" $M1)"
run allow "owned: the turn holder writes a file"     "$(writejson "$W" "$W/f.txt" $M1)"
run allow "owned: the turn holder uses git MCP"      "$(gmcpjsons mcp__git-mcp__git_commit "$W" $M1)"
run deny  "owned: a member without the turn, build"  "$(bashjson "$W" "npm test" $M2)"
has_reason "held by session bbbbbbbb" "the deny names the turn holder"
has_reason "build the api" "the deny names the turn's task"
has_reason "turn take --id team-o --sid $M2" "the deny says how to take a turn, with the session's own id"
has_reason "BACKGROUND" "the deny says to take the turn in the background"
has_reason "never remove turn.d" "the deny forbids removing turn.d"
run deny  "owned: a member without the turn, git checkout" "$(bashjson "$W" "git checkout main" $M2)"
run deny  "owned: a member without the turn, Write"  "$(writejson "$W" "$W/f.txt" $M2)"
run deny  "owned: a member without the turn, git MCP checkout" "$(gmcpjsons mcp__git-mcp__git_checkout "$W" $M2)"
run deny  "owned: the owner without the turn"        "$(bashjson "$W" "npm test" $OWN)"
run allow "owned: a member without the turn reads"   "$(bashjson "$W" "ls -la" $M2)"
run allow "owned: a member reads git status in Bash" "$(bashjson "$W" "git status" $M2)"
run allow "owned: a member reads git_status over MCP" "$(gmcpjsons mcp__git-mcp__git_status "$W" $M2)"
run allow "owned: a member writes under .archive/"   "$(writejson "$W" "$W/.archive/notes.md" $M2)"
run allow "owned: a member runs the lock script"     "$(bashjson "$W" "$LS status" $M2)"
run deny  "owned: a stranger"                        "$(bashjson "$W" "npm test" $STR)"
has_reason "a team holds this workspace's lock" "the stranger deny says a team holds it"
has_reason "Only the owner can add you" "the stranger deny says who adds members"
has_reason 'echo $CLAUDE_CODE_SESSION_ID' "the stranger deny says how to read its session id"
run deny  "owned: a stranger, Write"                 "$(writejson "$W" "$W/f.txt" $STR)"
run deny  "owned: a stranger, git MCP"               "$(gmcpjsons mcp__git-mcp__git_commit "$W" $STR)"
printf 'team-o\n' > "$W/$LOCKNAME/sessions/$STR"
run deny  "owned: a registration under the slug does not make a holder" "$(bashjson "$W" "npm test" $STR)"
EXTRA_ENV="WORKSPACE_LOCK_ID=team-o"
run deny  "owned: WORKSPACE_LOCK_ID does not count"  "$(bashjson "$W" "npm test" $STR)"
EXTRA_ENV=""
giveturn "$W" $OWN
run allow "owned: the owner with the turn"           "$(bashjson "$W" "npm test" $OWN)"
run deny  "owned: a member while the owner holds the turn" "$(bashjson "$W" "npm test" $M1)"
has_reason "held by session aaaaaaaa" "the deny names the owner as the turn holder"
# The lock's ETA gates only the owner's own turn: a silent owner does not stop a member that has the turn.
W=$(mkowned own_silent team-o -600); giveturn "$W" $M1
run allow "owned: a member keeps working while the owner is silent past the lock's ETA" "$(bashjson "$W" "npm test" $M1)"
giveturn "$W" $OWN
run deny  "owned: the owner past the lock's ETA is re-armed" "$(bashjson "$W" "npm test" $OWN)"
has_reason "heartbeat --id team-o --sid $OWN" "the owner's re-arm names the retake"
# The turn's own ETA gates its holder.
W=$(mkowned own_late); giveturn "$W" $M1 -10
run deny  "owned: a member past its turn's ETA"      "$(bashjson "$W" "npm test" $M1)"
has_reason "turn beat --id team-o --sid $M1" "the turn re-arm names turn beat"
run deny  "owned: a member past its turn's ETA, Write" "$(writejson "$W" "$W/f.txt" $M1)"
run deny  "owned: a member past its turn's ETA, git MCP" "$(gmcpjsons mcp__git-mcp__git_commit "$W" $M1)"
W=$(mkowned own_noeta); giveturn "$W" $M1; rm "$W/$LOCKNAME/lock.d/turn.d/eta_epoch"
run deny  "owned: a turn with no readable ETA is re-armed" "$(bashjson "$W" "npm test" $M1)"
W=$(mkowned own_free)
run deny  "owned: no turn held, member"              "$(bashjson "$W" "npm test" $M1)"
has_reason "no turn is held" "the deny says no turn is held"
run deny  "owned: no turn held, owner"               "$(writejson "$W" "$W/f.txt" $OWN)"
# A turn with no sid is held by no one, the owner included.
W=$(mkowned own_nosid); giveturn "$W" ""
run deny  "owned: an empty turn sid is held by no one, member" "$(bashjson "$W" "npm test" $M1)"
has_reason "holder is unknown" "the deny says the holder is unknown"
run deny  "owned: an empty turn sid is held by no one, owner" "$(bashjson "$W" "npm test" $OWN)"
run deny  "owned: an empty turn sid, empty session id" "$(bashjsone "$W" "npm test" "")"
# A turn held by a session that is not (or no longer) a member does not count, nor does anyone else's.
W=$(mkowned own_gone); giveturn "$W" $STR
run deny  "owned: a non-member holding turn.d is denied" "$(bashjson "$W" "npm test" $STR)"
run deny  "owned: a member under a non-member's turn"    "$(bashjson "$W" "npm test" $M1)"
# An empty session id is never a party.
W=$(mkowned own_empty_sid); giveturn "$W" $M1
run deny  "owned: empty session_id"                  "$(bashjsone "$W" "npm test" "")"
has_reason "no session id" "the empty-session deny says so"
run deny  "owned: no session_id key"                 "$(jq -nc --arg c "$W" '{tool_name:"Bash",cwd:$c,tool_input:{command:"npm test"}}')"
giveturn "$W" $OWN
run deny  "owned: empty session_id, owner's turn, Write" "$(jq -nc --arg c "$W" --arg f "$W/f.txt" '{tool_name:"Write",cwd:$c,session_id:"",tool_input:{file_path:$f,content:"x"}}')"
run deny  "owned: empty session_id, owner's turn, Bash"  "$(bashjsone "$W" "npm test" "")"
run deny  "owned: empty session_id, git MCP"             "$(gmcpjsons mcp__git-mcp__git_commit "$W" "")"
# Plain writes into the lock folder stay denied for every session, the turn holder included.
W=$(mkowned own_folder); giveturn "$W" $M1
run deny  "owned folder: Write into lock.d by the turn holder"  "$(writejson "$W" "$W/$LOCKNAME/lock.d/ended/$M2" $M1)"
has_reason "the team lock's own state" "the folder deny says why"
run deny  "owned folder: Write through .."           "$(writejson "$W" "$W/src/../$LOCKNAME/lock.d/members/$STR" $M1)"
run deny  "owned folder: Write into status.json"     "$(writejson "$W" "$W/$LOCKNAME/status.json" $M1)"
run deny  "owned folder: Write by the owner"         "$(writejson "$W" "$W/$LOCKNAME/lock.d/owner" $OWN)"
run deny  "owned folder: touch ended/ in Bash"       "$(bashjson "$W" "touch .workspace-lock/lock.d/ended/$M2" $M1)"
run deny  "owned folder: rm turn.d in Bash"          "$(bashjson "$W" "rm -rf .workspace-lock/lock.d/turn.d" $M1)"
run deny  "owned folder: a redirect into lock.d"     "$(bashjson "$W" "echo x > .workspace-lock/lock.d/kind" $M1)"
run deny  "owned folder: a chained write names lock.d" "$(bashjson "$W" "cd .workspace-lock && touch lock.d/x" $M1)"
run deny  "owned folder: the absolute path"          "$(bashjson "$W" "rm $W/$LOCKNAME/status.json" $M1)"
run allow "owned folder: a read of lock.d passes"    "$(bashjson "$W" "cat .workspace-lock/lock.d/holder" $M1)"
run allow "owned folder: a read by a non-holder passes" "$(bashjson "$W" "cat .workspace-lock/lock.d/holder" $M2)"
run allow "owned folder: a .gitignore line naming the folder" "$(bashjson "$W" "echo '.workspace-lock/' >> .gitignore" $M1)"
run allow "owned folder: Edit of a source file by the turn holder" "$(writejson "$W" "$W/src/a.txt" $M1)"
run deny  "owned folder: the folder itself in Bash"       "$(bashjson "$W" "$RMF .workspace-lock" $M1)"
run deny  "owned folder: a double slash and a quoted name" "$(bashjson "$W" "$RMF .workspace-lock//'lock.d'" $M1)"
run deny  "owned folder: a glob into the folder"          "$(bashjson "$W" "$RMF .workspace-lock/*" $M1)"
run deny  "owned folder: a write from a cwd inside the folder" "$(bashjson "$W/$LOCKNAME/lock.d" "touch owner" $M1)"
run allow "owned folder: a read from a cwd inside the folder" "$(bashjson "$W/$LOCKNAME/lock.d" "cat owner" $M1)"
run deny  "owned folder: a Write in other letter case"    "$(writejson "$W" "$W/.Workspace-Lock/LOCK.D/ended/$M2" $M1)"
run deny  "owned folder: git clean"                       "$(bashjson "$W" "git clean $GCF" $M1)"
run deny  "owned folder: git clean with x"                "$(bashjson "$W" "git clean ${GCF}x" $M1)"
run allow "owned folder: git clean -n"                    "$(bashjson "$W" "git clean -nd" $M1)"
run allow "owned folder: git clean excluding the folder"  "$(bashjson "$W" "git clean ${GCF}x -e .workspace-lock" $M1)"
run deny  "owned folder: git clean -e of another path"    "$(bashjson "$W" "git clean $GCF -e build" $M1)"
run deny  "owned folder: git_clean over MCP"              "$(gmcpjsons mcp__git-mcp__git_clean "$W" $M1)"
run allow "owned folder: git_clean on an open lock is as before" "$(gmcpjsons mcp__git-mcp__git_clean "$(mkws gc_open open-1 sessO)" sessO)"
# A lock-script verb in any form but the single plain call skips the check of who calls, even for the turn holder.
run deny  "owned verbs: a pipe, by the turn holder"       "$(bashjson "$W" "$LS member add --id team-o --sid $STR --by $OWN | cat" $M1)"
run deny  "owned verbs: a quoted script path, by the turn holder" "$(bashjson "$W" "\"\$HOME/.claude/tools/workspace-lock.sh\" owner transfer --id team-o --to $STR" $M1)"
run deny  "owned verbs: the repo copy, by the turn holder" "$(bashjson "$W" "bash tools/workspace-lock/workspace-lock.sh release --id team-o --sid $OWN" $M1)"
run allow "owned verbs: status in a pipe is a read"       "$(bashjson "$W" "$LS status | cat" $M1)"
run allow "owned folder: a commit message that names lock.d is not a write" "$(bashjson "$W" "git commit -m \"fix the lock.d wording\"" $M1)"
# git clean: read the way git reads it.
run deny  "owned folder: git clean -e<pattern> is no dry run"       "$(bashjson "$W" "git clean ${GCF}x -enode_modules" $M1)"
run deny  "owned folder: an exclude that only contains the name"    "$(bashjson "$W" "git clean $GCF -e .workspace-lock/keep" $M1)"
run deny  "owned folder: --exclude= that only contains the name"    "$(bashjson "$W" "git clean $GCF --exclude=.workspace-lock-x" $M1)"
run deny  "owned folder: git -P clean"                              "$(bashjson "$W" "git -P clean ${GCF}x" $M1)"
run deny  "owned folder: git --work-tree=. clean"                   "$(bashjson "$W" "git --work-tree=. clean ${GCF}x" $M1)"
run deny  "owned folder: git --no-optional-locks clean"             "$(bashjson "$W" "git --no-optional-locks clean ${GCF}x" $M1)"
run deny  "owned folder: git -C . -c a=b clean"                     "$(bashjson "$W" "git -C . -c a=b clean ${GCF}x" $M1)"
run deny  "owned folder: an n after the e is part of the pattern"   "$(bashjson "$W" "git clean ${GCF}xe.workspace-lock-n" $M1)"
run allow "owned folder: git -P clean -n"                           "$(bashjson "$W" "git -P clean -nd" $M1)"
run allow "owned folder: git clean --dry-run"                       "$(bashjson "$W" "git clean $GCF --dry-run" $M1)"
run allow "owned folder: git clean --exclude=.workspace-lock"       "$(bashjson "$W" "git clean ${GCF}x --exclude=.workspace-lock" $M1)"
run allow "owned folder: git clean -e<exact> in a cluster"          "$(bashjson "$W" "git clean ${GCF}xe .workspace-lock" $M1)"
run allow "owned folder: git -C . clean excluding the folder"       "$(bashjson "$W" "git -C . clean $GCF -e .workspace-lock" $M1)"
# The folder named with a separator stuck to it, or as a glob.
run deny  "owned folder: an echo first does not excuse a later write" "$(bashjson "$W" "echo hi; $RMF .workspace-lock" $M1)"
run deny  "owned folder: a ; stuck to the name"           "$(bashjson "$W" "$RMF .workspace-lock; true" $M1)"
run deny  "owned folder: a | stuck to the name"           "$(bashjson "$W" "$RMF .workspace-lock|cat" $M1)"
run deny  "owned folder: a subshell around the call"      "$(bashjson "$W" "($RMF .workspace-lock)" $M1)"
run deny  "owned folder: a redirect stuck to a word"      "$(bashjson "$W" "echo hi>.workspace-lock/lock.d/x" $M1)"
run deny  "owned folder: a glob for the folder name"      "$(bashjson "$W" "$RMF .w*" $M1)"
run deny  "owned folder: a ? glob into the folder"        "$(bashjson "$W" "touch .workspace-loc?/lock.d/members/$STR" $M1)"
run deny  "owned folder: a [ ] glob for the folder"       "$(bashjson "$W" "$RMF .workspace-loc[k]" $M1)"
run deny  "owned folder: a brace spelling of the folder"  "$(bashjson "$W" "$RMF {.workspace-lock,x}" $M1)"
run deny  "owned folder: a variable before the folder"    "$(bashjson "$W" "$RMF \$WS/.workspace-lock" $M1)"
run allow "owned folder: a glob under another folder"     "$(bashjson "$W" "$RMF src/*" $M1)"
run allow "owned folder: a leading * never matches the dot folder" "$(bashjson "$W" "$RMF $W/*" $M1)"
# A heredoc body is data, not path words.
HD="git commit -F - <<'EOF'${NL}the lock.d and .workspace-lock/ wording${NL}EOF"
run allow "owned folder: a heredoc commit message naming the folder" "$(bashjson "$W" "$HD" $M1)"
HD="cat > .workspace-lock/lock.d/kind <<'EOF'${NL}owned${NL}EOF"
run deny  "owned folder: a heredoc written into the folder"  "$(bashjson "$W" "$HD" $M1)"
HD="echo \"<<X\"${NL}$RMF .workspace-lock${NL}X"
run deny  "owned folder: a quoted << opens no heredoc"       "$(bashjson "$W" "$HD" $M1)"
HD="cat <<'EOF'${NL}$RMF .workspace-lock"
run deny  "owned folder: a heredoc with no end line hides nothing" "$(bashjson "$W" "$HD" $M1)"
HD="cat <<-EOF${NL}	body .workspace-lock/${NL}	EOF${NL}$RMF .workspace-lock"
run deny  "owned folder: a command after a <<- heredoc is still read" "$(bashjson "$W" "$HD" $M1)"
# A fused fd redirect (team2>&1) does not change the --id the script reads.
W2=$(mkowned fd_fuse team2); giveturn "$W2" $M1
run deny  "fd: a member's release with --id team2>&1"     "$(bashjson "$W2" "$LS release --id team2>&1 --sid $OWN" $M1)"
run deny  "fd: a member's heartbeat with --id team2>&1"   "$(bashjson "$W2" "$LS heartbeat --id team2>&1 --sid $OWN --eta +5m" $M1)"
run allow "fd: the owner's release with a real 2>&1"      "$(bashjson "$W2" "$LS release --id team2 --sid $OWN 2>&1" $OWN)"
EXTRA_ENV="WORKSPACE_LOCK_BYPASS=1"
run allow "owned folder: WORKSPACE_LOCK_BYPASS overrides, Write" "$(writejson "$W" "$W/$LOCKNAME/status.json" $M2)"
run allow "owned folder: WORKSPACE_LOCK_BYPASS overrides, Bash" "$(bashjson "$W" "touch .workspace-lock/lock.d/x" $M2)"
EXTRA_ENV=""
W=$(mkws open_folder open-1 sessO)
run allow "open lock: the holder still writes in its lock folder (unchanged)" "$(writejson "$W" "$W/$LOCKNAME/status.json" sessO)"

# --- Owned team: acquire is closed to everyone but the owner, and registers no one
W=$(mkowned acq_a); giveturn "$W" $M1
run deny  "acquire: a stranger takes the owned slug"  "$(bashjson "$W" "$LS acquire --id team-o --eta 30m" $STR)"
has_reason "closed" "the refused acquire says the lock is closed"
registered "$W" $STR && { echo "FAIL  a refused acquire of an owned slug is not registered"; FAIL=$((FAIL + 1)); } || PASS=$((PASS + 1))
run deny  "acquire: a stranger, --owned with its own sid" "$(bashjson "$W" "$LS acquire --id team-o --owned --sid $STR --eta 30m" $STR)"
registered "$W" $STR && { echo "FAIL  a refused owned acquire is not registered"; FAIL=$((FAIL + 1)); } || PASS=$((PASS + 1))
run deny  "acquire: a member never acquires"          "$(bashjson "$W" "$LS acquire --id team-o --owned --sid $M1 --eta 30m" $M1)"
has_reason "never acquires" "the member's refused acquire says so"
run deny  "acquire: a member without --owned"         "$(bashjson "$W" "$LS acquire --id team-o --eta 30m" $M1)"
run allow "acquire: the owner re-enters"              "$(bashjson "$W" "$LS acquire --id team-o --owned --sid $OWN --eta +1h" $OWN)"
registered "$W" $OWN && { echo "FAIL  an owned acquire registers no one"; FAIL=$((FAIL + 1)); } || PASS=$((PASS + 1))
run deny  "acquire: the owner without --owned"        "$(bashjson "$W" "$LS acquire --id team-o --eta +1h" $OWN)"
run deny  "acquire: the owner naming another sid"     "$(bashjson "$W" "$LS acquire --id team-o --owned --sid $M1 --eta +1h" $OWN)"
run deny  "acquire: --owned with a variable sid"      "$(bashjson "$W" "$LS acquire --id team-o --owned --sid \$CLAUDE_CODE_SESSION_ID --eta +1h" $OWN)"
has_reason 'echo $CLAUDE_CODE_SESSION_ID' "a variable sid is denied with the literal hint"
run deny  "acquire: a duplicate --sid"                "$(bashjson "$W" "$LS acquire --id team-o --owned --sid $OWN --sid $M1" $OWN)"
run allow "acquire: another slug waits its turn, registered" "$(bashjson "$W" "$LS acquire --id other-1 --eta 30m" $STR)"
[ "$(cat "$W/$LOCKNAME/sessions/$STR" 2>/dev/null)" = other-1 ] && PASS=$((PASS + 1)) || { echo "FAIL  an acquire of another slug registers the session"; FAIL=$((FAIL + 1)); }
W=$(mkws acq_free)
run allow "acquire --owned: free workspace, own sid"  "$(bashjson "$W" "$LS acquire --id team-n --owned --sid $STR --eta +1h" $STR)"
registered "$W" $STR && { echo "FAIL  an owned acquire of a free workspace registers no one"; FAIL=$((FAIL + 1)); } || PASS=$((PASS + 1))
run deny  "acquire --owned: another session's sid"    "$(bashjson "$W" "$LS acquire --id team-n --owned --sid $OWN --eta +1h" $STR)"
run deny  "acquire --owned: no --sid"                 "$(bashjson "$W" "$LS acquire --id team-n --owned --eta +1h" $STR)"
run deny  "acquire --owned: empty session id"         "$(bashjsone "$W" "$LS acquire --id team-n --owned --sid $STR --eta +1h" "")"
run deny  "acquire --owned: a variable sid"           "$(bashjson "$W" "$LS acquire --id team-n --owned --sid \"\$CLAUDE_CODE_SESSION_ID\" --eta +1h" $STR)"
run deny  "acquire --owned: a backtick sid"           "$(bashjson "$(mkws acq_arm solo-other)" "$LS acquire --id team-n --owned --sid \`echo x\` --eta +1h" $STR)"
run allow "acquire: --owned inside a quoted --task is only text" "$(bashjson "$W" "$LS acquire --id solo-t --task \"do --owned things\" --eta 30m" $STR)"
[ "$(cat "$W/$LOCKNAME/sessions/$STR" 2>/dev/null)" = solo-t ] && PASS=$((PASS + 1)) || { echo "FAIL  a plain acquire whose task says --owned registers"; FAIL=$((FAIL + 1)); }
W=$(mkws acq_bad)
run allow "acquire: an open acquire the parser dislikes still registers (the guard cannot see the script refuse it)" "$(bashjson "$W" "$LS acquire --id solo-b --bogus" $STR)"
[ "$(cat "$W/$LOCKNAME/sessions/$STR" 2>/dev/null)" = solo-b ] && PASS=$((PASS + 1)) || { echo "FAIL  an open acquire registers even when the parser dislikes a flag"; FAIL=$((FAIL + 1)); }

# --- Owned team: the identity of each verb (a cell per rule)
CH2="$SANDBOX/teamhome"; mkdir -p "$CH2/.claude/tools"; ln -s "$WL_SCRIPT" "$CH2/.claude/tools/workspace-lock.sh"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=cli"
W=$(mkowned idc); giveturn "$W" $M1
TK="$LS turn take --id team-o"
run allow "identity: turn take, own sid"              "$(bashjson "$W" "$TK --sid $M1 --eta +20m" $M1)"
run allow "identity: turn take with a task"           "$(bashjson "$W" "$TK --sid $M1 --eta +20m --task \"fix the --sid bug\"" $M1)"
run deny  "identity: turn take, another session's sid" "$(bashjson "$W" "$TK --sid $M1 --eta +20m" $M2)"
has_reason "must be this session's own id ($M2)" "the mismatch deny names the session's own id"
run deny  "identity: turn take, no --sid"             "$(bashjson "$W" "$TK --eta +20m" $M1)"
run deny  "identity: turn take, a variable sid"       "$(bashjson "$W" "$TK --sid \$CLAUDE_CODE_SESSION_ID --eta +20m" $M1)"
has_reason 'echo $CLAUDE_CODE_SESSION_ID' "a variable sid is denied with the literal hint"
run deny  "identity: turn take, a doubled --sid"      "$(bashjson "$W" "$TK --sid $M1 --sid $M2 --eta +20m" $M1)"
run deny  "identity: turn take, empty session id"     "$(bashjsone "$W" "$TK --sid $M1 --eta +20m" "")"
run deny  "identity: turn take, --id=slug form"       "$(bashjson "$W" "$LS turn take --id=team-o --sid $M1 --eta +20m" $M1)"
run deny  "identity: turn take, a trailing flag with no value" "$(bashjson "$W" "$TK --sid $M1 --eta" $M1)"
run deny  "identity: turn take, an unknown flag"      "$(bashjson "$W" "$TK --sid $M1 --eta +20m --by $M1" $M1)"
run deny  "identity: turn take, no --id"              "$(bashjson "$W" "$LS turn take --sid $M1 --eta +20m" $M1)"
run allow "identity: turn take through bash"          "$(bashjson "$W" "bash $TK --sid $M1 --eta +20m" $M1)"
run allow "identity: turn take, redirect to /dev/null" "$(bashjson "$W" "$TK --sid $M1 --eta +20m > /dev/null 2>&1" $M1)"
run deny  "identity: turn take, a compound call"      "$(bashjson "$W" "$TK --sid $M2 --eta +20m; touch f" $M2)"
run allow "identity: turn beat, own sid"              "$(bashjson "$W" "$LS turn beat --id team-o --sid $M1 --eta +20m" $M1)"
run deny  "identity: turn beat, another session's sid" "$(bashjson "$W" "$LS turn beat --id team-o --sid $M1" $M2)"
run allow "identity: turn give, own sid"              "$(bashjson "$W" "$LS turn give --id team-o --sid $M1 --tree clean" $M1)"
run deny  "identity: turn give, another session's sid" "$(bashjson "$W" "$LS turn give --id team-o --sid $M1 --tree clean" $M2)"
run deny  "identity: turn give with --by but no --force" "$(bashjson "$W" "$LS turn give --id team-o --sid $M1 --by $OWN --tree clean" $M1)"
run deny  "identity: turn give with --check but no --force" "$(bashjson "$W" "$LS turn give --id team-o --sid $M1 --tree clean --check" $M1)"
run allow "identity: member add, the owner"           "$(bashjson "$W" "$LS member add --id team-o --sid $STR --by $OWN" $OWN)"
run allow "identity: member remove, the owner"        "$(bashjson "$W" "$LS member remove --id team-o --sid $M2 --by $OWN" $OWN)"
run deny  "identity: member add, --by is another session" "$(bashjson "$W" "$LS member add --id team-o --sid $STR --by $OWN" $M1)"
run deny  "identity: member add, a member naming itself --by" "$(bashjson "$W" "$LS member add --id team-o --sid $STR --by $M1" $M1)"
has_reason "owns this workspace's team lock" "the member-add deny says it is for the owner"
run deny  "identity: member add, a stranger"          "$(bashjson "$W" "$LS member add --id team-o --sid $STR --by $STR" $STR)"
run deny  "identity: member add, no --by"             "$(bashjson "$W" "$LS member add --id team-o --sid $STR" $OWN)"
run deny  "identity: member add, a malformed --sid"   "$(bashjson "$W" "$LS member add --id team-o --sid not-a-sid --by $OWN" $OWN)"
run deny  "identity: member add, a variable --sid"    "$(bashjson "$W" "$LS member add --id team-o --sid \$NEW --by $OWN" $OWN)"
run deny  "identity: member remove, a member"         "$(bashjson "$W" "$LS member remove --id team-o --sid $M2 --by $M1" $M1)"
run allow "identity: member list, anyone"             "$(bashjson "$W" "$LS member list --id team-o" $STR)"
run deny  "identity: a made-up verb"                  "$(bashjson "$W" "$LS member promote --id team-o" $OWN)"
run deny  "identity: turn with no action"             "$(bashjson "$W" "$LS turn --id team-o" $OWN)"
W2=$(mkws idc_nolock)
run deny  "identity: member add on a workspace with no owned lock" "$(bashjson "$W2" "$LS member add --id team-o --sid $STR --by $STR" $STR)"
mkdir -p "$W/sub"
run deny  "identity: turn take from a subfolder"      "$(bashjson "$W/sub" "$TK --sid $M1 --eta +20m" $M1)"
has_reason "workspace root" "the subfolder deny says to run it from the root"
# Owned release and heartbeat: the owner only, naming itself.
run allow "identity: release, the owner"              "$(bashjson "$W" "$LS release --id team-o --sid $OWN" $OWN)"
run allow "identity: release --force, the owner"      "$(bashjson "$W" "$LS release --id team-o --sid $OWN --force" $OWN)"
run deny  "identity: release without --sid"           "$(bashjson "$W" "$LS release --id team-o" $OWN)"
run deny  "identity: release, a member"               "$(bashjson "$W" "$LS release --id team-o --sid $M1" $M1)"
run deny  "identity: release, a member naming the owner" "$(bashjson "$W" "$LS release --id team-o --sid $OWN" $M1)"
run deny  "identity: release, a stranger"             "$(bashjson "$W" "$LS release --id team-o --sid $STR" $STR)"
run deny  "identity: release, a variable sid"         "$(bashjson "$W" "$LS release --id team-o --sid \$CLAUDE_CODE_SESSION_ID" $OWN)"
run deny  "identity: release, empty session id"       "$(bashjsone "$W" "$LS release --id team-o --sid $OWN" "")"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=cli WORKSPACE_LOCK_ID=team-o"
run deny  "identity: release by WORKSPACE_LOCK_ID without --sid" "$(bashjson "$W" "$LS release" $M1)"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=cli"
run allow "identity: release of another slug passes to the script" "$(bashjson "$W" "$LS release --id other-1" $STR)"
run allow "identity: heartbeat, the owner"            "$(bashjson "$W" "$LS heartbeat --id team-o --sid $OWN --eta +1h" $OWN)"
run deny  "identity: heartbeat without --sid"         "$(bashjson "$W" "$LS heartbeat --id team-o --eta +1h" $OWN)"
run deny  "identity: heartbeat, a member"             "$(bashjson "$W" "$LS heartbeat --id team-o --sid $M1 --eta +1h" $M1)"
run deny  "identity: heartbeat, a variable sid"       "$(bashjson "$W" "$LS heartbeat --id team-o --sid \$X --eta +1h" $OWN)"
run deny  "identity: heartbeat, empty session id"     "$(bashjsone "$W" "$LS heartbeat --id team-o --sid $OWN --eta +1h" "")"
run deny  "parse: release with a comment that rewrites --id" "$(bashjson "$W" "$LS release --id team-o --sid $OWN --force # --id x" $STR)"
run deny  "parse: release with a brace list"          "$(bashjson "$W" "$LS release --id $BRC" $STR)"
run deny  "parse: heartbeat with a comment that rewrites --id" "$(bashjson "$W" "$LS heartbeat --id team-o --sid $OWN --eta +1h # --id x" $STR)"
run deny  "parse: turn give with a brace list in --tree" "$(bashjson "$W" "$LS turn give --id team-o --sid $M2 --tree $BRC" $M2)"
run deny  "parse: turn beat with a glob in --eta"     "$(bashjson "$W" "$LS turn beat --id team-o --sid $M2 --eta +*" $M2)"
run deny  "parse: owned acquire with a brace in --task" "$(bashjson "$W" "$LS acquire --id team-o --owned --sid $OWN --task $BRC" $OWN)"
run deny  "parse: a variable in --task of a team verb" "$(bashjson "$W" "$LS turn take --id team-o --sid $M2 --eta +5m --task \$WHAT" $M2)"
run deny  "parse: a flag word with a space"           "$(bashjson "$W" "$LS turn give --id team-o --sid $M2 --tree clean \"--force --check\"" $M2)"
run deny  "parse: a tilde word in a team verb"        "$(bashjson "$W" "$LS turn take --id team-o --sid $M2 --eta +5m --task ~/x" $M2)"
run allow "parse: a trailing comment on a plain team call" "$(bashjson "$W" "$LS turn take --id team-o --sid $M2 --eta +5m # waiting" $M2)"
run deny  "parse: a multi-line team call is not the single plain call" "$(bashjson "$W" "$LS turn take --id team-o \\${NL}  --sid $M2 --eta +5m" $M2)"
W2=$(mkws par_open solo-other)
run allow "parse: an open acquire in the background registers" "$(bashjson "$W2" "$LS acquire --id solo-bg --eta 30m > /tmp/acq.log 2>&1 &" sessBG)"
[ "$(cat "$W2/$LOCKNAME/sessions/sessBG" 2>/dev/null)" = solo-bg ] && PASS=$((PASS + 1)) || { echo "FAIL  a trailing & does not stop the registration"; FAIL=$((FAIL + 1)); }
run allow "parse: an open acquire whose --task mentions --id registers under the real --id" "$(bashjson "$W2" "$LS acquire --task \"see --id notes\" --id solo-tk --eta 30m" sessTK)"
[ "$(cat "$W2/$LOCKNAME/sessions/sessTK" 2>/dev/null)" = solo-tk ] && PASS=$((PASS + 1)) || { echo "FAIL  a --task naming --id does not change the registered slug"; FAIL=$((FAIL + 1)); }
run allow "identity: heartbeat --phase clear on an open lock still passes" "$(bashjson "$(mkws idc_open solo-me)" "$LS heartbeat --id solo-me --phase clear")"
# The owner's release drops the registrations that name the slug, and only those.
W=$(mkowned rel_reg); printf 'team-o\n' > "$W/$LOCKNAME/sessions/$STR"; printf 'solo-x\n' > "$W/$LOCKNAME/sessions/$M2"
run deny  "release: a member's call leaves the registrations" "$(bashjson "$W" "$LS release --id team-o --sid $M1" $M1)"
registered "$W" $STR && PASS=$((PASS + 1)) || { echo "FAIL  a refused release leaves the registrations"; FAIL=$((FAIL + 1)); }
run allow "release: the owner's call"                 "$(bashjson "$W" "$LS release --id team-o --sid $OWN" $OWN)"
registered "$W" $STR && { echo "FAIL  the owner's release drops a registration naming the slug"; FAIL=$((FAIL + 1)); } || PASS=$((PASS + 1))
[ "$(cat "$W/$LOCKNAME/sessions/$M2" 2>/dev/null)" = solo-x ] && PASS=$((PASS + 1)) || { echo "FAIL  the owner's release keeps a registration naming another slug"; FAIL=$((FAIL + 1)); }
# The release parser on an open lock learns --sid and --force.
rel_case drop "with a valid --sid"                    "$LS release --id solo-x --sid $OWN"
rel_case keep "with a malformed --sid (the script refuses)" "$LS release --id solo-x --sid not-a-sid"
rel_case keep "with --sid and no value"               "$LS release --id solo-x --sid"
rel_case keep "with --force on an open lock (the script refuses)" "$LS release --id solo-x --force"
rel_case keep "with --sid and --force on an open lock" "$LS release --id solo-x --sid $OWN --force"
W=$(mkws rel_dyn solo-x sessZ)
run deny  "release: a variable --sid on an open lock" "$(bashjson "$W" "$LS release --id solo-x --sid \$CLAUDE_CODE_SESSION_ID" sessZ)"
[ "$(cat "$W/$LOCKNAME/sessions/sessZ" 2>/dev/null)" = solo-x ] && PASS=$((PASS + 1)) || { echo "FAIL  a denied release keeps the registration"; FAIL=$((FAIL + 1)); }

# --- Owned team: the force-give and the owner transfer go through the script's --check
FR="$LS turn give --id team-o --sid $M1 --by $OWN --force"
W=$(mkowned force_a); giveturn "$W" $M1 600 0
printf '%s ended\n' "$NOW" > "$W/$LOCKNAME/lock.d/ended/$M1"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=cli"
run allow "force: a turn whose session ended is freed at once" "$(bashjson "$W" "$FR" $OWN)"
logline_has "$W/$LOCKNAME" "FORCE-NOW" "the immediate force is logged"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=sdk-cli"
run allow "force: an ended session's turn is freed in a headless session too" "$(bashjsone "$W" "$FR" $OWN bypassPermissions)"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=cli"
run deny  "force: only the owner"                     "$(bashjson "$W" "$LS turn give --id team-o --sid $M1 --by $M2 --force" $M2)"
run deny  "force: the owner naming another --by"      "$(bashjson "$W" "$LS turn give --id team-o --sid $M1 --by $M2 --force" $OWN)"
run deny  "force: --tree does not go with --force"    "$(bashjson "$W" "$FR --tree clean" $OWN)"
run deny  "force: a variable --sid"                   "$(bashjson "$W" "$LS turn give --id team-o --sid \$M --by $OWN --force" $OWN)"
run deny  "force: a variable --by"                    "$(bashjson "$W" "$LS turn give --id team-o --sid $M1 --by \$ME --force" $OWN)"
run deny  "force: empty session id"                   "$(bashjsone "$W" "$FR" "")"
run allow "force --check is a read"                   "$(bashjson "$W" "$FR --check" $OWN)"
run deny  "force --check by a member"                 "$(bashjson "$W" "$LS turn give --id team-o --sid $M1 --by $M2 --force --check" $M2)"
run deny  "force: a compound call"                    "$(bashjson "$W" "$FR; echo ok" $OWN)"
run deny  "force: a call behind cd"                   "$(bashjson "$W" "cd $W && $FR" $OWN)"
run deny  "force: bash -c, by a session without the turn" "$(bashjson "$W" "bash -c '$FR'" $OWN)"
run deny  "force: a redirect into the workspace"      "$(bashjson "$W" "$FR > out.txt" $OWN)"
W=$(mkowned force_stale); giveturn "$W" $M1 -4000 4000 "a \"quoted\" task"
run ask   "force: a stale turn asks"                  "$(bashjson "$W" "$FR" $OWN)"
has_reason "Free the turn on the workspace lock" "the force ask names what is freed"
has_reason "Held by session bbbbbbbb" "the force ask names the turn holder"
has_reason "last turn heartbeat" "the force ask names the last heartbeat"
logline_has "$W/$LOCKNAME" "FORCE-ASK" "the force ask is logged"
run ask   "force: a stale turn, bash in front"        "$(bashjson "$W" "bash $FR" $OWN)"
run ask   "force: a stale turn, auto mode asks"       "$(bashjsone "$W" "$FR" $OWN auto)"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=sdk-cli"
run deny  "force: a stale turn in a headless session" "$(bashjson "$W" "$FR" $OWN)"
has_reason "needs a human at the permission prompt" "the headless deny says why"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=cli"
run deny  "force: a stale turn under bypassPermissions" "$(bashjsone "$W" "$FR" $OWN bypassPermissions)"
W=$(mkowned force_alive); giveturn "$W" $M1 -4000 100
run deny  "force: a turn that still beats is refused" "$(bashjson "$W" "$FR" $OWN)"
has_reason "cannot be freed" "the refusal says the turn cannot be freed"
W=$(mkowned force_young); giveturn "$W" $M1 600 4000
run deny  "force: a turn within its ETA is refused"   "$(bashjson "$W" "$FR" $OWN)"
W=$(mkowned force_other); giveturn "$W" $M2 -4000 4000
run deny  "force: --sid names a session that does not hold the turn" "$(bashjson "$W" "$FR" $OWN)"
W=$(mkowned force_empty); giveturn "$W" "" -4000 4000
run ask   "force: an empty turn sid asks"             "$(bashjson "$W" "$FR" $OWN)"
W=$(mkowned force_none)
run deny  "force: no turn held"                       "$(bashjson "$W" "$FR" $OWN)"
has_reason "no turn is held" "the no-turn refusal relays the script's reason"
W=$(mkowned force_open); rm "$W/$LOCKNAME/lock.d/kind"
run deny  "force: an open lock has no turns"          "$(bashjson "$W" "$FR" $OWN)"
W=$(mkowned force_stale2); giveturn "$W" $M1 -4000 4000
EXTRA_ENV="HOME=$(stubhome stub_force_two 'echo "FORCEABLE a"; echo "FORCEABLE b"') CLAUDE_CODE_ENTRYPOINT=cli"
run deny  "force: --check prints two lines"           "$(bashjson "$W" "$FR" $OWN)"
EXTRA_ENV="HOME=$(stubhome stub_force_odd 'echo "MAYBE a"') CLAUDE_CODE_ENTRYPOINT=cli"
run deny  "force: --check prints an unknown verdict"  "$(bashjson "$W" "$FR" $OWN)"
EXTRA_ENV="HOME=$(stubhome stub_force_fail 'exit 1') CLAUDE_CODE_ENTRYPOINT=cli"
run deny  "force: --check fails"                      "$(bashjson "$W" "$FR" $OWN)"
EXTRA_ENV="HOME=$(stubhome stub_force_slow 'sleep 15; echo "FORCEABLE late"') CLAUDE_CODE_ENTRYPOINT=cli"
run deny  "force: --check times out"                  "$(bashjson "$W" "$FR" $OWN)"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=cli"
# The owner transfer: the person approves at a prompt; the new session is named by its literal id.
W=$(mkowned xfer); giveturn "$W" $M1
XF="$LS owner transfer --id team-o --to $STR"
run ask   "transfer: asks"                            "$(bashjson "$W" "$XF" $STR)"
has_reason "Make session dddddddd the owner" "the transfer ask names the new owner"
has_reason "Current owner aaaaaaaa" "the transfer ask names the current owner"
logline_has "$W/$LOCKNAME" "TRANSFER-ASK" "the transfer ask is logged"
run ask   "transfer: asked by a session other than the new owner" "$(bashjson "$W" "$XF" $M2)"
run ask   "transfer: bash in front"                   "$(bashjson "$W" "bash $XF" $STR)"
run allow "transfer --check is a read"                "$(bashjson "$W" "$XF --check" $STR)"
run deny  "transfer: to the current owner"            "$(bashjson "$W" "$LS owner transfer --id team-o --to $OWN" $OWN)"
has_reason "already the owner" "the refusal relays the script's reason"
run deny  "transfer: to a member"                     "$(bashjson "$W" "$LS owner transfer --id team-o --to $M1" $M1)"
run deny  "transfer: a variable --to"                 "$(bashjson "$W" "$LS owner transfer --id team-o --to \$CLAUDE_CODE_SESSION_ID" $STR)"
has_reason 'echo $CLAUDE_CODE_SESSION_ID' "a variable --to is denied with the literal hint"
run deny  "transfer: a malformed --to"                "$(bashjson "$W" "$LS owner transfer --id team-o --to nope" $STR)"
run deny  "transfer: with --by"                       "$(bashjson "$W" "$XF --by $OWN" $STR)"
run deny  "transfer: with --force"                    "$(bashjson "$W" "$XF --force" $STR)"
run deny  "transfer: no --to"                         "$(bashjson "$W" "$LS owner transfer --id team-o" $STR)"
run deny  "transfer: another action"                  "$(bashjson "$W" "$LS owner resign --id team-o" $STR)"
run deny  "transfer: a compound call"                 "$(bashjson "$W" "$XF; echo ok" $STR)"
run deny  "transfer: a call behind cd"                "$(bashjson "$W" "cd $W && $XF" $STR)"
run deny  "transfer: a redirect into the workspace"   "$(bashjson "$W" "$XF > out.txt" $STR)"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=sdk-cli"
run deny  "transfer: headless"                        "$(bashjson "$W" "$XF" $STR)"
EXTRA_ENV="HOME=$CH2 CLAUDE_CODE_ENTRYPOINT=cli"
run deny  "transfer: bypassPermissions"               "$(bashjsone "$W" "$XF" $STR bypassPermissions)"
run deny  "transfer: an empty --to" "$(bashjson "$W" "$LS owner transfer --id team-o --to \"\"" $STR)"
EXTRA_ENV=""

echo "workspace-lock-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
