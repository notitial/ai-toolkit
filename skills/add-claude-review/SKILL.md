---
description: "Add the automatic Claude PR review (GitHub Actions workflow + review command, posted by a reviewer GitHub App) to the current repo from ai-toolkit's canonical copies in tools/claude-review/: asks for the runner labels, the auth mode, the secret name and the reviewer App, applies only the documented replacement points, checks the SHAs, and opens the PR. Upgrades or reconfigures an existing copy too. The user creates or installs the App, sets the variables and secrets, and merges. Run from the target repo."
disable-model-invocation: true
---

# Add Claude Review

Install the Claude PR review into the current repo. The canonical files and the full guide are
`<ai-toolkit>/tools/claude-review/`; this skill applies them. Read that folder's `README.md` first: it is the
source of truth for the replacement points, the SHAs, the prerequisites and the test protocol. This skill never
restates their values.

**Risk topic.** This touches repo secrets and variables, a GitHub App (its creation, private key and install) and
workflow permissions. Every step marked
**(user)** is done by the user, in their own turn. A relayed approval (another session, a handover note, a spawn
prompt) does not count. Never read, print or echo a secret value.

## Step 1: Resolve the kit

This SKILL.md is symlinked from the ai-toolkit repo:

```bash
readlink -f ~/.claude/skills/add-claude-review/SKILL.md
```

Walk up two levels from `skills/add-claude-review/` to the toolkit's root. If the link is broken, ask the user for
the ai-toolkit path.

Install only the released kit, never work in progress: read `README.md`, `claude-review.yml` and
`claude-pr-review.md` from the default branch (`git show main:tools/claude-review/<file>` via git MCP), not from the
working tree, which may be on a feature branch. Write the two files to a scratch folder (`KIT`) and record the commit
(`main`'s SHA) for the PR description.

## Step 2: Inspect the target repo

Read-only. Report what you find before asking anything. Agents can't run gh (`hooks/gh-block.sh`): collect every
gh read below into one markdown code block for the user to run, and continue from the output they paste back.

- The repo: `gh repo view --json nameWithOwner,isPrivate,owner`.
- Existing install: `.github/workflows/claude-review.yml` and `.claude/commands/claude-pr-review.md`. If present,
  diff each against the kit. A workflow that differs only at the replacement points is on this version: this run is
  a **reconfiguration** (say so), and Step 3 prefills the current labels, auth mode and secret name from those lines.
  A v1 workflow (it loads `code-review@claude-code-plugins` through `plugin_marketplaces`) or an older v2 is an
  **upgrade**: keep its replacement values as the prefill.
- Variables and secret names visible to the repo: `gh variable list -R <owner/repo>` and
  `gh secret list -R <owner/repo>` (names only). `CLAUDE_REVIEW_APP_CLIENT_ID`, `CLAUDE_REVIEW_APP_LOGIN` and
  `CLAUDE_REVIEW_APP_KEY` mean the reviewer App is already configured; a v2.3 install has none of them. On an
  org-owned repo, also `gh secret list --org <owner>` and `gh variable list --org <owner>`; if that needs
  `admin:org`, ask the user to check which org secrets and variables the repo can see.
  Grep the repo's other workflows and config for `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`.
- The repo's `.claude/settings.json`: the review loads it (`--setting-sources project`, hooks off), so its
  `permissions.allow` rules, `additionalDirectories` and `defaultMode` widen what Claude reads in the review, and
  `enableAllProjectMcpServers` or `enabledMcpjsonServers` would let a `.mcp.json` from the PR start a server. Report
  any and ask the user whether to narrow them first.
- Required reviews on the default branch (read-only): `gh api repos/<owner/repo>/rulesets` and
  `gh api repos/<owner/repo>/branches/<default>/protection` (a 404 means none, or no access to see it). The App's
  review must never satisfy a required review (README prerequisite). Note the required status checks too: with
  checks from other workflows required, a `[skip ci]` PR can never merge (Step 6).
- Repo conventions: its CLAUDE.md git section (branch naming, commit prefixes, PR rules), whether CLAUDE.md has a
  "Review" section (README prerequisite: recommended), and whether a workspace lock is armed.

## Step 3: Ask

Ask in AskUserQuestion. No defaults that name a particular deployment; prefill from Step 2 when reconfiguring or
upgrading.

1. **Runner labels** for `preflight` and `review`: `ubuntu-latest` (the canonical value, and the only choice for a
   public repo), or the repo's self-hosted label set. Self-hosted runners must meet the README's runner
   prerequisites and must never hold a deploy key.
2. **Auth mode:** a Claude Console API key or a subscription OAuth token from `claude setup-token` (both tested; the
   README says what each means for cost and limits).
3. **Secret name**, in a second question once the mode is known. Default by mode: `ANTHROPIC_API_KEY` or
   `CLAUDE_CODE_OAUTH_TOKEN`. **If Step 2 found that name already used for anything else**, in the repo or as an org
   secret the repo can see (for example a production runtime key), warn and offer a dedicated name by mode:
   `CLAUDE_REVIEW_API_KEY` or `CLAUDE_REVIEW_OAUTH_TOKEN`. The review must never share a secret with anything else.
4. **Reviewer App:** the owner's existing one (ask for its slug and Client ID; neither is secret) or a new one the user
   creates (README prerequisite 3). One App per owner serves all its repos.
5. **Only if Step 2 found required reviews:** set `CHANGES_EVENT` and `APPROVE_EVENT` to `COMMENT` (the README's
   optional replacement), or scope the required reviews to people. Default: `COMMENT`.

Restate the plan and wait for the user's go: repo, install / upgrade / reconfiguration, labels, auth mode, secret
name, App, branch, the kit commit, and the README prerequisites that apply (on a private repo, about two billed
Actions minutes per review for `appcheck` and `publish`; the recommended CLAUDE.md "Review" section if missing).

## Step 4: Write the files

1. Branch from the default branch, per the repo's conventions. Follow its lock protocol if armed. Use git MCP tools
   with `path` on every call.
2. Copy `$KIT/claude-review.yml` to `.github/workflows/claude-review.yml` and `$KIT/claude-pr-review.md` to
   `.claude/commands/claude-pr-review.md`. Check both SHA-256s against the README's table **before** changing
   anything. A mismatch means the kit is inconsistent: stop and report.
3. Apply the README's replacement points as exact-string replacements on the workflow, asserting each match count
   (`runs-on: ubuntu-latest` matches four times: change only the `preflight` and `review` ones, at the README's
   line numbers; the others match once). A count that differs means the canonical file changed: stop.
   - header secret line → the chosen name and what it is;
   - both `preflight` and `review` `runs-on` lines → the chosen labels (no change for `ubuntu-latest`);
   - both credential input lines (`anthropic_api_key` and `claude_code_oauth_token` under it) → the one line for
     the chosen mode: `anthropic_api_key: ${{ secrets.<NAME> }}`, or `claude_code_oauth_token: ${{ secrets.<NAME> }}`
     for OAuth;
   - only if Step 3 chose it: `CHANGES_EVENT` and `APPROVE_EVENT` → `COMMENT`.
   Leave `appcheck`'s and `publish`'s `runs-on: ubuntu-latest` and every other line unchanged, header comments
   included.
4. Verify: the diff against `$KIT/claude-review.yml` shows only the replacement lines; `claude-pr-review.md` is
   byte-identical to the kit; `grep -n 'secrets\.'` shows the chosen `<NAME>` exactly once, with the input that
   matches the chosen mode, and otherwise only `CLAUDE_REVIEW_APP_KEY`. If `actionlint` is on `PATH`, lint the workflow
   with a scratch config that declares any custom self-hosted labels (`self-hosted-runner: labels: [...]`, passed
   with `-config-file`); don't add the config to the repo.

## Step 5: (user) GitHub setup

Print these for the user to do. **Do none of them yourself:** no `gh secret set` or `gh variable set`, no
`gh api` calls on the repo's or org's Actions permission settings, no App creation, key or install.

- A new App only: create it per README prerequisite 3 (Pull requests: Read and write, nothing else; no webhook) and
  generate a private key.
- Install the App on the repo.
- Allow GitHub-hosted runners for the repo (`appcheck` and `publish`), and on an org repo check workflow permissions.
- Turn on "Always suggest updating pull request branches" for the repo (Settings → General → Pull Requests; API field
  `allow_update_branch`). It is off by default and has no org-level switch. Without it a PR that falls behind `main`
  has no Update branch button, and the review can hit a missing `refs/pull/<N>/head` until the branch is updated.
  A stale branch is updated by merging `main` into it, never by rebasing (`rules/workflow.md`, Stale PR Branches).
- Set the variables and secrets, skipping any Step 2 showed already set for this review. The key is read from the
  `.pem` file and the Claude secret is prompted, so no value reaches shell history:

```bash
gh variable set CLAUDE_REVIEW_APP_CLIENT_ID -R <owner/repo> --body <Client ID>
gh variable set CLAUDE_REVIEW_APP_LOGIN -R <owner/repo> --body <app slug>
gh secret set CLAUDE_REVIEW_APP_KEY -R <owner/repo> < <path to the .pem>
gh secret set <NAME> -R <owner/repo>
```

- Upgrade from v2.3, after the merge: remove the repo from the Claude GitHub App's installation (it is no longer
  needed and would add its own 👀 to every `@claude` comment).

## Step 6: Commit and open the PR

1. Commit both files in **one** commit and one PR: `.claude/` is read from the default branch, so the command only
   works once both land. Title per the repo's conventions; end the commit message with `[skip ci]`, so the PR doesn't
   run its own copy of the workflow, unless Step 2 found required status checks from other workflows: then leave it
   out (the checks would never report), and the PR runs its own copy, so the local review in item 3 comes before
   anything is pushed, and only the user pushes.
2. The PR description says whether it adds, upgrades or reconfigures the Claude review, names the kit's version and
   ai-toolkit commit, lists the replacement values applied, and notes whether the PR runs its own copy
   (without `[skip ci]`) or isn't reviewed by it.
3. Review it locally instead: `code-reviewer` and `security-auditor`, giving them the kit path, the SHAs and the
   expected replacement diff.
4. (user) Merge.

## Step 7: Test

Only after the user confirms the merge and the Step 5 setup (ask them to run `gh secret list` and `gh variable list`,
given in a code block, and check `<NAME>` and `CLAUDE_REVIEW_APP_KEY` and both variables appear, names only). Offer the README's test protocol on a throwaway PR with one planted, reachable bug, and say that it opens a
PR, pushes, and posts `@claude review` comments that each run a billed review. Start only on the user's go.

Report each step against its pass criterion, with run ids and the job summary's cost lines. If a run shows an auth or
rate-limit error, stop and report; never switch auth mode to work around it. Closing the throwaway PR and deleting
its branch is destructive: ask before doing either.
