# Inactive metadata compaction policy

[`bin/fm-compact-metadata-policy.mjs`](../bin/fm-compact-metadata-policy.mjs) exports only `evaluateMetadata(metadata, guards, thresholds)`.
It is an import-only, deterministic offline prototype, not a Pi extension, command, tool, package, or registered resource.
Nothing imports it at runtime, and executing the file directly has no effect.
It has no dependencies, collector, workflow producer, lifecycle subscriptions, timer, UI, or background service.
Native Pi remains the sole compaction owner.

## Input boundary

Each argument must be an ordinary same-realm data record with `Object.prototype`, or a null-prototype data record.
Only the exact enumerable own string keys below are accepted, with no custom prototype, inherited fields, extra keys, symbols, non-enumerable fields, accessors, or nested values.
Validation snapshots data descriptors without invoking property getters, coercion, or serialization.
Invalid inputs and synchronous internal errors return only `unavailable`, never echoed values or error details.
JavaScript reflective operations can execute hostile Proxy traps; this boundary is not a sandbox for caller code or a compromised process.
Callers must construct primitive records rather than passing a context, event, session manager, or spread of private runtime data.

The metadata record has exactly five fields:

| Field | Accepted value |
| --- | --- |
| `schemaVersion` | Literal number `1` |
| `contextTokens` | Non-negative safe integer, or `null` for unavailable usage |
| `contextWindow` | Positive safe integer, or `null` for unavailable capacity |
| `nextStep` | `owed_now`, `none_now`, or `unknown` |
| `checkpointRecord` | `current`, `missing`, or `unknown` |

`none_now` declares no presently actionable step owed by this assistant, not project completion.
`current` declares that essential requirements, decisions, blockers, next actions, and recovery references have been recorded in their existing authoritative records; it does not prove correctness, retention, or future recall.
These fields must be explicit declarations, never inferred from idle/settled state, tool success, failure, elapsed time, or saved-file counts.
Null is accepted only for the two usage fields and the guard's declaration generation.
Usage above the window is valid high pressure and is not clamped.
Numbers are JavaScript safe integers; negative zero is valid zero where non-negative integers are allowed.

The separate guards have exactly these keys:

| Field | Accepted value |
| --- | --- |
| `generation` | Non-negative safe integer |
| `declarationGeneration` | Non-negative safe integer, or `null` for missing declarations |
| `interactiveEligible` | Boolean |
| `idle` | Boolean |
| `hasQueuedInput` | Boolean |

One declaration generation binds both explicit checkpoint fields.
The policy owns no generation state and cannot establish its provenance or freshness independently.
Synthetic tests supply invalidated snapshots for input/run start, session changes, navigation/fork, model changes, compaction attempts/results/failures, shutdown, and failed/aborted runs.
A hypothetical future caller must invalidate declarations across those boundaries and start unknown on reload/resume, avoid generation reuse or wraparound, and check eligibility immediately before presenting advice.
That caller is not implemented or authorized by this module.
Failure or abortion followed by idle must not silently restore old declarations.

Thresholds must be explicitly injected with exactly `minimumContextTokens` (non-negative safe integer) and `usageThreshold` (finite number greater than zero and at most one).
There are no production defaults, inferred settings, calibration, or claims to match Pi's native reserve-based trigger.
The test values are invented parameters only.

## Fixed results

The function applies this order:

1. Invalid input/parameters, unavailable usage, non-interactive eligibility, active work, or queued input returns `unavailable`.
2. Tokens below the absolute minimum or `tokens / window` below the usage threshold returns `below_threshold`.
   Equality reaches each threshold; ratio comparison uses JavaScript number arithmetic.
3. High pressure with `nextStep=none_now`, `checkpointRecord=current`, and a non-null declaration generation equal to the current generation returns `recorded_checkpoint_opportunity`.
4. Other high-pressure states, including unknown/missing/stale declarations, return `pressure_only`.

An opportunity is an advisory distinction, not an instruction or authorization to compact and never a claim of semantic safety.
The module does not read history, summaries, tool data, editor text, files, paths, identifiers, model/provider names, credentials, session IDs, or content hashes.
It does not call a model, network, filesystem, logger, persistence/configuration API, message injection, or compaction/cancellation/replacement controls.
There is no Main integration, installed Compact Adviser/Jev reuse, activation, installation, hints, automatic compaction, logging, reload/restart, package update, deployment, or publication step.
Even these non-text fields reveal workflow activity or capacity and must not be treated as non-private or approved for remote disclosure.

## Offline verification

Run the existing behavior-test entry point with Node.js 18 or newer:

```sh
bin/fm-test-run.sh tests/fm-compact-metadata-policy.test.sh
```

The executable tests cover all explicit-state/guard combinations, malformed records, safe-integer and threshold boundaries, null/unknown usage, overflow pressure, stale declarations, failed/aborted/queued cases, and input immutability.
A separate execution realm denies dependencies and exposes throwing history/editor, network, filesystem, credential, logging, persistence, configuration, registration, injection, and compaction capabilities.
The test harness loads module bytes before denial solely to execute the public interface, without source-byte assertions, packages, real history, or paid calls.
These seams verify this policy's behavior, not isolation from malicious extensions or compromised JavaScript intrinsics.

Six predeclared synthetic scenarios compare the explicit checkpoint rule with a pressure-only rule.
All have identical high pressure and eligible runtime guards; only one declares both no owed step and a current record.
If pressure alone is misrepresented as a checkpoint opportunity, it yields five false affirmative checkpoint claims against those declarations; the explicit rule suppresses them.
A pressure-only advisory that claims only pressure makes no checkpoint assertion in the first place.
This comparison demonstrates deterministic policy discrimination, not real-world semantic safety, beneficial compaction timing, post-compaction retention, or superiority over native Pi.
