#!/usr/bin/env bash
# workspace-lock.sh — advisory lock serializing the mutating work of independent sessions on a
# shared working copy. PURE lock mechanism: no git, no network (git is done by the caller via MCP).
#
# On-disk layout — one dot-prefixed folder (created on first acquire):
#   $WORKSPACE_LOCK_DIR/          must be ABSOLUTE when set via env (default: $PWD/.workspace-lock)
#     status.json                    persistent display MIRROR: {"state":"free"} | {"state":"locked",…}
#     lock.d/                        the atomic mutex (mkdir/rmdir) — AUTHORITATIVE for held/free
#     lock.d/holder                  the AUTHORITATIVE holder id (written before the mirror)
#     lock.d/{eta_epoch,phase,task,reason,repos,acquired_at}   token metadata — lets heartbeat
#                                    rebuild the mirror after a race/crash stamps it free
#     lock.d/heartbeat_epoch         last acquire/heartbeat (epoch) — the liveness half of `clear`
#     cleared/<id>                   "<epoch> <by-id>": <id>'s lock was cleared; its next lock call
#                                    fails loudly until a successful release
#     workspace-lock.log          durable give-up/refuse/wedge/clear log
#
# The mutex is `lock.d` (atomic `mkdir`); the holder id lives in `lock.d/holder`. `release` and
# `heartbeat` authenticate against `lock.d/holder` — NEVER `status.json` — and refuse on an unknown
# or mismatched holder. `status.json` is a display MIRROR only: every acquire gates on `lock.d`,
# never on the flag, so it can never cause a double-acquire. `status` is read-only and reconciles
# the reported state from `lock.d` (present → held, absent → free).
#
# See docs/adr/0012-overnight-orchestrator-lock.md.
# Canonical install (via /setup-claude): ~/.claude/tools/workspace-lock.sh — invoke as
#   $HOME/.claude/tools/workspace-lock.sh <sub> …   (allowlist Bash($HOME/.claude/tools/workspace-lock.sh *))
#
# Subcommands: acquire | release | status | heartbeat | clear   (run `acquire` in the BACKGROUND)
# Expiry (ADR 0012): once the ETA passes, the guard denies the holder's own
#   mutations until it retakes with `heartbeat --eta <new>` (a bare heartbeat is refused). Once
#   WEDGE_GRACE has passed since BOTH the ETA and the last heartbeat, another interactive session
#   may `clear --id <me> --holder <h>` — the guard asks the user first.
# Identity: `--id <slug>` on acquire/release/heartbeat, or env WORKSPACE_LOCK_ID (flag wins if both
#   set). Never use the inline `VAR=x <script>` prefix form — it defeats the Bash allowlist match.
# Config (env): WORKSPACE_LOCK_DIR (absolute), WORKSPACE_LOCK_MAX_WAIT, WORKSPACE_LOCK_INIT_LEASE,
#   WORKSPACE_LOCK_WEDGE_GRACE, WORKSPACE_LOCK_LOG, WORKSPACE_LOCK_TEST_POLL.
# Exit: 0 ok · 1 usage/precondition · 2 acquire timed out.
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
LOCK_LOG="${WORKSPACE_LOCK_LOG:-$LOCK_DIR/workspace-lock.log}"
MAX_WAIT="${WORKSPACE_LOCK_MAX_WAIT:-28800}"
INIT_LEASE="${WORKSPACE_LOCK_INIT_LEASE:-1800}"
# The one grace: a waiter's WEDGED warning, and `clear` (past ETA + grace AND heartbeat + grace).
WEDGE_GRACE="${WORKSPACE_LOCK_WEDGE_GRACE:-1800}"
POLL_BASE=30        # seconds between a waiter's rechecks of a held lock
POLL_JITTER=5       # plus 0..N seconds, so two waiters do not recheck in lockstep
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
WE_OWN_UNWRITTEN=0
cleanup_partial() { [ "$WE_OWN_UNWRITTEN" = "1" ] && rm -rf "$TOKEN_DIR"; exit 130; }

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
  _after_clear=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --after-clear) _after_clear=1; shift ;;
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
  [ -n "$_eta_secs" ] || _eta_secs="$INIT_LEASE"
  # A cleared id never gets back in silently: it must say --after-clear (once the user agrees).
  # A reentrant hold (this id holds lock.d again, e.g. after an earlier --after-clear) passes.
  if [ "$_after_clear" = "0" ] && [ "$(token_holder)" != "$WORKSPACE_LOCK_ID" ] \
     && _cm="$(cleared_msg "$WORKSPACE_LOCK_ID")"; then
    die "$_cm; re-acquire with --after-clear once the user agrees"
  fi
  mkdir -p "$LOCK_DIR" 2>/dev/null || die "cannot create $LOCK_DIR"
  _start="$(now_epoch)"
  _wedge_logged=0; _say_state=""; _say_at=0
  while : ; do
    if mkdir "$TOKEN_DIR" 2>/dev/null; then          # atomic — exactly one racer wins
      WE_OWN_UNWRITTEN=1
      # Write the AUTHORITATIVE holder id inside the token FIRST — before the mirror — so a
      # concurrent release/heartbeat authenticates against real ownership, never a stale mirror.
      if ! printf '%s\n' "$WORKSPACE_LOCK_ID" > "$TOKEN_DIR/holder" 2>/dev/null; then
        rm -rf "$TOKEN_DIR"; WE_OWN_UNWRITTEN=0
        die "acquired lock but failed to write holder token; released it"
      fi
      H_ETA_EPOCH=$(( $(now_epoch) + _eta_secs ))
      H_ACQUIRED_AT="$(now_iso)"
      H_REPOS_JSON="$(repos_json "$H_REPOS")"
      if ! token_write_meta 2>/dev/null; then
        rm -rf "$TOKEN_DIR"; WE_OWN_UNWRITTEN=0
        die "acquired lock but failed to write token metadata; released it"
      fi
      if write_status "$(status_locked_json)"; then
        WE_OWN_UNWRITTEN=0
        echo "ACQUIRED $WORKSPACE_LOCK_ID $LOCK_DIR"
        return 0
      fi
      rm -rf "$TOKEN_DIR"; WE_OWN_UNWRITTEN=0        # partial-failure cleanup (the only "trap")
      die "acquired lock but failed to write status.json; released it"
    fi
    _held="$(token_holder)"
    if [ -n "$_held" ] && [ "$_held" = "$WORKSPACE_LOCK_ID" ]; then
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

cmd_release() {
  _id_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) [ $# -ge 2 ] || die "release: --id requires a value"; _id_flag="$2"; shift 2 ;;
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
  # Mirror first, then token: if a racer wins lock.d the instant the rm lands, it immediately
  # re-stamps the mirror locked — this order can never leave a held lock displayed as free.
  write_status "$(status_free_json)" || true
  rm -rf "$TOKEN_DIR"                               # authoritative release
  rm -f "$CLEARED_DIR/$WORKSPACE_LOCK_ID" 2>/dev/null   # a normal end closes an earlier --after-clear
  echo "RELEASED $WORKSPACE_LOCK_ID"
}

cmd_status() {
  # Read-only: the state is reconciled from the authoritative token; nothing is created or written.
  if [ -d "$TOKEN_DIR" ]; then
    if [ -f "$STATUS_FILE" ] && [ "$(json_get state "$STATUS_FILE" 2>/dev/null || echo)" = "locked" ]; then
      cat "$STATUS_FILE"
    else                                            # token held but mirror stale/missing
      _h="$(token_holder)"
      printf '{\n  "state": "locked",\n  "holder_id": "%s",\n  "note": "mirror unavailable"\n}\n' "$(sanitize "${_h:-unknown}")"
    fi
  else
    status_free_json; echo
  fi
}

cmd_heartbeat() {
  _new_eta=""; _phase=""; _id_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
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
  # Past its ETA the lock is re-armed: only a heartbeat that declares a new ETA retakes it. A bare
  # beat would refresh liveness forever without ever revising the estimate a waiter reads.
  if [ -z "$_new_eta" ] && lock_expired 0; then
    die "ETA expired at $(epoch_to_iso "$(lock_eta_epoch)"); retake with: \$HOME/.claude/tools/workspace-lock.sh heartbeat --id $WORKSPACE_LOCK_ID --eta +30m"
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
    echo "holder is alive (heartbeat $(( _cn - _cb ))s ago, under the ${WEDGE_GRACE}s grace)"
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
    echo "CLEARABLE Clear the workspace lock at $LOCK_DIR? Holder $_want; ETA $_eta_iso (expired $(( (_now - _xe) / 60 )) min ago); last heartbeat $_hb_txt. Approve only if that holder is dead. Holder-supplied task (untrusted): \"$_task\""
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
  rm -rf "$TOKEN_DIR"
  [ ! -d "$TOKEN_DIR" ] || die "clear: failed to remove $TOKEN_DIR"
  log_line "CLEARED $_want (eta $_eta_iso, heartbeat $_hb_txt) by $WORKSPACE_LOCK_ID"
  echo "CLEARED $_want"
}

[ $# -ge 1 ] || die "usage: workspace-lock.sh {acquire|release|status|heartbeat|clear} [--id <slug>] [flags]"
_sub="$1"; shift
case "$_sub" in
  acquire)   cmd_acquire "$@" ;;
  release)   cmd_release "$@" ;;
  status)    cmd_status "$@" ;;
  heartbeat) cmd_heartbeat "$@" ;;
  clear)     cmd_clear "$@" ;;
  *) die "unknown subcommand: $_sub" ;;
esac
