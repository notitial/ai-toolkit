#!/bin/bash
# Session-end hook: tells an owned workspace lock that a session's process has stopped. Configured in
# ~/.claude/settings.json for SessionEnd (no matcher). SessionEnd cannot block, so it only records.
#
# What it does, for the lock found from the hook input's cwd (rules below; the session is S):
#   - S holds the turn of an owned lock: write ended/<S>, record last_give "<epoch> <S> unknown", remove
#     turn.d (log TURN-FREED-ON-END). The process is gone, so the turn is free whatever the reason.
#   - S is a member of an owned lock: write ended/<S> and KEEP members/<S>. Every stop but /clear
#     (resume, prompt_input_exit, a reload or a closed tab) can come back with the same session id, and a
#     removed member would return as a stranger. The lock script clears ended/<S> on that session's next
#     lock call, and `turn give --force` frees a turn whose holder has an ended/ marker at once.
#   - S is the owner: the lock stays (members may be mid-unit); log OWNER-ENDED.
#   - then remove sessions/<S> (a guard registration) when there is one.
# A session that is none of these (the panel's throwaway sessions, any session in an open lock) gets nothing
# written. A workspace with no lock.d (free or released) is left alone: nothing here ever creates a
# folder, so a release racing this hook cannot be undone by it.
#
# Which lock: WORKSPACE_LOCK_DIR (absolute, when the cwd is inside its workspace), else the nearest
# .workspace-lock/ up from the cwd that holds lock.d/. This is its own copy of the walk-up in
# hooks/workspace-lock-guard.sh (resolve_lock_dir), kept separate on purpose: hooks are linked one file at a
# time into ~/.claude/hooks/, so a shared library would not be installed beside them. Change both together;
# tools/workspace-lock/test-session-end.sh checks they land on the same lock. Owned locks refuse --repos, so
# the guard's --repos branch is not copied. One deliberate difference: with WORKSPACE_LOCK_DIR set, a cwd outside
# its workspace falls back to that lock when the walk up finds none.
#
# Never blocks, always exits 0 (no set -e). Reads JSON on stdin; without jq or on bad input it does nothing.
# bash 3.2.

set -f

now_epoch() { date -u +%s; }
short() { printf '%s' "$1" | cut -c1-8; }

# A session id is a lowercase UUID, which is also what the lock script accepts and keeps safe as a file name.
_H='[0123456789abcdef]'
SID_GLOB="$_H$_H$_H$_H$_H$_H$_H$_H-$_H$_H$_H$_H-$_H$_H$_H$_H-$_H$_H$_H$_H-$_H$_H$_H$_H$_H$_H$_H$_H$_H$_H$_H$_H"
valid_sid() {
  # shellcheck disable=SC2254  # SID_GLOB is a pattern on purpose
  case "$1" in $SID_GLOB) return 0 ;; *) return 1 ;; esac
}

under_archive() {
  _p="$1"
  while [ "$_p" != "/" ] && [ -n "$_p" ]; do
    [ -e "$_p/.git" ] && return 1
    case "$_p" in */.archive) return 0 ;; esac
    _p=$(dirname "$_p")
  done
  return 1
}
walk_up() {
  _d="$1"
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    if [ -d "$_d/.workspace-lock/lock.d" ] && ! under_archive "$_d"; then
      printf '%s' "$_d/.workspace-lock"; return 0
    fi
    _d=$(dirname "$_d")
  done
  return 0
}
resolve_lock_dir() {
  case "${WORKSPACE_LOCK_DIR:-}" in
    /*)
      _ews=$(dirname "$WORKSPACE_LOCK_DIR")
      case "$1" in "$_ews"|"$_ews"/*) printf '%s' "$WORKSPACE_LOCK_DIR"; return 0 ;; esac
      # Unlike the guard, a cwd outside the workspace still finds it: a member that ends in another folder
      # (a clone) must not leave its turn held. Only reached when the walk up finds no lock of its own.
      _w=$(walk_up "$1")
      if [ -n "$_w" ]; then printf '%s' "$_w"; elif [ -d "$WORKSPACE_LOCK_DIR/lock.d" ]; then printf '%s' "$WORKSPACE_LOCK_DIR"; fi
      return 0 ;;
  esac
  walk_up "$1"
}

log_line() {  # never creates the lock folder
  printf '%s  workspace-lock-session-end  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOCK_DIR/workspace-lock.log" 2>/dev/null
  return 0
}

# Same rename-then-delete as the lock script: the removal never touches a directory made after the rename.
remove_dir() {
  [ -d "$1" ] || return 0
  _rd="$1.gone.$$.$RANDOM"
  mv "$1" "$_rd" 2>/dev/null || return 1
  rm -rf "$_rd"
}

# write_marker <file> <text>: temp file in the same folder, then rename; fails quietly if the folder is gone.
write_marker() {
  _wt="$(dirname "$1")/.$(basename "$1").$$.tmp"
  { printf '%s\n' "$2" > "$_wt" && mv -f "$_wt" "$1"; } 2>/dev/null && return 0
  rm -f "$_wt" 2>/dev/null
  return 1
}

main() {
  command -v jq >/dev/null 2>&1 || { echo "workspace-lock-session-end: jq unavailable; nothing recorded" >&2; return 0; }
  INPUT=$(cat)
  printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || return 0
  SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty | strings')
  CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty | strings')
  REASON=$(printf '%s' "$INPUT" | jq -r '.reason // empty | strings' | LC_ALL=C tr -cd 'A-Za-z0-9_-' | cut -c1-24)
  [ -n "$REASON" ] || REASON=unknown
  valid_sid "$SID" || return 0
  case "$CWD" in /*) : ;; *) return 0 ;; esac

  LOCK_DIR=$(resolve_lock_dir "$CWD")
  [ -n "$LOCK_DIR" ] || return 0
  TOKEN="$LOCK_DIR/lock.d"
  [ -d "$TOKEN" ] || return 0

  if [ "$(head -n1 "$TOKEN/kind" 2>/dev/null)" = "owned" ]; then
    OWNER=$(head -n1 "$TOKEN/owner" 2>/dev/null)
    TURN="$TOKEN/turn.d"
    HELD_TURN=0
    [ -d "$TURN" ] && [ "$(head -n1 "$TURN/sid" 2>/dev/null)" = "$SID" ] && HELD_TURN=1
    IS_MEMBER=0
    [ -f "$TOKEN/members/$SID" ] && IS_MEMBER=1

    if [ "$HELD_TURN" = 1 ]; then
      # Free the turn BEFORE writing ended/<S>: that marker makes the turn forceable at once, so writing it first
      # would open a window for a force plus a new take, and this rename would then remove the new holder's turn.
      # Record last_give before freeing, as the script does, and re-read the holder before each step.
      if [ "$(head -n1 "$TURN/sid" 2>/dev/null)" != "$SID" ]; then
        :
      elif write_marker "$TOKEN/last_give" "$(now_epoch) $SID unknown"; then
        [ "$(head -n1 "$TURN/sid" 2>/dev/null)" = "$SID" ] && remove_dir "$TURN" && log_line "TURN-FREED-ON-END $(short "$SID") ($REASON)"
      else
        # Leave the turn in place rather than free it behind a stale last_give; ended/<S> (below) lets the owner force it.
        log_line "TURN-KEPT-ON-END $(short "$SID") ($REASON): could not record last_give"
      fi
    elif [ "$IS_MEMBER" = 1 ]; then
      log_line "MEMBER-ENDED $(short "$SID") ($REASON)"
    fi
    if { [ "$HELD_TURN" = 1 ] || [ "$IS_MEMBER" = 1 ]; } && [ -d "$TOKEN/ended" ]; then
      write_marker "$TOKEN/ended/$SID" "$(now_epoch) $REASON"
    fi
    if [ -n "$OWNER" ] && [ "$SID" = "$OWNER" ]; then
      log_line "OWNER-ENDED $(short "$SID") ($REASON)"
    fi
  fi

  [ -f "$LOCK_DIR/sessions/$SID" ] && rm -f "$LOCK_DIR/sessions/$SID" 2>/dev/null
  return 0
}

main
exit 0
