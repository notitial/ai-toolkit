#!/bin/bash
# SessionStart hook (matcher "startup|resume"): re-apply the session's own name, so a session restored after a
# VS Code restart or update is listed under it again.
#
# Why: a session reopened from the VS Code extension's chat list keeps its id and its title (/status still shows
# the name), but the agent list (the ListAgents tool) can show it under an auto-generated name until /rename is run
# again, and other sessions cannot message it by name until then. Running /rename with the same name in the restored
# session fixes that, and a hook's sessionTitle has the same effect as /rename (hooks docs, SessionStart decision
# control).
#
# What it prints: the session's own name as hookSpecificOutput.sessionTitle, taken from the input's session_title
# (set when the session has a custom title: -n/--name, /rename or a hook). On a resume with no session_title, the
# last top-level {"type":"custom-title"} record in the last 4 MB of transcript_path stands in (both -n and /rename
# append those), then the session's custom-title.json. Nothing otherwise. It never sets a name the session did not
# already have. Fork (including --resume --fork-session, per the docs' matcher table) is not matched: a copy keeps
# no claim to the original's name.
#
# Fail-open: no set -e, every path exits 0, and no output means no change. bash 3.2.

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null) || exit 0
field() { printf '%s' "$input" | jq -r "if type == \"object\" then (.$1 // empty) | strings else empty end" 2>/dev/null; }
src=$(field source)
case $src in startup|resume) ;; *) exit 0 ;; esac
title=$(field session_title)

if [ -z "$title" ] && [ "$src" = resume ]; then
  tp=$(field transcript_path)
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    # Only a top-level {"type":"custom-title"} record counts, never a customTitle key nested in a tool result or
    # quoted in a message; fromjson? drops the partial first line the byte window cuts.
    title=$(tail -c 4194304 "$tp" 2>/dev/null | LC_ALL=C grep -aF '"custom-title"' 2>/dev/null |
      jq -Rr 'fromjson? | select(type == "object" and .type == "custom-title") | .customTitle | strings
        | select(length > 0)' 2>/dev/null | tail -n 1)
    # Claude Code re-appends the record as the session runs, so the window normally holds one; past it, the
    # <session>/custom-title.json a /rename leaves beside the transcript.
    if [ -z "$title" ]; then
      sid=$(field session_id)
      case $sid in '' | */* | .*) ;; *)
        title=$(jq -r 'if type == "object" then (.customTitle // empty) | strings else empty end' \
          "${tp%/*}/$sid/custom-title.json" 2>/dev/null) ;;
      esac
    fi
  fi
fi

[ -n "$title" ] || exit 0
jq -nc --arg t "$title" '{hookSpecificOutput: {hookEventName: "SessionStart", sessionTitle: $t}}' 2>/dev/null
exit 0
