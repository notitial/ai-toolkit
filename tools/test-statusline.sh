#!/bin/bash
# Tests for tools/statusline.sh: the readings file that carries the rate-limit windows across chats, and the colour
# maths against tools/pace-vectors.tsv. USAGE_WATCHER_DIR points the readings file at the sandbox.
# Run: bash tools/test-statusline.sh   (STATUSLINE=<path> tests another copy.)
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
SL=${STATUSLINE:-$HERE/statusline.sh}
VECTORS=${VECTORS:-$HERE/pace-vectors.tsv}
command -v jq >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1 || { echo "SKIP: needs jq and shasum"; exit 0; }

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2] got [$3]"; fi
}

T=$(mktemp -d "${TMPDIR:-/tmp}/test-statusline-XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/cfg"
printf '{"accountUuid":"11111111-2222-3333-4444-555555555555"}\n' > "$T/cfg/.claude.json"
FP=$(printf %s "11111111-2222-3333-4444-555555555555" | shasum -a 256 | cut -c1-12)

render() {  # render <json>; runs the status line in the sandbox, prints nothing
  printf '%s' "$1" | HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" \
    USAGE_WATCHER_DIR="$T/uw" bash "$SL" > "$T/out.txt" 2>"$T/err.txt"
}
NOW=$(date +%s)
LIVE='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":10,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":42,"resets_at":'$((NOW + 7200))'},
 "seven_day":{"used_percentage":61,"resets_at":'$((NOW + 200000))'}},"session_id":"s1"}'
IDLE='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":10,"context_window_size":1000000},"session_id":"s1"}'
R="$T/uw/limits/readings-$FP.json"

# ---- a live render writes the readings file
render "$LIVE"; check "live render exits 0" 0 $?
check "readings file account" "$FP" "$(jq -r .account "$R" 2>/dev/null)"
check "readings five_hour %" 42 "$(jq -r .five_hour.used_percentage "$R" 2>/dev/null)"
check "readings seven_day %" 61 "$(jq -r .seven_day.used_percentage "$R" 2>/dev/null)"
check "readings resets_at" $((NOW + 7200)) "$(jq -r .five_hour.resets_at "$R" 2>/dev/null)"
OBS=$(jq -r .five_hour.observed_at "$R" 2>/dev/null)
[ "${OBS:-0}" -ge "$NOW" ] && [ "${OBS:-0}" -le $((NOW + 30)) ] && ok || bad "observed_at is now (got ${OBS:-none})"
check "readings mode" 600 "$(stat -c %a "$R" 2>/dev/null || stat -f %Lp "$R" 2>/dev/null)"
check "watcher dir mode" 700 "$(stat -c %a "$T/uw" 2>/dev/null || stat -f %Lp "$T/uw" 2>/dev/null)"
[ -d "$T/uw/limits" ] && ok || bad "watcher limits dir exists"
check "no stderr" "" "$(cat "$T/err.txt")"
check "no temp files left" 0 "$(find "$T/uw" -name '.tmp.*' | wc -l | tr -d ' ')"

# ---- a render without rate_limits borrows the stored values, keeping their observed time
# (timestamps have 1 s resolution: without the sleep a rewritten observed_at could not differ)
sleep 1
render "$IDLE"; check "idle render exits 0" 0 $?
check "borrowed five_hour %" 42 "$(jq -r .five_hour.used_percentage "$R" 2>/dev/null)"
check "borrowed observed_at unchanged" "$OBS" "$(jq -r .five_hour.observed_at "$R" 2>/dev/null)"

# ---- an unwritable watcher dir never breaks the render
rm -rf "$T/uw"
: > "$T/uw"
render "$LIVE"; check "blocked watcher dir: exits 0" 0 $?
[ -s "$T/out.txt" ] && ok || bad "blocked watcher dir: status line still printed"
check "blocked watcher dir: no stderr" "" "$(cat "$T/err.txt")"
rm -f "$T/uw"

# ---- the account is not guessed: no accountUuid, no readings file
rm -rf "$T/uw"
printf '{}\n' > "$T/cfg/.claude.json"
render "$LIVE"; [ -s "$T/out.txt" ] && ok || bad "unknown account: status line still printed"
check "unknown account writes no readings" 0 "$(find "$T/uw" -name 'readings-*' 2>/dev/null | wc -l | tr -d ' ')"
check "unknown account: Limit and Weekly still render" 2 "$(sed "s/$(printf '\033')\[[0-9;]*m//g" "$T/out.txt" | grep -o 'Limit\|Weekly' | wc -l | tr -d ' ')"

# ---- context bar: scaled to autoCompactWindow, capped at the harness window, else 250000
printf '{"accountUuid":"11111111-2222-3333-4444-555555555555"}\n' > "$T/cfg/.claude.json"
plain() { sed "s/$(printf '\033')\[[0-9;]*m//g" "$T/out.txt"; }
ctx_pct() { plain | sed -n 's/.*Context [^ ]* *\([0-9]*\)%.*/\1/p'; }
ctx_render() {  # ctx_render <settings-json|-> <window> <used_pct>
  if [ "$1" = "-" ]; then rm -f "$T/cfg/settings.json"; else printf '%s' "$1" > "$T/cfg/settings.json"; fi
  render '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":'"$3"',"context_window_size":'"$2"'},"session_id":"s1"}'
}
ctx_render '{"autoCompactWindow":500000}' 1000000 25; check "context: 500k setting" 50 "$(ctx_pct)"
ctx_render '{"autoCompactWindow":500000}' 200000 50; check "context: capped at the 200k window" 50 "$(ctx_pct)"
ctx_render '{}' 1000000 25; check "context: no setting falls back to 250k" 100 "$(ctx_pct)"
ctx_render - 1000000 25; check "context: no settings file falls back to 250k" 100 "$(ctx_pct)"
ctx_render '{"autoCompactWindow":"abc"}' 1000000 25; check "context: junk setting falls back to 250k" 100 "$(ctx_pct)"
ctx_render '{"autoCompactWindow":99}' 1000000 25; check "context: tiny setting falls back to 250k" 100 "$(ctx_pct)"
ctx_render '{"autoCompactWindow":99999999999999999999}' 1000000 25; check "context: huge setting falls back to 250k" 100 "$(ctx_pct)"
ctx_render '{"autoCompactWindow":"0500000"}' 1000000 25; check "context: leading zero is decimal, not octal" 50 "$(ctx_pct)"
ctx_render '{"autoCompactWindow":"0900000"}' 1000000 25; check "context: leading zero with a 9 exits 0" 0 $?
check "context: leading zero with a 9 reads as decimal (250k of 900k)" 28 "$(ctx_pct)"
ctx_render '{"autoCompactWindow":"09999999"}' 1000000 25; check "context: zero-padded setting above the window is capped" 25 "$(ctx_pct)"
rm -f "$T/cfg/settings.json"

# ---- a comma-decimal locale still reads fractional percentages (printf %.0f follows the locale)
DE_LOCALE=$(locale -a 2>/dev/null | grep -iE '^de_DE\.utf-?8$' | head -n1)
if [ -n "$DE_LOCALE" ]; then
  printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":10.4,"context_window_size":1000000},
   "rate_limits":{"five_hour":{"used_percentage":42.6,"resets_at":'$((NOW + 7200))'},
   "seven_day":{"used_percentage":61.4,"resets_at":'$((NOW + 200000))'}},"session_id":"s1"}' |
    LC_ALL=$DE_LOCALE HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" USAGE_WATCHER_DIR="$T/uw" bash "$SL" > "$T/out.txt" 2>"$T/err.txt"
  check "comma-decimal locale: Context %" 40 "$(ctx_pct)"
  check "comma-decimal locale: Limit %" 43 "$(plain | sed -n 's/.*Limit [^ ]* *\([0-9]*\)%.*/\1/p')"
  check "comma-decimal locale: Weekly %" 61 "$(plain | sed -n 's/.*Weekly [^ ]* *\([0-9]*\)%.*/\1/p')"
  check "comma-decimal locale: no stderr" "" "$(cat "$T/err.txt")"
else
  echo "note: no de_DE UTF-8 locale here, so the comma-decimal case is skipped"
fi

# ---- no shasum on the PATH: the line still renders in full, and no readings file is kept
mkdir -p "$T/bin"
for c in jq cat grep sed cut date mkdir dirname mktemp mv rm; do ln -sf "$(command -v "$c")" "$T/bin/$c"; done
BASH_BIN=$(command -v bash)
rm -rf "$T/uw"
printf '%s' "$LIVE" | PATH="$T/bin" HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" USAGE_WATCHER_DIR="$T/uw" \
  "$BASH_BIN" "$SL" > "$T/out.txt" 2>"$T/err.txt"
check "no shasum: exits 0" 0 $?
check "no shasum: Limit and Weekly still render" 2 "$(plain | grep -o 'Limit\|Weekly' | wc -l | tr -d ' ')"
check "no shasum: no readings file" 0 "$(find "$T/uw" -name 'readings-*' 2>/dev/null | wc -l | tr -d ' ')"
check "no shasum: no stderr" "" "$(cat "$T/err.txt")"

# ---- bars: the fill and empty glyphs, with the elapsed cell underlined
mk_render() {  # mk_render <five_pct> <five_elapsed_s> <week_pct> <week_elapsed_s>
  render '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":5,"context_window_size":1000000},
   "rate_limits":{"five_hour":{"used_percentage":'"$1"',"resets_at":'$((NOW + 18000 - $2))'},
   "seven_day":{"used_percentage":'"$3"',"resets_at":'$((NOW + 604800 - $4))'}},"session_id":"s1"}'
}
limit_bar() { plain | sed -n 's/.*Limit \([^ ]*\) .*/\1/p'; }
weekly_bar() { plain | sed -n 's/.*Weekly \([^ ]*\) .*/\1/p'; }
mk_render 30 9000 20 302400; check "bars: 5h 30% is 4 filled cells and nothing else" "▓▓▓▓░░░░░░░░" "$(limit_bar)"
check "bars: weekly 20% is 2 filled cells and nothing else" "▓▓░░░░░░░░░░" "$(weekly_bar)"
mk_render 30 9000 45 151200; check "bars: weekly 45% is 5 filled cells" "▓▓▓▓▓░░░░░░░" "$(weekly_bar)"

# ---- the prompt-cache glyph sits between the model and Context
CACHE_WARM='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":5,"context_window_size":1000000},
 "prompt_cache":{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":'$((NOW + 3000))'},"session_id":"s1"}'
render "$CACHE_WARM"
check "cache glyph between model and Context" 1 "$(plain | grep -cE '^\[Opus\] +(●|◕|◑|◔|○) +Context ')"
check "no cache glyph after the context bar" 0 "$(plain | sed 's/.*Context //' | grep -cE '●|◕|◑|◔')"
render "$IDLE"
check "no cache field: model then Context, nothing between" 1 "$(plain | grep -cE '^\[Opus\] +Context ')"

# ---- an account with no 5h window leaves the 5h segment out; one that may have a window keeps its placeholder
WEEK_ONLY='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":5,"context_window_size":1000000},
 "rate_limits":{"seven_day":{"used_percentage":1,"resets_at":'$((NOW + 500000))'}},"session_id":"s1"}'
seg_count() { plain | grep -o "$1" | wc -l | tr -d ' '; }
store_five() {  # store_five <observed_seconds_ago|none>: readings file holding a lapsed 5h window, no %
  rm -rf "$T/uw"; mkdir -p "$T/uw/limits"
  if [ "$1" = none ]; then printf '{"account":"%s"}\n' "$FP" > "$R"
  else printf '{"account":"%s","five_hour":{"resets_at":%s,"observed_at":%s}}\n' "$FP" $((NOW - $1 + 600)) $((NOW - $1)) > "$R"; fi
}
store_five none;   render "$WEEK_ONLY"; check "no 5h ever, live weekly: no Limit segment" 0 "$(seg_count Limit)"
check "no 5h ever, live weekly: Weekly still shown" 1 "$(seg_count Weekly)"
store_five 25000;  render "$WEEK_ONLY"; check "5h last seen 7 h ago, live weekly: no Limit segment" 0 "$(seg_count Limit)"
store_five 3600;   render "$WEEK_ONLY"; check "5h last seen 1 h ago, live weekly: placeholder kept" 1 "$(seg_count Limit)"
store_five 25000;  render "$IDLE";      check "5h absent, no weekly either: Limit placeholder kept" 1 "$(seg_count Limit)"
check "5h absent, no weekly either: Weekly placeholder kept" 1 "$(seg_count Weekly)"
store_five 25000;  render "$LIVE";      check "live 5h reading is always shown" 1 "$(seg_count Limit)"
check "no stderr after the 5h-absent cases" "" "$(cat "$T/err.txt")"

# ---- colour maths against the vectors generated from the same function
if [ -r "$VECTORS" ]; then
  eval "$(sed -n '/^rate_color_for() {/,/^}/p' "$SL")"
  rows=0 mismatches=0
  while IFS=$'\t' read -r used el warn damp col over; do
    case $used in '#'*|'') continue ;; esac
    got=$(rate_color_for "$used" "$el" "$warn" "$damp" | sed -n 's/.*38;5;\([0-9]*\)m.*/\1/p')
    rows=$((rows + 1))
    if [ "$got" != "$col" ]; then mismatches=$((mismatches + 1)); [ "$mismatches" -le 5 ] && bad "vector $used/$el/$warn: expected $col got $got"; fi
  done < "$VECTORS"
  [ "$rows" -gt 6000 ] && ok || bad "vectors: only $rows rows"
  [ "$mismatches" -eq 0 ] && ok || bad "vectors: $mismatches mismatches"
else
  bad "vectors file missing: $VECTORS"
fi

echo "test-statusline: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
