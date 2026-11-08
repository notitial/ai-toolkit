# gitleaks

A pre-commit hook and a CI scan that stop a secret being committed. Both run [gitleaks](https://github.com/gitleaks/gitleaks), pinned to one version.

It is a different layer from `hooks/secret-detector.sh`: that hook blocks an agent's tool calls that carry a secret or touch `.env` files; gitleaks scans what is committed, whoever wrote it.

## What

- **CI scan (enforced):** one reusable workflow, kept in the organization's `.github` repo, scans the commits a pull request adds. Each repo calls it.
- **Pre-commit hook (early feedback):** the same scanner on staged changes, before the commit exists.
- `git commit --no-verify` skips the hook, so CI is the check that binds. Make it a required check.

## Why

- A secret pushed to a branch stays in history after a fix commit. The scan fails the PR before it reaches `main`.
- One workflow means one place to bump the pin; the callers stay about 12 lines.
- Do not use `gitleaks-action`: it needs a paid licence on organization accounts. The reusable workflow downloads the release binary instead.

## The reusable workflow

Put it in the organization's `.github` repo as `.github/workflows/gitleaks.yml`. A reusable workflow in a public repo can be called from private repos. The runners need `curl`, `sha256sum`, `tar` and `git`; the binary is `linux_x64`, so an arm runner needs the arm64 tarball and its sha256 instead.

```yaml
# Reusable secret scan: gitleaks over the commits a PR adds. The binary is pinned by version and sha256
# (gitleaks-action is not used: it needs a paid licence on organization accounts). Read-only, no secrets.
name: Secret Scan

on:
  workflow_call:
    inputs:
      runs-on:
        description: 'Runner labels as JSON: "ubuntu-latest" or ["<label>","<label>"]'
        type: string
        default: '"ubuntu-latest"'

permissions:
  contents: read

jobs:
  gitleaks:
    name: gitleaks
    runs-on: ${{ fromJSON(inputs.runs-on) }}
    timeout-minutes: 5
    env:
      GITLEAKS_VERSION: 8.30.1
      GITLEAKS_SHA256: 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
    steps:
      - name: Check out the code
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Install gitleaks
        run: |
          curl -fsSL -o "$RUNNER_TEMP/gitleaks.tar.gz" \
            "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
          echo "${GITLEAKS_SHA256}  $RUNNER_TEMP/gitleaks.tar.gz" | sha256sum -c -
          tar -xzf "$RUNNER_TEMP/gitleaks.tar.gz" -C "$RUNNER_TEMP" gitleaks
      - name: Scan the PR's commits
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: '"$RUNNER_TEMP/gitleaks" git --redact --verbose --log-opts="$BASE_SHA..$HEAD_SHA"'
```

- A called workflow sees the caller's event, so the PR's base and head SHAs work as written. Trigger the caller on `pull_request` only: on any other event the SHAs are empty and the scan covers nothing.
- `runs-on` is JSON, because a workflow input is a string and a runner can be one label or a list.

## The caller, per repo

`.github/workflows/secret-scan.yml`:

```yaml
name: Secret Scan
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  scan:
    name: Secret Scan
    uses: <org>/.github/.github/workflows/gitleaks.yml@<commit SHA>  # <tag or date>
    with:
      runs-on: '["<label>","<label>"]'
```

- Pin by commit SHA, not a branch. Omit `with:` to run on `ubuntu-latest` (public repos).
- The required-check name for a reusable workflow is `<caller job> / <called job>`: here **`Secret Scan / gitleaks`**. Add that name to the `main` ruleset ([07-new-repo-setup.md](../../docs/07-new-repo-setup.md), step 8).
- If the organization limits which Actions may run, allow the reusable workflow's path.

## The pre-commit hook

[`.pre-commit-config.yaml`](.pre-commit-config.yaml) is the canonical copy; copy it to the repo root unchanged.

- Hook id `gitleaks`: pre-commit builds the pinned tag from source, so the first commit needs Go.
- Install per clone: `brew install pre-commit`, then `pre-commit install`.
- The `rev` tag and the workflow's `GITLEAKS_VERSION` must be the same version.

## Bump the pin

1. Pick the release and download its `gitleaks_<version>_checksums.txt` from the release page.
2. Take the `linux_x64` tarball's sha256 from that file. Download the tarball too and hash it (`shasum -a 256`); the two must match.
3. Change `GITLEAKS_VERSION` and `GITLEAKS_SHA256` in the reusable workflow; change `rev` in every `.pre-commit-config.yaml`.
4. Merge the workflow change, then raise each caller's commit SHA.

## False positives

- **One finding:** add its fingerprint (printed with `--verbose`) to `.gitleaksignore`, one per line.
- **A rule or a path:** add a `[[allowlists]]` block to `.gitleaks.toml` with `[extend] useDefault = true` so the default rules stay. A path allowlist exempts the whole file from every rule: use it for deliberate test fixtures only.
- Both files at the repo root are read by the hook and by the CI scan.

## Adopting in an existing repo

Run one full-history scan before the first PR; the CI scan only sees new commits.

```
gitleaks git --redact
```

- A real secret found in history: revoke and rotate it first. Rewriting history does not undo the exposure.
- A fixture or an old false positive: allowlist it as above, so the first PR is not blocked.

## Case study

Adopted in this repo. The first full-history scan found 5 hits, all `generic-api-key` on the deliberately fake fixtures in the tests of the three secret tools. They are allowlisted by path in [`.gitleaks.toml`](../../.gitleaks.toml).
