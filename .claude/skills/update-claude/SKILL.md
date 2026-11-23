---
description: "Update this machine to the newest ai-toolkit: fast-forward the checkout, show what changed, then run /setup-claude. Run from the ai-toolkit repo, usually when the session-start reminder announced a release."
---

# Update Claude

The install is the live checkout (ADR 0014), so an update is a fast-forward pull plus `/setup-claude`. This skill does both and shows what changed in between. It changes nothing when a check fails.

Git calls go through the git MCP tools with `path` set to this checkout (the folder three levels above this skill). The pull is `git_pull` with `fastForwardOnly: true` and no branch or remote, the one form `hooks/protected-paths-guard.sh` lets through.

## Steps

1. **Note the old version.** `git_tag` list: the highest plain version tag (`vX.Y.Z`), or none. Then `git_log` with `maxCount: 1`: the old `HEAD` sha.
2. **Check.** `git_status`: the branch must be `main`, with no changes and no untracked files. `git_fetch` with `tags: true`, then `git_log` of `origin/main..HEAD` (the `branch` parameter takes the range): it must be empty, since a local commit means a fast-forward is impossible. `git_log` of `HEAD..origin/main` is what the pull brings: if it is empty too, say "ai-toolkit is already up to date." and stop. Any other failure ends the skill with the refusal below.
3. **Pull:** `git_pull` as above. If it fails, the refusal below.
4. **Show what changed.** The new version: `git_tag` list again, the highest plain version tag. Then `git_log` with `branch: "<old sha>..HEAD"`, `oneline: true`, `maxCount: 20`: the titles, newest first.
5. **Run `/setup-claude`** with the Skill tool and let it finish, including its questions to the user.
6. **Close.** Your last message is only the closing below, nothing after it.

## The closing

The last message is two or three lines and no more. Nothing follows it, not a summary and not an offer.

If `/setup-claude` staged a settings file for the user to put live:

```
Updated ai-toolkit <old> -> <new>.
Last step: run the copy command shown above to put your settings live.
```

Otherwise:

```
Updated ai-toolkit <old> -> <new>. Setup done.
```

With no old tag, `<old>` is the old sha's first 7 characters. A refusal (step 2 or 3) is one line saying what blocked it and one line saying what to do, for example `Not updated: the checkout has uncommitted changes.` and `Commit or stash them, then run /update-claude again.` It never ends on a success line.
