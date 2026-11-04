# Reviewer cases

Regression cases for the PR reviewer (`claude-pr-review.md`, `REVIEW.md`). Each case is a change the reviewer saw and
let through: a bug that shipped, was found later and fixed forward. A change to the reviewer's command, `REVIEW.md` or
model is scored against these, the way Anthropic turns incidents into evals ("Solving code review at Anthropic").
There is no runner yet; this file is the format.

The set starts empty here. The kit's first cases came from the repo it was built in, whose commits this repo doesn't
have, so they stayed behind: a case is only useful where its `baseSha` and `headSha` can be checked out.

## One case

A directory `cases/<id>/` holding one `case.json`. `<id>` is `<date the reviewed PR merged>-<short-slug>`.
A case is a fixed change plus the finding the reviewer should have raised, **checked by a person**: a case with no
`checkedBy` is a candidate and is not scored.

| Field | Meaning |
|---|---|
| `kind` | `miss` (reviewed, bug shipped). `hit` (reviewer caught it; keep so a change cannot lose it) and `clean` (known-good change, no finding expected) are reserved for later. |
| `reviewedPr`, `baseSha`, `headSha` | The PR. `headSha` is its squash commit on `main` and `baseSha` its parent, so the reviewed diff is exactly `baseSha..headSha`. Both are on `main`, which only moves forward (no force push), so the case needs no stored diff. |
| `appReview` | The head the reviewer App reviewed and what it said. The case counts only if a review existed at (or before) the code that held the bug. |
| `fix` | The fix-forward PR and squash commit. For the person checking the case only: never show it to the reviewer. |
| `anchors` | Where the finding belongs: file and line range in the file as it is at `headSha`. A finding in any one of them counts. |
| `expected` | `severity`, `category`, and `summary`: the finding as a reviewer should write it, naming the trigger and the remedy. |
| `hitCriterion` | What counts as a hit, and what is only a partial hit. |
| `checkedBy`, `checkedOn` | Who confirmed the bug, its location and its summary. |
| `notes` | Anything a reader needs: how line numbers were counted, what else the fix commit holds. |

## Adding one

1. A fix-forward lands for a PR the reviewer App reviewed. Check that the App's review exists at the head that held
   the bug and that it did not raise the finding.
2. Take `baseSha` and `headSha` from the squash commit and its parent. Count the anchor lines on the file as it is at `headSha`.
3. Write `expected` and `hitCriterion` from the fix, then have the owner read them and set `checkedBy`.
4. One commit per case. `python3 -I -B -m unittest discover -s tools/claude-review/tests` checks the shape (and skips
   while there is none).

## Scoring (when a runner exists)

Run the review command offline (a local `claude -p`, subscription, never inside a busy window) on a clone checked out at
`headSha` with the diff `baseSha..headSha` as the PR. A hit is a finding in one of the anchors (a few lines of slack)
that says what `hitCriterion` asks. Store results by case, command and `REVIEW.md` hash, and model; re-run a case only
when one of those changes. Start with a small smoke subset.
