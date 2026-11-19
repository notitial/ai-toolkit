#!/usr/bin/env bash
# One `claude -p` session for the review command: the single place the review's flags live. The workflow's `review` job
# and replay/replay.py both run this file. Usage: run.sh <prompt> <checkout> <context> [more claude arguments]
#
# Run it from a folder that holds nothing the PR wrote: the working folder is the only place Claude loads CLAUDE.md,
# settings and agents from, so the kit's own reviewer folder (CLAUDE.md here) is the whole configuration. The PR's
# checkout and the context folder are NOT passed with --add-dir: a folder added that way contributes its .claude/agents
# and skills, so a PR could replace the subagents' instructions. Allow rules let Claude read them as data and nothing else
# (plus the command, which sits beside this file; a symlink out of them is refused too: the CLI checks the resolved path, and Grep does not follow links). The tools are the ones in --tools and nothing can post: no shell, no web, no
# writes, no MCP. --permission-mode dontAsk refuses everything not allowed (`default` is no longer listed by the CLI).
# Stdout is the stream-json transcript: the caller writes it to a file, never to the log.
set -eu
prompt=$1 checkout=$2 context=$3
shift 3
here=$(cd "$(dirname "$0")" && pwd)
allow="Agent,Task,Read(/$here/claude-pr-review.md)"
for dir in "$checkout" "$context"; do allow="$allow,Read(/$dir/**),Grep(/$dir/**),Glob(/$dir/**)"; done
exec claude -p "$prompt" --output-format stream-json --verbose --no-session-persistence --strict-mcp-config \
  --permission-mode dontAsk --setting-sources project --settings '{"disableAllHooks":true}' \
  --tools "Read,Grep,Glob,Agent" --allowedTools "$allow" \
  --disallowedTools "Bash,WebFetch,WebSearch,Write,Edit,NotebookEdit,Read(/$checkout/.git/**),Grep(/$checkout/.git/**),Glob(/$checkout/.git/**)" \
  --json-schema "$(cat "$(dirname "$0")/result-schema.json")" "$@"
