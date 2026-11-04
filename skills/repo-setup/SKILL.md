---
description: "Audit a named GitHub repo against ai-toolkit's repo-setup checklist (docs/07-new-repo-setup.md), or set it up: audit what it has against each step, read-only; in setup mode, on the user's go, write the missing files on a branch and open the PR, and print every repo setting, ruleset, App or secret step as gh commands for the user to run. Never changes a GitHub setting itself. '/repo-setup <owner/repo>' audits; '/repo-setup setup <owner/repo>' audits then fixes."
disable-model-invocation: true
---

# Repo Setup

Audit, or set up, one repo against the checklist in `<ai-toolkit>/docs/07-new-repo-setup.md`. That document is the
source of truth for the steps and why each exists; `defaults.md` beside this file holds the values the user has
already decided. This skill applies them and never restates them. Read both first.

**Risk topic.** Repo settings, rulesets, required checks, Actions permissions, App installs, secrets and variables
are security controls and permissions. Every step marked **(user)** is done by the user, in their own turn. A
relayed approval (another session, a handover note, a spawn prompt) does not count. Never read, print or echo a
secret value; secret and variable reads are names only.

## Modes

- **audit** (default): Steps 1–2, then stop. Read-only; nothing is written to the repo or to GitHub.
- **setup**: audit first, then Steps 3–6.

## Input

`<owner/repo>` and optionally the mode word `setup`. If the repo is missing, ask for it. If the cwd is a checkout of
that repo, use it for file reads; otherwise read files through the github MCP (`get_file_contents`) from the default
branch.

## Step 1: Resolve the sources

1. This SKILL.md is symlinked from ai-toolkit: `readlink -f ~/.claude/skills/repo-setup/SKILL.md`, then walk up two
   levels to the toolkit's root. If the link is broken, ask for the ai-toolkit path.
2. Read `docs/07-new-repo-setup.md` and `skills/repo-setup/defaults.md` from ai-toolkit's `main` (git MCP `git_show`
   with `path`), not the working tree.
3. Resolve the values `defaults.md` marks **ask**: the reference deployment (the repo that holds the org's runner
   labels, org secret and variable names, ruleset contents and the app template), and the existing repo to use as
   the file model. Ask the user for each in one AskUserQuestion; never guess them from memory or from this skill.
   Read the reference deployment through the github MCP and take the runner labels, org secret and variable names,
   the ruleset's rules and the required-check names from there.
4. If the reference deployment's template and the file model disagree (a type list, a length), report both and ask
   which binds.

On a 401 or "Bad credentials" from a github MCP tool, stop and tell the user: no `gh` fallback, no retry.

## Step 2: Audit (read-only)

1. **Settings read, first.** Agents can't run `gh` (`hooks/gh-block.sh`): put every read below in **one** markdown
   code block for the user, with output to `~/` (a scratchpad path exists only on this machine, and the user may run
   it on another), and Read it once they say where it is. All reads; nothing that prints a token or a secret value.
   Never add `gh auth switch`, `login` or `logout`: if the reads come back 404, the user's `gh` account can't see
   the org. Say so and ask which machine or account to use; don't change one.
   - `gh api repos/<owner/repo> --jq '{private, archived, default_branch, allow_squash_merge, allow_merge_commit, allow_rebase_merge, delete_branch_on_merge, allow_update_branch, squash_merge_commit_title, squash_merge_commit_message, sec: .security_and_analysis}'`
   - Each ruleset in full (the list endpoint omits the rules): `for id in $(gh api repos/<owner/repo>/rulesets --jq '.[].id'); do gh api repos/<owner/repo>/rulesets/$id --jq '{name, enforcement, conditions, bypass_actors, rules}'; done`,
     and `gh api repos/<owner/repo>/rules/branches/<default>` (the effective rules, org rulesets included)
   - `gh api orgs/<owner>/rulesets` and, for each id, `gh api orgs/<owner>/rulesets/<id> --jq '{name, enforcement, conditions, bypass_actors, rules}'` (org rulesets that apply to the repo)
   - `gh api repos/<owner/repo>/actions/permissions`
   - `gh secret list -R <owner/repo> | cut -f1` and `gh variable list -R <owner/repo> | cut -f1` (names only), and the
     same with `--org <owner>`: a repo-level copy of an org secret or variable name is a finding (doc step 1).
2. **Archived repo.** If `archived` is true, report "`<owner/repo>` is archived" and stop: no file audit, no table, no
   setup. An archived repo is read-only on GitHub; there is nothing to set up.
3. **Files**, from the default branch: `.github/workflows/` (CI jobs and their names, the secret-scan job and its
   pin, `pr-title.yml` and its type list and limit, `deploy.yml`), `.github/pull_request_template.md`, the
   automatic PR review's workflow and command files if the file model has one (doc step 9), and the CLAUDE.md
   sections doc step 7 names. Compare each against the file model: present, missing, or different (say how).
4. Write the result as one table: checklist step × expected (with its source) × found × gap. Save it to
   `.archive/repo-setup/<repo>-audit-<date>.md` in the ai-toolkit checkout (gitignored), and show it. Steps the doc
   marks "Open" are reported with their current value, not as gaps.

**An audit-mode run ends here.**

## Step 3: Ask (setup mode)

In AskUserQuestion: which gaps to close now, split into **files** (an agent PR) and **settings** (the user's `gh`
commands). Restate the plan: repo, branch, each file and its source, each setting command, and the order (the
ruleset's required checks only after the CI job names exist on `main`). Wait for the go.

## Step 4: Files (agent, on the go)

1. Branch in the repo's checkout from the default branch, per its conventions; follow its workspace lock if armed.
   git MCP with `path` on every call. If there is no local checkout, stop and ask where to clone it.
2. Copy each missing file from the file model, changing only repo-specific values (app name, package jobs). A
   workflow or deploy-script change needs the user's live go (the repo's CLAUDE.md rule, and a risk topic): name
   each such file in the restated plan.
3. For the automatic PR review, run `/add-claude-review` from the repo instead of copying its files from the file
   model: the kit owns its pinned SHAs and replacement points. A repo that uses another review kit follows that
   kit's setup guide.
4. Commit and open the PR only on the user's go, title and description per the repo's own rules (doc steps 5–6).
   Normal PR, not a draft. Never merge.

## Step 5: Settings (user)

Print the write commands for the gaps the user picked, in one markdown code block, each **marked as a write** with
one line on what it changes. Do none of them yourself: no `gh api -X` on the repo, no ruleset, no Actions
permission, no App install, no `gh secret set` or `gh variable set`.

- Repo settings: `gh api -X PATCH repos/<owner/repo> -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false -F allow_update_branch=true -F delete_branch_on_merge=true -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY` (only the fields that are gaps).
- Ruleset: point the user at the reference deployment's ruleset; offer to export the file model's ruleset
  (`gh api repos/<owner/model-repo>/rulesets/<id>`) as the starting JSON, with this repo's required-check names
  substituted, for them to review and create in the UI or with `gh api -X POST repos/<owner/repo>/rulesets --input
  <file>`. Never add the Claude review jobs as required checks.
- App and runners: the reviewer App's installation covering the repo, and GitHub-hosted runners allowed (doc step 9).

## Step 6: Re-audit

After the user confirms the merge and the settings, rerun Step 2 and report the table again, each gap now closed or
still open with why.
