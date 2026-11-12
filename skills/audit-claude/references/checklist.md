# Audit Checklist

Evaluation criteria distilled from the knowledge base in `docs/`. Each check produces PASS, PARTIAL, MISSING, or N/A. A check the shell refused or could not run is reported as "not verified", with the reason, instead of a status.

**Owned global files.** Files the repo keeps at its root as the source of the global layer (`rules/`, `agents/`, `skills/`, `hooks/`, linked into `~/.claude`; Step 1) are the project's own. Categories 2, 3, 4 and 8 and the classification evaluate them as if they sat under `.claude/`. Inherited global files are never scored.

**Global by design.** When a project deliberately keeps a thing at user level (permissions in user settings, rules installed globally), checks 2.1, 2.3, 5.1, 5.2, 5.7 and 7.3 may put `global by design: <evidence>` at the start of Detail instead of a bare MISSING. Evidence is the project text that states the choice, or the key names Step 1 extracts (`permissions`, a rule link whose target is in this repo). The status does not change: the classification still needs what Level A needs, and the Global layer note explains the gap. For 2.3 and 7.3 in a repo that owns the global layer, the owned always-on rules are the product it installs: score them as written (they count), mark the Detail `global by design`, and name in Detail any rule or section that applies only under a condition (it loads in every session anyway) as a candidate for on-demand loading.

## Category 1: Project Instructions (docs 01, 08)

Heading words are hints. A section check passes when a section's content covers the topic, whatever its heading.

| # | Check | How to verify |
|---|-------|---------------|
| 1.1 | CLAUDE.md exists at repo root | Glob for `CLAUDE.md` in root |
| 1.2 | Has Project Overview section | Scan for H2 containing "overview" or "what this is" |
| 1.3 | Has Build/Test/Lint section | Scan for H2 containing "build", "test", or "lint". If no build system, section should say so explicitly |
| 1.4 | Has Architecture or Structure section | Scan for H2 containing "architecture", "structure", "stack" or "layout", or any section whose content covers it |
| 1.5 | Has Conventions section | Scan for H2 containing "conventions", "patterns", or "style" |
| 1.6 | Has Git Conventions section | Scan for H2 containing "git", or git rules (commit format, branch naming) under another section such as Conventions |
| 1.7 | Has Key Paths table | Scan for a markdown table or path list that the file treats as its map of the repo (a Key Paths, Layout or ownership table). Any column header counts |
| 1.8 | Under 200 lines | Count lines. PARTIAL if 200-250, MISSING if >250. Detail also gives bytes (`wc -c`) and a token estimate (bytes / 4): long wrapped lines make a line count understate the weight |
| 1.9 | Uses imperative voice | Spot-check for "Use", "Do not", "Run" vs passive "It is recommended", "We prefer" |
| 1.10 | No code examples consuming token budget | Check for fenced code blocks longer than 10 lines — these belong in rules or docs |
| 1.11 | No content that belongs in rules | Check for domain-specific or path-scoped guidance that should be a rule instead. In a repo that runs the review kit (check 2.10) the target is a nested `CLAUDE.md`, not `.claude/rules/`. When 2.1 is MISSING because no rules directory exists, count that cause once, in 2.1: 1.11 is N/A and its Detail names the content. In a repo that runs the review kit, a rule spanning several folders must stay in the root `CLAUDE.md` (doc 02, "Rules the PR review must enforce"): keeping it there is not a 1.11 gap |
| 1.12 | Key paths still exist | Glob every path in the 1.7 table or list, in whatever column or position it sits (relative to the file that holds it; strip backticks and a trailing `/`; a wildcard needs at least one match). Skip paths outside the repo (`~`, absolute, URLs), `<name>` placeholders, and paths the file says live in another repo; list the skipped ones in Detail. A path that `.gitignore` lists and that is absent is generated or local: note it, do not count it. PASS when all exist, PARTIAL naming every missing path, MISSING when none exist. N/A when 1.7 found no table or list |

## Category 2: Rules (docs 02, 08)

| # | Check | How to verify |
|---|-------|---------------|
| 2.1 | Rules directory exists | Glob for `.claude/rules/` or `.cursor/rules/`. Also glob root `rules/*.md`: when its files are linked into `~/.claude/rules` (Step 1) the rules exist but sit outside the discoverable location, so PARTIAL (a fresh clone does not load them). A rule file is a Level A criterion, so a project with none is MISSING |
| 2.2 | Each rule has proper frontmatter | Read each rule file: a path-scoped Claude Code rule needs `paths` (one without it is always-on, counted in 2.3), Cursor needs `globs` or `alwaysApply`. An owned global rule (root `rules/`) takes no frontmatter: it is always-on by design |
| 2.3 | No more than 3-4 always-on rules | Count the always-on rules that really load: `alwaysApply: true` (Cursor), no `paths` field in `.claude/rules/` (Claude Code), or a root `rules/` file whose link exists in `~/.claude/rules`. A root rule with no link loads nowhere and is not counted |
| 2.4 | Each rule under 300 lines | Count lines per rule file |
| 2.5 | One rule = one concern | Check if any rule covers multiple unrelated topics (git + code style + naming = kitchen-sink) |
| 2.6 | No duplication across rules | Grep for repeated directives across rule files and CLAUDE.md |
| 2.7 | Do/Don't markers present | Check for explicit "Do not", "Never", "Forbidden" vs hedging "try to avoid", "consider" |
| 2.8 | No hardcoded absolute paths | Grep for `/Users/`, `/home/`, `C:\` in rule files |
| 2.9 | Canonical ownership clear | Each major concern (logging policy, naming, security) should trace to exactly one file |
| 2.10 | Review-enforced rules sit where the review reads | N/A without `.github/workflows/claude-review.yml`. With it, the review kit's written-rules pass reads only `CLAUDE.md` files (root, and nested ones in changed directories), never `.claude/rules/` (`tools/claude-review/claude-pr-review.md`, section 5). PARTIAL naming each path-scoped rule in `.claude/rules/` that states code rules (Do/Don't constraints) with no nested `CLAUDE.md` in that folder to carry them: the review leaves them unenforced. A docs-standards rule in a docs-first repo is in scope: the review checks whatever the diff changes. A rule is judged by its constraints, not its prose: a rule that mixes descriptive paragraphs with Do/Don't lines (for example a paragraph on why headings stay short, then "Do not nest lists deeper than two levels") counts when at least one Do/Don't line is there, and is out of scope when it has none. Recommend a nested `CLAUDE.md` (doc 02, "Rules the PR review must enforce") |

## Category 3: Agents (doc 03)

| # | Check | How to verify |
|---|-------|---------------|
| 3.1 | Agent definitions exist | Glob for `.claude/agents/*.md`, `.cursor/agents/*.md` or owned root `agents/*.md`. N/A when none exist, as the maturity criteria say: agents are optional below Level C, and the classification judges the Level C need. Never MISSING |
| 3.2 | Each agent has identity and scope | Read each agent: does it state what it's responsible for and what directory/repo it operates in? |
| 3.3 | Tool scoping per role | Check frontmatter `tools` field (Claude Code) or execution policy prose. Reviewers should not have Write. Coordinators should not have Build |
| 3.4 | Execution policy inline | Each agent should contain its own allowed/prohibited commands block — not reference an external file |
| 3.5 | Report format defined | Check for a structured report template (status, commit, files, blockers) |
| 3.6 | Model selection matches the role's stakes | Check `model` frontmatter. Haiku for lightweight lookups, Sonnet for implementation and routine review, Opus where a miss is costly (security, architecture, payments). An advisory, read-only role is judged by what its miss costs: Sonnet passes when a person or a later reviewer acts on its output, Opus is expected only when its verdict gates a change on its own |
| 3.7 | No command chaining in execution policy | Grep for `&&`, `||`, `;` in allowed commands sections |

## Category 4: Skills (doc 04)

| # | Check | How to verify |
|---|-------|---------------|
| 4.1 | Skills directory exists | Glob for `.claude/skills/*/SKILL.md`, `.claude/commands/*.md` or owned root `skills/*/SKILL.md`. Also glob `.claude/skills/*.md` — flat skill files are not recognized by Claude Code; flag any found and recommend restructuring into `<name>/SKILL.md` directories |
| 4.2 | Each skill has description field | Read frontmatter for `description` — needed for auto-triggering |
| 4.3 | Steps are concrete | Check that steps reference specific paths, commands, or tools — not abstract instructions |
| 4.4 | Output format defined | Check for explicit output template or format specification. A one-shot check-and-confirm skill (setup, install, audit-and-fix) that ends in a verify step stating the wanted result needs no template: PASS |
| 4.5 | Stop conditions defined | For iterative skills: check for iteration cap, convergence criteria, or explicit "when to stop" |
| 4.6 | `disable-model-invocation: true` set on skills with side effects | Check frontmatter. The flag is a behaviour switch (doc 04, "Low context cost when idle"): only the user can start the skill. A skill with side effects (deploy, scaffold, commit) without it is MISSING. A side effect is a write outside the working notes: a write only under `.archive/` or the tool's own state folder (such as `~/.claude/.eta/`) is not one, so such a skill is PASS with or without the flag. A skill or command without side effects is PASS without it: for a trigger-style skill auto-triggering is its point, and a command invoked from CI or by hand has nothing to guard (note the idle context cost in Detail as information). A side-effect skill that is deliberately model-invoked is PASS when its description or CLAUDE.md says so, PARTIAL when that is only implied |

## Category 5: Permissions and Safety (doc 05)

| # | Check | How to verify |
|---|-------|---------------|
| 5.1 | settings.json exists | Check `.claude/settings.json`. MISSING when absent, with `global by design` if the project keeps its permissions at user level (evidence: the `permissions` key names). When 5.1 is MISSING, 5.2-5.4 and 5.8 are N/A |
| 5.2 | Permissions use specific patterns | Read `permissions.allow` in `.claude/settings.json` — flag `Bash(*)` or overly broad patterns |
| 5.3 | No web tools unless justified | Check `permissions.allow` for `curl`, `wget`, `fetch` |
| 5.4 | Build commands wrapped in aliases | Check if raw build tools (`xcodebuild`, `gradlew`, `cargo`) appear vs project aliases |
| 5.5 | .gitignore covers settings.local.json | Read .gitignore for `.claude/settings.local.json` |
| 5.6 | Secret patterns excluded | Check .gitignore for `.env`, `*.jks`, `*.pem`, `*.p12`, `credentials.*` |
| 5.7 | Git MCP server configured when available | Check `~/.claude/mcp.json`, project `.mcp.json` and the user-scope `mcpServers` key names in `~/.claude.json` (names only: that file holds private data, Step 1) for a git MCP server (e.g., `git-mcp`). A server a plugin provides is in none of these files: if the session has git MCP tools but no file names one, report "not verified". If present, verify MCP git permissions exist in `permissions.allow`: the project file is read in full; for the user file take the one filtered count Step 1 allows (never the entries). If absent, recommend as improvement — do not penalize |
| 5.8 | No Bash git permissions when MCP available | If a git MCP server is configured, flag any remaining `Bash(git *)` entries in `permissions.allow` as migrable to MCP equivalents. N/A if no git MCP is configured |

## Category 6: Git Safety (docs 01, 05)

| # | Check | How to verify |
|---|-------|---------------|
| 6.1 | Commit message format documented | Check CLAUDE.md for commit format guidance (conventional commits, imperative mood, etc.) |
| 6.2 | Force-push restrictions mentioned | Check for "no force push" or equivalent in CLAUDE.md or rules. A global git guard hook also counts, as PASS with Detail `by global hook <name>, body not read`. Look in the `~/.claude/hooks/` listing (Step 1), the `hooks` key names of `~/.claude/settings.json`, and the project `.claude/settings.json`; judge from names only and never read a hook body |
| 6.3 | Secret-checking guidance present | Check for pre-commit hook references, gitleaks, or manual secret-check instructions |
| 6.4 | One-commit-per-task policy | For multi-agent setups: check orchestrator instructions for per-task commit guidance |

## Category 7: Context Efficiency (docs 08, 13)

| # | Check | How to verify |
|---|-------|---------------|
| 7.1 | CLAUDE.md under 200 lines | Already checked in 1.8 — reference that result |
| 7.2 | Rules under 300 lines each | Already checked in 2.4 — reference that result |
| 7.3 | Total always-loaded token estimate reasonable | Estimate: CLAUDE.md lines + sum of always-on rule lines, with bytes and a token estimate (bytes / 4). Status comes from the project-only token estimate: flag above about 4,000 tokens. Tokens decide; the line count (300 lines is roughly 4,000 tokens) is context, so a file of 234 long lines can still be flagged. Count only always-on rules that really load (2.3), owned global rules included. Also report the total with the inherited global instruction files (`~/.claude/CLAUDE.md`, `~/.claude/rules/*.md` not owned by this repo) in Detail, as information |
| 7.4 | No directive duplication across files | Grep for common repeated phrases across CLAUDE.md, rules, agent definitions |
| 7.5 | No verbose content in always-loaded positions | Check for long code examples, full API specs, or reference tables in CLAUDE.md or always-on rules |
| 7.6 | Orchestrator context discipline present | If the project runs orchestrators: check for guidance that treats extended thinking as garbage-collectable (compact on task/state boundaries), delegates heavy self-contained legwork to subagents that return evidence not a verdict, and guards resume specs against wholesale re-reads. This is usually **inherited from the global install** (`~/.claude/skills/{prep-compact,handover}` + the global CLAUDE.md "Subagents & Delegation" line), which project-local discovery does not glob — check there before concluding it is absent, and report MISSING only if the project defines its OWN orchestrator/resume machinery that lacks it. Grep for a `13-orchestrator-context-discipline` reference or the phrase "re-read only specific ranges, never wholesale". N/A for non-orchestrator projects. See docs/13 |

## Category 8: Orchestration Readiness (docs 12, 11, 10, 13) — Level C only

| # | Check | How to verify |
|---|-------|---------------|
| 8.1 | Checkpoint mechanism defined | Grep for "checkpoint" in agents, skills, or docs. Check for checkpoint file pattern |
| 8.2 | Thin coordinator principle followed | If orchestrator agent exists: verify it does not have Build/Test tools and instructions say "never read code". A skill that acts as the orchestrator has no tool list: judge its instructions (it delegates building, testing and code reading to subagents). N/A only when no orchestrator exists |
| 8.3 | Convergence patterns have iteration caps | Check convergence/review skills for max pass limits (typically 2-5) |
| 8.4 | Structured report format defined | Check agent definitions for `---REPORT---` or similar delimited format. Any fixed, named-section template a parent can parse (a headed report template) passes; free prose does not |
| 8.5 | Wave-based execution present | Check orchestrator instructions for wave/batch grouping of tasks |
| 8.6 | Commit verification step exists | Check for post-completion git verification (git log check after agent reports PASS) |
| 8.7 | Severity rubric defined | Check for CRITICAL/HIGH/MEDIUM/LOW or equivalent severity scale in review agents or rules |
| 8.8 | Spec quality gate present | Check for pre-implementation validation of requirements completeness |
| 8.9 | Reviewer/generator separation | Check that code-review agents are defined as subagents with their own context (not inline self-review in the implementing agent). Reviewer agents should have read-only tool scope — no Write/Edit/Bash for modifying code. See `docs/10-reviews.md#adversarial-review-and-reviewer-failure-modes` |
| 8.10 | Reviewers are grounded and skeptical | Read each review agent. PASS if it can see test/lint/build output AND is told to assume issues exist; PARTIAL if one holds; MISSING if neither. See `docs/10-reviews.md#adversarial-review-and-reviewer-failure-modes` |
| 8.11 | Re-review / fix-loop cap has ONE loaded source of truth | The cap number is the same everywhere, lives in an always-loaded file (CLAUDE.md or rules), and doesn't grow with the loop it bounds (no "+1 per wave"). See `docs/11-convergence.md` |
| 8.12 | Review loop's terminal state is a decision, not just "escalate" | At the cap, a 2nd consecutive NO-GO or a regression, the rule names a decision (ship with filed follow-ups, revert, or one scoped question). MISSING if the only exit is escalating to a human. See `docs/11-convergence.md` |
| 8.13 | Findings have a deferred path; reviewers classify reachability | Reviewers give a reachability verdict per finding, and a defect no released client can reach can be filed as deferred instead of blocking. See `docs/10-reviews.md` |
| 8.14 | Required verifications are feasibility-checked before the loop | Before the first round, every REQUIRED check is confirmed runnable at this point in the release chain; one that can't run must not force a NO-GO. See `docs/10-reviews.md#verification-gate` |
| 8.15 | Post-compaction read discipline in resume specs | The project's own handover/continuation templates say to re-read only specific ranges of large files, never whole files. A project relying on the global `prep-compact`/`handover` skills inherits this: PASS. See `docs/13-orchestrator-context-discipline.md` |

## Category 9: Cross-Platform Parity (doc 17) — multi-platform only

| # | Check | How to verify |
|---|-------|---------------|
| 9.1 | Shared domain model defined | Check for canonical model definitions referenced by multiple platform agents or rules |
| 9.2 | Error hierarchy matching | Check for consistent error type definitions across platforms |
| 9.3 | Test naming convention shared | Check for cross-platform test naming pattern in rules or CLAUDE.md |
| 9.4 | Parity audit mechanism exists | Check for parity reviewer agent, parity table, or parity check skill |

## Category 10: Structural Context (doc 09) — Level C indicator

Runs at every maturity level, each check on its own gate: 10.1 always, 10.2 from about 50 files, 10.3 whenever a plugin or server is configured. The file count is the source file count from Step 1 (images, fonts, media, lockfiles and other assets excluded; Markdown counts, and the language tally uses the same file set).

| # | Check | How to verify |
|---|-------|---------------|
| 10.1 | Key paths table exists and is current | Already checked in 1.7 (table) and 1.12 (paths exist) — reference both results |
| 10.2 | Structural context appropriate for repo size | **Under about 50 files:** N/A, a key paths table is enough (Tier 1). **From about 50 files (Tier 2):** CLAUDE.md or a rule names golden files. A golden file is a path the file presents as a pattern or example to copy; other path mentions (ownership, review rules, key paths) do not count. Glob every golden file or pattern named; a glob must match at least one file. PASS when at least one is named and all exist. PARTIAL naming each stale path when some are gone. MISSING when none is named, or when none of the named paths exist. **Roughly 500+ files:** also look for a CLAUDE.md in major subdirectories; PARTIAL if those and the golden files are thin and nothing else covers navigation. A missing repo map or code graph server is never a finding on file count alone: doc 09 adds them only when its "Choosing the Right Tier" signals show Tiers 1-2 fall short |
| 10.3 | Heavier structural tooling is justified | If a code-intelligence (LSP) plugin is enabled (Step 1), or a repo map or code graph MCP server (`.mcp.json`, or a user-scope server named in `~/.claude.json`, 5.7) is configured, check that CLAUDE.md or an always-on rule mentions it. For an enabled plugin also check its binary (`which`) and an install record that applies to this repo: a plugin without its binary or install does nothing, so PARTIAL naming what is missing. Details in `references/code-intelligence.md` (what counts as a mention and as an install record). Information in Detail, status unchanged: whether the plugin is enabled in a committed file or only a local one (a verdict that rests only on a gitignored local settings file says it would differ on a fresh clone); a plugin whose language has a trivial share of the source files; the TypeScript root-config warning. N/A when nothing is configured. A plugin that is not enabled is not a finding: doc 09 treats the LSP plugin as a Tier 3 step, taken only after Tiers 1-2 fall short and after measuring. Report it in Detail as `available: <plugin>` for each main language. The LSP tool works in terminal sessions only |
| 10.4 | No entire-repo context dumps or LLM-built maps | Check for tools or scripts that flatten entire repos into single files for context injection, or generate a codebase map whose layers an LLM writes. Flag as anti-pattern if found (doc 09, Anti-Patterns) |
