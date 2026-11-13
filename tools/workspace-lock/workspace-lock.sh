#!/usr/bin/env bash
# workspace-lock.sh — advisory lock serializing the mutating work of independent sessions on a
# shared working copy. PURE lock mechanism: no git, no network (git is done by the caller via MCP).
#
# On-disk layout — one dot-prefixed folder (created on first acquire):
#   $WORKSPACE_LOCK_DIR/          must be ABSOLUTE when set via env (default: $PWD/.workspace-lock)
#     status.json                    persistent display MIRROR: {"state":"free"} | {"state":"locked",…}
#     lock.d/                        the lock: present = held — AUTHORITATIVE for held/free
#     lock.d/claim                   empty; its exclusive create decides who holds lock.d
#     lock.d/holder                  the AUTHORITATIVE holder id (written before the mirror)
#     lock.d/{eta_epoch,phase,task,reason,repos,acquired_at}   token metadata — lets heartbeat
#                                    rebuild the mirror after a race/crash stamps it free
#     lock.d/heartbeat_epoch         last acquire/heartbeat (epoch) — the liveness half of `clear`
#     cleared/<id>                   "<epoch> <by-id>": <id>'s lock was cleared; its next lock call
#                                    fails loudly until a successful release
#     workspace-lock.log          durable give-up/refuse/wedge/clear log
#   Owned team (only `acquire --owned` writes these; without lock.d/kind the lock is an open one):
#     lock.d/kind                    "owned", written before holder
#     lock.d/owner                   the owner's session id, written before holder
#     lock.d/members/<sid>           "<added epoch>", one per member the owner added (at most 16)
#     lock.d/ended/<sid>             "<epoch> <reason>": that session's process stopped (written by a
#                                    session-end hook); its next lock call clears it
#     lock.d/turn.d/                 the turn: one member mutates at a time
#     lock.d/turn.d/sid              the turn holder's session id; its exclusive create decides the turn
#     lock.d/turn.d/{eta_epoch,heartbeat_epoch,task,taken_at}
#     lock.d/last_give               "<epoch> <sid> <clean|dirty|unknown>": the last hand-over
#
# The mutex is `lock.d`, won by an exclusive create (noclobber, O_EXCL) of `lock.d/claim`, never by
# mkdir's exit status: some mkdir builds exit 0 when another process created the directory first.
# The holder id lives in `lock.d/holder`. `release` and
# `heartbeat` authenticate against `lock.d/holder` — NEVER `status.json` — and refuse on an unknown
# or mismatched holder. `status.json` is a display MIRROR only: every acquire gates on `lock.d`,
# never on the flag, so it can never cause a double-acquire. `status` is read-only and reconciles
# the reported state from `lock.d` (present → held, absent → free).
#
# See docs/adr/0012-overnight-orchestrator-lock.md.
# Canonical install (via /setup-claude): ~/.claude/tools/workspace-lock.sh — invoke as
#   $HOME/.claude/tools/workspace-lock.sh <sub> …   (allowlist Bash($HOME/.claude/tools/workspace-lock.sh *))
#
# Subcommands: acquire | release | status | heartbeat | clear | member | turn | owner
#   (run `acquire` and `turn take` in the BACKGROUND)
# Expiry (ADR 0012): once the ETA passes, the guard denies the holder's own
#   mutations until it retakes with `heartbeat --eta <new>` (a bare heartbeat is refused). Once
#   WEDGE_GRACE has passed since BOTH the ETA and the last heartbeat, another interactive session
#   may `clear --id <me> --holder <h>` — the guard asks the user first.
# Identity: `--id <slug>` on every verb, or env WORKSPACE_LOCK_ID (flag wins if both set). Never
#   use the inline `VAR=x <script>` prefix form — it defeats the Bash allowlist match.
# Owned team: `acquire --owned --sid <sid>` makes the caller's session the owner. The owner adds
#   members (`member add|remove|list`); a member never acquires. One session mutates at a time: the
#   one that holds the turn (`turn take` in the BACKGROUND, `turn beat`, `turn give --tree
#   clean|dirty`). Only the owner heartbeats or releases an owned lock (`--sid <owner>`). A stuck turn
#   is freed with `turn give --force` (at once when its session ended, else after a prompt), a lost
#   owner with `owner transfer` (after a prompt); `--check` reports which, read-only. A <sid> is the
#   session's own literal $CLAUDE_CODE_SESSION_ID: 36 characters of 0-9, a-f and '-'. The script
#   records the caller's word; a guard hook checks it against the calling session.
# Config (env): WORKSPACE_LOCK_DIR (absolute), WORKSPACE_LOCK_MAX_WAIT, WORKSPACE_LOCK_INIT_LEASE,
#   WORKSPACE_LOCK_WEDGE_GRACE, WORKSPACE_LOCK_LOG, WORKSPACE_LOCK_TEST_POLL.
# Exit: 0 ok · 1 usage/precondition · 2 acquire or turn take timed out.
# Dependency-free (no jq); portable to macOS bash 3.2 and GNU/Linux.

set -u

die()       { echo "workspace-lock: $*" >&2; exit 1; }

# The lock path must never depend on where a FRESH shell happens to start (a relative path would
# let one session hold locks at two different resolved paths and self-deadlock). Env values
# must be absolute; the default resolves against $PWD once, here, so every path below is absolute.
LOCK_DIR="${WORKSPACE_LOCK_DIR:-}"
if [ -n "$LOCK_DIR" ]; then
  case "$LOCK_DIR" in
    /*) : ;;
    *)  die "WORKSPACE_LOCK_DIR must be an absolute path (got: '$LOCK_DIR')" ;;
  esac
else
  LOCK_DIR="$PWD/.workspace-lock"
fi
TOKEN_DIR="$LOCK_DIR/lock.d"
STATUS_FILE="$LOCK_DIR/status.json"
CLEARED_DIR="$LOCK_DIR/cleared"
TURN_DIR="$TOKEN_DIR/turn.d"
MAX_MEMBERS=16
LOCK_LOG="${WORKSPACE_LOCK_LOG:-$LOCK_DIR/workspace-lock.log}"
MAX_WAIT="${WORKSPACE_LOCK_MAX_WAIT:-28800}"
INIT_LEASE="${WORKSPACE_LOCK_INIT_LEASE:-1800}"
# The one grace: a waiter's WEDGED warning, and `clear` (past ETA + grace AND heartbeat + grace).
WEDGE_GRACE="${WORKSPACE_LOCK_WEDGE_GRACE:-1800}"
POLL_BASE=30        # seconds between a waiter's rechecks of a held lock
POLL_JITTER=5       # plus 0..N seconds, so two waiters do not recheck in lockstep
TURN_POLL_BASE=10   # the same for a `turn take` waiter: turns are short, so recheck sooner
TURN_POLL_JITTER=3
SAY_EVERY=600       # repeat an unchanged BUSY/WARN wait line at most this often

now_epoch() { date -u +%s; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Integer env config feeds arithmetic; force base-10 so leading zeros are not read as octal.
case "$MAX_WAIT"    in ''|*[!0-9]*) die "WORKSPACE_LOCK_MAX_WAIT must be a non-negative integer" ;; esac
case "$INIT_LEASE"  in ''|*[!0-9]*) die "WORKSPACE_LOCK_INIT_LEASE must be a non-negative integer" ;; esac
case "$WEDGE_GRACE" in ''|*[!0-9]*) die "WORKSPACE_LOCK_WEDGE_GRACE must be a non-negative integer" ;; esac
MAX_WAIT=$(( 10#$MAX_WAIT )); INIT_LEASE=$(( 10#$INIT_LEASE )); WEDGE_GRACE=$(( 10#$WEDGE_GRACE ))

# Holder id feeds the JSON and the release/heartbeat auth check; restrict to a safe slug so
# json_get round-trips it exactly (a comma/quote would truncate on read and lock the owner out).
# Identity arrives via `--id <slug>` (assigned to WORKSPACE_LOCK_ID before this runs; flag wins)
# or the env var directly.
require_id() {
  case "${WORKSPACE_LOCK_ID:-}" in
    '') die "lock id must be set (--id <slug> or env WORKSPACE_LOCK_ID)" ;;
    *[!A-Za-z0-9._-]*) die "WORKSPACE_LOCK_ID must match [A-Za-z0-9._-]+ (got: '$WORKSPACE_LOCK_ID')" ;;
  esac
}

# Strip control chars (newline/CR/tab/other C0) and escape backslash/quote so a value stays valid
# single-line JSON. Backslash is escaped before quote to avoid double-escaping.
sanitize() { printf '%s' "$1" | tr -d '\001-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Portable epoch -> ISO 8601 UTC. Detect GNU (`date -d @epoch`) by capability, else BSD/macOS.
epoch_to_iso() {
  if date -u -d @0 +%Y >/dev/null 2>&1; then date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
  else date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; fi
}

# json_get <key> <file> — read a value from our own predictable one-field-per-line JSON (no jq).
json_get() {
  _k="$1"; _f="$2"; [ -f "$_f" ] || return 1
  sed -n "s/.*\"$_k\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}.*/\1/p" "$_f" | head -n1
}

log_line() {
  mkdir -p "$(dirname "$LOCK_LOG")" 2>/dev/null || true
  printf '%s  %s  %s\n' "$(now_iso)" "${WORKSPACE_LOCK_ID:-unknown}" "$*" >> "$LOCK_LOG" 2>/dev/null || true
}

# "+4h" / "+30m" / "+90s" / bare-seconds -> non-negative seconds. Returns 1 (no output) on
# anything else, so callers use: v="$(eta_to_seconds "$x")" || die ...  ('die' inside a command
# substitution would only exit the subshell, so validation is propagated by exit code).
eta_to_seconds() {
  _v="${1#+}"; _mult=1
  case "$_v" in
    *h) _n="${_v%h}"; _mult=3600 ;;
    *m) _n="${_v%m}"; _mult=60 ;;
    *s) _n="${_v%s}" ;;
    *)  _n="$_v" ;;
  esac
  case "$_n" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( 10#$_n * _mult ))   # 10# forces base-10 so "+08h"/"+010h" are decimal, not octal
}

# "a,b,c" -> ["a","b","c"] ; "" -> []  (paths must not contain commas — see README).
repos_json() {
  _out="["; _first=1; _OLDIFS="$IFS"; IFS=','
  for _r in $1; do
    [ -n "$_r" ] || continue
    if [ "$_first" -eq 1 ]; then _first=0; else _out="$_out,"; fi
    _out="$_out\"$(sanitize "$_r")\""
  done
  IFS="$_OLDIFS"; printf '%s]' "$_out"
}

# Atomically replace status.json with the content in $1 (temp + mv; clean up temp on failure).
write_status() {
  _tmp="$LOCK_DIR/.status.$$.tmp"
  printf '%s\n' "$1" > "$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
  mv -f "$_tmp" "$STATUS_FILE" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
}

# The AUTHORITATIVE holder id lives inside the mutex token (written at acquire, before the mirror).
# release/heartbeat authenticate against THIS, never the non-authoritative status.json mirror.
token_holder() { cat "$TOKEN_DIR/holder" 2>/dev/null || true; }

# Lock metadata also lives inside the token (one plain file per field, written by acquire and kept
# current by heartbeat) so the display mirror can be REBUILT from the token alone after a
# release/re-acquire race or crash stamps status.json free while the lock is still held.
token_meta() { head -n1 "$TOKEN_DIR/$1" 2>/dev/null || true; }

# Uses globals H_ETA_EPOCH H_PHASE H_TASK H_REASON H_REPOS H_ACQUIRED_AT.
token_write_meta() {
  now_epoch                      > "$TOKEN_DIR/heartbeat_epoch" &&
  printf '%s\n' "$H_ETA_EPOCH"   > "$TOKEN_DIR/eta_epoch"   &&
  printf '%s\n' "$H_PHASE"       > "$TOKEN_DIR/phase"       &&
  printf '%s\n' "$H_TASK"        > "$TOKEN_DIR/task"        &&
  printf '%s\n' "$H_REASON"      > "$TOKEN_DIR/reason"      &&
  printf '%s\n' "$H_REPOS"       > "$TOKEN_DIR/repos"       &&
  printf '%s\n' "$H_ACQUIRED_AT" > "$TOKEN_DIR/acquired_at"
}

# ETA of the held lock as an epoch, token first (authoritative), mirror second; empty if unknown.
lock_eta_epoch() {
  _le="$(token_meta eta_epoch)"
  case "$_le" in ''|*[!0-9]*) _le="$(json_get eta_epoch "$STATUS_FILE" 2>/dev/null || true)" ;; esac
  case "$_le" in ''|*[!0-9]*) echo "" ;; *) echo "$_le" ;; esac
}

# lock_expired <grace>: the one clock — the held lock's ETA plus <grace> seconds has passed.
lock_expired() {
  _xe="$(lock_eta_epoch)"
  [ -n "$_xe" ] && [ "$(now_epoch)" -gt $(( _xe + $1 )) ]
}

# Last acquire/heartbeat as an epoch; empty when unknown (a lock taken before the field existed).
heartbeat_epoch() {
  _hx="$(token_meta heartbeat_epoch)"
  case "$_hx" in ''|*[!0-9]*) echo "" ;; *) echo "$_hx" ;; esac
}

# --- Owned team helpers --------------------------------------------------------------------------
# A session id is a lowercase UUID (8-4-4-4-12 hex digits). The format check keeps a value safe as
# a file name under members/ and ended/ (no '/', no '..', never empty).
_H='[0123456789abcdef]'   # spelled out: a range like a-f can match uppercase in some locales
SID_GLOB="$_H$_H$_H$_H$_H$_H$_H$_H-$_H$_H$_H$_H-$_H$_H$_H$_H-$_H$_H$_H$_H-$_H$_H$_H$_H$_H$_H$_H$_H$_H$_H$_H$_H"
valid_sid() {
  # shellcheck disable=SC2254  # SID_GLOB is a pattern on purpose
  case "$1" in $SID_GLOB) return 0 ;; *) return 1 ;; esac
}
require_sid() {   # <flag> <value>
  valid_sid "$2" || die "$1 must be a session id, a lowercase UUID (pass the literal value of \$CLAUDE_CODE_SESSION_ID; got: '$2')"
}
short()      { printf '%s' "$1" | cut -c1-8; }
is_owned()   { [ "$(token_meta kind)" = "owned" ]; }
lock_owner() { token_meta owner; }
is_member()  { [ -n "$1" ] && [ -f "$TOKEN_DIR/members/$1" ]; }
# is_party <sid>: the owner or a member of the held owned lock.
is_party()   { _po="$(lock_owner)"; { [ -n "$_po" ] && [ "$1" = "$_po" ]; } || is_member "$1"; }
turn_sid()   { head -n1 "$TURN_DIR/sid" 2>/dev/null || true; }
turn_meta()  { head -n1 "$TURN_DIR/$1" 2>/dev/null || true; }
num_or_empty() { case "$1" in ''|*[!0-9]*) echo "" ;; *) echo "$1" ;; esac; }
# A verified owner or member's lock call is its "next lock call" after a session-end hook wrote
# ended/<sid>: the session is back (a session id survives a resume or a window reload; only a
# /clear makes a new one).
clear_ended() { valid_sid "$1" || return 0; rm -f "$TOKEN_DIR/ended/$1" 2>/dev/null || true; }
member_count() {
  _mc=0
  for _mf in "$TOKEN_DIR/members"/*; do [ -f "$_mf" ] && _mc=$((_mc + 1)); done
  echo "$_mc"
}
# Holder-written free text for a prompt: printable ASCII only, no quotes, capped (as clear --check).
safe_text() { printf '%s' "$1" | LC_ALL=C tr -cd ' -~' | LC_ALL=C tr -d '"' | cut -c1-80; }

# The lock a member/turn/owner verb acts on: held, with the caller's slug, and owned. Never creates
# anything: these verbs only ever write inside an existing lock.d.
require_owned_lock() {
  if [ ! -d "$TOKEN_DIR" ]; then
    _cm="$(cleared_msg "$WORKSPACE_LOCK_ID")" && die "$_cm"
    die "no lock held at $LOCK_DIR"
  fi
  _rh="$(token_holder)"
  [ "$_rh" = "$WORKSPACE_LOCK_ID" ] || die "the lock at $LOCK_DIR is held by '${_rh:-unknown}', not '$WORKSPACE_LOCK_ID'"
  is_owned || die "lock '$WORKSPACE_LOCK_ID' is not an owned lock (only acquire --owned makes one)"
  [ -n "$(lock_owner)" ] || die "owned lock '$WORKSPACE_LOCK_ID' has no owner recorded; a human inspects it"
}

# record_give <sid> <clean|dirty|unknown>: the last hand-over, read by the next `turn take`.
# Written (temp + rename) BEFORE the turn is freed, so the next taker never reads an older one.
# Returns 1 when it could not write: a caller must never leave an older record standing.
record_give() {
  _rg="$TOKEN_DIR/.last_give.$$.tmp"
  { printf '%s %s %s\n' "$(now_epoch)" "$1" "$2" > "$_rg" && mv -f "$_rg" "$TOKEN_DIR/last_give"; } 2>/dev/null \
    && return 0
  rm -f "$_rg" 2>/dev/null
  return 1
}
# For a give that frees the turn whatever happens (remove, force): no record beats a stale one.
record_give_or_drop() { record_give "$1" "$2" || rm -f "$TOKEN_DIR/last_give" 2>/dev/null || true; }

# A path in a prompt line: printable ASCII only, so a directory name cannot reorder the text.
prompt_path() { printf '%s' "$1" | LC_ALL=C tr -cd ' -~'; }

# remove_dir <dir>: rename first, then delete. A rename is atomic, so a writer that arrives late
# (a turn take's claim, a member add's write) gets ENOENT instead of landing in a half-deleted
# directory. With a plain rm -rf a late entry makes the final rmdir fail and leaves a lock.d with
# no holder (the orphan state) or a turn.d with no sid.
remove_dir() {
  [ -d "$1" ] || return 0
  _rd="$1.gone.$$.$RANDOM"
  # No rm -rf fallback when the rename fails: the directory may already be someone else's new one.
  # A rename lost to a concurrent remover is a success (the directory is gone either way).
  mv "$1" "$_rd" 2>/dev/null || { [ -d "$1" ] || return 0; return 1; }
  rm -rf "$_rd"
}

# Prints the loud "your lock was cleared" message for <id> and returns 0, or returns 1 if none.
cleared_msg() {
  [ -f "$CLEARED_DIR/$1" ] || return 1
  _ce=""; _cby=""
  read -r _ce _cby < "$CLEARED_DIR/$1" 2>/dev/null || true
  case "$_ce" in ''|*[!0-9]*) _cat=unknown ;; *) _cat="$(epoch_to_iso "$_ce")" ;; esac
  echo "lock '$1' was cleared by '${_cby:-unknown}' at ${_cat} after its ETA expired; work since then was unserialized — stop and tell the user"
}

# Repopulate the H_* globals for status_locked_json from the token metadata. Caller must have
# verified ownership first. Missing fields degrade to safe defaults rather than failing.
rebuild_locked_from_token() {
  H_REPOS_JSON="$(repos_json "$(token_meta repos)")"
  H_PHASE="$(token_meta phase)";             [ -n "$H_PHASE" ] || H_PHASE="work"
  H_TASK="$(token_meta task)"
  H_REASON="$(token_meta reason)"
  H_ACQUIRED_AT="$(token_meta acquired_at)"; [ -n "$H_ACQUIRED_AT" ] || H_ACQUIRED_AT="$(now_iso)"
  H_ETA_EPOCH="$(token_meta eta_epoch)"
  case "$H_ETA_EPOCH" in ''|*[!0-9]*) H_ETA_EPOCH=$(( $(now_epoch) + INIT_LEASE )) ;; esac
}

status_free_json() { printf '{\n  "state": "free"\n}'; }

# Locked status JSON. Uses globals H_REPOS_JSON H_PHASE H_TASK H_REASON H_ETA_EPOCH H_ACQUIRED_AT.
status_locked_json() {
  _eta_iso="$(epoch_to_iso "$H_ETA_EPOCH")"
  _phase="$(sanitize "$H_PHASE")"; _task="$(sanitize "$H_TASK")"; _reason="$(sanitize "$H_REASON")"
  _host="$(sanitize "$(hostname 2>/dev/null || echo unknown)")"
  printf '{\n'
  printf '  "state": "locked",\n'
  printf '  "holder_id": "%s",\n' "$WORKSPACE_LOCK_ID"
  printf '  "repos": %s,\n'       "$H_REPOS_JSON"
  printf '  "phase": "%s",\n'     "$_phase"
  printf '  "task": "%s",\n'      "$_task"
  printf '  "reason": "%s",\n'    "$_reason"
  printf '  "acquired_at": "%s",\n' "$(sanitize "$H_ACQUIRED_AT")"
  printf '  "eta": "%s",\n'       "$_eta_iso"
  printf '  "eta_epoch": %s,\n'   "$H_ETA_EPOCH"
  printf '  "heartbeat": "%s",\n' "$(now_iso)"
  printf '  "host": "%s"\n'       "$_host"
  printf '}'
}

# Fixed short recheck plus jitter, whatever ETA the holder declared: a holder that releases
# early is noticed within one interval. (An ETA-scaled ladder slept up to an hour after an early
# release, because declared ETAs are padded.) A recheck is a local mkdir + small file reads.
compute_poll() {
  if [ -n "${WORKSPACE_LOCK_TEST_POLL:-}" ]; then echo "$WORKSPACE_LOCK_TEST_POLL"; return; fi
  echo $(( POLL_BASE + RANDOM % (POLL_JITTER + 1) ))
}

# Print a wait line on the first check, when the holder or wedge state changes, and otherwise at
# most every SAY_EVERY seconds, so a short poll does not flood the background output the caller
# reads. Uses globals _say_state/_say_at (set in cmd_acquire).
say_wait() {
  _sn="$(now_epoch)"
  if [ "$1" != "$_say_state" ] || [ $(( _sn - _say_at )) -ge "$SAY_EVERY" ]; then
    echo "$2" >&2
    _say_state="$1"; _say_at="$_sn"
  fi
}

# Narrow signal cleanup: only remove the token if THIS process created it but hasn't finished
# writing the mirror. Never touches a token we are merely waiting on.
# The same for a turn this process won but has not finished writing.
WE_OWN_UNWRITTEN=0; WE_OWN_TURN=0
cleanup_partial() {
  [ "$WE_OWN_UNWRITTEN" = "1" ] && remove_dir "$TOKEN_DIR"
  # Only while it is still ours: a member remove may have freed it and another member taken it.
  if [ "$WE_OWN_TURN" = "1" ]; then
    [ "$(turn_sid)" != "${O_SID:-}" ] || remove_dir "$TURN_DIR"
  fi
  exit 130
}

# The acquire-side mirror of the guard's under_archive: returns 0 when the lock dir sits
# under a .archive component with NO .git marker (dir, or the gitdir: FILE of a worktree/
# submodule) between the .archive component and the lock dir. A nested project legitimately
# archived under .archive/ keeps its own canonical lock — its .git stops the scan; only the
# bare-debris shape is refused. The .git check skips the lock dir itself (a .git inside the lock
# folder is not a workspace marker).
archive_debris_lock_dir() {
  _p="$LOCK_DIR"
  while [ -n "$_p" ] && [ "$_p" != "/" ] && [ "$_p" != "." ]; do
    case "$_p" in
      */.archive) return 0 ;;
    esac
    [ "$_p" != "$LOCK_DIR" ] && [ -e "$_p/.git" ] && return 1
    _p="$(dirname "$_p")"
  done
  return 1
}

cmd_acquire() {
  # A lock dir nested under a .archive/ component hijacks the guard's walk-up resolution
  # and breaks its .archive exemption. Refuse to acquire a bare-debris one (no .git marker
  # between — the guard would skip it); release/status still operate on an existing bad dir so
  # cleanup stays possible. Canonical location: <workspace-root>/.workspace-lock.
  if archive_debris_lock_dir; then
    die "refusing to acquire: lock dir is nested under a .archive component ($LOCK_DIR); use <workspace-root>/.workspace-lock, a sibling of .archive"
  fi
  trap cleanup_partial INT TERM
  H_REPOS=""; H_PHASE="work"; H_TASK=""; H_REASON=""; _eta_secs=""; _id_flag=""; _repos_set=0
  _after_clear=0; _owned=0; _sid=""; _sid_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --after-clear) _after_clear=1; shift ;;
      --owned)  _owned=1; shift ;;
      --sid)    [ $# -ge 2 ] || die "acquire: --sid requires a value";    _sid="$2";     _sid_set=1;  shift 2 ;;
      --repos)  [ $# -ge 2 ] || die "acquire: --repos requires a value";  H_REPOS="$2";  _repos_set=1;  shift 2 ;;
      --phase)  [ $# -ge 2 ] || die "acquire: --phase requires a value";  H_PHASE="$2";  shift 2 ;;
      --task)   [ $# -ge 2 ] || die "acquire: --task requires a value";   H_TASK="$2";   shift 2 ;;
      --reason) [ $# -ge 2 ] || die "acquire: --reason requires a value"; H_REASON="$2"; shift 2 ;;
      --eta)    [ $# -ge 2 ] || die "acquire: --eta requires a value"
                _eta_secs="$(eta_to_seconds "$2")" || die "invalid --eta: '$2' (use +Nh | +Nm | +Ns | seconds)"; shift 2 ;;
      --id)     [ $# -ge 2 ] || die "acquire: --id requires a value"; _id_flag="$2"; shift 2 ;;
      *) die "acquire: unknown arg: $1" ;;
    esac
  done
  [ -n "$_id_flag" ] && WORKSPACE_LOCK_ID="$_id_flag"   # flag wins over env
  require_id
  if [ "$_owned" = "1" ]; then
    require_sid --sid "$_sid"
    # Membership, turns and the tree record are per workspace root.
    [ "$_repos_set" = "0" ] || die "acquire: --repos does not go with --owned (an owned lock covers one workspace)"
  else
    [ "$_sid_set" = "0" ] || die "acquire: --sid goes with --owned"
  fi
  [ -n "$_eta_secs" ] || _eta_secs="$INIT_LEASE"
  # A cleared id never gets back in silently: it must say --after-clear (once the user agrees).
  # A reentrant hold (this id holds lock.d again, e.g. after an earlier --after-clear) passes.
  if [ "$_after_clear" = "0" ] && [ "$(token_holder)" != "$WORKSPACE_LOCK_ID" ] \
     && _cm="$(cleared_msg "$WORKSPACE_LOCK_ID")"; then
    die "$_cm; re-acquire with --after-clear once the user agrees"
  fi
  mkdir -p "$LOCK_DIR" 2>/dev/null || die "cannot create $LOCK_DIR"
  _start="$(now_epoch)"
  _wedge_logged=0; _say_state=""; _say_at=0; _miss=0
  while : ; do
    # The winner is whoever creates lock.d/claim (noclobber opens it O_EXCL): exactly one racer.
    # mkdir's status decides nothing (some builds exit 0 after losing the create race). A lock.d
    # that already has a holder is never claimed, so a lock taken before the claim file existed is
    # not taken over; that check only reads. Plain mkdir (LOCK_DIR was made above): a waiter whose
    # lock folder was removed fails its claim and stops, instead of rebuilding the folder.
    mkdir "$TOKEN_DIR" 2>/dev/null
    if [ ! -e "$TOKEN_DIR/holder" ] && ( set -C; : > "$TOKEN_DIR/claim" ) 2>/dev/null; then
      WE_OWN_UNWRITTEN=1
      # An owned lock writes kind and owner BEFORE holder, so no reader that sees the holder ever
      # takes it for an open lock. members/ and ended/ are made here, inside the fresh lock.d, so
      # later verbs never run mkdir near lock.d (a mkdir -p racing a release would recreate it).
      if [ "$_owned" = "1" ]; then
        if ! { printf 'owned\n' > "$TOKEN_DIR/kind" && printf '%s\n' "$_sid" > "$TOKEN_DIR/owner" \
               && mkdir "$TOKEN_DIR/members" "$TOKEN_DIR/ended"; } 2>/dev/null; then
          remove_dir "$TOKEN_DIR"; WE_OWN_UNWRITTEN=0
          die "acquired lock but failed to write the owned-lock files; released it"
        fi
      fi
      # Write the AUTHORITATIVE holder id inside the token FIRST — before the mirror — so a
      # concurrent release/heartbeat authenticates against real ownership, never a stale mirror.
      if ! printf '%s\n' "$WORKSPACE_LOCK_ID" > "$TOKEN_DIR/holder" 2>/dev/null; then
        remove_dir "$TOKEN_DIR"; WE_OWN_UNWRITTEN=0
        die "acquired lock but failed to write holder token; released it"
      fi
      H_ETA_EPOCH=$(( $(now_epoch) + _eta_secs ))
      H_ACQUIRED_AT="$(now_iso)"
      H_REPOS_JSON="$(repos_json "$H_REPOS")"
      if ! token_write_meta 2>/dev/null; then
        remove_dir "$TOKEN_DIR"; WE_OWN_UNWRITTEN=0
        die "acquired lock but failed to write token metadata; released it"
      fi
      if write_status "$(status_locked_json)"; then
        WE_OWN_UNWRITTEN=0
        if [ "$_owned" = "1" ]; then
          log_line "OWNED-ACQUIRED owner $(short "$_sid")"
          echo "ACQUIRED (owned) $WORKSPACE_LOCK_ID $LOCK_DIR"
        else
          echo "ACQUIRED $WORKSPACE_LOCK_ID $LOCK_DIR"
        fi
        return 0
      fi
      remove_dir "$TOKEN_DIR"; WE_OWN_UNWRITTEN=0        # partial-failure cleanup (the only "trap")
      die "acquired lock but failed to write status.json; released it"
    fi
    # Neither a claim nor a holder after a failed claim: not contention (a release removed lock.d in
    # between, or the create fails for another reason). Retry now, but never spin on a failing create.
    if [ ! -e "$TOKEN_DIR/claim" ] && [ ! -e "$TOKEN_DIR/holder" ]; then
      _miss=$((_miss + 1))
      [ "$_miss" -lt 3 ] || die "cannot create $TOKEN_DIR/claim"
      continue
    fi
    _miss=0
    _held="$(token_holder)"
    if [ -n "$_held" ] && [ "$_held" = "$WORKSPACE_LOCK_ID" ]; then
      # An owned lock is closed: only its owner re-enters, and only by saying --owned. Anyone else
      # with the slug exits at once (never waits: the slug is held, so a wait would never end). An
      # open lock is never converted. kind is written before holder, so it is settled by now.
      if is_owned; then
        _ow="$(lock_owner)"
        if [ "$_owned" != "1" ] || [ -z "$_ow" ] || [ "$_sid" != "$_ow" ]; then
          log_line "REFUSED acquire of owned lock; not its owner"
          die "lock '$WORKSPACE_LOCK_ID' is an owned lock and this call is not its owner (acquire --owned --sid <owner>). A member takes turns (turn take); anyone else asks the owner to add them (member add)"
        fi
      elif [ "$_owned" = "1" ]; then
        die "lock '$WORKSPACE_LOCK_ID' is held as an open lock; an open lock is never converted to an owned one"
      fi
      # Reentrant: this id already holds the lock (e.g. re-acquire after compaction or a fresh
      # shell). Refresh the token metadata + mirror from this call's args; never self-deadlock.
      H_ETA_EPOCH=$(( $(now_epoch) + _eta_secs ))
      H_ACQUIRED_AT="$(token_meta acquired_at)"; [ -n "$H_ACQUIRED_AT" ] || H_ACQUIRED_AT="$(now_iso)"
      # A reentrant join that did NOT pass --repos must preserve the arming call's repos list:
      # the guard's resolve_lock_dir reads lock.d/repos to recognize cross-repo team members, and
      # overwriting it with the empty default would silently stop serializing every sibling repo.
      [ "$_repos_set" = "1" ] || H_REPOS="$(token_meta repos)"
      H_REPOS_JSON="$(repos_json "$H_REPOS")"
      token_write_meta 2>/dev/null || true
      write_status "$(status_locked_json)" || true
      [ "$_owned" = "1" ] && clear_ended "$_sid"
      echo "ACQUIRED (already held) $WORKSPACE_LOCK_ID $LOCK_DIR"
      return 0
    fi
    _elapsed=$(( $(now_epoch) - _start ))
    if [ "$_elapsed" -ge "$MAX_WAIT" ]; then
      _by="${_held:-unknown}"
      log_line "GAVE UP after ${_elapsed}s; lock held by ${_by}"
      echo "TIMEOUT waited ${_elapsed}s; held by ${_by}. Tell the user; don't re-run this acquire." >&2
      return 2
    fi
    _poll="$(compute_poll)"; _cap=$(( MAX_WAIT - _elapsed ))
    [ "$_poll" -gt "$_cap" ] && _poll="$_cap"; [ "$_poll" -lt 1 ] && _poll=1
    if [ -z "$_held" ]; then
      # SIGKILL corpse: lock.d exists but the holder id never landed. Surface it as WEDGED and
      # keep waiting/timing out — no auto-remove, and `clear` refuses it too (human-cleared).
      say_wait unknown "WARN lock wedged, holder unknown — tell the user (a human inspects and clears it); next check in ${_poll}s"
      if [ "$_wedge_logged" -eq 0 ]; then log_line "WEDGED holder unknown at $TOKEN_DIR"; _wedge_logged=1; fi
    else
      if lock_expired "$WEDGE_GRACE"; then
        # Holder is past its ETA + grace: escalate to WARN and leave a durable line for the
        # morning handover to surface. The waiter never takes the lock itself; when the heartbeat
        # is stale too, it names the prompt-gated `clear` a session with a human can run.
        _eta_iso="$(epoch_to_iso "$(lock_eta_epoch)")"
        _hbe="$(heartbeat_epoch)"
        if [ -n "$_hbe" ]; then _hb="$(epoch_to_iso "$_hbe")"
        else _hb="$(json_get heartbeat "$STATUS_FILE" 2>/dev/null)"; [ -n "$_hb" ] || _hb=unknown; fi
        _hint=""
        if [ -z "$_hbe" ] || [ "$(now_epoch)" -gt $(( _hbe + WEDGE_GRACE )) ]; then
          _hint="; clearable from a session with a human: \$HOME/.claude/tools/workspace-lock.sh clear --id <you> --holder ${_held} (asks the user)"
        fi
        say_wait "wedged:$_held" "WARN lock wedged since ${_eta_iso}, held by ${_held}, heartbeat last ${_hb}${_hint}; next check in ${_poll}s"
        if [ "$_wedge_logged" -eq 0 ]; then
          log_line "WEDGED since ${_eta_iso}; held by ${_held}; heartbeat last ${_hb}"
          _wedge_logged=1
        fi
      else
        say_wait "busy:$_held" "BUSY held by ${_held}; next check in ${_poll}s"
      fi
    fi
    sleep "$_poll"
  done
}

# owned_owner_check <verb> <sid> <sid given 0|1>: on an owned lock only the owner, naming itself
# with --sid, may release or heartbeat it. An open lock ignores --sid (after the format check).
owned_owner_check() {
  [ "$3" = "0" ] || require_sid --sid "$2"
  is_owned || return 0
  [ "$3" = "1" ] || die "$1: lock '$WORKSPACE_LOCK_ID' is an owned lock; only its owner may $1 it, with --sid <owner sid>"
  _oo="$(lock_owner)"
  if [ -z "$_oo" ] || [ "$2" != "$_oo" ]; then
    log_line "REFUSED $1 of owned lock; not its owner"
    die "$1: only the owner of lock '$WORKSPACE_LOCK_ID' may $1 it; ask the session that owns this lock"
  fi
}

cmd_release() {
  _id_flag=""; _sid=""; _sid_set=0; _force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --id)  [ $# -ge 2 ] || die "release: --id requires a value"; _id_flag="$2"; shift 2 ;;
      --sid) [ $# -ge 2 ] || die "release: --sid requires a value"; _sid="$2"; _sid_set=1; shift 2 ;;
      --force) _force=1; shift ;;
      *) die "release: unknown arg: $1" ;;
    esac
  done
  [ -n "$_id_flag" ] && WORKSPACE_LOCK_ID="$_id_flag"   # flag wins over env
  require_id
  if [ ! -d "$TOKEN_DIR" ]; then
    _cm="$(cleared_msg "$WORKSPACE_LOCK_ID")" && die "$_cm"
    # Honest release: only report FREE when a lock folder actually lives at this resolved path.
    # No folder here means the lock was (most likely) acquired under a different directory —
    # printing FREE would hide a still-held lock elsewhere.
    [ -d "$LOCK_DIR" ] && { echo "FREE (nothing to release)"; return 0; }
    die "nothing to release: no lock folder at $LOCK_DIR — if acquired under a different directory, set WORKSPACE_LOCK_DIR to that absolute path"
  fi
  _held="$(token_holder)"
  if [ "$_held" != "$WORKSPACE_LOCK_ID" ]; then      # refuse on mismatch AND on unknown (empty)
    _cm="$(cleared_msg "$WORKSPACE_LOCK_ID")" && die "$_cm"
    log_line "REFUSED release; lock held by '${_held:-unknown}', not me"
    die "refusing to release lock held by '${_held:-unknown}' (I am '$WORKSPACE_LOCK_ID'); if its holder is dead, see 'clear' (asks the user)"
  fi
  owned_owner_check release "$_sid" "$_sid_set"
  is_owned || [ "$_force" = "0" ] || die "release: --force goes with an owned lock (it releases one while a turn is held)"
  # A member mid-unit must not lose the lock under it: wait for the turn, or say --force. A take
  # that wins between this check and the removal below is an accepted residual: the member's
  # next mutation finds no lock.
  if is_owned && [ -d "$TURN_DIR" ] && [ "$_force" = "0" ]; then
    _ts="$(turn_sid)"
    die "release: a turn is held by '$(short "${_ts:-unknown}")' (task: \"$(safe_text "$(turn_meta task)")\"); wait for its turn give, or release --force"
  fi
  # Mirror first, then token: if a racer wins lock.d the instant the rm lands, it immediately
  # re-stamps the mirror locked — this order can never leave a held lock displayed as free.
  write_status "$(status_free_json)" || true
  # Authoritative release (rename, then delete). Judge by remove_dir's status, never by whether a
  # lock.d exists afterwards: a waiter may already have taken a new one.
  remove_dir "$TOKEN_DIR" || die "release: failed to remove $TOKEN_DIR"
  rm -f "$CLEARED_DIR/$WORKSPACE_LOCK_ID" 2>/dev/null   # a normal end closes an earlier --after-clear
  echo "RELEASED $WORKSPACE_LOCK_ID"
}

# The owned-team fields of `status`, composed live from lock.d (turns never rewrite the mirror):
# JSON member lines with no trailing comma on the last one. Sids are shown by their first 8.
owned_status_fields() {
  printf '  "kind": "owned",\n'
  printf '  "owner": "%s",\n' "$(short "$(lock_owner)")"
  printf '  "members": %s,\n' "$(member_count)"
  if [ -d "$TURN_DIR" ]; then
    _te="$(num_or_empty "$(turn_meta eta_epoch)")"
    printf '  "turn_holder": "%s",\n' "$(short "$(turn_sid)")"
    printf '  "turn_task": "%s",\n' "$(sanitize "$(safe_text "$(turn_meta task)")")"
    printf '  "turn_eta": "%s",\n' "$([ -n "$_te" ] && epoch_to_iso "$_te")"
  else
    printf '  "turn_holder": "",\n'
  fi
  _lg_e=""; _lg_s=""; _lg_t=""
  read -r _lg_e _lg_s _lg_t 2>/dev/null < "$TOKEN_DIR/last_give" || true
  _lg_e="$(num_or_empty "$_lg_e")"
  if [ -n "$_lg_e" ]; then
    printf '  "last_give": "%s %s %s"\n' "$(epoch_to_iso "$_lg_e")" "$(short "$_lg_s" | LC_ALL=C tr -cd '0-9a-f-')" \
      "$(printf '%s' "$_lg_t" | LC_ALL=C tr -cd 'a-z')"
  else
    printf '  "last_give": ""\n'
  fi
}

cmd_status() {
  # Read-only: the state is reconciled from the authoritative token; nothing is created or written.
  if [ -d "$TOKEN_DIR" ]; then
    if [ -f "$STATUS_FILE" ] && [ "$(json_get state "$STATUS_FILE" 2>/dev/null || echo)" = "locked" ]; then
      _body="$(cat "$STATUS_FILE")"
    else                                            # token held but mirror stale/missing
      _h="$(token_holder)"
      _body="$(printf '{\n  "state": "locked",\n  "holder_id": "%s",\n  "note": "mirror unavailable"\n}' "$(sanitize "${_h:-unknown}")")"
    fi
    if is_owned; then
      # The mirror ends in a lone "}" line (status_locked_json): drop it, add the fields, close again.
      printf '%s,\n%s\n}\n' "$(printf '%s\n' "$_body" | sed '$d')" "$(owned_status_fields)"
    else
      printf '%s\n' "$_body"
    fi
  else
    status_free_json; echo
  fi
}

cmd_heartbeat() {
  _new_eta=""; _phase=""; _id_flag=""; _sid=""; _sid_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --sid)   [ $# -ge 2 ] || die "heartbeat: --sid requires a value"; _sid="$2"; _sid_set=1; shift 2 ;;
      --eta)   [ $# -ge 2 ] || die "heartbeat: --eta requires a value"
               _new_eta="$(eta_to_seconds "$2")" || die "invalid --eta: '$2' (use +Nh | +Nm | +Ns | seconds)"; shift 2 ;;
      --phase) [ $# -ge 2 ] || die "heartbeat: --phase requires a value"; _phase="$2"; shift 2 ;;
      --id)    [ $# -ge 2 ] || die "heartbeat: --id requires a value"; _id_flag="$2"; shift 2 ;;
      *) die "heartbeat: unknown arg: $1" ;;
    esac
  done
  [ -n "$_id_flag" ] && WORKSPACE_LOCK_ID="$_id_flag"   # flag wins over env
  require_id
  if [ ! -d "$TOKEN_DIR" ]; then
    _cm="$(cleared_msg "$WORKSPACE_LOCK_ID")" && die "$_cm"
    die "no lock held to heartbeat"
  fi
  _held="$(token_holder)"
  if [ "$_held" != "$WORKSPACE_LOCK_ID" ]; then
    _cm="$(cleared_msg "$WORKSPACE_LOCK_ID")" && die "$_cm"
    die "cannot heartbeat lock held by '${_held:-unknown}' (I am '$WORKSPACE_LOCK_ID')"
  fi
  owned_owner_check heartbeat "$_sid" "$_sid_set"
  is_owned && clear_ended "$_sid"
  # Past its ETA the lock is re-armed: only a heartbeat that declares a new ETA retakes it. A bare
  # beat would refresh liveness forever without ever revising the estimate a waiter reads.
  if [ -z "$_new_eta" ] && lock_expired 0; then
    die "ETA expired at $(epoch_to_iso "$(lock_eta_epoch)"); retake with: \$HOME/.claude/tools/workspace-lock.sh heartbeat --id $WORKSPACE_LOCK_ID${_sid:+ --sid $_sid} --eta +30m"
  fi
  # Keep the token metadata current FIRST (it is what any rebuild reads), then the mirror.
  now_epoch > "$TOKEN_DIR/heartbeat_epoch" 2>/dev/null || true
  _ee=""
  if [ -n "$_new_eta" ]; then
    _ee=$(( $(now_epoch) + _new_eta ))
    printf '%s\n' "$_ee" > "$TOKEN_DIR/eta_epoch" 2>/dev/null || true
  fi
  [ -n "$_phase" ] && { printf '%s\n' "$_phase" > "$TOKEN_DIR/phase" 2>/dev/null || true; }
  # Then rebuild the whole mirror from the token metadata: an in-place edit of status.json cannot
  # safely match a stored value that holds escaped quotes. A mirror that says free (a release/
  # re-acquire race stamped it) or is missing is rebuilt the same way.
  _note=""
  if [ ! -f "$STATUS_FILE" ] || [ "$(json_get state "$STATUS_FILE" 2>/dev/null || echo)" != "locked" ]; then
    _note=" (mirror rebuilt)"
  fi
  rebuild_locked_from_token
  write_status "$(status_locked_json)" || die "heartbeat: failed to update status.json"
  echo "HEARTBEAT $WORKSPACE_LOCK_ID$_note"
}

# Why <holder>'s lock may NOT be cleared by $WORKSPACE_LOCK_ID right now; prints nothing when it
# may. Read-only. Shared by `clear --check`, `clear`, and its re-check just before the removal.
clear_refusal() {
  _ch="$(token_holder)"
  [ -n "$_ch" ] || { echo "holder unknown (empty $TOKEN_DIR/holder); a human inspects and clears it"; return; }
  [ "$_ch" = "$1" ] || { echo "lock is held by '$_ch', not '$1'"; return; }
  [ "$_ch" != "$WORKSPACE_LOCK_ID" ] || { echo "you hold this lock; retake it with heartbeat --id $_ch --eta <new>, or release it"; return; }
  _cn="$(now_epoch)"; _cx="$(lock_eta_epoch)"
  [ -n "$_cx" ] || { echo "no ETA recorded for '$_ch'; a human inspects and clears it"; return; }
  [ "$_cn" -gt $(( _cx + WEDGE_GRACE )) ] \
    || { echo "ETA $(epoch_to_iso "$_cx") plus the ${WEDGE_GRACE}s grace has not passed"; return; }
  _cb="$(heartbeat_epoch)"
  # A missing file is an older lock (unknown, so stale); a present but unreadable one may be a live
  # holder's torn write, so it never counts as stale.
  if [ -z "$_cb" ] && [ -f "$TOKEN_DIR/heartbeat_epoch" ]; then
    echo "heartbeat_epoch is unreadable; a human inspects and clears it"; return
  fi
  if [ -n "$_cb" ] && [ "$_cn" -le $(( _cb + WEDGE_GRACE )) ]; then
    echo "holder is alive (heartbeat $(( _cn - _cb ))s ago, under the ${WEDGE_GRACE}s grace)"; return
  fi
  # An owned lock's ETA does not gate its members, so a silent owner says nothing about a member
  # mid-turn: never clear the lock under a turn the owner could not force either (the same rule:
  # alive until both its ETA and its heartbeat are past the grace; an ended or sid-less turn is not).
  if is_owned && [ -d "$TURN_DIR" ]; then
    _ct="$(turn_sid)"
    if [ -n "$_ct" ]; then
      _cf="$(force_class "$_ct")"
      [ "${_cf%% *}" != "no" ] || echo "a member's turn is alive: ${_cf#* }"
    fi
  fi
}

not_clearable() { echo "NOT-CLEARABLE $*"; exit 1; }

# clear --id <me> --holder <h> [--check]: free a lock whose ETA and last heartbeat are both older
# than WEDGE_GRACE. Compare-and-clear on <h>; never acquires for the caller. The guard runs
# --check first and turns CLEARABLE into a permission prompt; --check changes nothing on disk.
cmd_clear() {
  _id_flag=""; _want=""; _want_set=0; _check=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --id)     [ $# -ge 2 ] || die "clear: --id requires a value"; _id_flag="$2"; shift 2 ;;
      --holder) [ $# -ge 2 ] || die "clear: --holder requires a value"; _want="$2"; _want_set=1; shift 2 ;;
      --check)  _check=1; shift ;;
      *) die "clear: unknown arg: $1" ;;
    esac
  done
  [ -n "$_id_flag" ] && WORKSPACE_LOCK_ID="$_id_flag"   # flag wins over env
  require_id
  [ "$_want_set" = "1" ] || not_clearable "--holder <id> is required (the holder you expect to clear)"
  case "$_want" in ''|*[!A-Za-z0-9._-]*) not_clearable "--holder must match [A-Za-z0-9._-]+" ;; esac
  [ -d "$TOKEN_DIR" ] || not_clearable "no lock at $LOCK_DIR"
  _why="$(clear_refusal "$_want")"
  [ -z "$_why" ] || not_clearable "$_why"
  _now="$(now_epoch)"; _xe="$(lock_eta_epoch)"; _eta_iso="$(epoch_to_iso "$_xe")"
  _hbe="$(heartbeat_epoch)"
  if [ -n "$_hbe" ]; then _hb_txt="$(epoch_to_iso "$_hbe") ($(( (_now - _hbe) / 60 )) min ago)"
  else _hb_txt="unknown"; fi
  if [ "$_check" = "1" ]; then
    # Holder-written free text: keep printable ASCII only (no control, bidi or zero-width chars),
    # drop quotes, cap it, and label it untrusted.
    _task="$(token_meta task | LC_ALL=C tr -cd ' -~' | LC_ALL=C tr -d '"' | cut -c1-80)"
    echo "CLEARABLE Clear the workspace lock at $(prompt_path "$LOCK_DIR")? Holder $_want; ETA $_eta_iso (expired $(( (_now - _xe) / 60 )) min ago); last heartbeat $_hb_txt. Approve only if that holder is dead. Holder-supplied task (untrusted): \"$_task\""
    return 0
  fi
  # Marker first: if it cannot be written, nothing is removed. Then re-check in place right before
  # the removal (the same residual window release accepts), mirror free, token gone.
  _had_marker=0; _old_marker=""
  [ -f "$CLEARED_DIR/$_want" ] && { _had_marker=1; _old_marker="$(cat "$CLEARED_DIR/$_want" 2>/dev/null)"; }
  { mkdir -p "$CLEARED_DIR" && printf '%s %s\n' "$_now" "$WORKSPACE_LOCK_ID" > "$CLEARED_DIR/$_want"; } 2>/dev/null \
    || die "clear: cannot write $CLEARED_DIR/$_want; lock left in place"
  _why="$(clear_refusal "$_want")"
  if [ -n "$_why" ]; then
    if [ "$_had_marker" = "1" ]; then printf '%s\n' "$_old_marker" > "$CLEARED_DIR/$_want" 2>/dev/null
    else rm -f "$CLEARED_DIR/$_want" 2>/dev/null; fi
    not_clearable "$_why (changed during clear)"
  fi
  write_status "$(status_free_json)" || true
  remove_dir "$TOKEN_DIR" || die "clear: failed to remove $TOKEN_DIR"
  log_line "CLEARED $_want (eta $_eta_iso, heartbeat $_hb_txt) by $WORKSPACE_LOCK_ID"
  echo "CLEARED $_want"
}

# --- Owned team verbs ----------------------------------------------------------------------------
# parse_opts <label> "<allowed flags>" <args…>: the shared flag parser of member/turn/owner. Sets
# O_SID O_BY O_TO O_ETA O_ETA_SET O_TASK O_TREE O_FORCE O_CHECK and WORKSPACE_LOCK_ID (--id wins).
parse_opts() {
  _pl="$1"; _pa=" $2 "; shift 2
  O_SID=""; O_BY=""; O_TO=""; O_ETA=""; O_ETA_SET=0; O_TASK=""; O_TREE=""; O_FORCE=0; O_CHECK=0; _pid=""
  while [ $# -gt 0 ]; do
    case "$_pa" in *" $1 "*) : ;; *) die "$_pl: unknown arg: $1" ;; esac
    case "$1" in
      --force) O_FORCE=1; shift; continue ;;
      --check) O_CHECK=1; shift; continue ;;
    esac
    [ $# -ge 2 ] || die "$_pl: $1 requires a value"
    case "$1" in
      --id)   _pid="$2" ;;
      --sid)  O_SID="$2" ;;
      --by)   O_BY="$2" ;;
      --to)   O_TO="$2" ;;
      --task) O_TASK="$2" ;;
      --tree) O_TREE="$2" ;;
      --eta)  O_ETA="$(eta_to_seconds "$2")" || die "invalid --eta: '$2' (use +Nh | +Nm | +Ns | seconds)"; O_ETA_SET=1 ;;
    esac
    shift 2
  done
  [ -n "$_pid" ] && WORKSPACE_LOCK_ID="$_pid"
  require_id
}

# member add|remove --id <slug> --sid <member> --by <owner> · member list --id <slug>
cmd_member() {
  [ $# -ge 1 ] || die "usage: member {add|remove|list} --id <slug> [--sid <member> --by <owner>]"
  _act="$1"; shift
  case "$_act" in
    list)
      parse_opts "member list" "--id" "$@"
      require_owned_lock
      # One line each: "owner <sid>", "member <sid> added=<iso>[ ended=<iso>]", "turn <sid|unknown>".
      echo "owner $(lock_owner)"
      for _mf in "$TOKEN_DIR/members"/*; do
        [ -f "$_mf" ] || continue
        _ms="${_mf##*/}"; _ma="$(num_or_empty "$(head -n1 "$_mf" 2>/dev/null)")"
        _line="member $_ms added=$([ -n "$_ma" ] && epoch_to_iso "$_ma" || echo unknown)"
        if [ -f "$TOKEN_DIR/ended/$_ms" ]; then
          _me=""; read -r _me _ 2>/dev/null < "$TOKEN_DIR/ended/$_ms" || true
          _me="$(num_or_empty "$_me")"
          _line="$_line ended=$([ -n "$_me" ] && epoch_to_iso "$_me" || echo unknown)"
        fi
        echo "$_line"
      done
      if [ -d "$TURN_DIR" ]; then _ts="$(turn_sid)"; echo "turn ${_ts:-unknown}"; fi
      return 0 ;;
    add|remove) ;;
    *) die "member: unknown action: $_act (add | remove | list)" ;;
  esac
  parse_opts "member $_act" "--id --sid --by" "$@"
  require_sid --sid "$O_SID"; require_sid --by "$O_BY"
  require_owned_lock
  [ "$O_BY" = "$(lock_owner)" ] || die "member $_act: only the owner of lock '$WORKSPACE_LOCK_ID' adds or removes members (--by is not the owner)"
  if [ "$_act" = add ]; then
    [ "$O_SID" != "$O_BY" ] || die "member add: the owner is not added as a member; it takes turns as the owner"
    if is_member "$O_SID"; then clear_ended "$O_SID"; echo "MEMBER (already) $O_SID"; return 0; fi
    [ "$(member_count)" -lt "$MAX_MEMBERS" ] || die "member add: lock '$WORKSPACE_LOCK_ID' already has $MAX_MEMBERS members"
    # A plain write inside lock.d/members: if a release removed lock.d meanwhile, it fails, never recreates.
    { printf '%s\n' "$(now_epoch)" > "$TOKEN_DIR/members/$O_SID"; } 2>/dev/null \
      || die "member add: cannot write $TOKEN_DIR/members/$O_SID (was the lock released?)"
    clear_ended "$O_SID"
    log_line "MEMBER-ADDED $(short "$O_SID")"
    echo "MEMBER-ADDED $O_SID"
    return 0
  fi
  [ "$O_SID" != "$O_BY" ] || die "member remove: the owner is not a member; to stop, release the lock"
  # Member file first, then the turn: the reverse order would let this member win a turn between.
  _was=0; is_member "$O_SID" && _was=1
  rm -f "$TOKEN_DIR/members/$O_SID" 2>/dev/null
  clear_ended "$O_SID"
  _freed=0
  # Compare-and-free: the same residual window as release (the holder could give and another
  # member take between the read and the rm; turns are minutes long, so this is accepted).
  if [ -d "$TURN_DIR" ] && [ "$(turn_sid)" = "$O_SID" ]; then
    record_give_or_drop "$O_SID" unknown
    remove_dir "$TURN_DIR"; _freed=1
    log_line "TURN-FREED-ON-REMOVE $(short "$O_SID")"
  fi
  if [ "$_was" = "1" ]; then log_line "MEMBER-REMOVED $(short "$O_SID")"; echo "MEMBER-REMOVED $O_SID"
  elif [ "$_freed" = "1" ]; then echo "NOT-A-MEMBER $O_SID (but it held the turn)"
  else echo "NOT-A-MEMBER $O_SID (nothing to remove)"; fi
  [ "$_freed" = "0" ] || echo "TURN-FREED-ON-REMOVE $O_SID"
  return 0
}

# turn_party_ok <sid>: the lock is still held under this slug, still owned, and <sid> still belongs.
turn_party_ok() {
  [ -d "$TOKEN_DIR" ] && [ "$(token_holder)" = "$WORKSPACE_LOCK_ID" ] && is_owned && is_party "$1"
}

compute_turn_poll() {
  if [ -n "${WORKSPACE_LOCK_TEST_POLL:-}" ]; then echo "$WORKSPACE_LOCK_TEST_POLL"; return; fi
  echo $(( TURN_POLL_BASE + RANDOM % (TURN_POLL_JITTER + 1) ))
}

# The last hand-over, for the session that just took the turn. A give that was not `clean` warns;
# it never refuses (the taker checks git_status and decides whether to resume on top of it).
print_last_give() {
  _lg_e=""; _lg_s=""; _lg_t=""
  read -r _lg_e _lg_s _lg_t 2>/dev/null < "$TOKEN_DIR/last_give" || return 0
  _lg_e="$(num_or_empty "$_lg_e")"; [ -n "$_lg_e" ] || return 0
  _lg_t="$(printf '%s' "$_lg_t" | LC_ALL=C tr -cd 'a-z')"
  echo "LAST-GIVE $(epoch_to_iso "$_lg_e") by $(short "$_lg_s" | LC_ALL=C tr -cd '0-9a-f-') tree ${_lg_t:-unknown}"
  [ "$_lg_t" = "clean" ] || echo "WARN the last turn was given back with tree '${_lg_t:-unknown}': check git_status before you build on it"
}

# turn take --id <slug> --sid <me> --eta +Nm [--task …]   (run in the BACKGROUND)
turn_take() {
  require_sid --sid "$O_SID"
  [ "$O_ETA_SET" = "1" ] || die "turn take: --eta is required (how long this unit of work takes, e.g. +20m)"
  require_owned_lock
  is_party "$O_SID" || die "turn take: '$(short "$O_SID")' is not a member of lock '$WORKSPACE_LOCK_ID'; ask its owner to add you (member add), and only read until then"
  clear_ended "$O_SID"
  trap cleanup_partial INT TERM
  _start="$(now_epoch)"; _say_state=""; _say_at=0; _miss=0
  while : ; do
    # Re-checked on every poll: a waiter whose lock was released or replaced, or who was removed,
    # stops instead of taking a turn in a lock it no longer belongs to.
    turn_party_ok "$O_SID" \
      || die "turn take: lock '$WORKSPACE_LOCK_ID' was released or changed, or '$(short "$O_SID")' is no longer a member; stopped waiting"
    # The marker was cleared when this call started; one that appears now means the session this
    # waiter works for has stopped, so it must not win a turn nobody drives.
    [ ! -f "$TOKEN_DIR/ended/$O_SID" ] \
      || die "turn take: the session '$(short "$O_SID")' ended while waiting; run turn take again if it is back"
    # Plain mkdir inside lock.d (never -p: if lock.d is gone it fails, and the check above stops us).
    # Its status decides nothing: the winner is whoever creates turn.d/sid (noclobber, O_EXCL).
    mkdir "$TURN_DIR" 2>/dev/null
    if ( set -C; printf '%s\n' "$O_SID" > "$TURN_DIR/sid" ) 2>/dev/null; then
      WE_OWN_TURN=1
      if ! { printf '%s\n' $(( $(now_epoch) + O_ETA )) > "$TURN_DIR/eta_epoch" \
             && now_epoch > "$TURN_DIR/heartbeat_epoch" \
             && printf '%s\n' "$O_TASK" > "$TURN_DIR/task" \
             && now_iso > "$TURN_DIR/taken_at"; } 2>/dev/null; then
        [ "$(turn_sid)" != "$O_SID" ] || remove_dir "$TURN_DIR"; WE_OWN_TURN=0
        die "turn take: won the turn but failed to write it; gave it back"
      fi
      # Test-only seam: hold the window between the win and the re-check open (test-turn.sh).
      [ -z "${WORKSPACE_LOCK_TEST_WIN_PAUSE:-}" ] || sleep "$WORKSPACE_LOCK_TEST_WIN_PAUSE"
      # Re-check after the win: a release, a member remove or this session's end may have landed
      # during the claim. A give-back leaves last_give alone: this turn never did any work.
      if ! turn_party_ok "$O_SID" || [ -f "$TOKEN_DIR/ended/$O_SID" ]; then
        # Only if it is still ours: a member remove may already have freed it, and another taken it.
        [ "$(turn_sid)" != "$O_SID" ] || remove_dir "$TURN_DIR"; WE_OWN_TURN=0
        die "turn take: won the turn, but the lock changed, '$(short "$O_SID")' was removed or its session ended; gave it back"
      fi
      # A force or member remove that freed this turn meanwhile: never report a turn held by another.
      if [ "$(turn_sid)" != "$O_SID" ]; then
        WE_OWN_TURN=0
        die "turn take: won the turn, but it was freed before the take finished; run turn take again"
      fi
      WE_OWN_TURN=0
      log_line "TURN-TAKEN $(short "$O_SID")"
      print_last_give
      echo "TURN $O_SID"
      return 0
    fi
    # No sid after a failed claim: not contention (lock.d vanished, or a give landed). Recheck now,
    # but never spin on a create that keeps failing for another reason.
    if [ ! -e "$TURN_DIR/sid" ]; then
      _miss=$((_miss + 1))
      [ "$_miss" -lt 3 ] || die "turn take: cannot create $TURN_DIR"
      continue
    fi
    _miss=0
    _ts="$(turn_sid)"
    if [ -n "$_ts" ] && [ "$_ts" = "$O_SID" ]; then
      # Already ours (a retake after a compaction): refresh the ETA and beat, never self-deadlock.
      { printf '%s\n' $(( $(now_epoch) + O_ETA )) > "$TURN_DIR/eta_epoch"
        now_epoch > "$TURN_DIR/heartbeat_epoch"
        [ -z "$O_TASK" ] || printf '%s\n' "$O_TASK" > "$TURN_DIR/task"; } 2>/dev/null || true
      echo "TURN (already held) $O_SID"
      return 0
    fi
    _elapsed=$(( $(now_epoch) - _start ))
    if [ "$_elapsed" -ge "$MAX_WAIT" ]; then
      log_line "GAVE UP turn take after ${_elapsed}s; turn held by $(short "${_ts:-unknown}")"
      echo "TIMEOUT waited ${_elapsed}s for the turn; held by $(short "${_ts:-unknown}"). Tell the user; don't re-run this take." >&2
      return 2
    fi
    _poll="$(compute_turn_poll)"; _cap=$(( MAX_WAIT - _elapsed ))
    [ "$_poll" -gt "$_cap" ] && _poll="$_cap"; [ "$_poll" -lt 1 ] && _poll=1
    if [ -z "$_ts" ]; then
      say_wait "turn:unknown" "BUSY turn held, holder unknown (a crashed take? the owner can free it with turn give --force); next check in ${_poll}s"
    elif [ "$(force_class "$_ts" | cut -d' ' -f1)" != "no" ]; then
      # Never taken over by a waiter: name the owner's force path, as acquire's WEDGED line does.
      say_wait "turn-stale:$_ts" "WARN turn held by $(short "$_ts") is stale or its session ended; tell the owner (turn give --force --sid <holder> --by <owner>); next check in ${_poll}s"
    else
      _te="$(num_or_empty "$(turn_meta eta_epoch)")"
      say_wait "turn:$_ts" "BUSY turn held by $(short "$_ts") (task: \"$(safe_text "$(turn_meta task)")\", ETA $([ -n "$_te" ] && epoch_to_iso "$_te" || echo unknown)); next check in ${_poll}s"
    fi
    sleep "$_poll"
  done
}

# turn give --id <slug> --sid <me> --tree clean|dirty
turn_give() {
  [ -z "$O_BY" ] && [ "$O_CHECK" = "0" ] || die "turn give: --by and --check go with --force"
  require_sid --sid "$O_SID"
  case "$O_TREE" in
    clean|dirty) ;;
    '') die "turn give: --tree clean|dirty is required: what git_status showed, ignoring .workspace-lock/ and .archive/ (a dirty tree is recorded, never refused)" ;;
    *)  die "turn give: --tree must be clean or dirty (got: '$O_TREE')" ;;
  esac
  require_owned_lock
  [ -d "$TURN_DIR" ] || die "turn give: no turn is held on lock '$WORKSPACE_LOCK_ID' (was it freed? check status)"
  _ts="$(turn_sid)"
  [ "$_ts" = "$O_SID" ] || die "turn give: the turn is held by '$(short "${_ts:-unknown}")', not '$(short "$O_SID")'"
  record_give "$O_SID" "$O_TREE" || die "turn give: could not record the hand-over in $TOKEN_DIR/last_give; the turn is kept"
  remove_dir "$TURN_DIR" || die "turn give: failed to free the turn"
  clear_ended "$O_SID"
  log_line "TURN-GIVEN $(short "$O_SID") tree $O_TREE"
  echo "TURN-GIVEN $O_SID $O_TREE"
}

# force_class <sid>: how the turn named <sid> may be forced free, read-only. Prints one of
#   now <why>   its session ended (a session-end hook wrote ended/<sid>): free at once
#   ask <why>   stale (turn ETA + grace AND turn heartbeat + grace passed) or no sid: after a prompt
#   no <why>    held by someone else, or alive
force_class() {
  _ft="$(turn_sid)"
  if [ -z "$_ft" ]; then echo "ask the turn has no holder recorded (a take that crashed before writing it)"; return; fi
  [ "$_ft" = "$1" ] || { echo "no the turn is held by '$(short "$_ft")', not '$(short "$1")'"; return; }
  if [ -f "$TOKEN_DIR/ended/$_ft" ]; then echo "now the session of '$(short "$_ft")' ended"; return; fi
  _fn="$(now_epoch)"
  _fe="$(num_or_empty "$(turn_meta eta_epoch)")"; _fb="$(num_or_empty "$(turn_meta heartbeat_epoch)")"
  if [ -n "$_fe" ] && [ "$_fn" -le $(( _fe + WEDGE_GRACE )) ]; then
    echo "no the turn's ETA $(epoch_to_iso "$_fe") plus the ${WEDGE_GRACE}s grace has not passed"; return
  fi
  if [ -n "$_fb" ] && [ "$_fn" -le $(( _fb + WEDGE_GRACE )) ]; then
    echo "no the turn holder is alive (turn heartbeat $(( _fn - _fb ))s ago, under the ${WEDGE_GRACE}s grace)"; return
  fi
  echo "ask the turn is past its ETA plus the grace and its heartbeat is stale"
}

# turn give --id <slug> --sid <member> --by <owner> --force [--check]
turn_force() {
  [ -z "$O_TREE" ] || die "turn give --force: --tree does not go with --force (a forced give records 'unknown')"
  require_sid --sid "$O_SID"; require_sid --by "$O_BY"
  require_owned_lock
  [ "$O_BY" = "$(lock_owner)" ] || die "turn give --force: only the owner of lock '$WORKSPACE_LOCK_ID' frees another session's turn (--by is not the owner)"
  # --check output contract (a guard prompts on it): exactly one stdout line, prefix and a space —
  # "FORCEABLE-NOW " (exit 0), "FORCEABLE " (exit 0, prompt) or "NOT-FORCEABLE " (exit 1).
  # Usage errors die on stderr (exit 1), which a guard treats as a failed check. The force itself
  # carries no proof that a prompt was approved: the guard's ask is the only gate, as for clear.
  if [ ! -d "$TURN_DIR" ]; then
    [ "$O_CHECK" = "1" ] && { echo "NOT-FORCEABLE no turn is held on lock '$WORKSPACE_LOCK_ID'"; exit 1; }
    echo "FREE (no turn held)"; return 0
  fi
  _fc="$(force_class "$O_SID")"; _fk="${_fc%% *}"; _fw="${_fc#* }"
  [ "$_fk" != "no" ] || { echo "NOT-FORCEABLE $_fw"; exit 1; }
  if [ "$O_CHECK" = "1" ]; then
    if [ "$_fk" = "now" ]; then
      echo "FORCEABLE-NOW $_fw; its turn on lock '$WORKSPACE_LOCK_ID' can be freed at once"
    else
      _fn="$(now_epoch)"
      _fe="$(num_or_empty "$(turn_meta eta_epoch)")"; _fb="$(num_or_empty "$(turn_meta heartbeat_epoch)")"
      _fe_txt=unknown; [ -n "$_fe" ] && _fe_txt="$(epoch_to_iso "$_fe") ($(( (_fn - _fe) / 60 )) min ago)"
      _fb_txt=unknown; [ -n "$_fb" ] && _fb_txt="$(epoch_to_iso "$_fb") ($(( (_fn - _fb) / 60 )) min ago)"
      echo "FORCEABLE Free the turn on the workspace lock at $(prompt_path "$LOCK_DIR")? Held by session $(short "$(turn_sid)"); ${_fw}; turn ETA $_fe_txt; last turn heartbeat $_fb_txt. Approve only if that session is dead. Holder-supplied task (untrusted): \"$(safe_text "$(turn_meta task)")\""
    fi
    return 0
  fi
  # Re-check right before the removal: the holder may have beaten, given or been replaced since.
  _fc="$(force_class "$O_SID")"
  [ "${_fc%% *}" != "no" ] || { echo "NOT-FORCEABLE ${_fc#* } (changed during the force)"; exit 1; }
  record_give_or_drop "$O_SID" unknown
  remove_dir "$TURN_DIR" || die "turn give --force: failed to remove $TURN_DIR"
  log_line "TURN-FORCED $(short "$O_SID") ($_fw)"
  echo "TURN-FORCED $O_SID"
}

# turn beat --id <slug> --sid <me> [--eta +Nm]
turn_beat() {
  require_sid --sid "$O_SID"
  require_owned_lock
  [ -d "$TURN_DIR" ] || die "turn beat: no turn is held on lock '$WORKSPACE_LOCK_ID' (was it freed? check status)"
  _ts="$(turn_sid)"
  [ "$_ts" = "$O_SID" ] || die "turn beat: the turn is held by '$(short "${_ts:-unknown}")', not '$(short "$O_SID")'"
  clear_ended "$O_SID"
  # Past the turn's ETA only a beat that declares a new ETA retakes it (as heartbeat does for the lock).
  _te="$(num_or_empty "$(turn_meta eta_epoch)")"
  if [ "$O_ETA_SET" = "0" ] && [ -n "$_te" ] && [ "$(now_epoch)" -gt "$_te" ]; then
    die "turn ETA expired at $(epoch_to_iso "$_te"); retake with: \$HOME/.claude/tools/workspace-lock.sh turn beat --id $WORKSPACE_LOCK_ID --sid $O_SID --eta +30m"
  fi
  { now_epoch > "$TURN_DIR/heartbeat_epoch"; } 2>/dev/null || die "turn beat: cannot write the turn (was it freed?)"
  [ "$O_ETA_SET" = "0" ] || { printf '%s\n' $(( $(now_epoch) + O_ETA )) > "$TURN_DIR/eta_epoch"; } 2>/dev/null || true
  echo "TURN-BEAT $O_SID"
}

cmd_turn() {
  [ $# -ge 1 ] || die "usage: turn {take|give|beat} --id <slug> --sid <session id> [flags]"
  _act="$1"; shift
  case "$_act" in
    take) parse_opts "turn take" "--id --sid --eta --task" "$@"; turn_take ;;
    give) parse_opts "turn give" "--id --sid --tree --by --force --check" "$@"
          if [ "$O_FORCE" = "1" ]; then turn_force; else turn_give; fi ;;
    beat) parse_opts "turn beat" "--id --sid --eta" "$@"; turn_beat ;;
    *) die "turn: unknown action: $_act (take | give | beat)" ;;
  esac
}

# transfer_refusal <to>: why ownership may NOT move to <to>; prints nothing when it may. Read-only.
transfer_refusal() {
  _tr_o="$(lock_owner)"
  [ "$1" != "$_tr_o" ] || { echo "'$(short "$1")' is already the owner"; return; }
  ! is_member "$1" || echo "'$(short "$1")' is a member; remove it first (member remove), then transfer"
}

# owner transfer --id <slug> --to <new sid> [--check]: for an owner that lost its session id (only
# /clear makes a new one). The person approves at a prompt (a guard hook asks after --check).
cmd_owner() {
  [ $# -ge 1 ] || die "usage: owner transfer --id <slug> --to <session id> [--check]"
  _act="$1"; shift
  [ "$_act" = "transfer" ] || die "owner: unknown action: $_act (transfer)"
  parse_opts "owner transfer" "--id --to --check" "$@"
  require_sid --to "$O_TO"
  require_owned_lock
  _why="$(transfer_refusal "$O_TO")"
  [ -z "$_why" ] || { echo "NOT-TRANSFERABLE $_why"; exit 1; }
  _old="$(lock_owner)"
  if [ "$O_CHECK" = "1" ]; then
    _now="$(now_epoch)"; _xe="$(lock_eta_epoch)"; _hbe="$(heartbeat_epoch)"
    _xe_txt=unknown; [ -n "$_xe" ] && _xe_txt="$(epoch_to_iso "$_xe")"
    _hb_txt=unknown; [ -n "$_hbe" ] && _hb_txt="$(epoch_to_iso "$_hbe") ($(( (_now - _hbe) / 60 )) min ago)"
    echo "TRANSFERABLE Make session $(short "$O_TO") the owner of the workspace lock at $(prompt_path "$LOCK_DIR")? Current owner $(short "$_old"); lock ETA $_xe_txt; last heartbeat $_hb_txt. Approve only if the current owner has lost its session (for example after /clear)."
    return 0
  fi
  # Write beside it and rename (atomic), after a re-check, so no reader sees a half-written owner.
  _tmp="$TOKEN_DIR/.owner.$$.tmp"
  { printf '%s\n' "$O_TO" > "$_tmp"; } 2>/dev/null || die "owner transfer: cannot write $TOKEN_DIR (was the lock released?)"
  _why="$(transfer_refusal "$O_TO")"
  if [ -n "$_why" ] || [ "$(lock_owner)" != "$_old" ]; then
    rm -f "$_tmp"; echo "NOT-TRANSFERABLE ${_why:-the owner changed during the transfer}"; exit 1
  fi
  mv -f "$_tmp" "$TOKEN_DIR/owner" 2>/dev/null || { rm -f "$_tmp"; die "owner transfer: failed to write the new owner"; }
  # An owner is acting again: refresh the lock's liveness (not its ETA), so clear does not treat
  # the lock as dead under its new owner. The old owner's end marker no longer means anything.
  now_epoch > "$TOKEN_DIR/heartbeat_epoch" 2>/dev/null || true
  clear_ended "$_old"
  log_line "OWNER-TRANSFERRED $(short "$_old") -> $(short "$O_TO")"
  echo "OWNER-TRANSFERRED $O_TO"
}

[ $# -ge 1 ] || die "usage: workspace-lock.sh {acquire|release|status|heartbeat|clear|member|turn|owner} [--id <slug>] [flags]"
_sub="$1"; shift
case "$_sub" in
  acquire)   cmd_acquire "$@" ;;
  release)   cmd_release "$@" ;;
  status)    cmd_status "$@" ;;
  heartbeat) cmd_heartbeat "$@" ;;
  clear)     cmd_clear "$@" ;;
  member)    cmd_member "$@" ;;
  turn)      cmd_turn "$@" ;;
  owner)     cmd_owner "$@" ;;
  *) die "unknown subcommand: $_sub" ;;
esac
