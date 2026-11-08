# Device E2E Under Agent Control

Running UI end-to-end suites on simulators or physical devices from an agent, where the device is an exclusive resource and the real iteration budget is set by the backend, not the test runtime.

## The Problem

Agents have correct instincts for unit and integration tests: run them in parallel, retry the flaky ones, raise the timeout when something is slow. Every one of those instincts is wrong for device E2E, and the failures are quiet rather than loud.

A device or simulator is a **single exclusive resource**. A test that authenticates spends a quota that belongs to the whole team. A runner killed by a sibling process looks exactly like a slow test. None of this is visible in a pass/fail count, so an agent tuning against that signal tunes in the wrong direction: raising timeouts to fix contention, or adding retries that burn the rate limit the suite was already hitting.

## The Pattern

### Serialize the device — one runner, always

Two UI-automation drivers attached to one simulator deadlock; neither completes and both eventually report a timeout. Treat the device as a mutex.

- **Never** fan out flows across agents against a shared simulator or device.
- If parallelism is required, it requires a device per lane. Nothing else works.
- State this in the agent's instructions, not only in the runner script. An agent that sees a suite of N flows and a "run them" instruction will parallelize by default.

### Name exactly one driver in the agent's instructions

Where a runner is reachable two ways (an MCP server and a CLI, say), agent-facing docs that describe one while the operative rule is the other guarantee an agent eventually picks both. On an exclusive device, "both" is the deadlock above.

Do not document the alternative as an option. Name the one supported path and say the other is unsupported.

### Never kill by process name

`pkill -f <toolname>` is machine-wide. It kills the runner belonging to every other session on that host, including another agent's and a human's.

- Track the PID you started and kill that.
- A cleanup step that is correct in isolation and destructive in a shared environment is a recurring hazard for agent tooling, because agents run concurrently far more often than humans do.

### An externally killed run is not a timeout

If the runner classifies any killed process as `TIMEOUT`, a run terminated by a sibling's cleanup reports as slow. Two wrong conclusions follow, and an agent will reach both: *this test is flaky*, and *the timeout needs raising*.

| Ended by | Signal | Correct report |
|---|---|---|
| Deadline expiring | runner's own clock | `TIMEOUT` — the test really is too slow |
| External `SIGKILL`/`SIGTERM` | someone else | `KILLED` — say so; the run proves nothing |
| Non-zero exit | the test | `FAILED` |

Collapsing the second row into the first converts an environment defect into a permanent false belief about the test suite.

### "Headless-runnable" is a property of the chain, not the file

A flow containing no credentials may still depend on a session that a **credentialed** flow established earlier in the sequence. Reading each file for secrets and concluding the credential-free ones are safe to run unattended is a category error.

- Compute runnability over the dependency chain: a flow is headless-runnable only if it, and everything it resumes from, needs no interactive credential.
- Expect far fewer flows than the file-level count suggests, often only the launch smoke test.

### Rate limits are the iteration budget — read them from the source

How often an agent can run an auth-touching suite is capped by the backend's throttles, not by how long the suite takes. Signup, login, SSO and email-confirmation endpoints are typically throttled far more aggressively than anything else.

- **Read the limits from the service's own declarations** (the decorators, middleware or config that enforce them) and cite file and line.
- **Never** take a throttle figure from a README. Observed: a README's stated signup limit and cooldown misread a decorator adjacent to the real one, and the real per-window login limit appeared in no document at all.
- Budget the run before starting it. A suite that needs more account creations per hour than the limit allows fails partway through and reports as a product defect.

### Never allowlist a runner subcommand that takes inline program text

A subcommand accepting test source inline, plus environment injection, is arbitrary code execution wearing a test runner's allowlist entry. Allowlist only the form that takes a path to a file already in the repo, where the content is reviewable and version-controlled.

This is the shell-wrapper rule from [05-permissions-and-safety.md](05-permissions-and-safety.md), repeated because test runners rarely read as dangerous.

## When Not to Use This

Do not use device E2E as an agent's verification step when a cheaper tier answers the question. It is the slowest, most contended and most quota-expensive signal available; an agent that runs it on every iteration spends the team's rate limit to learn what a unit test would have told it. Reserve it for checks that need a rendered UI on a real device.

## Case Study: An iOS Smoke Suite Audited for Unattended Use

A suite of about 25 UI flows on a simulator, with a shell runner and an agent definition describing how to drive it. The audit asked one question: which flows can an unattended agent run?

| Finding | Consequence |
|---|---|
| Runner's cleanup did a machine-wide kill by process name | Concurrent sessions killed each other's servers; each blamed its own test |
| The same runner mapped an external kill to `TIMEOUT` | The contention above presented as a flaky, slow suite |
| Agent definition described the MCP driver; the operative rule was CLI-only | Both drivers on one simulator deadlock |
| Four flows read as credential-free but resumed a session authenticated by an earlier credentialed flow | Only the launch smoke test was runnable unattended |
| Backend login throttle was stricter than any document stated | An agent budgeting from the README would exhaust the limit mid-run |

The audit changed the answer from "most of the suite" to "one flow". None of the five findings was visible in a test report; every one came from reading the runner and the service, not from running the tests.

**The general lesson.** For this tier, the artifacts that decide whether an agent can operate safely are the *runner script*, the *agent instructions* and the *service's rate limits*, not the tests. Audit those three before granting an agent the suite.

Source: retired ai-tooling doc 18.
