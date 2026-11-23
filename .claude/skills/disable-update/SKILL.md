---
description: "Turn the session-start update reminder off for this checkout, or back on. Run from the ai-toolkit repo."
disable-model-invocation: true
---

# Disable Update

Turns the release reminder (`hooks/update-check.sh`) off for this checkout: the hook then stays silent and makes no network call. Running it again turns the reminder back on. `/skip-update` skips one release and keeps the reminder.

## Steps

1. Run `bash <this checkout>/hooks/update-check.sh --toggle` (resolve the path from this skill's location: `../../../hooks/update-check.sh`).
2. Print its one line of output as the whole reply. Add nothing.
