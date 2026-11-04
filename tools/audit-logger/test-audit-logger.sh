#!/bin/bash
# Tests for hooks/audit-logger.sh (HOOK=<path> tests another copy). Run: bash tools/audit-logger/test-audit-logger.sh
# The hook runs under HOOK_SHELL (default /bin/bash, 3.2). It writes .archive/audit/audit-YYYY-MM.log under the
# input's cwd (or its git root), so every case gets its own temp folder as cwd and nothing touches a real audit log.
# The hook never prints a decision and always exits 0; the cases read the log record it appends.
# Every secret below is a made-up placeholder, assembled from fragments at run time so this file holds no contiguous
# key token (the live secret-detector scans Write/Edit content too).

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../../hooks/audit-logger.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required" >&2; exit 2; }
SH="${HOOK_SHELL:-/bin/bash}"
T=$(mktemp -d "${TMPDIR:-/tmp}/audit-logger-XXXXXX")
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
PASS=0
FAIL=0
N=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

newdir() {  # newdir: a fresh cwd with a .gitignore that covers .archive; sets D
  N=$((N + 1))
  D="$T/case$N"
  mkdir -p "$D"
  echo .archive/ > "$D/.gitignore"
}
log_of() { ls "$1"/.archive/audit/audit-*.log 2>/dev/null | head -1; }
run_hook() {  # run_hook <stdin json>: sets RC and ERR
  ERR=$(printf '%s' "$1" | "$SH" "$HOOK" 2>&1 >/dev/null)
  RC=$?
}
last() { tail -n 1 "$1"; }
detail_case() {  # detail_case <label> <input json built with $D as cwd> <expected tool> <expected detail>
  local label=$1 json=$2 want_tool=$3 want_detail=$4 log
  run_hook "$json"
  log=$(log_of "$D")
  if [ "$RC" != 0 ]; then bad "$label: exit $RC"; return; fi
  if [ -z "$log" ]; then bad "$label: no log written"; return; fi
  if last "$log" | jq -e --arg t "$want_tool" --arg d "$want_detail" '.tool == $t and .detail == $d' >/dev/null 2>&1; then ok; else bad "$label: got $(last "$log")"; fi
}
input() {  # input <tool_name> <tool_input json>: uses $D as cwd
  jq -nc --arg n "$1" --arg d "$D" --argjson i "$2" '{tool_name: $n, cwd: $d, session_id: "sess-1", tool_input: $i}'
}

newdir; detail_case "Bash command"            "$(input Bash '{"command":"ls -la"}')" Bash "ls -la"
newdir; detail_case "Write file path"         "$(input Write '{"file_path":"/x/a.md","content":"hi"}')" Write "write: /x/a.md"
newdir; detail_case "Edit file path"          "$(input Edit '{"file_path":"/x/a.ts","new_string":"y"}')" Edit "edit: /x/a.ts"
newdir; detail_case "NotebookEdit notebook path" "$(input NotebookEdit '{"notebook_path":"/x/n.ipynb","cell_id":"c1","new_source":"print(1)","cell_type":"code","edit_mode":"replace"}')" NotebookEdit "notebook-edit: /x/n.ipynb"
newdir; detail_case "NotebookEdit file_path ignored" "$(input NotebookEdit '{"file_path":"/x/n.ipynb"}')" NotebookEdit "notebook-edit: "
newdir; detail_case "git push, plain"         "$(input mcp__git-mcp__git_push '{"path":"/r","branch":"feat"}')" mcp__git-mcp__git_push "git push (/r) feat"
newdir; detail_case "git push, remoteBranch"  "$(input mcp__git-mcp__git_push '{"path":"/r","remoteBranch":"feat"}')" mcp__git-mcp__git_push "git push (/r) feat"
newdir; detail_case "git push, all flags"     "$(input mcp__git-mcp__git_push '{"path":"/r","branch":"feat","force":true,"forceWithLease":true,"delete":true}')" mcp__git-mcp__git_push "git push (/r) feat [+force+lease+delete]"
newdir; detail_case "git push, no args"       "$(input mcp__git-mcp__git_push '{}')" mcp__git-mcp__git_push "git push"
newdir; detail_case "other git tool"          "$(input mcp__git-mcp__git_status '{"path":"/r"}')" mcp__git-mcp__git_status "git status (/r)"
newdir; detail_case "other git tool, no path" "$(input mcp__git-mcp__git_log '{}')" mcp__git-mcp__git_log "git log"
newdir; detail_case "other MCP: first short string" "$(input mcp__other__do '{"n":5,"q":"hello","r":"world"}')" mcp__other__do "hello"
newdir; detail_case "other MCP: long string skipped" "$(input mcp__other__do "$(jq -nc --arg l "$(printf 'x%.0s' $(seq 1 250))" '{a: $l, b: "short"}')")" mcp__other__do "short"
newdir; detail_case "other MCP: no strings"  "$(input mcp__other__do '{"n":5}')" mcp__other__do ""
newdir; detail_case "Bash with no command"   "$(input Bash '{}')" Bash ""

# Record shape: valid JSON line with a UTC timestamp, the session id, and no deny fields on an ordinary call.
newdir
run_hook "$(input Bash '{"command":"ls"}')"
log=$(log_of "$D")
if [ -n "$log" ] && last "$log" | jq -e '(.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and .session == "sess-1" and (has("event") | not) and (has("hook") | not)' >/dev/null 2>&1; then ok; else bad "record shape: $(last "$log" 2>/dev/null)"; fi
case $log in */audit-"$(date +%Y-%m)".log) ok ;; *) bad "log name is not audit-YYYY-MM.log: $log" ;; esac

newdir
run_hook "$(jq -nc --arg d "$D" '{tool_name: "Bash", cwd: $d, tool_input: {command: "ls"}}')"
log=$(log_of "$D")
if [ -n "$log" ] && last "$log" | jq -e '.session == "unknown"' >/dev/null 2>&1; then ok; else bad "missing session_id should log unknown: $(last "$log" 2>/dev/null)"; fi

# Appends one line per call; every line is valid JSON.
newdir
run_hook "$(input Bash '{"command":"one"}')"; run_hook "$(input Bash '{"command":"two"}')"; run_hook "$(input Bash '{"command":"three"}')"
log=$(log_of "$D")
if [ -n "$log" ] && [ "$(wc -l < "$log" | tr -d ' ')" = 3 ] && jq -e . "$log" >/dev/null 2>&1; then ok; else bad "append: expected 3 JSON lines in ${log:-none}"; fi

# Deny events (the denying hooks re-emit their stdin with _audit_event, _deny_hook, _deny_reason).
newdir
run_hook "$(jq -nc --arg d "$D" '{tool_name: "Bash", cwd: $d, tool_input: {command: "git reset --hard"}, _audit_event: "deny", _deny_hook: "destructive-blocker", _deny_reason: "Git hard reset"}')"
log=$(log_of "$D")
if [ -n "$log" ] && last "$log" | jq -e '.event == "deny" and .hook == "destructive-blocker" and .reason == "Git hard reset" and .detail == "git reset --hard"' >/dev/null 2>&1; then ok; else bad "deny event fields: $(last "$log" 2>/dev/null)"; fi

# Redaction. Each secret shape must be masked in the detail and in a deny reason.
JWT="ey""Jhbgcio.ey""Jzdwiio.c2lnbmF0dXJl"
redact_case() {  # redact_case <label> <secret text> <expected marker substring>
  local label=$1 secret=$2 marker=$3 log
  newdir
  run_hook "$(input Bash "$(jq -nc --arg c "echo $secret done" '{command: $c}')")"
  log=$(log_of "$D")
  if [ -z "$log" ]; then bad "redact $label: no log"; return; fi
  if last "$log" | jq -e --arg m "$marker" '.detail | contains($m)' >/dev/null 2>&1 && ! grep -qF -- "$secret" "$log"; then ok; else bad "redact $label: $(last "$log")"; fi
}
redact_case "jwt"            "$JWT"                              "[REDACTED_JWT]"
redact_case "new relic key"  "NR""AK-ABCDEFGHIJKLMNOP"           "[REDACTED_NRKEY]"
redact_case "aws key"        "AK""IAABCDEFGHIJKLMNOP"            "[REDACTED_AWSKEY]"
redact_case "aws temp key"   "AS""IAABCDEFGHIJKLMNOP"            "[REDACTED_AWSKEY]"
redact_case "github token"   "gh""p_abcdefghijklmnopqrstuvwx"    "[REDACTED_GHTOKEN]"
redact_case "github pat"     "github_""pat_abcdefghijklmnop"     "[REDACTED_GHTOKEN]"
redact_case "gitlab token"   "glp""at-abcdefghijklmnopqrst"      "[REDACTED_GLPAT]"
redact_case "api key"        "sk-""ant-api03-ABCDEFGHIJKLMNOP"   "[REDACTED_APIKEY]"
redact_case "project key"    "sk-""proj-ABCDEFGHIJKLMNOPQRSTUV"  "[REDACTED_APIKEY]"
redact_case "api key after a literal backslash-n" "a\\nsk-""ant-api03-ABCDEFGHIJKLMNOP" "[REDACTED_APIKEY]"
redact_case "api key after a literal backslash-t" "a\\tsk-""ant-api03-ABCDEFGHIJKLMNOP" "[REDACTED_APIKEY]"
redact_case "api key after an underscore"         "KEY_sk-""ant-api03-ABCDEFGHIJKLMNOP"  "[REDACTED_APIKEY]"
redact_case "api key after a hyphen"              "x-sk-""ant-api03-ABCDEFGHIJKLMNOP"    "[REDACTED_APIKEY]"
newdir
run_hook "$(input Bash '{"command":"pip install flask-cors && npm run task-build-and-deploy"}')"
log=$(log_of "$D")
if [ -n "$log" ] && last "$log" | jq -e '.detail | contains("flask-cors && npm run task-build-and-deploy")' >/dev/null 2>&1; then ok; else bad "words with sk- kept: $(last "$log" 2>/dev/null)"; fi
redact_case "stripe live"    "sk_""live_ABCDEFGHIJKLMNOP"        "[REDACTED_STRIPE]"
redact_case "google key"     "AI""zaABCDEFGHIJKLMNOP"            "[REDACTED_GOOGLE]"
redact_case "slack token"    "xo""xb-1234-abcdef"                "[REDACTED_SLACK]"
redact_case "pem header"     "-----BEGIN RSA PRIVATE ""KEY-----" "[REDACTED_PEM]"
redact_case "db password"    "postgres://admin:hunter2pw@db.invalid/app" "postgres://admin:[REDACTED]@"
redact_case "key=value"      "api_key=abc123def456"              "api_key=[REDACTED]"
redact_case "suffixed name"  "AWS_SECRET_ACCESS_KEY=""abc123def456" "AWS_SECRET_ACCESS_KEY=[REDACTED]"
redact_case "pass suffix"    "DB_PASS=""abc123def456"            "DB_PASS=[REDACTED]"
newdir
run_hook "$(input Bash '{"command":"echo Tests passed: 5"}')"
log=$(log_of "$D")
if [ -n "$log" ] && last "$log" | jq -e '.detail | contains("passed: 5")' >/dev/null 2>&1; then ok; else bad "plain passed: redacted: $(last "$log" 2>/dev/null)"; fi
redact_case "password flag"  "password: s3cretvalue"             "password: [REDACTED]"
redact_case "bearer header"  "Bearer abcDEF123.xyz"              "Bearer [REDACTED]"

# A PEM key cut before its END line: the base64 body goes with the header, up to the first character outside the
# PEM alphabet (base64, whitespace, `:,-`, and a literal backslash-n, -r or -t). Bodies here are made-up filler.
PEM_HDR="-----BEGIN RSA PRIVATE ""KEY-----"
PEM_END="-----END RSA PRIVATE ""KEY-----"
PEM_B1="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo0123456789+/abcdefghijklmnop"
PEM_B2="qrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+/=="
pem_case() {  # pem_case <label> <command text> <leaked substring> <substring that must survive, or empty>
  local label=$1 cmd=$2 leak=$3 keep=$4 log
  newdir
  run_hook "$(input Bash "$(jq -nc --arg c "$cmd" '{command: $c}')")"
  log=$(log_of "$D")
  if [ -z "$log" ]; then bad "pem $label: no log"; return; fi
  if last "$log" | jq -e --arg k "$keep" '.detail | contains("[REDACTED_PEM]") and ($k == "" or contains($k))' >/dev/null 2>&1 \
     && ! grep -qF -- "$leak" "$log" && ! grep -qF -- "$PEM_HDR" "$log"; then ok; else bad "pem $label: $(last "$log" | cut -c1-200)"; fi
}
pem_case "cut key, body gone"         "printf '$PEM_HDR"$'\n'"$PEM_B1"$'\n'"$PEM_B2'; echo kept"  "$PEM_B1" "echo kept"
pem_case "cut key, second body line"  "printf '$PEM_HDR"$'\n'"$PEM_B1"$'\n'"$PEM_B2'; echo kept"  "$PEM_B2" "echo kept"
PEM_TOK="QUJD""AKIA""ABCDEFGH""AIza""Sy12345678""ASIA""ABCDEFGH""ZZZZ"
pem_case "cut key, AWS and Google shapes in the body" "printf '$PEM_HDR"$'\\n'"$PEM_TOK"$'\\n'"$PEM_B2'; echo kept" "$PEM_B2" "echo kept"
pem_case "cut key, header only"       "echo '$PEM_HDR'"                                             "$PEM_HDR" ""
pem_case "cut key, literal backslash-n" "echo '$PEM_HDR\\n$PEM_B1\\n$PEM_B2'; echo kept"        "$PEM_B1" "echo kept"
pem_case "cut encrypted key"          "printf '$PEM_HDR"$'\n'"Proc-Type: 4,ENCRYPTED"$'\n'"DEK-Info: AES-128-CBC,0123456789ABCDEF"$'\n\n'"$PEM_B1'; echo kept" "$PEM_B1" "echo kept"
pem_case "complete block, text after kept" "printf '$PEM_HDR"$'\n'"$PEM_B1"$'\n'"$PEM_END'; echo kept" "$PEM_B1" "echo kept"
# The same shape in a deny reason.
newdir
run_hook "$(jq -nc --arg d "$D" --arg r "blocked $PEM_HDR $PEM_B1" '{tool_name: "Bash", cwd: $d, tool_input: {command: "ls"}, _audit_event: "deny", _deny_hook: "h", _deny_reason: $r}')"
log=$(log_of "$D")
if [ -n "$log" ] && last "$log" | jq -e '.reason | contains("[REDACTED_PEM]")' >/dev/null 2>&1 && ! grep -qF -- "$PEM_B1" "$log"; then ok; else bad "cut key in a deny reason: $(last "$log" 2>/dev/null)"; fi
# Many headers and no END: one match must eat the whole run (the old header-only rule made one replacement per header
# and took 7 s on 6,000). 3,000 headers is 96 KB; a Linux argv element is capped at 128 KB, and the hook passes the
# command to jq as one.
newdir
PEM_MANY=$(for _ in $(seq 1 3000); do printf '%s ' "$PEM_HDR"; done)
T0=$SECONDS
run_hook "$(input Bash "$(jq -nc --arg c "$PEM_MANY" '{command: $c}')")"
log=$(log_of "$D")
if [ -n "$log" ] && [ $((SECONDS - T0)) -le 5 ] && last "$log" | jq -e '.detail | (split("[REDACTED_PEM]") | length) == 2' >/dev/null 2>&1 && ! grep -qF -- "$PEM_HDR" "$log"; then ok; else bad "many PEM headers: $((SECONDS - T0)) s, $(last "${log:-/dev/null}" 2>/dev/null | cut -c1-120)"; fi

# A secret in a deny reason is redacted too.
newdir
run_hook "$(jq -nc --arg d "$D" --arg r "leaked $JWT here" '{tool_name: "Bash", cwd: $d, tool_input: {command: "ls"}, _audit_event: "deny", _deny_hook: "h", _deny_reason: $r}')"
log=$(log_of "$D")
if [ -n "$log" ] && last "$log" | jq -e '.reason | contains("[REDACTED_JWT]")' >/dev/null 2>&1 && ! grep -qF -- "$JWT" "$log"; then ok; else bad "deny reason redaction: $(last "$log" 2>/dev/null)"; fi

# Truncation to 300 chars, applied after redaction so a secret on the boundary is masked before it is cut.
newdir
run_hook "$(input Bash "$(jq -nc --arg c "$(printf 'a%.0s' $(seq 1 400))" '{command: $c}')")"
log=$(log_of "$D")
if [ -n "$log" ] && last "$log" | jq -e '(.detail | length) == 300' >/dev/null 2>&1; then ok; else bad "truncation to 300: $(last "$log" 2>/dev/null | cut -c1-80)"; fi
newdir
PAD=$(printf 'a%.0s' $(seq 1 290))
run_hook "$(input Bash "$(jq -nc --arg c "$PAD gh""p_abcdefghijklmnopqrstuvwx" '{command: $c}')")"
log=$(log_of "$D")
if [ -n "$log" ] && ! grep -q 'ghp_' "$log" && ! grep -q 'gh''p_abc' "$log"; then ok; else bad "secret straddling the cut leaked: $(last "$log" 2>/dev/null | cut -c250-)"; fi

# Log location: the git root of the cwd, not the cwd itself.
newdir
git init -q "$D/repo" && mkdir -p "$D/repo/sub/dir"
echo .archive/ > "$D/repo/.gitignore"
run_hook "$(jq -nc --arg d "$D/repo/sub/dir" '{tool_name: "Bash", cwd: $d, tool_input: {command: "ls"}}')"
if [ -n "$(log_of "$D/repo")" ] && [ -z "$(log_of "$D/repo/sub/dir")" ]; then ok; else bad "log should land at the git root"; fi

# .gitignore warnings (stderr only, never a failure).
newdir
run_hook "$(input Bash '{"command":"ls"}')"
if [ "$RC" = 0 ] && [ -z "$ERR" ]; then ok; else bad "gitignore with .archive: rc=$RC err=$ERR"; fi
newdir; printf 'node_modules\n' > "$D/.gitignore"
run_hook "$(input Bash '{"command":"ls"}')"
case $ERR in *"not in .gitignore"*) [ "$RC" = 0 ] && ok || bad "gitignore without .archive: rc=$RC" ;; *) bad "gitignore without .archive: no warning (err=$ERR)" ;; esac
newdir; rm -f "$D/.gitignore"
run_hook "$(input Bash '{"command":"ls"}')"
case $ERR in *"no .gitignore found"*) [ "$RC" = 0 ] && ok || bad "no gitignore: rc=$RC" ;; *) bad "no gitignore: no warning (err=$ERR)" ;; esac
if [ -n "$(log_of "$D")" ]; then ok; else bad "no gitignore: the log should still be written"; fi

# Writes nothing, prints nothing, exits 0 with no cwd.
newdir
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "$SH" "$HOOK" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok; else bad "no cwd: rc=$rc out=$out"; fi
out=$(printf '%s' '' | "$SH" "$HOOK" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok; else bad "empty input: rc=$rc out=$out"; fi

# Fails open on input that is not JSON and on a log folder it cannot write: exit 0.
out=$(printf '%s' 'not json' | "$SH" "$HOOK" 2>/dev/null); rc=$?
if [ "$rc" = 0 ]; then ok; else bad "non-JSON input: rc=$rc"; fi
newdir; chmod 500 "$D"
run_hook "$(input Bash '{"command":"ls"}')"
chmod 700 "$D"
if [ "$RC" = 0 ]; then ok; else bad "unwritable log folder: rc=$RC"; fi

# Fails open without jq: no output, exit 0, nothing written.
newdir
out=$(input Bash '{"command":"ls"}' | PATH=/nonexistent "$SH" "$HOOK" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ] && [ -z "$(log_of "$D")" ]; then ok; else bad "no-jq fail-open: rc=$rc out=$out"; fi

echo "audit-logger: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
