# Structural Context

How agents understand codebase structure — from static key-paths tables to code graph servers.

## The Problem

AI coding agents have no persistent memory of codebase structure. Every session starts from zero: the agent globs for files, reads a few, builds a mental model, then loses it when the conversation ends. In a 30-file project this costs seconds. In a 2,000-file monorepo it can consume 60-80% of tokens on orientation before the agent writes a single line of code.

The core issue is asymmetry: agents have powerful tools for reading and searching (glob, grep, read) but no structural overview of what exists, how it connects, or where to start. Without a map, the agent navigates by breadcrumb — each file read reveals the next file to read, burning context on exploration rather than problem-solving.

This document covers the spectrum of solutions, from lightweight static documentation to dynamic code graph servers, and when to use each.

## The Spectrum of Structural Context

Four tiers of structural context, each appropriate for different repo sizes and complexities. Each tier builds on the one before it — you do not skip levels.

### Tier 1: Key Paths Table (under ~50 files)

A markdown table in CLAUDE.md mapping directory paths to purposes. This is the minimum viable structural context and is sufficient for small, focused projects.

```markdown
## Key Paths

| Path | Purpose |
|------|---------|
| src/api/ | REST endpoints and middleware |
| src/models/ | Database models and migrations |
| src/services/ | Business logic layer |
| tests/ | Test suite (mirrors src/ structure) |
| docs/ | Project documentation |
```

The key paths table is the highest-value section per token spent in any instruction file (see [01-project-instructions.md](01-project-instructions.md)). Without it, agents waste tool calls searching for files they could navigate to directly.

**When Tier 1 is enough:** The agent can hold the entire project structure in working memory from the table alone. Cross-module dependencies are few enough that a sentence or two in the architecture section covers them.

### Tier 2: Golden Files (roughly 50-500 files)

When a project has multiple instances of the same pattern (controllers, services, tests, components), a key paths table tells the agent *where* things are but not *how* they should look. Golden files solve this by pointing to specific, well-written examples the agent should follow.

```markdown
## Patterns

When creating new files, follow these reference implementations:
- Controllers: `src/api/controllers/orders.controller.ts`
- Services: `src/services/billing.service.ts`
- Integration tests: `tests/integration/auth.test.ts`
```

The selection is manual and intentional — pick files that represent your team's ideal implementation. Start with 2-3 golden files for your most common patterns, then add more only when agents produce inconsistent results in a specific area.

Golden files work because concrete code examples consistently outperform abstract style descriptions. "Follow the pattern in `orders.controller.ts`" is more effective than a paragraph describing controller conventions.

**When Tier 2 is enough:** The agent can find what it needs by reading the key paths table and golden files, plus a few targeted searches. It does not repeatedly ask "where is X?" or produce code that ignores existing abstractions.

### Tier 3: Repo Maps (roughly 500-10,000 files)

At this scale, static documentation cannot capture enough structure. The agent needs a compact, machine-generated summary of the codebase — a repo map.

A repo map is a token-budgeted structural summary showing the most relevant files, classes, and function signatures without implementation bodies. The proven approach (pioneered by Aider) uses tree-sitter to parse every file, extracts definitions and references, builds a file dependency graph, then ranks by relevance using PageRank.

The output format is indented plaintext showing file paths with nested symbol signatures:

```
src/auth/handler.py:
    class AuthHandler:
        def authenticate(self, token: str) -> User:
        def refresh(self, session: Session) -> Token:

src/api/routes.py:
    def register_routes(app: Flask) -> None:
    def health_check() -> dict:

src/models/user.py:
    class User(BaseModel):
        id: int
        email: str
        def validate_email(self) -> bool:
```

This format compresses a codebase to roughly 5-10% of its original token count while retaining the structural information agents need for architectural reasoning. Key properties of an effective repo map:

- **Token-budgeted.** The map fits a fixed token budget (typically 1,000-4,000 tokens). A ranking algorithm decides what to include and what to cut.
- **Dynamically re-ranked.** The best implementations re-rank the map per query, boosting symbols relevant to what the user is currently asking about.
- **Definitions over implementations.** Class names, method signatures, and type annotations are included. Function bodies are not. The agent reads full implementations only when it needs to.
- **Cached and incremental.** Initial parsing may be slow on large repos, but results are cached and updated as files change.

Repo maps can be generated by standalone tools or exposed through MCP servers. The specific tool matters less than the pattern: tree-sitter parse → dependency graph → relevance ranking → token-budgeted output.

**When Tier 3 is enough:** The agent can orient itself using the repo map and reach the right files in 1-2 tool calls instead of 5-10. Cross-module relationships are visible from the map.

### Tier 4: Code Graph Servers (10,000+ files or complex dependency chains)

For very large or highly interconnected codebases, a static repo map is not sufficient. The agent needs to *query* the codebase structure on demand — asking questions like "what calls this function?", "what breaks if I change this type?", or "show me the dependency chain from service A to service B."

Code graph servers are MCP servers that build a persistent structural index of the codebase and expose query tools. The common architecture:

1. **Index:** Tree-sitter parses all files into an AST. Definitions, references, call sites, imports, and inheritance relationships are extracted.
2. **Store:** The extracted graph is stored in a database (SQLite, graph DB, or in-memory). Nodes are symbols (functions, classes, methods). Edges are relationships (calls, imports, inherits, implements).
3. **Query:** MCP tools let the agent query the graph: symbol lookup, caller/callee chains, dependency traversal, impact analysis ("what files are affected if I change X?").
4. **Update:** The index updates incrementally as files change, either via file watching or git-diff-based re-indexing.

What to look for when evaluating a code graph server:

- **Local and private.** Code stays on your machine. Avoid servers that send code to external APIs.
- **Language coverage.** Tree-sitter supports 40+ languages, but query quality varies. Check that your primary languages have full support (definitions + references + call sites).
- **Incremental updates.** Re-indexing the entire repo on every change does not scale. Look for file-watching or diff-based updates.
- **Claude Code compatible.** The server must expose tools via MCP and be configurable in Claude Code's MCP settings.
- **Reasonable tool count.** Servers with 50+ tools add overhead to every conversation. Prefer servers with 10-20 focused tools.

**When Tier 4 is needed:** The agent cannot answer "what depends on X?" without reading many files. Changing a shared type or interface requires understanding impact across the codebase. Navigation by search alone misses architectural relationships.

## Choosing the Right Tier

The decision depends on repo size, interconnectedness, and observed agent behavior — not just file count.

| Signal | What it suggests |
|--------|-----------------|
| Agent finds what it needs in 1-2 searches | Current tier is sufficient |
| Agent spends 5+ tool calls on orientation before starting work | Needs a higher tier |
| Agent produces code that duplicates existing abstractions | Missing structural visibility — needs repo map or golden files |
| Agent cannot answer "what breaks if I change X?" | Needs a code graph server |
| You frequently correct the agent about where things are | Key paths table is incomplete or needs upgrade to repo map |
| Agent re-explores the same areas across sessions | Structural context is not persisting (check CLAUDE.md, consider dynamic tools) |

Start at the lowest tier that works. Over-indexing a small project wastes setup time and adds MCP tool overhead to every conversation. Under-indexing a large project wastes tokens on repeated exploration.

## Anti-Patterns

**Dumping the entire repo into context.** Tools that flatten a codebase into a single file and paste it into the prompt hit context limits quickly and add noise. Larger context windows do not improve precision — they add irrelevant content that dilutes the agent's attention. Selective, ranked context consistently outperforms exhaustive dumps.

**Vector search alone.** Embedding-based semantic search captures meaning similarity but misses structural relationships. It finds "code that looks like what you described" but cannot trace call chains, dependency graphs, or impact analysis. Vector search is a useful complement to structural indexing, not a replacement.

**Over-indexing small repos.** Installing a code graph server for a 30-file project adds MCP tool overhead (~300-500 tokens per tool in the tool list) to every conversation without proportional benefit. A key paths table and 2-3 golden files are cheaper and equally effective at this scale.

**Stale structural documentation.** Static repo maps and key-paths tables become stale as the codebase evolves. If agents trust outdated documentation, they navigate to code that has moved or been deleted. Dynamic tools (MCP servers with file watchers) solve staleness automatically. Static documentation requires periodic review.

**Ignoring the orientation cost.** If you have never measured how many tokens your agent spends before it starts productive work, you do not know whether your structural context is adequate. Watch the first 5-10 tool calls of a session — if most are exploratory searches rather than targeted reads, your structural context needs improvement.

## Case Study: Small Project vs Large Monorepo

### 30-file API Service (Tier 1 sufficient)

A focused Node.js API with `src/`, `tests/`, and `docs/`. The CLAUDE.md key paths table maps 5 directories. The agent finds any file in 1 search. Golden files are unnecessary because there is only one controller, one service, and one test pattern. Total structural context cost: ~15 lines in CLAUDE.md, zero additional tooling.

### 2,000-file Monorepo (Tier 3-4 needed)

A monorepo with 6 services, shared libraries, and cross-service dependencies. The key paths table grew to 25 entries but the agent still could not find code across service boundaries. Adding a tree-sitter-based code graph MCP server reduced orientation from ~12,000 tokens (15+ exploratory searches) to ~2,000 tokens (repo map + 2 targeted queries). The agent could now answer "what services consume this event?" without reading every service's handler directory.

The tradeoff: the MCP server added ~20 tools to the tool list (~4,000 tokens of tool descriptions) and required initial indexing (~3 minutes). For single-service work, Tier 2 (golden files + hierarchical CLAUDE.md per service) was more efficient. The code graph server earned its cost only for cross-service work.

## Relationship to Other Documents

- [01-project-instructions.md](01-project-instructions.md) — covers the key paths table (Tier 1) and instruction file structure
- [08-context-management.md](08-context-management.md) — covers token budgeting and context window optimization
- [10-permissions-and-safety.md](10-permissions-and-safety.md) — covers MCP server permissions and the MCP-over-Bash pattern
