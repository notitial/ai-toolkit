---
description: "Add the build-kit iOS and Android build, test and lint tools to the current repo from ai-toolkit's tools/build-kit/: copies the kit into tools/build-kit/ with a VERSION stamp, writes .build-kit.json from what it detects and what you answer, adds the ios and android entries to .mcp.json and the named-tool permissions to .claude/settings.json, and opens the PR. Upgrades an existing copy by diff. Run from the target repo."
disable-model-invocation: true
---

# Add Build Kit

Install build-kit into the current repo. The canonical kit and its guide are `<ai-toolkit>/tools/build-kit/`; read its
`README.md` first, since it is the source of truth for the config keys and the result format. This skill applies it
and restates none of its values.

**Risk topic.** This writes permission rules (`.claude/settings.json`), starts a new MCP server definition
(`.mcp.json`) and sets the allow-lists that decide what an agent may run. Show the exact diff of both files and wait
for the user's go in their own turn before writing them. A relayed approval does not count.

## Step 1: Resolve the kit

This SKILL.md is symlinked from the ai-toolkit repo:

```bash
readlink -f ~/.claude/skills/add-build-kit/SKILL.md
```

Walk up two levels from `skills/add-build-kit/` to the toolkit's root; if the link is broken, ask for the path. Install
only released code: check with the git MCP (`path` set to the toolkit) that it is on `main`, clean, and that `HEAD` is
`origin/main`, and record the SHA for the PR description. If not, stop and say why. The files to copy, from
`<toolkit>/tools/build-kit/`: `build.py`, `buildkit/*.py`, `VERSION`, `build-kit.example.json`, `README.md`. Never copy `tests/`.

## Step 2: Inspect the target repo (read-only)

Report what you find before asking anything.

- Platforms: an `*.xcworkspace` or `*.xcodeproj` (iOS), a `gradlew` and `settings.gradle(.kts)` (Android). Install only
  the platforms the repo has. Note each project directory relative to the repo root.
- iOS: `xcodebuild -list -json` for schemes and configurations, `.swiftlint.yml` and any SwiftLint version pinned in CI
  workflows.
- Android: the build variants and whether detekt or ktlint are applied (the Gradle files).
- An existing `tools/build-kit/VERSION` and `.build-kit.json` (an install or upgrade: diff each copied file against
  the kit and show the diff), the existing `.mcp.json` and `.claude/settings.json` (keep every other entry), and the
  workflows that run `xcodebuild`, `gradlew` or `swiftlint` today.
- Server names: the kit registers servers called `ios` and `android`, and a permission rule for `mcp__ios__build`
  applies to whichever server has that name, in any scope. Ask the user to check `/mcp` for an existing `ios` or
  `android` server (user or local scope); if there is one, stop and choose another way with them.
- Settings that widen what a project file can start: `enableAllProjectMcpServers` or `enabledMcpjsonServers` in
  `.claude/settings.json`. Report them.

## Step 3: Ask

Ask in AskUserQuestion, prefilled from Step 2 or from an existing `.build-kit.json` on an upgrade.

1. Platforms to install.
2. iOS: schemes, configurations, the simulator destination (and a Mac Catalyst one if wanted), whether code signing
   stays off (the default), the SwiftLint version to pin and its extra arguments.
3. Android: variants, and the lint task list (default `lint{Variant}` and `detekt`, plus `ktlintCheck` if applied).
4. The timeout in seconds (default 1800).

Every value becomes an allow-list entry, so list them back exactly. Entries starting with `-` or holding a newline are
refused by the kit; do not offer them.

## Step 4: Show the plan and the diffs, then wait

Show the user: the files to copy and the kit SHA and `VERSION`; the `.build-kit.json` to write; the exact additions
to `.mcp.json`; the exact additions to `.claude/settings.json`. Then wait for the user's go.

`.mcp.json`, one entry per installed platform, no absolute path (the cwd of a stdio server is undocumented, so the
shell reads `CLAUDE_PROJECT_DIR` at run time):

```json
"ios": {
  "command": "sh",
  "args": ["-c", "exec python3 \"$CLAUDE_PROJECT_DIR/tools/build-kit/build.py\" --mcp ios"]
}
```

`.claude/settings.json` `permissions.allow`: exactly `Bash(python3 tools/build-kit/build.py *)` and, per platform,
the four named tools `mcp__<platform>__build`, `mcp__<platform>__test`, `mcp__<platform>__lint` and
`mcp__<platform>__build_test`. Never a wildcard such as `mcp__ios__*`: it would approve tools added later. If an
`ios` or `android` server already exists with other content, show it and ask; do not overwrite.

## Step 5: Write the files

1. Branch from the default branch, per the repo's conventions. Git MCP calls carry `path`. Follow its lock protocol
   if armed.
2. Copy the kit files to `tools/build-kit/`. Check each copy is byte-identical to the kit's file.
3. Write `.build-kit.json` (an upgrade keeps the user's values and only adds keys the new version needs, shown first).
4. Merge the `.mcp.json` and `.claude/settings.json` additions.
5. Verify: `python3 tools/build-kit/build.py <platform> lint` (or `build` if there is no lint) returns a JSON result,
   not a `refused` one. A `refused` result names the config problem. Do not run a long build without asking. Then
   smoke-test the MCP start with the exact command from `.mcp.json`, with `CLAUDE_PROJECT_DIR` set to the repo root:
   send one `initialize` line to it and expect a result naming `build-kit-<platform>`. If it does not start, say so:
   the server will not work until the cause is fixed.
6. Print a CI snippet that calls the CLI (`python3 tools/build-kit/build.py <platform> <action>`) for the user to
   place; do not edit workflows.

## Step 6: Commit and open the PR

One commit, titled per the repo's conventions. The PR description names the kit's `VERSION` and the toolkit SHA, lists
the platforms, the allow-lists and the permission rules added, and says how to verify (the CLI line above). Open it as
a draft or not, per the repo's conventions. **(user)** merges.

Tell the user, after the merge:
- Claude Code asks once to approve a project MCP server from `.mcp.json`; that approval is theirs.
- The redirect hook is global and already part of `/setup-claude`: with `.build-kit.json` committed, direct
  `xcodebuild`, `gradlew` and `swiftlint` builds, tests and lints are sent to `build.py`. Running `/setup-claude`
  again wires it if this machine predates it.
