# Cross-Platform Parity

Enforcing consistent behavior across multiple platform implementations.

## The Problem

When the same feature ships on two or more platforms (e.g., native mobile A + B, web + mobile, server + client), implementations drift:

- **Domain model divergence** — one platform adds a field the other omits, or uses different nullability
- **Error handling gaps** — one platform handles a network timeout gracefully while the other crashes
- **Test coverage asymmetry** — one platform has 15 test scenarios, the other has 5
- **Naming inconsistency** — `fetchItems` on one platform, `getEntries` on the other
- **State machine mismatch** — one platform has a "refreshing" state, the other goes straight from "success" to "loading"

These divergences are invisible in per-platform reviews. Each implementation looks correct in isolation. The problems surface when users experience different behavior on different platforms, or when a cross-platform bug fix works on one platform but not the other because the error paths differ.

## The Implementation Brief as Shared Contract

The cheapest way to prevent divergence: define the implementation once, before any platform starts coding.

The **Implementation Brief** (see [05-orchestrator.md](05-orchestrator.md)) serves as a shared contract:
- Same acceptance criteria for both platforms
- Same domain model fields and types
- Same error cases to handle
- Same test scenarios to implement
- Same localization keys to reference

When both platform agents receive the same brief, they start from the same specification. Divergence is still possible in implementation details, but the _what_ is aligned before the _how_ begins.

## Domain Model Alignment

Define canonical domain models in a shared location (e.g., a cross-platform contract document or rule):

```
Resource:
  id: String (unique identifier)
  type: ResourceType (enum)
  name: String
  endpoint: String
  credential: String (secure storage)
  isDefault: Boolean
```

Both platforms implement this model with platform-idiomatic types, but the **fields, types, and nullability** must match:

| Field | Platform A | Platform B | Match? |
|-------|------------|------------|--------|
| id | `String` | `String` | Yes |
| type | `ResourceType` (enum) | `ResourceType` (enum) | Yes |
| name | `String` | `String` | Yes |
| endpoint | `String` | `String` | Yes |
| credential | `String` (secure storage) | `String` (secure storage) | Yes |

**DTO naming convention:** Use `{Entity}Dto` on both platforms. Do not use `ItemResponse` on one platform and `ItemDTO` on the other — the pattern must be consistent so cross-platform reviews can compare apples to apples.

## Error Hierarchy Matching

Define error cases once, implement on both platforms:

```
DomainError:
  .network(.unreachable | .timeout | .sslError | .invalidResponse(statusCode))
  .api(.unauthorized | .forbidden | .notFound | .serverError(code) | .unexpectedResponse)
  .config(.noResourceConfigured(type) | .invalidEndpoint | .missingCredential)
  .local(.unknown)
```

Both platforms must handle the same cases. If Platform A maps HTTP 401 to `.api(.unauthorized)` but Platform B maps it to `.network(.invalidResponse(401))`, the error handling behavior diverges — different retry logic, different user messages, different recovery paths.

**Enforcement:** The cross-platform contract rule checks that error mapping follows the canonical hierarchy. Parity reviews compare error handling paths between platforms.

## State Machine Matching

If your UI uses a state machine (e.g., Loading -> Success -> Error), both platforms must implement the same states with the same transitions:

```
ViewState<T>:
  Loading                       — initial load, no data
  Refreshing(staleData: T)      — reloading, showing previous data
  Success(data: T)              — data loaded
  Error(error: DomainError)     — load failed
```

**Common divergence:** One platform adds a `Refreshing` state while the other goes Loading -> Success -> Loading -> Success on refresh. The user sees a loading spinner on one platform and stale data with a refresh indicator on the other. Same feature, different UX.

**Naming matters:** Use the exact same type name on both platforms. `ViewState<T>` on both, not `ScreenState<T>` on one and `ViewState<T>` on the other. This makes parity reviews trivial — search for the same string.

## Test Naming Parity

Adopt a single naming convention for test scenarios across platforms:

```
featureName_scenario_expectedResult
```

Examples:
- `settings_deleteItem_removesFromList`
- `search_emptyQuery_showsEmptyState`
- `connectionTest_timeout_showsNetworkError`

When both platforms use the same naming convention, a parity audit can directly compare: does Platform A have a test for `connectionTest_timeout_showsNetworkError`? Does Platform B? Are they testing the same behavior?

**This is the simplest parity enforcement and one of the most effective.** Naming convention alignment makes divergence visible without tooling — a human can compare test lists.

## Localization Key Sharing

Both platforms reference the same source keys from a single localization file:

```
Source: core/localization/en.json
  -> Generated: Platform A string resources
  -> Generated: Platform B localized strings
```

Both platforms use the same logical key: `error.network.timeout` generates the same user-facing string on both platforms. Platform-specific formatting is handled by the generator.

**Never define strings in platform code.** If a string exists in one platform's resources but not in the localization source, it is invisible to the other platform and will diverge or be missing.

## The Parity Table

Track parity status in a structured table:

```markdown
| Feature | Scenario | Expected | Platform A Test | Platform B Test | Status |
|---------|----------|----------|-----------------|-----------------|--------|
| Settings | Add item | Saves to storage | addItem_valid_saves | addItem_valid_saves | Aligned |
| Settings | Delete item | Removes + refreshes | delete_confirmed_removes | Missing | Gap |
| Search | Empty query | Empty state shown | emptyQuery_showsEmpty | emptyQuery_showsEmpty | Aligned |
```

The parity table lives in documentation (e.g., `docs/testing-strategy.md`) and is updated by implementation skills, scaffold skills, and parity audit skills.

**Rule:** Never ship a feature with a parity gap unless it is explicitly marked as `PARTIAL` (single-platform delivery with a follow-up ticket for the other platform).

## Parity Audit Patterns

Automated parity checking scans for divergence:

1. **Feature directory scan** — list feature directories on both platforms, flag features that exist on one but not the other
2. **Test file comparison** — compare test scenario names between platforms for each feature
3. **Domain model comparison** — check that entity names, field names, and DTO conventions match
4. **Error handling comparison** — verify the same error cases are handled on both platforms
5. **Parity table cross-reference** — check that every implemented feature has a parity table entry, and every table entry has matching implementations

**Output:** A gap analysis with specific items: "Platform A has `settings_deleteItem_removesFromList` but Platform B does not."

## Architecture Review as Early Parity Catch

The design review gate (see [07-reviews.md](07-reviews.md)) validates the Implementation Brief against cross-platform constraints **before code is written**:

- Does the proposed domain model match the canonical definition?
- Does the error handling cover all cases in the error hierarchy?
- Are the proposed state transitions consistent with the state machine?
- Are the test scenarios comprehensive enough for both platforms?

Catching model mismatches at the brief stage costs minutes. Catching them after both platforms have implemented costs hours of refactoring.

## Case Study: Cross-Platform Native App

A native mobile project enforced parity across two platforms through three mechanisms:

**Cross-platform contract rule:** A path-scoped rule (triggered on shared documentation and core module changes) defined the canonical domain models (`Resource`, `ViewState<T>`, `DomainError`), delivery protocol (parallel by default, partial requires a label), and naming conventions. Both platform agents referenced this rule as authority.

**Parity reviewer agent:** After both platforms completed a story, a read-only parity reviewer compared: domain models, test scenarios, error handling, localization keys, naming consistency. It produced a verdict (PASS, MINOR, MAJOR) with specific findings.

**Testing parity table:** The testing strategy document contained a feature-by-scenario-by-platform matrix. Implementation skills updated it; parity audit skills verified it. Gaps were flagged as blockers for milestone completion.

The parity reviewer caught issues that per-platform reviews missed: one platform mapping a config error as a network error, different DTO field names for the same API response, and test scenarios that existed on one platform but not the other. These would have shipped as silent behavioral differences without cross-platform verification.
