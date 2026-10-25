#!/bin/bash
# Tests for hooks/gh-block.sh (HOOK=<path> tests another copy). Run: bash tools/gh-block/test-gh-block.sh
# The hook runs under HOOK_SHELL (default /bin/bash, 3.2) with HOME pointed at a temp folder, so a deny never
# writes to the live audit log. Each case expects deny or pass (no output).

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../../hooks/gh-block.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
SH="${HOOK_SHELL:-/bin/bash}"
T=$(mktemp -d "${TMPDIR:-/tmp}/gh-block-XXXXXX")
trap 'rm -rf "$T"' EXIT
cp "$HOOK" "$T/gh-block.sh"
# A copy whose /usr/bin/jq fallback points nowhere, for the no-jq cases.
sed 's|^JQ_FALLBACK=/usr/bin/jq$|JQ_FALLBACK=/nonexistent/jq|' "$HOOK" > "$T/gh-block-nojq.sh"
grep -q '^JQ_FALLBACK=/nonexistent/jq$' "$T/gh-block-nojq.sh" || { echo "fallback swap failed" >&2; exit 2; }
PASS=0
FAIL=0

decision() {
  local out
  out=$(printf '%s' "$1" | HOME="$T" "$SH" "$T/gh-block.sh" 2>/dev/null)
  [ -z "$out" ] && { echo pass; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed
}
check() {  # check <deny|pass> <label> <command>
  local got
  got=$(decision "$(jq -nc --arg c "$3" '{tool_name: "Bash", tool_input: {command: $c}}')")
  if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $2: want $1, got $got"; fi
}

check deny "bare gh" 'gh pr view 12'
check deny "gh alone" 'gh'
check deny "full path" '/opt/homebrew/bin/gh api repos/o/r'
check deny "relative path" './gh auth status'
check deny "after a pipe" 'echo 12 | xargs gh pr view'
check deny "after &&" 'cd repo && gh pr checks 3 --watch'
check deny "after ;" 'true;gh run list'
check deny "in a substitution" 'echo $(gh auth token)'
check deny "in backticks" 'x=`gh api user`'
check deny "single-quoted" "'gh' pr list"
check deny "double-quoted" '"gh" pr list'
check deny "backslash" '\gh pr list'
check deny "env prefix" 'GH_HOST=github.com gh pr list'
check deny "command builtin" 'command gh pr list'
check deny "second line" $'ls\ngh pr list'
check deny "tab before" $'true\tgh pr list'
check deny "in a script string" "python3 -c \"import subprocess; subprocess.run(['gh', 'pr', 'list'])\""
check deny "gh config dir" 'cat ~/.config/gh/hosts.yml'
check deny "search for the word" 'grep -rn gh src'
check deny "split by double quotes" '"g"h pr merge 12'
check deny "split by single quotes" "g''h pr list"
check deny "inner backslash" 'g\h pr list'
check deny "ANSI-C quoted" "\$'g'h pr list"
check deny "upper case" 'GH pr list'
check pass "colour escape" "printf \$'\\033[31mred\\033[0m'"
check deny "mixed case" 'Gh api user'
check deny "upper-case full path" '/opt/homebrew/bin/GH pr list'
check pass "gh-pages branch" 'git log gh-pages'
check pass "GH_TOKEN mention" 'echo "$GH_TOKEN" | wc -c'
check pass "ghost" 'ghost --version'
check pass "dotted" 'ls foo.gh'
check pass "gh inside a word" 'echo sigh highway'
check pass "no gh" 'ls -la'
check pass "underscore" 'echo gh_value'
check pass "quoted gh-pages" 'git checkout "gh-pages"'
check pass "printf escape before" "printf 'a\\ngh'"
check pass "empty command" ''
check pass "braces only" '{}'
got=$(decision '{"tool_name":"Read","tool_input":{"file_path":"/x/gh"}}')
if [ "$got" = pass ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: non-Bash tool: want pass, got $got"; fi
# Sweep #3: Monitor runs its command in a shell, so it is screened as Bash is.
got=$(decision "$(jq -nc '{tool_name: "Monitor", tool_input: {command: "until gh pr checks 3; do sleep 30; done", description: "w"}}')")
if [ "$got" = deny ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: Monitor naming gh: want deny, got $got"; fi
got=$(decision '{"tool_name":"Monitor","tool_input":{"command":"tail -f build.log | grep -m1 done","description":"w"}}')
if [ "$got" = pass ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: Monitor without gh: want pass, got $got"; fi
got=$(decision 'not json')
if [ "$got" = pass ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: malformed input: want pass, got $got"; fi
got=$(decision 'not json, gh pr merge 1')
if [ "$got" = deny ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: malformed input naming gh: want deny, got $got"; fi
got=$(decision '{"tool_name":"Bash","tool_input":{"command":["gh","pr","list"]}}')
if [ "$got" = deny ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: non-string command naming gh: want deny, got $got"; fi

# The deny reason points at the MCP tools and the markdown-block handover.
out=$(jq -nc '{tool_name: "Bash", tool_input: {command: "gh pr view 1"}}' | HOME="$T" "$SH" "$T/gh-block.sh" 2>/dev/null)
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
if printf '%s' "$reason" | grep -q 'github MCP' && printf '%s' "$reason" | grep -q 'markdown code block'; then
  PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: deny reason wording"; fi

# A deny reaches the audit logger at $HOME/.claude/hooks/audit-logger.sh (detached, after the decision).
mkdir -p "$T/.claude/hooks"
cp "$T/gh-block.sh" "$T/.claude/hooks/gh-block.sh"
printf '#!/bin/bash\ncat > "%s/out-audit"\n' "$T" > "$T/.claude/hooks/audit-logger.sh"
jq -nc '{tool_name: "Bash", tool_input: {command: "gh pr list"}}' | HOME="$T" "$SH" "$T/.claude/hooks/gh-block.sh" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/out-audit" ] && break; sleep 0.2; done
if jq -e '._audit_event == "deny" and ._deny_hook == "gh-block"' "$T/out-audit" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: a deny did not reach the audit logger"; fi

# Without jq the hook still denies a gh call (fail-closed) and passes anything else. In the raw JSON a newline or
# tab in the command is an escape (\n, \t), which must still count as a boundary.
mkdir "$T/nojq"
for b in cat grep env dirname tr; do ln -s "$(command -v $b)" "$T/nojq/$b"; done
nojq() {  # nojq <deny|pass> <label> <raw json> [hook copy]
  local out got=pass
  out=$(printf '%s' "$3" | PATH="$T/nojq" "$SH" "${4:-$T/gh-block-nojq.sh}" 2>/dev/null)
  [ -z "$out" ] || { printf '%s' "$out" | grep -Eq '"permissionDecision": ?"deny"' && got=deny || got=malformed; }
  if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: no jq: $2: want $1, got $got"; fi
}
nojq deny "gh call" '{"tool_name":"Bash","tool_input":{"command":"gh pr list"}}'
nojq pass "ls" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
nojq deny "gh on a second line" '{"tool_name":"Bash","tool_input":{"command":"cd repo\ngh pr merge 1"}}'
nojq deny "gh after a tab" '{"tool_name":"Bash","tool_input":{"command":"true\tgh pr list"}}'
nojq deny "upper case" '{"tool_name":"Bash","tool_input":{"command":"GH pr list"}}'
# With jq off PATH but at /usr/bin/jq, the hook parses normally: a Read of a gh path passes, as it does with jq.
if [ -x /usr/bin/jq ]; then
  nojq pass "falls back to /usr/bin/jq" '{"tool_name":"Read","tool_input":{"file_path":"/x/gh"}}' "$T/gh-block.sh"
  nojq deny "fallback still denies gh" '{"tool_name":"Bash","tool_input":{"command":"gh pr list"}}' "$T/gh-block.sh"
fi

# Exactly one JSON document: with two, .tool_name prints two lines, never equals Bash, and the call would pass.
# Not a single object, so the hook reads the raw text: a mention denies, no mention passes.
DOC_READ='{"tool_name":"Read","tool_input":{"file_path":"/x/notes.md"}}'
DOC_BAD=$(jq -nc '{tool_name: "Bash", tool_input: {command: "gh pr list"}}')
for _c in "two documents, bad one second|$DOC_READ"$'\n'"$DOC_BAD|deny" "two documents, bad one first|$DOC_BAD"$'\n'"$DOC_READ|deny" "two documents, neither names the CLI|$DOC_READ $DOC_READ|pass" "one document, trailing newline|$(jq -nc '{tool_name: "Bash", tool_input: {command: "ls"}}')"$'\n'"|pass"; do
  _want=${_c##*|}; _rest=${_c%|*}; _label=${_rest%%|*}; _in=${_rest#*|}
  got=$(decision "$_in")
  if [ "$got" = "$_want" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $_label: want $_want, got $got"; fi
done

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
