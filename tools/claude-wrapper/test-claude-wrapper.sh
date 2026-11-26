#!/bin/bash
# Tests for tools/claude-wrapper/claude-wrapper.sh (WRAPPER=<path> tests another copy). Run: bash tools/claude-wrapper/test-claude-wrapper.sh
# The wrapper runs under WRAPPER_SH (default /bin/sh) against a fake binary that prints its argv, one `arg=` line each,
# and its stdin. Each case compares the whole output with the wanted argv.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WRAPPER="${WRAPPER:-$HERE/claude-wrapper.sh}"
SH="${WRAPPER_SH:-/bin/sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/claude-wrapper-XXXXXX")
trap 'rm -rf "$T"' EXIT
cat > "$T/fake" <<'EOF'
#!/bin/sh
for a in "$@"; do echo "arg=$a"; done
echo "stdin=$(cat)"
EOF
chmod 755 "$T/fake"
PASS=0
FAIL=0

# check <label> <AIT_RC_OFF value: unset|empty|<value>> <wanted argv, one per line> <args...>
check() {
  local label=$1 marker=$2 want=$3 got
  shift 3
  case $marker in
    unset) got=$(echo hello | env -u AIT_RC_OFF "$SH" "$WRAPPER" "$T/fake" "$@") ;;
    empty) got=$(echo hello | AIT_RC_OFF= "$SH" "$WRAPPER" "$T/fake" "$@") ;;
    *) got=$(echo hello | AIT_RC_OFF=$marker "$SH" "$WRAPPER" "$T/fake" "$@") ;;
  esac
  if [ -n "$want" ]; then want="$want"$'\n'stdin=hello; else want=stdin=hello; fi
  if [ "$got" = "$want" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$label" "$want" "$got"; fi
}

RC='{"remoteControlAtStartup":false}'
CHAT=(--output-format stream-json --verbose --input-format stream-json --permission-mode default)
CHAT_ARGV=$'arg=--output-format\narg=stream-json\narg=--verbose\narg=--input-format\narg=stream-json\narg=--permission-mode\narg=default'

check "marker absent: chat argv identical" unset "$CHAT_ARGV" "${CHAT[@]}"
check "marker absent: --settings left as it is" unset "$(printf 'arg=--settings\narg={}\n%s' "$CHAT_ARGV")" --settings '{}' "${CHAT[@]}"
check "marker set: helper subcommand identical" 1 $'arg=auth\narg=status\narg=--json' auth status --json
check "marker set: helper with setting sources identical" 1 $'arg=--setting-sources\narg=user workspace-trust\narg=--json' --setting-sources 'user workspace-trust' --json
check "marker set: no arguments" 1 ""
check "marker set: a lone --input-format is not the chat pair" 1 $'arg=--input-format\narg=text' --input-format text
check "marker 0: identical" 0 "$CHAT_ARGV" "${CHAT[@]}"
check "marker empty: identical" empty "$CHAT_ARGV" "${CHAT[@]}"
check "marker true: identical" true "$CHAT_ARGV" "${CHAT[@]}"
check "marker set: chat gets --settings first" 1 "$(printf 'arg=--settings\narg=%s\n%s' "$RC" "$CHAT_ARGV")" "${CHAT[@]}"
check "marker set: JSON --settings spliced, one flag, space kept" 1 \
  "$(printf 'arg=--output-format\narg=stream-json\narg=--verbose\narg=--input-format\narg=stream-json\narg=--settings\narg={"remoteControlAtStartup":false,"deniedMcpServers":[{"serverName":"my server"}]}\narg=--permission-mode\narg=default')" \
  --output-format stream-json --verbose --input-format stream-json --settings '{"deniedMcpServers":[{"serverName":"my server"}]}' --permission-mode default
check "marker set: {} replaced" 1 \
  "$(printf 'arg=--input-format\narg=stream-json\narg=--settings\narg=%s' "$RC")" --input-format stream-json --settings '{}'
check "marker set: file-path --settings left alone, none added" 1 \
  $'arg=--input-format\narg=stream-json\narg=--settings\narg=/some dir/s.json' --input-format stream-json --settings '/some dir/s.json'
check "marker set: a trailing --settings with no value is not a flag" 1 \
  "$(printf 'arg=--settings\narg=%s\narg=--input-format\narg=stream-json\narg=--settings' "$RC")" --input-format stream-json --settings
check "marker set: other arguments keep spaces and empties" 1 \
  "$(printf 'arg=--settings\narg=%s\narg=--input-format\narg=stream-json\narg=two  words\narg=' "$RC")" --input-format stream-json 'two  words' ''

# stdin and the exit status come through: the wrapper execs the binary.
printf '#!/bin/sh\nexit 7\n' > "$T/exit7"; chmod 755 "$T/exit7"
AIT_RC_OFF=1 "$SH" "$WRAPPER" "$T/exit7" --input-format stream-json
if [ $? -eq 7 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: exit status of the binary is not passed on"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
