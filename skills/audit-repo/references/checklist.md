# Audit Repo Checklist

Every item `/audit-repo` judges. The standard and its reasons are `docs/07-new-repo-setup.md` (steps in brackets);
the decided values are `skills/repo-setup/defaults.md`. A row says what to read, what "present" means, and the fix.
Org-specific values (runner labels, org names, the ruleset's exact check names) come from the reference deployment the
user names, never from this file.

Status per item: **present**, **missing**, **different**, **n/a** (the repo has no reason to carry it), **exception**
(the user named it with a reason), **not verified** (the read failed; say why).

Fix kinds: **PR** = the skill fixes the file on a branch; **cmd** = the skill prints the `gh` command, the owner runs it.

## Live state (read-only)

One block of reads for the user to run (all GETs; names only for secrets and variables). `<default>` is the repo's
default branch.

| Read | Command |
|---|---|
| Repo | `gh api repos/<owner/repo> --jq '{private, archived, default_branch, allow_squash_merge, allow_merge_commit, allow_rebase_merge, delete_branch_on_merge, allow_update_branch, squash_merge_commit_title, squash_merge_commit_message, sec: .security_and_analysis}'` |
| Rulesets | `for id in $(gh api repos/<owner/repo>/rulesets --jq '.[].id'); do gh api repos/<owner/repo>/rulesets/$id --jq '{id, name, enforcement, conditions, bypass_actors, rules}'; done` |
| Effective rules | `gh api repos/<owner/repo>/rules/branches/<default>` |
| Org rulesets | `gh api orgs/<owner>/rulesets`, then `gh api orgs/<owner>/rulesets/<id> --jq '{name, enforcement, conditions, bypass_actors, rules}'` for each id |
| Alerts | `gh api repos/<owner/repo>/vulnerability-alerts` (204 = on, 404 = off) |
| Actions | `gh api repos/<owner/repo>/actions/permissions` |
| Names | `gh secret list -R <owner/repo> \| cut -f1`, `gh variable list -R <owner/repo> \| cut -f1`, and the same with `--org <owner>` |

| ID | Item [doc step] | Present when | Fix |
|---|---|---|---|
| L1 | Visibility [1] | `private` matches the reference deployment (private for an org repo; a public repo is a deliberate choice) | cmd, owner's call |
| L2 | Merge methods [2] | `allow_squash_merge` true; `allow_merge_commit` and `allow_rebase_merge` false | cmd: `gh api -X PATCH repos/<owner/repo> -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false` |
| L3 | Squash commit text [2] | `squash_merge_commit_title` = `PR_TITLE`, `squash_merge_commit_message` = `PR_BODY` | cmd: `... -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY` |
| L4 | Branch hygiene [2] | `delete_branch_on_merge` and `allow_update_branch` true | cmd: `... -F delete_branch_on_merge=true -F allow_update_branch=true` |
| L5 | Ruleset exists [8] | exactly one active ruleset targeting the default branch (name `main protection`); no second ruleset that duplicates or weakens it | cmd: `POST` a new ruleset from the file model's JSON; where one exists, fix it with `PUT` (L6–L10), never a second |
| L6 | Ruleset: history rules [8] | `deletion`, `non_fast_forward`, `required_linear_history`, `required_signatures` all present | cmd (ruleset edit) |
| L7 | Ruleset: pull request [8] | `pull_request` rule with `required_approving_review_count` 0 and `allowed_merge_methods` exactly `["squash"]` | cmd |
| L8 | Ruleset: required checks [8] | `required_status_checks` lists the repo's CI jobs (named `<Area> Checks`), `Secret Scan / gitleaks` and the PR title check (`PR Title / check` for the shared workflow, `PR Title Checks` for a self-contained copy), each matching a check the repo's workflows really produce on the default branch (files F1, F2, F4); `strict_required_status_checks_policy` false; no Claude review job listed | cmd; add a name only after its job has run on the default branch |
| L9 | Ruleset: bypass [8] | one bypass actor, the repo-admin role, mode `pull_request` | cmd |
| L10 | Ruleset enforcement [8] | `enforcement` is `active`, not `evaluate` or `disabled` | cmd |
| L11 | Dependabot alerts [2, 11] | the alerts read returns 204; n/a for a repo with no dependency manifests | cmd: `gh api -X PUT repos/<owner/repo>/vulnerability-alerts` |
| L12 | Dependabot security updates [2, 11] | `security_and_analysis.dependabot_security_updates.status` is `enabled`; n/a as L11 | cmd: `gh api -X PUT repos/<owner/repo>/automated-security-fixes` |
| L13 | Secret scanning and push protection [2] | public repo: both `enabled`. Private repo: off is the standard, on is not a gap | cmd: `gh api -X PATCH repos/<owner/repo> --input <file>` with the `security_and_analysis` fields |
| L14 | No repo-level copy of an org name [1] | no repo secret or variable has the name of an org secret or variable | cmd: `gh secret delete <NAME> -R <owner/repo>` (never a value) |
| L15 | Review kit: variables and secrets [9] | if the repo uses the review: variables `CLAUDE_REVIEW_APP_CLIENT_ID`, `CLAUDE_REVIEW_APP_LOGIN` and secrets `CLAUDE_REVIEW_APP_KEY` and one Claude credential exist, by name; where the reference deployment requires the org's runners, the variable `SELF_HOSTED_REVIEW` is set, on the repo or on the org with private visibility only, to the org's labels, never a hosted label (unset means the kit's hosted fallback, which never starts there: report it as different); a leftover `CLAUDE_REVIEW_KEY_RUNS_ON` the kit no longer reads is information only | cmd, as `tools/claude-review/README.md`, "Prerequisites", item 4 (no value on the line) |
| L16 | Review kit: App working [9] | the files read shows a review by the reviewer App on a recent PR, or the repo is not meant to have one | cmd: App installation in the owner's settings (a UI step, say so) |
| L17 | Actions permissions [3] | information only: report `enabled`, `allowed_actions` and, where the reference deployment says so, that GitHub-hosted runners are allowed for any review job left on them (none while `SELF_HOSTED_REVIEW` is set) | cmd, owner's call |

## Files (agent fixes on a branch)

Read from the default branch. Compare against the file model, then the toolkit's templates.

| ID | Item [doc step] | Present when | Fix |
|---|---|---|---|
| F1 | CI workflow [3] | one job per package, each named `<Area> Checks`; `permissions: {}` at the top with per-job grants; actions pinned by full SHA with a tag comment; `timeout-minutes` and `persist-credentials: false` on every job and checkout; a `concurrency` group; triggers `pull_request` to the default branch; a dead-code step where the stack has a checker; an end-to-end job that typechecks its specs, builds first and has no undecided retry (n/a otherwise). n/a: no CI declared in Step 1 | PR: copy the shape from the file model |
| F2 | Secret scan caller [4] | `secret-scan.yml` on `pull_request` only, caller job `Secret Scan`, called workflow pinned by commit SHA with a comment, `runs-on` passed per the runner rule | PR |
| F3 | Pre-commit config [4] | `.pre-commit-config.yaml` has the hooks and revs of `skills/repo-setup/pre-commit-config.yaml` (gitleaks `rev` equal to the secret-scan workflow's `GITLEAKS_VERSION`); extra hooks are not a gap if each has a reason | PR: copy the toolkit file |
| F4 | PR title check [5] | `pr-title.yml`: a caller job `PR Title` of the shared reusable workflow (check `PR Title / check`), or a self-contained copy with job `PR Title Checks`, plain bash, the title read from `env`, never interpolated; types `docs feat fix chore test ci refactor`; length limit 45; `dependabot[bot]` exempt from the length and not from the format; `runs-on` per the runner rule | PR |
| F5 | PR template [6] | `.github/pull_request_template.md` has Summary, Why, How to verify and Checklist; the checklist's title rule and type list match F4; a repo with a UI has a checklist line that a UI change attaches the old/new pair | PR |
| F6 | CLAUDE.md conventions [7] | a Git or Conventions section with the title types (same list as F4) and limit, squash-only merges, who merges, `main` merged into a stale branch, build, test and lint commands; a Review section or `REVIEW.md` when the repo uses the review | PR: add the missing parts, change no other line |
| F7 | Runner rule in every workflow [3] | when the reference deployment says private repos use the org's own runners: every `runs-on` in every workflow, reusable-workflow inputs included, uses the repo's labels; none is hosted (`ubuntu-*`, `macos-*`, `windows-*`) or falls back to one; a reusable workflow in the repo takes `runs-on` with no hosted default, and every caller passes it. Exception: the review kit's four jobs take their runners from the variable in L15, so its caller needs no `runs-on`. Public repos: hosted | PR |
| F8 | Check names [3, 5] | every job a repo defines is `<Area> Checks`; the exceptions are the shared reusable workflows, whose check is `<caller job> / <called job>` (`Secret Scan / gitleaks`, `PR Title / check`). A job named another way is "different", and renaming it is a PR plus a ruleset change (L8), in that order | PR + cmd |
| F9 | Dependabot config [11] | `.github/dependabot.yml` has `github-actions` plus one entry per package ecosystem found in the repo; weekly; commit-message prefix `ci` (actions) or `chore` (packages) so F4 passes; minor and patch grouped; a small `open-pull-requests-limit`. n/a: no manifests and no workflows | PR |
| F10 | Review kit caller [9] | when the repo uses the review: `.github/workflows/claude-review.yml` is the caller of `tools/claude-review/README.md`, "The reusable kit": `permissions: {}` at the top and its job ceiling, `uses:` ending in `@main` (a SHA pin is "different"), secrets mapped by name (the App key and one Claude credential, never `inherit`). The review's jobs are not in L8 | PR: run `/add-claude-review`, never write by hand |
| F11 | Deploy workflow [10] | an app only: `deploy.yml` and `.github/scripts/` as the app template, merge-is-deploy said in CLAUDE.md | PR; needs the user's live go (deploy files) |
| F12 | Secret hygiene [4] | no `.env` or key file tracked (`.gitignore` covers them); `.gitleaks.toml` and `.gitleaksignore`, if present, allowlist only fixtures with a reason | PR |

## Judging

- A difference is either a gap to fix or a reason to change the standard; say which you think it is, and let the user
  decide. Never "fix" a repo to match a rule the reference deployment does not make.
- Items that depend on each other are reported together and fixed in order: F1/F4 (job names) before L8 (required
  checks); F10 (review kit) before L15/L16.
- A `[skip ci]` PR never reports its required checks. A PR that renames a required job waits for the old name, which
  never reports: the owner swaps the old name for the new one in the ruleset, then the PR merges. Say so before
  suggesting either.
