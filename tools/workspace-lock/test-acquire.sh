#!/usr/bin/env bash
# test-acquire.sh — functional tests for workspace-lock.sh's acquire wait loop: release handoff at
# the real cadence, two-waiter exclusivity, MAX_WAIT timeout, a waiter never displacing a fresh holder,
# throttled wait lines, reentrant acquire. Runs the real script against throwaway lock dirs.
#
# Usage: bash tools/workspace-lock/test-acquire.sh      (~1.5 min; the handoff test waits on a
#   real 30-35s recheck). WL_SCRIPT=<path> tests another copy of the script.
# Exit 0 = all pass, 1 = any fail.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WL="${WL_SCRIPT:-$HERE/workspace-lock.sh}"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
check() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi; }

# newdir <name> -> absolute lock dir under its own workspace
newdir() { mkdir -p "$TMP/$1"; echo "$TMP/$1/.workspace-lock"; }

# wenv <VAR=val...> <cmd...> — run with every WORKSPACE_LOCK_* knob cleared first, so an exported
# value can neither skew a test nor append to a real durable log.
wenv() {
  env -u WORKSPACE_LOCK_ID -u WORKSPACE_LOCK_DIR -u WORKSPACE_LOCK_LOG -u WORKSPACE_LOCK_MAX_WAIT \
    -u WORKSPACE_LOCK_INIT_LEASE -u WORKSPACE_LOCK_WEDGE_GRACE -u WORKSPACE_LOCK_TEST_POLL "$@"
}

# wl <lockdir> <args...> — run the script against one lock dir with a clean env.
wl() { _d="$1"; shift; wenv WORKSPACE_LOCK_DIR="$_d" "$WL" "$@"; }

# wait_for <file> <fixed string> <seconds> — 0 once the file holds the string.
wait_for() {
  _n=0
  while [ "$_n" -lt $(( $3 * 10 )) ]; do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1; _n=$((_n + 1))
  done
  return 1
}

holder() { cat "$1/lock.d/holder" 2>/dev/null; }
count()  { grep -cF -- "$2" "$1" 2>/dev/null || true; }

# --- (a) handoff at the real cadence: a waiter acquires within one recheck of release ----------
D="$(newdir a)"
wl "$D" acquire --id h --eta +4h >/dev/null 2>&1
wenv WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_MAX_WAIT=120 "$WL" acquire --id w >"$TMP/a.out" 2>"$TMP/a.err" &
wait_for "$TMP/a.err" "BUSY held by h" 5; check "a: waiter reports BUSY on the first check" $?
_p="$(sed -n 's/.*next check in \([0-9]*\)s.*/\1/p' "$TMP/a.err" | head -n1)"
[ -n "$_p" ] && [ "$_p" -ge 30 ] && [ "$_p" -le 35 ]; check "a: recheck is 30-35s with a +4h holder ETA (got ${_p:-none})" $?
sleep 2
_t0="$(date +%s)"
wl "$D" release --id h >/dev/null
wait_for "$TMP/a.out" "ACQUIRED w" 40; _rc=$?
_dt=$(( $(date +%s) - _t0 ))
check "a: waiter acquires within 40s of release (took ${_dt}s)" "$_rc"
[ "$(holder "$D")" = "w" ]; check "a: lock.d/holder is the waiter" $?
wait

# --- (b) two waiters, one release: exactly one wins, the other keeps waiting -------------------
D="$(newdir b)"
wl "$D" acquire --id h >/dev/null 2>&1
for _w in w1 w2; do
  wenv WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_MAX_WAIT=60 WORKSPACE_LOCK_TEST_POLL=1 "$WL" acquire --id "$_w" >"$TMP/b.$_w.out" 2>"$TMP/b.$_w.err" &
done
wait_for "$TMP/b.w1.err" "BUSY" 5 && wait_for "$TMP/b.w2.err" "BUSY" 5; check "b: both waiters BUSY" $?
wl "$D" release --id h >/dev/null
sleep 4
_won=""; _n=0
for _w in w1 w2; do grep -qF "ACQUIRED $_w" "$TMP/b.$_w.out" && { _won="$_w"; _n=$((_n + 1)); }; done
[ "$_n" = "1" ]; check "b: exactly one waiter acquired (count $_n)" $?
[ -n "$_won" ] && [ "$(holder "$D")" = "$_won" ]; check "b: lock.d/holder is the winner ($_won)" $?
_lose=w1; [ "$_won" = "w1" ] && _lose=w2
grep -qF "ACQUIRED" "$TMP/b.$_lose.out"; [ $? -ne 0 ]; check "b: the other waiter has not acquired" $?
wl "$D" release --id "$_won" >/dev/null
wait_for "$TMP/b.$_lose.out" "ACQUIRED $_lose" 5; check "b: the other waiter acquires after the second release" $?
wait

# --- (c) past MAX_WAIT: TIMEOUT, exit 2, and the 30s poll is clamped to the remaining wait ------
D="$(newdir c)"
wl "$D" acquire --id h >/dev/null 2>&1
_t0="$(date +%s)"
wenv WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_MAX_WAIT=3 "$WL" acquire --id w >"$TMP/c.out" 2>"$TMP/c.err"; _rc=$?
_dt=$(( $(date +%s) - _t0 ))
[ "$_rc" = "2" ]; check "c: exit 2 past MAX_WAIT (got $_rc)" $?
grep -qF "TIMEOUT waited" "$TMP/c.err"; check "c: prints TIMEOUT" $?
[ "$_dt" -le 8 ]; check "c: gives up near MAX_WAIT, not after a full recheck (${_dt}s)" $?
[ "$(holder "$D")" = "h" ]; check "c: holder unchanged" $?

# --- (d) no displacement: a fresh acquirer that wins the gap keeps the lock -------------------------
D="$(newdir d)"
wl "$D" acquire --id h >/dev/null 2>&1
wenv WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_MAX_WAIT=10 WORKSPACE_LOCK_TEST_POLL=3 "$WL" acquire --id w >"$TMP/d.out" 2>"$TMP/d.err" &
_wpid=$!
wait_for "$TMP/d.err" "BUSY held by h" 5
wl "$D" release --id h >/dev/null
wenv WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_MAX_WAIT=0 "$WL" acquire --id c >/dev/null 2>&1
check "d: fresh acquirer takes the freed lock at once" $?
wait "$_wpid"; _rc=$?
[ "$_rc" = "2" ]; check "d: the earlier waiter times out instead of taking the lock (rc $_rc)" $?
grep -qF "ACQUIRED" "$TMP/d.out"; [ $? -ne 0 ]; check "d: the earlier waiter never printed ACQUIRED" $?
grep -qF "BUSY held by c" "$TMP/d.err"; check "d: the waiter saw the new holder" $?
[ "$(holder "$D")" = "c" ]; check "d: lock.d/holder is still the fresh acquirer" $?
wl "$D" release --id w >/dev/null 2>&1; [ $? -ne 0 ]; check "d: the waiter cannot release it" $?

# --- (e) throttled wait lines: once per state, and a state change still prints ------------------
D="$(newdir e)"
wl "$D" acquire --id h --eta 0 >/dev/null 2>&1
wenv WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_MAX_WAIT=10 WORKSPACE_LOCK_TEST_POLL=1 WORKSPACE_LOCK_WEDGE_GRACE=3 \
  "$WL" acquire --id w >"$TMP/e.out" 2>"$TMP/e.err"
_b="$(count "$TMP/e.err" "BUSY held by h")"; _x="$(count "$TMP/e.err" "WARN lock wedged since")"
[ "$_b" -ge 1 ] && [ "$_b" -le 2 ]; check "e: BUSY printed once over ~4 checks (got $_b, allow 2)" $?
[ "$_x" -ge 1 ] && [ "$_x" -le 2 ]; check "e: WARN printed on the wedge transition, once (got $_x, allow 2)" $?
[ "$(count "$TMP/e.err" "TIMEOUT waited")" = "1" ]; check "e: TIMEOUT still printed" $?

# --- (f) reentrant acquire still returns at once ------------------------------------------------
D="$(newdir f)"
wl "$D" acquire --id h >/dev/null 2>&1
_o="$(wl "$D" acquire --id h 2>&1)"; _rc=$?
[ "$_rc" = "0" ] && printf '%s' "$_o" | grep -qF "ACQUIRED (already held) h"; check "f: reentrant acquire -> already held" $?

# --- ETA expiry and `clear` (ADR 0012) ----------------------------------------------------------
# Time is faked by backdating the token's own files: backdate <lockdir> <eta-age-s> <hb-age-s|none>.
backdate() {
  _now="$(date -u +%s)"
  printf '%s\n' $(( _now - $2 )) > "$1/lock.d/eta_epoch"
  if [ "$3" = none ]; then rm -f "$1/lock.d/heartbeat_epoch"
  else printf '%s\n' $(( _now - $3 )) > "$1/lock.d/heartbeat_epoch"; fi
}
snap() { (cd "$1" && find lock.d -type f | sort | xargs cat | cksum) 2>/dev/null; }
# refused <label> <lockdir> <clear args…> — NOT-CLEARABLE, exit 1, lock.d byte-identical
refused() {
  _l="$1"; _d="$2"; shift 2
  _s0="$(snap "$_d")"
  _o="$(wl "$_d" clear "$@" 2>&1)"; _rc=$?
  [ "$_rc" = "1" ] && printf '%s' "$_o" | grep -qF "NOT-CLEARABLE" && [ "$(snap "$_d")" = "$_s0" ]
  check "g: $_l -> NOT-CLEARABLE, lock untouched" $?
}

# --- (g) clear refusals (default 30-min grace) -------------------------------------------------
D="$(newdir g)"; wl "$D" acquire --id h >/dev/null 2>&1
backdate "$D" 1000 4000;  refused "ETA under the grace"          "$D" --id c --holder h
backdate "$D" 4000 100;   refused "heartbeat under the grace"    "$D" --id c --holder h
backdate "$D" 4000 4000;  refused "--holder mismatch"            "$D" --id c --holder other
refused "own lock"                                              "$D" --id h --holder h
refused "missing --holder"                                      "$D" --id c
D3="$(newdir g3)"; mkdir -p "$D3/lock.d"; : > "$D3/lock.d/holder"
refused "empty holder"                                          "$D3" --id c --holder x
_o="$(wl "$TMP/g/sub/.workspace-lock" clear --id c --holder h 2>&1)"; _rc=$?
[ "$_rc" = "1" ] && printf '%s' "$_o" | grep -qF "NOT-CLEARABLE no lock at"; check "g: no lock at the resolved dir -> NOT-CLEARABLE" $?

# --- (j) --check prints one line and changes nothing; (n) holder text is sanitized -------------
D="$(newdir j)"; wl "$D" acquire --id h --task "$(printf 'fix "x"\001 \342\200\256rtl %0100d' 0)" >/dev/null 2>&1; backdate "$D" 4000 4000
_l0="$(ls -laR "$D" | cksum)"; _s0="$(snap "$D")"
_o="$(wl "$D" clear --check --id c --holder h 2>&1)"; _rc=$?
[ "$_rc" = "0" ] && [ "$(printf '%s\n' "$_o" | wc -l | tr -d ' ')" = "1" ] && printf '%s' "$_o" | grep -q '^CLEARABLE '
check "j: --check -> one CLEARABLE line" $?
[ "$(ls -laR "$D" | cksum)" = "$_l0" ] && [ "$(snap "$D")" = "$_s0" ]; check "j: --check changed nothing on disk" $?
_t="$(printf '%s' "$_o" | sed -n 's/.*(untrusted): "\(.*\)"$/\1/p')"
[ "${#_t}" -le 80 ] && ! printf '%s' "$_t" | grep -q '["[:cntrl:]]'; check "n: task capped at 80, no quotes or control chars (len ${#_t})" $?
! printf '%s' "$_o" | LC_ALL=C grep -q '[^ -~]'; check "n: prompt is printable ASCII only (no bidi or zero-width chars)" $?

# --- (k) a lock without heartbeat_epoch (taken by the old script) counts as stale ---------------
backdate "$D" 4000 none
wl "$D" clear --check --id c --holder h 2>&1 | grep -qF "last heartbeat unknown"; check "k: missing heartbeat_epoch -> unknown, clearable" $?
printf 'torn\n' > "$D/lock.d/heartbeat_epoch"
_o="$(wl "$D" clear --check --id c --holder h 2>&1)"; _rc=$?
[ "$_rc" = "1" ] && printf '%s' "$_o" | grep -qF "heartbeat_epoch is unreadable"; check "k: unreadable heartbeat_epoch -> refused, never stale" $?

# --- (p) the grace default is 30 min -----------------------------------------------------------
backdate "$D" 1000 5000; wl "$D" clear --check --id c --holder h >/dev/null 2>&1; [ $? = 1 ]
check "p: 1000s past ETA is under the default grace" $?
backdate "$D" 2000 5000; wl "$D" clear --check --id c --holder h >/dev/null 2>&1; check "p: 2000s past ETA is over it" $?

# --- (l) a marker that cannot be written aborts the clear and keeps the lock --------------------
D="$(newdir l)"; wl "$D" acquire --id h >/dev/null 2>&1; backdate "$D" 4000 4000
mkdir -p "$D/cleared"; chmod 500 "$D/cleared"
wl "$D" clear --id c --holder h >/dev/null 2>&1; _rc=$?
chmod 700 "$D/cleared"
[ "$_rc" != "0" ] && [ "$(holder "$D")" = "h" ]; check "l: unwritable marker -> no clear, lock kept" $?

# --- (h) clear: lock gone, marker + log + free mirror, and a blocked waiter then wins ------------
D="$(newdir h)"; wl "$D" acquire --id h >/dev/null 2>&1; backdate "$D" 4000 4000
wenv WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_MAX_WAIT=30 WORKSPACE_LOCK_TEST_POLL=1 "$WL" acquire --id w >"$TMP/h.out" 2>"$TMP/h.err" &
wait_for "$TMP/h.err" "held by h" 5
_o="$(wl "$D" clear --id c --holder h 2>&1)"; _rc=$?
[ "$_rc" = "0" ] && printf '%s' "$_o" | grep -qF "CLEARED h"; check "h: clear prints CLEARED" $?
[ -f "$D/cleared/h" ] && grep -qF " c" "$D/cleared/h"; check "h: marker names the clearer" $?
grep -qF "CLEARED h (eta" "$D/workspace-lock.log"; check "h: CLEARED logged" $?
wait_for "$TMP/h.out" "ACQUIRED w" 5; check "h: the blocked waiter acquires" $?
grep -qF "clearable from a session with a human" "$TMP/h.err"; check "m: WEDGED line carries the clear hint when the heartbeat is stale" $?
wait
wl "$D" release --id w >/dev/null 2>&1

# --- (i) after a clear: the old holder fails loudly, --after-clear is the way back --------------
_o="$(wl "$D" heartbeat --id h --eta +60 2>&1)"; [ $? = 1 ] && printf '%s' "$_o" | grep -qF "was cleared by 'c'"
check "i: old holder's heartbeat --eta fails loudly" $?
_o="$(wl "$D" release --id h 2>&1)"; [ $? = 1 ] && printf '%s' "$_o" | grep -qF "was cleared by"
check "i: old holder's release fails loudly (lock free)" $?
_o="$(wl "$D" acquire --id h 2>&1)"; [ $? = 1 ] && printf '%s' "$_o" | grep -qF "after-clear"
check "i: old holder's acquire fails loudly" $?
wl "$D" acquire --id h --after-clear >/dev/null 2>&1 && [ "$(holder "$D")" = "h" ] && [ -f "$D/cleared/h" ]
check "i: --after-clear acquires and keeps the marker" $?
wl "$D" acquire --id h >/dev/null 2>&1; check "i: reentrant acquire ignores the marker" $?
wl "$D" release --id h >/dev/null 2>&1 && [ ! -f "$D/cleared/h" ]; check "i: a successful release removes the marker" $?

# --- (m) no clear hint while the holder still heartbeats ---------------------------------------
D="$(newdir m)"; wl "$D" acquire --id h --eta 0 >/dev/null 2>&1
wenv WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_MAX_WAIT=5 WORKSPACE_LOCK_TEST_POLL=1 WORKSPACE_LOCK_WEDGE_GRACE=2 \
  "$WL" acquire --id w >"$TMP/m.out" 2>"$TMP/m.err" &
_mp=$!
for _i in 1 2 3 4 5; do date -u +%s > "$D/lock.d/heartbeat_epoch"; sleep 1; done
wait "$_mp"
grep -qF "WARN lock wedged" "$TMP/m.err" && ! grep -qF "clearable from" "$TMP/m.err"; check "m: wedged but beating -> no clear hint" $?

# --- (o) the retake: a bare heartbeat past the ETA is refused, --eta retakes ---------------------
D="$(newdir o)"; wl "$D" acquire --id h >/dev/null 2>&1; backdate "$D" 10 10
_hb0="$(cat "$D/lock.d/heartbeat_epoch")"
_o="$(wl "$D" heartbeat --id h 2>&1)"; [ $? = 1 ] && printf '%s' "$_o" | grep -qF -- "--eta" && [ "$(cat "$D/lock.d/heartbeat_epoch")" = "$_hb0" ]
check "o: bare heartbeat past ETA refused, heartbeat_epoch unchanged" $?
wl "$D" heartbeat --id h --eta +60 >/dev/null 2>&1 && [ "$(cat "$D/lock.d/eta_epoch")" -gt "$(date -u +%s)" ] \
  && [ "$(cat "$D/lock.d/heartbeat_epoch")" -gt "$_hb0" ]
check "o: heartbeat --eta retakes (both epochs move)" $?
backdate "$D" 4000 4000
wl "$D" heartbeat --id h --eta +60 >/dev/null 2>&1; check "o: retake still works past the grace (no clear yet)" $?
wl "$D" heartbeat --id h >/dev/null 2>&1; check "o: bare heartbeat inside the ETA still works" $?

# --- (q) heartbeat --phase rebuilds the mirror: a stored phase with quotes cannot corrupt it ------
D="$(newdir q)"; wl "$D" acquire --id h --phase 'fix "login"' --eta +1h >/dev/null 2>&1
wl "$D" heartbeat --id h --phase build >/dev/null 2>&1; check "q: heartbeat --phase exits 0" $?
grep -qF '"phase": "build",' "$D/status.json" && ! grep -qF 'login' "$D/status.json" \
  && grep -qF '"state": "locked",' "$D/status.json"
check "q: status.json holds the new phase and nothing of the old one" $?
wl "$D" heartbeat --id h --phase 'ship "v2" \ now' >/dev/null 2>&1
grep -qF '"phase": "ship \"v2\" \\ now",' "$D/status.json"; check "q: quotes and a backslash in a phase are escaped" $?
if command -v jq >/dev/null 2>&1; then
  [ "$(jq -r .phase "$D/status.json" 2>/dev/null)" = 'ship "v2" \ now' ]; check "q: status.json parses and the phase round-trips" $?
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
