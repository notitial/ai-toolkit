#!/bin/bash
# Pre-tool-use hook: blocks Bash/Write/Edit/MultiEdit/NotebookEdit/git_commit calls that carry a secret, read or
# write a .env file, search recursively over a tree that holds .env files, or (Bash only) print a macOS Keychain
# secret (see keychain_read below).
# Configured in ~/.claude/settings.json for PreToolUse on Bash|Write|Edit|MultiEdit|NotebookEdit|mcp__git-mcp__git_commit.
#
# Reads JSON from stdin and prints a deny decision, or nothing to allow. Exit 0 always.

set -uo pipefail

# Audit row for a fail-closed deny. The input may be unreadable, so the row carries none of it: only the cwd
# and the tool name when jq can read them.
audit_unscannable() {
  local logger cwd tool
  command -v jq >/dev/null 2>&1 || return 0
  logger="$(dirname "${BASH_SOURCE[0]}")/audit-logger.sh"
  [ -r "$logger" ] || return 0
  cwd=$(printf '%s' "${INPUT:-}" | jq -r '(.cwd | strings | select(startswith("/"))) // empty' 2>/dev/null || true)
  tool=$(printf '%s' "${INPUT:-}" | jq -r '(.tool_name | strings | select(test("^[A-Za-z0-9_-]+$")) | .[0:64]) // empty' 2>/dev/null || true)
  jq -nc --arg c "${cwd:-$PWD}" --arg t "${tool:-unknown}" --arg r "unscannable input blocked (fail-closed)" --arg h "secret-detector" \
    '{cwd: $c, tool_name: $t, _audit_event: "deny", _deny_reason: $r, _deny_hook: $h}' 2>/dev/null \
    | bash "$logger" >/dev/null 2>&1 || true
}

# Without jq, or with input that is not a JSON object, nothing can be scanned: deny.
deny_unscannable() {
  audit_unscannable
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"secret-detector: jq unavailable or the input is not a JSON object - secret scanning blocked (fail-closed). Install jq or ask the user to review the content manually."}}'
  exit 0
}
command -v jq >/dev/null 2>&1 || deny_unscannable

INPUT=$(cat) || true
case $INPUT in
  *[![:space:]]*) printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || deny_unscannable ;;
esac

# grep -q quits at the first match and the writer upstream gets SIGPIPE, which pipefail would report as
# "no match". Return grep's own status instead.
match_in() {  # match_in <grep flags> <pattern> <text>
  printf '%s\n' "$3" | grep "$1" -- "$2"
  return "${PIPESTATUS[1]}"
}

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

# The text to scan, and the file written, per tool.
CONTENT=""
FILE_PATH=""
field() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || true; }
case "$TOOL_NAME" in
  Bash)         CONTENT=$(field '.tool_input.command // empty') ;;
  Write)        CONTENT=$(field '.tool_input.content // empty');    FILE_PATH=$(field '.tool_input.file_path // empty') ;;
  Edit)         CONTENT=$(field '.tool_input.new_string // empty'); FILE_PATH=$(field '.tool_input.file_path // empty') ;;
  NotebookEdit) CONTENT=$(field '.tool_input.new_source // empty'); FILE_PATH=$(field '.tool_input.notebook_path // empty') ;;
  MultiEdit)
    CONTENT=$(field '[.tool_input.edits[]? | .new_string? | strings] | join("\n")')
    FILE_PATH=$(field '.tool_input.file_path // empty')
    ;;
  mcp__git-mcp__git_commit) CONTENT=$(field '.tool_input.message // empty') ;;
  *) exit 0 ;;
esac

# Nothing to scan. An empty write to a .env file still has a path, so it reaches the path check below.
if [ -z "$CONTENT" ] && [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Best-effort record of a deny in the audit log; never blocks this hook.
audit_deny() {
  local logger
  logger="$(dirname "${BASH_SOURCE[0]}")/audit-logger.sh"
  [ -r "$logger" ] || return 0
  printf '%s' "$INPUT" \
    | jq -c --arg r "$1" --arg h "secret-detector" \
        '. + {_audit_event:"deny",_deny_reason:$r,_deny_hook:$h}' 2>/dev/null \
    | bash "$logger" >/dev/null 2>&1 || true
}

deny() {  # deny <audit reason> <reason shown to the agent>
  audit_deny "$1"
  jq -n --arg r "$2" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# Secret patterns (extended regex, POSIX classes). Keep in step with audit-logger.sh's redact() set.
JWT_PATTERN='(^|[^a-zA-Z0-9_-])eyJ[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'

# The short key prefixes (sk-, sk_live_, rk_live_, sk-ant-) need a minimum run of contiguous letters and digits
# after the prefix. A real key body is one long unbroken run; prose such as task-id or risk-owner is words joined
# by - or _, so it does not match. The leading ${_K}* lets the run sit past a separator inside the key. The one
# prefix that matches on its own is split into two strings, so this file holds no key-shaped text.
_A='[A-Za-z0-9]'                              # key-body char (alphanumeric, no separators)
_K='[A-Za-z0-9_-]'                            # full key charset incl. - and _

SECRET_PATTERNS=(
  'AKIA[0-9A-Z]{16}'                            # AWS access key ID (16 chars after AKIA)
  'ASIA[0-9A-Z]{16}'                            # AWS temporary access key (16 chars after ASIA)
  "sk-""ant-${_K}*${_A}{16,}"                   # Anthropic secret key (>=16 contiguous alnum body)
  "sk-${_K}*${_A}{20,}"                         # OpenAI / Stripe secret key (>=20 contiguous alnum)
  "sk_live_${_K}*${_A}{12,}"                    # Stripe live secret key (>=12 contiguous alnum)
  "rk_live_${_K}*${_A}{12,}"                    # Restricted API key live (>=12 contiguous alnum)
  'AIza[a-zA-Z0-9_-]+'                          # Google API key
  'ghp_[a-zA-Z0-9][a-zA-Z0-9]*'                 # GitHub personal access token
  'gho_[a-zA-Z0-9][a-zA-Z0-9]*'                 # GitHub OAuth token
  'gh[sur]_[a-zA-Z0-9]{20,}'                    # GitHub app, user-to-server and refresh tokens (>=20 body chars)
  'github_pat_[a-zA-Z0-9_][a-zA-Z0-9_]*'        # GitHub fine-grained PAT
  'glpat-[a-zA-Z0-9_-]{20,}'                    # GitLab personal access token (>=20 body chars)
  '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY' # PEM private keys
  'xox[bpsar]-[a-zA-Z0-9-]+'                    # Slack tokens
  "$JWT_PATTERN"                                # JWT tokens (3-part base64 base64url)
)

for pattern in "${SECRET_PATTERNS[@]}"; do
  if match_in -qE "$pattern" "$CONTENT"; then
    # The reason shows the first 20 characters only; the audit reason carries none of the match.
    MATCHED=$(printf '%s\n' "$CONTENT" | grep -oE -- "$pattern" | head -1 | cut -c1-20 || true)
    deny "secret pattern blocked" "Potential secret detected (pattern match: ${MATCHED}...). Review the content and remove secrets before proceeding."
  fi
done

# .env files in Bash commands. A .env token is `.env`, `.env.<anything>` or `<name>.env`, with an optional
# path. Example files (.env.example/.sample/.template/.dist), `process.env`, `import.meta.env`, exclude
# options and the first quoted pattern of a grep, egrep, fgrep, rg, ag or ack, after short flags only and not
# after -e, -f, -g or -G, which take a value, nor a double-quoted one holding $ or a backtick, which may run a
# command (searching .gitignore for '.env' reads no .env), are blanked first, so they neither trigger a deny nor hide a real .env beside them. Case is
# ignored, as on the default macOS filesystem.
ENVTOK='(\.env(rc|\.[A-Za-z0-9_.*-]+|\*)?|[A-Za-z0-9_-]+\.env)'
ENVPATH='([^[:space:]"'"'"'<>|;&()=@:,]*/)?'"$ENVTOK"
ENVEND='(["'"'"'[:space:];&|<>,)`]|$)'
ENVLEFT='[[:space:]"'"'"'=@:/<*,(`]'
env_clean() {
  printf '%s' "$1" | sed -E \
    -e 's#([^[:space:]"'"'"'=@<>:,()|;&]*\.env\.(example|sample|template|dist))([[:space:]"'"'"'<>|;&,)`]|$)#EXAMPLE\3#g' \
    -e 's#process\.env#PROCENV#g; s#import\.meta\.env#IMPENV#g' \
    -e 's#(^|[;&|(`[:space:]])(grep|egrep|fgrep|rg|ag|ack)(([[:space:]]+-[A-FH-Za-dh-z]+)*)[[:space:]]+("[^"$`]*"|'"'"'[^'"'"']*'"'"')#\1\2\3 Q#g' \
    -e 's#(^|[[:space:]])--exclude(-dir)?[= ][^[:space:]]+#\1#g; s#(^|[[:space:]])(-g|--glob)[= ]+["'"'"']?![^[:space:]]+#\1#g'
}

# Segments of a command, one per line as "<words>\036<segment>": split at | ; & outside quotes, so a grep
# pattern such as 'A|B' stays in its segment. In <words> a quoted string becomes its text when it holds no
# space ('.' stays a path, --exclude='*.env*' a flag) and the word Q when it does (a pattern like "a . b").
segments() {
  printf '%s\n' "$1" | awk '
    function flush() { if (raw ~ /[^ \t]/) printf "%s\036%s\n", words, raw; words = ""; raw = "" }
    {
      q = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (q != "") {
          if (c == q) { raw = raw q qs q; words = words ((qs == "" || qs ~ /[ \t]/) ? "Q" : qs); q = "" }
          else qs = qs c
        }
        else if (c == "\047" || c == "\"") { q = c; qs = "" }
        else if (c ~ /[|;&]/) flush()
        else { raw = raw c; words = words c }
      }
      if (q != "") { raw = raw q qs; words = words "Q" }
      flush()
    }'
}

# recursive_env_search <words>: the segment runs a recursive grep, or an rg that also reads hidden or
# ignored files. Whatever the path, it may read a .env below it, so it needs an exclude (checked by the caller).
recursive_env_search() {
  local w kind=""
  set -f
  for w in $(printf '%s' "$1" | tr '()`' '   '); do
    if [ -z "$kind" ]; then
      case "${w##*/}" in grep|egrep|fgrep) kind=grep ;; rg) kind=rg ;; esac
      continue
    fi
    case "$kind/$w" in
      grep/--recursive|grep/--dereference-recursive) set +f; return 0 ;;
      grep/-[!-]*) case "$w" in *[rR]*) set +f; return 0 ;; esac ;;
      rg/--hidden|rg/--no-ignore*|rg/--unrestricted|rg/-.|rg/-u|rg/-uu|rg/-uuu) set +f; return 0 ;;
    esac
  done
  set +f
  return 1
}

# keychain_read <command>: prints a word when the command may print a Keychain secret, nothing otherwise.
# Secret: `security find-generic-password` or `find-internet-password` (a prefix of 6+ characters counts, as the
# security tool may take one) with -w (print the password) or -g (print it to stderr), in any flag position or
# combination (-gw, -wg, -gs), and `dump-keychain -d`. The existence check (no -w, no -g) and
# `add-generic-password ... -w` (a prompt) pass. A `security` with no subcommand after it, or with -i or -p, reads
# its subcommands from stdin, out of this scan's sight, so it counts too.
# The match is over the whole command, with no parsing of the shell: quote characters and backslashes are removed
# (sec"urity" is security, a backslash-newline joins lines), ( ) ` ; | & < > = and white space become word breaks,
# and the words are compared in lower case. The checks are word-for-word, never per command: the flag may sit
# anywhere, so quoting, comments, here-documents, $(...), `sh -c "..."` and separators with no space around them
# need no handling of their own. It over-matches on purpose: an echo or a grep that spells the words out denies
# too, and so does any word `security` that ends a command or is followed by something other than a subcommand
# (`grep -i security notes.txt`, `ls docs/security`); use the Grep tool for that. Only a lookup passes
# (`command -v security`, `which`, `type`, `whence`, `where`, each at the start of a command).
# Known gaps, kept to keep the check simple: a name or flag built at run time (s=security; $s ..., -s svc $f, aliases,
# functions, brace expansion, wildcards in a name or in zsh's -(w), ${IFS}, $"..."), ANSI-C quoting ($'...'), a script written with the Write tool and then
# run, a program that runs the command itself (python -c), and the other secret-printing subcommands (export,
# find-key). A normal-route fence, not a sandbox.
keychain_read() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { RS = "\001" }
    function isname(lt, full) { return length(lt) >= 6 && index(full, lt) == 1 }
    function cmdstart(x) { return x == "" || x == ";" || x ~ /^(if|then|elif|else|while|until|do|!|\{)$/ }
    {
      s = $0
      gsub(/\\\\/, "", s); gsub(/\\\n/, "", s); gsub(/[\047"\\]/, "", s)
      gsub(/[<>=]/, " & ", s); gsub(/[;|&()`\n\t\r]/, " ; ", s)
      n = split(s, w, / +/)
      for (i = 1; i <= n; i++) {
        t = w[i]
        if (t == "") continue
        lt = tolower(t); base = lt; sub(/.*\//, "", base)
        if (isname(lt, "find-generic-password") || isname(lt, "find-internet-password")) fnd = 1
        else if (isname(lt, "dump-keychain")) dmp = 1
        if (t ~ /^-[A-Za-z]*[wg]/) wg = 1
        if (t ~ /^-[A-Za-z]*d/) dd = 1
        if (t ~ /^-.*[*?[]/) { wg = 1; dd = 1 }
        if (base == "security" && !((p1 ~ /^(which|type|whence|where)$/ && cmdstart(p2)) || (p1 ~ /^-[pvV]*[vV]$/ && p2 == "command" && cmdstart(p3)))) {
          sub_ok = 0
          for (j = i + 1; j <= n; j++) {
            if (w[j] == "") continue
            if (w[j] ~ /^-/) { if (w[j] ~ /^-[A-Za-z]*[ip]/) { print "x"; exit } continue }
            sub_ok = (tolower(w[j]) ~ /^[a-z]+-[a-z-]+$/)
            break
          }
          if (!sub_ok) { print "x"; exit }
        }
        p3 = p2; p2 = p1; p1 = lt
      }
      if ((fnd && wg) || (dmp && dd)) print "x"
    }
  '
}

if [ "$TOOL_NAME" = "Bash" ]; then
  if [ -n "$(keychain_read "$CONTENT")" ]; then
    deny "blocked Keychain secret read" "Keychain secret read blocked: a secret must never reach an agent. Ask the user to run this command in their own terminal. The existence check (security find-generic-password -s <service>, without -w or -g) is allowed. If this command only searches for the text, use the Grep tool."
  fi
  CLEAN=$(env_clean "$CONTENT")
  # Readers: a .env token among a reader's arguments; source or `.` of a .env; an input redirect from one;
  # a curl-style upload of one (@file, -T, --upload-file).
  READERS='cat|head|tail|less|more|grep|awk|sed|cut|strings|xxd|rg|ag|bat|nl|tac|od|hexdump|base64|diff|cp'
  env_hit=0
  match_in -qiE '(^|[^[:alnum:]_.-])(source|\.)[[:space:]]+["'"'"']?'"$ENVPATH$ENVEND" "$CLEAN" && env_hit=1
  match_in -qiE '(^|[^[:alnum:]_.-])('"$READERS"')[[:space:]]+([^|;&<>]*'"$ENVLEFT"')?'"$ENVPATH$ENVEND" "$CLEAN" && env_hit=1
  match_in -qiE '(^|[^<])<[[:space:]]*["'"'"']?'"$ENVPATH$ENVEND" "$CLEAN" && env_hit=1
  match_in -qiE '(@|(^|[[:space:]])-T[[:space:]]*|--upload-file[[:space:]=]+)["'"'"']?'"$ENVPATH$ENVEND" "$CLEAN" && env_hit=1
  if [ "$env_hit" = 1 ]; then
    deny "blocked .env read" "Attempting to read a .env file which likely contains secrets. Use environment variables directly or ask the user for the specific values needed."
  fi
  # Writers: an output redirect to a .env token, a .env token among tee's arguments, dd of=<.env>, or the
  # EOFENV/ENVEOF heredoc. Checked on the cleaned text, so process.env and example files never count. A
  # redirect's or dd's path may hold quotes and substitutions ("$DIR"/.env, $(pwd)/.env). A JS arrow `=>`
  # followed by a space is no redirect; `=>.env` with no space is (echo KEY=>.env writes the file).
  env_write=0
  WPATH='["'"'"']?([^[:space:]<>|;&]*/)?'"$ENVTOK$ENVEND"
  match_in -qiE '(^|[^=])>\|?[[:space:]]*'"$WPATH" "$CLEAN" && env_write=1
  match_in -qiE '=>\|?'"$WPATH" "$CLEAN" && env_write=1
  match_in -qiE '(^|[^[:alnum:]_.-])tee[[:space:]]+([^|;&<>]*'"$ENVLEFT"')?'"$ENVPATH$ENVEND" "$CLEAN" && env_write=1
  match_in -qiE '(^|[[:space:]])of='"$WPATH" "$CLEAN" && env_write=1
  match_in -qE '<<(EOFENV|ENVEOF)' "$CONTENT" && env_write=1
  if [ "$env_write" = 1 ]; then
    deny "blocked .env write (redirection/tee/heredoc)" "Attempting to write to a .env file via redirection, tee, dd or heredoc. These files contain secrets and should not be modified by agents."
  fi
  if match_in -qE '(^|[^[:alnum:]_.-])(grep|egrep|fgrep|rg)[[:space:]]' "$CONTENT"; then
    while IFS=$'\036' read -r words seg; do
      recursive_env_search "$words" || continue
      # Allowed when the segment excludes *.env* (grep --exclude, rg -g '!...'). `.env*` is not enough: it misses
      # <name>.env files such as prod.env, which ENVTOK treats as secret too.
      match_in -qE '(^|[[:space:]])--exclude[= ]["'"'"']?\*\.env\*["'"'"']?([[:space:]]|$)' "$seg" && continue
      match_in -qE '(^|[[:space:]])(-g|--glob)[= ]+["'"'"']?!\*\.env\*["'"'"']?([[:space:]]|$)' "$seg" && continue
      deny "blocked recursive search over .env" "A recursive search may read .env files. Add --exclude='*.env*' (grep) or -g '!*.env*' (rg), or use the Grep tool."
    done <<EOF_SEGS
$(segments "$CONTENT")
EOF_SEGS
  fi
fi

# Write/Edit/MultiEdit/NotebookEdit on a .env file. An exact example file name is allowed.
if [ -n "$FILE_PATH" ]; then
  if ! match_in -qiE '^\.env\.(example|sample|template|dist)$' "${FILE_PATH##*/}" \
    && match_in -qiE '(^|/)'"$ENVTOK"'$' "$FILE_PATH"; then
    deny "blocked .env write (Write/Edit/MultiEdit/NotebookEdit)" "Attempting to write to a .env file. These files contain secrets and should not be modified by agents."
  fi
fi

exit 0
