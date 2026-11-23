#!/bin/bash
# SessionStart hook (matcher "startup"): once a week, ask GitHub for the repo's latest release and, while the
# checkout is behind it, print a one-line reminder at every session start. Also the engine of /skip-update and
# /disable-update.
#   update-check.sh [--update <slash-command>] [<checkout>]            the hook (reads the SessionStart input on stdin)
#   update-check.sh [--update <cmd>] --skip [<checkout>]               skip the newest known release
#   update-check.sh [--update <cmd>] --toggle [<checkout>]             turn the notices off, or back on
# <checkout> defaults to the repo this script lives in (its link resolved); another repo's setup passes its own, and
# --update names that repo's update command (default /update-toolkit). The GitHub owner and name come from the
# checkout's origin URL, so no repo is written into the script. With no --update and no checkout (this repo's own wiring)
# the reminder names the /skip-update and /disable-update skills; with either, it prints this script's --skip and
# --toggle commands instead, since the script then serves another repo, which has no such skills here.
#
# Why: the install is a live checkout (ADR 0014), so an update is a fast-forward pull, and nothing tells a machine
# that a release exists. What it does: the local version is the highest plain version tag merged into HEAD; the
# latest is GitHub's "latest" release (a pre-release or draft never counts), fetched at most once in 7 days with one
# unauthenticated GET and a 3 s cap, cached in ~/.local/state/claude-update-check/<owner>__<repo>.json with the time
# of the check (a failed attempt is retried after a day), the skipped version and the off switch. Every startup reads that
# cache, no network, and prints {"systemMessage": ...} when the latest is newer than the local version and newer
# than the skipped one. It sends nothing about the user or the machine.
#
# A checkout with no release tag (every install made before the first release) counts as version none, so the first
# release is announced to it too; /update-toolkit then brings the tag. Known gaps: tags must be plain numeric
# versions (v1.2.3); anything else is ignored. Only github.com origins (an ssh
# alias like github.com-work works; a port in the URL does not). A private repo answers the unauthenticated request
# with 404, so it never notifies. A checkout that is ahead of its last release tag is compared by that tag. Fails open: no set -e, every hook path
# exits 0, and no output means nothing to say. bash 3.2.

export PATH="$PATH:/usr/bin:/bin"
UPDATE_CMD=/update-toolkit MODE=hook DIR="" OWN=1  # OWN: no --update and no checkout given
while [ $# -gt 0 ]; do
  case $1 in
    --update) [ $# -ge 2 ] || exit 0; UPDATE_CMD=$2; OWN=0; shift ;;
    --skip) MODE=skip ;;
    --toggle) MODE=toggle ;;
    *) DIR=$1; OWN=0 ;;
  esac
  shift
done

# quit <text>: the hook says nothing; /skip-update and /disable-update tell the user why it did not work.
quit() { [ "$MODE" = hook ] && exit 0; printf '%s\n' "$1"; exit 1; }
command -v jq >/dev/null 2>&1 || quit "update-check needs jq."
command -v git >/dev/null 2>&1 || quit "update-check needs git."
[ -n "${HOME:-}" ] || quit "update-check needs HOME."

if [ -z "$DIR" ]; then
  S=${BASH_SOURCE[0]}
  while [ -L "$S" ]; do
    L=$(readlink "$S") || break
    case $L in /*) S=$L ;; *) S=${S%/*}/$L ;; esac
  done
  DIR=${S%/*}/..
fi
DIR=$(cd -P "$DIR" 2>/dev/null && pwd -P) || quit "No such checkout."

url=$(git -C "$DIR" remote get-url origin 2>/dev/null)
case $url in *github.com*) ;; *) quit "This checkout has no github.com origin." ;; esac
slug=$(printf '%s' "$url" | sed -E 's#^(https?://|ssh://)?([^@/]+@)?github\.com[A-Za-z0-9-]*[:/]+##; s#/*$##; s#\.git$##')
printf '%s' "$slug" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || quit "Cannot read the GitHub repo from the origin URL."
name=${slug#*/}

if [ "$OWN" = 1 ]; then
  skip_cmd="/skip-update there"; off_cmd=/disable-update; again="/disable-update again"
else
  self=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/${BASH_SOURCE[0]##*/}
  q_self=$(printf '%q' "$self"); q_dir=$(printf '%q' "$DIR")  # paste-safe: a path may hold a space
  skip_cmd="bash $q_self --skip $q_dir"; off_cmd="bash $q_self --toggle $q_dir"; again="the same command again"
fi

ver_ok() { printf '%s' "$1" | grep -Eq '^v?[0-9]+(\.[0-9]+)*$'; }
newer() {  # newer <a> <b>: a is a later version than b
  [ "${1#v}" != "${2#v}" ] && [ "$(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | tail -n 1)" = "${1#v}" ]
}

loc=$(git -C "$DIR" tag --merged HEAD --list 'v[0-9]*' '[0-9]*' --sort=-v:refname 2>/dev/null \
  | grep -E '^v?[0-9]+(\.[0-9]+)*$' | head -n 1)
ver_ok "$loc" || loc=v0.0.0  # no release tag yet (every install made before the first release): any release is newer
shown=${loc#v}; [ "$loc" = v0.0.0 ] && shown=none

SD="$HOME/.local/state/claude-update-check"
SF="$SD/${slug%/*}__$name.json"
st=$(cat "$SF" 2>/dev/null)
printf '%s' "$st" | jq -e 'type == "object"' >/dev/null 2>&1 || st='{}'
jv() { printf '%s' "$st" | jq -r "(.$1 // empty) | tostring" 2>/dev/null; }
checked=$(jv checked); case $checked in '' | *[!0-9]*) checked=0 ;; esac
latest=$(jv latest);   ver_ok "$latest" || latest=""
skipped=$(jv skipped); ver_ok "$skipped" || skipped=""
disabled=$(jv disabled); [ "$disabled" = true ] || disabled=false

save() {
  local tmp
  (umask 077; mkdir -p "$SD") 2>/dev/null || return 1
  tmp=$(mktemp "$SD/.tmp-XXXXXX" 2>/dev/null) || return 1
  jq -nc --argjson c "$checked" --arg l "$latest" --arg s "$skipped" --argjson d "$disabled" \
    '{checked: $c, latest: $l, skipped: $s, disabled: $d}' >"$tmp" 2>/dev/null && mv "$tmp" "$SF" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
}

case $MODE in
  skip)
    if [ -n "$latest" ] && newer "$latest" "$loc"; then
      skipped=$latest
      save || quit "Could not write $SF."
      printf '%s\n' "Skipped $name ${latest#v}. You'll hear about the next release."
    else
      if [ "$shown" = none ]; then printf '%s\n' "Nothing to skip: no release is known for $name yet."
      else printf '%s\n' "Nothing to skip: $name $shown is the latest release known."; fi
    fi
    exit 0 ;;
  toggle)
    if [ "$disabled" = true ]; then disabled=false; word=on; other=off; else disabled=true; word=off; other=on; fi
    save || quit "Could not write $SF."
    printf '%s\n' "Update notifications for $name are $word. Run $again to turn them $other."
    exit 0 ;;
esac

# The hook proper.
src=$(cat 2>/dev/null | jq -r 'if type == "object" then (.source // empty) | strings else empty end' 2>/dev/null)
[ "$src" = startup ] || exit 0
[ "$disabled" = true ] && exit 0

now=$(date +%s)
if [ $((now - checked)) -ge 604800 ] && command -v curl >/dev/null 2>&1; then
  tag=$(curl -fsS --max-time 3 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$slug/releases/latest" 2>/dev/null \
    | jq -r 'if type == "object" then (.tag_name // empty) | strings else empty end' 2>/dev/null)
  if ver_ok "$tag"; then latest=$tag; checked=$now; else checked=$((now - 518400)); fi  # a failed attempt retries in a day
  save
fi

[ -n "$latest" ] && newer "$latest" "$loc" || exit 0
if [ -n "$skipped" ] && ! newer "$latest" "$skipped"; then exit 0; fi
msg="Update available for \"$name\" ($shown->${latest#v}). Run $UPDATE_CMD in the checkout to install it, $skip_cmd to skip it or $off_cmd to turn these notices off."
jq -nc --arg m "$msg" '{systemMessage: $m}' 2>/dev/null
exit 0
