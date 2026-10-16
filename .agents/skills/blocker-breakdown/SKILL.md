---
name: blocker-breakdown
description: >-
  Explain one named current blocker or all current blockers as a teaching-oriented, evidence-backed breakdown without starting remediation.
  Use when the captain invokes /blocker-breakdown, asks why one named item is blocked or stuck, or asks to explain all current blockers.
  Do not use for ordinary implementation requests, ordinary status requests, raw worker events, or unrelated uses of the word blocked.
user-invocable: true
metadata:
  internal: true
---

# blocker-breakdown

Explain why work cannot advance, teach the relevant technical idea, and leave authority exactly where it already belongs.
This is a read-only explanation procedure.
It never starts a fix, answers a product decision, grants access, expands permissions, steers or changes a worker, changes task lifecycle, merges, deploys, or treats an explanation as approval to remediate.

## Trigger and scope

Load this skill for:

- an explicit `/blocker-breakdown` invocation;
- a request to explain why one named task, PR, project, or other work item is blocked or stuck; or
- a request to explain all current blockers.

Do not load it merely because a request contains `blocked`.
An ordinary implementation request, ordinary fleet or status request, pasted or raw worker event, and an unrelated phrase such as "blocked layout" are not blocker-breakdown requests.
Use Bearings for a general status digest.
Use the normal diagnostic and delivery lifecycle when the captain asks to investigate or fix rather than explain.

Choose the narrowest requested scope.
For one named item, explain only that item and the directly necessary dependency context.
Do not add a fleet-wide table or unrelated blockers.
For an all-blockers request, cover every blocker that authoritative current state shows as active across the main home and registered secondmate homes.
Put deliberately paused or historical work in a separate **Paused or historical, not active** section, and do not count it as an active blocker.
If that section is empty, say so.

## Establish current truth

Capture the observation time, timezone, and source for every material fact.
Use the existing authoritative owner interfaces rather than collecting fleet state yourself:

1. Use `bin/fm-bearings-snapshot.sh --json` for bounded fleet-wide enumeration and registered-secondmate structured-home state.
2. For a named main-home direct report, or whenever a main-home row's current condition matters, use `bin/fm-crew-state.sh <id>` at explanation time.
3. Use the configured backlog interface for the item's durable work record, dependency, hold, and owner information.
4. Use guarded PR state interfaces when a PR's present state is part of the blocker.
5. For a secondmate-owned item, use that home's routed structured result or request the explanation through the registered secondmate route when the available structured state is insufficient.
   Never inspect private child chat or reconstruct the secondmate's child tree from the parent home.

Do not infer current truth from old event lines, terminal history, a previous report, or conversation memory.
Old evidence may explain chronology only after current state is established, and it must be labeled historical with its own timestamp.
Do not create a new fleet-state script, parser, cache, or parallel collector for this skill.
If current state cannot be obtained, say exactly what source or access is unavailable and classify that limitation instead of converting stale evidence into certainty.

## Analyze before writing

Separate evidence from inference.
Mark the cause as **confirmed** only when current authoritative evidence or a reproducible causal result supports it.
Otherwise mark it **hypothesis**, state what evidence supports it, and name the next observation that could confirm or disprove it.

Assign exactly one primary classification:

- **Technical defect** - code, configuration, infrastructure, or tool behavior is wrong.
- **Source/access limitation** - required evidence, credentials, service, repository, or interface is unavailable.
- **Deliberate pause** - work was intentionally deferred or is waiting for a known external condition.
- **Coordination obstruction** - ownership, dependency ordering, handoff, or another work stream prevents progress.
- **Product/scope choice** - materially different accepted outcomes require the captain's decision.

State whether retrying can help and why.
A retry is useful only when the failure is plausibly transient or the prerequisite has changed.
Repeated execution cannot repair a deterministic defect, missing authority, unavailable credential, unresolved dependency, or product choice.

Identify the smallest safe correction without performing it.
Give at least one materially different direction when one genuinely exists and explain its tradeoff.
Do not manufacture a false alternative when only one safe correction fits accepted intent.
Name the exact owner who can take the next action and the existing authority boundary, including any captain-only access, decision, merge, deployment, destructive, irreversible, or security-sensitive action.

## Response contract

Address the captain and follow `AGENTS.md` section 9's captain-facing language contract.
Translate internal labels and raw evidence into outcomes rather than relaying worker output verbatim.
Keep the depth proportional to the request.

For each active blocker, include these fields in this order:

1. **Blocker** - the affected work and immediate consequence.
2. **Technical explanation** - the mechanism that prevents progress.
3. **Plain-English explanation** - the same mechanism without specialist vocabulary.
4. **Evidence** - timestamp, timezone, authoritative source or routed provenance, and a freshness statement.
5. **Cause confidence** - `Confirmed` or `Hypothesis`, with the reason and disconfirming test when applicable.
6. **Classification** - one category from this skill's classification list.
7. **Will retrying help?** - yes, no, or only after a named condition changes, with why.
8. **Smallest safe correction** - the minimum bounded action that could clear it, explicitly presented as explanation rather than authorization.
9. **Different direction** - one materially different option and its tradeoff when one exists, otherwise say that no materially different safe direction is evident.
10. **Owner and authority** - who owns the action and what this explanation does not authorize.
11. **Next success proof** - the observable current result that would prove the blocker cleared.
12. **CS concept** - one relevant computer-science concept, defined briefly and tied to this blocker.
13. **Diagnostic question** - one question whose answer would most reduce the remaining uncertainty or distinguish the next paths.

A named-blocker answer may use short paragraphs rather than a table, but it must retain every field.
An all-blockers answer starts with **Active blockers**, gives one compact subsection per active blocker, then gives **Paused or historical, not active** as a visibly separate section.
Paused or historical entries need enough evidence and timing to explain why they are excluded, but do not need the full thirteen-field active-blocker treatment unless the captain asks.
If no active blocker is confirmed, say so and distinguish unavailable evidence from an actually clear fleet.

End with a one-sentence boundary such as: "This breakdown explains the next safe move; it does not authorize or start it."
Do not turn the final diagnostic question into a demand that the captain decide unless the existing authority boundary genuinely places that answer with the captain.

## Trigger and output scenario matrix

This matrix documents judgment-based interpretation; it is not an executable classifier contract and must not be converted into a keyword parser or live-model CI test.

| Request | Load? | Scope or result |
| --- | --- | --- |
| `/blocker-breakdown payments-api` | Yes | One named blocker only |
| `Why is the payments API task stuck?` | Yes | One named blocker only |
| `Explain all current blockers` | Yes | All active blockers, with paused or historical work separate |
| `Implement the retry fix` | No | Ordinary implementation lifecycle |
| `Give me a status update` | No | Ordinary status or Bearings path |
| `blocked: worker needs credentials` | No | Raw worker event handling |
| `Fix the blocked page layout` | No | Ordinary implementation request; "blocked" is unrelated |

Review examples against this matrix for explicit invocation, natural single-item and all-current-blocker requests, non-trigger cases, proportionate single-versus-all output, active-versus-paused separation, fresh sourced evidence, and the absence of remediation or permission expansion.
