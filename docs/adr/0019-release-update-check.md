# 19. Releases and a Weekly Update Check

**Status:** accepted
**Date:** 2026-11-23

## Context

The install is the live checkout on `main`, moved with `git pull --ff-only` ([ADR 0014](0014-live-checkout-installs.md)).
Nothing tells a machine that there is something to pull, and nothing marks a version worth moving to: every merge is
a possible install.

## Options Considered

- **Packaged releases (tarball, installer).** The hooks, the github MCP guard and the launcher all check that the
  checkout is on `main` and matches `origin/main`, so an unpacked tree or a checkout pinned to a tag would fail the
  check. Rejected.
- **A hook that compares `main` with the local checkout on every start.** Network on every session, and no way to say
  which commit is worth installing. Rejected.
- **GitHub Releases as the marker, a weekly check in a SessionStart hook: chosen.**

## Decision

- **A release is a tag on `main` plus a GitHub Release marked Latest.** The owner cuts it. An update is still the
  fast-forward pull of ADR 0014, which lands on `main`'s tip, at or after the tag. Tags are plain versions
  (`v0.1.0`; `v0.x` until the owner calls the setup stable).
- **`hooks/update-check.sh`** (SessionStart, `startup` only) asks `releases/latest` of the checkout's own GitHub repo
  at most once in 7 days, one unauthenticated request capped at 3 s, and caches the answer under
  `~/.local/state/claude-update-check/`. Every startup reads that cache and, while the checkout's newest reachable tag
  is older than the cached release, prints a one-line `systemMessage`. GitHub's "latest" excludes pre-releases and
  drafts, so what the owner marks Latest is what is recommended. The hook fails open and sends nothing about the user
  or the machine.
- **Skip and off.** `/skip-update` records the newest known release as skipped; the reminder returns for a later one.
  `/disable-update` turns the reminder off per checkout and, run again, on. Both are user-invoked skills that call the
  hook script.
- **`/update-claude`** fast-forwards the checkout (the one pull form `hooks/protected-paths-guard.sh` allows), shows the
  commits between the old and new tag, then runs `/setup-claude`. Its last message is a fixed two-line closing, so the
  one step left for the user is not missed.
- **`/setup-claude` is no longer user-invoked only.** The flag existed because the skill edits settings and
  permissions. The settings file is never written by an agent: `hooks/protected-paths-guard.sh` denies it, and the skill
  stages the merged result for the user to copy into place ([ADR 0017](0017-protected-paths-hook.md)). The rest of the
  skill (links, checks, registration hints) is idempotent. The description now says an agent runs it only when the
  person asks or from `/update-claude`.
- **Other repos reuse the script.** It takes the checkout and the update command's name as arguments and reads the
  repo from `origin`, so a repo built on the toolkit wires its own entry and ships its own `/update-…`, `/skip-update`
  and `/disable-update` skills.

## Consequences

- One request per repo per week, and no network the rest of the time. A failed attempt is retried a day later, so a
  machine offline at its first stale startup hears about the release within a day of being online.
- A checkout that is ahead of its last tag compares by that tag, so a reminder can name a release the checkout
  already has the content of.
- The local version is the highest plain version tag merged into `HEAD`. Other tags (`backup`, `v1.3.0-rc1`) are
  ignored on both sides, wherever they sit in the history.
- The request is unauthenticated, so a private repo answers 404 and never notifies; a repo that reuses the script
  must be public.
- Cutting releases stays a manual, outward-facing step for the owner.
