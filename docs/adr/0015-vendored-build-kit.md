# 15. A Vendored Build Kit With a Standard-Library MCP Server

**Status:** accepted
**Date:** 2026-11-08

## Context

Agents working on iOS and Android projects need to build, test and lint, and the earlier per-project servers for this
had four recurring problems: model-supplied values reached a shell, the Android lint skipped detekt and the iOS lint
and build differed from CI, a call blocked for up to ten minutes with no timeout or cancel and the full parent
environment, and absolute paths into one checkout broke when it moved. The toolkit's hooks and skills are global, but
a build tool belongs to a project: its schemes, variants and lint pins are the project's.

## Options Considered

- **Where the tools live.**
  - Run from the toolkit checkout: every project would depend on one path and on the toolkit's state, and a rename
    breaks all of them. Rejected.
  - **A copy inside each project, installed and upgraded by a skill: chosen.** It follows the `claude-review` kit
    ([ADR 0013](0013-app-owned-pr-review.md)): the toolkit holds the canonical files, `/add-build-kit` copies them and
    upgrades by diff, nothing runs until a project installs it.
- **Script layer and MCP.** MCP only leaves CI and Bash users with different code; shell scripts need a second layer
  to parse results. **One Python CLI with an MCP mode on the same file: chosen**, so CI, agents in Bash and MCP clients
  run the same functions and the same validation.
- **MCP implementation.** The official Node SDK needs Node, npm and an install per project. **A small stdio server on
  the Python standard library: chosen.** The subset needed (`initialize`, `tools/list`, `tools/call`, `ping`,
  cancellation) is about 80 lines, uses one process of a few MB, and is tested over stdio. The cost is that the toolkit
  owns that protocol layer and must track the spec.
- **Redirecting direct builds.** A hook per project, or none. **One global opt-in hook: chosen.** It does nothing
  without a `.build-kit.json`, so installing it changes no other project; and it sends to the CLI, not the MCP tool, so
  a dead MCP server cannot lock agents out of building.

## Decision

`tools/build-kit/` holds a Python 3.9+ CLI (`build.py`, `buildkit/`) with `--mcp <ios|android>`. Commands are argument
lists; every model-supplied value must be on an allow-list from the project's `.build-kit.json`, as an enum in the MCP
schema and checked again in the CLI. Children run in their own process group with a timeout, MCP cancellation, a
per-project and platform lock, and an allow-listed environment. `/add-build-kit` installs it, writes the config,
`.mcp.json` entries without absolute paths and named-tool permissions (never a wildcard). `hooks/build-redirect.sh`
is wired by `/setup-claude`.

## Consequences

- A project's tools stay fixed at the installed `VERSION` until it upgrades, and fixes reach projects only through
  that upgrade.
- The allow-lists guard against what an agent sends, not against a changed `.build-kit.json` or build scripts: the
  config is reviewed like the build itself.
- The toolkit now carries an MCP server implementation; a spec change that breaks it is fixed here and shipped through
  the upgrade.
- What the kit does not cover (archive, simulator control, instrumented tests) has no route while the hook denies
  direct `xcodebuild` and build-like Gradle tasks in an opted-in project; `clean` and read-only queries pass, and the
  rest needs the user.
