# Exact work identity verification

Audience: maintainer verification.

[`bin/fm-work-identity.sh`](../../bin/fm-work-identity.sh) is the single data-contract and validation owner.
[`docs/work-identity.md`](../work-identity.md) owns current operator usage without restating that schema.

## Public-interface evidence

The contract was verified on 2026-08-14 on macOS arm64 through public commands and fleet projections:

```sh
tests/fm-work-identity.test.sh
tests/fm-remote-backlog-handoff.test.sh
tests/fm-brief.test.sh
tests/fm-fleet-snapshot-view.test.sh
```

Bounded output:

```text
ok - exact multi-work-unit intake survives instructions, metadata, snapshot, and Bearings once per worker
ok - concurrent identical records converge and intentional unlinked intake stays explicit
ok - namespaces remain distinct and version, role, duplicate, contradiction, and id syntax are closed
ok - unsafe manifests, labels, stored files, cross-home copies, and task mismatches refuse
ok - generated instructions and metadata freeze the exact relation against stale edits
ok - legacy tasks stay explicitly unlinked despite every fuzzy fallback signal
ok - secondmate structured summary and Bearings expose one exact delegated-child worker
ok - linked handoff rebinds identity for delegated decision summaries and Bearings
ok - delegated linked integrity failures stop parent publication
ok - schema-maximum delegated identities stream in bounded normalized batches
ok - Bearings preserves complete IDs and labels for every bounded worker row
ok - remote handoff stages an exact destination-bound identity before receipt
ok - fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly
ok - fixture snapshot covers task rows, backlog rows, pointers, and stable ordering
```

The focused suite covers single and multiple work units, Work Aligner `plan_id` and `work_units`, DTM project and issue IDs, Data Team Ticket IDs, local Firstmate plans, namespace separation, complete stable IDs paired with labels, absent legacy records, idempotence, exact task and home binding, local and remote handoff rebinding, malformed versions and syntax, duplicate and contradictory IDs, unsafe paths and labels, symlink and hardlink refusal, stale digest refusal, delegated fail-stop propagation, schema-maximum bounded batching, stable snapshot output, delegated-child and secondmate projections, decision surfaces, and every prohibited fuzzy signal.
It also confirms that relation recording changes no runtime task-state file and that handoff rebinding adds only local destination identity bookkeeping before the existing backlog move.

## Runtime-backend applicability

The backend review covered every spawn-capable runtime supported on 2026-08-14:

| Runtime backend | Applicability | Evidence boundary |
| --- | --- | --- |
| tmux | Applicable | The common spawn preflight validates identity before tmux endpoint creation. |
| Herdr | Applicable | The same preflight runs before Herdr flat or presentation endpoint creation. |
| Zellij | Applicable | The same preflight runs before Zellij tab creation. |
| Orca | Applicable | The same preflight runs before Orca worktree and terminal creation, and retained abort metadata carries the same binding. |
| cmux | Applicable | The same preflight runs before cmux workspace creation. |

No backend parses the relation or receives a backend-specific identity format.
All five converge on the same generated instructions and schema/status/digest metadata fields.
A secondmate child uses the same interface in its own exact `FM_HOME`; local and remote parent projections consume the bounded `fm-secondmate-home-summary.v1` result rather than scanning or reconstructing that child home.

The common spawn and projection boundaries were exercised with:

```sh
tests/fm-spawn-worktree-settle.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-trace-context-spawn.test.sh
tests/fm-bearings-snapshot.test.sh
```

Bounded output:

```text
ok - a single transient stale pane_current_path read is not accepted as the worktree
ok - batch dispatch re-execs and reports every id=repo pair
ok - relaunch reuses the recorded carrier verbatim for both the meta record and the injected export
ok - TOON and JSON are parity representations of the same model
```

## Worker-tool applicability

The launch-template review covered every verified worker tool supported on 2026-08-14:

| Worker tool | Generated-instruction path | Applicability |
| --- | --- | --- |
| Claude | Full encoded brief passed at launch | Applicable without a tool-specific parser. |
| Codex | Full encoded brief passed at launch | Applicable without a tool-specific parser. |
| OpenCode | Full encoded brief passed at launch | Applicable without a tool-specific parser. |
| Pi | Full brief passed with the worker extensions | Applicable without a tool-specific parser. |
| pi-signed | Full brief passed through the exact signed selection | Applicable without a tool-specific parser. |
| Grok | Full encoded brief passed at launch | Applicable without a tool-specific parser. |
| Kimi | Exact absolute brief pointer delivered after TUI readiness | Applicable to the same immutable brief. |
| Cursor | Full brief passed with the exact workspace | Applicable without a tool-specific parser. |
| Muse | Full encoded brief passed at launch | Applicable for its supported crewmate and scout roles. |

Persistent secondmate agents are not work-unit workers themselves.
Their ship and scout children use the same table in the secondmate home's ordinary spawn path, while Muse remains inapplicable to the persistent secondmate role for its pre-existing supervision limitation.
No tool may infer a relation from rendered output, process identity, endpoint labels, or status prose.
