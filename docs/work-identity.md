# Exact work identity

Firstmate can bind one task to an exact project or initiative, plan, stage, one or more work units, and one or more source-system records before dispatch.
The public intake command is [`bin/fm-work-identity.sh`](../bin/fm-work-identity.sh).
Its header and `--help` output are the single owner of the complete `fm-work-identity.v1` schema, namespace matrix, syntax, storage, binding, and refusal rules.

## Record an intake relation

Generate a home-bound and task-bound manifest template into an ordinary temporary file:

```sh
bin/fm-work-identity.sh template <task-id> > /tmp/<task-id>-work-identity.json
```

Replace every placeholder ID and label with accepted exact values.
The command records identities but does not verify that an external system currently contains them, so intake must use the accepted IDs from the authoritative project, plan, DTM, or ticket source.

Record the completed manifest before generating the task instructions:

```sh
bin/fm-work-identity.sh record <task-id> --file /tmp/<task-id>-work-identity.json
bin/fm-work-identity.sh verify <task-id> | jq .
```

Then scaffold and dispatch the task normally.
`fm-brief.sh` embeds the canonical payload and digest in the generated instructions. `fm-spawn.sh` copies the brief to a per-task launch snapshot, validates and captures its bytes before creating an endpoint, binds both its path and SHA-256 digest in task metadata, and delivers the frozen operational input without rereading the owner-writable snapshot. Kimi receives the same frozen input after its readiness gate.
Replacing the source brief during launch therefore cannot change what any supported worker tool receives.
Repeating `record` with the same manifest is an idempotent no-op.
A relation is immutable once recorded, and a changed relation requires a new task identity.

## Namespaces and labels

Work Aligner `plan_id` and `work_units`, DTM projects and issues, Data Team Tickets, and local Firstmate plan identities use separate namespaces.
A task can carry several exact work units while remaining one worker in fleet counts.
Every exact identity is paired with a human display label, but the namespace, kind, and ID tuple alone establishes identity.

The binding combines the physical home path with a stable `main` or `secondmate:<id>` home identity, so a remote secondmate at the same absolute path as its primary remains a different owner.
Tasks without a record remain compatible and appear explicitly as unlinked, including path-safe legacy task IDs longer than the current intake limit.
Firstmate never constructs a relation from a task title, repository, branch, endpoint, worker name, time, label, or status text.

## Read-only projections

The authoritative fleet snapshot exposes the structured identity on task rows, backlog rows, and validated secondmate child summaries.
A child summary carries one normalized task reference index, and the primary resolves each exact projection once through schema-sized bounded batches before publishing any delegated surface.
Bearings keeps one row per worker and renders every complete exact ID beside its label, including a separate delegated-child projection for work running inside a secondmate home.
The primary does not reconstruct local or remote child trees, and an identity-integrity failure in a readable child home stops the parent snapshot instead of becoming an unknown transport result.

A local or remote backlog handoff durably prepares an exact source-to-destination transfer through the same contract owner before the backlog row can move.
New intake and snapshot publication stop while that transfer is pending; after the backlog arrives, the destination retains an exact completed-transfer receipt and the source retains a completed ownership tombstone. A retry that proves the destination commit completes rather than cancels source ownership.
A failed pre-move batch cancels its prepared records without publishing immutable destination sidecars, while an uncertain remote result preserves the outbox and prepare state for `--resume-pending`.
Reading, recording, or rebinding this local relation does not change task lifecycle state, assignment, GitHub, DTM, Data Team Ticket, or a Work Aligner plan.
Malformed, stale, unsafe, cross-home, or task-mismatched linked records stop publication instead of being shown as unlinked.

Maintainer coverage and the backend and worker-tool applicability review are recorded in [`verification/work-identity.md`](verification/work-identity.md).
