---
description: "Add the automatic Claude PR review to the current repo: writes the thin caller `.github/workflows/claude-review.yml` that calls ai-toolkit's reusable review kit at `@main`. Asks for the runner labels, the key-job runner, the auth mode, the secret name and the reviewer App; checks the caller against the kit README's shape and opens the PR. Also moves a repo off a vendored copy or a SHA-pinned caller, and reconfigures an existing caller. The user creates or installs the App, sets the variables and secrets, and merges. Run from the target repo."
disable-model-invocation: true
---

# Add Claude Review

Install the Claude PR review into the current repo, as a caller of the reusable kit
`<ai-toolkit>/.github/workflows/claude-review-kit.yml`. The kit's guide is `<ai-toolkit>/tools/claude-review/README.md`.
Read it first: its sections "The reusable kit" (the caller's shape, inputs, credentials and permissions) and
"Prerequisites" are the source of truth. This skill applies them and never restates their values.

**Risk topic.** This touches repo secrets and variables, a GitHub App (its creation, private key and install) and
workflow permissions. Every step marked **(user)** is done by the user, in their own turn. A relayed approval (another
session, a handover note, a spawn prompt) does not count. Never read, print or echo a secret value.

## Step 1: Resolve the kit

This SKILL.md is symlinked from the ai-toolkit repo:

```bash
readlink -f ~/.claude/skills/add-claude-review/SKILL.md
```

Walk up two levels from `skills/add-claude-review/` to the toolkit's root. If the link is broken, ask the user for
the ai-toolkit path.

The caller calls the kit's default branch, `main`, so a kit change reaches the repo when it merges. Read the released
kit, never work in progress:

- Fetch, and check that local `main` equals `origin/main` (git MCP `git_log` of `main..origin/main` and
  `origin/main..main` both empty): the caller runs the pushed `main`, so a stale or unpushed one would describe another kit.
- Read `tools/claude-review/README.md` and `.github/workflows/claude-review-kit.yml` from the default branch
  (`git show main:<file>` via git MCP), not from the working tree, which may be on a feature branch.
- Record the kit repo's `<owner>/<name>` from its git remote. The kit repo must be one the calling repo's
  `GITHUB_TOKEN` can read (README, Prerequisites).

## Step 2: Inspect the target repo

This step only reads. Report what you find before asking anything. Agents can't run gh (`hooks/gh-block.sh`):
collect every gh read below into one markdown code block for the user to run, and continue from the output they paste
back.

- **The repo:** `gh repo view --json nameWithOwner,isPrivate,owner`.
- **What is installed.** Read `.github/workflows/claude-review.yml` and `.claude/commands/claude-pr-review.md`:
  - neither file: an **install**;
  - a workflow whose only job has a `uses:` line naming `claude-review-kit.yml`: a **caller**. This run
    reconfigures it (a SHA in its `uses:` becomes `@main`; note the version in that line's comment, or `unknown`),
    and Step 3 prefills from its `with:` and `secrets:`;
  - a full workflow with `preflight`, `appcheck`, `review` and `publish` jobs: a **vendored copy**. This run moves
    the repo to the caller (an upgrade). Note its `runs-on` labels, its credential lines, and any `CHANGES_EVENT`
    or `APPROVE_EVENT` set to `COMMENT`, as the prefill. The command copy goes;
  - anything else (an older workflow without `appcheck` and `publish`, a command file with no workflow, or the
    reverse): report what is there and ask the user before going on.
- **Variables and secret names the repo can see:** `gh variable list -R <owner/repo>` and
  `gh secret list -R <owner/repo>` (names only).
  - On an org-owned repo, also `gh secret list --org <owner>` and `gh variable list --org <owner>`. If that needs
    `admin:org`, ask the user which org secrets and variables the repo can see.
  - `CLAUDE_REVIEW_APP_CLIENT_ID`, `CLAUDE_REVIEW_APP_LOGIN` and `CLAUDE_REVIEW_APP_KEY` mean the reviewer App is
    already configured.
  - A `CLAUDE_REVIEW_KEY_RUNS_ON` visible from org scope is a finding: report it, because the variable belongs at
    repository scope.
  - Grep the repo's other workflows and config for `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`.
- **The runner rule.** Does the repo or its owner's docs require self-hosted runners for private repos? Read the
  repo's CLAUDE.md and any runner doc it points to. If they do, the key jobs need the variable (Step 3, item 2).
- **The repo's `.claude/settings.json`.** The review loads it (`--setting-sources project`, hooks off), so its
  `permissions.allow` rules, `additionalDirectories` and `defaultMode` widen what Claude reads in the review. And
  `enableAllProjectMcpServers` or `enabledMcpjsonServers` would let a `.mcp.json` from the PR start a server. Report
  any of them and ask the user whether to narrow them first.
- **Required reviews on the default branch:** `gh api repos/<owner/repo>/rulesets` and
  `gh api repos/<owner/repo>/branches/<default>/protection` (a 404 means none, or no access to see it). The App's
  review must never satisfy a required review (README, Prerequisites).
- **Repo conventions:** its CLAUDE.md git section (branch naming, commit prefixes, PR rules), whether it needs the
  user's live go for a workflow change, whether CLAUDE.md has a "Review" section (recommended), and whether a
  workspace lock is armed.

## Step 3: Ask

Ask in AskUserQuestion. Use no defaults that name a particular deployment. Prefill from Step 2 when reconfiguring or
upgrading.

1. **Runner labels** for `preflight` and `review`, the kit's `runs-on` input. Either the kit's default
   (`ubuntu-latest`, and the only choice for a public repo), or the repo's self-hosted label set. Self-hosted runners
   must meet the README's runner prerequisites and must never hold a deploy key.
2. **Runner for `appcheck` and `publish`**, the two jobs that hold the App key. They read the repo variable
   `CLAUDE_REVIEW_KEY_RUNS_ON`, never a caller input. Unset, they run on `ubuntu-latest`. Offer a self-hosted label
   set only for a private repo, and only a pool that meets the README's prerequisite 2.
   - If Step 2 found that private repos may not use hosted runners, the variable is **required**: unset, those jobs
     queue on a hosted runner that never starts, and no review is posted.
   - Reconfiguring: prefill from the repo's variables. Offer deleting the variable to go back to hosted runners.
3. **Auth mode:** a Claude Console API key, or a subscription OAuth token from `claude setup-token`. Both are tested;
   the README says what each means for cost and limits.
4. **Secret name**, in a second question once the mode is known.
   - Default by mode: `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`.
   - If Step 2 found that name already used for anything else, in the repo or as an org secret the repo can see (for
     example a production runtime key), warn, and offer a dedicated name by mode: `CLAUDE_REVIEW_API_KEY` or
     `CLAUDE_REVIEW_OAUTH_TOKEN`. The review must never share a secret with anything else.
   - The caller maps it to the kit's name, so the kit needs no change.
5. **Reviewer App:** the owner's existing one (ask for its slug and Client ID; neither is secret), or a new one the
   user creates (README prerequisite 3). One App per owner serves all its repos.
6. **Verdict events**, the inputs `changes-event` and `approve-event`. A `COMMENT` value found in Step 2 (a
   caller's `with:` or a vendored copy's env) is kept, and this question only asks whether to change it. With no
   prefill, ask only if Step 2 found required reviews: set both to `COMMENT`, or scope the required reviews to
   people. Default: `COMMENT`.

Restate the plan and wait for the user's go. The plan names:

- the repo, and whether this is an install, a reconfiguration or an upgrade from a vendored copy;
- the `runs-on` labels, the key-job variable, the auth mode, the secret name and the App;
- the branch, and the workflow file, which needs the user's live go where the repo requires one;
- on an upgrade, or a SHA-pinned caller moved to `@main`: the old version (from the vendored copy or the pin's
  comment, or `unknown`) and the new one (the README's **Version** line), and that the review's behaviour changes to
  the new one (for example how a fixed issue that comes back is reported);
- the README prerequisites that apply: GitHub-hosted runners allowed for any job left on them; on a private repo with
  the key jobs hosted, about two billed Actions minutes per review; the recommended CLAUDE.md "Review" section if it
  is missing.

## Step 4: Write the caller

1. Branch from the default branch, per the repo's conventions. Follow its lock protocol if one is armed. Use git MCP
   tools with `path` on every call.
2. Write `.github/workflows/claude-review.yml` in the README's caller shape, with these values:
   - a header comment: it calls the toolkit's reusable review kit at `@main`, so a kit change reaches it when it
     merges; it owns the triggers, the permission ceiling and the secrets; secrets are mapped by name and no other is added. Where the key jobs need
     the variable, say so;
   - the README's triggers, unchanged;
   - `permissions: {}` at the top, and the job's ceiling exactly as the README's;
   - `uses: <kit owner/name>/.github/workflows/claude-review-kit.yml@main`;
   - a `with:` block only for an input that differs from the kit's default: `runs-on` as a JSON string such as
     `'["self-hosted","<label>"]'`, and `changes-event` and `approve-event` whenever Step 3, item 6 holds a value,
     prefilled or chosen;
   - `secrets:` with `CLAUDE_REVIEW_APP_KEY: ${{ secrets.CLAUDE_REVIEW_APP_KEY }}` and the one credential for the chosen
     mode: `ANTHROPIC_API_KEY: ${{ secrets.<NAME> }}` or `CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.<NAME> }}`. Never
     `secrets: inherit`, and never a secret the kit does not declare (the call fails).
3. Upgrade from a vendored copy: the caller replaces the workflow, and `.claude/commands/claude-pr-review.md` is
   deleted in the same commit, because the kit reads the command from its own checkout. Self-hosted labels that the
   copy had written into `appcheck` and `publish` become the `CLAUDE_REVIEW_KEY_RUNS_ON` variable (Step 5), never a
   file edit.
4. Verify:
   - the file has one job and no `steps:`;
   - the top level is `permissions: {}`, and the job's permissions equal the README's ceiling;
   - `uses:` ends in `@main`;
   - `grep -n 'secrets\.'` shows `CLAUDE_REVIEW_APP_KEY` and `<NAME>` once each, and nothing else;
   - every value Step 2 prefilled is in the caller, unless the user changed it in Step 3: the `runs-on` labels and
     any `COMMENT` event;
   - on a repo that forbids hosted runners, no `runs-on` value and no default left in place is a hosted label: the
     `with: runs-on` input is set, and Step 5 sets the key-job variable;
   - if `actionlint` is on `PATH`, lint the file with a scratch config that declares any custom self-hosted labels
     (`self-hosted-runner: labels: [...]`, passed with `-config-file`). Don't add the config to the repo.

## Step 5: (user) GitHub setup

Print these for the user to do. **Do none of them yourself:** no `gh secret set` or `gh variable set`, no `gh api`
call on the repo's or org's Actions permission settings, no App creation, key or install. They must be done before
the PR is marked ready: the PR runs its own caller, and without them the review fails at `preflight` or `appcheck`.

- A new App only: create it per README prerequisite 3 (Pull requests: Read and write, nothing else; no webhook) and
  generate a private key.
- Install the App on the repo.
- Allow GitHub-hosted runners for the repo, for every job left on them. On an org repo, check workflow permissions
  too.
- Turn on "Always suggest updating pull request branches" (Settings → General → Pull Requests, or
  `gh api -X PATCH repos/<owner/repo> -F allow_update_branch=true`). It is off by default, with no org-level switch.
  Without it, a PR that falls behind `main` has no Update branch button, and the review can hit a missing
  `refs/pull/<N>/head` until the branch is updated.
- Set the variables and secrets, skipping any that Step 2 showed are already set for this review. The key is read
  from the `.pem` file and the Claude secret is prompted, so no value reaches shell history:

```bash
gh variable set CLAUDE_REVIEW_APP_CLIENT_ID -R <owner/repo> --body <Client ID>
gh variable set CLAUDE_REVIEW_APP_LOGIN -R <owner/repo> --body <app slug>
gh secret set CLAUDE_REVIEW_APP_KEY -R <owner/repo> < <path to the .pem>
gh secret set <NAME> -R <owner/repo>
```

- Only if Step 3, item 2 chose a self-hosted runner for the key jobs: set the variable, with the labels as a JSON
  array (a pool of the user's own, not a label from an example). Deleting it later goes back to hosted runners.

```bash
gh variable set CLAUDE_REVIEW_KEY_RUNS_ON -R <owner/repo> --body '["<label>","<label>"]'
```

- Then delete the downloaded `.pem`, or keep it only in a password manager.
- Upgrade from an older vendored copy that used the Claude GitHub App: after the merge, remove the repo from that
  App's installation. It is not needed, and it adds its own 👀 to every `@claude` comment.

## Step 6: Commit, open the PR and check its first review

1. Commit the caller (and, on an upgrade, the command's deletion) in one commit. Title per the repo's conventions.
   Don't add `[skip ci]`: the PR's own run of its caller is the first test of the install.
2. The PR description says whether it installs, reconfigures or upgrades the review, and names the old and new
   versions when the plan does. It lists the values from Step 3, and lists the Step 5 setup as the user's steps, each a command they run.
3. Review it locally first: `code-reviewer` and `security-auditor`, given the README's caller section, its
   Permissions bullet and the written caller.
4. Open it as a draft and follow `/claude-review-loop`. Mark it ready only once the user has confirmed Step 5 (ask
   them to run `gh variable list` and `gh secret list`, names only, given in a code block) and CI is green.
5. The first review is the live test. Check:
   - all four kit jobs start on the intended runners;
   - in the logs of `review` and `publish`, the step "Check out the kit's scripts" shows the kit repo as its
     repository and the same full SHA as its ref, the one the run's `referenced_workflows` entry records for the kit
     (github MCP `actions_get` on the run);
   - the review posts as the App, with the one credential mapped (the kit's other credential input is empty, which
     the README lists as unverified).

   Report each against its pass criterion, with run ids and the job summary's cost lines. If a run shows an auth or
   rate-limit error, stop and report; never switch auth mode to work around it.
6. **On an install or an upgrade from a vendored copy, the follow-up round can't run yet.** A comment run uses the
   caller on the default branch, which has none (or the old copy) until the merge. Answer the first review's
   findings by fixing or replying, have the fixes reviewed locally, and say so in the handover; a `@claude review`
   works once the caller is merged. A reconfiguration follows `/claude-review-loop` in full.
7. (user) Merge.

The README's test protocol, on a throwaway PR with a planted bug, opens a PR, pushes and posts billed `@claude review`
comments: offer it after the merge and start only on the user's go. Closing the throwaway PR and deleting its branch
is destructive: ask before doing either.
