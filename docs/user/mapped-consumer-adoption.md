# Adopting Mapped Consumer Surfaces

Published stable `keiro-dsl` Language 5 can carry one mapped declaration through every
supported private consumer surface: aggregate commands, private events and
registers; persisted workqueue payloads; read-model query input/result types;
and inline or catalog projections derived from an aggregate event source.

This is a published contract. Fleet rollout still requires both
[MasterPlan 34](../masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md)
and
[MasterPlan 35](../masterplans/35-make-mapped-types-first-class-across-queues-read-models-and-projections-before-fleet-adoption.md)
to be complete in the Keiro revision you intend to adopt. Passing those
repository gates authorizes adoption; it does not migrate a
service, drain a queue, rebuild a projection, or apply application DDL.

## What Is Covered

| Surface | Generated authority | Persisted or operational consequence |
| --- | --- | --- |
| Private event | Aggregate codec and harness | Old event payloads may require a version bump and upcaster. |
| Snapshot register | Aggregate transducer and structural conformance | Old snapshots may miss their discriminator and full-replay. |
| Workqueue field | `Queue`, `QueueCodec`, and `QueuePolicy` | Queued jobs retain schema-version-1 envelope semantics and may require a drain or transitional codec. |
| Query input/result | Read-model `QueryContract` aliases | Callers and the read-model implementation must recompile; SQL shape is not changed. |
| Aggregate projection | Inline/catalog handler relation and aggregate-source fingerprint | Every affected handler needs review; replayable catalog owners may require a group rebuild. |
| Declaration inventory | Service `StructuralConformance`, semantic-impact report, and ledger | Unused declarations still retain one service-level law and history row. |

Structural mappings generate exact JSON fields and total binding checks. Opaque
mappings retain the application type's `ToJSON`/`FromJSON` authority and finite
fixture evidence. A nested declaration inherits every checked consumer path
that reaches it.

Category and all-history projection sources remain heterogeneous decoder
boundaries. Public integration contracts and arbitrary SQL are not inferred as
private mapped consumers. Coverage reports keep those limits visible instead of
claiming structural proof.

## Establish The Adoption Baseline

Adopt one service at a time:

1. Pin a Keiro revision where both prerequisite master plans are complete. Keep
   existing language-4 services on `--min-language 4` until they intentionally
   opt in.
2. Change the service or every workspace member to `language keiro-dsl 5`, then
   declare the complete queue/query/catalog authority the service actually
   owns. A preamble-only edit is not an adoption.
3. Run `check` with binding and coverage evidence. Resolve every opaque or
   unsupported boundary deliberately.
4. Scaffold once. Reconcile the generated Cabal fragment, fill new create-once
   bindings and holes, and review the Language-5 generated tree. Do not edit
   generated files to make the corpus check pass.
5. Compile and run the generated service conformance target. Persist the new
   semantic-impact ledger as the baseline; a legacy ledger correctly reports
   prior consumer evidence as unavailable.
6. Run `diff` against the deployed revision and assign each reported consequence
   to an owner before rollout.

The Keiro repository qualifies the same sequence with:

```bash
bash keiro-dsl/test/mapped-surface-locality-test.sh
bash keiro-dsl/test/mapped-surface-mutation-test.sh
cabal run -v0 keiro-dsl-corpus-regen -- check
```

The locality gate proves that adding an unrelated workspace member, aggregate,
queue, read model, or projection does not amplify an existing mapped edit's
changed-file set. The mutation gate deliberately corrupts every authority and
requires the named conformance boundary to turn red before restoring exact
bytes.

## Act On A Mapped Change

Treat semantic-impact consequences independently:

- `private-event-history`: bump the event schema and add/test a contiguous
  upcaster when old event JSON is incompatible. Run the real-log replay audit.
- `snapshot-hydration`: expect old snapshots to miss and full-replay; budget the
  load and use an explicit fold token for semantic changes that preserve shape.
- `workqueue-history`: deploy a backward-reading worker before a new producer.
  If no compatible decoder exists, stop producers and drain the old queue; a
  temporary dual-shape codec is the alternative. Never bless incompatibility by
  updating only a generated golden.
- `query-api`: recompile every caller and the hand-owned query body. Query aliases
  do not alter table columns, row codecs, shape hashes, or migrations.
- `projection-handler-review`: review each named inline/live/replay handler. A
  mapped event edit changes the aggregate-source fingerprint, not application
  SQL by inference.
- `projection-rebuild`: finish or abandon an incompatible active run, deploy the
  matching catalog and replay holes, and rebuild the named group under its
  runtime fence.
- `consumer-build`: rebuild the exact named consumer even when no persisted
  history consequence applies.

Application teams continue to own queue-drain timing, query caller rollout,
projection verification, read-model DDL and SQL migrations, and release
coordination. See [Evolution And Replayability](../guides/evolution-and-replayability.md),
[Work Queues](work-queues.md), and
[Read Models And Projections](read-models-and-projections.md) for the operational
procedures.
