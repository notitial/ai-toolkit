#!/bin/bash
# Tests for hooks/secret-redact-output.sh (HOOK=<path> tests another copy). Run: bash tools/secret-redact-output/test-secret-redact-output.sh
# Each case feeds a PostToolUse JSON to the hook and checks the updatedToolOutput it returns (or that it returns
# nothing). Every secret is a made-up placeholder assembled from fragments at run time, so this file holds no
# contiguous key token (secret-detector.sh scans Write/Edit content).

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../../hooks/secret-redact-output.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
SH="${HOOK_SHELL:-/bin/bash}"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

BODY36=abcdefghijklmnopqrstuvwxyz0123456789
BODY20=ABCDEFGHIJKLMNOPQRST
GH="gh""p_$BODY36"
GHS="gh""s_$BODY36"
GHU="gh""u_$BODY36"
GHR="gh""r_$BODY36"
GHO="gh""o_$BODY36"
GHPAT="github_""pat_${BODY36}_ABCDEF"
ANT="sk-""ant-api03-${BODY20}1234"
OAI="sk""-${BODY20}${BODY20}"
AWS="AK""IA${BODY20:0:16}"
GOOG="AI""za${BODY36}ABCDEFG"
SLACK="xo""xb-1234567890-abcdef"
JWT="ey""Jhbgcio.ey""Jzdwiio.c2lnbmF0dXJl"
PEM_HEAD="-----BEGIN RSA PRIVATE ""KEY-----"
PEM_END="-----END RSA PRIVATE ""KEY-----"
TASKISH="ta""sk-${BODY36}"

bash_resp() { jq -nc --arg s "$1" --arg e "${2:-}" '{tool_name:"Bash",tool_response:{stdout:$s,stderr:$e,interrupted:false,isImage:false,noOutputExpected:false}}'; }
mcp_resp()  { jq -nc --arg s "$1" '{tool_name:"mcp__example__query_apps",tool_response:[{type:"text",text:$s}]}'; }
run()       { printf '%s' "$1" | "$SH" "$HOOK" 2>/dev/null; }
upd()       { run "$1" | jq -c '.hookSpecificOutput.updatedToolOutput' 2>/dev/null; }

redacts() {
  local out; out=$(upd "$2")
  if [ -z "$out" ] || [ "$out" = null ]; then bad "$1: no replacement returned"; return; fi
  if printf '%s' "$out" | grep -qF -- "$3"; then bad "$1: secret still present"; return; fi
  if [ -n "${4:-}" ] && ! printf '%s' "$out" | grep -qF -- "$4"; then bad "$1: marker $4 missing in $out"; return; fi
  ok
}
passes() {
  local out; out=$(run "$2")
  if [ -z "$out" ]; then ok; else bad "$1: unexpected output: $out"; fi
}

# --- Bash: token shapes
redacts "github pat in stdout"        "$(bash_resp "x $GH y")" "$GH" "[REDACTED:github-token]"
redacts "github app token"            "$(bash_resp "$GHS")" "$GHS" "[REDACTED:github-token]"
redacts "github user-to-server"       "$(bash_resp "$GHU")" "$GHU" "[REDACTED:github-token]"
redacts "github refresh token"        "$(bash_resp "$GHR")" "$GHR" "[REDACTED:github-token]"
redacts "github oauth token"          "$(bash_resp "$GHO")" "$GHO" "[REDACTED:github-token]"
redacts "github fine-grained"         "$(bash_resp "$GHPAT")" "$GHPAT" "[REDACTED:github-token]"
redacts "anthropic key"               "$(bash_resp "k=$ANT")" "$ANT" "[REDACTED:"
redacts "openai-style key"            "$(bash_resp "$OAI")" "$OAI" "[REDACTED:api-key]"
redacts "aws access key"              "$(bash_resp "id $AWS")" "$AWS" "[REDACTED:aws-key]"
redacts "google key"                  "$(bash_resp "$GOOG")" "$GOOG" "[REDACTED:google-key]"
redacts "slack token"                 "$(bash_resp "$SLACK")" "$SLACK" "[REDACTED:slack-token]"
redacts "jwt"                         "$(bash_resp "t $JWT")" "$JWT" "[REDACTED:jwt]"
redacts "bearer header"               "$(bash_resp "Authorization: Bearer ${BODY36}")" "$BODY36" "[REDACTED:bearer]"
redacts "url password"                "$(bash_resp "https://user:pa55w0rd-x@example.invalid/r.git")" "pa55w0rd-x" "://user:[REDACTED:password]@"
redacts "x-auth-key header"           "$(bash_resp "X-Auth-Key: ${BODY36}")" "$BODY36" "[REDACTED:value]"

# --- Bash: env files and env listings
redacts "env file ACCESS_TOKEN="      "$(bash_resp "APP_NAME=x
ACCESS_TOKEN=${BODY36}
LABELS=a")" "$BODY36" "ACCESS_TOKEN=[REDACTED:value]"
redacts "env listing, key name only"  "$(bash_resp "HOME=/Users/x
MY_API_KEY=${BODY36}
PATH=/usr/bin")" "$BODY36" "MY_API_KEY=[REDACTED:value]"
JSONTOK='{"access_token": "'"$BODY36"'", "name": "x"}'
redacts "json token field"            "$(bash_resp "$JSONTOK")" "$BODY36" "[REDACTED:value]"
redacts "password colon form"         "$(bash_resp "password: ${BODY36}")" "$BODY36" "[REDACTED:value]"

# --- PEM
redacts "pem block"                   "$(bash_resp "a
$PEM_HEAD
MIIEvQIBADANBgkqhkiG9w0BAQEFAASC
KgwggSkAgEAAoIBAQC7
$PEM_END
b")" "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC" "[REDACTED:private-key]"
redacts "pem block without end line"  "$(bash_resp "$PEM_HEAD
MIIEvQIBADANBgkqhkiG9w0BAQEFAASC
KgwggSkAgEAAoIBAQC7")" "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC" "[REDACTED:private-key]"

# --- MCP shapes
redacts "mcp content blocks"          "$(mcp_resp "app config: {\"token\": \"${BODY36}\"}")" "$BODY36" "[REDACTED:value]"
redacts "mcp github token in text"    "$(mcp_resp "env GITHUB_TOKEN=$GH")" "$GH"
redacts "mcp plain string response"   "$(jq -nc --arg s "$GH" '{tool_name:"mcp__x__y",tool_response:$s}')" "$GH" "[REDACTED:github-token]"
redacts "mcp nested object"           "$(jq -nc --arg s "$GH" '{tool_name:"mcp__x__y",tool_response:{content:[{type:"text",text:$s}],isError:false}}')" "$GH" "[REDACTED:github-token]"

# --- Bash output shape: exactly the four fields, even when the input carried a fifth
shape=$(upd "$(bash_resp "x $GH")" | jq -c 'keys')
if [ "$shape" = '["interrupted","isImage","stderr","stdout"]' ]; then ok; else bad "bash shape: $shape"; fi
stderr_kept=$(upd "$(bash_resp "x $GH" "warn: keep me")" | jq -r '.stderr')
if [ "$stderr_kept" = "warn: keep me" ]; then ok; else bad "stderr not preserved: $stderr_kept"; fi
redacts "secret in stderr"            "$(bash_resp "ok" "token=${BODY36}")" "$BODY36"
env_ok=$(run "$(bash_resp "x $GH")" | jq -r '.hookSpecificOutput.hookEventName')
if [ "$env_ok" = "PostToolUse" ]; then ok; else bad "hookEventName: $env_ok"; fi

# --- no change, no output (false positives and clean output)
passes "clean output"                 "$(bash_resp "total 8
-rw-r--r-- 1 u g 12 file.txt")"
passes "short sk- prefix"             "$(bash_resp "sk""-abc")"
passes "sk- inside a word"            "$(bash_resp "$TASKISH and risk-owner-task-id-for-review")"
passes "aws prefix too short"         "$(bash_resp "AK""IASHORT")"
passes "github token placeholder"     "$(bash_resp "GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}")"
passes "short secret-named value"     "$(bash_resp "PASSWORD=short")"
passes "var reference value"          "$(bash_resp "export API_KEY=\$API_KEY_FROM_KEYCHAIN")"
passes "github prefix without a body" "$(bash_resp "gh""p_")"
passes "plain https url"              "$(bash_resp "https://example.invalid/path?x=1")"
passes "url with user only"           "$(bash_resp "git@example.invalid:o/r.git ssh://git@example.invalid/o/r.git")"
passes "empty output"                 "$(bash_resp "")"
passes "image result left alone"      "$(jq -nc --arg s "$GH" '{tool_name:"Bash",tool_response:{stdout:$s,stderr:"",interrupted:false,isImage:true}}')"
passes "no tool_response"             '{"tool_name":"Bash"}'
passes "null tool_response"           '{"tool_name":"Bash","tool_response":null}'
passes "already redacted"             "$(bash_resp "ACCESS_TOKEN=[REDACTED:value] and [REDACTED:github-token]")"

# --- idempotence: feeding the redacted output back changes nothing
first=$(upd "$(bash_resp "ACCESS_TOKEN=${BODY36} $GH")" | jq -r '.stdout')
case "$first" in *"[REDACTED:"*) ok ;; *) bad "idempotence setup produced no redaction: $first" ;; esac
passes "second pass is a no-op"       "$(bash_resp "$first")"

# --- fail open
passes "malformed JSON"               'not json'
passes "empty input"                  ''
nojq=$(printf '%s' "$(bash_resp "x $GH")" | env -i PATH=/nonexistent /bin/bash "$HOOK" 2>/dev/null; echo "rc=$?")
if [ "$nojq" = "rc=0" ]; then ok; else bad "no jq: $nojq"; fi
bigout=$(jq -nc --arg t "$GH" '{tool_name:"Bash",tool_response:{stdout:(("a" * 4100000) + " " + $t),stderr:"",interrupted:false,isImage:false}}' | "$SH" "$HOOK" 2>/dev/null)
if [ -z "$bigout" ]; then ok; else bad "oversized input was processed"; fi
bigerr=$(jq -nc --arg t "$GH" '{tool_name:"Bash",tool_response:{stdout:(("a" * 4100000) + " " + $t),stderr:"",interrupted:false,isImage:false}}' | "$SH" "$HOOK" 2>&1 >/dev/null)
case "$bigerr" in *"over 4 MB"*) ok ;; *) bad "oversized input gave no stderr note: $bigerr" ;; esac

# --- generic rule: readable output stays readable
passes "path value with credentials"  "$(bash_resp "GOOGLE_APPLICATION_CREDENTIALS=/Users/x/.config/gcloud/application_default_credentials.json")"
passes "password store dir"           "$(bash_resp "PASSWORD_STORE_DIR=/Users/x/.password-store")"
passes "git credential helper"        "$(bash_resp "credential.helper=/usr/local/share/gcm-core/git-credential-manager")"
passes "code reference to a getter"   "$(bash_resp "const token=getAuthTokenFromStorage()")"
passes "env reference in code"        "$(bash_resp "apiKey: process.env.OPENAI_API_KEY,")"
passes "form getter in code"          "$(bash_resp "password = request.form.get('password')")"
passes "secret name value"            "$(bash_resp "secretName: postgres-credentials-prod")"
passes "nextPageToken cursor"         "$(bash_resp "$(printf '{"nextPageToken": "%s"}' "CiAKGjBpNDd2NWFHRlBuSmpTRDJ1dHJh1234")")"
passes "NextContinuationToken"        "$(bash_resp "NextContinuationToken=CiAKGjBpNDd2NWFHRlBuSmpTRDJ1dHJh1234")"
passes "next_page_token env"          "$(bash_resp "next_page_token=CiAKGjBpNDd2NWFHRlBuSmpTRDJ1dHJh1234")"

# --- generic rule: no tail left behind, other separators and shapes
redacts "symbol inside the value"     "$(bash_resp "password=abcdefghijklmnop!TailOfSecret99")" "TailOfSecret99" "[REDACTED:value]"
redacts "symbols from the start"      "$(bash_resp "password=P@ssw0rd!Long#Secret1234")" "Long#Secret1234" "[REDACTED:value]"
ESCJSON='{"SecretString":"{\"password\":\"'"$BODY36"'\"}"}'
redacts "escaped json in a string"    "$(bash_resp "$ESCJSON")" "$BODY36" "[REDACTED:value]"
redacts "redis url, empty username"   "$(bash_resp "redis://:s3cretpass9@cache.invalid:6379")" "s3cretpass9" "[REDACTED:password]"
redacts "stripe live key"             "$(bash_resp "k ""sk""_live_${BODY20}1234")" "live_${BODY20}1234" "[REDACTED:stripe-key]"
redacts "gitlab token"                "$(bash_resp "glp""at-${BODY20}1234")" "${BODY20}1234" "[REDACTED:gitlab-token]"
redacts "authorization basic"         "$(bash_resp "Authorization: Basic dXNlcjpwYXNzd29yZDEyMzQ1Njc4")" "dXNlcjpwYXNzd29yZDEyMzQ1Njc4" "[REDACTED:value]"
redacts "session cookie"              "$(bash_resp "Cookie: session=${BODY36}; theme=dark")" "$BODY36" "[REDACTED:value]"
redacts "cli password flag"           "$(bash_resp "mysql --password ${BODY36} -h db")" "$BODY36" "[REDACTED:value]"
redacts "openai project key"          "$(bash_resp "sk""-proj-${BODY20}_${BODY20}")" "$BODY20" "[REDACTED:api-key]"

# --- more cloud and vendor token shapes
B64=$BODY36$BODY36
redacts "google refresh token"        "$(bash_resp "t 1//0${B64:0:40}")" "${B64:0:40}" "[REDACTED:google-refresh-token]"
redacts "google client secret"        "$(bash_resp "GOC""SPX-${BODY20}1234")" "${BODY20}1234" "[REDACTED:google-client-secret]"
redacts "google access token"         "$(bash_resp "ya""29.${BODY20}1234")" "${BODY20}1234" "[REDACTED:google-access-token]"
redacts "id-prefixed api key"         "$(bash_resp "key 1-${B64:0:64}")" "${B64:0:64}" "[REDACTED:api-key]"
passes "digits-dash short run"        "$(bash_resp "build 12-${BODY20}")"

# --- PEM spans stay inside the key
PEMCODE=$(printf '%s";\nrun_something(x);\n' "$PEM_HEAD")
passes_code=$(upd "$(bash_resp "$PEMCODE
$PEM_END")" | jq -r '.stdout')
if printf '%s' "$passes_code" | grep -qF "run_something(x);"; then ok; else bad "pem rule swallowed code: $passes_code"; fi

# --- MCP shape handling
MCPOBJ=$(jq -nc --arg s "x $GH" '{tool_name:"mcp__x__exec",tool_response:{stdout:$s,exitCode:1,isError:true}}')
mcp_keys=$(upd "$MCPOBJ" | jq -c 'keys')
if [ "$mcp_keys" = '["exitCode","isError","stdout"]' ]; then ok; else bad "mcp object keys changed: $mcp_keys"; fi
MCPIMG=$(jq -nc --arg s "x $GH" '{tool_name:"mcp__x__shot",tool_response:{text:$s,isImage:true}}')
redacts "mcp object with isImage"     "$MCPIMG" "$GH" "[REDACTED:github-token]"

# --- hostile input cannot stall the hook: each fixture is ~1 MB and must finish fast and still redact
timed() {
  local label=$1 json=$2 secret=$3 t0 t1 out
  t0=$(date +%s)
  out=$(printf '%s' "$json" | "$SH" "$HOOK" 2>/dev/null)
  t1=$(date +%s)
  if [ $((t1 - t0)) -gt 8 ]; then bad "$label: took $((t1 - t0))s"; return; fi
  if [ -z "$out" ] || printf '%s' "$out" | grep -qF -- "$secret"; then bad "$label: real secret not redacted"; return; fi
  ok
}
timed "long word run" "$(jq -nc --arg t "ACCESS_TOKEN=$BODY36" '{tool_name:"Bash",tool_response:{stdout:(("a" * 1000000) + "\n" + $t),stderr:"",interrupted:false,isImage:false}}')" "$BODY36"
timed "repeated sk- run" "$(jq -nc --arg t "ACCESS_TOKEN=$BODY36" '{tool_name:"Bash",tool_response:{stdout:(("sk-" * 300000) + "\n" + $t),stderr:"",interrupted:false,isImage:false}}')" "$BODY36"
timed "repeated pem headers" "$(jq -nc --arg h "$PEM_HEAD " --arg t "ACCESS_TOKEN=$BODY36" '{tool_name:"Bash",tool_response:{stdout:(($h * 30000) + "\n" + $t),stderr:"",interrupted:false,isImage:false}}')" "$BODY36"
timed "keyword flood" "$(jq -nc --arg t "ACCESS_TOKEN=$BODY36" '{tool_name:"Bash",tool_response:{stdout:(("token" * 150000) + "\n" + $t),stderr:"",interrupted:false,isImage:false}}')" "$BODY36"

# --- escaped and CRLF PEM, many lines, dense matches, URL values, extra key names
PEMBODY=MIIEvQIBADANBgkqhkiG9w0BAQEFAASC
PEMESC=$(printf '{"private_key": "%s\\n%s\\nKgwggSkAgEAAoIBAQC7\\n%s\\n", "token_uri": "https://oauth2.example.invalid/token"}' "$PEM_HEAD" "$PEMBODY" "$PEM_END")
redacts "json-escaped pem"            "$(bash_resp "$PEMESC")" "$PEMBODY" "[REDACTED:private-key]"
PEMESC2=$(printf '{"x": "%s\\\\n%s\\\\n%s"}' "$PEM_HEAD" "$PEMBODY" "$PEM_END")
redacts "double-escaped pem"          "$(bash_resp "$PEMESC2")" "$PEMBODY" "[REDACTED:private-key]"
PEMCRLF=$(printf '%s\r\n%s\r\n%s\r\n' "$PEM_HEAD" "$PEMBODY" "$PEM_END")
redacts "crlf pem"                    "$(bash_resp "$PEMCRLF")" "$PEMBODY" "[REDACTED:private-key]"
passes "url value after token name"   "$(bash_resp '"token_uri": "https://oauth2.example.invalid/token", "token_endpoint": "https://idp.example.invalid/oauth2/v2.0/token"')"
redacts "DB_PASS name"                "$(bash_resp "DB_PASS=${BODY36}")" "$BODY36" "[REDACTED:value]"
redacts "APP_KEY name"                "$(bash_resp "APP_KEY=base64:${BODY36}")" "$BODY36" "[REDACTED:value]"
timed "many empty lines" "$(jq -nc --arg t "ACCESS_TOKEN=$BODY36" '{tool_name:"Bash",tool_response:{stdout:(("\n" * 300000) + $t),stderr:"",interrupted:false,isImage:false}}')" "$BODY36"
timed "dense url matches" "$(jq -nc --arg t "ACCESS_TOKEN=$BODY36" '{tool_name:"Bash",tool_response:{stdout:(("://:abc@" * 125000) + "\n" + $t),stderr:"",interrupted:false,isImage:false}}')" "$BODY36"
timed "many short lines" "$(jq -nc --arg t "ACCESS_TOKEN=$BODY36" '{tool_name:"Bash",tool_response:{stdout:(("ab cd ef\n" * 100000) + $t),stderr:"",interrupted:false,isImage:false}}')" "$BODY36"

passes "help text for a token flag"   "$(bash_resp "  --token   Authentication token for the API
  --password  Password to use")"
redacts "token flag with a real value" "$(bash_resp "tool --token ${BODY36} run")" "$BODY36" "[REDACTED:value]"
timed "millions of tiny lines" "$(jq -nc --arg t "ACCESS_TOKEN=$BODY36" '{tool_name:"Bash",tool_response:{stdout:(("a\n" * 900000) + $t),stderr:"",interrupted:false,isImage:false}}')" "$BODY36"
timed "190 pem headers" "$(jq -nc --arg h "$PEM_HEAD " --arg t "ACCESS_TOKEN=$BODY36" '{tool_name:"Bash",tool_response:{stdout:(($h * 190) + "\n" + $t),stderr:"",interrupted:false,isImage:false}}')" "$BODY36"

# --- a long line is cut into 2 KB blocks; a token across a cut is still redacted whole
long_resp() { jq -nc --arg t "$1" --arg f "$2" --argjson o "$3" '{tool_name:"Bash",tool_response:{stdout:(($f * $o) + $t + ("," * 3000)),stderr:"",interrupted:false,isImage:false}}'; }
for off in 2030 2040 2047 4080 6130; do
  redacts "github token across a cut at $off" "$(long_resp "$GH" "," "$off")" "${BODY36:16}" "[REDACTED:github-token]"
done
redacts "env value across a cut"      "$(long_resp "ACCESS_TOKEN=$BODY36" "x " 1015)" "${BODY36:5}" "ACCESS_TOKEN=[REDACTED:value]"
URLPW=pa55w0rdpa55w0rdab12
redacts "url password ending on a cut" "$(long_resp "https://u:$URLPW@example.invalid" "," 2018)" "$URLPW" "://u:[REDACTED:password]@"
edge_out=$(upd "$(long_resp "$GH" "é," 1015)" | jq -r '.stdout')
edge_want=$(jq -nr '("é," * 1015) + "[REDACTED:github-token]" + ("," * 3000)')
if [ "$edge_out" = "$edge_want" ]; then ok; else bad "long line not rebuilt exactly (${#edge_out} chars)"; fi

# --- the hook never emits a permission decision
for j in "$(bash_resp "x $GH")" "$(mcp_resp "$GH")"; do
  if run "$j" | jq -e '.hookSpecificOutput | has("permissionDecision") or has("decision")' >/dev/null 2>&1; then bad "emitted a decision"; else ok; fi
done

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
