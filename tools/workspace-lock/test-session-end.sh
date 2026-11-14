#!/bin/bash
# test-session-end.sh: tests for hooks/workspace-lock-session-end.sh. Builds owned locks with the real lock script,
# feeds the hook SessionEnd input and checks what it wrote, kept or left alone, and that it always exits 0. It also
# runs one fixture tree through the guard and the hook and asserts they land on the same lock (the hook carries its
# own copy of the guard's lookup).
#
# Usage: bash tools/workspace-lock/test-session-end.sh      HOOK=<path> / WL_SCRIPT=<path> test other copies.
# Exit 0 = all pass, 1 = any fail. bash 3.2.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK:-$HERE/../../hooks/workspace-lock-session-end.sh}"
GUARD="${GUARD:-$HERE/../../hooks/workspace-lock-guard.sh}"
WL="${WL_SCRIPT:-$HERE/workspace-lock.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi; }

O=aaaaaaaa-0000-4000-8000-000000000001   # owner
M1=bbbbbbbb-0000-4000-8000-000000000002  # members
M2=cccccccc-0000-4000-8000-000000000003
X=dddddddd-0000-4000-8000-000000000004   # a session that is nothing to the lock

wenv() { env -u WORKSPACE_LOCK_ID -u WORKSPACE_LOCK_DIR -u WORKSPACE_LOCK_LOG -u WORKSPACE_LOCK_TEST_POLL "$@"; }
wl() { _d="$1"; shift; wenv WORKSPACE_LOCK_DIR="$_d" "$WL" "$@"; }
# team <name>: an owned lock "t" in $TMP/<name> with owner O and members M1, M2; prints the workspace root
team() {
  mkdir -p "$TMP/$1/sub/deeper"
  _l="$TMP/$1/.workspace-lock"
  wl "$_l" acquire --id t --owned --sid "$O" --eta +1h >/dev/null 2>&1
  wl "$_l" member add --id t --sid "$M1" --by "$O" >/dev/null 2>&1
  wl "$_l" member add --id t --sid "$M2" --by "$O" >/dev/null 2>&1
  echo "$TMP/$1"
}
take() { wl "$1/.workspace-lock" turn take --id t --sid "$2" --eta +10m >/dev/null 2>&1; }
# hook <cwd> <sid> [reason]: run the hook as the CLI would; prints nothing, sets HRC to its exit status
hook() {
  jq -nc --arg s "$2" --arg c "$1" --arg r "${3-other}" '{session_id: $s, cwd: $c, hook_event_name: "SessionEnd", reason: $r}' \
    | wenv /bin/bash "$HOOK" >"$TMP/hook.out" 2>&1
  HRC=$?
}
hook_ok() { [ "$HRC" = 0 ] && [ ! -s "$TMP/hook.out" ]; }
tree() { (cd "$1" && { find . -print | sort; find . -type f -exec cksum {} + | sort; } | tr '\n' ' '); }
logged() { grep -qF -- "$2" "$1/.workspace-lock/workspace-lock.log" 2>/dev/null; }

# --- the turn holder -------------------------------------------------------------------------------
R="$(team a)"; L="$R/.workspace-lock/lock.d"
take "$R" "$M1"
hook "$R" "$M1" prompt_input_exit
hook_ok; check "turn holder: exits 0, no output" $?
[ ! -e "$L/turn.d" ]; check "turn holder: turn.d removed" $?
read -r _e _r < "$L/ended/$M1" 2>/dev/null; case "$_e" in ''|*[!0-9]*) false ;; *) [ "$_r" = prompt_input_exit ] ;; esac
check "turn holder: ended/<sid> holds '<epoch> <reason>'" $?
[ -f "$L/members/$M1" ]; check "turn holder: members/<sid> kept" $?
read -r _ge _gs _gv < "$L/last_give" 2>/dev/null; [ "$_gs" = "$M1" ] && [ "$_gv" = unknown ]
check "turn holder: last_give records '<sid> unknown'" $?
logged "$R" "TURN-FREED-ON-END ${M1%%-*}"; check "turn holder: logs TURN-FREED-ON-END" $?
_o="$(wl "$R/.workspace-lock" turn take --id t --sid "$M1" --eta +10m 2>&1)"
printf '%s' "$_o" | grep -q '^TURN' && printf '%s' "$_o" | grep -qi 'warn'; check "a resumed member takes a turn again and is warned about last_give" $?
[ ! -e "$L/ended/$M1" ]; check "its turn take cleared ended/<sid> (the member's next lock call)" $?

# --- a member without the turn; the turn of someone else -------------------------------------------
R="$(team b)"; L="$R/.workspace-lock/lock.d"
take "$R" "$M2"
hook "$R" "$M1" resume
hook_ok; check "member: exits 0, no output" $?
[ -f "$L/ended/$M1" ] && [ -f "$L/members/$M1" ]; check "member: ended/<sid> written, members/<sid> kept" $?
[ "$(cat "$L/turn.d/sid")" = "$M2" ] && [ ! -e "$L/last_give" ]; check "member: another session's turn and last_give untouched" $?
logged "$R" "MEMBER-ENDED"; check "member: logs MEMBER-ENDED" $?
wl "$R/.workspace-lock" member add --id t --sid "$M1" --by "$O" >/dev/null 2>&1
[ ! -e "$L/ended/$M1" ]; check "member add clears the marker" $?
hook "$R" "$M1" clear; hook "$R" "$M1" resume
read -r _e _r < "$L/ended/$M1"; [ "$_r" = resume ]; check "member: a second end for the same sid rewrites the marker" $?

# --- the owner ---------------------------------------------------------------------------------------
R="$(team c)"; L="$R/.workspace-lock/lock.d"
hook "$R" "$O" other
hook_ok; check "owner: exits 0, no output" $?
[ "$(cat "$L/owner")" = "$O" ] && [ "$(cat "$L/holder")" = t ] && [ -f "$L/members/$M1" ] && [ -f "$L/members/$M2" ] && [ ! -e "$L/ended/$O" ]
check "owner: lock, members and owner untouched, no ended/ marker" $?
logged "$R" "OWNER-ENDED"; check "owner: logs OWNER-ENDED" $?
R="$(team c2)"; L="$R/.workspace-lock/lock.d"
take "$R" "$O"
hook "$R" "$O" other
[ ! -e "$L/turn.d" ] && [ -d "$L" ] && [ "$(cat "$L/owner")" = "$O" ]; check "owner holding the turn: the turn is freed, the lock stays" $?
logged "$R" "TURN-FREED-ON-END" && logged "$R" "OWNER-ENDED"; check "owner holding the turn: logs both" $?

# --- a session that is nothing to the lock --------------------------------------------------------------
R="$(team d)"; take "$R" "$M1"; _before="$(tree "$R")"; _log="$(cat "$R/.workspace-lock/workspace-lock.log" 2>/dev/null)"
hook "$R" "$X" other
hook_ok; check "stranger: exits 0, no output" $?
[ "$(tree "$R")" = "$_before" ] && [ "$(cat "$R/.workspace-lock/workspace-lock.log" 2>/dev/null)" = "$_log" ]; check "stranger: nothing written, nothing logged" $?
[ -d "$R/.workspace-lock/lock.d/turn.d" ]; check "stranger: the turn of a member is untouched" $?

# --- registrations -----------------------------------------------------------------------------------------
R="$TMP/open"; mkdir -p "$R/sub"
wl "$R/.workspace-lock" acquire --id solo-1 --eta +1h >/dev/null 2>&1
mkdir -p "$R/.workspace-lock/sessions"; echo solo-1 > "$R/.workspace-lock/sessions/$X"; echo solo-1 > "$R/.workspace-lock/sessions/$M2"
_before="$(cat "$R/.workspace-lock/lock.d/holder")"
hook "$R/sub" "$X" other
hook_ok; check "open lock: exits 0, no output" $?
[ ! -e "$R/.workspace-lock/sessions/$X" ] && [ -f "$R/.workspace-lock/sessions/$M2" ]; check "open lock: only this session's registration is removed" $?
[ "$(cat "$R/.workspace-lock/lock.d/holder")" = "$_before" ] && [ ! -d "$R/.workspace-lock/lock.d/ended" ]; check "open lock: holder untouched, no owned folders made" $?
R="$(team e)"; mkdir -p "$R/.workspace-lock/sessions"; echo t > "$R/.workspace-lock/sessions/$M1"
hook "$R" "$M1" other
[ ! -e "$R/.workspace-lock/sessions/$M1" ]; check "owned lock: the member's registration is removed too" $?

# --- a free or released workspace ----------------------------------------------------------------------------
mkdir -p "$TMP/free/sub"
hook "$TMP/free/sub" "$M1" other
hook_ok && [ "$(ls -A "$TMP/free")" = sub ]; check "free workspace: exits 0, nothing created" $?
[ ! -e "$TMP/free/.workspace-lock" ] && [ ! -e "$TMP/free/sub/.workspace-lock" ]; check "free workspace: no .workspace-lock anywhere" $?
R="$(team f)"; wl "$R/.workspace-lock" release --id t --sid "$O" >/dev/null 2>&1
_before="$(tree "$R")"
hook "$R" "$M1" other
hook_ok && [ ! -e "$R/.workspace-lock/lock.d" ] && [ "$(tree "$R")" = "$_before" ]; check "released workspace: lock.d is not recreated, nothing written" $?
HRC=0; jq -nc --arg s "$M1" --arg c "$R/sub" '{session_id: $s, cwd: $c, reason: "other"}' | wenv WORKSPACE_LOCK_DIR="$R/.workspace-lock" /bin/bash "$HOOK" >/dev/null 2>&1 || HRC=$?
[ "$HRC" = 0 ] && [ ! -e "$R/.workspace-lock/lock.d" ] && [ "$(tree "$R")" = "$_before" ]; check "released workspace, WORKSPACE_LOCK_DIR set: the same" $?

# --- odd input: always exit 0, never write ------------------------------------------------------------------------
R="$(team g)"; take "$R" "$M1"; _before="$(tree "$R")"
_odd() {  # _odd <label> <stdin text>
  printf '%s' "$2" | wenv /bin/bash "$HOOK" >/dev/null 2>&1; _rc=$?
  [ "$_rc" = 0 ] && [ "$(tree "$R")" = "$_before" ]; check "odd input, $1: exits 0, writes nothing" $?
}
_odd "empty stdin" ""
_odd "not JSON" "not json"
_odd "a JSON array" "[1]"
_odd "no session_id" "{\"cwd\":\"$R\"}"
_odd "no cwd" "{\"session_id\":\"$M1\"}"
_odd "a relative cwd" "{\"session_id\":\"$M1\",\"cwd\":\"sub\"}"
_odd "an uppercase sid" "{\"session_id\":\"$(printf '%s' "$M1" | tr a-f A-F)\",\"cwd\":\"$R\"}"
_odd "a sid with a path in it" "{\"session_id\":\"../../x\",\"cwd\":\"$R\"}"
_odd "a numeric session_id" "{\"session_id\":5,\"cwd\":\"$R\"}"
hook "$R" "$M2" 'a b/../x;$(id)'
read -r _e _r < "$R/.workspace-lock/lock.d/ended/$M2"; [ "$_r" = abxid ]; check "reason: only [A-Za-z0-9_-] survives into ended/<sid>" $?
hook "$R" "$X" ""
hook_ok; check "an empty reason is fine" $?
R="$(team h)"; take "$R" "$M1"; rm -rf "$R/.workspace-lock/lock.d/ended"
hook "$R" "$M1" other
[ ! -e "$R/.workspace-lock/lock.d/ended" ] && [ ! -e "$R/.workspace-lock/lock.d/turn.d" ]; check "no ended/ folder (an older lock): not created, the turn is still freed" $?

# --- a hand-over that cannot be recorded keeps the turn ---------------------------------------------------------------
if [ "$(id -u)" != 0 ]; then
  R="$(team i)"; take "$R" "$M1"; chmod 555 "$R/.workspace-lock/lock.d"
  hook "$R" "$M1" other
  chmod 755 "$R/.workspace-lock/lock.d"
  hook_ok && [ -d "$R/.workspace-lock/lock.d/turn.d" ] && [ -f "$R/.workspace-lock/lock.d/ended/$M1" ]; check "last_give not writable: the turn is kept, ended/<sid> still written, exit 0" $?
  logged "$R" "TURN-KEPT-ON-END"; check "last_give not writable: logs TURN-KEPT-ON-END" $?
  _o="$(wl "$R/.workspace-lock" turn give --id t --sid "$M1" --by "$O" --force --check 2>&1)"
  printf '%s' "$_o" | grep -q '^FORCEABLE-NOW'; check "  ... and the owner's force sees it as forceable at once" $?
fi

# --- guard and hook land on the same lock -------------------------------------------------------------------------------
# The guard denies a stranger's mutation (npm test) only when it resolved an owned lock; the hook writes ended/<sid> only when it
# resolved one. So the same cwd must give "denied" and "marker written" together, or neither.
guard_denies() {  # guard_denies <cwd> [WORKSPACE_LOCK_DIR]
  _gj="$(jq -nc --arg c "$1" --arg s "$X" '{tool_name: "Bash", tool_input: {command: "npm test"}, session_id: $s, cwd: $c}')"
  if [ -n "${2:-}" ]; then _go="$(printf '%s' "$_gj" | wenv WORKSPACE_LOCK_DIR="$2" /bin/bash "$GUARD" 2>/dev/null)"
  else _go="$(printf '%s' "$_gj" | wenv /bin/bash "$GUARD" 2>/dev/null)"; fi
  printf '%s' "$_go" | grep -q '"permissionDecision": *"deny"'
}
hook_acts() {  # hook_acts <lock root> <cwd> [WORKSPACE_LOCK_DIR]: does a member's end write its marker there?
  rm -f "$1/.workspace-lock/lock.d/ended/$M1"
  if [ -n "${3:-}" ]; then jq -nc --arg s "$M1" --arg c "$2" '{session_id: $s, cwd: $c, reason: "other"}' | wenv WORKSPACE_LOCK_DIR="$3" /bin/bash "$HOOK" >/dev/null 2>&1
  else hook "$2" "$M1" other; fi
  [ -f "$1/.workspace-lock/lock.d/ended/$M1" ]
}
parity() {  # parity <label> <lock root> <cwd> <expect: lock|none> [WORKSPACE_LOCK_DIR]
  _gd=1; guard_denies "$3" "${5:-}" && _gd=0
  _ha=1; hook_acts "$2" "$3" "${5:-}" && _ha=0
  if [ "$4" = lock ]; then [ "$_gd" = 0 ] && [ "$_ha" = 0 ]; else [ "$_gd" = 1 ] && [ "$_ha" = 1 ]; fi
  check "parity, $1: guard and hook both resolve the lock ($4)" $?
}
R="$(team p)"
parity "the workspace root" "$R" "$R" lock
parity "a subfolder" "$R" "$R/sub" lock
parity "a nested subfolder" "$R" "$R/sub/deeper" lock
parity "WORKSPACE_LOCK_DIR set, cwd in the workspace" "$R" "$R/sub" lock "$R/.workspace-lock"
mkdir -p "$TMP/elsewhere"
_gd=1; guard_denies "$TMP/elsewhere" "$R/.workspace-lock" && _gd=0
[ "$_gd" = 1 ] && hook_acts "$R" "$TMP/elsewhere" "$R/.workspace-lock"; check "WORKSPACE_LOCK_DIR set, cwd outside: the guard ignores it, the hook still finds the lock (the one difference)" $?
mkdir -p "$R/.archive/old/.workspace-lock/lock.d" "$R/.archive/old/work"
parity "a lock left inside .archive/ is skipped by both" "$R" "$R/.archive/old/work" lock
mkdir -p "$R/.archive/proj/.git" "$R/.archive/proj/.workspace-lock/lock.d/members" "$R/.archive/proj/.workspace-lock/lock.d/ended"
printf 'owned\n' > "$R/.archive/proj/.workspace-lock/lock.d/kind"; printf '%s\n' "$O" > "$R/.archive/proj/.workspace-lock/lock.d/owner"
printf 't\n' > "$R/.archive/proj/.workspace-lock/lock.d/holder"; printf '1\n' > "$R/.archive/proj/.workspace-lock/lock.d/members/$M1"
mkdir -p "$R/.archive/proj/src"
_gd=1; guard_denies "$R/.archive/proj/src" && _gd=0
rm -f "$R/.archive/proj/.workspace-lock/lock.d/ended/$M1"; hook "$R/.archive/proj/src" "$M1" other
_ha=1; [ -f "$R/.archive/proj/.workspace-lock/lock.d/ended/$M1" ] && _ha=0
[ "$_gd" = 0 ] && [ "$_ha" = 0 ]; check "parity, a real project (.git) archived under .archive/: both resolve its lock" $?
mkdir -p "$TMP/none/sub"
parity "no lock anywhere" "$R" "$TMP/none/sub" none

echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" = 0 ]
