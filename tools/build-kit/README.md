# build-kit

Opt-in build, test and lint tools for iOS and Android projects. A project carries its own copy, installed by
`/add-build-kit` ([skill](https://github.com/notitial/ai-toolkit/blob/main/skills/add-build-kit/SKILL.md)); nothing in a project points back at this repo, and nothing
runs anywhere until a project installs it.

- **One Python CLI** (`build.py`, Python 3.9+, standard library only: no pip, no Node, no SDK). Agents in Bash, CI and
  people all run the same code.
- **The same file serves MCP** (`build.py --mcp <ios|android>`): the four actions as typed tools with enum
  parameters, so agents can auto-approve named tools and subagents without Bash can build.
- **A global opt-in hook** ([`hooks/build-redirect.sh`](https://github.com/notitial/ai-toolkit/blob/main/hooks/build-redirect.sh)) sends direct `xcodebuild`,
  `gradlew` and `swiftlint` runs to the CLI in projects that have a `.build-kit.json`.

## Use

```bash
python3 tools/build-kit/build.py ios build
python3 tools/build-kit/build.py ios test --scheme App --destination sim
python3 tools/build-kit/build.py android lint --variant Release
python3 tools/build-kit/build.py --mcp android
```

| Action | iOS | Android |
|--------|-----|---------|
| `build` | `xcodebuild build` | `assemble<Variant>` |
| `test` | `xcodebuild test` | `test<Variant>UnitTest` |
| `build_test` | the same single `xcodebuild test` (it builds first) | `assemble` and `test` in one Gradle call |
| `lint` | `swiftlint lint` with the configured args | `lint<Variant>` and `detekt` in one Gradle call (`--continue`) |

The kit works on the project it is installed in: `build.py` finds its root from its own location
(`<project>/tools/build-kit/build.py`), so there is no flag or variable that points it at another directory, and a
permission rule for `build.py` cannot be used to build a different checkout. Every parameter is optional and defaults to
the first entry of its allow-list. Exit code: 0 passed, 2 refused, 1 anything else.

## Result

One JSON object: `ok`, `status` (`passed`, `failed`, `timeout`, `cancelled`, `log_limit`, `busy`, `refused`, `error`),
`exit_code`, `duration_s`, `timed_out`, `error_count` and `errors` (`file`, `line`, `col`, `message`; the first 50),
`warnings` (a count), `tests` (`passed`, `failed`, `skipped`, `failures`, `source`; for `test` and `build_test`),
`notes`, `log` (the output, up to 100 MB) and `tail` (its last lines). Nothing is cut silently: the log has everything (a build
that prints more than 100 MB is stopped, status `log_limit`). `ok` follows the exit code; a note says when errors are
listed for an exit code 0, or when Gradle wrote no fresh report (a task it skipped as up to date).

- iOS errors and warnings come from `file:line:col: error:` lines; test counts from `xcresulttool` on the result
  bundle, else from XCTest lines in the log.
- Android adds the Kotlin and javac lines; `lint` reads Android lint XML and detekt checkstyle XML, and `test` JUnit XML, from regular
  files written during the run, in any module folder under the project (not through links, in hidden folders or over
  5 MB; a report with a DOCTYPE or ENTITY declaration is skipped with a note).
- Logs, result bundles, the lock and the SwiftLint cache live in `~/.cache/build-kit/<project hash>/` (mode 0700, the
  last 10 runs kept), not in `/tmp`.

## Config: `.build-kit.json`

Committed at the project root; `build-kit.example.json` (beside this file) shows every key.

| Key | Meaning |
|-----|---------|
| `timeoutSeconds` | Per call, default 1800. At the limit the whole process group gets TERM, then KILL. |
| `ios.projectDir`, `android.projectDir` | Working directory, relative to the root; it may not leave the project. |
| `ios.workspace` or `ios.project` | Passed as `-workspace` or `-project`. |
| `ios.schemes`, `ios.configurations` | Allow-lists (defaults `Debug`). |
| `ios.destinations` | Name to `-destination` string. The model picks a name; the string is one argument. Omit for none. |
| `ios.codeSigning` | `false` (default) adds `CODE_SIGNING_ALLOWED=NO`. |
| `ios.swiftlint` | `version` (a mismatch with the installed one adds a note, and the local one runs) and `args`. |
| `android.variants` | Allow-list for `<Variant>` (default `Debug`). |
| `android.buildTask`, `testTask`, `lintTasks` | Gradle tasks; `{Variant}` is replaced. Defaults as in the table above. |

## What it protects, and what it does not

- Commands are argument lists, never a shell. A model-supplied value must be on its allow-list (an enum in the MCP
  schema, checked again in the CLI); anything else is refused before a process starts. Config words that look like
  options (a leading `-`) or hold a newline are refused too.
- A child gets only `PATH`, `HOME`, `USER`, locale, `TMPDIR`, `DEVELOPER_DIR`, `JAVA_HOME`, `ANDROID_HOME`,
  `ANDROID_SDK_ROOT` and `GRADLE_USER_HOME`: API keys and tokens in the parent environment do not reach a build.
- One run per project and platform at a time: a second call waits a few seconds, then returns `busy`.
- MCP cancellation, closing stdin, SIGTERM and SIGHUP stop the build's process group. A build that finishes on its own
  is not followed: processes it leaves running (a Gradle daemon) stay.
- **The config is the trust boundary.** The allow-lists protect against values an agent sends, not against a changed
  `.build-kit.json`, and a build runs the project's own code (build phases, Gradle scripts, SwiftLint config) anyway.
  Review changes to the config like changes to the build.

## Install and upgrade

Run `/add-build-kit` from the target repo. It copies `build.py`, `buildkit/`, `VERSION`, `build-kit.example.json` and
this README to `tools/build-kit/`, writes `.build-kit.json`, adds the `.mcp.json` entries (`ios` and `android`; the command is
`sh -c 'exec python3 "$CLAUDE_PROJECT_DIR/tools/build-kit/build.py" --mcp <platform>'`, so no absolute path) and the
named-tool permissions plus `Bash(python3 tools/build-kit/build.py *)`, and opens a PR. Running it again diffs the
copy against this one and upgrades. `VERSION` changes with any behaviour change.

CI calls the same CLI, for example `python3 tools/build-kit/build.py ios test --destination sim`, so local and CI runs
share their arguments.

## Known gaps

- The `xcresulttool` summary fields (`passedTests`, `failedTests`, `skippedTests`, `testFailures`) follow Xcode 16 and
  are covered by fixtures only; on another shape the counts fall back to the log.
- A SwiftLint version mismatch warns and runs the local version; there is no pinned container fallback.
- A timeout or cancel kills the build's process group; whether that includes a Gradle daemon the run started depends
  on how Gradle starts it (not verified).
- `$CLAUDE_PROJECT_DIR` is how `.mcp.json` finds the script; that Claude Code exports it to stdio servers follows its
  documentation and is checked by the installer's smoke step, not by these tests.
- `swiftlint --fix` and `autocorrect`, `-exportArchive`, package resolution and similar chores are neither redirected
  nor run by the kit.
- Out of scope: simulator boot, install and launch, UI tests, instrumented Android tests, coverage, archive and
  signing, Cursor wiring.

## Tests

```bash
python3 -I -B -m unittest discover -s tools/build-kit/tests
bash tools/build-redirect/test-build-redirect.sh
```

Fake `xcodebuild`, `xcrun`, `swiftlint` and `gradlew` on `PATH` record their arguments and environment and replay
fixture output, so the suite runs on Linux CI with no Xcode or SDK. It covers the injection strings, allow-lists,
timeout, cancel, lock, environment stripping, each parser and MCP over stdio.
