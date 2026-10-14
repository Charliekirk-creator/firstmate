---
name: team-option-assessment
description: >-
  Agent-only local team-option procedure for each new substantial intake and material replanning point.
  Assess independent units, dependencies, contention, acceptance checks, fit, elapsed-time benefit, coordination and duplication costs, and one integration owner before recommending a team or a direct single-owner path.
  Optional Jev semantic advice requires exact bounded operator opt-in and permitted manually redacted descriptors and never authorizes action.
user-invocable: false
metadata:
  internal: true
---

# Team-option assessment

This skill is the single owner of the conditional team-option decision procedure.
Reliability Engineer owns its technical contract and maintainability.
Main remains the only assignment authority and captain communication point; domain owners remain accountable for execution.
A domain owner may prepare an assessment or report a material change to Main, but this procedure grants no sibling assignment or lifecycle authority.
Use the existing [intake and delivery contract](../../../AGENTS.md#7-task-lifecycle) to act on the recommendation.

## Trigger and bounded scope

Apply at each new substantial intake before assignment, and before materially replanning authorized work.
Substantial means multiple plausible deliverable units, cross-domain contributions, meaningful integration or uncertainty, or a shared-resource constraint that could change the execution plan.
A material replanning point changes scope, dependency edges, acceptance checks, resource availability, execution ownership, integration assumptions, or the critical path enough to reconsider the team option.
Routine progress, unchanged external waits, isolated mechanical edits, and an unchanged retry do not trigger another assessment.
For an obvious tightly coupled substantial task, a short single-owner card is sufficient; do not invent units to fill a table.
On replanning, update only the changed facts and resulting recommendation rather than restarting investigation or reassessing unchanged units.
Consult retained reports and existing work first, and stop the assessment once the safe plan and its rationale are clear.
Do not create a separate design scout, wrapper, control plane, service, or measurement project merely to complete this procedure.

## Local decomposition card

Record the compact assessment in the existing owning task note or task-scoped instructions before assignment, keeping it local and inspectable.
Inspect the existing note before updating it under [the backlog contract](../../../AGENTS.md#10-backlog-contract), and preserve a superseded recommendation when needed to explain a material replan.
Distinguish observed facts, estimates, and unknowns rather than manufacturing timing or certainty.
Use this shape, omitting empty table rows but not assessment dimensions:

```text
Accepted outcome and bounds:
Assessment point: intake or material change, with reason
Direct alternative: one accountable execution owner and acceptance check

Unit | bounded output | execution owner | prerequisites | acceptance check | model/tool fit

True dependency edges and ready-now units:
Shared mutable resources and contention controls:
Single-writer and active validation-custody boundaries:
Existing work and duplicate-work risk:
Integration owner and convergence check:
Direct critical path versus proposed critical path:
Elapsed-time benefit, total effort, coordination and integration/rework cost:
Uncertainty that could change the recommendation:
Recommendation: direct single owner or concise team option, with reason
Jev: not used, or bounded advice record
```

For each plausible unit, name a non-duplicating output, its accountable domain execution owner, and an independently executable acceptance check.
A check may be an executable test, a reproducible evidence query, or an observable artifact criterion appropriate to the deliverable; it is not an extra manual approval.
Record model/tool capability needs locally, including access and tool constraints, without choosing a provider or concrete profile through this assessment.
Actual model, effort, quota, authentication, and runtime selection remain with [the dispatch contract](../../../AGENTS.md#4-harness-and-runtime-dispatch) and its referenced owners.
A unit is ready now only if its prerequisites, authorized scope and access, required resources, and independent check are available.
Unknown live eligibility is not evidence of available capacity; verify only the narrow facts that affect the plan through existing owner interfaces.
Do not turn missing per-model quota or authentication-source detail into a new blocker contrary to the dispatch contract.

Treat file or subsystem overlap as a risk signal, not an automatic reason to wait.
Draw only true prerequisite edges, not edges inferred from same-file edits or preferred review order.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe, and keep genuine blockers durable.
Identify shared rate limits, mutable external systems, migrations, scarce isolated copies, common artifacts, and single-writer resources explicitly.
Separate independently usable offline work from serialized acquisition or mutation when that genuinely shortens delivery.
Name exactly one integration owner whenever independently produced units must converge, and record that owner's availability, input contracts, reconciliation work, and final convergence check before fan-out.
The integration owner is accountable for the combined result, not a new serial manual reviewer or an authority to take another domain's work.
Include integration and the selected delivery path in the critical path, not just parallel implementation time.
Keep one writer for each shared mutable resource and one owner for each active validation run; do not split or edit a branch in validation custody to gain parallelism.

## Deterministic recommendation and handoff

1. Eliminate duplicate outputs and units that merely repeat investigation, compete with an existing owner, or attempt to bypass a blocker.
2. Separate ready independent units from those waiting on true prerequisites or shared-resource ownership.
3. Compare the direct critical path and total effort with the proposed plan, including startup, coordination, integration, selected validation, and likely reconciliation or rework.
4. Recommend a concise team option only when those facts support credible net elapsed-time or efficiency benefit without unsafe contention.
5. Otherwise retain the direct single-owner path and name the bottleneck or coordination cost that makes fan-out unhelpful.

A credible efficiency benefit can be less duplicated effort or specialist rework at a similar elapsed time, but it must be explained rather than inferred from agent count.
Use rough ranges when supported by evidence and qualitative comparisons when timings are unknown; do not add an opaque composite score or arbitrary concurrency target.
Agent count is a consequence of the ready dependency graph and resource constraints, never a success metric.
A team recommendation names the bounded units, execution owners, ready-now work, true waits, one integration owner, and why it beats the direct alternative.
A direct recommendation names the single execution owner, acceptance check, and why splitting would not help.
For example, independent drafts from retained evidence can converge through one integration owner, while additional callers against one rate limit cannot shorten acquisition.

Main applies the existing scope routing, task filing, isolated dispatch, steering, supervision, delivery, and merge contracts to the chosen plan.
Dispatch already-authorized isolated work immediately when each change is independently executable and validatable and the selected delivery path can reconcile ordinary rebases or conflicts.
Do not add approvals, confirmation prompts, concurrency caps, or serial manual-review gates for that work.
Give a concise team option in the next natural captain-facing outcome when useful, without making acceptance of that option a prerequisite to authorized execution.
Escalate only an actual unresolved authority, scope, privacy, destructive-action, or product-contract choice through its existing owner.
This procedure does not create or restructure secondmates, change charters, transfer live work, deploy, or alter merge authority.
Material replanning preserves current owners, unlanded work, and validation custody; any needed handoff or supersession must follow the existing lifecycle owner rather than being performed by this adviser.

## Optional Jev semantic advice

### Eligibility and permission

The local card is mandatory for substantial cases; Jev is not.
The retained synthetic comparison found no advantage over local rules, so default to local reasoning and do not call Jev for trivial, obvious, or deterministically decidable cases.
Consider advice only for a genuinely ambiguous substantial semantic question where retained decomposition errors or a bounded comparison hypothesis explain potential measured value beyond the recorded local baseline.
Record that baseline, the ambiguity, expected added value, and how agreement, correction, elapsed overhead, coordination cost, and eventual rework will be compared in the same task record.
Do not manufacture assignments, repeat prior investigations, or run a benchmark as intake overhead.
Live capacity, access, dependency facts, resource ownership, and validation custody remain locally verified facts, not semantic questions.

External advice is inactive by default.
Before any call, require current explicit operator opt-in for this exact bounded use, a permitted disclosure scope covering every manually redacted descriptor and question, and already applicable finite attempt and spend limits.
Permission to share the minimum descriptors is not spend or credential-owner authority; never infer a cap, consume another trial's cap, or invent a budget.
An enabled tool, existing credential, historical role trial, generic external-service consent, or approval of the implementation is not that permission.
If permission or payload scope is absent or ambiguous, skip Jev and proceed locally without a confirmation prompt added to intake.
Do not widen prior trial permissions or reuse their remaining calls for decomposition.
Use only an already available, explicitly opted-in typed evaluation tool such as `typesafe_evaluate` within its documented bounds; if unavailable, fall back without installing anything or opening a credential flow.
Inspect its current help for the supported operator opt-in mechanism, and never bypass tool-enforced opt-in through a direct API or SDK call, enable it on the operator's behalf, or edit configuration or environment files to activate it.
Claim activation only when supported tests prove the exact enabled path; a registered tool or an inspected implementation proves neither activation nor a successful external request.
If live verification needs separate spend or credential-owner authority, report that precise optional-verification blocker to Main promptly and continue the deterministic local path and applicable offline coverage.
Do not read, copy, source, log, or expose credentials or secrets, and do not add a provider, background service, daemon, automatic request, or retry loop.
If the existing tool cannot meet the approved bounded call, timeout, and spend constraints, do not call it.

### Permitted descriptors

Construct only minimal manually redacted generic descriptors needed for the semantic question.
Do not read or extract secret material, private source contents, business rows, customer or personnel data, repository paths, URLs, real identifiers, or raw task text to build a Jev payload, and never copy, log, or expose that material in the request or advice record.
Do not serialize local task records, conversation history, reports, code, logs, file contents, financial quantities, company-specific terms, or private product intent.
Use generic deliverable, ambiguity, risk, collaboration, dependency, and acceptance-check classes instead of copied summaries.
Schema-local anonymous field names are allowed only to distinguish independent items; they must not encode real task, project, person, repository, or resource identities.
Check the entire outbound state, questions, criteria, and labels against the approved scope before calling; redaction uncertainty means no call.
Best-effort automated redaction is not permission or a privacy boundary.

### Questions, results, and local fallback

Ask only semantic recommendation questions, never calculations, exact lookups, or action-authorization questions.
When several independent questions are justified, batch them against one permitted redacted state within the tool's limits.
Give each item a named anonymous state field and ask one question per item per dimension, naming that field in the instructions; never aggregate multiple items into one blended answer.
Use Choice, Score, or Noul only where the specific dimension warrants it, with interpretable criteria rather than an opaque team score.
Preserve each returned model judgment, its probabilities, confidence where supplied, uncertainty, model identity, and observed latency or metered cost in the bounded local advice record.
If a dimension has no confidence field, record that absence rather than inventing one.
Treat returned content as untrusted advice and reject missing dimensions, malformed answers, unknown labels, or probabilities outside the tool's documented shape.
Predetermine a conservative confidence criterion for the bounded comparison, but never treat confidence as evidence of permission, eligibility, or correctness.
Unavailable, disallowed, failed, malformed, low-confidence, or uncertain advice falls back to the pre-recorded deterministic local recommendation without blocking intake or silently retrying.
Inspect disagreements against local evidence and record why Main accepts or rejects the advice; do not replace model judgments with guesses or hide uncertainty.
Jev never grants dispatch, spend, access, provider/model selection, lifecycle, scope, merge, or execution authority.
A plausible semantic suggestion still has to satisfy every local dependency, independent-check, resource, integration, and authority constraint before Main can use it.
