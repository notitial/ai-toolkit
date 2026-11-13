#!/usr/bin/env bash
# test-turn.sh — functional tests for workspace-lock.sh's owned team: acquire --owned, members,
# turns (take, give --tree, beat, give --force), owner transfer, owner-only release and heartbeat,
# and the owned status fields. Runs the real script against throwaway lock dirs; time is faked by
# writing epoch files, and waits use a 1-second poll, so it is fast enough for --quick.
#
# Usage: bash tools/workspace-lock/test-turn.sh      (about 30 s). WL_SCRIPT=<path> tests another copy.
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

newdir() { mkdir -p "$TMP/$1"; echo "$TMP/$1/.workspace-lock"; }
wenv() {
  env -u WORKSPACE_LOCK_ID -u WORKSPACE_LOCK_DIR -u WORKSPACE_LOCK_LOG -u WORKSPACE_LOCK_MAX_WAIT \
    -u WORKSPACE_LOCK_INIT_LEASE -u WORKSPACE_LOCK_WEDGE_GRACE -u WORKSPACE_LOCK_TEST_POLL \
    -u WORKSPACE_LOCK_TEST_WIN_PAUSE "$@"
}
wl() { _d="$1"; shift; wenv WORKSPACE_LOCK_DIR="$_d" "$WL" "$@"; }
# wlw <lockdir> <args...> — a waiter: 1 s poll, 20 s cap.
wlw() { _d="$1"; shift; wenv WORKSPACE_LOCK_DIR="$_d" WORKSPACE_LOCK_TEST_POLL=1 WORKSPACE_LOCK_MAX_WAIT=20 "$WL" "$@"; }
wait_for() {
  _n=0
  while [ "$_n" -lt $(( $3 * 10 )) ]; do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1; _n=$((_n + 1))
  done
  return 1
}
# fails <label> <expected text> <cmd...> — exit 1 and the text in the output
fails() {
  _l="$1"; _x="$2"; shift 2
  _o="$("$@" 2>&1)"; _rc=$?
  [ "$_rc" = "1" ] && printf '%s' "$_o" | grep -qF -- "$_x"; check "$_l" $?
}

O=aaaaaaaa-0000-4000-8000-000000000001     # owner
M1=bbbbbbbb-0000-4000-8000-000000000002    # members
M2=cccccccc-0000-4000-8000-000000000003
X=dddddddd-0000-4000-8000-000000000004     # stranger
N=eeeeeeee-0000-4000-8000-000000000005     # a new owner

now() { date -u +%s; }
# turn_age <lockdir> <eta-age-s|none> <hb-age-s|none>: backdate the turn's own epochs
turn_age() {
  if [ "$2" = none ]; then rm -f "$1/lock.d/turn.d/eta_epoch"; else printf '%s\n' $(( $(now) - $2 )) > "$1/lock.d/turn.d/eta_epoch"; fi
  if [ "$3" = none ]; then rm -f "$1/lock.d/turn.d/heartbeat_epoch"; else printf '%s\n' $(( $(now) - $3 )) > "$1/lock.d/turn.d/heartbeat_epoch"; fi
}
# team <name>: an owned lock "t" with owner O and members M1, M2; prints the lock dir
team() {
  _td="$(newdir "$1")"
  wl "$_td" acquire --id t --owned --sid "$O" --eta +1h >/dev/null 2>&1
  wl "$_td" member add --id t --sid "$M1" --by "$O" >/dev/null 2>&1
  wl "$_td" member add --id t --sid "$M2" --by "$O" >/dev/null 2>&1
  echo "$_td"
}

# --- acquire --owned ----------------------------------------------------------------------------
D="$(newdir a)"
_o="$(wl "$D" acquire --id t --owned --sid "$O" --eta +1h 2>&1)"
printf '%s' "$_o" | grep -qF "ACQUIRED (owned) t"; check "acquire --owned prints ACQUIRED (owned)" $?
[ "$(cat "$D/lock.d/kind")" = owned ] && [ "$(cat "$D/lock.d/owner")" = "$O" ] && [ "$(cat "$D/lock.d/holder")" = t ] \
  && [ -d "$D/lock.d/members" ] && [ -d "$D/lock.d/ended" ]; check "acquire --owned writes kind, owner, holder, members/, ended/" $?
_o="$(wl "$D" acquire --id t --owned --sid "$O" 2>&1)"; printf '%s' "$_o" | grep -qF "ACQUIRED (already held) t"
check "the owner's re-acquire is re-entrant" $?
_t0="$(now)"; fails "a plain acquire of the owned slug exits 1" "is an owned lock" wenv WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_MAX_WAIT=60 "$WL" acquire --id t
[ $(( $(now) - _t0 )) -le 3 ]; check "  ... at once, without waiting" $?
fails "acquire --owned by another sid exits 1" "is an owned lock" wl "$D" acquire --id t --owned --sid "$X"
[ "$(cat "$D/lock.d/owner")" = "$O" ]; check "  ... and the owner is unchanged" $?
wenv WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_MAX_WAIT=1 WORKSPACE_LOCK_TEST_POLL=1 "$WL" acquire --id other --owned --sid "$X" >/dev/null 2>"$TMP/a.err"; _rc=$?
[ "$_rc" = "2" ] && grep -qF "BUSY held by t" "$TMP/a.err"; check "an owned acquire of another slug waits as today (BUSY, then exit 2)" $?
D2="$(newdir a2)"
fails "--owned without --sid is refused" "must be a session id" wl "$D2" acquire --id t --owned
fails "an uppercase sid is refused" "must be a session id" wl "$D2" acquire --id t --owned --sid "AAAAAAAA-0000-4000-8000-000000000001"
fails "a short sid is refused" "must be a session id" wl "$D2" acquire --id t --owned --sid "aaaaaaaa"
fails "an unexpanded \$VAR sid is refused" "must be a session id" wl "$D2" acquire --id t --owned --sid '$CLAUDE_CODE_SESSION_ID'
fails "a sid with a slash is refused" "must be a session id" wl "$D2" acquire --id t --owned --sid "aaaaaaaa-0000-4000-8000-0000000/../1"
fails "--sid without --owned is refused" "--sid goes with --owned" wl "$D2" acquire --id t --sid "$O"
fails "--repos with --owned is refused" "--repos does not go with --owned" wl "$D2" acquire --id t --owned --sid "$O" --repos /x,/y
[ ! -e "$D2" ]; check "refused owned acquires created nothing" $?
D3="$(newdir a3)"; wl "$D3" acquire --id t >/dev/null 2>&1
fails "--owned on an open lock with the same slug is refused" "never converted" wl "$D3" acquire --id t --owned --sid "$O"
[ ! -f "$D3/lock.d/kind" ]; check "  ... and the open lock stays open" $?

# --- owner-only heartbeat and release -------------------------------------------------------------
D="$(team b)"
fails "owned heartbeat without --sid is refused" "only its owner" wl "$D" heartbeat --id t --eta +1h
fails "owned heartbeat by a member is refused" "only the owner" wl "$D" heartbeat --id t --sid "$M1" --eta +1h
wl "$D" heartbeat --id t --sid "$O" --eta +1h >/dev/null 2>&1; check "owned heartbeat by the owner works" $?
fails "owned release without --sid is refused" "only its owner" wl "$D" release --id t
fails "owned release by a member is refused" "only the owner" wl "$D" release --id t --sid "$M1"
wl "$D" turn take --id t --sid "$M1" --eta +10m >/dev/null 2>&1
fails "owned release while a turn is held is refused" "a turn is held" wl "$D" release --id t --sid "$O"
[ -d "$D/lock.d/turn.d" ]; check "  ... and the turn is kept" $?
_o="$(wl "$D" release --id t --sid "$O" --force 2>&1)"; [ $? = 0 ] && printf '%s' "$_o" | grep -qF "RELEASED t" && [ ! -d "$D/lock.d" ]
check "release --force releases with a turn held (lock.d gone)" $?
ls "$D" | grep -q 'gone'; [ $? -ne 0 ]; check "  ... and leaves no renamed debris" $?
D="$(newdir b2)"; wl "$D" acquire --id open >/dev/null 2>&1
fails "release --force on an open lock is refused" "--force goes with an owned lock" wl "$D" release --id open --force
wl "$D" heartbeat --id open --sid "$O" >/dev/null 2>&1 && wl "$D" release --id open --sid "$O" >/dev/null 2>&1
check "an open lock accepts and ignores --sid on heartbeat and release" $?

# --- members --------------------------------------------------------------------------------------
D="$(newdir c)"; wl "$D" acquire --id t --owned --sid "$O" >/dev/null 2>&1
fails "member add by a non-owner is refused" "only the owner" wl "$D" member add --id t --sid "$M1" --by "$X"
fails "member add of the owner is refused" "the owner is not added" wl "$D" member add --id t --sid "$O" --by "$O"
_o="$(wl "$D" member add --id t --sid "$M1" --by "$O" 2>&1)"; printf '%s' "$_o" | grep -qF "MEMBER-ADDED $M1" && [ -f "$D/lock.d/members/$M1" ]
check "member add writes members/<sid>" $?
_o="$(wl "$D" member add --id t --sid "$M1" --by "$O" 2>&1)"; [ $? = 0 ] && printf '%s' "$_o" | grep -qF "MEMBER (already)"
check "re-adding a member is idempotent" $?
for _i in 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16; do
  wl "$D" member add --id t --sid "ffffffff-0000-4000-8000-0000000000$_i" --by "$O" >/dev/null 2>&1
done
[ "$(ls "$D/lock.d/members" | wc -l | tr -d ' ')" = 16 ]; check "16 members fit" $?
fails "a 17th member is refused" "already has 16 members" wl "$D" member add --id t --sid "ffffffff-0000-4000-8000-000000000017" --by "$O"
printf '1700000000 other\n' > "$D/lock.d/ended/$M1"
_o="$(wl "$D" member list --id t 2>&1)"
printf '%s\n' "$_o" | head -n1 | grep -qx "owner $O" \
  && printf '%s\n' "$_o" | grep -q "^member $M1 added=[0-9T:Z-]* ended=2023-11-14T22:13:20Z$"
check "member list: owner line, member lines with added= and ended=" $?
fails "member remove of the owner is refused" "the owner is not a member" wl "$D" member remove --id t --sid "$O" --by "$O"
_o="$(wl "$D" member remove --id t --sid "$X" --by "$O" 2>&1)"; [ $? = 0 ] && printf '%s' "$_o" | grep -qF "NOT-A-MEMBER"
check "removing a non-member is a no-op" $?
wl "$D" member remove --id t --sid "$M1" --by "$O" >/dev/null 2>&1; [ ! -f "$D/lock.d/members/$M1" ] && [ ! -f "$D/lock.d/ended/$M1" ]
check "member remove deletes members/<sid> and its ended marker" $?
D3="$(newdir c3)"; wl "$D3" acquire --id t >/dev/null 2>&1
fails "member add on an open lock is refused" "not an owned lock" wl "$D3" member add --id t --sid "$M1" --by "$O"
fails "turn take on an open lock is refused" "not an owned lock" wl "$D3" turn take --id t --sid "$M1" --eta +1m
fails "member add naming another slug is refused" "held by 't', not 'u'" wl "$D" member add --id u --sid "$M1" --by "$O"
D4="$TMP/c4/.workspace-lock"; mkdir -p "$TMP/c4"
fails "member add on a free workspace is refused" "no lock held" wl "$D4" member add --id t --sid "$M1" --by "$O"
fails "turn take on a free workspace is refused" "no lock held" wl "$D4" turn take --id t --sid "$M1" --eta +1m
fails "owner transfer on a free workspace is refused" "no lock held" wl "$D4" owner transfer --id t --to "$N"
[ ! -e "$D4" ]; check "  ... and nothing was created (no lock folder, no log)" $?

# --- turns: take, give, hand-over --------------------------------------------------------------
D="$(team d)"
_t0="$(now)"; fails "a non-member's turn take exits 1" "not a member" wlw "$D" turn take --id t --sid "$X" --eta +5m
[ $(( $(now) - _t0 )) -le 3 ]; check "  ... at once" $?
fails "turn take without --eta is refused" "--eta is required" wl "$D" turn take --id t --sid "$M1"
_o="$(wl "$D" turn take --id t --sid "$M1" --eta +10m --task "fix x" 2>&1)"
printf '%s' "$_o" | grep -qF "TURN $M1" && ! printf '%s' "$_o" | grep -qF "LAST-GIVE" && [ "$(cat "$D/lock.d/turn.d/sid")" = "$M1" ]
check "a member takes a free turn (TURN, no LAST-GIVE yet)" $?
turn_age "$D" 0 0; _e0="$(cat "$D/lock.d/turn.d/eta_epoch")"
_o="$(wl "$D" turn take --id t --sid "$M1" --eta +10m 2>&1)"
printf '%s' "$_o" | grep -qF "TURN (already held)" && [ "$(cat "$D/lock.d/turn.d/eta_epoch")" -gt "$_e0" ] \
  && [ "$(cat "$D/lock.d/turn.d/task")" = "fix x" ]
check "re-entrant take refreshes the ETA and keeps the task" $?
wlw "$D" turn take --id t --sid "$O" --eta +5m >"$TMP/d.out" 2>"$TMP/d.err" &
wait_for "$TMP/d.err" "BUSY turn held by bbbbbbbb" 15; check "the owner waits for a member's turn (BUSY names the holder)" $?
fails "turn give without --tree is refused" "--tree clean|dirty is required" wl "$D" turn give --id t --sid "$M1"
fails "turn give --tree maybe is refused" "must be clean or dirty" wl "$D" turn give --id t --sid "$M1" --tree maybe
fails "turn give by a non-holder is refused" "held by 'bbbbbbbb'" wl "$D" turn give --id t --sid "$M2" --tree clean
fails "turn give --by without --force is refused" "go with --force" wl "$D" turn give --id t --sid "$M1" --tree clean --by "$O"
_o="$(wl "$D" turn give --id t --sid "$M1" --tree dirty 2>&1)"; printf '%s' "$_o" | grep -qF "TURN-GIVEN $M1 dirty"
check "turn give --tree dirty is recorded, never refused" $?
wait_for "$TMP/d.out" "TURN $O" 15; check "the waiting owner takes the turn after the give" $?
grep -q "^LAST-GIVE .* by bbbbbbbb tree dirty$" "$TMP/d.out" && grep -qF "WARN the last turn was given back with tree 'dirty'" "$TMP/d.out"
check "  ... and is shown the dirty hand-over with a WARN" $?
wait
wl "$D" turn give --id t --sid "$O" --tree clean >/dev/null 2>&1
_o="$(wl "$D" turn take --id t --sid "$M2" --eta +5m 2>&1)"
printf '%s' "$_o" | grep -qF "tree clean" && ! printf '%s' "$_o" | grep -qF "WARN"; check "a clean hand-over shows no WARN" $?
if [ "$(id -u)" != 0 ]; then   # root ignores the mode bits this case relies on
  chmod 500 "$D/lock.d"
  fails "a give whose record cannot be written is refused" "the turn is kept" wl "$D" turn give --id t --sid "$M2" --tree dirty
  chmod 700 "$D/lock.d"
  [ "$(cat "$D/lock.d/turn.d/sid")" = "$M2" ] && grep -q " clean$" "$D/lock.d/last_give"; check "  ... the turn and the old record stay" $?
fi
wl "$D" turn give --id t --sid "$M2" --tree clean >/dev/null 2>&1
fails "turn give with no turn held is refused" "no turn is held" wl "$D" turn give --id t --sid "$M2" --tree clean

# --- two waiters race: exactly one wins each give -----------------------------------------------
D="$(team e)"
wl "$D" turn take --id t --sid "$O" --eta +5m >/dev/null 2>&1
for _s in "$M1" "$M2"; do wlw "$D" turn take --id t --sid "$_s" --eta +5m >"$TMP/e.$_s.out" 2>&1 & done
wait_for "$TMP/e.$M1.out" "BUSY" 15 && wait_for "$TMP/e.$M2.out" "BUSY" 15; check "two waiters both wait (BUSY) before the give" $?
wl "$D" turn give --id t --sid "$O" --tree clean >/dev/null 2>&1
# poll (bounded, 15 s) until one waiter wins, then give the other a full poll to (wrongly) win too
_n=0; while [ "$_n" -lt 150 ] && ! grep -qF "TURN " "$TMP/e.$M1.out" "$TMP/e.$M2.out" 2>/dev/null; do sleep 0.1; _n=$((_n + 1)); done
sleep 1.5
_n=0; _won=""; for _s in "$M1" "$M2"; do grep -qF "TURN $_s" "$TMP/e.$_s.out" && { _n=$((_n + 1)); _won="$_s"; }; done
[ "$_n" = 1 ] && [ "$(cat "$D/lock.d/turn.d/sid")" = "$_won" ]; check "two waiters, one give: exactly one takes the turn ($_n)" $?
_lose="$M1"; [ "$_won" = "$M1" ] && _lose="$M2"
wl "$D" turn give --id t --sid "$_won" --tree clean >/dev/null 2>&1
wait_for "$TMP/e.$_lose.out" "TURN $_lose" 15; check "  ... the other takes it after the next give" $?
wait

# --- a waiter stops when it no longer belongs ---------------------------------------------------
D="$(team f)"; wl "$D" turn take --id t --sid "$M1" --eta +5m >/dev/null 2>&1
wlw "$D" turn take --id t --sid "$M2" --eta +5m >"$TMP/f1.out" 2>&1 & _p=$!
wait_for "$TMP/f1.out" "BUSY" 15; wl "$D" member remove --id t --sid "$M2" --by "$O" >/dev/null 2>&1
wait "$_p"; _rc=$?; [ "$_rc" = 1 ] && grep -qF "no longer a member" "$TMP/f1.out"; check "a waiter exits 1 when the owner removes it" $?
wl "$D" member add --id t --sid "$M2" --by "$O" >/dev/null 2>&1
wlw "$D" turn take --id t --sid "$M2" --eta +5m >"$TMP/f2.out" 2>&1 & _p=$!
wait_for "$TMP/f2.out" "BUSY" 15; printf '%s other\n' "$(now)" > "$D/lock.d/ended/$M2"
wait "$_p"; _rc=$?; [ "$_rc" = 1 ] && grep -qF "ended while waiting" "$TMP/f2.out"; check "a waiter exits 1 when its session's end marker appears" $?
wlw "$D" turn take --id t --sid "$M2" --eta +5m >"$TMP/f3.out" 2>&1 & _p=$!
wait_for "$TMP/f3.out" "BUSY" 15; [ ! -f "$D/lock.d/ended/$M2" ]; check "turn take clears its own end marker when it starts" $?
wl "$D" release --id t --sid "$O" --force >/dev/null 2>&1
wait "$_p"; _rc=$?; [ "$_rc" = 1 ] && grep -qF "released or changed" "$TMP/f3.out" && [ ! -d "$D/lock.d" ]
check "a waiter exits 1 when the lock is released, and recreates nothing" $?

# --- after the win: a removed member gives the turn back; a killed take leaves no turn -----------
D="$(team g)"; wl "$D" turn take --id t --sid "$O" --eta +5m >/dev/null 2>&1; wl "$D" turn give --id t --sid "$O" --tree clean >/dev/null 2>&1
# (env, not the wenv function, so $! is the script itself and the kill reaches it)
UNSET="-u WORKSPACE_LOCK_ID -u WORKSPACE_LOCK_LOG -u WORKSPACE_LOCK_MAX_WAIT -u WORKSPACE_LOCK_INIT_LEASE -u WORKSPACE_LOCK_WEDGE_GRACE -u WORKSPACE_LOCK_TEST_POLL"
# until_turn <lockdir> <sid>: wait (bounded, 15 s) until that sid's take has won and written turn.d
until_turn() { _n=0; while [ "$(cat "$1/lock.d/turn.d/sid" 2>/dev/null)" != "$2" ] && [ "$_n" -lt 150 ]; do sleep 0.1; _n=$((_n + 1)); done; }
_lg0="$(cat "$D/lock.d/last_give")"
env $UNSET WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_TEST_WIN_PAUSE=3 "$WL" turn take --id t --sid "$M1" --eta +5m >"$TMP/g.out" 2>&1 & _p=$!
until_turn "$D" "$M1"; printf '%s other\n' "$(now)" > "$D/lock.d/ended/$M1"
wait "$_p"; _rc=$?
[ "$_rc" = 1 ] && grep -qF "gave it back" "$TMP/g.out" && [ ! -d "$D/lock.d/turn.d" ] && [ "$(cat "$D/lock.d/last_give")" = "$_lg0" ]
check "a session that ended between its win and the re-check gives the turn back, last_give untouched" $?
env $UNSET WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_TEST_WIN_PAUSE=3 "$WL" turn take --id t --sid "$M2" --eta +5m >"$TMP/g2.out" 2>&1 & _p=$!
until_turn "$D" "$M2"; wl "$D" member remove --id t --sid "$M2" --by "$O" >/dev/null 2>&1
wait "$_p"; _rc=$?
[ "$_rc" = 1 ] && grep -qF "gave it back" "$TMP/g2.out" && [ ! -d "$D/lock.d/turn.d" ]
check "a member removed between its win and the re-check ends with no turn held" $?
wl "$D" member add --id t --sid "$M2" --by "$O" >/dev/null 2>&1
env $UNSET WORKSPACE_LOCK_DIR="$D" WORKSPACE_LOCK_TEST_WIN_PAUSE=3 "$WL" turn take --id t --sid "$M2" --eta +5m >/dev/null 2>&1 & _p=$!
until_turn "$D" "$M2"; [ -d "$D/lock.d/turn.d" ]; _held=$?; kill -TERM "$_p"; wait "$_p"
[ "$_held" = 0 ] && [ ! -d "$D/lock.d/turn.d" ]; check "a take killed before it finished leaves no turn behind" $?

# --- member remove frees the holder's turn -------------------------------------------------------
D="$(team h)"; wl "$D" turn take --id t --sid "$M1" --eta +5m >/dev/null 2>&1
_o="$(wl "$D" member remove --id t --sid "$M1" --by "$O" 2>&1)"
printf '%s' "$_o" | grep -qF "TURN-FREED-ON-REMOVE $M1" && [ ! -d "$D/lock.d/turn.d" ] && grep -q " $M1 unknown$" "$D/lock.d/last_give"
check "member remove frees its turn and records an unknown give" $?

# --- turn beat ----------------------------------------------------------------------------------
D="$(team i)"; wl "$D" turn take --id t --sid "$M1" --eta +5m >/dev/null 2>&1
fails "turn beat by a non-holder is refused" "held by 'bbbbbbbb'" wl "$D" turn beat --id t --sid "$M2"
turn_age "$D" 10 100; _hb0="$(cat "$D/lock.d/turn.d/heartbeat_epoch")"
fails "a bare turn beat past the turn's ETA is refused" "turn ETA expired" wl "$D" turn beat --id t --sid "$M1"
[ "$(cat "$D/lock.d/turn.d/heartbeat_epoch")" = "$_hb0" ]; check "  ... and changes nothing" $?
printf '%s other\n' "$(now)" > "$D/lock.d/ended/$M1"
wl "$D" turn beat --id t --sid "$M1" --eta +10m >/dev/null 2>&1 && [ "$(cat "$D/lock.d/turn.d/eta_epoch")" -gt "$(now)" ] \
  && [ "$(cat "$D/lock.d/turn.d/heartbeat_epoch")" -gt "$_hb0" ] && [ ! -f "$D/lock.d/ended/$M1" ]
check "turn beat --eta retakes (both epochs move) and clears the end marker" $?

# --- turn give --force ----------------------------------------------------------------------------
D="$(team j)"
fails "force --check with no turn held: NOT-FORCEABLE" "NOT-FORCEABLE no turn is held" wl "$D" turn give --id t --sid "$M1" --by "$O" --force --check
_o="$(wl "$D" turn give --id t --sid "$M1" --by "$O" --force 2>&1)"; [ $? = 0 ] && printf '%s' "$_o" | grep -qF "FREE (no turn held)"
check "force with no turn held: FREE" $?
wl "$D" turn take --id t --sid "$M1" --eta +5m --task "$(printf 'fix "y"\001 \342\200\256rtl %0100d' 0)" >/dev/null 2>&1
fails "force by a non-owner is refused" "only the owner" wl "$D" turn give --id t --sid "$M1" --by "$M2" --force
fails "force without --by is refused" "--by must be a session id" wl "$D" turn give --id t --sid "$M1" --force
fails "force with --tree is refused" "--tree does not go with --force" wl "$D" turn give --id t --sid "$M1" --by "$O" --force --tree clean
fails "force on a healthy turn: NOT-FORCEABLE" "NOT-FORCEABLE" wl "$D" turn give --id t --sid "$M1" --by "$O" --force
fails "force naming the wrong sid: NOT-FORCEABLE" "not 'cccccccc'" wl "$D" turn give --id t --sid "$M2" --by "$O" --force --check
turn_age "$D" 4000 100
fails "past the ETA but beating within the grace: NOT-FORCEABLE" "holder is alive" wl "$D" turn give --id t --sid "$M1" --by "$O" --force --check
turn_age "$D" 4000 4000
_s0="$(ls -laR "$D" | cksum)"
_o="$(wl "$D" turn give --id t --sid "$M1" --by "$O" --force --check 2>&1)"; _rc=$?
[ "$_rc" = 0 ] && [ "$(printf '%s\n' "$_o" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$_o" | grep -q '^FORCEABLE Free the turn'
check "stale turn: --check prints one FORCEABLE line (the prompt class)" $?
[ "$(ls -laR "$D" | cksum)" = "$_s0" ]; check "  ... and changes nothing on disk" $?
! printf '%s' "$_o" | LC_ALL=C grep -q '[^ -~]' && _tt="$(printf '%s' "$_o" | sed -n 's/.*(untrusted): "\(.*\)"$/\1/p')" \
  && [ "${#_tt}" -le 80 ] && ! printf '%s' "$_tt" | grep -q '"'
check "  ... printable ASCII only, holder task capped and unquoted" $?
turn_age "$D" none none
wl "$D" turn give --id t --sid "$M1" --by "$O" --force --check 2>&1 | grep -q '^FORCEABLE '; check "missing turn ETA and heartbeat: the prompt class" $?
turn_age "$D" 0 0; printf '%s other\n' "$(now)" > "$D/lock.d/ended/$M1"
_o="$(wl "$D" turn give --id t --sid "$M1" --by "$O" --force --check 2>&1)"
[ "$(printf '%s\n' "$_o" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$_o" | grep -q '^FORCEABLE-NOW '; check "ended session: one FORCEABLE-NOW line, even inside its ETA" $?
_o="$(wl "$D" turn give --id t --sid "$M1" --by "$O" --force 2>&1)"
[ $? = 0 ] && printf '%s' "$_o" | grep -qF "TURN-FORCED $M1" && [ ! -d "$D/lock.d/turn.d" ] && grep -q " $M1 unknown$" "$D/lock.d/last_give" \
  && grep -qF "TURN-FORCED bbbbbbbb" "$D/workspace-lock.log"
check "force frees the turn, records the member's unknown give, logs TURN-FORCED" $?
mkdir "$D/lock.d/turn.d"
wl "$D" turn give --id t --sid "$M2" --by "$O" --force --check 2>&1 | grep -q '^FORCEABLE .*no holder recorded'; check "a turn with no sid: the prompt class" $?
wl "$D" turn give --id t --sid "$M2" --by "$O" --force >/dev/null 2>&1 && [ ! -d "$D/lock.d/turn.d" ]; check "  ... and the force frees it" $?

# --- owner transfer ---------------------------------------------------------------------------------
D="$(team k)"
fails "transfer --check to the owner: NOT-TRANSFERABLE" "NOT-TRANSFERABLE" wl "$D" owner transfer --id t --to "$O" --check
fails "transfer --check to a member: NOT-TRANSFERABLE" "is a member" wl "$D" owner transfer --id t --to "$M1" --check
_s0="$(ls -laR "$D" | cksum)"
_o="$(wl "$D" owner transfer --id t --to "$N" --check 2>&1)"; _rc=$?
[ "$_rc" = 0 ] && [ "$(printf '%s\n' "$_o" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$_o" | grep -q "^TRANSFERABLE .*session eeeeeeee .*Current owner aaaaaaaa"
check "transfer --check to a new sid: one TRANSFERABLE line" $?
[ "$(ls -laR "$D" | cksum)" = "$_s0" ]; check "  ... and changes nothing on disk" $?
printf '%s\n' $(( $(now) - 5000 )) > "$D/lock.d/heartbeat_epoch"; printf '%s clear\n' "$(now)" > "$D/lock.d/ended/$O"
_o="$(wl "$D" owner transfer --id t --to "$N" 2>&1)"
printf '%s' "$_o" | grep -qF "OWNER-TRANSFERRED $N" && [ "$(cat "$D/lock.d/owner")" = "$N" ] \
  && [ "$(cat "$D/lock.d/heartbeat_epoch")" -ge $(( $(now) - 5 )) ] && [ ! -f "$D/lock.d/ended/$O" ]
check "transfer writes the owner, refreshes the lock's heartbeat, drops the old owner's marker" $?
fails "  ... the old owner can no longer heartbeat" "only the owner" wl "$D" heartbeat --id t --sid "$O"
wl "$D" heartbeat --id t --sid "$N" >/dev/null 2>&1; check "  ... the new owner can" $?

# --- status -------------------------------------------------------------------------------------
D="$(team l)"; wl "$D" turn take --id t --sid "$M1" --eta +5m --task 'say "hi"' >/dev/null 2>&1
_o="$(wl "$D" status 2>&1)"
printf '%s' "$_o" | grep -qF '"kind": "owned",' && printf '%s' "$_o" | grep -qF '"owner": "aaaaaaaa",' \
  && printf '%s' "$_o" | grep -qF '"members": 2,' && printf '%s' "$_o" | grep -qF '"turn_holder": "bbbbbbbb",' \
  && printf '%s' "$_o" | grep -qF '"turn_task": "say hi",' && printf '%s' "$_o" | grep -qF '"last_give": ""'
check "owned status: kind, owner, members, turn holder and task, last_give" $?
if command -v jq >/dev/null 2>&1; then
  [ "$(printf '%s' "$_o" | jq -r .state 2>/dev/null)" = locked ]; check "  ... and it parses as JSON" $?
fi
wl "$D" turn give --id t --sid "$M1" --tree dirty >/dev/null 2>&1
wl "$D" status 2>&1 | grep -q '"last_give": "[0-9T:Z-]* bbbbbbbb dirty"'; check "status shows the last give" $?
D2="$(newdir l2)"; wl "$D2" acquire --id open >/dev/null 2>&1
_o="$(wl "$D2" status 2>&1)"; ! printf '%s' "$_o" | grep -qF '"kind"' && [ "$_o" = "$(cat "$D2/status.json")" ]
check "an open lock's status is the mirror, unchanged" $?

# --- end markers are cleared by the session's next lock call ----------------------------------------
D="$(team m)"
printf '%s other\n' "$(now)" > "$D/lock.d/ended/$O"; wl "$D" heartbeat --id t --sid "$O" >/dev/null 2>&1
[ ! -f "$D/lock.d/ended/$O" ]; check "the owner's heartbeat clears its end marker" $?
printf '%s other\n' "$(now)" > "$D/lock.d/ended/$M1"; wl "$D" turn take --id t --sid "$M1" --eta +5m >/dev/null 2>&1
[ ! -f "$D/lock.d/ended/$M1" ] && [ "$(cat "$D/lock.d/turn.d/sid")" = "$M1" ]; check "turn take clears the member's end marker and takes the turn" $?
printf '%s other\n' "$(now)" > "$D/lock.d/ended/$M1"; wl "$D" turn give --id t --sid "$M1" --tree clean >/dev/null 2>&1
[ ! -f "$D/lock.d/ended/$M1" ]; check "turn give clears it" $?
printf '%s other\n' "$(now)" > "$D/lock.d/ended/$M2"; wl "$D" member add --id t --sid "$M2" --by "$O" >/dev/null 2>&1
[ ! -f "$D/lock.d/ended/$M2" ]; check "member add (again) clears it" $?

# --- clear on an owned lock -----------------------------------------------------------------------
D="$(team n)"; wl "$D" turn take --id t --sid "$M1" --eta +5m >/dev/null 2>&1
_now="$(now)"; printf '%s\n' $(( _now - 4000 )) > "$D/lock.d/eta_epoch"; printf '%s\n' $(( _now - 4000 )) > "$D/lock.d/heartbeat_epoch"
fails "clear is refused while a member's turn beats within the grace" "turn is alive" wl "$D" clear --check --id c --holder t
turn_age "$D" -3600 4000
fails "clear is refused inside the turn's ETA even with no recent beat" "turn is alive" wl "$D" clear --check --id c --holder t
turn_age "$D" 4000 4000
wl "$D" clear --check --id c --holder t 2>&1 | grep -q '^CLEARABLE '; check "clear is allowed once the turn is stale too" $?
wl "$D" clear --id c --holder t >/dev/null 2>&1 && [ ! -d "$D/lock.d" ]; check "clear removes the lock with its turn and members" $?
fails "after a clear, the member's next turn verb says the lock was cleared" "was cleared by 'c'" wl "$D" turn give --id t --sid "$M1" --tree clean

# --- a release racing turn takes leaves lock.d whole or gone, never half-removed --------------------
_orph=0
for _i in 1 2 3 4 5 6; do
  D="$(team "r$_i")"
  wl "$D" turn take --id t --sid "$M1" --eta +5m >/dev/null 2>&1 &
  wl "$D" member add --id t --sid "ffffffff-0000-4000-8000-0000000000$_i$_i" --by "$O" >/dev/null 2>&1 &
  wl "$D" release --id t --sid "$O" --force >/dev/null 2>&1
  wait
  if [ -d "$D/lock.d" ] && [ ! -f "$D/lock.d/holder" ]; then _orph=$((_orph + 1)); fi
done
[ "$_orph" = 0 ]; check "release racing a take and an add never leaves an orphaned lock.d ($_orph)" $?

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
