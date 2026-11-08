# New Repo Setup

The checklist every new repo in a GitHub org gets on day one, with what each step is and why, so the second repo doesn't re-derive the first.

## What and Why

- **What:** the GitHub-side setup of a repo that agents work in: settings, the `main` ruleset, CI, secret scanning, the PR title and description rules, an automatic PR review if the repo uses one, and the repo's own CLAUDE.md conventions.
- **Why:** each repo set up by hand drifts. Within a week of moving four repos into one org, they disagreed on the PR title types, the title length, whether a PR template exists and which repos have the review. A missed step is invisible until it fails: a `[skip ci]` PR that can never merge, a stale branch with no Update button, a secret in history.
- **Scope:** this document lists the steps and links to the source of each value. It never restates a value that lives elsewhere: the AI side of a repo (CLAUDE.md, rules, skills) is [06-repo-initialization.md](06-repo-initialization.md); the org's values (runner labels, org secrets, ruleset contents) are the reference deployment's (below).
- **Who does what:** an agent writes files and opens the PR. Every repo setting, ruleset, secret, variable and App install is the owner's, run as `gh` commands from their own turn (`rules/security.md`). The `/repo-setup` skill walks these steps (audit only, or audit then fix) and changes no setting itself; the values already decided are in `skills/repo-setup/defaults.md`.

## The Checklist

Do the steps in order: later ones assume earlier ones (the ruleset names the CI job names; the review install depends on the ruleset's required checks).

| # | Step | Kind | Source of the values |
|---|---|---|---|
| 1 | Create the repo in the org, private | owner | reference deployment, "GitHub plan" |
| 2 | Repo settings: squash merge only, update-branch on, head branches auto-deleted | owner | reference deployment; CLAUDE.md "Git Conventions" |
| 3 | CI workflow: one job per package (typecheck, lint, test) | files | the app template in the reference deployment |
| 4 | Secret scanning: gitleaks pre-commit hook and a CI scan (pinned) | files | [tools/gitleaks/](../tools/gitleaks/README.md) |
| 5 | PR title check | files | an existing app repo's `pr-title.yml` |
| 6 | PR description template | files | an existing app repo's `.github/pull_request_template.md` |
| 7 | CLAUDE.md conventions and a Review section | files | [01](01-project-instructions.md), [06](06-repo-initialization.md), this toolkit's CLAUDE.md ("Git Conventions") |
| 8 | Ruleset `main protection` | owner | reference deployment, "GitHub plan" |
| 9 | Automatic PR review, if the repo uses one | files + owner | the review tool's own setup |
| 10 | Deploy workflow (apps only) | files + ops | the app template; deploy request to ops |
| 11 | Audit | read-only | this checklist |

### 1. Create the repo

- Create it in the org, **private**. Why: a private repo has no fork PRs, so no outside workflow runs with the org's secrets; going public later requires approval for outside contributors' workflows first.
- The org's runner groups, org secrets and org variables then reach it with no repo-level setup. Never create repo-level copies of org secret or variable names: a repo-level value overrides the org one.

### 2. Repo settings

- **Squash merge only** (merge commits and rebase merges off), with the squash commit taking the PR title and description. Why: the PR title becomes the one commit on `main`, so the title rule (step 5) is the commit rule.
- **Always suggest updating pull request branches** (`allow_update_branch`). Why: without it the Update branch button shows only when a rule requires up-to-date branches, and agents bring a stale branch current by merging `main` into it, never by rebasing (`rules/workflow.md`, Stale PR Branches). There is no org-level switch: set it on every repo.
- **Automatically delete head branches** (`delete_branch_on_merge`). Why: a merged branch left on the remote reads as open work; the local copy is deleted separately once its tip matches the merged PR head.
- Open (no decision recorded yet): GitHub secret scanning and push protection, Dependabot alerts. Until then, the CI gitleaks job (step 4) is the only scan. The audit reports each repo's current value; decide once, then add the row here.

### 3. CI workflow

- Copy `ci.yml` from the app template. One job per package, each running that package's typecheck, lint and test; the job names become required checks in step 8, so name them before writing the ruleset.
- Conventions every workflow follows: `permissions: {}` at the top and per-job grants; actions pinned by full SHA with a tag comment; `timeout-minutes` on every job; `persist-credentials: false` on checkout; a `concurrency` group; CI on the CI runner labels, never a deploy runner.

### 4. Secret scanning

- A `secret-scan.yml` caller workflow, SHA-pinned to the org's reusable gitleaks workflow (the binary pinned by version and SHA-256), plus a `.pre-commit-config.yaml` at the repo root. The job `Secret Scan / gitleaks` is a required check (step 8). Why: a secret pushed to a branch is in history even after a fix commit; the scan fails the PR before it reaches `main`. The pattern, the workflow and how to bump the pin: [tools/gitleaks/](../tools/gitleaks/README.md).
- The agent-side layer is global, not per repo: `hooks/secret-detector.sh` blocks a secret in an edit or a commit, and `hooks/secret-redact-output.sh` redacts one in tool output (both installed by `/setup-claude`).

### 5. PR title check

- Copy `pr-title.yml`: a plain-bash regex, no third-party action, the title passed through `env`, never interpolated. It enforces `<type>: <description>` with the type list and length limit it defines.
- The length limit is 45, not 50: GitHub appends ` (#N)` to the squash commit title, and the commit title must stay at or under about 50.
- Write the same type list into the repo's CLAUDE.md (step 7) and the PR template's checklist (step 6). Why: three copies that disagree is the drift this checklist exists to stop; the workflow is the one that binds.

### 6. PR description template

- Copy `.github/pull_request_template.md`: **Summary / Why / How to verify / Checklist**. Why: the PR description becomes the squash commit's body, so it is the commit's record; "How to verify" is what the owner runs before merging.
- Adapt the checklist to the repo (title format, CI green, review comments answered, deploy or CI files touched named, the repo's own invariants); keep the four headings.

### 7. CLAUDE.md conventions

- A **Git** or **Conventions** section with: the commit and PR title types (step 5's list) and limits; squash merges only; only the owner merges or pushes `main`; workflow and deploy-script changes need the owner's live go; stale branches get `main` merged in. The CLAUDE.md of the repo that holds this checklist ("Git Conventions") is the worked example.
- A **Review** section listing quotable rules for the automatic review, or a `REVIEW.md` (step 9).
- Build, test and lint commands, per [06-repo-initialization.md](06-repo-initialization.md) Universal Targets.

### 8. Ruleset `main protection`

- One ruleset on `main` per repo, with the rules and bypass the reference deployment lists: PR required (squash only), linear history, signed commits, no force push, no deletion, the CI job names, `Secret Scan / gitleaks` and `Check PR Title` as required checks; Admin bypass in pull-request-only mode. Why: it is the only control between an agent's branch and `main`, and in a merge-is-deploy repo, production.
- A repo with no CI carries the same ruleset without the required-checks rule. The checks don't require an up-to-date branch, so a stale branch is brought current by hand (step 2).
- **Never require a review bot's jobs.** Its verdict is a signal, and a bot's approval must never satisfy a required review ([ADR 0013](adr/0013-app-owned-pr-review.md)).
- A repo with required checks can't merge a `[skip ci]` PR: the required checks never report.

### 9. Automatic PR review

- If the repo uses an automatic PR review (this toolkit ships one, [tools/claude-review/](../tools/claude-review/README.md), which `/add-claude-review` installs: [ADR 0013](adr/0013-app-owned-pr-review.md)), install it after the ruleset, keep its jobs out of the required checks (step 8), and treat its verdict as a signal.
- For a review that posts as a GitHub App, the App's installation must cover the repo, and GitHub-hosted runners must be allowed.
- Optional: a `REVIEW.md` at the repo root, the owner's review brief (failure modes to hunt, a nit cap, paths to skip).

### 10. Deploy workflow (apps only)

- Copy `deploy.yml` and `.github/scripts/` from the app template, set the app name, and send the deploy request to ops. The deploy key is an org secret; never add a repo copy.
- A repo whose `main` deploys on push is merge-is-deploy: say so in its CLAUDE.md, since every merge reaches production.

### 11. Audit

- Re-run the checklist read-only against the repo: files from the default branch (github MCP), settings and rulesets from the owner's `gh api` reads. Each row is present, missing or different; a difference is either a gap to fix or a reason to change this checklist.

## Reference Deployment

The org values this checklist points at live in the org's reference deployment repo, not here. The skill asks the user which repo that is on every run. It holds:
- A deploy-model document with a "GitHub plan": the org, the runner groups and labels, org secrets and variables, the `main protection` ruleset and its required checks, `allow_update_branch`.
- Any decision records on why the repos share one org and the residual risks (an org-wide deploy secret, no merge queue).
- An app template: the CI, PR title and deploy workflows and the deploy script a new app copies.

## Case Study: Four Repos, One Week

Four repos moved into one Team org in a day: two app repos with a deploy, a photo tool and a repo of shared tooling. Within the week:
- The app repos' `pr-title.yml` allowed `docs|feat|fix|chore|test|ci` at 45 characters, while their PR templates and the template README listed the types without `test`, and the tooling repo's CLAUDE.md listed four types at 50 characters with no title check at all.
- One app repo had no review workflow and no `.claude/` at all, while every change to the review reached the other three as three separate PRs.
- The tooling repo merged a `ci:` PR although its own CLAUDE.md listed no `ci` type.
- The update-branch setting was found missing only when an agent needed the button; it went into the deploy model as a per-repo step on the day it was found.
None of these broke a build. Each was found by hand, one at a time. The checklist plus a read-only audit makes the next one a table row instead.
