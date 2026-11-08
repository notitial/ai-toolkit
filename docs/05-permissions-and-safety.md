# Permissions and Safety

Command whitelists, sandbox patterns, and secrets safety for AI agents.

## The Principle

AI agents should operate on the principle of least privilege: they can run only the commands necessary for their role, nothing more. This is not about distrusting the model — it is about reducing the blast radius of mistakes. An agent that cannot run `rm -rf` cannot accidentally delete your repo, no matter how confused its context gets.

## The Command Whitelist Pattern

Instead of blacklisting dangerous commands (an endless game), whitelist the safe ones:

```
ALLOWED:
  Git: git status, git diff, git log, git add, git commit, git branch
  Build: project-build, project-test, project-lint (aliases, not raw tools)
  Generators: python tools/generate_strings.py, node tools/build.js
  File tools: read, write, glob, grep

PROHIBITED (everything not listed above, including):
  Web: curl, wget, web_search
  Package managers: npm install, pip install, brew install
  Raw build tools: xcodebuild, gradlew, cargo build
  Chaining: &&, ||, ; (breaks allowlist matching)
```

**Why whitelist over blacklist:** You can enumerate the 20 commands an agent needs. You cannot enumerate every dangerous command that exists. New tools, shell builtins, and creative command construction make blacklists porous.

**Where the list lives:** enforce it in `settings.json` permissions (allow and deny) and hooks, which bind every subagent; a rule file holding the list is reference only. An allow list makes an unlisted command prompt rather than fail, so a hard limit needs a deny rule or a hook. Each agent definition carries only a short inline policy (allowed categories, key prohibitions), because a subagent is not guaranteed to load rule files. Copying the full list everywhere costs its tokens on every session (see [the case study below](#case-study-whitelist-consolidation)).

## Prompt Whitelist vs Tool Sandbox

Two independent layers of enforcement:

1. **Prompt whitelist (model level):** The agent's instructions say "only run these commands." This is a request — the model can violate it if confused or context-degraded.

2. **Tool sandbox (runtime level):** The hosting tool (Claude Code `settings.json`, Cursor sandbox) physically prevents execution of unauthorized commands. This is enforcement.

Both layers are necessary. The prompt whitelist reduces attempts (less noise, fewer permission prompts). The sandbox catches violations. They are independent — disabling one does not affect the other.

**Claude Code example:**
```json
{
  "permissions": {
    "allow": [
      "Bash(project-build)",
      "Bash(project-test)",
      "Bash(project-lint)",
      "mcp__git-mcp__git_status",
      "mcp__git-mcp__git_diff",
      "mcp__git-mcp__git_log",
      "mcp__git-mcp__git_add"
    ]
  }
}
```

## Allowed Command Categories

### Git (read + write)
`git status`, `git diff`, `git log`, `git add`, `git commit`, `git branch`, `git checkout`. Most agents need these for context and committing work.

**Restricted git:** `git push` only when explicitly approved. `git reset --hard`, `git clean`, `git rebase` — never in automated contexts, or only with explicit human confirmation.

### Build aliases
Wrap raw build tools in project-specific aliases. The agent runs `project-build`, never `xcodebuild` or `./gradlew assembleDebug`. Benefits: aliases encode the right flags, target, and configuration. Agents cannot invent wrong flag combinations.

### Generators and scripts
Project-specific code generators (localization, design tokens, string resources). These are known-safe, idempotent, and their output can be verified by diffing generated files.

### File tools
Read, write, glob, grep — the built-in tools that AI coding assistants provide. These are sandboxed by the tool itself and are the preferred way to interact with files (over `cat`, `sed`, `awk`).

### MCP tools
If you use MCP servers (project management, external APIs), whitelist them explicitly. MCP tools that modify external state (updating ticket status, posting comments) deserve their own permission tier.

## Prohibited Command Categories

### Web tools
`curl`, `wget`, `web_search` — agents do not need internet access for implementation work. If they do (e.g., checking API docs), use a specific MCP server with bounded scope instead of raw HTTP access.

### Package managers
`npm install`, `pip install`, `brew install` — agents should not modify dependencies without human review. Dependency changes affect build reproducibility, security posture, and bundle size.

### Raw build tools
`xcodebuild`, `gradlew`, `cargo build`, `make` — always wrap in aliases. Raw invocations risk wrong flags, wrong targets, wrong configurations. The alias is the contract; the raw tool is the implementation.

### Command chaining
`&&`, `||`, `;` between commands — breaks allowlist matching (the sandbox sees the whole string, not individual commands) and makes failure tracing harder. One command per execution.

## The "One Command at a Time" Rule

Prohibit command chaining (`&&`, `||`, `;`) in agent-executed commands. Reasons:

1. **Allowlist bypass:** `git status && rm -rf /` passes if the allowlist matches on prefix.
2. **Failure tracing:** When a chained command fails, which part failed? The agent often cannot tell.
3. **Permission clarity:** Each command should be independently authorized. Chaining obscures what is being approved.

This is the simplest security rule and one of the most effective.

## Matching Commands in Hooks

A PreToolUse hook that classifies a Bash command by matching a token (`git`, say) as a bare **substring** over-denies whenever the token appears in prose or an argument: `echo "… git push …"`, a `--reason "…"` value. Match the token only in **command position** instead.

- **Boundary:** line start, or after a separator (`|`, `;`, `&`, `&&`, `||`), a subshell `(`, a brace `{`, a backtick or a `$(` substitution opener.
- **Leaders to skip:** `VAR=` assignments, wrappers (`env`, `sudo`, `command`, `timeout <duration>`), shell keywords (`then`, `do`, `else`, `elif`), a leading `!`, and an optional surrounding quote.
- **Result:** wrapper-prefixed, keyword-led, negated, path-qualified and redirect-led invocations still match; prose does not.
- **Trade-off for a security backstop:** narrowing a substring match trades prose precision for coverage of exotic interpreter and wrapper forms the match was catching by accident. Make that trade deliberately and pair it with a server-side control (branch protection, a guard on the tool itself) for the tail the hook no longer sees.

**Case study.** [`hooks/git-mcp-redirect.sh`](../hooks/git-mcp-redirect.sh) was narrowed from a substring match to a shared `ANCHOR` and `LEADER` pair (the command-position boundary and the skippable leaders) after it denied read-only commands whose prose mentioned a git subcommand. Source: retired ai-tooling doc 16, "Lessons From Dogfooding".

## MCP Servers as Tool Replacement

The Model Context Protocol (MCP) defines a standard way for AI agents to access external tools and resources through typed, server-based interfaces. Where Bash permissions use regex patterns against shell commands, MCP servers expose discrete tools with typed parameters, structured output, and atomic execution. This makes MCP the preferred permission model for any tool category where a server exists.

### Why MCP over Bash

Three properties make MCP servers better than Bash wildcards for agent permissions:

1. **Granular permissions.** Each MCP tool is a single named operation (`mcp__git-mcp__git_status`, `mcp__github__create_pull_request`). Bash wildcards like `Bash(git status*)` match the intended command plus unexpected flag combinations. MCP tools have typed parameters — the server validates inputs, not the permission regex.

2. **Structured output.** MCP tools return structured data (JSON with typed fields). Bash returns raw text that the model must parse. Structured output reduces parsing errors and improves downstream tool chaining — an agent can read a `files` array directly instead of parsing `git status` output.

3. **No command chaining risk.** MCP tools execute atomically through JSON-RPC. There is no shell involved, so `&&`, `||`, `;` bypass attacks are impossible. This eliminates the "One Command at a Time" enforcement burden for any tool category moved to MCP.

### Where MCP servers apply

MCP is not limited to git. Any tool category where a quality server exists is a candidate for migration from Bash:

| Category | Example MCP servers | What it replaces |
|---|---|---|
| Git operations | `@cyanheads/git-mcp-server` | `Bash(git *)` wildcards |
| GitHub / project management | GitHub MCP plugin | `Bash(gh *)` commands |
| Filesystem browsing | Filesystem MCP server | `Bash(ls *)`, `Bash(find *)` |
| Documentation lookup | Context7, custom doc servers | `Bash(curl *)` for API docs |
| Database queries | Database MCP servers | `Bash(psql *)`, `Bash(sqlite3 *)` |

The pattern is consistent: identify Bash permissions that use wildcards, find or build an MCP server that covers the same operations, then replace the Bash permissions with MCP tool permissions.

### Migration pattern: Git (worked example)

Git is the most common migration because every project uses it and a mature MCP server exists.

Replace Bash git permissions with their MCP equivalents in `settings.json`:

| Bash permission | MCP replacement |
|---|---|
| `Bash(git status*)` | `mcp__git-mcp__git_status` |
| `Bash(git diff*)` | `mcp__git-mcp__git_diff` |
| `Bash(git log*)` | `mcp__git-mcp__git_log` |
| `Bash(git show*)` | `mcp__git-mcp__git_show` |
| `Bash(git remote -v*)` | `mcp__git-mcp__git_remote` |
| `Bash(git tag*)` | `mcp__git-mcp__git_tag` |
| `Bash(git stash list*)` | `mcp__git-mcp__git_stash` |
| `Bash(git add *)` | `mcp__git-mcp__git_add` |

Auto-approve read-only MCP tools and low-risk operations like `git_add` (staging). Leave write operations (`git_commit`, `git_push`, `git_reset`, `git_rebase`) for interactive prompting — they modify repository state and deserve human confirmation. `git_remote`, `git_tag` and `git_stash` prompt too: each also has write modes (`set-url`, `delete`, `drop`), and a permission rule matches the tool name, not the mode.

Install the server at user scope for global availability:

```bash
npm i -g @cyanheads/git-mcp-server@2.15.1
claude mcp add --scope user git-mcp -- git-mcp-server
```

Run it as an installed binary, never through `npx -y …@latest`, which caused mid-session disconnects. [`/setup-claude`](../.claude/skills/setup-claude/SKILL.md) pins the version and checks the config.

### Permissions alone do not steer behavior

Removing Bash git permissions creates a prompt gate (the agent asks for approval), but it does not make agents *prefer* MCP tools. Agents may still attempt Bash git commands and trigger the permission prompt repeatedly.

To steer behavior, add an explicit directive to your instruction file:

```
Use git MCP tools (mcp__git-mcp__*) for all git operations instead of Bash git commands.
```

This applies to any MCP migration: the permission layer enforces, but the instruction file steers. Both are needed.

### What stays as Bash

Bash permissions remain appropriate for:
- Commands with no MCP equivalent (`ls`, `cat`, `wc`, `pwd`, `which`, `mkdir`)
- Project-specific build aliases (`project-build`, `project-test`) that wrap complex toolchain invocations
- One-off commands where building an MCP server would be overengineering

## Permission Scoping Per Role

Different agent roles need different permissions:

| Role | Allowed | Prohibited |
|------|---------|------------|
| Orchestrator | Git read, checkpoint file I/O, MCP | Build, test, lint, code writes |
| Reviewer | File read, git read | File write, build, git write |
| Platform implementer | File read/write, git, build, test, lint | Web, package managers, other platform's build |
| Architecture agent | File read, git read | File write, build, git write |
| Docs agent | File read/write in docs/ | Build, test, code outside docs/ |

**Principle:** No agent should have permissions it does not need. A reviewer that can write code is a reviewer that might "helpfully" fix issues instead of reporting them — changing the review's semantics. See [03-agents.md](03-agents.md) for role definitions.

## Build Alias Pattern

Define aliases that wrap raw build tools:

```bash
# In ~/.zshenv or project-specific shell config
alias project-build="cd /path/to/project && ./gradlew assembleDebug"
alias project-test="cd /path/to/project && ./gradlew testDebugUnitTest"
alias project-lint="cd /path/to/project && ./gradlew detekt lintDebug"
```

Benefits:
- **Encapsulation:** The correct flags, target, and configuration are fixed. Agents cannot invent wrong combinations.
- **Allowlisting:** `Bash(project-build)` is a clean permission. `Bash(./gradlew *)` is a wildcard that permits anything.
- **Portability:** Switch from Gradle to Bazel by changing the alias, not every agent definition.

## Secrets Safety

### Before committing
Check for sensitive files in staged changes. Common patterns to block:

- `.env`, `.env.*` — environment variables with secrets
- `*.jks`, `*.keystore` — Android signing keys
- `*.p12`, `*.mobileprovision` — iOS signing
- `GoogleService-Info.plist`, `google-services.json` — Firebase config
- `*.pem` — certificates and private keys

### Pre-commit hooks
Use tools like `gitleaks` in a pre-commit hook to scan for secret patterns (API keys, tokens, passwords) in staged diffs. The hook runs on every commit, catching secrets that file-pattern matching misses.

An agent-side complement: this repo's [hooks/secret-detector.sh](../hooks/secret-detector.sh) runs as a Claude Code PreToolUse hook, denying Bash, Write, Edit, MultiEdit, NotebookEdit and git commit-message calls whose content matches secret patterns — catching the secret before it ever reaches the working tree, rather than at commit time. It also denies a Bash call that prints a macOS Keychain secret (`security find-generic-password -w` and its relatives), so the normal routes to a Keychain value are screened. A command built at run time still gets past it; only a sandbox stops that.

The hook never sees the Read tool, so **path screening belongs to permission rules**: hooks screen content, and `Read(...)` deny rules screen paths (`/setup-claude` installs them for `.env` files, keys, cloud and tool credentials, and keychains). Neither stops a program that opens the file itself (`grep -r` from a parent directory, a script); only a sandbox does. The rules leave `.env.production`, `.env.staging`, `.env.test`, `.env.example` and `.env.sample` readable as public build config, so no secret may live in them.

### In code and logs
- **Never log secrets or PII.** API keys, auth tokens, base URLs with credentials, user email addresses — none of these should appear in log output.
- **Middleware-level stripping:** If your logging framework supports middleware, add a filter that strips known secret patterns before output reaches any logger.
- **Test data:** Do not use real API keys or real user data in test fixtures. Use obviously fake values (`"api_key": "test-key-not-real"`).

### In agent context
Agents see your code, including secrets that might be hardcoded. The command whitelist prevents them from exfiltrating secrets via `curl` or `web_search`, but be aware that secrets in code are visible to the model.

## Settings Configuration

### Claude Code
`.claude/settings.json` at project root defines project-level permissions. `.claude/settings.local.json` adds local overrides (gitignored).

```json
{
  "permissions": {
    "allow": ["Bash(project-build)", "Bash(git status*)"]
  },
  "enabledPlugins": {
    "swift-lsp@claude-plugins-official": true
  }
}
```

User-level settings (`~/.claude/settings.json`) apply across all projects. Project settings take precedence for the project scope.

### Cursor
`.cursorignore` controls file visibility. Sandbox settings control command execution. MCP servers configured in `.cursor/mcp.json`.

### Per-repo vs user-level
- **Project settings:** Command allowlists, plugins, MCP servers specific to this project.
- **User settings:** Global preferences, default permissions, tools you always want enabled.
- **Local settings (gitignored):** API keys for MCP servers, personal overrides, debug flags.

## Case Study: Whitelist Consolidation

One project's command whitelist was initially defined inline in 7 files: orchestrator agent, both platform agents, story-prep agent, parity reviewer, command-whitelist rule, and orchestrator-context rule. Each copy was ~200 tokens. Total: ~1,400 tokens wasted on every session.

The consolidation kept a short inline policy in each agent (about 50 tokens: allowed categories and key prohibitions) and moved the full list to one always-applied rule that everything else references, about 1,000 fewer tokens per session. That rule is reference only: what actually binds is the `settings.json` permission list (allow and deny) and hooks. See [01-project-instructions.md](01-project-instructions.md) for the canonical-source pattern.

The `settings.json` permission list evolved to be specific: `Bash(project-build)` rather than `Bash(*)`. This meant new commands needed explicit addition, which was minor friction — but it also meant a confused agent could not run arbitrary shell commands, which was a major safety win.

## Case Study: A Distributed Permission Baseline

A team onboarding kit installs a three-tier permission model: careful, recommended and full. A secrets hook sits beside it, and managed settings (`disableBypassPermissionsMode`, `disableAutoMode`) hold the rules people must not override. The tiers and the managed-settings split are sound. Its failures teach more than its successes, because each one looks guarded in the file and is open in practice:

| Gap | Why it fails | Fix |
|---|---|---|
| Secrets hook matcher `Bash` only, `Read(*)` pre-allowed | The hook never sees the Read tool, so `.env` is one Read call away | Screen paths with `Read(...)` deny rules; keep hooks for content (see [Secrets Safety](#secrets-safety)) |
| `Bash(git push --force *)` deny | A Bash rule matches the command's shape: `git push origin main --force` doesn't fit the pattern | Deny the dangerous word wherever it appears, in a hook; a pattern rule stops only the spellings it names |
| `Read(~/.ssh/**)` deny beside a pre-allowed script runner | Current Claude Code applies Read denies to the Bash readers it recognises (`cat`, `head`, `sed`), but not to a script or `grep -r` that opens the file itself | Treat Read denies as tool-level only; reach for a sandbox when the file must be unreachable |
| Union-only settings merge | Lists only gain entries, so moving from full to careful leaves `Bash(*)` in place: the merge can't tighten | Track the keys a preset manages, and replace those lists instead of merging them |
| Policy text names a "second hook" | The settings file registers one: the docs and the behaviour drifted | Assert what the docs claim, as `/setup-claude`'s drift check does for hooks |

- **Never** count a deny rule as protection until the bypass spellings have been tried: reordered flags, another tool, another reader.
- A regex guardrail is a deterrent, and its false-positive rate decides whether people keep it on. Measure the denies before adding words.
