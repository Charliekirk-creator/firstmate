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
ok - spawn delivers validated bytes despite source and snapshot replacement
ok - sidecar validation hashes one captured byte sequence
ok - manifest intake canonicalizes one capture and rejects source rewrites
ok - concurrent identical records converge and intentional unlinked intake stays explicit
ok - spawn retries adopt one exact endpoint creation receipt
ok - pre-metadata dispatch retries resume one exact owner receipt
ok - metadata projection validates one stable captured byte sequence
ok - namespaces remain distinct and version, role, duplicate, contradiction, and id syntax are closed
ok - unsafe manifests, labels, stored files, cross-home copies, and task mismatches refuse
ok - generated instructions and metadata freeze the exact relation against stale edits
ok - legacy tasks stay explicitly unlinked despite every fuzzy fallback signal
ok - secondmate structured summary and Bearings expose one exact delegated-child worker
ok - linked handoff rebinds identity for delegated decision summaries and Bearings
ok - handoff preparation freezes intake and failed batches leave no immutable target sidecars
ok - snapshot preflight blocks prepared ownership and recovers exact dispatch metadata
ok - delegated linked integrity failures stop parent publication
ok - schema-maximum delegated identities use bounded remote pages
ok - Bearings preserves complete IDs and labels for every bounded worker row
ok - remote handoff commits an exact destination identity and source tombstone
ok - fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly
ok - fixture snapshot covers task rows, backlog rows, pointers, and stable ordering
```

The focused suite covers single and multiple work units, Work Aligner `plan_id` and `work_units`, DTM project and issue IDs, Data Team Ticket IDs, local Firstmate plans, namespace separation, complete stable IDs paired with labels, absent and filesystem-component-overlong legacy records, idempotence, exact path/task/stable-home binding, local and remote handoff rebinding, malformed versions and syntax, duplicate and contradictory IDs, unsafe paths, C1 controls, Unicode format controls, symlink and hardlink refusal, stale digest refusal, delegated fail-stop propagation, schema-maximum per-home paging under one deadline, stable snapshot output, active and held delegated-child projections, main and delegated status decisions, nested active, decision, hold, and queue omission disclosure, and every prohibited fuzzy signal.
It also confirms that relation recording changes no runtime task-state file, manifest intake and metadata projection each validate one captured byte sequence and refuse a same-size source rewrite, and all tools receive one captured launch input even when the source and launch snapshot change after preflight. Metadata binds the delivered byte digest and exact transaction receipt, projection refuses advertised transactions without that owner receipt, an exact pre-metadata retry adopts its task-bound endpoint and resumes the prepared receipt, completed dispatch history retires after lifecycle cleanup, prepared ownership omitted from backlog and metadata still blocks every snapshot mode, exact published metadata recovers an interrupted dispatch commit, secondmate projection follows the metadata-bound launch snapshot, handoff prepare excludes concurrent intake, failed multi-item staging publishes no immutable destination sidecar, and successful or recovered local and remote transfers retain exact source tombstones and destination commit receipts.

## Runtime-backend applicability

The backend review covered every spawn-capable runtime supported on 2026-08-14:

| Runtime backend | Applicability | Evidence boundary |
| --- | --- | --- |
| tmux | Applicable | The common spawn preflight snapshots and validates identity before tmux endpoint creation, then receipts the exact session, target, and stable window ID. |
| Herdr | Applicable | The same preflight receipts the exact session, workspace, tab, pane, and target for flat or presentation creation. |
| Zellij | Applicable | The same preflight receipts the exact session, tab, pane, and target after creation. |
| Orca | Applicable | The same preflight receipts the exact worktree, terminal, target, and path after creation. |
| cmux | Applicable | The same preflight receipts the exact workspace, surface, and target after creation. |

No backend parses the relation or receives a backend-specific identity format.
All five converge on the same captured launch input and schema/status/identity-digest/instruction-digest metadata fields.
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

| Worker tool | Validated launch-snapshot path | Applicability |
| --- | --- | --- |
| Claude | Full encoded snapshot passed at launch | Applicable without a tool-specific parser. |
| Codex | Full encoded snapshot passed at launch | Applicable without a tool-specific parser. |
| OpenCode | Full encoded snapshot passed at launch | Applicable without a tool-specific parser. |
| Pi | Full snapshot passed with the worker extensions | Applicable without a tool-specific parser. |
| pi-signed | Full snapshot passed through the exact signed selection | Applicable without a tool-specific parser. |
| Grok | Full encoded snapshot passed at launch | Applicable without a tool-specific parser. |
| Kimi | Full captured operational input delivered after TUI readiness | Applicable without a post-validation path reread. |
| Cursor | Full snapshot passed with the exact workspace | Applicable without a tool-specific parser. |
| Muse | Full encoded snapshot passed at launch | Applicable for its supported crewmate and scout roles. |

Persistent secondmate agents are not work-unit workers themselves.
Their local and remote control tasks refuse linked intake before endpoint or home mutation and record the route as explicitly unlinked; their ship and scout children use the same table in the secondmate home's ordinary spawn path, while Muse remains inapplicable to the persistent secondmate role for its pre-existing supervision limitation.
No tool may infer a relation from rendered output, process identity, endpoint labels, or status prose.
