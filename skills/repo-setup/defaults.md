# Repo Setup Defaults

The values `/repo-setup` uses without asking, and the ones it asks for. Rationale for each is in
`docs/07-new-repo-setup.md`; this file only records what the user has decided. Change a value here, in a PR, when the
decision changes.

## Decided (use as written)

| Setting | Value |
|---|---|
| Visibility | private |
| Merge methods | squash only; merge commit and rebase merge off |
| Squash commit | title from the PR title, message from the PR description |
| `allow_update_branch` | on |
| `delete_branch_on_merge` | on |
| PR title types | `docs`, `feat`, `fix`, `chore`, `test`, `ci`, `refactor`; the repo's `pr-title.yml` binds, this is its starting value |
| PR title length limit | 45; `dependabot[bot]` is exempt from the length check only, not the format |
| Check names | `<Area> Checks` for a job the repo defines (CI jobs; `PR Title Checks` for a self-contained title check); `Secret Scan / gitleaks` and `PR Title / check` for the shared reusable workflows, whose names GitHub builds as `<caller job> / <called job>` |
| Runners | `ubuntu-latest`; where the reference deployment says private repos use the org's own runners, every job uses its labels and none has a hosted fallback, except the review kit's `appcheck` and `publish`, whose runner is the kit's `CLAUDE_REVIEW_KEY_RUNS_ON` variable: a dedicated key pool where own runners are required, never a hosted label |
| Claude review jobs as required checks | never |
| Secret scan | gitleaks: `.pre-commit-config.yaml` plus a `secret-scan.yml` caller of the org's reusable workflow (`tools/gitleaks/`) |
| Pre-commit hooks | `pre-commit-config.yaml` beside this file: `gitleaks`, `check-merge-conflict`, `check-added-large-files`, `check-yaml`, `actionlint` |
| Ruleset `main protection` | deletion and non-fast-forward blocked; linear history; signed commits; pull request required, 0 approvals, squash only; admin role bypasses in pull-request mode; required checks = the repo's CI jobs, `Secret Scan / gitleaks`, the PR title check (`PR Title / check`) |
| Repo-level copies of org secret or variable names | never |
| GitHub secret scanning and push protection | on in public repos, off in private ones (a paid add-on; gitleaks covers it) |
| Dependabot | `dependabot.yml` (`github-actions` plus each package ecosystem, weekly, grouped minor and patch, prefix `ci` or `chore`); alerts and security updates on |

## Ask (never filled in from memory)

Ask the user once per run, in one AskUserQuestion:

- The reference deployment: the source that holds the org's runner labels, org secret and variable names, ruleset
  contents and the app template. It is a GitHub repo (`<owner/repo>`, read through the github MCP) or an absolute
  path to a local markdown file or folder (read with the Read tool). If it cannot be read (a 404, a missing file),
  stop and ask for another; never guess its values.
- The file model: the existing repo whose workflows, PR template and CLAUDE.md sections the new one copies.
- The PR title type list, when the reference deployment and the file model disagree with each other or with the list above.
- Whether the repo is an app (deploy workflow) or not.
- Whether the repo has CI (decides if the ruleset carries a required-checks rule).
- Any repo that is a deliberate exception to a row above, and why.
