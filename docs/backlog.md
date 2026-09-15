# Keiro backlog and next release

Audited and reconciled 2026-09-15. This index covers the 47 plans surfaced by the original unfinished-plan audit, including four redirect documents. It removes 14 stale entries from actionable work and narrows plan 47 to its remaining evidence. The other 33 retain real work, evidence gaps, or dependency decisions. This is a snapshot; each plan's current Progress and Mina tracking remain authoritative as implementation proceeds.

## Next release collection

Mina collection **Keiro next release — correctness** (collection ID **1**) contains the six recommended plans in the order below, with per-item notes. The release follows 0.16.0.0; its version and date are deliberately unassigned until scope and compatibility are settled. Tracking statuses reflect the audit, not a claim of implementation completion.

```bash
mina track collection show 1
mina track list --project keiro
mina track show 15
mina track note list --item 15
```

Tracked item IDs, in collection order: 15, 16, 17, 18, 19, 20. `mina track show <item-id>` displays status; `mina track note list --item <item-id>` displays its notes. Item statuses are manually maintained; update them when a dependency or acceptance gate changes.

| Plan | Release status | Remaining action |
| --- | --- | --- |
| [164](plans/164-make-producer-outbox-identity-deterministic-and-replay-safe.md) | In progress | Close producer identity full-suite and performance evidence; reconcile the active implementation before release. |
| [265](plans/265-make-aggregate-transition-family-diffs-idempotent-and-order-independent.md) | Planned | Make transition-family comparison deterministic and order independent. Implement before 266. |
| [266](plans/266-classify-guard-unions-by-replay-body-and-validate-replay-only-remedies.md) | Blocked by 265 | Classify same-body guard unions and validate replay-only remedies after the comparison foundation lands. |
| [117](plans/117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md) | Planned | Preserve DLQ redrive headers and make archive/purge visibility-safe; include failure-path tests. |
| [116](plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md) | Blocked on upstream ordering | Local FIFO failure/batch tests can start; release acceptance also needs the upstream deterministic grouped-read contract. |
| [118](plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md) | Planned | Ship retention semantics and constructor guardrails; make the index change conditional on measured benefit. |

The upstream ordering gate for 116 is `mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order`. The optional FIFO index work is coordinated with `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`. A negative index result is an acceptable outcome for that optional optimization; it does not excuse the retention safety/documentation work.

## Closed stale entries

Mina's `[-]` marker means closed without claiming delivery here. Disposition annotations distinguish superseded work, delivery elsewhere, declined actions, and scope exclusions. Historical instructions are retained with a current-scope notice. The DSL closures follow [MasterPlan 8](masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md)'s recorded acceptance and delivery commits; they do not certify every generator promised by the original drafts.

| Plan | Disposition | Basis / retained boundary |
| --- | --- | --- |
| [16](plans/16-adopt-codd-for-database-migrations.md) | Closed: superseded remainder | Native migration verification (122) replaces remaining Codd-era validation; legacy removal stays in 189. |
| [46](plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md) | Closed: superseded | Schema-qualified DDL (85, commit fcd97705) replaces the proposed search_path edits; ADR-9 governs current migration ownership. |
| [52](plans/52-shared-codd-migration-scaffold-library-design-capture.md) | Closed: superseded remainder | Native migration ownership/embedding (122–123) replaces the Keiro rationale for a standalone Codd scaffold library; the library proposal was not implemented. |
| [54](plans/54-validateeventstream-and-mkeventstream-validate-keiki-transducers-at-the-eventstream-boundary.md) | Closed: delivered core | Optional codec-tag enumeration is outside the completed validator scope. Reassess upstream capability before a separate extension. |
| [58](plans/58-build-the-keiro-dsl-service-dsl-toolchain.md) | Closed: redirect | MasterPlan 8 owns the DSL decomposition. |
| [61](plans/61-keiro-dsl-process-manager-and-durable-timer-nodes.md) | Closed: delivered scope | Full process conformance recorded in aa1e9987; behavior-bearing handle remains hand-written. |
| [62](plans/62-keiro-dsl-integration-nodes-inbox-outbox-kafka-and-contract.md) | Closed: delivered scope | Full integration conformance recorded in ed03e6ba; mapper and runner bodies remain hand-written. |
| [63](plans/63-keiro-dsl-pgmq-workqueue-and-dispatch-nodes.md) | Closed: delivered scope | Full dispatch conformance recorded in 2587b96a; raw SQL and fan-out remain application-owned. |
| [64](plans/64-keiro-dsl-workflow-and-operation-nodes.md) | Closed: delivered scope | Full workflow conformance recorded in 834efeb6; workflow body and broader wrapper generation were not delivered as originally proposed. |
| [129](plans/129-fix-null-parameter-semantics-across-pop-read-and-notify-statements.md) | Closed: upstream redirect | Authoritative NULL-semantics replacement is in the upstream project; closure here does not certify rollout. |
| [130](plans/130-make-insert-notifications-survive-crashes-and-document-the-channel-contract.md) | Closed: upstream redirect | Authoritative notification replacement is in the upstream project; closure here does not certify rollout. |
| [131](plans/131-validate-queue-names-and-classify-transient-errors-across-the-pgmq-layers.md) | Closed: upstream redirect | Authoritative queue validation/error replacement is in the upstream project; closure here does not certify rollout. |
| [135](plans/135-surface-librdkafka-fatal-errors-through-the-consumer-stack.md) | Closed: delivered scope | PR submission was deliberately declined; optional broker demonstration is outside scope. Recorded July 27 test evidence remains the basis. |
| [137](plans/137-guarantee-deterministic-consumer-close-in-hw-kafka-streamly.md) | Closed: delivered scope | Deterministic close and regression proof recorded July 27; optional broker demonstration is outside scope. |

The three upstream replacements are:

- `mori://shinzui/pgmq-hs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements`
- `mori://shinzui/pgmq-hs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract`
- `mori://shinzui/pgmq-hs/plans/15-validate-queue-names-and-classify-transient-errors-across-the-pgmq-layers`

## Retained implementation and evidence closeout

| Plan | Disposition | Next action |
| --- | --- | --- |
| [9](plans/9-integrate-keiki-codec-json-into-keiro-snapshot-path.md) | Open: validation/docs | Codec integration exists; refresh the old build blocker, verify snapshot parity, finish usage guidance, and record codec performance. |
| [47](plans/47-key-workflow-step-index-and-discovery-on-workflow-id-and-name.md) | Open: regression/docs | Implementation absorbed by 48. Retain dedicated shared-ID/different-name parent-child regression proof and guidance/full-suite closeout; account for current generation-aware keys. |
| [25](plans/25-opentelemetry-semantic-conventions-audit-and-instrumentation-alignment.md) | Open: instrumentation | Complete W3C propagator wiring, a trace walkthrough, and reconciliation of the original instrumentation audit. |
| [179](plans/179-generate-one-human-readable-authoritative-keiro-transducer.md) | Open: historical release evidence | Reconcile the old 0.9.0.0 publication checkbox with actual release records; do not publish that historical version again. |
| [189](plans/189-remove-the-legacy-codd-runner-while-retaining-history-import-compatibility.md) | Open: migration cleanup | Move the two legacy migration drills into the default suite before removing legacy-codd-tools and its code/history duplicates. |
| [199](plans/199-close-the-final-review-findings-and-cut-keiro-dsl-0-11-0-0.md) | Open: release documentation | Record the downstream upgrade sequence requested by its final checklist item. |
| [232](plans/232-add-typed-domain-outcomes-to-the-dsl.md) | Open: performance evidence | Finish the remaining scaling/performance evidence; generated implementation alone does not close its acceptance gate. |
| [253](plans/253-apply-the-deferred-consolidation-cleanups-from-the-fix-verification-review.md) | Open: performance evidence | Obtain an uninterrupted passing command benchmark guard on a quiet host; then close the parent registry entry. |

The upgrade note in 199 concerns `mori://shinzui/mori`; its plan retains the specific consumer upgrade steps. Completed code and old release versions are not sufficient evidence to check off unresolved validation or publication records.

## Coordination and confidence backlog

| Plan | Disposition | Next action |
| --- | --- | --- |
| [119](plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter.md) | Refresh upstream ownership | Seek-barrier/serial execution correctness: verify the authoritative implementation and rollout before scheduling duplicate work. |
| [120](plans/120-add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge.md) | Refresh upstream ownership | Acknowledged batch publishing and the Keiro bridge: reconcile upstream API delivery separately from Keiro contract tests. |
| [121](plans/121-enforce-consumer-offset-store-configuration-and-correct-the-kafka-transport-docs.md) | Refresh upstream ownership | Offset-store configuration witness and transport docs: reconcile with 119/120 and current release evidence. |
| [134](plans/134-harden-ephemeral-pg-startup-port-allocation-and-orphan-cleanup.md) | Refresh upstream ownership | Fixture readiness, port allocation, and orphan cleanup: verify current upstream delivery before dependency changes. |
| [132](plans/132-add-real-crash-window-tests-on-a-durability-enabled-fixture.md) | Deferred: test infrastructure | Durable fixtures and real backend-kill tests remain useful confidence work; first refresh fixture restart/recovery prerequisites. |
| [133](plans/133-test-under-production-locale-and-a-non-superuser-role.md) | Deferred: production parity | ICU locale and non-superuser positive/negative grant tests remain real work. |
| [207](plans/207-add-the-messaging-and-read-side-command-domains-to-keiro-ops.md) | Blocked: upstream primitive | Checkpoint/lag operations remain blocked on the durable checkpoint inventory contract. |

The remaining gate in 207 is `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2`. Cross-repository implementation checklists above remain open until current owner/release evidence is reconciled; these are not duplicate-work authorizations.

## Deferred feature and evaluation backlog

| Plan | Disposition | Next action |
| --- | --- | --- |
| [7](plans/7-internal-decider-style-ergonomic-facade-over-runcommand.md) | Deferred: evaluation | Measure ergonomic value of a Decider facade before adding public API. |
| [83](plans/83-delegated-idempotence-inbox-intake-bypass-the-keiro-inbox-table-when-the-downstream-state-machine-already-dedupes.md) | Deferred: feature | Delegated inbox idempotence changes runtime and DSL contracts; retain its existing tracking rather than adding it to this release. |
| [163](plans/163-productize-event-history-migration-bootstrap-backup-restore-and-checkpoint-tooling.md) | Deferred: large initiative | History backup/restore/bootstrap adds a package and upstream primitives; scope as a separate release initiative. |
| [166](plans/166-evaluate-bounded-aggregate-collection-membership-and-quantification.md) | Deferred: experiment | Complete the bounded-collection GO/NO-GO evaluation before any production language feature; refresh the historical version gate. |
| [267](plans/267-add-safe-mapped-register-construction-to-declared-transitions.md) | Deferred: language feature | Mapped-register construction needs a coordinated candidate Language 6 charter with 273. |
| [271](plans/271-apply-async-projections-and-advance-checkpoints-atomically.md) | Deferred: evaluation | Require a concrete consumer and acceptance budgets before atomic projection/fencing prototypes. |
| [273](plans/273-make-process-manager-reactions-first-class-in-keiro-dsl.md) | Next feature candidate | Reaction DSL is a coherent follow-up to delivered runtime plan 279; coordinate Language 6 ownership with 267. |
| [274](plans/274-expose-process-manager-inspection-reads.md) | Deferred: operational feature | Resolve its reserved migration 0033 collision with 275 and pending-timer API overlap with 277. |
| [275](plans/275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md) | Alternative next feature | Operational inventory is the prerequisite for the 276 UI; resolve migration numbering with 274 first. |
| [276](plans/276-serve-the-keiro-ops-surface-over-http.md) | Depends on 275 | Build the operations UI after its inventory/query contracts are delivered. |
| [277](plans/277-publish-websocket-live-feeds-over-keiro-wake.md) | Deferred: operational feature | Coordinate pending-timer API ownership with 274 before implementation. |
| [278](plans/278-expose-aggregate-inspection-read-apis.md) | Blocked: dependency release | Requires the planned kiroku-store 0.9 capability; audit baseline was released 0.8.0.0. Reverify the registry and upstream tags before changing bounds. |

For the following feature release, prefer 273 if authoring capability is the goal, or 275 then 276 if operational visibility is the goal. Both choices need their listed contract conflicts resolved before coding. Neither is added to the correctness collection.

## Verification boundary

The cleanup changes plan metadata and dispositions, preserving real pending acceptance work. Delivery commits and current source/fixture presence support historical completion claims; their old test transcripts are not fresh test runs. Verification passed: Mina parsed all 15 changed plans, every void item carried a disposition, the 14 closed entries had no pending items, and plan 47 retained exactly two. The six collection members, their order, statuses, and one note each were verified. `git diff --check` passed. Runtime tests and release publication remain acceptance work of the selected implementation plans.
