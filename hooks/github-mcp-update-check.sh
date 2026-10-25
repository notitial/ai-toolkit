#!/bin/bash
# PreToolUse hook (matcher ^mcp__github__.*$): tells the user when the pinned github-mcp-server has a newer
# release, or an advisory that applies to the installed version.
#
# Why: the server is a pinned, root-installed binary (tools/github-mcp/README.md), so nothing upgrades it on its
# own. The check runs where the server is used, against the binary installed on this machine.
#
# How: most calls only test a few files in the state directory. When the last-check stamp is 7 or more days old,
# the call moves it to 6 days old (so nothing else starts a check for about a day) and starts a copy of itself in
# the background with --check. One check runs at a time (a mkdir lock). The check reads the installed --version
# and asks the GitHub API, with no token, for the latest release and the reviewed advisories on
# github.com/github/github-mcp-server, and stamps the time only once both answers are read. A notice is written
# when the release is newer than the installed version, or an advisory applies: not withdrawn, the installed
# version inside its vulnerable range, and either a newer first patched version or none (then only if published
# after the installed build). Any failure or unexpected answer keeps the previous notice and retries in about a
# day. While a notice is pending, an installed version that differs from the notice's (an upgrade) clears it and
# re-arms the check; otherwise the first github call each day shows it as a systemMessage.
#
# Never blocks: no permission decision, no set -e, and every path exits 0. bash 3.2; macOS date and find.

BIN=/usr/local/libexec/mcp-github/github-mcp-server
CURL=/usr/bin/curl
API=https://api.github.com
STATE="${XDG_CACHE_HOME:-$HOME/.cache}/mcp-github"
CHECKED="$STATE/checked"
NOTICE="$STATE/notice.json"
SHOWN="$STATE/shown"
LOCK="$STATE/lock.d"

# installed: the installed version, digits only (2.0.3), or nothing if --version gives anything else.
installed() {
  "$BIN" --version </dev/null 2>/dev/null | sed -n 's/^Version: v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' |
    head -n 1
}

# Set the last-check stamp to 6 days ago, so the next check comes in about a day.
retry_soon() {
  touch -t "$(date -v-6d +%Y%m%d%H%M.%S 2>/dev/null)" "$CHECKED" 2>/dev/null || touch "$CHECKED" 2>/dev/null
}

check() {
  local inst built rel adv out
  # A lock older than an hour belongs to a check that was killed.
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || return 0
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  inst=$(installed)
  built=$("$BIN" --version </dev/null 2>/dev/null | sed -n 's/^Build Date: //p' | head -n 1)
  [ -n "$inst" ] || { retry_soon; return 0; }
  rel=$("$CURL" -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
    "$API/repos/github/github-mcp-server/releases/latest" 2>/dev/null) || { retry_soon; return 0; }
  adv=$("$CURL" -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
    "$API/advisories?type=reviewed&ecosystem=go&affects=github.com/github/github-mcp-server&per_page=100" \
    2>/dev/null) || { retry_soon; return 0; }
  # Anything but a release object and an advisory array is an unexpected answer, never "up to date".
  out=$(jq -nc --arg inst "$inst" --arg built "$built" --argjson rel "$rel" --argjson adv "$adv" '
    def semver: type == "string" and test("^v?[0-9]+\\.[0-9]+\\.[0-9]+$");
    def ver: ltrimstr("v") | split(".") | map(tonumber);
    def newer($a; $b): ($a | ver) > ($b | ver);
    # in_range($v): $v meets every constraint of a range such as ">= 0.22.0, < 1.1.2"; a constraint that does
    # not parse counts as met, so an odd range reports rather than hides.
    def in_range($v): (. // "" | tostring | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")))
      | all(.[]; (capture("^(?<op>>=|<=|>|<|=)\\s*(?<x>v?[0-9]+\\.[0-9]+\\.[0-9]+)$") // null) as $c
        | if $c == null then true
          else ($v | ver) as $a | ($c.x | ver) as $b
            | if $c.op == ">=" then $a >= $b elif $c.op == ">" then $a > $b elif $c.op == "<=" then $a <= $b
              elif $c.op == "<" then $a < $b else $a == $b end
          end);
    def clean: select(type == "string" and test("^[A-Za-z0-9._-]{1,40}$"));
    if ($rel | type) != "object" or ($adv | type) != "array" then error("unexpected answer") else . end
    | ($rel.tag_name // "") as $tag
    | [ $adv[] | objects | select(.withdrawn_at == null) | . as $a | (.vulnerabilities // [])[]? | objects
        | select(.package.name? == "github.com/github/github-mcp-server")
        | select(.vulnerable_version_range | in_range($inst))
        | (.first_patched_version // "" | if type == "object" then (.identifier // "") else . end) as $f
        | select(if ($f | semver) then newer($f; $inst)
                 else ($built != "" and (($a.published_at // "") | tostring) > $built) end)
        | {id: ($a.ghsa_id | clean), severity: (($a.severity // "unknown") | clean),
           fixed: (if ($f | semver) then ($f | ltrimstr("v")) else "none" end)} ]
      | unique_by(.id) as $hits
    | (($tag | semver) and ($rel.draft != true) and ($rel.prerelease != true) and newer($tag; $inst)) as $up
    | if $up or ($hits | length) > 0
      then {installed: $inst, latest: (if $up then ($tag | ltrimstr("v")) else "" end), advisories: $hits}
      else {} end' 2>/dev/null) || { retry_soon; return 0; }
  [ -n "$out" ] || { retry_soon; return 0; }
  if [ "$out" = "{}" ]; then
    rm -f "$NOTICE" "$SHOWN"
  else
    printf '%s\n' "$out" > "$NOTICE.tmp.$$" && mv -f "$NOTICE.tmp.$$" "$NOTICE"
  fi
  touch "$CHECKED" 2>/dev/null
}

command -v jq >/dev/null 2>&1 || exit 0
[ -x "$BIN" ] || exit 0
mkdir -p "$STATE" 2>/dev/null || exit 0
if [ "${1:-}" = --check ]; then
  check
  exit 0
fi
cat >/dev/null 2>&1

if [ ! -e "$CHECKED" ] || [ -n "$(find "$CHECKED" -mmin +10079 2>/dev/null)" ]; then
  retry_soon
  (/bin/bash "${BASH_SOURCE[0]}" --check </dev/null >/dev/null 2>&1 &)
fi

[ -s "$NOTICE" ] || exit 0
noted=$(jq -r '.installed // empty | strings' "$NOTICE" 2>/dev/null)
inst=$(installed)
# An unreadable --version proves nothing about an upgrade; keep the notice. A notice without a version clears.
if [ -n "$inst" ] && [ "$inst" != "$noted" ] || [ -z "$noted" ]; then
  rm -f "$NOTICE" "$SHOWN" "$CHECKED"
  exit 0
fi
# Shown less than a day ago: stay quiet.
if [ -e "$SHOWN" ] && [ -z "$(find "$SHOWN" -mmin +1439 2>/dev/null)" ]; then
  exit 0
fi
touch "$SHOWN" 2>/dev/null
jq -c '
  "github-mcp-server " + .installed + " is installed"
  + (if (.latest // "") != "" then "; " + .latest + " is released" else "" end)
  + (if (.advisories | length) > 0
     then "; advisories: " + ([.advisories[] | .id + " (" + .severity + ", fixed in " + .fixed + ")"] | join(", "))
     else "" end)
  + ". Upgrade steps: tools/github-mcp/README.md (Upgrades) in the toolkit checkout."
  | {systemMessage: .}' "$NOTICE" 2>/dev/null
exit 0
