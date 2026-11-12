# Code-Intelligence Plugins

Lookup for the LSP detection in Step 1 and check 10.3. Source: Claude Code docs, [code intelligence plugins](https://code.claude.com/docs/en/plugins/code-intelligence.md) (plugin and binary columns, copied from its table). The extension column is for matching a repo's languages; the plugin's own extension list is authoritative. Re-check the table when the audit runs against a language not listed here.

| Language | Plugin id | Language-server binary | Extensions |
|----------|-----------|------------------------|------------|
| C/C++ | `clangd-lsp@claude-plugins-official` | `clangd` | `.c` `.h` `.cc` `.cpp` `.cxx` `.hpp` `.hh` |
| C# | `csharp-lsp@claude-plugins-official` | `csharp-ls` | `.cs` |
| Go | `gopls-lsp@claude-plugins-official` | `gopls` | `.go` |
| Java | `jdtls-lsp@claude-plugins-official` | `jdtls` | `.java` |
| Kotlin | `kotlin-lsp@claude-plugins-official` | `kotlin-lsp` | `.kt` `.kts` |
| Liquid | `liquid-lsp` (Shopify; listed in the official marketplace) | `shopify` (Shopify CLI) | `.liquid` |
| Lua | `lua-lsp@claude-plugins-official` | `lua-language-server` | `.lua` |
| PHP | `php-lsp@claude-plugins-official` | `intelephense` | `.php` |
| Python | `pyright-lsp@claude-plugins-official` | `pyright-langserver` | `.py` `.pyi` |
| Ruby | `ruby-lsp@claude-plugins-official` | `ruby-lsp` | `.rb` |
| Rust | `rust-analyzer-lsp@claude-plugins-official` | `rust-analyzer` | `.rs` |
| Swift | `swift-lsp@claude-plugins-official` | `sourcekit-lsp` (ships with Xcode or the Swift toolchain) | `.swift` |
| TypeScript and JavaScript | `typescript-lsp@claude-plugins-official` | `typescript-language-server` | `.ts` `.tsx` `.js` `.jsx` `.mts` `.cts` `.mjs` `.cjs` |

## How the facts are read

- **Enabled:** `enabledPlugins` maps `<plugin>@<marketplace>` to `true` or `false`. It can sit in `.claude/settings.json` (project, committed), `.claude/settings.local.json` (local, gitignored) and `~/.claude/settings.json` (user). Local overrides project, project overrides user; an explicit `false` at a higher scope turns the plugin off. Match the plugin name before the `@`; the marketplace part can differ. Extract only that key (SKILL.md, Settings privacy). Report where it is enabled: a plugin enabled only in a local or user file is absent from a fresh clone, which is worth a Detail line.
- **Installed:** enabled in a settings file does not load the plugin; it must also be installed on the machine. `~/.claude/plugins/installed_plugins.json` records installs and may be read, with the same one-key care: print only the entries of the plugin being checked. A record counts only if its `scope` is `user`, or its `projectPath` equals the audited repo. A record for another project's path does not install the plugin here; do not name those other paths in the report. Report "enabled, install not found" when no applicable record exists.
- **Binary:** the plugin does not include the language server. Check `which <binary>`. The binary must be on the `PATH` of the shell that starts `claude`; the audit's shell may differ, so word a miss as "not found on PATH in this shell".
- **Scope of the tool:** the `LSP` tool is read-only and runs in terminal sessions. It does not run in cloud sessions. Do not claim more than that.
- **Main languages:** tally the tracked source files (SKILL.md, Step 1) by extension. Treat a language as main when it has a meaningful share of them (a few percent, or the top two or three languages). Skip docs-only extensions (`.md`, `.json`, `.yml`).
- **Trivial share:** an enabled plugin whose language has under about 2% of the tracked source files (a single file in a large repo) is information in Detail: the plugin may not be paying off. A measured result that says so counts the same.
- **CLAUDE.md mentions it:** CLAUDE.md or an always-on rule names the plugin, its LSP tool, its language server, or a measured result of using it. A key-paths row or an unrelated word match does not count.
- **TypeScript root config:** for an enabled `typescript-lsp`, if the repo root has no `tsconfig.json`, or the root one is solution-style (`"files": []` plus `references`), warn in Detail that a language server started at the root may not apply the subproject's `paths` aliases or find its `typescript`. Two real installs failed this way. Status unchanged.
- **Not enabled:** information only, never PARTIAL or MISSING, whatever the file count.
