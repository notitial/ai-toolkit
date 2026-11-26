#!/bin/sh
# Claude process wrapper: the VS Code extension runs `claudeProcessWrapper <claude binary> <args...>` for every Claude
# process it starts. Why: an account window (code-<name>, tools/accounts.zsh) runs on a token whose organization may
# disable Remote Control, and the extension then shows an error banner on every start. A `--settings` flag outranks the
# user's settings, so this adds {"remoteControlAtStartup":false} to the chat process of that window only.
# Matches: the argument pair `--input-format stream-json` (the chat process; the short helper calls such as
# `auth status` lack it), and only when AIT_RC_OFF=1 (set by code-<name>). Every other call execs unchanged, so with no
# marker the script is a pure pass-through.
# Never adds a second --settings (the CLI keeps one value): an existing JSON one gets the key spliced in, an existing
# file path is left alone. Fails soft: anything not understood passes through unchanged and still execs.
# Setup (user step, machine scope): tools/README.md, "claude-wrapper". Tests: bash tools/claude-wrapper/test-claude-wrapper.sh
bin=$1
shift
if [ "${AIT_RC_OFF:-}" = 1 ]; then
  case " $* " in
  *" --input-format stream-json "*)
    n=$#
    seen=0
    while [ "$n" -gt 0 ]; do
      a=$1
      shift
      n=$((n - 1))
      if [ "$a" = --settings ] && [ "$n" -gt 0 ]; then
        v=$1
        shift
        n=$((n - 1))
        case $v in
          '{}') v='{"remoteControlAtStartup":false}' ;;
          '{'*) v="{\"remoteControlAtStartup\":false,${v#\{}" ;;
        esac
        seen=1
        set -- "$@" --settings "$v"
      else
        set -- "$@" "$a"
      fi
    done
    [ "$seen" = 1 ] || set -- --settings '{"remoteControlAtStartup":false}' "$@"
    ;;
  esac
fi
exec "$bin" "$@"
