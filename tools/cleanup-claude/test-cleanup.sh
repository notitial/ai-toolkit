#!/bin/bash
# Tests for tools/cleanup-claude/cleanup.sh against fake home directories in a temp dir.
#   bash tools/cleanup-claude/test-cleanup.sh
# Needs jq. Nothing outside the temp dir is touched: CLEANUP_TESTING=1 lets CLEANUP_HOME, CLEANUP_LIBEXEC and CLEANUP_NO_LAUNCHCTL redirect the script.

set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
CLEAN="$HERE/cleanup.sh"
TEMPLATE="$ROOT/.claude/skills/setup-claude/templates/safe-permissions.json"
command -v jq >/dev/null 2>&1 || { echo "SKIP: needs jq"; exit 0; }

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/cleanup-test-XXXXXX") && T=$(cd "$T" && pwd -P) || exit 2
trap 'rm -rf "$T"' EXIT

ALLOW1=$(jq -r '.permissions.allow[0]' "$TEMPLATE")
ASK1=$(jq -r '.permissions.ask[0]' "$TEMPLATE")
DENY1=$(jq -r '.permissions.deny[0]' "$TEMPLATE")
PLUGIN1=$(jq -r '.enabledPlugins | keys[0]' "$TEMPLATE")
DENIED_URL=$(jq -r '.deniedMcpServers[0].serverUrl' "$TEMPLATE")
SL_CMD=$(jq -r '.statusLine.command' "$TEMPLATE")
AM_ENV=$(jq -r '.autoMode.environment[1]' "$TEMPLATE")
AM_SOFT=$(jq -r '.autoMode.soft_deny[1]' "$TEMPLATE")

N=0
mkhome() {  # mkhome -> sets H to a fresh fake home with a toolkit install and some look-alikes
  N=$((N + 1)); H="$T/h$N"; C="$H/.claude"
  mkdir -p "$C"/{agents,hooks,rules,skills,tools,projects/p1,sessions} "$H/elsewhere"
  ln -s "$ROOT/agents/code-reviewer.md" "$C/agents/code-reviewer.md"
  ln -s "$ROOT/hooks/gh-block.sh" "$C/hooks/gh-block.sh"
  ln -s "$ROOT/rules/security.md" "$C/rules/security.md"
  ln -s "$ROOT/skills/handover" "$C/skills/handover"
  ln -s "$ROOT/tools/statusline.sh" "$C/statusline.sh"
  ln -s "$ROOT/tools/workspace-lock/workspace-lock.sh" "$C/tools/workspace-lock.sh"
  ln -s /nonexistent/ai-toolkit/rules/gone.md "$C/rules/gone.md"
  ln -s "$H/elsewhere" "$C/skills/foreign"
  ln -s /nonexistent/other/thing.md "$C/rules/dangling-foreign.md"
  mkdir -p "$C/skills/synced"; echo keep > "$C/skills/synced/.bucket-1"
  echo '#!/bin/sh' > "$C/hooks/mine.sh"
  echo '# mine' > "$C/CLAUDE.md"
  echo '{}' > "$C/projects/p1/t.jsonl"; echo '{}' > "$C/sessions/1.json"
  echo '{"old":1}' > "$C/settings.json.bak-1"
  jq -n --arg allow "$ALLOW1" --arg ask "$ASK1" --arg deny "$DENY1" --arg plugin "$PLUGIN1" --arg url "$DENIED_URL" --arg sl "$SL_CMD" --arg ame "$AM_ENV" --arg ams "$AM_SOFT" --arg root "$ROOT" '{
    model: "sonnet", theme: "dark",
    env: {CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY: "1", DISABLE_FEEDBACK_COMMAND: "1", ENABLE_CLAUDEAI_MCP_SERVERS: "false", MY_VAR: "x"},
    attribution: {commit: "", pr: "", sessionUrl: false}, autoCompactWindow: 500000, promptCacheTtl: "1h", subagentPromptCacheTtl: "1h", enableAllProjectMcpServers: false,
    deniedMcpServers: [{serverUrl: $url}, {serverUrl: "https://mine.example/*"}],
    skillOverrides: {"auto-mode-setup": "off", "other-skill": "on"},
    statusLine: {type: "command", command: $sl},
    enabledPlugins: {($plugin): true, "mine@somewhere": true},
    autoMode: {environment: ["$defaults", $ame, "my own env line"], soft_deny: ["$defaults", $ams, "my own rule"]},
    permissions: {allow: [$allow, "Bash(my-cmd:*)"], ask: [$ask, "Bash(my-ask:*)"], deny: [$deny, "Bash(my-deny:*)", "Edit(/" + $root + "/.git/**)", "Edit(/" + $root + "/hooks/**)", "Edit(/" + $root + "/rules/**)", "Edit(/" + $root + "/agents/**)", "Edit(/" + $root + "/skills/**)", "Edit(/" + $root + "/tools/github-mcp/**)", "Edit(/" + $root + "/tools/workspace-lock/**)", "Edit(/" + $root + "/tools/statusline.sh)", "Edit(/" + $root + "/tools/shell-init.zsh)", "Edit(/" + $root + "/tools/ait.zsh)", "Edit(/elsewhere/hooks/**)"]},
    hooks: {
      PreToolUse: [
        {matcher: "Bash", hooks: [{type: "command", command: "$HOME/.claude/hooks/gh-block.sh"}, {type: "command", command: "$HOME/.claude/hooks/mine.sh"}]},
        {matcher: "Read", hooks: [{type: "command", command: "/opt/mine/guard.sh"}]},
        {matcher: "^mcp__github__.*$", hooks: [{type: "command", command: ("/bin/bash -p '"'"'" + $root + "/tools/github-mcp/guard.sh'"'"' || exit 2")}]},
        {matcher: "^mcp__github__.*$", hooks: [{type: "command", command: "/bin/bash -p '"'"'/elsewhere/tools/github-mcp/guard.sh'"'"' || exit 2"}]},
        {matcher: "mcp__github__.*", hooks: [{type: "command", command: "/usr/local/libexec/mcp-github/guard.sh"}]}
      ],
      PostToolUse: [{matcher: "*", hooks: [{type: "command", command: "$HOME/.claude/hooks/audit-logger.sh"}]}]
    }}' > "$C/settings.json"
  cp "$C/settings.json" "$H/settings.orig"
  printf '%s\n' 'export A=1' 'source ~/.claude/tools/shell-init.zsh' 'alias x=y' '# docs: .claude/tools/shell-init.zsh' \
    'source ~/.claude/tools/shell-init.zsh && export CHAINED=1' > "$H/.zshrc"
}
run() {  # run <args...>: runs the script on $H, output to $T/out, status to RC
  CLEANUP_TESTING=1 CLEANUP_HOME="$H" CLEANUP_LIBEXEC="$T/libexec" CLEANUP_NO_LAUNCHCTL=1 bash "$CLEAN" "$@" > "$T/out" 2>&1; RC=$?
}
snap() { (cd "$H" && find . \( -type f -o -type l -o -type d \) | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$([ -L "$f" ] && readlink "$f" || { [ -d "$f" ] && echo dir || shasum "$f" | cut -c1-16; })"; done | shasum | cut -c1-16); }
has() { jq -e "$1" "$C/settings.json" >/dev/null 2>&1; }

# ---- dry run changes nothing
mkhome
before=$(snap)
run
check "dry run exits 0" '[ $RC -eq 0 ]'
check "dry run leaves the tree as it was" '[ "$(snap)" = "$before" ]'
check "dry run says so" 'grep -q "dry run, nothing changed" "$T/out"'
check "dry run lists the links it would remove" 'grep -q "REMOVE .*hooks/gh-block.sh" "$T/out"'
check "dry run names both cache TTL keys it would remove" 'grep -q "removed  promptCacheTtl" "$T/out" && grep -q "removed  subagentPromptCacheTtl" "$T/out"'
check "dry run leaves the cache TTL keys in the file" 'has ".promptCacheTtl == \"1h\" and .subagentPromptCacheTtl == \"1h\""'

# ---- apply: links
run --apply
check "apply exits 0" '[ $RC -eq 0 ]'
for l in agents/code-reviewer.md hooks/gh-block.sh rules/security.md skills/handover statusline.sh tools/workspace-lock.sh rules/gone.md; do
  check "toolkit link removed: $l" '[ ! -e "$C/$l" ] && [ ! -L "$C/$l" ]'
done
check "a link to a foreign directory is kept" '[ -L "$C/skills/foreign" ]'
check "a foreign dangling link is kept" '[ -L "$C/rules/dangling-foreign.md" ]'
check "a real directory (skills/synced) is kept" '[ -f "$C/skills/synced/.bucket-1" ]'
check "the user's own hook script is kept" '[ -f "$C/hooks/mine.sh" ]'
check "login-side files are kept (CLAUDE.md, transcripts, sessions, backups)" '[ -f "$C/CLAUDE.md" ] && [ -f "$C/projects/p1/t.jsonl" ] && [ -f "$C/sessions/1.json" ] && [ -f "$C/settings.json.bak-1" ]'
check "the checkout is untouched" '[ -f "$ROOT/hooks/gh-block.sh" ]'
check "an emptied agents dir is removed" '[ ! -d "$C/agents" ]'

# ---- apply: settings
check "settings still valid JSON" 'jq -e . "$C/settings.json" >/dev/null'
check "settings: user keys kept (model, theme)" 'has ".model == \"sonnet\" and .theme == \"dark\""'
check "settings: toolkit env keys gone, the connector switch and MY_VAR kept" 'has "(.env | keys) == [\"ENABLE_CLAUDEAI_MCP_SERVERS\", \"MY_VAR\"]"'
check "settings: attribution, compact window, statusLine gone; the MCP flag (a security entry) kept" 'has "((has(\"attribution\") or has(\"autoCompactWindow\") or has(\"statusLine\")) | not) and .enableAllProjectMcpServers == false"'
check "settings: an opted-in cache TTL of 1h is gone from both keys" 'has "((has(\"promptCacheTtl\") or has(\"subagentPromptCacheTtl\")) | not)"'
check "settings: denied MCP servers are kept by default" 'has "(.deniedMcpServers | length) == 2"'
check "settings: only the user's skill override stays" 'has ".skillOverrides == {\"other-skill\": \"on\"}"'
check "settings: toolkit plugin gone, user plugin kept" 'has ".enabledPlugins == {\"mine@somewhere\": true}"'
check "settings: the toolkit allow entry is gone, the user's kept" 'has ".permissions.allow == [\"Bash(my-cmd:*)\"]"'
check "settings: ask entries are kept by default" 'has "(.permissions.ask | index(\"$ASK1\")) != null and (.permissions.ask | index(\"Bash(my-ask:*)\")) != null"'
check "settings: autoMode keeps \$defaults, the user's line, and the soft_deny rules" 'has ".autoMode.environment == [\"\$defaults\", \"my own env line\"] and (.autoMode.soft_deny | length) == 3"'
check "settings: deny entries are kept by default" 'has "(.permissions.deny | index(\"$DENY1\")) != null and (.permissions.deny | index(\"Bash(my-deny:*)\")) != null"'
check "settings: the live-checkout denies are kept by default (security entries)" 'has "(.permissions.deny | index(\"Edit(/$ROOT/hooks/**)\")) != null and (.permissions.deny | index(\"Edit(/$ROOT/tools/github-mcp/**)\")) != null"'
check "settings: the github guard hooks (this checkout's and the root-owned one) are kept by default" 'has "[.hooks.PreToolUse[].hooks[].command] | (map(select(contains(\"$ROOT/tools/github-mcp/guard.sh\"))) | length) == 1 and index(\"/usr/local/libexec/mcp-github/guard.sh\") != null"'
check "the kept guard hook is reported" 'grep -q "^KEEP .*github MCP guard hook" "$T/out"'
check "settings: toolkit hooks gone, the user's hook beside one is kept" 'has "[.hooks.PreToolUse[].hooks[].command] | index(\"\$HOME/.claude/hooks/mine.sh\") != null and index(\"/opt/mine/guard.sh\") != null and index(\"\$HOME/.claude/hooks/gh-block.sh\") == null"'
check "settings: an event holding only toolkit hooks is gone" 'has ".hooks | has(\"PostToolUse\") | not"'
bak=$(ls "$C"/settings.json.bak-*-cleanup 2>/dev/null | head -1)
check "settings: a backup of the original was written" '[ -n "$bak" ] && cmp -s "$bak" "$H/settings.orig"'
check "settings: the backup is mode 600" '[ "$(stat -c %a "$bak" 2>/dev/null || stat -f %Lp "$bak")" = 600 ]'

# ---- apply: shell rc
check "rc: the plain source line is removed" '! grep -q "^source ~/.claude/tools/shell-init.zsh$" "$H/.zshrc"'
check "rc: other lines, a comment that mentions the path, and a chained line are kept" 'grep -q "export A=1" "$H/.zshrc" && grep -q "alias x=y" "$H/.zshrc" && grep -q "^# docs: .claude/tools/shell-init.zsh" "$H/.zshrc" && grep -q "CHAINED=1" "$H/.zshrc"'
check "rc: the chained line is printed for the user" 'grep -q "Edit by hand" "$T/out"'
check "rc: a timestamped copy was kept" 'ls "$H"/.zshrc.cleanup-bak-* >/dev/null 2>&1'

# ---- idempotent
run --apply
check "second apply exits 0" '[ $RC -eq 0 ]'
check "second apply finds nothing to edit" 'grep -q "nothing of the toolkit" "$T/out" && ! grep -q "^EDIT" "$T/out"'

# ---- keep-ambiguous and include-deny
mkhome
run --apply --keep-ambiguous
check "--keep-ambiguous keeps the template allow entry" 'has "(.permissions.allow | index(\"$ALLOW1\")) != null"'
check "--keep-ambiguous keeps the toolkit plugin" 'has ".enabledPlugins | has(\"$PLUGIN1\")"'
check "--keep-ambiguous keeps the autoMode context line" 'has "(.autoMode.environment | length) == 3"'
check "--keep-ambiguous keeps an opted-in cache TTL" 'has ".promptCacheTtl == \"1h\" and .subagentPromptCacheTtl == \"1h\""'
check "--keep-ambiguous still removes the toolkit hooks" 'has "[.hooks.PreToolUse[].hooks[].command] | index(\"\$HOME/.claude/hooks/gh-block.sh\") == null"'
mkhome
jq '.promptCacheTtl = "5m"' "$C/settings.json" > "$T/ttl.json" && cp "$T/ttl.json" "$C/settings.json"
run --apply
check "a cache TTL of 5m is the user's own and stays, whatever the other key does" 'has ".promptCacheTtl == \"5m\" and (has(\"subagentPromptCacheTtl\") | not)"'
mkhome
jq '.subagentPromptCacheTtl = 3600 | del(.promptCacheTtl)' "$C/settings.json" > "$T/ttl.json" && cp "$T/ttl.json" "$C/settings.json"
run --apply
check "a lone cache TTL that is not the string 1h stays" 'has ".subagentPromptCacheTtl == 3600 and (has(\"promptCacheTtl\") | not)"'
mkhome
run --apply --include-security
check "--include-security removes the template deny and ask entries, keeps the user's" 'has "(.permissions.deny | index(\"$DENY1\")) == null and (.permissions.deny | index(\"Bash(my-deny:*)\")) != null and (.permissions.ask | index(\"$ASK1\")) == null and (.permissions.ask | index(\"Bash(my-ask:*)\")) != null"'
check "--include-security removes the ten live-checkout denies, keeps another path's" 'has "(.permissions.deny | map(select(startswith(\"Edit(/$ROOT/\"))) | length) == 0 and (.permissions.deny | index(\"Edit(/elsewhere/hooks/**)\")) != null"'
check "--include-security removes the denied servers, the connector switch, the MCP flag, soft_deny rules" 'has "(.deniedMcpServers == [{serverUrl: \"https://mine.example/*\"}]) and (.env | has(\"ENABLE_CLAUDEAI_MCP_SERVERS\") | not) and (has(\"enableAllProjectMcpServers\") | not) and .autoMode.soft_deny == [\"\$defaults\", \"my own rule\"]"'
mkhome
run --apply --include-deny
check "--include-deny is the same flag" 'has "(.permissions.deny | index(\"$DENY1\")) == null"'
mkhome
run --apply --remove-guard-hook
check "--remove-guard-hook removes this checkout's and the root-owned guard hook, keeps another checkout's" 'has "[.hooks.PreToolUse[].hooks[].command] | (map(select(contains(\"$ROOT/tools/github-mcp/guard.sh\"))) | length) == 0 and index(\"/usr/local/libexec/mcp-github/guard.sh\") == null and (map(select(contains(\"/elsewhere/tools/github-mcp/guard.sh\"))) | length) == 1"'
check "--remove-guard-hook alone keeps the deny entries" 'has "(.permissions.deny | index(\"$DENY1\")) != null"'
check "--remove-guard-hook: no KEEP line" '! grep -q "^KEEP .*guard hook" "$T/out"'
mkhome
run --apply --include-security
check "--include-security removes the guard hook too (its go in advance)" 'has "[.hooks.PreToolUse[].hooks[].command] | (map(select(contains(\"$ROOT/tools/github-mcp/guard.sh\"))) | length) == 0 and index(\"/usr/local/libexec/mcp-github/guard.sh\") == null"'

# ---- a settings.json that is a symlink: the real file is edited and backed up, the link stays
mkhome
mv "$C/settings.json" "$H/elsewhere/settings.json"; ln -s "$H/elsewhere/settings.json" "$C/settings.json"
run --apply
check "symlinked settings: the link survives and the real file is edited" '[ -L "$C/settings.json" ] && jq -e "(.env | has(\"CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY\")) | not" "$H/elsewhere/settings.json" >/dev/null'
check "symlinked settings: the backup sits next to the real file" 'ls "$H"/elsewhere/settings.json.bak-*-cleanup >/dev/null 2>&1 && ! ls "$C"/settings.json.bak-*-cleanup >/dev/null 2>&1'
mkhome
rm "$C/settings.json"; ln -s "$H/elsewhere/missing.json" "$C/settings.json"
run --apply
check "dangling settings link: left in place, the run still succeeds" '[ -L "$C/settings.json" ] && [ ! -e "$C/settings.json" ] && [ $RC -eq 0 ]'

# ---- a settings file that is not JSON is left alone
mkhome
echo 'not json {' > "$C/settings.json"
run --apply
check "bad settings: exit 1" '[ $RC -eq 1 ]'
check "bad settings: file untouched and no backup" 'grep -q "not json" "$C/settings.json" && ! ls "$C"/settings.json.bak-*-cleanup >/dev/null 2>&1'
check "bad settings: links are still removed" '[ ! -L "$C/hooks/gh-block.sh" ]'

# ---- runtime state
mkhome
mkdir -p "$C/.eta" "$H/.cache/mcp-github" "$H/.local/state/claude-statusline/limits"
echo x > "$H/.local/state/claude-statusline/limits/readings-x.json"
echo x > "$C/.eta/records.jsonl"; echo x > "$H/.cache/mcp-github/checked"
run --apply
check "state: the update-check cache is removed" '[ ! -e "$H/.cache/mcp-github" ]'
check "state: the statusline readings folder is removed" '[ ! -e "$H/.local/state/claude-statusline" ]'
check "state: the ASK item is kept (the ETA log)" '[ -f "$C/.eta/records.jsonl" ]'
check "state: the ASK item is listed" 'grep -q "^ASK .*\.eta" "$T/out"'
run --apply --purge-ask
check "--purge-ask removes the ASK item" '[ ! -e "$C/.eta" ]'
check "--purge-ask still keeps transcripts and CLAUDE.md" '[ -f "$C/projects/p1/t.jsonl" ] && [ -f "$C/CLAUDE.md" ]'

# ---- printed commands, never run
mkhome
mkdir -p "$T/libexec/mcp-github"
printf '{"mcpServers":{"git-mcp":{},"github":{},"mine":{}}}\n' > "$H/.claude.json"
cj=$(shasum "$H/.claude.json")
run --apply
check "manual: while the root-owned guard hook is kept, no rm of its folder is printed" '! grep -q "sudo rm -r" "$T/out" && grep -q "^KEEP .*root-owned install" "$T/out"'
mkhome
mkdir -p "$T/libexec/mcp-github"
printf '{"mcpServers":{"git-mcp":{},"github":{},"mine":{}}}\n' > "$H/.claude.json"
cj=$(shasum "$H/.claude.json")
run --apply --remove-guard-hook
check "manual: with the guard hook removed, the sudo command names the existing root-owned dirs" 'grep -q "sudo rm -r $T/libexec/mcp-github\$" "$T/out"'
check "manual: the root-owned dirs are not touched" '[ -d "$T/libexec/mcp-github" ]'
check "manual: mcp remove is printed for git-mcp and github only" 'grep -q "claude mcp remove --scope user git-mcp" "$T/out" && grep -q "claude mcp remove --scope user github" "$T/out" && ! grep -q "remove --scope user mine" "$T/out"'
check "manual: .claude.json is not modified" '[ "$(shasum "$H/.claude.json")" = "$cj" ]'
check "manual: Keychain commands are printed, not run" 'grep -q "security delete-generic-password -s mcp-github" "$T/out"'

# ---- the root-owned folder stays while a settings file this run leaves still names its guard hook
mkhome
mkdir -p "$T/libexec/mcp-github"
printf '%s\n' '{"hooks": {"PreToolUse": [{"matcher": "mcp__github__.*", "hooks": [{"type": "command", "command": "/usr/local/libexec/mcp-github/guard.sh"}]}]},' > "$C/settings.json"
run --apply --remove-guard-hook
check "root guard: a settings file that is not JSON keeps the folder" '! grep -q "sudo rm -r" "$T/out" && grep -q "^KEEP .*names the root-owned guard hook and is left alone" "$T/out"'
mkhome
mkdir -p "$T/libexec/mcp-github"
chmod 500 "$C"
run --apply --remove-guard-hook
chmod 700 "$C"
check "root guard: a settings file that could not be written keeps the folder" '! grep -q "sudo rm -r" "$T/out" && grep -q "^KEEP .*names the root-owned guard hook and was not written" "$T/out"'

# ---- the roster /setup-claude and install-copies.sh link, all removed
N=$((N + 1)); H="$T/h$N"; R="$H/.claude"; mkdir -p "$R/agents" "$R/hooks" "$R/rules" "$R/skills" "$R/tools"
for f in "$ROOT"/agents/*.md; do ln -s "$f" "$R/agents/${f##*/}"; done
for f in "$ROOT"/hooks/*.sh; do ln -s "$f" "$R/hooks/${f##*/}"; done
for f in "$ROOT"/rules/*.md; do ln -s "$f" "$R/rules/${f##*/}"; done
for d in "$ROOT"/skills/*/; do n=${d%/}; n=${n##*/}; [ -f "$ROOT/skills/$n/SKILL.md" ] && ln -s "$ROOT/skills/$n" "$R/skills/$n"; done
ln -s "$ROOT/tools/statusline.sh" "$R/statusline.sh"
ln -s "$ROOT/tools/workspace-lock/workspace-lock.sh" "$R/tools/workspace-lock.sh"
ln -s "$ROOT/tools/shell-init.zsh" "$R/tools/shell-init.zsh"
total=$(find "$R" -type l | wc -l | tr -d ' ')
run --apply
check "roster: $total links, none left" '[ "$(find "$R" -type l | wc -l | tr -d " ")" = 0 ]'

# ---- refusals
CLEANUP_TESTING=1 CLEANUP_HOME="relative/path" bash "$CLEAN" > "$T/out" 2>&1; rc=$?; check "a relative home is refused (exit 2)" '[ $rc -eq 2 ]'
CLEANUP_TESTING=1 CLEANUP_HOME="$T/does-not-exist" bash "$CLEAN" > "$T/out" 2>&1; rc=$?; check "a missing home is refused (exit 2)" '[ $rc -eq 2 ]'
bash "$CLEAN" --nonsense > "$T/out" 2>&1; rc=$?; check "an unknown option is refused (exit 2)" '[ $rc -eq 2 ]'
mkdir -p "$T/empty"; CLEANUP_TESTING=1 CLEANUP_HOME="$T/empty" bash "$CLEAN" > "$T/out" 2>&1; rc=$?; check "a home with no config dir is refused (exit 2)" '[ $rc -eq 2 ]'
mkhome
before=$(snap); run --config-dir "$H"; check "the removed --config-dir option is refused (exit 2) and changes nothing" '[ $RC -eq 2 ] && [ "$(snap)" = "$before" ]'
HOME="$H" CLEANUP_HOME="$T/empty" bash "$CLEAN" > "$T/out" 2>&1
check "a stray CLEANUP_HOME without CLEANUP_TESTING is ignored" '! grep -q "$T/empty" "$T/out" && ! grep -q "no Claude config dir found" "$T/out"'

# ---- --verbose prints paths, never values
mkhome
jq '.env.ANTHROPIC_AUTH_TOKEN = "sk-secret-value-123"' "$C/settings.json" > "$C/s.tmp" && mv "$C/s.tmp" "$C/settings.json"
run --verbose
check "verbose: lists the paths that go" 'grep -q "gone .*env.CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY" "$T/out"'
check "verbose: prints no env value" '! grep -q "sk-secret-value-123" "$T/out"'
run
check "default: prints no env value either" '! grep -q "sk-secret-value-123" "$T/out"'
run --apply
check "the user's env secret stays in the file" 'has ".env.ANTHROPIC_AUTH_TOKEN == \"sk-secret-value-123\""'

# ---- settings file mode is kept; wrong-typed keys do not break it
mkhome
chmod 640 "$C/settings.json"
run --apply
check "settings keep their mode (640)" '[ "$(stat -c %a "$C/settings.json" 2>/dev/null || stat -f %Lp "$C/settings.json")" = 640 ]'
mkhome
echo '{"hooks": null, "env": "x", "permissions": [], "deniedMcpServers": {}, "statusLine": "x", "autoMode": 3, "enabledPlugins": [], "skillOverrides": "x"}' > "$C/settings.json"
cp "$C/settings.json" "$H/wrongtype.orig"
run --apply
check "wrong-typed keys: exit 0, file untouched" '[ $RC -eq 0 ] && cmp -s "$C/settings.json" "$H/wrongtype.orig"'

# ---- hook matching: exact command forms only
mkhome
echo '#!/bin/sh' > "$C/hooks/audit-logger.sh"
jq '.hooks.PreToolUse += [
      {matcher: "A", hooks: [{type: "command", command: "$HOME/.claude/hooks/audit-logger.sh"}]},
      {matcher: "B", hooks: [{type: "command", command: "$HOME/.claude/hooks/secret-detector.sh && my-thing"}]},
      {matcher: "C", hooks: [{type: "command", command: "bash $HOME/.claude/hooks/secret-redact-output.sh --flag"}]},
      {matcher: "E", hooks: [{type: "prompt", prompt: "x"}]},
      {matcher: "F", hooks: [{type: "command", command: "$HOME/.claude/hooks/gh-block.sh"}]}]' "$C/settings.json" > "$C/s.tmp" && mv "$C/s.tmp" "$C/settings.json"
run --apply
check "hooks: a hook with no command does not stop the clean-up" '[ $RC -eq 0 ] && ! grep -q "filter failed" "$T/out" && has "[.hooks.PreToolUse[] | select(.matcher == \"F\")] | length == 0"'
check "hooks: the hook with no command is kept" 'has "[.hooks.PreToolUse[] | select(.matcher == \"E\")] | length == 1"'
check "hooks: the user's own real script with a toolkit name is kept" 'has "[.hooks.PreToolUse[] | select(.matcher == \"A\")] | length == 1"'
check "hooks: a chained command is kept" 'has "[.hooks.PreToolUse[] | select(.matcher == \"B\")] | length == 1"'
check "hooks: a bash-prefixed toolkit hook with arguments is removed" 'has "[.hooks.PreToolUse[] | select(.matcher == \"C\")] | length == 0"'

# ---- autoMode: only the template lines go, \$defaults stays; a list of nothing else is dropped
mkhome
jq --slurpfile t "$TEMPLATE" '.autoMode = {environment: $t[0].autoMode.environment}' "$C/settings.json" > "$C/s.tmp" && mv "$C/s.tmp" "$C/settings.json"
run --apply
check "autoMode holding only the template's lines is dropped whole" 'has "has(\"autoMode\") | not"'

# ---- shell rc edge cases
mkhome
printf '%s\n' 'if [ -f ~/.claude/tools/shell-init.zsh ]; then' '  source ~/.claude/tools/shell-init.zsh' 'fi' 'export KEEP=1' > "$H/.zshrc"
cp "$H/.zshrc" "$H/zshrc.orig"
run --apply
check "rc: a source line that is the only body of an if is not removed, and is printed" 'cmp -s "$H/.zshrc" "$H/zshrc.orig" && grep -q "Edit by hand" "$T/out"'
mkhome
echo 'source ~/.claude/tools/shell-init.zsh' > "$H/.zshrc"
run --apply
check "rc: a file holding only the toolkit line becomes empty, exit 0" '[ $RC -eq 0 ] && [ ! -s "$H/.zshrc" ]'
echo 'source ~/.claude/tools/shell-init.zsh' > "$H/.zshrc"
sleep 1
run --apply
check "rc: a second cleanup after the line came back works, with a second copy" '[ $RC -eq 0 ] && [ ! -s "$H/.zshrc" ] && [ "$(ls "$H"/.zshrc.cleanup-bak-* | wc -l | tr -d " ")" = 2 ]'
mkhome
mkhome
printf 'export A=1\nsource ~/.claude/tools/shell-init.zsh' > "$H/.zshrc"
run --apply
check "rc: a last line with no newline is handled" 'grep -q "export A=1" "$H/.zshrc" && ! grep -q shell-init "$H/.zshrc"'
mkhome
printf '%s\n' 'if true; then' '  source ~/.claude/tools/shell-init.zsh  # toolkit' '  export B=1' 'fi' > "$H/.zshrc"
run --apply
check "rc: an indented source line with a trailing comment is removed or printed, never skipped" '! grep -q shell-init "$H/.zshrc" || grep -q "Edit by hand" "$T/out"'
for end in '&&' '||' '|' '\'; do
  mkhome
  printf '%s\n' "[[ -o interactive ]] $end" '  source ~/.claude/tools/shell-init.zsh' 'export PATH=/x:$PATH' > "$H/.zshrc"
  cp "$H/.zshrc" "$H/zshrc.orig"
  run --apply
  check "rc: a source line continuing a line that ends in $end is not removed, and is printed" 'cmp -s "$H/.zshrc" "$H/zshrc.orig" && grep -q "Edit by hand" "$T/out"'
done
mkhome
printf '%s\n' 'export A=1 &&' '' '  source ~/.claude/tools/shell-init.zsh' > "$H/.zshrc"
cp "$H/.zshrc" "$H/zshrc.orig"
run --apply
check "rc: a blank line between the && line and the source line still counts as continued" 'cmp -s "$H/.zshrc" "$H/zshrc.orig" && grep -q "Edit by hand" "$T/out"'
mkhome
printf '%s\n' 'export A=1' 'source ~/.claude/tools/shell-init.zsh' 'export B=1 &&' 'export C=1' > "$H/.zshrc"
run --apply
check "rc: a && line after the source line does not keep it" '! grep -q shell-init "$H/.zshrc" && grep -q "export B=1 &&" "$H/.zshrc"'
mkhome
mkdir -p "$H/zdot"
printf '%s\n' 'export Z=1' 'source ~/.claude/tools/shell-init.zsh' > "$H/zdot/.zshrc"
printf '%s\n' 'source ~/.claude/tools/shell-init.zsh' > "$H/zdot/.zprofile"
export CLEANUP_ZDOTDIR="$H/zdot"
run
check "rc: a dry run lists the rc files under ZDOTDIR" 'grep -q "EDIT .*zdot/.zshrc" "$T/out" && grep -q "EDIT .*zdot/.zprofile" "$T/out" && grep -q shell-init "$H/zdot/.zshrc"'
run --apply
unset CLEANUP_ZDOTDIR
check "rc: the source lines under ZDOTDIR are removed, with a copy" '! grep -q shell-init "$H/zdot/.zshrc" && grep -q "export Z=1" "$H/zdot/.zshrc" && [ ! -s "$H/zdot/.zprofile" ] && ls "$H/zdot"/.zshrc.cleanup-bak-* >/dev/null 2>&1'
check "rc: the home's own .zshrc is still cleaned beside ZDOTDIR" '! grep -qx "source ~/.claude/tools/shell-init.zsh" "$H/.zshrc"'
mkhome
export CLEANUP_ZDOTDIR="$H"
run
unset CLEANUP_ZDOTDIR
check "rc: ZDOTDIR equal to the home is scanned once" '[ "$(grep -c "EDIT .*/\.zshrc " "$T/out")" = 1 ]'
mkhome
mkdir -p "$H/zdot"
printf '%s\n' 'source ~/.claude/tools/shell-init.zsh' > "$H/zdot/.zshrc"
ZDOTDIR="$H/zdot" run --apply
check "rc: under CLEANUP_TESTING the real ZDOTDIR is ignored" 'grep -q shell-init "$H/zdot/.zshrc"'

mkhome

# ---- links: only links are removed, folders that are links are not entered
mkhome
mkdir -p "$C/skills/my-skill"; echo keep > "$C/skills/my-skill/f"
nl=$(printf 'my-skill\nx'); ln -s "$ROOT/skills/handover" "$C/skills/$nl"
run --apply
check "links: a link whose name holds a newline never takes a real directory with it" '[ -f "$C/skills/my-skill/f" ]'
mkhome
mkdir -p "$H/dotfiles/skills"; ln -s "$ROOT/skills/handover" "$H/dotfiles/skills/handover"
rm -r "$C/skills"; ln -s "$H/dotfiles/skills" "$C/skills"
run --apply
check "links: a folder that is a link elsewhere is not entered (the dotfiles link stays)" '[ -L "$H/dotfiles/skills/handover" ] && [ -L "$C/skills" ]'
mkhome
rm -r "$C/skills"; ln -s "$ROOT/skills" "$C/skills"
run --apply
check "links: a whole-folder link into the checkout is removed, the checkout is intact" '[ ! -L "$C/skills" ] && [ -f "$ROOT/skills/handover/SKILL.md" ]'

# ---- a state folder reached through a symlink that leaves the home is not removed
mkhome
mkdir -p "$T/outside/mcp-github"; echo keep > "$T/outside/mcp-github/checked"
ln -s "$T/outside" "$H/.cache"
run --apply
check "outside: a path whose folder is a link out of the home is skipped, not removed" '[ -f "$T/outside/mcp-github/checked" ] && grep -q "SKIP .*outside the home" "$T/out"'

# ---- install-time settings: removed (with keys another installer added), a symlink kept; rendered autoMode lines go
conf_fixture() { printf '%s\n' 'github_write_owners=example-user' 'github_keychain_account=example-user' 'github_username=example-user' > "$C/install.conf"; chmod 600 "$C/install.conf"; }
mkhome
conf_fixture
AM_RENDERED=$(jq -r '.autoMode.environment[] | select(test("<username>"))' "$TEMPLATE" | head -n 1 | sed 's/<username>/example-user/g')
jq --arg l "$AM_RENDERED" '.autoMode.environment += [$l]' "$C/settings.json" > "$C/s.tmp" && mv "$C/s.tmp" "$C/settings.json"
run --apply
check "install.conf: removed" '[ ! -e "$C/install.conf" ] && grep -q "REMOVE .*install.conf  (install-time settings)" "$T/out"'
check "settings: an autoMode line rendered from install.conf is removed" '[ -n "$AM_RENDERED" ] && [ -f "$C/settings.json" ] && ! jq -e --arg l "$AM_RENDERED" ".autoMode.environment // [] | index(\$l)" "$C/settings.json" >/dev/null'
mkhome
conf_fixture
printf '%s\n' 'other_tool_label=com.example' >> "$C/install.conf"
mkdir -p "$C/repos/other-tool"
run --apply
check "install.conf: removed with another installer's keys in it, whatever else is installed" '[ ! -e "$C/install.conf" ] && grep -q "REMOVE .*install.conf  (install-time settings)" "$T/out"'
check "install.conf: another installer's folder is left alone" '[ -d "$C/repos/other-tool" ]'
mkhome
echo x > "$H/elsewhere/real.conf"; ln -s "$H/elsewhere/real.conf" "$C/install.conf"
run --apply
check "install.conf: a symlink is kept and reported" '[ -L "$C/install.conf" ] && [ -f "$H/elsewhere/real.conf" ] && grep -q "SKIP .*install.conf  (a symlink" "$T/out"'

echo "test-cleanup: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
