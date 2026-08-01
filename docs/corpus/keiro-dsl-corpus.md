# keiro-dsl conformance corpus

Worked examples of the typed-spec toolchain: the curated `.keiro` fixtures below, every compiled
conformance component, and every mutation/gate script. Paths are relative to `keiro-dsl/` in the
keiro repository. Start with the valid fixture for a surface, then use its negative or diff
variants to see the exact guardrails. The test suite separately enforces that all ordinary
fixtures use the frozen version-1 contract unless they are explicitly listed as successor-language
or source-version cases below.

## Source-language contract fixtures

| Fixture | Role / primary coverage |
| --- | --- |
| `test/fixtures/language-v1.keiro` | valid declared v1 source |
| `test/fixtures/language-legacy.keiro` | compatible unversioned source with effective version 1 |
| `test/fixtures/language-future.keiro` | unsupported future version rejected before body parsing |
| `test/fixtures/language-malformed.keiro` | malformed non-decimal version token |
| `test/fixtures/language-zero.keiro` | invalid zero version |
| `test/fixtures/language-duplicate.keiro` | duplicate preamble refusal |
| `test/fixtures/language-misplaced.keiro` | preamble-after-context refusal |
| `test/fixtures/id-domain-migration-v3.keiro` | language-3 enforced generated ID with split current admission and historical replay |

Version 1 is frozen. Version 2 adds nominal bindings and authoritative scalar expressions while
retaining runtime semantics 1. Version 3 selects runtime semantics 2 and enforces prefix-bearing
TypeID-v7 admission without tightening historical generated-event replay. A later syntax feature
must add a successor registry entry and a fixture showing that the released v1 parser still rejects
the new syntax. General source/workspace upgrade automation remains deferred to
[IR-5](../improvement-requests/add-version-aware-keiro-dsl-upgrade-and-fleet-rewrite-tooling.md).

## Core fixture inventory

This curated inventory covers the primary feature, negative, and evolution surfaces. Every path
below resolves; the complete machine-checked fixture set contains 238 `.keiro` files as of
2026-08-01. Successor-language fixtures are named explicitly and remain separate from the frozen
version-1 corpus.

| Fixture | Role / primary coverage |
| --- | --- |
| `test/fixtures/aggregate-bad-refs.keiro` | negative aggregate register, command, and write references |
| `test/fixtures/behavior-complete.keiro` | version-2 complete finite behavior inventory: later/terminal cells, guarded siblings, no-op, generated command identity, and replay-only twin |
| `test/fixtures/behavior-complete-workspace/service.keiro-workspace` | the same behavior inventory split across attributable workspace members |
| `test/fixtures/contract-bump-fieldadd.keiro` | additive contract field with schema-version bump |
| `test/fixtures/contract-discriminator.keiro` | contract discriminator evolution |
| `test/fixtures/contract-eventadd.keiro` | additive contract event evolution |
| `test/fixtures/contract-eventdrop.keiro` | breaking contract event removal |
| `test/fixtures/contract-fieldadd.keiro` | contract field addition without a version bump |
| `test/fixtures/contract-fieldtype.keiro` | breaking contract field-type evolution |
| `test/fixtures/contract-topic.keiro` | breaking contract topic evolution |
| `test/fixtures/contract.keiro` | valid contract topics, events, fields, and codecs |
| `test/fixtures/dispatch-dedup-bad-field.keiro` | negative dispatch dedupe payload field reference |
| `test/fixtures/dispatch-dedup-ghost-queue.keiro` | negative dispatch dedupe queue reference |
| `test/fixtures/duplicate-names.keiro` | duplicate declarations and generated-name collision diagnostics |
| `test/fixtures/emit-badevent.keiro` | negative emit mapping to an undeclared contract event |
| `test/fixtures/emit-derive.keiro` | emit derivation evolution |
| `test/fixtures/emit-mapchange.keiro` | breaking emit status-map evolution |
| `test/fixtures/emit-noskip.keiro` | negative emit map without `_ => skip` |
| `test/fixtures/emit-ordering.keiro` | publisher ordering-policy evolution |
| `test/fixtures/emit-outboxfield.keiro` | publisher/outbox identity evolution |
| `test/fixtures/emit-topic-mismatch.keiro` | negative emit event/topic affinity |
| `test/fixtures/emit.keiro` | valid contract, emit, and publisher vertical |
| `test/fixtures/hospital-surge-badref.keiro` | negative process saga/target/fire reference |
| `test/fixtures/hospital-surge-clock.keiro` | negative sampled timer deadline |
| `test/fixtures/hospital-surge-dispatchid.keiro` | negative user-supplied runtime dispatch id |
| `test/fixtures/hospital-surge-inputtype.keiro` | process input-shape evolution |
| `test/fixtures/hospital-surge-procname.keiro` | process stable-name evolution |
| `test/fixtures/hospital-surge-timerid.keiro` | timer identity evolution |
| `test/fixtures/hospital-surge-window.keiro` | timer-window evolution |
| `test/fixtures/hospital-surge.keiro` | valid process, timer, saga category, and worker policies |
| `test/fixtures/incident-paging/incident-paging.keiro` | valid readmodel-backed router plus target aggregate |
| `test/fixtures/intake-decode.keiro` | inbox decode-posture evolution |
| `test/fixtures/intake-dedupekey.keiro` | inbox dedupe-identity evolution |
| `test/fixtures/intake-dedupepolicy.keiro` | inbox dedupe-policy evolution |
| `test/fixtures/intake-dup-retry.keiro` | negative duplicate-as-retry inversion |
| `test/fixtures/intake-dup-row.keiro` | negative duplicate disposition outcome |
| `test/fixtures/intake-incomplete.keiro` | negative incomplete inbox disposition table |
| `test/fixtures/intake-pf-retry.keiro` | negative previously-failed-as-retry inversion |
| `test/fixtures/intake-topic-mismatch.keiro` | negative intake event/topic affinity |
| `test/fixtures/intake.keiro` | valid contract and inbox intake vertical |
| `test/fixtures/operation-ghost-aggregate.keiro` | negative command operation aggregate reference |
| `test/fixtures/operation-signal-value.keiro` | negative signal/await value-type mismatch |
| `test/fixtures/order.keiro` | minimal register-free aggregate smoke fixture |
| `test/fixtures/process-bad-timer.keiro` | negative timer ceiling and dispatch field binding |
| `test/fixtures/process-ghost-refs.keiro` | negative process command, timer, and projection references |
| `test/fixtures/readmodel-consistency-conflict.keiro` | negative projection/readmodel consistency conflict |
| `test/fixtures/readmodel-dispatch-unresolved.keiro` | negative dispatch readmodel and column references |
| `test/fixtures/readmodel-inline-unreferenced.keiro` | negative unowned inline readmodel feed |
| `test/fixtures/readmodel-query-unresolved.keiro` | negative query readmodel and consistency references |
| `test/fixtures/readmodel-runtime.keiro` | valid standalone readmodel runtime scaffold |
| `test/fixtures/readmodel-scope-eventual.keiro` | negative scope on an eventual readmodel |
| `test/fixtures/readmodel-shape-drift.keiro` | negative captured shape and column-type validation |
| `test/fixtures/readmodel-strong-inline.keiro` | negative strong inline readmodel |
| `test/fixtures/readmodel-strong-standalone.keiro` | standalone strong-projection diagnostics |
| `test/fixtures/readmodel.keiro` | valid readmodels, projection, query, workqueue, and dispatch |
| `test/fixtures/reservation-bad-command.keiro` | negative aggregate command reference |
| `test/fixtures/reservation-clock.keiro` | negative wall-clock sampling in a transition |
| `test/fixtures/reservation-cmdfieldtype.keiro` | command-derived event field-type evolution |
| `test/fixtures/reservation-deprecated.keiro` | deprecated event still emitted on the write path |
| `test/fixtures/reservation-enumadd.keiro` | additive enum constructor evolution |
| `test/fixtures/reservation-enumdrop.keiro` | breaking enum constructor removal |
| `test/fixtures/reservation-enumwire.keiro` | breaking enum wire-spelling change |
| `test/fixtures/reservation-fieldadd.keiro` | event field added without a version bump |
| `test/fixtures/reservation-fieldremove.keiro` | event field removed at the same version |
| `test/fixtures/reservation-fieldtype.keiro` | breaking event field-type change |
| `test/fixtures/reservation-idprefix.keiro` | id-prefix evolution |
| `test/fixtures/reservation-no-statusmap.keiro` | negative missing total status map |
| `test/fixtures/reservation-projection.keiro` | projection evolution |
| `test/fixtures/reservation-snapshot.keiro` | valid snapshot policy and captured codec identity |
| `test/fixtures/reservation-v2-noupcast.keiro` | negative v2 event without an upcaster |
| `test/fixtures/reservation-v2.keiro` | valid v2 event and contiguous upcaster |
| `test/fixtures/reservation-v3-dangling.keiro` | negative dangling v1-to-v3 upcaster chain |
| `test/fixtures/reservation-wire.keiro` | wire-policy evolution |
| `test/fixtures/reservation-work-dedupkey.keiro` | dispatch dedupe-key evolution |
| `test/fixtures/reservation-work-df-retry.keiro` | negative decode-failure-as-retry inversion |
| `test/fixtures/reservation-work-divergent.keiro` | negative captured physical queue drift |
| `test/fixtures/reservation-work-fieldtype.keiro` | workqueue payload field-type evolution |
| `test/fixtures/reservation-work-fifo-nokey.keiro` | negative FIFO queue without a group key |
| `test/fixtures/reservation-work-key-unordered.keiro` | negative group key on an unordered queue |
| `test/fixtures/reservation-work-optfield.keiro` | optional workqueue payload field evolution |
| `test/fixtures/reservation-work-partitioned-empty.keiro` | negative empty partition fixture |
| `test/fixtures/reservation-work-rename.keiro` | queue identity evolution |
| `test/fixtures/reservation-work-reqfield.keiro` | required workqueue payload field evolution |
| `test/fixtures/reservation-work-retarget.keiro` | dispatch queue retargeting |
| `test/fixtures/reservation-work-sf-deadletter.keiro` | negative store-failure-as-dead-letter inversion |
| `test/fixtures/reservation-work-unlogged.keiro` | unlogged durability warning |
| `test/fixtures/reservation-work-wirename.keiro` | workqueue payload wire-name evolution |
| `test/fixtures/reservation-work.keiro` | valid readmodel, workqueue, ordering, and dispatch vertical |
| `test/fixtures/reservation.keiro` | canonical aggregate, guard, status-map, codec, and projection |
| `test/fixtures/rule-bad-domain.keiro` | negative unresolved rule domain |
| `test/fixtures/rule-not-total.keiro` | negative rule totality, constructor, clock, and atom checks |
| `test/fixtures/statusmap-dangling.keiro` | negative dangling status-map event names |
| `test/fixtures/statusmap-dup-key.keiro` | negative duplicate status-map key |
| `test/fixtures/subscription.keiro` | cold-start aggregate authored from the skill |
| `test/fixtures/surge-service.keiro` | full process-service scaffold source |
| `test/fixtures/transfer-routing.keiro` | fresh-agent aggregate + hospital-load readmodel + dead-lettering router cold-start |
| `test/fixtures/workflow-body.keiro` | workflow body evolution |
| `test/fixtures/workflow-can-mid.keiro` | negative non-terminal/nested `continueAsNew` |
| `test/fixtures/workflow-continue-seed-v2.keiro` | breaking continuation seed evolution |
| `test/fixtures/workflow-continue.keiro` | valid terminal `continueAsNew` |
| `test/fixtures/workflow-dup-label.keiro` | negative duplicate replay label |
| `test/fixtures/workflow-evolution-diff.keiro` | workflow patch/body diff target |
| `test/fixtures/workflow-evolution.keiro` | valid patch and continuation runtime declarations |
| `test/fixtures/workflow-idfield.keiro` | workflow id-source evolution |
| `test/fixtures/workflow-inputfield.keiro` | workflow input-shape evolution |
| `test/fixtures/workflow-output.keiro` | workflow output-shape evolution |
| `test/fixtures/workflow-patch-colon.keiro` | negative reserved colon in a patch id |
| `test/fixtures/workflow-patch-dup.keiro` | negative duplicate nested patch id |
| `test/fixtures/workflow-rename.keiro` | workflow stable-name evolution |
| `test/fixtures/workflow-signal-mismatch.keiro` | negative signal without a matching await |
| `test/fixtures/workflow-stepadd.keiro` | workflow journal-step addition |
| `test/fixtures/workflow-unresolved-fields.keiro` | negative workflow id and sleep input fields |
| `test/fixtures/workflow.keiro` | valid workflow, all operation shapes, readmodel, and aggregate |
| `test/fixtures/workqueue-dlq-divergent.keiro` | negative captured DLQ drift |
| `test/fixtures/workqueue-dup-row.keiro` | negative duplicate workqueue disposition outcome |
| `test/fixtures/workqueue-group-key-change.keiro` | breaking group-key evolution |
| `test/fixtures/workqueue-hashed-logical.keiro` | long logical queue name and hashed physical derivation |
| `test/fixtures/workqueue-incomplete.keiro` | negative incomplete workqueue disposition table |
| `test/fixtures/workqueue-ordering-change.keiro` | breaking ordering-policy evolution |
| `test/fixtures/workqueue-policy-base.keiro` | baseline ordering/provisioning diff fixture |
| `test/fixtures/workqueue-provision-change.keiro` | breaking provisioning evolution |
| `test/fixtures/workqueue-table-divergent.keiro` | negative captured backing-table drift |
| `test/fixtures/workqueue-uppercase-logical.keiro` | uppercase logical name normalization parity |

## Compiled conformance and harness components

The 32 current `keiro-dsl-conformance*` Cabal components are all indexed here.

| Component | Proves |
| --- | --- |
| `test/conformance/` (`keiro-dsl-conformance`) | canonical generated aggregate plus filled transducer, replay validation, codec round-trips, and behavior |
| `test/conformance-behavior-complete/` (`keiro-dsl-conformance-behavior-complete`) | all 14 static requirements have typed later-state, terminal-rejection, no-op, guarded-sibling, and replay-only witnesses with exact Keiki 0.7 attribution; 13 verify and one conservative guard surface remains unverified |
| `test/conformance-aggregate-scalars/` (`keiro-dsl-conformance-aggregate-scalars`) | generated direct scalar aggregate codecs, snapshots, and transition behavior compile and execute |
| `test/conformance-scalar-expressions/` (`keiro-dsl-conformance-aggregate-scalar-expressions`) | generated version-2 scalar terms agree across concrete, symbolic, replay, and snapshot surfaces |
| `test/conformance-nominal-scalars/` (`keiro-dsl-conformance-nominal-scalars`) | consumer nominal binding laws, ID/enum exact equality, wire rejection, snapshots, and forward/replay parity |
| `test/conformance-structural/` (`keiro-dsl-conformance-structural`) | structural binding laws, branch coverage, generated codec bytes, projection witnesses, and mapped-register replay |
| `test/conformance-codec-compare/` (`keiro-dsl-conformance-codec-compare`) | historical and generated structural codecs classify canonical JSON parity and migration differences |
| `test/conformance-replay/` (`keiro-dsl-conformance-replay`) | generated replay audit targets and seeded/full replay divergence gates compile and execute |
| `test/conformance-id-domain-migration/` (`keiro-dsl-conformance-id-domain-migration`) | identical malformed generated-ID text replays through the internal legacy event seam and fails current field-located admission |
| `test/conformance-workspace-nominals/` (`keiro-dsl-conformance-workspace-nominals`) | two workspace aggregate domains import one generated ID/enum authority, exchange those exact types, and round-trip both event codecs |
| `test/conformance-snapshot/` (`keiro-dsl-conformance-snapshot`) | snapshot policy/codec wiring against live stream-construction guards |
| `test/conformance-skeletons/` (`keiro-dsl-conformance-skeletons`) | every distinct `new <kind>` starter scaffolds to compiling Haskell |
| `test/conformance-coldstart/` (`keiro-dsl-conformance-coldstart`) | the original fresh-agent aggregate cold-start closes from skill to green harness |
| `test/conformance-contract/` (`keiro-dsl-conformance-contract`) | generated contract payload ADTs and codecs round-trip |
| `test/conformance-intake-runtime/` (`keiro-dsl-conformance-intake-runtime`) | generated inbox disposition/dedupe policy compiles against live inbox types |
| `test/conformance-intake-full/` (`keiro-dsl-conformance-intake-full`) | filled inbox transaction and outbox producer compile as a full integration service |
| `test/conformance-publisher-runtime/` (`keiro-dsl-conformance-publisher-runtime`) | generated publisher ordering/backoff compiles against live outbox types |
| `test/conformance-queue/` (`keiro-dsl-conformance-queue`) | generated workqueue payload codec round-trips |
| `test/conformance-queue-runtime/` (`keiro-dsl-conformance-queue-runtime`) | queue naming parity, ordering/provisioning, retry policy, and dispositions compile against live PGMQ |
| `test/conformance-readmodel-runtime/` (`keiro-dsl-conformance-readmodel-runtime`) | readmodel registration/rebuild/query holes use live APIs and a qualified table |
| `test/conformance-dispatch-full/` (`keiro-dsl-conformance-dispatch-full`) | generated queue policy plus a filled worker assemble into a live PGMQ job |
| `test/conformance-workflow/` (`keiro-dsl-conformance-workflow`) | generated workflow facts match hand-written, mutation-pinnable expectations |
| `test/conformance-workflow-runtime/` (`keiro-dsl-conformance-workflow-runtime`) | workflow name, awakeable ids, patches, and continuation declarations compile against live runtime |
| `test/conformance-process-full/` (`keiro-dsl-conformance-process-full`) | generated saga/target aggregates plus filled process manager compile against live runtime |
| `test/conformance-workflow-full/` (`keiro-dsl-conformance-workflow-full`) | filled ordered workflow body compiles against the live workflow effect |
| `test/conformance-process-runtime/` (`keiro-dsl-conformance-process-runtime`) | process timer, category, worker policy, and fire disposition compile against live APIs |
| `test/conformance-router-runtime/` (`keiro-dsl-conformance-router-runtime`) | router policy lowering and target-keyed deterministic id contract compile against live runtime |
| `test/conformance-router/` (`keiro-dsl-conformance-router`) | generated router facts match hand-written expectations |
| `test/conformance-router-full/` (`keiro-dsl-conformance-router-full`) | filled resolver/router value and target aggregate compile against live APIs |
| `test/conformance-newsurface/` (`keiro-dsl-conformance-newsurface`) | fresh-agent aggregate/readmodel/router artifact passes 12 scaffold and live-router assertions |
| `test/conformance-process/` (`keiro-dsl-conformance-process`) | generated process facts are firewall-clean and mutation-pinnable |
| `test/conformance-v2/` (`keiro-dsl-conformance-v2`) | generated v2 codec and filled upcaster migrate v1 payloads through the chain |

## Mutation and gate scripts

| Script | Shows |
| --- | --- |
| `test/behavior-complete-mutation-test.sh` | twelve missing, dishonest, wrong-command, misattributed, codec, register, and generated-output mutations fail exact behavior obligations while an obsolete output hook stays unable to affect execution |
| `test/mutation-test.sh` | flipping the filled aggregate guard reddens a specific behavior assertion |
| `test/diff-test.sh` | unsafe evolution is BREAKING while versioned/upcast evolution is ADDITIVE |
| `test/process-mutation-test.sh` | changing the timer rejection inversion reddens its process fact |
| `test/router-mutation-test.sh` | changing target-keyed router identity reddens its router fact |
| `test/workflow-mutation-test.sh` | changing ordered workflow notation reddens its workflow fact |
| `test/id-domain-migration-mutation-test.sh` | replacing the internal legacy replay seam with the current parser reddens the exact migration assertion and restores the generated codec |

## Reference fills

Generated trees under each `test/conformance*/Generated/` directory are raw scaffold output
and are pinned byte-for-byte where the suite supports regeneration. Hand-owned modules next
to those trees are the worked fills. The most useful starting points are:

- `test/conformance/HospitalCapacity/Reservation/Holes.hs` for a keiki transducer.
- `test/conformance-behavior-complete/BehaviorComplete/Journey/BehaviorHoles.hs` for a complete
  typed behavior-witness list spanning later states, terminal rejections, and replay-only history.
- `test/conformance-process-full/SurgeDemo/SurgeFlow/Manager.hs` for category-safe process
  streams and process-manager assembly.
- `test/conformance-router-full/IncidentPaging/PagingRouter/RouterValue.hs` for a stable
  resolver and target-keyed router.
- `test/conformance-readmodel-runtime/HospitalCapacity/Transfer_decisions/ReadModelHoles.hs`
  for schema-qualified readmodel SQL.
- `test/conformance-workflow-full/HospitalCapacity/HospitalTransferReservation/WorkflowBody.hs`
  for an ordered durable workflow body.
