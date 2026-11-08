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
| PR title length limit | 45 |
| Claude review jobs as required checks | never |
| Secret scan | gitleaks: `.pre-commit-config.yaml` plus a `secret-scan.yml` caller of the org's reusable workflow (`tools/gitleaks/`) |
| Repo-level copies of org secret or variable names | never |
| GitHub secret scanning and push protection | open (no decision yet); report the current value, not a gap |
| Dependabot alerts | open; report the current value, not a gap |

## Ask (never filled in from memory)

Ask the user once per run, in one AskUserQuestion:

- The reference deployment: the repo that holds the org's runner labels, org secret and variable names, ruleset
  contents and the app template.
- The file model: the existing repo whose workflows, PR template and CLAUDE.md sections the new one copies.
- The PR title type list, when the reference deployment and the file model disagree.
- Whether the repo is an app (deploy workflow) or not.
- Whether the repo has CI (decides if the ruleset carries a required-checks rule).
- Any repo that is a deliberate exception to a row above, and why.
