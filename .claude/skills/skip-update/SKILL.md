---
description: "Skip the release update the session-start reminder announced for this checkout, until a newer release appears. Run from the ai-toolkit repo."
disable-model-invocation: true
---

# Skip Update

The update reminder (`hooks/update-check.sh`) repeats at every session start until the checkout is updated. This skips the newest release it knows of; the reminder returns when a newer release is published. `/disable-update` turns the reminder off altogether.

## Steps

1. Run `bash <this checkout>/hooks/update-check.sh --skip` (resolve the path from this skill's location: `../../../hooks/update-check.sh`).
2. Print its one line of output as the whole reply. Add nothing.
