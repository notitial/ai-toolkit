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

- **Enabled:** `enabledPlugins` maps `<plugin>@<marketplace>` to `true` or `false`. It can sit in `.claude/settings.json` (project, committed), `.claude/settings.local.json` (local) and `~/.claude/settings.json` (user). Local overrides project, project overrides user; an explicit `false` at a higher scope turns the plugin off. Match the plugin name before the `@`; the marketplace part can differ.
- **Installed:** enabled in a project's `settings.json` only does not load the plugin; it must also be installed on the machine. `~/.claude/plugins/installed_plugins.json` records installs and may be read. Report "enabled, install not found" when the plugin is enabled but absent there.
- **Binary:** the plugin does not include the language server. Check `command -v <binary>`. The binary must be on the `PATH` of the shell that starts `claude`; the audit's shell may differ, so word a miss as "not found on PATH in this shell".
- **Scope of the tool:** the `LSP` tool is read-only and runs in terminal sessions. It does not run in cloud sessions. Do not claim more than that.
- **Main languages:** tally source files by extension, ignoring dependency and build folders. Treat a language as main when it has a meaningful share of the source files (a few percent, or the top two or three languages). Skip docs-only extensions (`.md`, `.json`, `.yml`).
