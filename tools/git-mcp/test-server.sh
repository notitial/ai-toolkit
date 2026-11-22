#!/bin/bash
# Tests for tools/git-mcp/server.js (SERVER=<path> tests another copy). Run: bash tools/git-mcp/test-server.sh
# Each case starts the server, sends one tools/call over stdio and reads the answer: `ok` (git ran and succeeded) or
# `err` (refused by the server, or git failed), and optionally a text the answer must hold. The repos live in a temp
# folder, HOME points there too, so no global git config or credential is read, and the "remote" is a bare repo
# beside them. Needs node and git, nothing else.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SERVER="${SERVER:-$HERE/server.js}"
command -v node >/dev/null 2>&1 || { echo "node required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/git-mcp-XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home"
# The script's own git calls must not follow the caller's environment either (run from a git hook, say).
for v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
export XDG_CONFIG_HOME="$T/home/.config"
printf '[user]\n\tname = Test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n[advice]\n\tdetachedHead = false\n' > "$T/home/.gitconfig"
R="$T/repo"
PASS=0
FAIL=0

# Prints the outcome on line 1 (ok, err, or rpc-error), then the answer's text.
PARSE='let b="";process.stdin.on("data",(d)=>{b+=d}).on("end",()=>{const m=JSON.parse(b.trim().split("\n").pop());if(m.error){console.log("rpc-error\n"+m.error.message);return}console.log((m.result.isError?"err":"ok")+"\n"+m.result.content[0].text)})'
raw() { HOME="$T/home" node "$SERVER"; }  # stdin: JSON-RPC lines; stdout: the server's lines
call() {  # call <tool> <arguments json>
  printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" | raw | node -e "$PARSE"
}
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; shift; printf '%s\n' "$@" | head -n 6 | sed 's/^/  /'; }
expect() {  # expect <ok|err> <label> <tool> <arguments json> [<text the answer must hold>]
  local out
  out=$(call "$3" "$4" 2>&1)
  if [ "${out%%$'\n'*}" != "$1" ]; then bad "$2: want $1" "$out"; return; fi
  if [ -n "${5:-}" ]; then case $out in *"$5"*) ;; *) bad "$2: answer lacks '$5'" "$out"; return ;; esac; fi
  PASS=$((PASS + 1))
}
is() {  # is <label> <command…>: a plain check of the repo's state
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else bad "$label ($*)"; fi
}
holds() { case $2 in *"$3"*) PASS=$((PASS + 1)) ;; *) bad "$1: lacks '$3'" "$2" ;; esac; }
lacks() { case $2 in *"$3"*) bad "$1: holds '$3'" "$2" ;; *) PASS=$((PASS + 1)) ;; esac; }
g() { HOME="$T/home" git -C "$R" "$@"; }

# ---- the protocol ------------------------------------------------------------------------------------------------
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"ping"}' '{"jsonrpc":"2.0","id":4,"method":"resources/list"}' 'not json' | raw)
holds "initialize names the server" "$out" '"serverInfo":{"name":"git-mcp"'
holds "initialize echoes the protocol version" "$out" '"protocolVersion":"2025-06-18"'
out2=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2999-01-01"}}' | raw)
holds "an unknown protocol version gets one the server speaks" "$out2" '"protocolVersion":"2025-06-18"'
holds "ping answers" "$out" '{"jsonrpc":"2.0","id":3,"result":{}}'
holds "unknown method" "$out" '"code":-32601'
holds "parse error" "$out" '"code":-32700'
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 5 ] && PASS=$((PASS + 1)) || bad "a notification gets no answer: want 5 lines" "$out"
names=$(printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | raw | node -e 'let b="";process.stdin.on("data",(d)=>{b+=d}).on("end",()=>{const t=JSON.parse(b).result.tools;console.log(t.map((x)=>x.name).sort().join(" "));console.log(t.every((x)=>x.inputSchema.additionalProperties===false&&x.inputSchema.required[0]==="path")?"closed":"open")})')
WANT="git_add git_blame git_branch git_checkout git_cherry_pick git_clean git_clone git_commit git_diff git_fetch git_init git_log git_merge git_pull git_push git_rebase git_reflog git_remote git_reset git_show git_stash git_status git_tag"
[ "${names%%$'\n'*}" = "$WANT" ] && PASS=$((PASS + 1)) || bad "tool list" "$names"
holds "every schema is closed and requires path" "$names" "closed"
expect err "arguments null" git_status 'null' "must be an object"
is "no dependency: only node: modules are loaded" sh -c "! grep -n 'require(' '$SERVER' | grep -v \"require('node:\" | grep -v 'require.main'"

# ---- a round trip per tool ---------------------------------------------------------------------------------------
expect ok "init" git_init "{\"path\":\"$R\"}" "Initialized"
is "init made a repo on main" test "$(g symbolic-ref --short HEAD)" = main
expect ok "status, empty repo" git_status "{\"path\":\"$R\"}" "## No commits yet on main"
printf 'one\ntwo\n' > "$R/a.txt"
printf '{}\n' > "$R/package-lock.json"
expect ok "status shows untracked" git_status "{\"path\":\"$R\"}" "?? a.txt"
expect ok "status without untracked" git_status "{\"path\":\"$R\",\"includeUntracked\":false}" "## No commits"
out=$(call git_status "{\"path\":\"$R\",\"includeUntracked\":false}")
lacks "status without untracked hides them" "$out" "a.txt"
expect ok "add paths" git_add "{\"path\":\"$R\",\"paths\":[\"a.txt\",\"package-lock.json\"]}"
expect err "add nothing" git_add "{\"path\":\"$R\"}" "give paths"
expect ok "commit" git_commit "{\"path\":\"$R\",\"message\":\"first\\n\\nbody line\"}" "first"
is "commit body kept" test "$(g log -1 --format=%b)" = "body line"
expect ok "commit, message starting with a dash" git_commit "{\"path\":\"$R\",\"message\":\"--amend is only text\",\"allowEmpty\":true}"
is "the dash message is the subject" test "$(g log -1 --format=%s)" = "--amend is only text"
is "and nothing was amended" test "$(g rev-list --count HEAD)" = 2
printf 'one\ntwo\nthree\n' > "$R/a.txt"
printf '{"x":1}\n' > "$R/package-lock.json"
printf 'new\n' > "$R/b.txt"
expect ok "diff" git_diff "{\"path\":\"$R\"}" "+three"
out=$(call git_diff "{\"path\":\"$R\"}")
lacks "diff leaves lock files out" "$out" "package-lock.json"
expect ok "diff with lock files" git_diff "{\"path\":\"$R\",\"autoExclude\":false}" "package-lock.json"
expect ok "diff name only" git_diff "{\"path\":\"$R\",\"nameOnly\":true}" "a.txt"
expect ok "diff stat" git_diff "{\"path\":\"$R\",\"stat\":true}" "1 file changed"
expect ok "diff with untracked" git_diff "{\"path\":\"$R\",\"includeUntracked\":true}" "+new"
expect ok "diff names with untracked" git_diff "{\"path\":\"$R\",\"includeUntracked\":true,\"nameOnly\":true}" "b.txt"
expect ok "diff limited to a path" git_diff "{\"path\":\"$R\",\"paths\":[\"b.txt\"]}" "ok (no output)"
expect ok "commit with filesToStage" git_commit "{\"path\":\"$R\",\"message\":\"second\",\"filesToStage\":[\"a.txt\",\"b.txt\"],\"author\":{\"name\":\"Ann\",\"email\":\"ann@example.com\"}}" "second"
is "author set" test "$(g log -1 --format=%an)" = Ann
printf 'four\n' >> "$R/a.txt"
printf 'newer\n' >> "$R/b.txt"
expect ok "add update keeps to its paths" git_add "{\"path\":\"$R\",\"update\":true,\"paths\":[\"b.txt\"]}"
is "only the named file is staged" test "$(g diff --cached --name-only)" = b.txt
g reset --quiet --hard
printf 'lock\n' > "$R/yarn.lock"
mkdir "$R/nested" && HOME="$T/home" git init -q "$R/nested"
out=$(call git_diff "{\"path\":\"$R\",\"includeUntracked\":true}")
lacks "an untracked lock file is left out too" "$out" "yarn.lock"
holds "an untracked folder with its own repo is named, not diffed" "$out" "nested/"
rm -rf "$R/yarn.lock" "$R/nested"
expect ok "diff staged" git_diff "{\"path\":\"$R\",\"staged\":true}" "ok (no output)"
expect ok "diff source and target" git_diff "{\"path\":\"$R\",\"source\":\"HEAD~1\",\"target\":\"HEAD\"}" "+three"
expect ok "diff target only" git_diff "{\"path\":\"$R\",\"target\":\"HEAD~2\",\"paths\":[\"a.txt\"]}" "+three"
expect ok "log" git_log "{\"path\":\"$R\"}" "second"
expect ok "log oneline, one entry" git_log "{\"path\":\"$R\",\"oneline\":true,\"maxCount\":1}" "second"
out=$(call git_log "{\"path\":\"$R\",\"oneline\":true,\"maxCount\":1}")
lacks "log maxCount" "$out" "first"
expect ok "log by file, author and grep" git_log "{\"path\":\"$R\",\"filePath\":\"b.txt\",\"author\":\"Ann\",\"grep\":\"sec\",\"stat\":true}" "b.txt"
expect ok "log of a ref with patch" git_log "{\"path\":\"$R\",\"branch\":\"HEAD~1\",\"patch\":true,\"skip\":1,\"since\":\"2000-01-01\"}" "+two"
expect ok "show a commit" git_show "{\"path\":\"$R\",\"object\":\"HEAD\",\"stat\":true}" "b.txt"
expect ok "show a file at a revision" git_show "{\"path\":\"$R\",\"object\":\"HEAD~2\",\"filePath\":\"a.txt\"}" "two"
expect err "show takes no absolute file path" git_show "{\"path\":\"$R\",\"object\":\"HEAD\",\"filePath\":\"$R/a.txt\"}" "relative to path"
expect ok "show reads the file path from path, not from the repo top" git_show "{\"path\":\"$R/.git/..\",\"object\":\"HEAD\",\"filePath\":\"./b.txt\"}" "new"
expect ok "show raw" git_show "{\"path\":\"$R\",\"object\":\"HEAD\",\"format\":\"raw\"}" "tree "
expect ok "blame" git_blame "{\"path\":\"$R\",\"filePath\":\"a.txt\",\"startLine\":3,\"endLine\":3}" "three"
out=$(call git_blame "{\"path\":\"$R\",\"filePath\":\"a.txt\",\"startLine\":3}")
lacks "blame range" "$out" "two"
expect ok "reflog" git_reflog "{\"path\":\"$R\",\"maxCount\":2}" "commit: second"
expect ok "a folder inside the repo works as path" git_status "{\"path\":\"$R/.git/..\"}" "## main"

expect ok "branch create" git_branch "{\"path\":\"$R\",\"mode\":\"create\",\"branchName\":\"feature/x\",\"startPoint\":\"HEAD~1\"}"
expect ok "branch list" git_branch "{\"path\":\"$R\"}" "feature/x"
expect ok "branch list ignores a name (no mode: list)" git_branch "{\"path\":\"$R\",\"branchName\":\"never-made\"}" "main"
is "list mode made no branch" sh -c "! git -C '$R' rev-parse --verify -q never-made"
expect ok "branch list with limit" git_branch "{\"path\":\"$R\",\"limit\":1}" "[first 1 shown]"
expect ok "branch list merged" git_branch "{\"path\":\"$R\",\"merged\":true,\"all\":true}" "feature/x"
expect ok "branch list not merged into a ref" git_branch "{\"path\":\"$R\",\"noMerged\":\"feature/x\"}" "main"
expect ok "branch show-current" git_branch "{\"path\":\"$R\",\"mode\":\"show-current\"}" "main"
expect ok "branch rename" git_branch "{\"path\":\"$R\",\"mode\":\"rename\",\"branchName\":\"feature/x\",\"newBranchName\":\"feature/y\"}"
expect err "branch create over an existing one" git_branch "{\"path\":\"$R\",\"mode\":\"create\",\"branchName\":\"main\"}" "already exists"
expect err "branch create needs a name" git_branch "{\"path\":\"$R\",\"mode\":\"create\"}" "branchName is required"
expect ok "checkout a branch" git_checkout "{\"path\":\"$R\",\"target\":\"feature/y\"}"
is "on feature/y" test "$(g branch --show-current)" = feature/y
expect ok "checkout -b" git_checkout "{\"path\":\"$R\",\"target\":\"topic\",\"createBranch\":true}"
printf 'topic\n' > "$R/t.txt"
expect ok "add all" git_add "{\"path\":\"$R\",\"all\":true}"
expect ok "commit on topic" git_commit "{\"path\":\"$R\",\"message\":\"topic work\"}"
TOPIC=$(g rev-parse HEAD)
printf 'scratch\n' >> "$R/t.txt"
expect ok "checkout paths restores a file" git_checkout "{\"path\":\"$R\",\"target\":\"HEAD\",\"paths\":[\"t.txt\"]}"
is "file restored" test "$(cat "$R/t.txt")" = topic
expect ok "checkout main" git_checkout "{\"path\":\"$R\",\"target\":\"main\"}"
expect ok "merge" git_merge "{\"path\":\"$R\",\"branch\":\"topic\",\"noFastForward\":true,\"message\":\"merge topic\"}"
is "merge commit made" test "$(g log -1 --format=%s)" = "merge topic"
expect err "merge abort with no merge" git_merge "{\"path\":\"$R\",\"abort\":true}"
expect err "merge needs a branch" git_merge "{\"path\":\"$R\"}" "branch is required"
expect ok "branch delete" git_branch "{\"path\":\"$R\",\"mode\":\"delete\",\"branchName\":\"topic\"}"
expect ok "cherry-pick" git_cherry_pick "{\"path\":\"$R\",\"commits\":[\"$TOPIC\"],\"noCommit\":true}"
expect err "cherry-pick needs commits" git_cherry_pick "{\"path\":\"$R\"}" "commits is required"
expect err "cherry-pick abort with none running" git_cherry_pick "{\"path\":\"$R\",\"abort\":true}"
expect ok "checkout feature/y again" git_checkout "{\"path\":\"$R\",\"target\":\"feature/y\"}"
expect ok "rebase" git_rebase "{\"path\":\"$R\",\"upstream\":\"main\"}"
is "rebased onto main" g merge-base --is-ancestor main feature/y
expect err "rebase start needs upstream" git_rebase "{\"path\":\"$R\"}" "upstream is required"
expect err "interactive rebase" git_rebase "{\"path\":\"$R\",\"upstream\":\"main\",\"interactive\":true}" "not offered"
expect err "rebase abort with none running" git_rebase "{\"path\":\"$R\",\"mode\":\"abort\"}"
expect ok "checkout main again" git_checkout "{\"path\":\"$R\",\"target\":\"main\"}"

printf 'staged\n' > "$R/s.txt"
g add s.txt
expect ok "reset paths unstages" git_reset "{\"path\":\"$R\",\"paths\":[\"s.txt\"]}"
is "unstaged, file kept" sh -c "test -f '$R/s.txt' && test -z \"\$(git -C '$R' diff --cached --name-only)\""
expect err "reset paths with a mode" git_reset "{\"path\":\"$R\",\"mode\":\"hard\",\"paths\":[\"s.txt\"]}" "mode mixed"
HEAD_BEFORE=$(g rev-parse HEAD)
expect ok "reset soft" git_reset "{\"path\":\"$R\",\"mode\":\"soft\",\"target\":\"HEAD~1\"}"
is "HEAD moved back" test "$(g rev-parse HEAD)" = "$(g rev-parse "$HEAD_BEFORE~1")"
expect ok "reset hard (the hook, not the server, holds this back)" git_reset "{\"path\":\"$R\",\"mode\":\"hard\",\"target\":\"$HEAD_BEFORE\"}"
expect ok "clean dry run" git_clean "{\"path\":\"$R\",\"dryRun\":true}" "Would remove s.txt"
is "dry run removed nothing" test -f "$R/s.txt"
expect ok "clean dry run wins over force" git_clean "{\"path\":\"$R\",\"dryRun\":true,\"force\":true}" "Would remove"
is "still nothing removed" test -f "$R/s.txt"
expect err "clean with neither flag" git_clean "{\"path\":\"$R\"}" "set dryRun"
expect ok "stash push" git_stash "{\"path\":\"$R\",\"includeUntracked\":true,\"message\":\"wip one\"}"
is "stashed" test ! -f "$R/s.txt"
expect ok "stash list" git_stash "{\"path\":\"$R\",\"mode\":\"list\",\"limit\":5}" "wip one"
expect ok "stash apply" git_stash "{\"path\":\"$R\",\"mode\":\"apply\",\"stashRef\":\"stash@{0}\"}"
expect ok "clean force" git_clean "{\"path\":\"$R\",\"force\":true}" "Removing s.txt"
expect ok "stash pop" git_stash "{\"path\":\"$R\",\"mode\":\"pop\"}"
expect ok "stash again" git_stash "{\"path\":\"$R\",\"mode\":\"push\",\"includeUntracked\":true}"
expect err "stash drop needs a ref" git_stash "{\"path\":\"$R\",\"mode\":\"drop\"}" "stashRef is required"
expect ok "stash drop" git_stash "{\"path\":\"$R\",\"mode\":\"drop\",\"stashRef\":\"stash@{0}\"}"
expect ok "stash clear" git_stash "{\"path\":\"$R\",\"mode\":\"clear\"}"

expect ok "tag create" git_tag "{\"path\":\"$R\",\"mode\":\"create\",\"tagName\":\"v1\"}"
expect ok "tag create annotated at a commit" git_tag "{\"path\":\"$R\",\"mode\":\"create\",\"tagName\":\"v0\",\"commit\":\"HEAD~1\",\"message\":\"old one\"}"
expect ok "tag list" git_tag "{\"path\":\"$R\"}" "old one"
expect err "tag verify, unsigned" git_tag "{\"path\":\"$R\",\"mode\":\"verify\",\"tagName\":\"v0\"}"
expect ok "tag delete" git_tag "{\"path\":\"$R\",\"mode\":\"delete\",\"tagName\":\"v0\"}"

HOME="$T/home" git init -q --bare "$T/remote.git"
expect ok "remote add" git_remote "{\"path\":\"$R\",\"mode\":\"add\",\"name\":\"origin\",\"url\":\"$T/remote.git\"}"
expect ok "remote list" git_remote "{\"path\":\"$R\"}" "remote.git (push)"
expect ok "remote get-url" git_remote "{\"path\":\"$R\",\"mode\":\"get-url\",\"name\":\"origin\"}" "remote.git"
expect ok "remote add a second" git_remote "{\"path\":\"$R\",\"mode\":\"add\",\"name\":\"up\",\"url\":\"https://example.com/o/r.git\"}"
expect ok "remote set-url" git_remote "{\"path\":\"$R\",\"mode\":\"set-url\",\"name\":\"up\",\"url\":\"git@example.com:o/r.git\",\"push\":true}"
expect ok "remote rename" git_remote "{\"path\":\"$R\",\"mode\":\"rename\",\"name\":\"up\",\"newName\":\"up2\"}"
expect ok "remote remove" git_remote "{\"path\":\"$R\",\"mode\":\"remove\",\"name\":\"up2\"}"
expect ok "push dry run" git_push "{\"path\":\"$R\",\"remote\":\"origin\",\"branch\":\"main\",\"dryRun\":true}"
is "dry run pushed nothing" sh -c "! git -C '$T/remote.git' rev-parse --verify -q main"
expect ok "push with upstream" git_push "{\"path\":\"$R\",\"remote\":\"origin\",\"branch\":\"main\",\"setUpstream\":true,\"tags\":true}"
is "pushed" test "$(git -C "$T/remote.git" rev-parse main)" = "$(g rev-parse main)"
expect ok "push to another remote branch" git_push "{\"path\":\"$R\",\"remote\":\"origin\",\"branch\":\"feature/y\",\"remoteBranch\":\"review/y\"}"
is "remote branch made" git -C "$T/remote.git" rev-parse --verify -q review/y
expect ok "push HEAD to a remote branch" git_push "{\"path\":\"$R\",\"remote\":\"origin\",\"remoteBranch\":\"side\"}"
is "side made from HEAD" test "$(git -C "$T/remote.git" rev-parse side)" = "$(g rev-parse HEAD)"
# The hooks pass a dry run whatever else it carries, so a dry run must change nothing on the remote.
expect ok "dry run with force" git_push "{\"path\":\"$R\",\"remote\":\"origin\",\"branch\":\"feature/y\",\"remoteBranch\":\"side\",\"dryRun\":true,\"force\":true}"
is "the forced dry run moved nothing" test "$(git -C "$T/remote.git" rev-parse side)" = "$(g rev-parse HEAD)"
expect ok "dry run with delete" git_push "{\"path\":\"$R\",\"remote\":\"origin\",\"remoteBranch\":\"side\",\"dryRun\":true,\"delete\":true}"
is "the delete dry run deleted nothing" git -C "$T/remote.git" rev-parse --verify -q side
expect ok "push delete" git_push "{\"path\":\"$R\",\"remote\":\"origin\",\"delete\":true,\"remoteBranch\":\"side\"}"
is "remote branch gone" sh -c "! git -C '$T/remote.git' rev-parse --verify -q side"
expect err "push delete needs a branch" git_push "{\"path\":\"$R\",\"remote\":\"origin\",\"delete\":true}" "delete needs"
# No remote is chosen for the caller: the hooks judge the remote git itself would pick, so a branch needs its remote named.
expect err "push a branch with no remote" git_push "{\"path\":\"$R\",\"branch\":\"feature/y\"}" "remote is required"
expect err "push a remote branch with no remote" git_push "{\"path\":\"$R\",\"remoteBranch\":\"main\"}" "remote is required"
expect err "push delete with no remote" git_push "{\"path\":\"$R\",\"delete\":true,\"branch\":\"review/y\"}" "remote is required"
expect ok "plain push, nothing named" git_push "{\"path\":\"$R\"}"
# A named branch goes to the branch of that name, whatever push.default or the branch's upstream says.
g config push.default upstream
g branch --quiet --track tracks-main origin/main
expect ok "push a branch that tracks main" git_push "{\"path\":\"$R\",\"remote\":\"origin\",\"branch\":\"tracks-main\"}"
is "it went to its own name, not to main" git -C "$T/remote.git" rev-parse --verify -q tracks-main
# branch HEAD sends no refspec: with push.default=upstream git then pushes to the upstream, which is what the guard judged.
g checkout --quiet tracks-main
g commit --quiet --allow-empty -m "on tracks-main"
expect ok "push HEAD follows push.default" git_push "{\"path\":\"$R\",\"remote\":\"origin\",\"branch\":\"HEAD\"}"
is "HEAD went to the upstream the guard would resolve" test "$(git -C "$T/remote.git" rev-parse main)" = "$(g rev-parse tracks-main)"
is "and not to the branch's own name" test "$(git -C "$T/remote.git" rev-parse tracks-main)" != "$(g rev-parse tracks-main)"
g checkout --quiet main
g merge --quiet --ff-only tracks-main
g config --unset push.default
expect ok "push accepts confirmed" git_push "{\"path\":\"$R\",\"confirmed\":true,\"dryRun\":true}"
expect ok "clone" git_clone "{\"path\":\"$T/clone\",\"url\":\"$T/remote.git\",\"branch\":\"main\"}"
is "cloned" test -f "$T/clone/a.txt"
expect ok "clone a file URL, shallow and bare" git_clone "{\"path\":\"$T/clone2.git\",\"url\":\"file://$T/remote.git\",\"depth\":1,\"bare\":true}"
printf 'more\n' >> "$T/clone/a.txt"
HOME="$T/home" git -C "$T/clone" commit -q -am "from the clone"
HOME="$T/home" git -C "$T/clone" push -q origin main
expect ok "fetch" git_fetch "{\"path\":\"$R\",\"prune\":true,\"tags\":true}"
is "fetched" test "$(g rev-parse origin/main)" = "$(git -C "$T/clone" rev-parse HEAD)"
expect ok "pull, fast-forward only" git_pull "{\"path\":\"$R\",\"fastForwardOnly\":true,\"branch\":\"main\"}"
is "pulled" test "$(g rev-parse main)" = "$(git -C "$T/clone" rev-parse HEAD)"
expect ok "pull with rebase, nothing new" git_pull "{\"path\":\"$R\",\"rebase\":true}"
expect ok "checkout a branch that only the remote has" git_checkout "{\"path\":\"$R\",\"target\":\"review/y\"}"
is "a local branch was made for it" test "$(g branch --show-current)" = review/y
expect ok "back to main" git_checkout "{\"path\":\"$R\",\"target\":\"main\"}"
printf 'unsaved\n' >> "$R/a.txt"
expect err "checkout target is never a path" git_checkout "{\"path\":\"$R\",\"target\":\".\"}"
is "the unsaved change is still there" sh -c "grep -q unsaved '$R/a.txt'"
g checkout --quiet -- a.txt

# Two calls for one repo in one stream run one after the other: the log, sent with the commit, already shows it.
printf 'queued\n' > "$R/q.txt"
out=$(printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"git_commit\",\"arguments\":{\"path\":\"$R\",\"message\":\"queued commit\",\"filesToStage\":[\"q.txt\"]}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"git_log\",\"arguments\":{\"path\":\"$R\",\"maxCount\":1,\"oneline\":true}}}" | raw | grep -F '"id":2,')
holds "a call waits for the one before it on the same path" "$out" "queued commit"

# ---- what the server refuses -------------------------------------------------------------------------------------
# The repo path: absolute on every call, no default folder.
expect err "no path" git_status '{}' "path is required"
expect err "empty path" git_status '{"path":""}' "path is required"
expect err "relative path" git_status '{"path":"repo"}' "absolute"
expect err "dot path" git_status '{"path":"."}' "absolute"
expect err "path with a trailing newline" git_status "{\"path\":\"$R\\n\"}" "control characters"
expect err "path is not a string" git_status "{\"path\":[\"$R\"]}" "must be a string"
expect err "path does not exist" git_status "{\"path\":\"$T/nowhere\"}" "not an existing folder"
expect err "path is a file" git_status "{\"path\":\"$R/a.txt\"}" "not an existing folder"
expect err "init with a relative path" git_init '{"path":"x"}' "absolute"
expect err "clone into a relative path" git_clone "{\"path\":\"x\",\"url\":\"$T/remote.git\"}" "absolute"
expect err "unknown tool" git_worktree "{\"path\":\"$R\"}" "unknown tool"
expect err "the working-directory tool is gone" git_set_working_dir "{\"path\":\"$R\"}" "unknown tool"
expect err "a prototype name is no tool" constructor "{\"path\":\"$R\"}" "unknown tool"
# A closed key set and strict types: the hooks read these fields, so a loose reading here would differ from theirs.
expect err "unknown key" git_status "{\"path\":\"$R\",\"extra\":1}" "unknown parameter"
expect err "unknown key on fetch" git_fetch "{\"path\":\"$R\",\"refspec\":\"+refs/*:refs/*\"}" "unknown parameter"
expect err "upload-pack is no key" git_fetch "{\"path\":\"$R\",\"uploadPack\":\"touch $T/pwned\"}" "unknown parameter"
expect err "a prototype key" git_status "{\"path\":\"$R\",\"__proto__\":{\"x\":1}}" "unknown parameter"
expect err "dryRun as a string" git_push "{\"path\":\"$R\",\"dryRun\":\"true\"}" "true or false"
expect err "clean dryRun as a string" git_clean "{\"path\":\"$R\",\"dryRun\":\"true\",\"force\":true}" "true or false"
expect err "fastForwardOnly as a string" git_pull "{\"path\":\"$R\",\"fastForwardOnly\":\"true\"}" "true or false"
expect err "force as a number" git_push "{\"path\":\"$R\",\"force\":1}" "true or false"
expect err "null value" git_push "{\"path\":\"$R\",\"force\":null}" "true or false"
expect err "mode as an array" git_reset "{\"path\":\"$R\",\"mode\":[\"hard\"]}" "must be one of"
expect err "mode not in the list" git_reset "{\"path\":\"$R\",\"mode\":\"HARD\"}" "must be one of"
expect err "stash mode not in the list" git_stash "{\"path\":\"$R\",\"mode\":\"show\"}" "must be one of"
expect err "count as a string" git_log "{\"path\":\"$R\",\"maxCount\":\"5\"}" "integer"
expect err "count out of range" git_log "{\"path\":\"$R\",\"maxCount\":0}" "integer"
expect err "paths as a string" git_add "{\"path\":\"$R\",\"paths\":\"a.txt\"}" "must be an array"
expect err "arguments as an array" git_status '[]' "must be an object"
# An empty string is "not given", as the hooks read it: the default applies, never a truthy value.
expect err "empty dryRun is not a dry run" git_clean "{\"path\":\"$R\",\"dryRun\":\"\",\"force\":\"\"}" "set dryRun"
expect ok "empty mode is the default mode" git_reset "{\"path\":\"$R\",\"mode\":\"\",\"target\":\"\"}"
expect ok "empty branch mode lists" git_branch "{\"path\":\"$R\",\"mode\":\"\",\"branchName\":\"\"}" "main"
# A remote is a configured name, never a URL, a path or an option.
expect err "remote dot on fetch" git_fetch "{\"path\":\"$R\",\"remote\":\".\"}" "remote name"
expect err "remote dot-dot on pull" git_pull "{\"path\":\"$R/.git\",\"remote\":\"..\",\"fastForwardOnly\":true}" "remote name"
mkdir "$R/sub" && HOME="$T/home" git init -q "$R/sub"
expect err "a folder name as remote on fetch" git_fetch "{\"path\":\"$R\",\"remote\":\"sub\"}" "not configured"
mkdir "$T/plain"
expect err "fetch outside a repo keeps git's own message" git_fetch "{\"path\":\"$T/plain\"}" "not a git repository"
expect err "a folder name as remote on pull" git_pull "{\"path\":\"$R\",\"remote\":\"sub\"}" "not configured"
expect err "a folder name as remote on push" git_push "{\"path\":\"$R\",\"remote\":\"sub\",\"dryRun\":true}" "not configured"
rm -rf "$R/sub"
expect err "remote URL on push" git_push "{\"path\":\"$R\",\"remote\":\"https://example.com/x.git\"}" "remote name"
expect err "remote path on push" git_push "{\"path\":\"$R\",\"remote\":\"$T/remote.git\"}" "remote name"
expect err "remote option on fetch" git_fetch "{\"path\":\"$R\",\"remote\":\"--upload-pack=touch $T/pwned\"}" 'must not start with "-"'
expect err "remote option on pull" git_pull "{\"path\":\"$R\",\"remote\":\"-q\"}" 'must not start with "-"'
expect err "remote as a number" git_push "{\"path\":\"$R\",\"remote\":7}" "must be a string"
expect err "remote name option" git_remote "{\"path\":\"$R\",\"mode\":\"add\",\"name\":\"-f\",\"url\":\"$T/remote.git\"}" 'must not start with "-"'
# A branch name cannot carry a refspec or an option.
expect err "branch option on push" git_push "{\"path\":\"$R\",\"branch\":\"--force\"}" 'must not start with "-"'
expect err "force refspec on push" git_push "{\"path\":\"$R\",\"branch\":\"+main\"}" "branch or tag name"
expect err "refspec on push" git_push "{\"path\":\"$R\",\"branch\":\"feature/y:main\"}" "branch or tag name"
expect err "delete refspec on push" git_push "{\"path\":\"$R\",\"remoteBranch\":\":main\"}" "branch or tag name"
expect err "two refs in one branch" git_push "{\"path\":\"$R\",\"branch\":\"feature/y main\"}" "branch or tag name"
expect err "wildcard on push" git_push "{\"path\":\"$R\",\"branch\":\"refs/heads/*\"}" "branch or tag name"
expect err "branch option on merge" git_merge "{\"path\":\"$R\",\"branch\":\"--no-verify\"}" 'must not start with "-"'
expect err "branch option on pull" git_pull "{\"path\":\"$R\",\"branch\":\"--rebase\"}" 'must not start with "-"'
expect err "branch name option" git_branch "{\"path\":\"$R\",\"mode\":\"delete\",\"branchName\":\"-D\"}" 'must not start with "-"'
expect err "checkout -b with a ref expression" git_checkout "{\"path\":\"$R\",\"target\":\"a:b\",\"createBranch\":true}" "branch or tag name"
expect err "tag name option" git_tag "{\"path\":\"$R\",\"mode\":\"delete\",\"tagName\":\"--all\"}" 'must not start with "-"'
expect err "initial branch option" git_init "{\"path\":\"$T/i\",\"initialBranch\":\"--template=$T\"}" 'must not start with "-"'
expect err "clone branch option" git_clone "{\"path\":\"$T/c3\",\"url\":\"$T/remote.git\",\"branch\":\"--upload-pack=touch $T/pwned\"}" 'must not start with "-"'
# A ref position takes no option.
expect err "ref option on checkout" git_checkout "{\"path\":\"$R\",\"target\":\"--orphan=x\"}" 'must not start with "-"'
expect err "ref option on show" git_show "{\"path\":\"$R\",\"object\":\"--output=$T/pwned\"}" 'must not start with "-"'
expect err "ref option on log" git_log "{\"path\":\"$R\",\"branch\":\"--output=$T/pwned\"}" 'must not start with "-"'
expect err "ref option on diff" git_diff "{\"path\":\"$R\",\"target\":\"--output=$T/pwned\"}" 'must not start with "-"'
expect err "ref option on diff source" git_diff "{\"path\":\"$R\",\"source\":\"--no-index\",\"target\":\"HEAD\"}" 'must not start with "-"'
expect err "ref option on reset" git_reset "{\"path\":\"$R\",\"target\":\"--hard\"}" 'must not start with "-"'
expect err "ref option on rebase" git_rebase "{\"path\":\"$R\",\"upstream\":\"--exec=touch $T/pwned\"}" 'must not start with "-"'
expect err "ref option on rebase onto" git_rebase "{\"path\":\"$R\",\"upstream\":\"main\",\"onto\":\"-x\"}" 'must not start with "-"'
expect err "ref option on cherry-pick" git_cherry_pick "{\"path\":\"$R\",\"commits\":[\"HEAD\",\"--abort\"]}" 'must not start with "-"'
expect err "ref option on branch start" git_branch "{\"path\":\"$R\",\"mode\":\"create\",\"branchName\":\"q\",\"startPoint\":\"-f\"}" 'must not start with "-"'
expect err "ref option on merged" git_branch "{\"path\":\"$R\",\"merged\":\"--delete\"}" 'must not start with "-"'
expect err "ref option on tag commit" git_tag "{\"path\":\"$R\",\"mode\":\"create\",\"tagName\":\"q\",\"commit\":\"-d\"}" 'must not start with "-"'
expect err "ref option on reflog" git_reflog "{\"path\":\"$R\",\"ref\":\"--expire=now\"}" 'must not start with "-"'
expect err "ref with a newline" git_show "{\"path\":\"$R\",\"object\":\"HEAD\\n--x\"}" "control characters"
expect err "stash ref expression" git_stash "{\"path\":\"$R\",\"mode\":\"drop\",\"stashRef\":\"--all\"}" 'must not start with "-"'
expect err "stash ref that is no stash" git_stash "{\"path\":\"$R\",\"mode\":\"apply\",\"stashRef\":\"main\"}" "stash@{0}"
# A file position takes no option; free text stays the value of its own option.
expect err "file option on add" git_add "{\"path\":\"$R\",\"paths\":[\"--force\"]}" 'must not start with "-"'
expect err "file option on diff" git_diff "{\"path\":\"$R\",\"paths\":[\"--output=$T/pwned\"]}" 'must not start with "-"'
expect err "file option on blame" git_blame "{\"path\":\"$R\",\"filePath\":\"--contents=$T/x\"}" 'must not start with "-"'
expect err "file option on log" git_log "{\"path\":\"$R\",\"filePath\":\"--output=$T/pwned\"}" 'must not start with "-"'
expect err "file option on commit" git_commit "{\"path\":\"$R\",\"message\":\"m\",\"filesToStage\":[\"-A\"]}" 'must not start with "-"'
expect err "NUL in a file name" git_add "{\"path\":\"$R\",\"paths\":[\"a\\u0000b\"]}" "NUL"
printf 'dash\n' > "$R/-dash.txt"
expect ok "a dash file by ./ name" git_add "{\"path\":\"$R\",\"paths\":[\"./-dash.txt\"]}"
is "dash file staged" test "$(g diff --cached --name-only)" = "-dash.txt"
expect ok "text that looks like an option is only text (grep)" git_log "{\"path\":\"$R\",\"grep\":\"--output=$T/pwned\"}"
expect ok "text that looks like an option is only text (since)" git_log "{\"path\":\"$R\",\"since\":\"--output=$T/pwned\",\"author\":\"--all\"}"
expect ok "stash message that looks like an option" git_stash "{\"path\":\"$R\",\"message\":\"--all\"}"
is "the stash kept its message" sh -c "git -C '$R' stash list | grep -q -- '--all'"
expect err "commit needs a message" git_commit "{\"path\":\"$R\"}" "message is required"
expect err "author needs both fields" git_commit "{\"path\":\"$R\",\"message\":\"m\",\"author\":{\"name\":\"A\"}}" "author.email is required"
expect err "author with an extra field" git_commit "{\"path\":\"$R\",\"message\":\"m\",\"author\":{\"name\":\"A\",\"email\":\"a@b.c\",\"date\":\"x\"}}" "unknown parameter"
# URLs: no helper transport, no option.
expect err "ext transport on clone" git_clone "{\"path\":\"$T/c4\",\"url\":\"ext::sh -c 'touch $T/pwned'\"}" "must be an http"
expect err "helper transport on remote add" git_remote "{\"path\":\"$R\",\"mode\":\"add\",\"name\":\"h\",\"url\":\"fd::3\"}" "must be an http"
expect err "mirror clone is not offered" git_clone "{\"path\":\"$T/c7\",\"url\":\"$T/remote.git\",\"mirror\":true}" "unknown parameter"
expect err "ssh host that is an option" git_clone "{\"path\":\"$T/c8\",\"url\":\"ssh://-oProxyCommand=touch%20$T/pwned/x\"}" "must be an http"
expect err "scp host that is an option" git_remote "{\"path\":\"$R\",\"mode\":\"add\",\"name\":\"h\",\"url\":\"x@-oProxyCommand=y:z\"}" "must be an http"
expect err "url option on clone" git_clone "{\"path\":\"$T/c5\",\"url\":\"--upload-pack=touch $T/pwned\"}" 'must not start with "-"'
expect err "relative url on clone" git_clone "{\"path\":\"$T/c6\",\"url\":\"../remote.git\"}" "must be an http"
expect err "url option on set-url" git_remote "{\"path\":\"$R\",\"mode\":\"set-url\",\"name\":\"origin\",\"url\":\"--push\"}" 'must not start with "-"'
is "nothing an injected option names was written" test ! -e "$T/pwned"

# No inherited GIT_* reaches git: with GIT_DIR and GIT_WORK_TREE set for the server, `path` still decides the repo,
# and an identity or a config key set through the environment is not used.
HOME="$T/home" git init -q --initial-branch=elsewhere "$T/other"
out=$(printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"path":"%s"%s}}}\n' \
    1 git_status "$R" '' 2 git_commit "$R" ',"message":"env","allowEmpty":true' \
  | GIT_DIR="$T/other/.git" GIT_WORK_TREE="$T/other" GIT_AUTHOR_NAME=Mallory \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=mallory@example.com raw)
holds "GIT_DIR in the environment is dropped" "$out" "## main"
lacks "the other repo is not read" "$out" "elsewhere"
is "GIT_AUTHOR_NAME is dropped" test "$(g log -1 --format=%an)" = Test
is "GIT_CONFIG_* is dropped" test "$(g log -1 --format=%ae)" = test@example.com

# A message the server cannot name does not end it: the next one is answered.
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":8,"method":{"toString":1}}' '[1]' '{"jsonrpc":"2.0","id":9,"method":"ping"}' | raw)
holds "an odd method is refused, and the server lives on" "$out" '{"jsonrpc":"2.0","id":9,"result":{}}'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
