#!/usr/bin/env bash
# Claude Code status line
# Displays: model name, context window usage (scaled to the compact window), 5-hour and weekly rate limit usage
#
# Also keeps this account's latest rate-limit windows in a small readings file, so a chat with no live
# reading still shows the newest one another chat saw (see below).
#
# Installed to ~/.claude/statusline.sh via symlink from /setup-claude.
# Configured in ~/.claude/settings.json as:
#   "statusLine": { "type": "command", "command": "bash $HOME/.claude/statusline.sh" }

set -eo pipefail
# printf %.0f below reads numbers in the locale's format, and a comma-decimal locale rejects 23.5: pin C.
export LC_ALL=C

command -v jq >/dev/null 2>&1 || { printf "[jq missing]\n"; exit 1; }

input=$(cat)

# Parse all fields in a single jq call
# Use -1 sentinel for missing numeric fields — bash read collapses empty TSV fields,
# which shifts subsequent values when an interior field is null.
# Both windows are rendered and kept in the readings file below.
IFS=$'\t' read -r model ctx_used_pct ctx_window_size rate_pct resets_at week_pct week_resets_at session_id effort_level cache_warm cache_observed cache_ttl cache_expires transcript_path cost_usd < <(
  echo "$input" | jq -r '[
    ((.model.display_name // "Unknown") | gsub(" \\([^)]*context\\)"; "")),
    (.context_window.used_percentage // -1),
    (.context_window.context_window_size // -1),
    (.rate_limits.five_hour.used_percentage // -1),
    (.rate_limits.five_hour.resets_at // -1),
    (.rate_limits.seven_day.used_percentage // -1),
    (.rate_limits.seven_day.resets_at // -1),
    (.session_id // "unknown"),
    (.effort.level // "none"),
    (.prompt_cache.warm | tostring),
    (.prompt_cache.caching_observed | tostring),
    (.prompt_cache.ttl // "none"),
    (.prompt_cache.expires_at // -1),
    ((.transcript_path // "") | if . == "" then "none" else . end),
    (.cost.total_cost_usd // -1)
  ] | @tsv'
)

# Reference window the context gauge is scaled to, deliberately not the model's own
# window, so the bar means the same thing on every model — a 1M-context session
# reading >100% here is correct, not a bug.
# The rounding term in the render below is derived from this value (half of it),
# so this is the single place the reference is set.
CTX_REFERENCE=250000
# The yardstick is the compact window: the size at which the session compacts itself,
# so 100% on the bar means "about to compact". Read autoCompactWindow from settings,
# cap it at the window the harness reports (a session cannot hold more than that),
# and fall back to 250000 when it is absent, not a number, or below 10000.
_ctx_cfg=$(jq -r '.autoCompactWindow // empty' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null) || _ctx_cfg=""
case "$_ctx_cfg" in
  ''|*[!0-9]*) ;;
  *) if [ "${#_ctx_cfg}" -le 9 ]; then
       _ctx_cfg=$((10#$_ctx_cfg))   # 10# so a leading zero is not read as octal
       if [ "$_ctx_cfg" -ge 10000 ]; then CTX_REFERENCE=$_ctx_cfg; fi
     fi ;;
esac
if [ "$ctx_window_size" -gt 0 ] 2>/dev/null && [ "$ctx_window_size" -lt "$CTX_REFERENCE" ]; then
  CTX_REFERENCE=$ctx_window_size
fi

# Overshoot (projected end-of-window usage, %) above which a rate bar leaves grey.
# Weekly is lower on purpose: a weekly overshoot takes DAYS to correct rather than
# hours, so it is worth hearing about sooner even though the signal is the same.
FIVE_HOUR_WARN_AT=100
WEEKLY_WARN_AT=90
# An account that reports a weekly figure but has shown no live 5h one for this long (seconds) has no
# 5h window (a plan without one): the 5h segment is left out instead of drawn as an empty bar.
FIVE_ABSENT_AFTER_S=21600
# Below this much ACTUAL usage a bad pace is still cheap to correct, so the bar is
# held at its first tier. See the damper in rate_color_for.
RATE_DAMP_BELOW=25

# Context color based on the reference window above
# 0-50% grey, 50-70% blue, 70-85% gold, 85-100% dusty red, >100% hard red
ctx_color_for() {
  local pct="${1:-0}"
  if [ "$pct" -gt 100 ]; then
    printf "\033[38;5;168m"
  elif [ "$pct" -ge 85 ]; then
    printf "\033[38;5;131m"
  elif [ "$pct" -ge 70 ]; then
    printf "\033[38;5;144m"
  elif [ "$pct" -ge 50 ]; then
    printf "\033[38;5;67m"
  else
    printf "\033[38;5;245m"
  fi
}

# Colour for a rate-limit bar, keyed on PROJECTED OVERSHOOT.
#
# overshoot = the percentage of the allowance this pace would consume by the time
# the window resets. 100 lands exactly on budget; 150 would need half again more
# than exists. Grey while the projection lands inside budget, then progressively
# redder the further past it the pace is heading.
#
# Nothing here keys on absolute usage as a SIGNAL, deliberately. The only thing a
# limit bar can still change is behaviour before the wall — at 100% used no
# request succeeds at all, so a colour there is information arriving too late to
# act on, and the bar is already visibly full. Absolute usage enters only as the
# damper below.
#
# Both bars share this function; they differ only in where grey ends. Two
# near-identical colour functions is exactly the shape that drifts, so the 5-hour
# and weekly policies stay one code path with different constants.
#
# Args: used_pct elapsed_pct warn_at damp_below
#   warn_at    — overshoot above which the bar leaves grey
#   damp_below — below this much actual usage, never escalate past the first tier
rate_color_for() {
  local pct="${1:-0}"
  local time_pct="${2:-0}"
  local warn_at="${3:-100}"
  local damp_below="${4:-25}"

  # DIVISOR GUARD — load-bearing, not a nicety. time_pct is the denominator on the
  # next line, so dropping this is a division by zero at the start of a window.
  # It doubles as noise suppression: in the opening slice of a window a trivial
  # burst projects to an enormous overshoot that costs nothing to correct.
  if [ "$pct" -le 0 ] || [ "$time_pct" -le 5 ]; then
    printf "\033[38;5;245m"
    return
  fi

  local overshoot=$(( pct * 100 / time_pct ))

  if [ "$overshoot" -le "$warn_at" ]; then
    # On track to land inside the allowance — stay out of the way.
    printf "\033[38;5;245m"
  elif [ "$pct" -lt "$damp_below" ]; then
    # DAMPER. The pace is bad, but barely any of the window is actually spent, so
    # it is still cheap to correct and the ratio is mostly noise this early. Show
    # the first tier and no more — escalation is reserved for a pace that is both
    # bad and already expensive.
    printf "\033[38;5;144m"
  elif [ "$overshoot" -gt $(( warn_at + 60 )) ]; then
    # Burning far faster than the window allows.
    printf "\033[38;5;168m"
  elif [ "$overshoot" -gt $(( warn_at + 25 )) ]; then
    # Will run out well before the reset.
    printf "\033[38;5;131m"
  else
    # Will run out, but late in the window.
    printf "\033[38;5;144m"
  fi
}

# Build a progress bar with optional time marker
# Args: percentage (0-100+), bar_width, [time_position 0-100]
# Time marker is shown by underlining that cell (keeps ▓/░ character, theme-agnostic).
bar() {
  local pct="${1:-0}"
  local width="${2:-12}"
  local time_pos="${3:-}"
  local filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  local marker_pos=""
  if [ -n "$time_pos" ]; then
    marker_pos=$(( (time_pos * width + 50) / 100 ))
    [ "$marker_pos" -ge "$width" ] && marker_pos=$(( width - 1 ))
  fi
  local marker_on=$'\033[4m'
  local marker_off=$'\033[24m'
  local result=""
  local i
  for (( i=0; i<width; i++ )); do
    local char
    if [ "$i" -lt "$filled" ]; then
      char="▓"
    else
      char="░"
    fi
    if [ -n "$marker_pos" ] && [ "$i" -eq "$marker_pos" ]; then
      result="${result}${marker_on}${char}${marker_off}"
    else
      result="${result}${char}"
    fi
  done
  printf "%s" "$result"
}

# --- API-key view ----------------------------------------------------------------
# An API key has no subscription rate_limits, so the Limit/Weekly bars would sit empty. When
# ANTHROPIC_API_KEY is set (presence only, the value is never read or printed) and the harness
# sent no rate_limits, they give way to: cached <bar of the cache-read share of all input>,
# Input <all input tokens> / <cost-weighted input>, Output <tokens>, Cost <$>. All input is fresh plus
# cache-write plus cache-read tokens; the weighted figure prices them in fresh-token units (weights below).
# The statusline's stdin carries only the LAST response's tokens, so the totals are summed here
# from the session's own transcript plus its subagents' transcripts (<transcript minus .jsonl>/subagents/
# agent-*.jsonl; their usage is in the session's Cost too). One usage per assistant message id; the transcript
# repeats it for every content block. The sum is cached by the total size of those files and redone by a
# detached job when it grows, so a render never waits for it. Cost is the harness's own figure.

# Weights of the cost-weighted Input figure, in hundredths of the base input price: fresh input x1, a 5-minute
# cache write x1.25, a 1-hour cache write x2, a cache read x0.1. They are base-price multipliers; some models bill
# cache reads lower, so the figure is an estimate of price-equivalent fresh tokens, not a bill.
API_W_FRESH=100 API_W_WRITE_5M=125 API_W_WRITE_1H=200 API_W_READ=10

# Compact token count: 812, 9.5k, 297k, 1.2M, 62.9M.
fmt_tok() {
  local n="${1:-0}"
  if [ "$n" -ge 1000000 ]; then printf "%d.%dM" $(( n / 1000000 )) $(( n % 1000000 / 100000 ))
  elif [ "$n" -ge 10000 ]; then printf "%dk" $(( n / 1000 ))
  elif [ "$n" -ge 1000 ]; then printf "%d.%dk" $(( n / 1000 )) $(( n % 1000 / 100 ))
  else printf "%d" "$n"; fi
}

# api_list <transcript>: sets the array API_FILES to the readable transcript and subagent transcripts (no subshell,
# so a render pays no fork for it). A glob with no match stays literal and fails the -r test.
api_list() {
  local f
  API_FILES=()
  for f in "$1" "${1%.jsonl}"/subagents/agent-*.jsonl; do
    if [ -r "$f" ] && [ -f "$f" ]; then API_FILES[${#API_FILES[@]}]=$f; fi
  done
  [ "${#API_FILES[@]}" -gt 0 ]
}

# api_size <transcript>: the total bytes of API_FILES from one stat call; fails (no size, no sum job) when stat
# does not report every file, e.g. one vanished meanwhile.
api_size() {
  local out s total=0
  api_list "$1" || return 1
  out=$(stat -f%z "${API_FILES[@]}" 2>/dev/null) || out=$(stat -c%s "${API_FILES[@]}" 2>/dev/null) || return 1
  set -- $out
  [ "$#" -eq "${#API_FILES[@]}" ] || return 1
  for s in "$@"; do total=$(( total + s )); done
  printf '%s' "$total"
}

# api_sum_transcript <transcript> <size> <cache>: writes "size<TAB>fresh<TAB>write5m<TAB>write1h<TAB>read<TAB>output".
# <size> is the api_size read BEFORE the sum, so a file that grew meanwhile is summed again next time. The writes
# split by cache lifetime from usage.cache_creation.ephemeral_{5m,1h}_input_tokens; any part of
# cache_creation_input_tokens the split does not cover counts as 5-minute writes, so a usage without the split is
# all 5-minute writes and the raw total never drops below fresh + cache_creation_input_tokens + read.
api_sum_transcript() {
  local sums tmp="$3.$$"
  api_list "$1" || return 0
  # Per message id the largest figure of each field wins (output_tokens only grows while a response streams, the
  # input fields repeat), a non-number counts 0, and a line without a message object is skipped. awk ends
  # a last line that has no newline, which jq -R would join to the next file's first line; a file that
  # vanished meanwhile loses only its own usage.
  sums=$({ awk 1 "${API_FILES[@]}" 2>/dev/null || true; } | jq -nRr 'reduce (inputs | fromjson? | select(type == "object" and .type == "assistant"
        and ((.message | type) == "object") and ((.message.usage | type) == "object"))) as $l ({};
      ($l.message.id // $l.requestId // $l.uuid // "") as $k
      | ($l.message.usage | (.cache_creation_input_tokens | numbers // 0) as $cc
          | ((.cache_creation | objects | .ephemeral_1h_input_tokens | numbers) // 0) as $c1
          | ((.cache_creation | objects | .ephemeral_5m_input_tokens | numbers) // 0) as $c5
          | [(.input_tokens | numbers // 0), ($c5 + ([$cc - $c5 - $c1, 0] | max)), $c1,
             (.cache_read_input_tokens | numbers // 0), (.output_tokens | numbers // 0)]) as $u
      | .[$k] = (if .[$k] then [.[$k], $u] | transpose | map(max) else $u end))
    | [.[]] | (if length == 0 then [[0, 0, 0, 0, 0]] else . end) | transpose | map(add) | @tsv' 2>/dev/null) || return 0
  [ -n "$sums" ] || return 0
  printf '%s\t%s\n' "$2" "$sums" > "$tmp" 2>/dev/null && mv -f "$tmp" "$3" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# api_view_segment: prints the cached / Input / Output / Cost segments. Fail-open and silent.
api_view_segment() {
  local dir="${STATUSLINE_CACHE_DIR:-$HOME/.cache/claude-statusline}" tp="$transcript_path"
  local grey=$'\033[38;5;245m' teal=$'\033[38;5;73m' off=$'\033[0m'
  local key size cache run c_size fresh w5 w1 cread out extra total weighted cached_pct run_m
  # An id-less session would share one cache file with every other: no sum for it.
  if [ "$tp" != none ] && [ "$session_id" != unknown ] && [ -r "$tp" ]; then
    size=$(api_size "$tp") || size=
    key=$(printf %s "$session_id" | tr -c 'A-Za-z0-9_-' _)
    cache="$dir/$key.tsv"; run="$dir/$key.run"
    if [ -n "$size" ]; then
      c_size=-1
      [ -r "$cache" ] && IFS=$'\t' read -r c_size fresh w5 w1 cread out extra < "$cache" 2>/dev/null || true
      # Not six columns (a five-column file from before the 5m/1h split): stale, summed again, never misread.
      if [ -z "${out:-}" ] || [ -n "${extra:-}" ]; then c_size=-1; fresh= w5= w1= cread= out=; fi
      # One job at a time: a marker younger than 60 s (compared in seconds, not find -mmin, which rounds up on BSD) means one runs.
      run_m=$(stat -f%m "$run" 2>/dev/null || stat -c%Y "$run" 2>/dev/null) || run_m=0
      if [ "$c_size" != "$size" ] && ! [ $(( $(date '+%s') - run_m )) -lt 60 ] 2>/dev/null; then
        ( umask 077; mkdir -p "$dir"; : > "$run" ) 2>/dev/null || true
        ( umask 077; api_sum_transcript "$tp" "$size" "$cache"; rm -f "$run"
          find "$dir" -type f -mtime +7 -delete ) >/dev/null 2>&1 </dev/null &
        disown 2>/dev/null || true
      fi
    fi
  fi
  if [ -n "${cread:-}" ] && [ "${fresh:-x}" -ge 0 ] 2>/dev/null && [ "${w5:-x}" -ge 0 ] 2>/dev/null \
    && [ "${w1:-x}" -ge 0 ] 2>/dev/null && [ "$cread" -ge 0 ] 2>/dev/null && [ "${out:-x}" -ge 0 ] 2>/dev/null; then
    total=$(( fresh + w5 + w1 + cread ))
    weighted=$(( (fresh * API_W_FRESH + w5 * API_W_WRITE_5M + w1 * API_W_WRITE_1H + cread * API_W_READ + 50) / 100 ))
    cached_pct=0
    [ "$total" -gt 0 ] && cached_pct=$(( (cread * 100 + total / 2) / total ))
    printf "  %scached%s %s%s%s" "$grey" "$off" "$teal" "$(bar "$cached_pct" 12)" "$off"
    printf "  %sInput%s %s / %s" "$grey" "$off" "$(fmt_tok "$total")" "$(fmt_tok "$weighted")"
    printf "  %sOutput%s %s" "$grey" "$off" "$(fmt_tok "$out")"
  else
    printf "  %sInput%s \033[38;5;240m…%s" "$grey" "$off" "$off"
  fi
  if [ "$cost_usd" != "-1" ]; then
    printf "  %sCost%s \$%s" "$grey" "$off" "$(LC_ALL=C printf '%.2f' "$cost_usd" 2>/dev/null || printf '0.00')"
  fi
}

# Model segment (+ the model's reasoning-effort tag, when it reports one).
# Same teal as the model bracket. The harness sends
# .effort.level as low|medium|high|xhigh|max (absent — sentinel "none" — when the
# model does not support effort); an unrecognised/absent value renders nothing.
printf "\033[38;5;73m[%s]\033[0m" "$model"
case "${effort_level:-none}" in
  low)    eff=L ;;
  medium) eff=M ;;
  high)   eff=H ;;
  xhigh)  eff=XH ;;
  max)    eff=MX ;;
  *)      eff= ;;
esac
[ -n "$eff" ] && printf " \033[38;5;73m[%s]\033[0m" "$eff"

# Prompt-cache segment — a single "draining pie" glyph for how much of the main
# conversation's cached prefix lifetime is left before it goes COLD. Deliberately icon-ONLY
# (no digits) and always exactly one glyph wide, so the field never changes size across
# states — it sits between the model and Context, where the position makes "cache" implicit.
#
# From the harness prompt_cache object (Claude Code v2.1.251+): .warm, .caching_observed,
# .ttl ("5m"/"1h"), .expires_at (epoch seconds when the prefix leaves its TTL). The fill
# drains ● ◕ ◑ ◔ ○ over the TTL and the colour warms teal→gold→red as it nears cold. A cold-but-
# observed cache renders a DIM ○ (kept, not hidden, to hold the width). The whole segment is
# silent ONLY when caching was never observed or the field is absent (older build / before
# the first API response) — fail-open, a statusline must never break a session.
#
# A live drain needs the statusline to re-run; with refreshInterval set it ticks, otherwise
# it reflects the state as of the last redraw. Glyphs are assigned to a var before printing
# (never appended as literals in a loop) — the clean multibyte pattern used by bar().
if [ "${cache_observed:-null}" = "true" ]; then
  if [ "${cache_warm:-null}" = "true" ] && [ "${cache_expires:--1}" -gt 0 ] 2>/dev/null; then
    case "${cache_ttl:-none}" in
      5m) cache_ttl_s=300 ;;
      1h) cache_ttl_s=3600 ;;
      *)  cache_ttl_s=3600 ;;   # unknown/absent TTL: assume the longer window
    esac
    cache_remain=$(( cache_expires - $(date '+%s') ))
    [ "$cache_remain" -lt 0 ] && cache_remain=0
    cache_left=$(( cache_remain * 100 / cache_ttl_s ))   # % of TTL remaining
    [ "$cache_left" -gt 100 ] && cache_left=100
    # Fill drains AND colour warms together over five evenly-spaced tiers: teal (full) →
    # deeper teal → gold → terracotta → bright red (imminent). Codes are the file's own
    # dusty palette (73 = the [model] teal, 66, 144, 173) with a bright 196 only at the wall.
    if   [ "$cache_left" -ge 88 ]; then cache_g="●"; cache_code=73
    elif [ "$cache_left" -ge 62 ]; then cache_g="◕"; cache_code=66
    elif [ "$cache_left" -ge 38 ]; then cache_g="◑"; cache_code=144
    elif [ "$cache_left" -ge 12 ]; then cache_g="◔"; cache_code=173
    else                                cache_g="○"; cache_code=196; fi
    printf "  \033[38;5;%sm%s\033[0m" "$cache_code" "$cache_g"
  elif [ "${cache_warm:-null}" = "false" ]; then
    # Observed this session but the last response read nothing from cache → gone cold.
    printf "  \033[38;5;240m○\033[0m"
  fi
fi

# Context window segment — scaled to the CTX_REFERENCE yardstick
# Derives actual token usage from used_percentage × window_size, then rescales.
# The + CTX_REFERENCE/2 is round-half-up, so it must track the reference itself.
if [ "$ctx_used_pct" != "-1" ] && [ "$ctx_window_size" -gt 0 ] 2>/dev/null; then
  used_pct_int=$(printf "%.0f" "$ctx_used_pct" 2>/dev/null) || used_pct_int=0
  actual_tokens=$(( used_pct_int * ctx_window_size / 100 ))
  ctx_pct=$(( (actual_tokens * 100 + CTX_REFERENCE / 2) / CTX_REFERENCE ))
  clr=$(ctx_color_for "$ctx_pct")
  printf "  \033[38;5;245mContext\033[0m %s%s\033[0m %s%3d%%\033[0m" "$clr" "$(bar "$ctx_pct" 12)" "$clr" "$ctx_pct"
fi

# --- personal rate-window store: latest value across this account's chats ----
# Goal: every chat shows the newest 5h/weekly reading regardless of which chat
# observed it. The harness hands a session a window only while that session has a
# live reading of it; an idle chat's render omits it, so its bar would otherwise
# vanish. We keep a small per-account store, MERGED on every render — a live
# reading this render wins; otherwise the last stored value for that window is
# retained — and drive the Limit/Weekly bars from it.
#
# Per account: the store path embeds self_fp, a fingerprint of
# ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json (whoever is logged in for THIS session), so
# each account reads and writes its own file and never sees another's meter. Run each
# extra account with its own CLAUDE_CONFIG_DIR: a session on CLAUDE_CODE_OAUTH_TOKEN
# that shares the default ~/.claude.json still shows the stored login's accountUuid,
# so it would write into, and borrow from, another account's file. Such a session keeps
# no store (the token is tested for presence only, never read).
# Freshness is per-window and keyed on resets_at (see below), not a wall-clock age.
# Fail-open and silent, like every segment.
self_src="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
self_fp=unknown
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
  : # a token session on the shared login: its account is unknown here
elif [ -r "$self_src" ]; then
  self_uuid=$(GREP_OPTIONS= GREP_COLORS= grep -m1 -o '"accountUuid" *: *"[^"]*"' "$self_src" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/') || true
  if [ -n "${self_uuid:-}" ]; then
    self_fp=$(printf %s "$self_uuid" | shasum -a 256 2>/dev/null | cut -c1-12) || self_fp=unknown
    [ -n "${self_fp:-}" ] || self_fp=unknown
  fi
fi
five_pct_eff=$rate_pct; five_reset_eff=$resets_at; five_live=1; five_dim=0
week_pct_eff=$week_pct; week_reset_eff=$week_resets_at; week_live=1; week_dim=0
now_s=$(date '+%s')
pw_file="${USAGE_WATCHER_DIR:-$HOME/.local/state/claude-statusline}/limits/readings-$self_fp.json"
if [ "$self_fp" != "unknown" ]; then
  st_five_pct=-1; st_five_reset=-1; st_five_obs=-1
  st_week_pct=-1; st_week_reset=-1; st_week_obs=-1
  if [ -r "$pw_file" ]; then
    IFS=$'\t' read -r pw_acct st_five_pct st_five_reset st_five_obs st_week_pct st_week_reset st_week_obs < <(
      jq -r '[
        (.account // "unknown"),
        (.five_hour.used_percentage // -1),
        (.five_hour.resets_at // -1),
        (.five_hour.observed_at // -1),
        (.seven_day.used_percentage // -1),
        (.seven_day.resets_at // -1),
        (.seven_day.observed_at // -1)
      ] | @tsv' "$pw_file" 2>/dev/null
    ) || true
  fi
  # Merge: a live reading this render wins; else keep the stored one (borrowed).
  # observed_at is when a window's value was last seen LIVE: now for a
  # live reading, carried for a borrowed one, so the file's readers can age it even
  # though every render rewrites the file. -1 = unknown (an older store).
  if [ "$rate_pct" != "-1" ] 2>/dev/null; then
    five_pct_eff=$rate_pct; five_reset_eff=$resets_at; five_live=1; five_obs=$now_s
  else
    five_pct_eff=${st_five_pct:--1}; five_reset_eff=${st_five_reset:--1}; five_live=0; five_obs=${st_five_obs:--1}
  fi
  if [ "$week_pct" != "-1" ] 2>/dev/null; then
    week_pct_eff=$week_pct; week_reset_eff=$week_resets_at; week_live=1; week_obs=$now_s
  else
    week_pct_eff=${st_week_pct:--1}; week_reset_eff=${st_week_reset:--1}; week_live=0; week_obs=${st_week_obs:--1}
  fi
  # The stored copy never keeps a window that has reset: its % describes the last
  # window. What is kept is when it was last seen (resets_at + observed_at, no %), so
  # a reader can say "absent, last seen …" instead of nothing. The display below
  # does its own expiry, unchanged.
  five_pct_st=$five_pct_eff; week_pct_st=$week_pct_eff
  if [ "$five_reset_eff" -gt 0 ] 2>/dev/null && [ "$now_s" -ge "$five_reset_eff" ] 2>/dev/null; then five_pct_st=-1; fi
  if [ "$week_reset_eff" -gt 0 ] 2>/dev/null && [ "$now_s" -ge "$week_reset_eff" ] 2>/dev/null; then week_pct_st=-1; fi
  # Persist the merged view (atomic, private, best-effort — never break a session) to the readings file
  # (pw_file), where the next render of any chat on this account picks it up.
  pw_json=$(jq -n \
    --arg account "$self_fp" \
    --argjson fp "${five_pct_st:--1}" --argjson fr "${five_reset_eff:--1}" --argjson fo "${five_obs:--1}" \
    --argjson wp "${week_pct_st:--1}" --argjson wr "${week_reset_eff:--1}" --argjson wo "${week_obs:--1}" \
    '{ account: $account }
     + (if $fp >= 0 then {five_hour: {used_percentage: $fp, resets_at: $fr, observed_at: $fo}}
        elif $fo >= 0 and $fr > 0 then {five_hour: {resets_at: $fr, observed_at: $fo}} else {} end)
     + (if $wp >= 0 then {seven_day: {used_percentage: $wp, resets_at: $wr, observed_at: $wo}}
        elif $wo >= 0 and $wr > 0 then {seven_day: {resets_at: $wr, observed_at: $wo}} else {} end)
    ' 2>/dev/null) || pw_json=''
  if [ -n "$pw_json" ]; then
    (
      umask 077
      mkdir -p "$(dirname "$pw_file")" 2>/dev/null || exit 0
      tmp=$(mktemp "$(dirname "$pw_file")/.tmp.XXXXXX" 2>/dev/null) || exit 0
      printf '%s\n' "$pw_json" > "$tmp" 2>/dev/null && mv -f "$tmp" "$pw_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    ) || true
  fi
fi
# Freshness of a BORROWED value is keyed on its own window, not a wall-clock age: a
# personal usage figure stays accurate until the window RESETS, so it renders in the
# normal pace palette while
# the window is open. Once the window has reset (now past resets_at) the stored %
# no longer describes the current window and no fresh reading exists, so it drops
# to the empty placeholder; a borrowed value whose reset time is unknown can't be
# judged, so it renders dim. A live reading (this session's own) is never touched.
if [ "$five_live" -eq 0 ] && [ "$five_pct_eff" != "-1" ] 2>/dev/null; then
  if [ "$five_reset_eff" -gt 0 ] 2>/dev/null; then
    if [ "$now_s" -ge "$five_reset_eff" ] 2>/dev/null; then five_pct_eff=-1; five_reset_eff=-1; fi
  else
    five_dim=1
  fi
fi
if [ "$week_live" -eq 0 ] && [ "$week_pct_eff" != "-1" ] 2>/dev/null; then
  if [ "$week_reset_eff" -gt 0 ] 2>/dev/null; then
    if [ "$now_s" -ge "$week_reset_eff" ] 2>/dev/null; then week_pct_eff=-1; week_reset_eff=-1; fi
  else
    week_dim=1
  fi
fi

# API-key session: ANTHROPIC_API_KEY is set, the harness sent no rate_limits, and the account has no stored
# window either (so a subscription chat that only lacks a live reading keeps its bars, key or not). The
# Input/Output/Cost view takes the place of the Limit and Weekly bars (the fi after the Weekly segment closes this if).
if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ "$rate_pct" = "-1" ] && [ "$week_pct" = "-1" ] \
  && [ "$five_pct_eff" = "-1" ] && [ "$week_pct_eff" = "-1" ]; then
  api_view_segment || true
else
# 5-hour rate limit segment. Driven by five_pct_eff / five_reset_eff / five_dim
# from the per-account window store above: this session's live reading when it has
# one, else the newest value another chat stored (dim when stale). Empty
# placeholder when neither exists (idle account / window reset) so the field never
# disappears. The exception is an account with no 5h window at all: a live or unexpired
# weekly figure, and no live 5h reading seen for FIVE_ABSENT_AFTER_S (or ever), leaves the
# segment out. With no weekly figure either (a new session's first render) both placeholders stay.
if [ "$five_pct_eff" != "-1" ] 2>/dev/null; then
  pct_int=$(printf "%.0f" "$five_pct_eff" 2>/dev/null) || pct_int=0
  time_pos=""
  time_pct=0
  if [ "$five_reset_eff" -gt 0 ] 2>/dev/null; then
    now=$(date '+%s')
    elapsed=$(( now - (five_reset_eff - 18000) ))
    [ "$elapsed" -lt 0 ] && elapsed=0
    [ "$elapsed" -gt 18000 ] && elapsed=18000
    time_pct=$(( elapsed * 100 / 18000 ))
    time_pos=$time_pct
  fi
  if [ "$five_dim" -eq 1 ]; then clr=$(printf "\033[38;5;240m"); else clr=$(rate_color_for "$pct_int" "$time_pct" "$FIVE_HOUR_WARN_AT" "$RATE_DAMP_BELOW"); fi
  printf "  \033[38;5;245mLimit\033[0m %s%s\033[0m %s%3d%%\033[0m" "$clr" "$(bar "$pct_int" 12 "$time_pos")" "$clr" "$pct_int"
else
  five_seen=${five_obs:--1}
  if [ "$week_pct_eff" != "-1" ] 2>/dev/null \
    && { [ "$five_seen" -lt 0 ] 2>/dev/null || [ $(( now_s - five_seen )) -ge "$FIVE_ABSENT_AFTER_S" ] 2>/dev/null; }; then
    : # this account has no 5h window: no segment
  else
    # No live reading and no fallback → dim empty bar, no digits, no reset marker.
    printf "  \033[38;5;245mLimit\033[0m \033[38;5;240m%s\033[0m" "$(bar 0 12)"
  fi
fi

# Weekly (7-day) rate limit segment
# Same signal and same palette as the 5-hour bar above — only WEEKLY_WARN_AT
# differs, so this one leaves grey sooner. The elapsed-time marker carries the
# pace visually as well: 60% used means very different things on day 2 and day 6.
# Driven by week_pct_eff / week_reset_eff / week_dim from the window store above.
if [ "$week_pct_eff" != "-1" ] 2>/dev/null; then
  week_pct_int=$(printf "%.0f" "$week_pct_eff" 2>/dev/null) || week_pct_int=0
  week_time_pos=""
  week_time_pct=0
  if [ "$week_reset_eff" -gt 0 ] 2>/dev/null; then
    now=$(date '+%s')
    week_elapsed=$(( now - (week_reset_eff - 604800) ))
    [ "$week_elapsed" -lt 0 ] && week_elapsed=0
    [ "$week_elapsed" -gt 604800 ] && week_elapsed=604800
    week_time_pct=$(( week_elapsed * 100 / 604800 ))
    week_time_pos=$week_time_pct
  fi
  if [ "$week_dim" -eq 1 ]; then clr=$(printf "\033[38;5;240m"); else clr=$(rate_color_for "$week_pct_int" "$week_time_pct" "$WEEKLY_WARN_AT" "$RATE_DAMP_BELOW"); fi
  printf "  \033[38;5;245mWeekly\033[0m %s%s\033[0m %s%3d%%\033[0m" "$clr" "$(bar "$week_pct_int" 12 "$week_time_pos")" "$clr" "$week_pct_int"
else
  # No live reading and no fallback → dim empty bar, no digits, no reset marker.
  printf "  \033[38;5;245mWeekly\033[0m \033[38;5;240m%s\033[0m" "$(bar 0 12)"
fi
fi

printf "\n"
