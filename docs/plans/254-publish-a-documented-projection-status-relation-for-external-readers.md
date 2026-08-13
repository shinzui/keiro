---
id: 254
slug: publish-a-documented-projection-status-relation-for-external-readers
title: "Publish a versioned serving and rebuild status relation"
kind: exec-plan
created_at: 2026-08-12T23:55:46Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
master_plan: "docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md"
---

# Publish a versioned serving and rebuild status relation

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current. Update `docs/adr/` in the same
change when durable architectural context changes.


## Purpose / Big Picture

After this change, any PostgreSQL client can query the documented relation
`keiro_read.projection_group_status_v1` and distinguish three independent facts:

- whether the current serving projection may be read and written;
- which revision and generation epoch are serving, and how far that serving data has
  durably progressed;
- whether a candidate rebuild is active, and how far that separate candidate has
  progressed toward its head.

This distinction is essential for online schema changes. During a v2 rebuild, v1 remains
live and continues advancing while the candidate replay starts from history. Reporting
the candidate cursor as the serving position would make a healthy projection appear to
regress. Reporting `rebuilding-versioned` as unavailable would contradict the promise
that readers continue to use v1.

The relation is a frozen versioned contract. Future compatible implementation changes
may replace its view body, but its v1 columns, types, order, null semantics, and value
meanings do not change. An incompatible extension creates a new relation such as
`projection_group_status_v2`; v1 is not evolved by an open-ended “additive only” rule.

This is EP-2 of
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md`.
It hard-depends on plan 256's generation metadata. Its former external dependency is
now satisfied: `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-5` shipped
the stable `kiroku.subscription_checkpoints_v1` relation in
`kiroku-store-migrations` 0.3.1.0. This plan must not read `kiroku.subscriptions` or any
other private Kiroku table directly.


## Progress

- [x] (2026-08-13T22:35:58Z) M1: verified the frozen
  `kiroku.subscription_checkpoints_v1` relation and upstream contract tests through
  Mori, released `kiroku-store-migrations` 0.3.1.0, its Hackage metadata, and its
  annotated upstream tag.
- [ ] M2: private cursor bindings and public
  `keiro_read.projection_group_status_v1` migration, comments, grants guidance,
  expected-schema view coverage, and SQL semantics tests are complete.
- [ ] M3: registration/adoption reconciliation, typed Haskell accessor, and offline plus
  schema-versioned lifecycle tests pass against a real database.
- [ ] M4: user documentation, ADR creation/amendments, changelogs, out-of-process
  transcript, full verification, and MasterPlan status updates are complete.


## Surprises & Discoveries

- The original plan made any active replay replace `applied_position` with the replay
  cursor. That is valid only for an unavailable in-place target; it is false for an
  online candidate beside a serving generation.
- The original acceptance expected a post-promotion checkpoint regression. Completed
  plan 258 now backfills deduplication and advances subscription checkpoints atomically
  with promotion, so position regression is neither expected nor a reliable cache
  invalidation signal.
- A persisted Keiro view over `kiroku.subscriptions` would make Kiroku's private table
  shape part of Keiro's migration graph. PostgreSQL dependency failures would turn an
  upstream internal migration into a cross-repository outage. The owning library must
  publish the SQL relation first.
- An unversioned relation with “columns may be added” still breaks positional decoders
  and clients using `SELECT *`. A named v1 relation is a clearer compatibility promise.
- Kiroku's released relation is structurally read-only and owner-rights evaluated. Its
  four values are semantically non-null even though PostgreSQL reports ordinary-view
  columns as nullable in generic catalog introspection. Keiro must preserve those source
  semantics without claiming catalog-level `NOT NULL` metadata for the upstream view.


## Decision Log

- Decision: Publish `keiro_read.projection_group_status_v1`, not a relation in the
  private `keiro` schema.
  Rationale: external readers receive `USAGE` only on a dedicated public-contract
  schema and need no visibility into private lifecycle objects.
  Date: 2026-08-13
- Decision: Freeze the complete v1 row contract. Incompatible evolution creates v2.
  Rationale: additive columns and values are not universally source-compatible for SQL
  clients and generated decoders.
  Date: 2026-08-13
- Decision: Persist and expose lifecycle, read availability, and write availability as
  orthogonal facts.
  Rationale: versioned rebuild is an active lifecycle while the old generation remains
  available; future lifecycle values should not require regenerating every guard.
  Date: 2026-08-13
- Decision: Serving and candidate positions use separate columns and bases.
  Rationale: a replay cursor describes staging completeness, not the data currently
  served to readers.
  Date: 2026-08-13
- Decision: Serving-generation epoch, not position regression, identifies a promoted
  replacement.
  Rationale: serving checkpoints should remain monotonic through a correct promotion,
  while caches still need an unambiguous generation-change signal.
  Date: 2026-08-13
- Decision: Do not create the view until `mori://shinzui/kiroku` publishes a supported
  SQL checkpoint relation.
  Rationale: Keiro may consume a dependency-owned public contract but may not freeze a
  private dependency table into its own public view.
  Date: 2026-08-13
- Decision: The relation remains a view over transactional authorities rather than a
  separately maintained status table.
  Rationale: generation lifecycle, cursor bindings, and owner-published checkpoints are
  already updated transactionally; duplicating their values creates drift risk.
  Date: 2026-08-13
- Decision: Missing cursor authority or an incomplete member set produces an unknown
  serving position, never the minimum of whichever rows happen to exist.
  Rationale: partial checkpoint inventory overstates durable progress.
  Date: 2026-08-13
- Decision: Consume `kiroku.subscription_checkpoints_v1` from
  `kiroku-store-migrations` 0.3.1.0 or later, while the coordinated MasterPlan adoption
  raises the minimum migration package to 0.3.2.0 for IR-6.
  Rationale: 0.3.1.0 is the first owner-published checkpoint contract; 0.3.2.0 preserves
  it unchanged and adds the separately required replay-retention migration. Both
  authoritative Hackage metadata and upstream tags identify the shipped contracts.
  Date: 2026-08-13


## Outcomes & Retrospective

Architecture review corrected the public vocabulary before it became a stable contract.
The external SQL prerequisite is complete. Keiro implementation remains Not Started and
begins after plan 256 supplies the generation metadata.


## Context and Orientation

Plan 256 adds durable target generations and projection revisions to the private Keiro
schema. Each rebuild group has a lifecycle phase, explicit read/write availability, a
serving revision, and an increasing serving epoch. An online run additionally has a
candidate revision and candidate generations. An offline run may temporarily have no
readable serving generation.

The replay runner persists an inclusive captured head and per-source cursor positions in
the run/source tables. The candidate applied floor is the minimum cursor across required
sources only after source membership is complete. The serving applied floor is derived
from delivery mode:

- Inline-only projections commit with the source append. They have basis `append` and
  no independent numeric cursor; a reader transaction that sees an event also sees its
  projection effect.
- Subscription-fed groups have basis `checkpoint`. Their serving floor is the minimum
  durable member checkpoint over every bound subscription, using the supported Kiroku
  SQL relation.
- A legacy group without catalog cursor authority has basis `unmanaged` and no promised
  numeric position.
- An unavailable in-place rebuild has no serving applied position. Its replay progress
  appears only in the candidate/rebuild columns.

`keiro.keiro_projection_group_cursors` remains derived private registration metadata
mapping a group to its Kiroku subscription names. Registration and reviewed catalog
adoption reconcile it transactionally. It is not fingerprint identity because the
canonical group slice already contains resolved cursor authority.

The status relation is read-only and owner-privileged. Deployment roles receive:

```sql
GRANT USAGE ON SCHEMA keiro_read TO projection_reader;
GRANT SELECT ON keiro_read.projection_group_status_v1 TO projection_reader;
```

No grant on the private `keiro` or `kiroku` schemas is part of the contract.

Kiroku's released source defines the upstream view in migration `0009` with these frozen
columns, in order: `subscription_name text`, `consumer_group_member integer`,
`checkpoint_position bigint`, and `checkpoint_updated_at timestamptz`. The relation has
one row per persisted exact checkpoint and no row-order promise. Readers need schema
`USAGE` and relation `SELECT`; Kiroku creates no application role or grant. The owning
implementation record is
`mori://shinzui/kiroku/plans/72-publish-a-stable-sql-subscription-checkpoint-relation`,
and the durable compatibility decision is
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-6`.

Relevant local decisions are ADR-9, ADR-26, ADR-31, ADR-32, ADR-33, and ADR-34. The
cross-repository checkpoint lifecycle semantics are owned by
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-4`, while the versioned public-SQL contract
is owned by `mori://shinzui/kiroku/okf/adrs/concepts/ADR-6`. Mori does not yet expose a
canonical artifact-level URI for the SQL relation itself; use the canonical Kiroku
project URI plus `kiroku-store-migrations/migrations/0009.sql` until that URI shape is
defined.


### Frozen v1 columns

The migration creates the columns below in this exact order. The implementation may
refine Haskell field names but not the SQL contract after documentation ships.

```text
group_id                         text        not null
lifecycle_phase                 text        not null
reads_allowed                   boolean     not null
writes_allowed                  boolean     not null
serving_revision_id             text        null
serving_epoch                   bigint      not null
serving_position_basis          text        not null
serving_applied_position        bigint      null
active_run_id                   text        null
candidate_revision_id           text        null
candidate_rebuild_position      bigint      null
candidate_rebuild_head          bigint      null
query_models                    text[]      not null
rebuild_started_at              timestamptz null
last_promoted_at                timestamptz null
failed_at                       timestamptz null
failure_code                    text        null
failure_detail                  text        null
```

`reads_allowed` is the sanctioned availability fact. Consumers do not interpret
`lifecycle_phase` to decide whether reading is safe. `writes_allowed` explains service
behavior but does not authorize external writes. `serving_revision_id` is null only for
legacy unmanaged or unrecoverable metadata. `serving_epoch` starts at zero or one per
the plan-256 migration and increases on every promotion; it never decreases.

`serving_position_basis` is exactly `append`, `checkpoint`, or `unmanaged` in v1.
Unknown future bases require v2 rather than silently extending this decoder contract.
Candidate progress is populated only for an active replay with a complete persisted
source set. It may start below serving progress without implying serving regression.

The view has one row per rebuild group. `query_models` is sorted and contains the
currently registered logical query names. External contracts that need per-binding
schema compatibility use plan 255's registry; the group-status row does not overload
query-model version into target-generation identity.


## Plan of Work

### Milestone 1 — Establish the upstream SQL checkpoint dependency

This milestone is complete. `mori registry show shinzui/kiroku --full` located the
owning source; `kiroku-store-migrations` 0.3.1.0 publishes the supported, read-only
`kiroku.subscription_checkpoints_v1` relation requested by
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-5`. Hackage and the annotated
upstream tag agree on the release, and Kiroku's plan 72 records catalog, privilege,
dependency-replacement, index-plan, and clean-consumer evidence.

Implementation must retain the exact name and four-column contract recorded above and
must treat its values as semantically non-null. Never substitute
`kiroku.subscriptions`, even in tests.

### Milestone 2 — Ship the private binding and public v1 relation

After plan 256 and M1 are complete, add the next free Keiro native migration. It creates
`keiro_read` if absent, creates the private cursor-binding table if plan 256 did not,
and creates `keiro_read.projection_group_status_v1` with the frozen columns above.
Every public column receives a `COMMENT` describing its meaning and null cases. The view
joins only Keiro-owned private objects and the stable Kiroku public relation.

Extend `Keiro.Migrations.SchemaCheck` so expected-schema verification covers views and
their ordered column names/types without exposing view definitions as a compatibility
contract. Update lint, expected schema, migration fixture counts, manifest, native lock,
and changelog.

Migration tests must cover:

- inline, subscription, mixed-delivery, and unmanaged groups;
- missing subscription/member rows producing unknown serving position;
- an offline rebuild with reads false and candidate progress separate;
- a versioned rebuild with reads true, serving checkpoint advancing independently, and
  candidate progress starting behind it;
- atomic promotion changing serving revision/epoch while clearing candidate fields;
- failed versioned and failed offline runs with truthful availability;
- privilege behavior proving a role can read the view without underlying table grants.

### Milestone 3 — Reconcile bindings and expose typed accessors

Update registration and adoption in
`keiro/src/Keiro/ReadModel/Rebuild/Group.hs` to reconcile group cursor bindings in their
existing transactions. Add a hidden
`keiro/src/Keiro/ReadModel/Rebuild/Status.hs` module and re-export its public types and
functions through `Keiro.ReadModel.Rebuild`.

The typed shape mirrors every v1 column and decodes the closed v1 basis vocabulary.
Lifecycle remains inspectable text or a forward-compatible internal status type, but
callers use `readsAllowed` rather than hard-coding lifecycle values.

```haskell
listProjectionGroupStatuses ::
  (Store :> es) => Eff es [ProjectionGroupStatusV1]

lookupProjectionGroupStatus ::
  (Store :> es) => RebuildGroupId -> Eff es (Maybe ProjectionGroupStatusV1)
```

Add a real-database lifecycle test that runs offline repair and schema-versioned rebuild.
After offline promotion the checkpoint should reflect plan 258's atomic advance, not
regress to the replay origin. During the versioned run, serving position continues to
track the live generation while candidate progress climbs independently. Promotion
changes the epoch exactly once.

### Milestone 4 — Document and verify the external contract

Add a complete column table and recipes to
`docs/user/read-models-and-projections.md`. Document these rules prominently:

- read safety comes from `reads_allowed`, not `lifecycle_phase`;
- wait-for-position compares only `serving_applied_position` with basis `checkpoint`;
- basis `append` is transactionally current and has no independent number;
- candidate progress is never serving freshness;
- cache invalidation compares `serving_epoch`, not checkpoint regression;
- a missing group, false availability, unmanaged basis, or unknown required position is
  fail-safe;
- v1 is frozen, and clients should name columns rather than use `SELECT *`.

Create an ADR for the public status contract using the next ID allocated at landing
time. Amend ADR-9 for view snapshot coverage and ADR-26/34 for the public group observer
contract. Maintain `docs/adr/log.md` with `okf log add` and run strict validation.

Capture a two-connection Jitsurei transcript showing v1 serving status and candidate v2
progress together, followed by one epoch change at promotion. Update `keiro` and
`keiro-migrations` changelogs and run `just verify`.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro` unless the upstream
Kiroku plan explicitly says otherwise.

```bash
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
cabal test keiro-migrations-test
cabal test keiro-test --test-option=--match --test-option="projection group status v1"
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```

For the Jitsurei transcript, use one connection to run the supported schema-versioned
rebuild and a separate `psql` loop selecting explicit v1 columns. Record real output in
Outcomes & Retrospective; do not paste hypothetical values as evidence.


## Validation and Acceptance

Acceptance requires an independent SQL client to implement both freshness and rebuild
observation from documented columns alone without private-schema privileges.

During online v2 replay the client observes `reads_allowed = true`, an unchanged serving
revision/epoch, a normally advancing serving checkpoint, and a separate candidate
cursor/head. During the bounded cutover it may wait on the group/table locks but never
sees a false serving/candidate mixture. After commit it observes the v2 revision, an
epoch increment, cleared candidate fields, and a serving checkpoint at the promoted
head.

During an offline rebuild it observes `reads_allowed = false` and does not interpret
replay progress as safe serving data. A missing Kiroku member makes serving position
unknown. Dropping or changing the public view is detected by expected-schema
verification. No test or shipped object refers to a private Kiroku table.


## Idempotence and Recovery

The migration is forward-only and never edited after release. Registration reconciles
cursor bindings delete-then-insert inside its existing transaction, so retry cannot
leave partial membership. The public view is derived and carries no second mutable
copy of lifecycle state.

If the upstream Kiroku relation changes incompatibly before this plan lands, update the
dependency deliberately and re-run all SQL contract tests; do not hide the change in the
view body. After v1 ships, an incompatible public contract requires v2 and a documented
migration window.


## Interfaces and Dependencies

The plan depends on:

- plan 256's private generation/revision metadata and serving availability fields;
- the released SQL checkpoint relation requested by
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-5`, concretely
  `kiroku.subscription_checkpoints_v1` from `kiroku-store-migrations` 0.3.1.0 or later;
- `keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` and native migration fixtures;
- catalog registration/adoption in
  `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`;
- the new typed accessor module
  `keiro/src/Keiro/ReadModel/Rebuild/Status.hs`;
- plan 255, which consumes `reads_allowed`, serving revision, and epoch but does not
  redefine them.

This plan does not grant target-table access, generate reader functions, or infer which
query contract is compatible with a target revision. Those belong to plan 255.


## Commit and Trailer Convention

Use Conventional Commits and include:

```text
MasterPlan: docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md
ExecPlan: docs/plans/254-publish-a-documented-projection-status-relation-for-external-readers.md
Intention: intention_01kzw6dkhje7qvw6w321pwyv12
```


## Revision Note

Revised 2026-08-13 after architecture validation. The plan now versions the public
relation, separates serving availability/position from candidate lifecycle/progress,
uses serving epochs for generation changes, removes checkpoint-regression acceptance,
and makes an owner-published Kiroku SQL checkpoint relation a hard prerequisite.

Revised again on 2026-08-13 after Kiroku completed and released IR-5. Milestone 1 is now
complete, the exact `kiroku.subscription_checkpoints_v1` contract and owning canonical
artifacts are recorded, and plan 256 is the only remaining hard prerequisite.
