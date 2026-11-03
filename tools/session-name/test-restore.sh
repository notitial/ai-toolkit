#!/usr/bin/env bash
# test-restore.sh: behavioural tests for hooks/session-name-restore.sh. Run the hook under /bin/bash (3.2) and a
# current bash with HOOK_SHELL=<bash> (default: /bin/bash); HOOK=<path> tests another copy. The hook prints a
# SessionStart sessionTitle or nothing, and always exits 0.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../../hooks/session-name-restore.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
PASS=0; FAIL=0
T=$(mktemp -d "${TMPDIR:-/tmp}/sessname-XXXXXX")
trap 'rm -rf "$T"' EXIT

# run <expected title, or - for no output> <label> <stdin>
run() {
  _out=$(printf '%s' "$3" | "${HOOK_SHELL:-/bin/bash}" "$HOOK" 2>/dev/null); _st=$?
  if [ "$_st" != 0 ]; then echo "FAIL  $2 — exit $_st"; FAIL=$((FAIL + 1)); return; fi
  if [ "$1" = - ]; then
    [ -z "$_out" ] && { PASS=$((PASS + 1)); return; }
    echo "FAIL  $2 — expected no output, got $_out"; FAIL=$((FAIL + 1)); return
  fi
  _got=$(printf '%s' "$_out" | jq -r 'select(.hookSpecificOutput.hookEventName == "SessionStart") | .hookSpecificOutput.sessionTitle' 2>/dev/null)
  if [ "$_got" = "$1" ]; then PASS=$((PASS + 1)); else echo "FAIL  $2 — expected '$1', got '$_out'"; FAIL=$((FAIL + 1)); fi
}
inp() {  # inp <source> <session_title or ""> <transcript_path or "">
  jq -nc --arg s "$1" --arg t "$2" --arg p "$3" \
    '{hook_event_name:"SessionStart",session_id:"s1",source:$s} + (if $t == "" then {} else {session_title:$t} end)
     + (if $p == "" then {} else {transcript_path:$p} end)'
}
rec() { jq -nc --arg t "$1" '{type:"custom-title",customTitle:$t,sessionId:"s1"}'; }
msg() { jq -nc --arg c "$1" '{type:"user",message:{content:$c},sessionId:"s1"}'; }

run probe-c        "resume with session_title"          "$(inp resume probe-c "")"
run DEVELOPER      "startup with session_title (-n)"    "$(inp startup DEVELOPER "")"
run -              "fork is not matched"                "$(inp fork probe-c "")"
run -              "compact is not matched"             "$(inp compact probe-c "")"
run -              "clear is not matched"               "$(inp clear probe-c "")"
run -              "resume, no title, no transcript"    "$(inp resume "" "")"
run -              "resume, no title, missing file"     "$(inp resume "" "$T/none.jsonl")"

{ rec OLD; msg hi; rec probe-c; msg bye; } > "$T/a.jsonl"
run probe-c        "resume, no title: last transcript record" "$(inp resume "" "$T/a.jsonl")"
run -              "startup, no title: transcript not read"   "$(inp startup "" "$T/a.jsonl")"
run given          "session_title wins over the transcript"   "$(inp resume given "$T/a.jsonl")"

{ rec real; msg 'quoted "customTitle":"FAKE" in a message'; } > "$T/b.jsonl"
run real           "a quoted record inside a message does not count" "$(inp resume "" "$T/b.jsonl")"
msg 'nothing named here' > "$T/c.jsonl"
run -              "resume, transcript without a record"      "$(inp resume "" "$T/c.jsonl")"

rec 'say "hi" \ there' > "$T/d.jsonl"
run 'say "hi" \ there' "a title with quotes and a backslash"  "$(inp resume "" "$T/d.jsonl")"
run 'a "b" \ c'    "session_title with quotes is JSON-encoded" "$(inp resume 'a "b" \ c' "")"

run -              "malformed input"                     'not json'
run -              "empty input"                         ''
run -              "array input"                         '[]'
run -              "null input"                          'null'
run -              "non-string session_title"            '{"source":"resume","session_title":5}'
run -              "object session_title"                '{"source":"resume","session_title":{"a":1}}'
run -              "non-string source"                   '{"source":["resume"],"session_title":"x"}'

# Only a top-level custom-title record counts: a customTitle key nested in a tool result is not the session's name.
{ rec real; jq -nc '{type:"user",toolUseResult:{customTitle:"FAKE",type:"custom-title"},sessionId:"s1"}'; } > "$T/f.jsonl"
run real           "a nested customTitle in a tool result does not count" "$(inp resume "" "$T/f.jsonl")"
{ rec real; jq -nc '{type:"custom-title",customTitle:"",sessionId:"s1"}'; } > "$T/g.jsonl"
run real           "an empty record does not clear the name" "$(inp resume "" "$T/g.jsonl")"
printf 'x\000y\n' > "$T/h.jsonl"; rec real >> "$T/h.jsonl"
run real           "a NUL byte in the transcript"        "$(inp resume "" "$T/h.jsonl")"

# The 4 MB window: a record further back than that is not read; the session's custom-title.json stands in.
{ rec FAR; head -c 4300000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$T/e.jsonl"
run -              "a record beyond the last 4 MB is not read" "$(inp resume "" "$T/e.jsonl")"
mkdir -p "$T/s1"; printf '{"customTitle":"from-json"}\n' > "$T/s1/custom-title.json"
run from-json      "past the window, custom-title.json"  "$(inp resume "" "$T/e.jsonl")"
run real           "the transcript record wins over custom-title.json" "$(inp resume "" "$T/f.jsonl")"
rm -rf "$T/s1"
# A record cut by the window's first byte is dropped; one whole line later still counts.
{ head -c 4194000 /dev/zero | tr '\0' 'x'; rec CUT; rec whole; } > "$T/i.jsonl"
run whole          "a record split by the window start"  "$(inp resume "" "$T/i.jsonl")"

# No jq: no output, exit 0.
mkdir -p "$T/nojq"; ln -s "$(command -v tail)" "$T/nojq/tail"; ln -s "$(command -v cat)" "$T/nojq/cat"
_out=$(printf '%s' "$(inp resume probe-c "")" | PATH="$T/nojq" "${HOOK_SHELL:-/bin/bash}" "$HOOK" 2>/dev/null); _st=$?
if [ "$_st" = 0 ] && [ -z "$_out" ]; then PASS=$((PASS + 1)); else echo "FAIL  no jq — exit $_st, output '$_out'"; FAIL=$((FAIL + 1)); fi

echo "pass $PASS   fail $FAIL"
[ "$FAIL" = 0 ]
