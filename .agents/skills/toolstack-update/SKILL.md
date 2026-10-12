---
name: toolstack-update
description: >-
  Inspect the installed and actually used toolstack and propose individually approved updates.
  Use when the captain asks to inspect or update the toolstack, or invokes /skill:toolstack-update.
  Defaults to inspection; preserves existing update owners, pins, active work, and credentials.
user-invocable: true
disable-model-invocation: true
metadata:
  internal: true
---

# Approval-first toolstack updates

This skill is the authoritative workflow owner.
It coordinates existing supported owners, not a new updater, scheduler, or service.
Inspection, a completed report, or a request to build this skill grants no installation or update authority.
Never activate a proposed package just because an inventory or earlier assessment mentioned it.

## Discovery, scope, and invocation

This is a **project-shared Firstmate skill**, not a user-level personal skill and not an installer-facing public skill.
Its tracked location is `.agents/skills/toolstack-update/SKILL.md` in the Firstmate code root.
Official [Pi skill documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md) specifies project `.agents/skills` discovery from the working directory through its ancestors, stopping at the repository root, subject to project trust and resource filters.
The Main Pi session can explicitly invoke `/skill:toolstack-update inspect` when running from its trusted Firstmate copy; `/skill:toolstack-update` also defaults to inspection.
A fresh session or an independently approved reload is needed to refresh an existing resource listing after installation.
Do not reload, install, or change trust/settings as part of building or inspecting this skill.

Project scope is **not Main-only**: other Pi sessions, workers, and second mates in that trusted Firstmate copy can discover the same skill.
Discoverability is not authority.
Only the owning primary firstmate may collect the captain's approval and coordinate an update; a worker or second mate returns findings to its primary instead of applying host-wide changes.
The supervision branch's resource configuration is independent; do not assume it inherits this skill.

Pi's user locations `~/.pi/agent/skills/` and `~/.agents/skills/` are personal and can expose skills across unrelated folders.
This change does not write to either, register a personal package, or make this skill available outside Firstmate by implication.
A later personal Main Pi installation requires a separate, explicit destination/discovery decision that refers to this owner rather than copying its behavior contract.
Firstmate's public `skills/` directory is installer-facing and is not this destination; `metadata.internal` preserves the existing installer-discovery convention, not a Pi role restriction.
Other harnesses follow the existing Firstmate skill-loading instructions; this skill changes no adapter, backend, hook, or session lifecycle.

## Inspection and evidence

Read an existing task assessment when relevant, then refresh only volatile evidence.
Do not launch another design investigation when established evidence already answers the question.

Use `python3 scripts/proposals.py catalog`, resolving the path from this skill directory, for the exact default target catalog and dependency-only exclusions.
That helper owns catalog membership; do not keep another target list in a prompt, settings file, or documentation page.
Its header and `--help` own the bounded JSON interface, supported dispatch descriptions, and exact mechanical prerequisites.
Python 3 is an existing local dependency for the helper, not an update target or an installation authorized by this skill.
If it is absent, report the missing dependency; do not install it automatically.

For each catalog target:

1. Establish whether it is installed, actually used, merely installed, or proposed.
   Record the observation time and evidence for usage separately from installation.
   A process name or an old report does not prove current work, loaded code, or health.
2. Resolve the executable's real path, package manifest/receipt, selected installation owner, and every relevant copy on PATH.
   Compare installed and loaded versions separately, including compatible older servers.
   Do not choose another owner because it advertises a newer version.
3. Compare canonical installed and available versions using official public release/registry metadata or a documented inspection-only owner command.
   Never call a mutating updater to check availability, invent a `--check` flag, interpret a failed fetch as “current”, or retry indefinitely.
   Existing configured Firstmate update notifications are evidence inputs; [the existing check owner](../../../bin/fm-tool-update-check.sh) already handles release/PATH-skew notifications.
   Do not arm a second schedule or edit watched-tool configuration under inspection authority.
4. Inspect the entire applicable changelog interval, runtime requirements, extensions, plugins, schemas, owner migrations, known issues, and compatibility with active consumers.
   A successful package installation or permissive peer range is not compatibility proof.
5. For Pi, inventory enabled package declarations and explicit pins, discovered extensions, all skill source locations including symlinks, and prompt templates including command collisions.
   Distinguish presence, discoverability, and actually loaded resources in each process.
   Mark the helper's resource inventory complete only after all three resource kinds and both relevant user/project scopes have been inspected, including known-empty locations.
   Preserve exact package declarations and scope; do not reconcile the entire package set.

Inspect dependencies only when needed to establish a target's owner or compatibility.
Do not turn an excluded application, Node, a package manager, provider executable, MCP server, or newly proposed package into a default update target.
Read only dependency identities, versions, and configuration **field names or narrowly selected non-secret values** needed for the contract.
Never dump credential stores, auth files, account data, environment values, provider tokens, unrelated private source, or whole settings files.
No login, OAuth refresh, keychain prompt, provider inference, payment, browser auto-install fallback, or new network exposure is an inspection or smoke-test prerequisite.

The proposal helper consumes only selected non-secret facts supplied on stdin.
It does not discover the host, open configuration/credentials, run subprocesses, access the network, or execute any update, even after preparation.
Unknown observations remain unknown; absent tools are not implicit installation requests.
`inspect` is the default and never returns an executable update action.
`propose` describes exactly one concrete target or one inventoried Pi resource and requests individual approval.

## Proposal and individual approval

For each candidate, present the observed current -> proposed version, unchanged source/owner/scope, relevant release changes, compatibility evidence, affected dependencies, exact supported owner action, disruption, required maintenance boundary, protected state, rollback limitations, and verification plan.
Separate no-change, unknown, deferred, and candidate outcomes.
Do not convert multiple candidates into an “approve everything” installation step.

Ask the captain for approval of **each concrete update** before executing it.
Bind approval to that target/resource, observed current and proposed versions, owner command or skill, unchanged package declarations, scope, and maintenance consequences.
Approval for one target cannot authorize another, a later release, an owner migration, or a changed package pin.
Record the captain's actual answer through [the existing decision owner](../captain-hold-lifecycle/SKILL.md) when a task is held for it; do not fabricate an approval or infer one from silence or a broad intent to inspect.
A scout report, a helper's JSON, approval of another or already completed update, or an `approved` field written by the worker is not captain authority.

The helper's `prepare` command checks one supplied approval against a freshly regenerated proposal and a complete primary-owned checkpoint.
It is a **non-executing consistency check**, not an independent authorization source or proof that supplied observations are true.
Unknown/mismatched evidence, altered commands, stale or batch approvals, changed pins/declarations, and active or unknown affected work refuse preparation.
Do not spoof or weaken its checkpoint to obtain a command.

If a supported native owner selects mutable `latest`, confirm the reviewed release again immediately before action.
When a fixed-version guarantee is required and that owner cannot provide it, stop and obtain approval for its documented exact-version route, if any; do not invent flags or silently substitute installers.
A changed release or dependency footprint requires a new proposal and answer.

## Active work and existing owners

Checkpoint the **affected** consumers, not just the visible primary session: active sessions and workers, pending review feedback, shared services, validation custody, in-flight Git/forge operations, and held captain decisions.
Use current structured state through existing owners for recorded direct reports; never survey or control another home's children.
If work would be affected or its safety is unknown, defer the update.
“Paused”, quiet, or an empty main-home queue is not a maintenance window.
Do not stop, cancel, stash, discard, force-release, resume, reload, or restart anything to make the checkpoint pass.
Preserve explicit pins, package declarations, credentials, protected local state, and a reviewed recovery path.

Firstmate updates remain exclusively owned by [the `/updatefirstmate` skill](../updatefirstmate/SKILL.md).
Invoke that skill with the concrete approval from the owning code root/home; never replace it with raw pulls, private-helper calls, remote changes, or duplicated re-read/nudge logic.
Its guarded skips are outcomes, not obstacles to bypass.
Do not confuse a configured fork's head with upstream convergence.

For other targets, use only the inspected tool's supported owner command.
The helper describes reviewed common owners and refuses unknown ones instead of guessing.
Load current owner help before action and preserve the selected source, scope, pins, and installation method.
`tasks-axi update` edits a task, not the CLI; do not use it as a self-updater.
A pinned Pi package stays pinned; project package operations require proven project-only owner isolation, not the assumption that a personal operation is project-local.
Locally maintained extensions, skills, and templates need their actual source owner's separately reviewed change, not a package-manager sweep.
No blanket package-manager updates, all-package Pi updates, all-skill pulls, or channel switches are permitted.

Herdr client installation and loaded-server convergence are separate actions.
Use its current installation owner, not a native installer over a package-manager copy.
Any lifecycle action requires the [existing guarded Herdr contract](../../../docs/herdr-backend.md#destructive-lab-safety) and the owning primary's explicit authority; an unguarded worker must stop rather than append lifecycle commands to its instructions.
Compatible older servers do not require an invented restart.

No Mistakes updates reset a shared daemon serving multiple lanes/homes.
Workers never stop, restart, or update it.
Only the primary may arrange a separately approved shared maintenance interval after the current validation owners have settled custody; inspect parked decisions, pushes, and CI too.
Never force or cancel an active run to proceed, and never add `--yes`, `--force`, or daemon-reset workarounds.
The helper's generic checkpoint cannot prove that shared custody is clear.

Review-tool updates can replace shared servers or interrupt polls; preserve all affected reviews and stricter local skill/version/security pins first.
Browser CLI commands can download an MCP dependency implicitly; resolve its existing transport/owner before a test.
The Apple-owned Git update can replace the wider Command Line Tools bundle; disclose and approve that scope rather than installing Homebrew Git or changing PATH by inference.

## Apply, verify, and report

After the specific approval and clear checkpoint, invoke the existing owner **once for that item**.
The proposal helper has no apply path; the agent uses the existing owner directly.
Never feed emitted JSON to a generic shell/eval runner.
Do not make unrelated installers, dependency updates, access changes, publishing, license acceptance, deletion, service replacement, or irreversible migration incidental to a tool update.
Those need separately stated authority or a deferred outcome.
On an owner failure, stop that item, preserve evidence and custody, and report the concrete failure; do not silently retry through a different owner.

Verify installed **and effective** versions, realpath/owner identity, retained settings/pins/packages/local state, applicable health, and the smallest permitted behavior check before moving on.
Start with credential-free version/help/static checks; runtime tests or session resumption need their own established permission and maintenance boundary.
Installation success does not prove a running server, bridge, worker, or session loaded the new code.
A partial install with an offline service is a failed verification, not a successful update.
Use only the approved recovery path; a prior binary does not undo a database, pool, config, or session migration.
Never promise rollback merely because an older version can be downloaded.

Write an auditable per-item result with observation time, before/proposed/actual/effective versions, source/owner identity, approval scope, executed owner action, outcome, verification, recovery used or limitations, and deferred items with concrete recheck conditions.
Keep secrets and private task content out of that summary.
When a response is needed, translate outcomes and decisions under Firstmate's existing captain-facing conventions.
Do not end blind while live work remains; this skill neither replaces nor arms supervision.
