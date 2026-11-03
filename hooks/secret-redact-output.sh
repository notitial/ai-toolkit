#!/bin/bash
# PostToolUse hook: redacts token-shaped values in the OUTPUT of Bash and MCP tool calls before the model sees it.
# Configured in ~/.claude/settings.json for PostToolUse on Bash|mcp__.* (the setup skill's template:
# .claude/skills/setup-claude/templates/safe-permissions.json).
#
# Why: secret-detector.sh scans what the model writes, but a command or an MCP tool can still print a credential, and
# the output lands in the model's context and the transcript. This hook replaces matching values with
# [REDACTED:<kind>] in hookSpecificOutput.updatedToolOutput. It never denies or asks: anonymize instead of block.
#
# Fails open by the platform's design (no jq, a crash, a timeout or bad JSON passes the original output), so it is a
# second layer next to secret-detector.sh and the permission denies on secret files. Every pattern is linear and
# bounded, and long strings are scanned in 2 KB blocks, so a large output cannot push it past its timeout; a match of
# up to 512 characters (key and value together) where a long line is cut is still redacted whole. Not covered: the
# output of a Bash command that exits non-zero (PostToolUseFailure cannot replace output), Read, Grep and WebFetch
# output, secrets with no recognizable shape, and an MCP server's own structured copy of its result, which the
# transcript keeps unredacted (a hook can replace only the copy the model sees).
#
# Patterns use oniguruma (jq). Keep the token shapes in step with secret-detector.sh and audit-logger.sh redact().

command -v jq >/dev/null 2>&1 || exit 0

LC_ALL=C
INPUT=$(cat) || exit 0
if [ "${#INPUT}" -gt 4000000 ]; then
  echo "secret-redact-output: output over 4 MB, passed through unredacted" >&2
  exit 0
fi

PROG=$(cat <<'EOF'
# The token rules, in order: [regex, kind, literals]. A (?<k>...) group is kept and the rest of the match becomes
# [REDACTED:<kind>]. A rule runs only on text that holds one of its literals (compared in lower case), which keeps
# the regex work on ordinary output small.
def rules: [
    ["(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{20,}", "github-token", ["gh"]],
    ["github_pat_[A-Za-z0-9_]{20,}", "github-token", ["github_pat_"]],
    ["(?<![A-Za-z0-9])1//0[A-Za-z0-9_-]{30,}", "google-refresh-token", ["1//0"]],
    ["GOCSPX-[A-Za-z0-9_-]{20,}", "google-client-secret", ["gocspx-"]],
    ["(?<![A-Za-z0-9])ya29\\.[A-Za-z0-9_-]{20,}", "google-access-token", ["ya29."]],
    ["(?<![A-Za-z0-9-])[0-9]{1,3}-[A-Za-z0-9]{64}(?![A-Za-z0-9])", "api-key", ["-"]],
    ["(?<![A-Za-z0-9])glpat-[A-Za-z0-9_-]{20,}", "gitlab-token", ["glpat-"]],
    ["(?<![A-Za-z0-9])sk-ant-[A-Za-z0-9_-]{16,}", "anthropic-key", ["sk-ant-"]],
    ["(?<![A-Za-z0-9_-])sk-(?:(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}|[A-Za-z0-9]{20,})", "api-key", ["sk-"]],
    ["(?<![A-Za-z0-9])[sr]k_live_[A-Za-z0-9]{16,}", "stripe-key", ["k_live_"]],
    ["(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}", "aws-key", ["akia", "asia"]],
    ["(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{30,}", "google-key", ["aiza"]],
    ["(?<![A-Za-z0-9])xox[bpsar]-[A-Za-z0-9-]{10,}", "slack-token", ["xox"]],
    ["eyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}", "jwt", ["eyj"]],
    ["(?i)(?<k>bearer[ \\t]+)[A-Za-z0-9._~+/=-]{20,512}", "bearer", ["bearer"]],
    ["(?i)(?<k>authorization[\\\\\"']{0,3}[ \\t]*[:=][ \\t]*[\\\\\"']{0,3}(?:basic|token)[ \\t]+)[A-Za-z0-9._~+/=-]{16,512}", "value", ["authorization"]],
    ["(?<k>://[^/\\s:@]*:)[^/\\s@?#]{3,}(?=@)", "password", ["://"]],
    ["(?i)(?<k>(?:set-)?cookie[\\\\\"']{0,3}[ \\t]*:[ \\t]*[\\\\\"']{0,3})[^\\r\\n\"'\\\\]{16,2048}", "value", ["cookie"]],
    ["(?i)(?<k>x-auth-key[\\\\\"']{0,3}[ \\t]*[:=][ \\t]*[\\\\\"']{0,3})[A-Za-z0-9_-]{20,512}", "value", ["x-auth-key"]],
    ["(?i)(?<k>(?<![A-Za-z0-9])--?(?:password|passwd|token|secret|api-?key)(?:=|[ \\t]+))(?![-/~.$\\[{(<])(?=[^\\s\"'\\\\<>,;&]{0,512}[0-9])(?=[^\\s\"'\\\\<>,;&]{0,512}[A-Za-z])[^\\s\"'\\\\<>,;&]{8,512}", "value", ["pass", "token", "secret", "api"]],
    ["(?i)(?<!next)(?<!next[_-])(?<!page)(?<!page[_-])(?<!continuation)(?<!continuation[_-])(?<!sync)(?<!sync[_-])(?<!resume)(?<!resume[_-])(?<k>(?:token|secret|password|passwd|(?<=[_-])(?:pass|key)|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_.-]{0,40}[\\\\\"']{0,3}[ \\t]*[:=][ \\t]*[\\\\\"']{0,3})(?=[^\\s\"'\\\\<>,;&]{0,512}[0-9])(?=[^\\s\"'\\\\<>,;&]{0,512}[A-Za-z])(?![/~.$\\[{(<])(?![a-z][a-z0-9+.-]*://)[^\\s\"'\\\\<>,;&]{16,512}", "value", ["token", "secret", "pass", "key", "credential"]]
  ];
def live($R): ascii_downcase as $low | [$R[] | select(any(.[2][]; . as $x | $low | contains($x)))];
def redact1($R): live($R) as $L | reduce $L[] as $r (.; gsub($r[0]; (.k // "") + "[REDACTED:" + $r[1] + "]"));
def pem:
  if (split("PRIVATE KEY") | length) > 201 then "[REDACTED:private-key]"
  else
    gsub("-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----(?:[A-Za-z0-9+/=:, .\\r\\n]|\\\\{1,3}[nr]|-(?!----)){0,8192}(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----)?"; "[REDACTED:private-key]")
  end;
# A line longer than 2 KB is cut into 2 KB blocks. Before each cut, the 512 characters on either side are searched:
# when a match crosses the cut, the cut moves past the end of that match, so a match of up to 512 characters (key and
# value together) at a cut is redacted whole. Shorter lines are grouped into blocks that end at a newline, which no
# match crosses.
# cut_at($L; $c; $n): for each rule, the last match that starts before $c. When one reaches $c, the cut moves one past
# its end (a lookahead such as the URL rule's @ stays with it) and is checked again, at most $n more times.
def cut_at($L; $c; $n):
  ([$L[] as $r | match("^.{0,\($c - 1)}(?:" + $r[0] + ")") | select(.length >= $c) | .length + 1] | max) as $e
  | if $e == null then $c elif $n == 0 then $e else cut_at($L; $e; $n - 1) end;
def long_line($R):
  [match(".{1,2048}"; "g") | .string] as $b
  | ($b | length) as $n
  | reduce range(0; $n) as $j ({out: [], skip: 0};
      . as $s | ($b[$j] | .[$s.skip:]) as $cur
      | if $j == $n - 1 then {out: ($s.out + [$cur | redact1($R)]), skip: 0}
        else ((($cur | .[-512:]) + ($b[$j + 1] | .[:512])) | live($R) as $L | cut_at($L; 512; 4) - 512) as $d
          | {out: ($s.out + [($cur + ($b[$j + 1] | .[:$d])) | redact1($R)]), skip: $d}
        end)
  | .out | join("");
def redact($R):
  if type == "string"
  then pem | [match("(?s).{0,2047}\n|[^\n]+"; "g") | .string | if length > 2048 then long_line($R) else redact1($R) end] | join("")
  else . end;
rules as $R
| . as $in
| $in.tool_response as $r
| ($in.tool_name == "Bash") as $bash
| if $r == null or ($bash and ($r | type) == "object" and $r.isImage == true) then empty
  else
    ($r | walk(redact($R))) as $n
    | if $n == $r then empty
      else
        (if $bash and ($n | type) == "object" and ($n | has("stdout"))
         then {stdout: $n.stdout, stderr: ($n.stderr // ""), interrupted: ($n.interrupted // false), isImage: ($n.isImage // false)}
         else $n end) as $out
        | {hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $out}}
      end
  end
EOF
)

OUT=$(printf '%s' "$INPUT" | jq -c "$PROG" 2>/dev/null) || { echo "secret-redact-output: jq failed, output passed through unredacted" >&2; exit 0; }

[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
