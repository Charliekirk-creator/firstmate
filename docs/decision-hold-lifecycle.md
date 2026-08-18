# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
Positional keys are the explicit current unresolved inventory and always require active holds, independent of status text; `--none` explicitly records an empty current inventory, and repeated `--resolved <key>` arguments carry older keys that must have exact durable resolution proof when no live metadata remains.
It verifies every listed identity against tasks-axi before recording completion.
When normal configured retention has moved an older Done identity out of `data/backlog.md`, it reads that identity's exact record from the `[markdown].archive` path used by tasks-axi without restoring it.
The configured archive and backlog must resolve under the active `FM_HOME` through ordinary physical paths; a foreign data override or symlinked data parent cannot supply history.
A configured archive may have not-yet-created nested parents, which are normalized under the physical home and accepted only while every existing ancestor is an ordinary directory; tasks-axi remains responsible for creating them during normal pruning.
Only one ordinary, single-linked archived record inside a canonical `## Archived YYYY-MM-DD` retention section whose canonical trailing fields parse as kind captain with captain-hold provenance satisfies the historical header check; rows under notes or other prose sections are not history, and parsing stops at the canonical metadata boundary, so title text is never provenance.
Its resolution block must bind the exact origin and decision key, contain no more than the decision-file limit of 8192 captain-answer bytes, recompute to the recorded captain-answer digest, enforce resolution-mode routing, and list the same routed identities in both structured routing fields.
Released-version records without embedded origin and key remain compatible directly when the composed hold id has exactly one valid origin/key decomposition, through an existing exact record attestation, or through the explicit `migrate-legacy` path while exact reviewed metadata survives.
An ambiguous legacy record without that durable attestation fails closed because mutable owner inventories cannot prove which colliding origin and key created it; migration requires the exact recorded captain decision and refuses a competing reviewed decomposition.
Successful unambiguous verification or explicit migration atomically persists an attestation matching the hold id, origin, key, and complete resolution-record digest under a bounded digest filename in the authoritative data directory before teardown, and the same path covers a queued legacy resolution left by an interrupted close so an exact retry remains deterministic.
A publication interrupted after its no-clobber link is recoverable only when the record names that exact generated staging link; the recovered record is then canonicalized so a later unrelated hardlink remains invalid. Only the legacy routed format may omit `Resolution mode:`.
Absence, duplicate or ambiguous identity, unsafe archive files, non-absence backlog read errors, malformed or mismatched resolution records, and malformed or mismatched active provenance remain hard failures.
For any keyed status decision it will transfer, including one followed by a terminal status line, it requires the matching active backlog hold before appending a `captain-held [key=<key>]: ...` event; archived history cannot own a new transfer.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's `verify` subcommand after checking for the report and before removing any source state.
Verification never changes the backlog or archive; it may atomically persist an exact attestation for a uniquely decomposable legacy record, while an unattested ambiguous legacy record remains unverified.
`migrate-legacy <origin-id> <decision-key> --decision-file <path>` is the explicit compatibility path for that ambiguous case: it requires the surviving canonical reviewed inventory, validates retained or normally archived captain-hold provenance and the complete legacy resolution, matches the supplied decision digest, rejects a competing reviewed owner, and writes only the home-local attestation.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve`, `answer`, and `decline` subcommands close active holds, while `repair` attests a hold already closed outside the script.
All four require a non-empty captain decision file and record the same resolution block in the hold body with the origin, decision key, decision digest, routed identities, and a `Resolution mode:` naming the path.
An exact retry is idempotent, while a changed decision or, for `resolve`, a changed routed-task set is rejected; a queued record carrying repair's Done-only mode is malformed and cannot satisfy completion or verification.

The `resolve` subcommand is the routed path and additionally requires at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It clears each dependency edge through tasks-axi and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, and a failed intermediate step leaves the hold open.

The `answer` and `decline` subcommands share one unrouted close implementation and differ only in the `Resolution mode:` they record and the outcome word they print, so neither can drift into a weaker close than the other.
Both record `(none)` as the routed identities and refuse while any task in the same backlog is still blocked by the hold, because releasing routed work without recording it is `resolve`'s job.
Every candidate found in the listing prefilter is confirmed against its own structured record before the refusal is reported.
`answer` exists so the act carrying a captain answer can also be the act that closes its hold; `decline` continues to mean the stronger claim that the answer routes no follow-up work at all.

The `repair` subcommand records the resolution block on a hold that was already closed outside the script, such as by a direct `tasks-axi done`, so an origin whose decision was genuinely answered stops failing `verify`.
It refuses a hold that is still actively held, never reopens a closed hold, and never clears a dependency edge, so an unanswered decision keeps blocking teardown until the captain's word closes it.
It also requires the identity to carry the captain-hold provenance that tasks-axi preserves through a close and requires the surviving body to match the requested origin and key before any update, so neither an ordinary captain-kind task nor a colliding composed id can be repaired into another decision.

## Answer-time closure

The live status-log decision ledger has always had answer-time closure through `bin/fm-send.sh --resolve-key`: answering a keyed decision closes it in the same act.
The durable hold ledger did not, so an answer could be captured, believed, and even implemented while its hold stayed open, and the captain could then be asked to re-answer a decision already on disk.

"A keyed answer closes its matching hold" is now one capability with one owner.
`answers` is its channel-agnostic entry point: it reads `<decision-key>`, answer, and label lines on stdin, maps each key to `<origin-id>-decision-<key>`, and closes it through the same `answer` path, so every guard applies identically no matter which channel the answer arrived on.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch and no knowledge of chat, review decks, or any transport.
A channel's only job is to turn whatever it received into those keyed lines and pipe them in; it never maps keys to holds, builds decision records, chooses between the close paths, or closes a hold itself.
The decision text is a pure function of source, key, answer, and label, which is what makes a replayed delivery an idempotent no-op rather than a rejected different decision.
A key whose hold is absent, already closed, or still blocking routed work is reported as skipped and left for `resolve`, and the command exits nonzero when any key was skipped.

`bind`, `unbind`, and `binding` record which origin a captured-answer source belongs to, for a channel whose answers arrive detached from the origin.
The binding is a private record under `state/decision-bindings/`, and a source with no binding feeds nothing, so the path is opt-in per source.
`bind` deliberately does not require the source to exist yet, so a channel can be bound before it is armed and never produce an answer that has nowhere to go.

Two channels feed that one intake today, and both are ordinary callers rather than special cases.

`bin/fm-send.sh --resolve-key` is the chat channel.
Its existing status-log close is unchanged for a key the status log still owns.
For a key the status log no longer owns it checks whether that key names an active captain hold on the target task, and feeds the answer as one keyed line if so, which is what lets chat answer a decision already transferred to its hold.
A key open in neither ledger is still refused before anything is sent.
Because `complete` closes the live status copy at the moment it transfers a decision to its hold, the two ledgers are the two sides of one transfer and never both own a key at once, so the common path still performs no backlog read.

`bin/fm-procevent.sh` is the captured-result channel, and its wiring is generic.
After capture, a bound source has its result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>` and whatever that prints is piped into the intake, so any adapter with an `answers` command works and the runner names no adapter, parses no result, and carries no decision rule.
Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, so recording the captain's answer cannot retire the notification firstmate needs in order to act on it.
`bin/fm-procevent-lavish.sh answers` is one such adapter command; it reports the structured choices a review captured and stops there, reading only rows tagged `choice` so freeform captain prose can never forge a decision key.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Unrouted close-path verification date: 2026-08-13.
Answer-time closure verification date: 2026-08-16.
Retained-history completion verification date: 2026-08-17.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

Three further regressions cover the close paths that route no work.
A declined decision closes with a recorded answer, satisfies `verify`, leaves Bearings' Captain's Call, and is refused while the hold still blocks routed work.
A hold closed by a direct `tasks-axi done` reproduces the shape that fails `verify` and blocks teardown, and `repair` with a captain decision file clears both.
An unanswered decision still blocks completion and teardown, and neither `decline` nor `repair` can close a hold that is still actively held or supply an answer with a missing or empty decision file.
`repair` also refuses a closed captain-kind task that was never held for the captain.

A retained-history regression resolves two synthetic decisions, proves retained released-version metadata first, moves both records into a non-default configured archive by completing newer ordinary work, and then completes and verifies a later decision repeatedly through the public executable.
The same explicit unresolved inventory is required to have an active hold even when no matching status event exists, so status text cannot select historical fallback.
After normal teardown removes origin metadata and its generated attestation is removed to reproduce a pre-upgrade home, repeated completion still recognizes the uniquely decomposable legacy record and a hold retry cannot recreate it.
It proves the bounded Done window and archive stay byte-identical across repeated completion and verification instead of oscillating through row restoration.
Companion failure cases reopen an archived key without an active owner, surface a backlog read error while matching history exists, remove an active decision record, mismatch an active record's origin and key, normally prune an out-of-band close with no resolution block, collide two origin/key pairs onto one concatenated id, refuse automatic or competing migration of that collision, spoof captain metadata in an ordinary captain-kind title, exceed the captain decision size bound, mismatch resolution modes, digests, and routed-work lists, and point archive or legacy state reads across home boundaries; none can masquerade as historical resolution.
A surviving exact reviewed owner can explicitly migrate an ambiguous released-version record with the matching captain decision, and repeated migration and verification are idempotent. A queued repair-only resolution is separately rejected, while a queued released-version resolution is verified through teardown and then retried after its ephemeral metadata is gone; another case proves overlong released task identities use bounded attestation filenames, authenticated interrupted publication recovers, and unrelated hardlinks remain untouched and rejected.
The public completion gate also accepts option-shaped decision keys and verifies active and resolved records while `jq` is unavailable, relying only on the universal toolchain.

Three answer-time closure regressions run against the published poll response shape, with synthetic `sample` identities.
A bound source whose origin exposes six holds captures one review carrying five structured choices plus one freeform message, and the runner feeds it through a fixture adapter that is not the review adapter at all, so what is proven is that any bound channel with an `answers` command gets closure rather than that one channel is wired specially.
Four holds whose answers route no work close, the one still blocking routed work is skipped and stays available to `resolve`, and the one whose key appears only inside the freeform prose never closes.
The capture is left unacknowledged throughout, so the wake firstmate needs in order to act on the answers is never retired.
A replayed delivery closes nothing new and is not rejected as a different decision, a source with no binding closes nothing at all, and the `answer` subcommand itself refuses an empty or missing decision file, an absent hold, and a drifted retry.
A separate regression drives the real `fm-send` over a stubbed transport to prove the chat channel reaches the same intake for a decision already transferred to its hold, which the status ledger alone can no longer close.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - a declined decision closes with a recorded answer and no routed work
ok - a decision closed outside the script is repairable and then clears teardown
ok - an unanswered decision still blocks completion and resists both unrouted close paths
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - pruned resolved history permits later decisions without retention oscillation
ok - queued legacy resolution identity survives teardown and retry
ok - legacy migration rejects missing, conflicting, and foreign ownership
ok - legacy compatibility stays bounded and explicitly migrates ambiguous ownership
ok - only canonical retention sections prove archived decisions
ok - queued holds reject the repair-only resolution mode
ok - retained resolutions enforce the captain decision size bound
ok - pruned-history fallback rejects missing, malformed, and mismatched decisions
ok - historical resolution proof is exact, structured, and home-bound
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a bound channel's captured answers close their captain holds at answer time
ok - a channel source with no decision binding closes nothing
ok - the answer path keeps every guard the unrouted close path already had
ok - the chat channel feeds the same keyed-answer intake a captured review does
ok - option-shaped keys and jq-free decision verification stay compatible

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - an authoritative captain hold surfaces end-to-end
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-send-resolve-key.test.sh
ok - fm-send --resolve-key: the answer send itself closes the open decision
ok - fm-send --resolve-key: a key that is not open refuses loudly before anything is sent
(13 assertions total; the status-log ledger's behavior is unchanged)

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
ok - the run abort and the leaked-process reap both complete before the destructive worktree return

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=68 local_links=251

$ git diff --check
(no output)
```
