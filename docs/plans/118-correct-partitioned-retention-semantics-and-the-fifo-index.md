---
id: 118
slug: correct-partitioned-retention-semantics-and-the-fifo-index
title: "Correct partitioned retention semantics and the FIFO index"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
intention: "intention_01m2b1p3vhe179jtr5qz6ghqks"
master_plan: "docs/masterplans/17-harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review.md"
provenance:
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T13:26:48Z
      mode: "update"
      note: "Validated that MasterPlan 17 was not migrated to the pgmq project; refreshed pgmq 0.6/migration-0007 premises and recorded read_grouped_head"
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T14:36:53Z
      mode: "update"
      note: "Relocated the upstream SQL/doc scope to pgmq-hs MasterPlan 5; rewrote upstream milestones as consumption"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-12T17:28:45Z
      mode: "update"
      note: "Audited local downstream changes and aligned handoffs with client-only ordering, optional additive indexes, and no SQL overrides."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T13:44:09Z
      mode: "update"
      note: "Refreshed current retention/index scope and added full-workload performance regression gates"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T16:49:37Z
      mode: "implement"
      note: "Started retention guardrail and truthful FIFO provisioning documentation"
---

# Correct partitioned retention semantics and the FIFO index

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current while implementing it. Promote durable conclusions to
the ADR corpus before completion.

**Current cross-repository contract (2026-09-16).**
`mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`
prohibits overriding extension-owned SQL on native and extension installations. Its index work
may recommend only an optional, separately named `q_<queue>_group_lookup_idx` after full-query
measurement. Upstream `q_<queue>_fifo_idx`, FIFO helpers, function bodies, and name-based
presence reporting remain unchanged. No migration, automatic replacement, or startup DDL is
planned. Existing historical migration bytes remain immutable.


## Purpose / Big Picture

`keiro-pgmq` currently makes two unsafe or inaccurate provisioning claims. A partitioned
queue's `retentionInterval` looks like a harmless cleanup preference, but PGMQ configures
pg_partman to permanently drop whole old partitions from both the active queue and archive.
Processing state does not protect an eligible active partition, so a backlog or consumer outage
longer than the retention horizon can silently delete unprocessed work.

Keiro also describes upstream's JSONB GIN index on `headers` as the index that grouped reads
match. The grouped reads instead group and compare
`COALESCE(headers->>'x-pgmq-group', '_default_fifo_group')` and order by `msg_id`. The GIN
operator class does not directly serve that expression equality or ordering. This mismatch does
not prove a particular full query plan, and an expression B-tree can itself create write,
storage, vacuum, DDL-lock, or polling regressions. Performance must be measured rather than
inferred from one plan node.

After this plan, Keiro documents partition deletion accurately and offers a deliberately bounded
construction-time guardrail. Ordinary FIFO provisioning is described truthfully as upstream's
conventional GIN. Keiro recommends no supplemental index unless measurements show a material
win for the actual `read_grouped`, `read_grouped_rr`, and `read_grouped_head` workloads without
an unacceptable polling, write, lease, storage, or lock regression. Any accepted expression
index is optional operator-owned state installed through the owning pgmq project, not Keiro
startup. No upstream function or existing index is replaced.


## Progress

- [x] (2026-09-16) Refreshed current Keiro, pgmq-hs, PGMQ, and Shibuya adapter evidence. `cabal test keiro-pgmq-test --test-show-details=direct` passed with 65 examples, 0 failures, and 2 pre-existing pending examples.
- [x] (2026-09-16) M1: Added and tested the bounded `mkPartitionSpec` guardrail; corrected `PartitionSpec`, `QueueKind`, and provisioning Haddocks while preserving the DLQ runbook. Haddocks rendered successfully and `keiro-pgmq-test` passed with 79 examples, 0 failures, and 2 pre-existing pending examples.
- [x] (2026-09-16) M2: Audited the owning pgmq-hs plan and current source. It still contains no probe, measurements, or operator procedure, so the accepted result is an explicit pending/no-recommendation outcome rather than invented performance evidence.
- [x] (2026-09-16) M3: Corrected FIFO provisioning Haddocks and user guidance to describe the conventional name-detected GIN accurately. Existing reconciliation tests passed; supplemental-index lifecycle, lock, and partition validation is not applicable because no procedure was accepted.
- [x] (2026-09-16) Updated `keiro-pgmq/CHANGELOG.md`, completed ADR distillation into new ADR 45, passed strict validation for 45 ADR concepts, built all packages, passed the native flake checks, and completed the final source audit.


## Surprises & Discoveries

- The current Keiro source still exports only the raw `PartitionSpec` constructor. Its Haddock
  still presents retention as an example string, and its FIFO provisioning Haddocks still say
  the stock GIN is the index grouped reads match. This plan's implementation is unstarted.
- Plan 117 has already corrected `Keiro.PGMQ.Dlq` while implementing safe DLQ operations. The
  current module says ordinary DLQ rows do not expire automatically and separately warns that a
  partitioned archive follows partition maintenance. This plan must verify and preserve that
  paragraph, not overwrite it with its July draft.
- `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`
  remains planning-only: no probe fixture, EXPLAIN evidence, or operator procedure exists yet.
  Its initial candidate is a B-tree over the coalesced group expression and `msg_id`; that shape
  may help group joins while still scanning the whole backlog to compute group minima.
- The released pgmq-hs family remains 0.6.0.0 and vendors PGMQ 1.13.0; authoritative repository
  tags still end at those versions. The pgmq-hs checkout has later unrelated effectful-core-bound
  work but no index experiment or changed grouped-read SQL.
- The current Mori registry resolves the owning pgmq-hs and adapter projects and packages but
  not their plan or MasterPlan artifact kinds. The canonical plan URIs in this document are
  retained intentionally; their files were verified through the project checkouts returned by
  `mori path`.
- Plan 116 now chooses a distinct `FifoHeads` mode backed by `read_grouped_head`, and
  `mori://shinzui/shibuya-pgmq-adapter/plans/7-add-grouped-head-fifo-polling-to-the-pgmq-adapter`
  owns adapter dispatch and safe-drain evidence. The adapter source has implemented and committed
  `HeadPerGroup`, database semantics, and a 10k/100k safe FIFO drain matrix, including 100,000
  messages across 10,000 groups; the latest authoritative adapter release remains 0.15.0.0 while
  its full benchmark, documentation, and release milestone is in progress. Index evaluation must
  include grouped heads and reuse that end-to-end harness rather than measure only the two legacy
  grouped reads.
- Empty and invisible-backlog polls are first-class performance cases. Standard workers repeat
  an empty grouped read after their configured delay; long polling may repeat the same expensive
  inner query every 100 ms for several seconds. A candidate that improves a visible batch but
  worsens empty polling can increase steady-state database load.
- PGMQ creates a `vt` index and every lease changes `vt`. Such updates cannot use PostgreSQL's
  heap-only-tuple optimization, so an extra B-tree can add index writes and bloat even though its
  own key columns are unchanged. Measure repeated claim/retry/visibility cycles, not only insert
  latency and a single read.
- PGMQ 1.13 classifies `partition_interval` by casting it to PostgreSQL `INTEGER`, a signed
  32-bit value. The previous plan's proposed `Int64` classifier could disagree for values outside
  that range and treated negative numeric text as a time interval. The constructor must mirror
  the server boundary and describe the retention comparison as Keiro policy, not pg_partman
  proof.
- The refreshed pgmq-hs plan 20 remains entirely unchecked and the checkout contains no
  `fifo-index-probe.sql`, measurements, or supported supplemental-index procedure. The plan's
  negative/pending branch is therefore the only evidence-based completion available in Keiro;
  procedure-specific lock and partition tests would be fictional without an accepted procedure.
- The adapter checkout and authoritative remote tag now contain released 0.16.0.0 at annotated
  tag `v0.16.0.0`, superseding this plan's refresh-time statement that 0.15.0.0 was latest. This
  resolves the grouped-head workload dependency but does not supply supplemental-index evidence.


## Decision Log

- Decision: Fix the retention hazard with truthful documentation plus a bounded
  `mkPartitionSpec` constructor, while retaining the raw constructor. Label partitioned
  provisioning experimental until its live pg_partman example runs in CI.
  Rationale: Keiro must prevent obvious configuration mistakes without pretending a local
  parser can prove that an operator-selected retention horizon exceeds every future outage or
  backlog.
  Date: 2026-09-16

- Decision: `mkPartitionSpec` validates trimmed non-empty values; positive, signed-32-bit
  `partition_interval` for numeric/message-id partitioning; matching numeric-versus-time units;
  and positive numeric retention not smaller than one configured id span. Parse numeric-looking
  text through unbounded `Integer` first so overflow and negatives receive explicit errors.
  Time strings such as `daily` and `7 days` remain opaque because duplicating PostgreSQL's
  interval parser would drift.
  Rationale: Mirror PGMQ's actual `INTEGER` classifier without claiming that construction proves
  a safe retention horizon. Retention must still exceed application worst-case outage and
  backlog age by an operator-chosen margin.
  Date: 2026-09-16

- Decision: Queue-kind drift remains outside this plan. Re-provisioning an existing queue with
  a different `QueueKind` may be skipped by the additive reconciler.
  Rationale: The parent master plan records this accepted boundary; fixing it would change the
  reconciler contract rather than retention or index truthfulness.
  Date: 2026-07-23

- Decision: Follow the upstream MasterPlan 5 boundary: only additive, separately named indexes
  are permitted. Do not replace GIN, helper behavior, presence reporting, or SQL functions.
  Rationale: Preserve upstream ownership and compatibility.
  Date: 2026-09-12

- Decision: Do not publish a general supplemental-index recommendation from a candidate shape
  or an EXPLAIN node. Compare the production baseline, stock GIN, with stock GIN plus candidate
  and require a material benefit with bounded regressions.
  Rationale: The three grouped reads have different plans, and an extra index affects inserts,
  every non-HOT lease update, disk, vacuum, DDL locks, and repeated empty polls. A plan-node win
  can still be an end-to-end loss.
  Date: 2026-09-16

- Decision: Keiro will not add a `keiro-ops` command or direct private-schema mutation for the
  supplemental index. If the experiment succeeds, the pgmq-owning project publishes the tested
  create/inspect/remove procedure or supported API; Keiro only documents the handoff.
  Rationale: [ADR 28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  requires operator commands to respect library schema ownership.
  Date: 2026-09-16

- Decision: Complete the index-evidence milestone with an explicit pending/no-recommendation
  result because the owning pgmq-hs plan has not produced a probe, measurements, or procedure.
  Do not perform lifecycle tests against a hypothetical index definition or copy candidate DDL
  into Keiro.
  Rationale: The plan expressly accepts a negative or pending result, while reproducible owning-
  project evidence is a prerequisite for any recommendation.
  Date: 2026-09-16

- Decision: Record the partition guardrail and upstream-SQL/index boundary in
  [ADR 45](../adr/0045-pgmq-provisioning-preserves-upstream-sql-and-bounds-local-retention-validation.md).
  ADR 1 is unchanged because processing telemetry did not change; ADR 28 remains the supporting
  schema-ownership rule rather than the primary home for partition-retention semantics.
  Rationale: Whole-partition deletion, bounded local validation, and the no-unmeasured-index rule
  are durable public provisioning constraints.
  Date: 2026-09-16


## Outcomes & Retrospective

Implementation is complete. `mkPartitionSpec` trims inputs and rejects empty, mixed-unit,
non-positive, signed-32-bit-overflowing partition, and too-short numeric retention settings while
leaving paired time syntax server-validated and retaining the raw constructor escape hatch.
Haddocks, user documentation, and the changelog now state that retention drops whole active and
archive partitions and that the conventional FIFO GIN's name-based presence is not proof of
grouped-read acceleration.

The owning pgmq-hs plan has not produced the required full-workload measurements or an operator
procedure, so Keiro deliberately recommends no supplemental index and installs no experimental
DDL. `cabal build all`, rendered `keiro-pgmq` Haddocks, `keiro-pgmq-test` (79 examples, 0
failures, 2 pre-existing pending), strict ADR validation (45 concepts), formatting, and the final
native flake and diff/source audits passed. ADR 45 preserves the durable provisioning boundary.


## Context and Orientation

This repository contains `keiro-pgmq`, typed background jobs over PGMQ. The package currently
bounds the pgmq-hs libraries to `>=0.6 && <0.7` in `keiro-pgmq/keiro-pgmq.cabal`. Resolve the
dependency checkout with `mori path mori://shinzui/pgmq-hs`; it vendors PGMQ 1.13.0 in
`vendor/pgmq/pgmq-extension/sql/pgmq.sql` and installs that native schema through
`pgmq-migration`. Historical migration bytes are immutable. This plan adds no function override,
FIFO migration, or package-bound change.

The Keiro provisioning surface is the queue-lifecycle section of
`keiro-pgmq/src/Keiro/PGMQ/Job.hs`. `QueueKind` selects standard, unlogged, or partitioned
storage. `PartitionSpec` carries opaque `partitionInterval` and `retentionInterval` text.
`queueProvisionConfigs` lowers a provision to `pgmq-config` values and always creates the DLQ
as a standard queue. `ensureJobQueueWith` invokes the additive reconciler. `ensureFifoIndex` and
`ensureOrderedJobQueue` request upstream's conventional GIN index. Presence is inferred from its
name; neither presence nor successful creation proves query use. `pg_partman` is the PostgreSQL
extension that manages time- or message-id-range child tables and runs retention maintenance.

For PGQ-4, `pgmq.create_partitioned` updates pg_partman's `part_config` for the active queue
with the requested retention, `retention_keep_table = false`, and automatic maintenance. It
does the same for the archive table. Maintenance therefore drops eligible child tables rather
than checking each message's acknowledgement state. Time-based active/archive parents use
`enqueued_at`/`archived_at`; numeric parents use `msg_id`. A seven-day retention combined with
an eight-day consumer outage can delete old unprocessed active work with no Keiro DLQ entry.

For PGQ-5, `pgmq._create_fifo_index_if_not_exists` creates GIN on `headers`. The current
`read_grouped`, `read_grouped_rr`, and `read_grouped_head` implementations all compute the
coalesced group expression and group by it. Their later stages differ: throughput mode finds
visible minima and performs per-group member probes, round-robin computes absolute heads and
layers eligible members, while grouped-head selects one visible absolute head per group. The
primary key and `vt` indexes may participate independently. Full current inner queries, not a
PL/pgSQL call that hides nested plans, are the measurement unit.

Relevant local ADRs are [ADR 1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md),
which requires the drain and worker span contract to remain unchanged, and
[ADR 28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md),
which prevents Keiro operator commands from mutating a dependency's private schema. This plan
does not alter consumption telemetry and does not add a Keiro operator command.

Sibling [Plan 116](116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md)
owns `Job`, `JobOrdering`, `JobTuning`, `FifoHeads`, and the adapter release. It makes
`read_grouped_head` part of Keiro's expected workload; this plan measures that query but does
not edit those types. [Plan 117](117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md)
has implemented the DLQ runbook changes. Preserve its paragraph. Both siblings share
`keiro-pgmq/src/Keiro/PGMQ/Job.hs`, so re-read the file immediately before implementation and
confine retention/provisioning edits to the queue-lifecycle declarations.


## Plan of Work

### Milestone 1 — tell the truth about partitioned retention and guard construction

At the end of this milestone, a user reading the queue lifecycle API cannot mistake partition
retention for per-row cleanup, and obvious malformed numeric configurations fail before database
access. Provisioning behavior itself does not change.

In `keiro-pgmq/src/Keiro/PGMQ/Job.hs`, rewrite the `PartitionSpec` Haddock to explain both
opaque pg_partman strings, whole-partition deletion of active and archived data, the outage or
backlog failure mode, and the need to size retention above worst-case processing lag. Say that
the raw constructor is unvalidated and prefer `mkPartitionSpec`. Update `PartitionedKind` and
`partitionedProvision` with a short version of the warning and the experimental label.

Add and export this interface next to `PartitionSpec`, re-exported through `Keiro.PGMQ`:

```haskell
data PartitionSpecConfigError
    = EmptyPartitionInterval
    | EmptyRetentionInterval
    | NonPositivePartitionInterval !Integer
    | NonPositiveRetentionInterval !Integer
    | PartitionIntervalOutsidePostgresInteger !Integer
    | MixedPartitionUnits !Text !Text
    | RetentionBelowPartitionInterval !Integer !Integer
    deriving stock (Eq, Show)

mkPartitionSpec :: Text -> Text -> Either PartitionSpecConfigError PartitionSpec
```

Trim both inputs and reject empties. Use `Data.Text.Read.signed Data.Text.Read.decimal` and
accept only an empty remainder, parsing to unbounded `Integer`.
A numeric partition interval must be positive and at most `2147483647`, because PGMQ casts it
to PostgreSQL `INTEGER` to select `msg_id` partitioning. Numeric retention must be positive.
Exactly one numeric value is `MixedPartitionUnits`. Two numeric values with retention smaller
than the partition span are rejected as conservative Keiro policy. Two nonnumeric values pass
through for PostgreSQL/pg_partman to validate. Store the trimmed values. Do not say this proves
retention safe or that a smaller retention drops the currently filling partition.

Add pure tests in `keiro-pgmq/test/Main.hs` near the other constructor validation. Cover time
values, valid numeric values, trimming, both empty fields, zero and negative values, a partition
value above `2147483647`, mixed units in both directions, retention below the numeric partition
span, and the raw-constructor escape hatch. Update the existing pure partitioned lowering example
to construct its spec through `mkPartitionSpec`. In `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`, make no
planned prose rewrite; verify that its current ordinary-DLQ and partitioned-archive sentences
remain accurate.

Acceptance is a green `keiro-pgmq-test`, accurate rendered Haddocks, and no change to queue
creation SQL or to the `Job`, `JobOrdering`, and `JobTuning` types owned by Plan 116.


### Milestone 2 — prove that an optional supplement does not create a performance problem

Read `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`
for the candidate, supported queue types, lock cost, and explicit lifecycle. If that plan still
has no results, leave Keiro's recommendation pending and proceed only with truthful GIN
documentation. No pgmq-migration release or Keiro dependency bump is required for independent
operator DDL.

The production comparison is stock GIN versus stock GIN plus candidate. A no-FIFO-index case is
diagnostic only because `ensureOrderedJobQueue` currently provisions stock GIN. Keep data and
statistics identical between cases. Run at least three untimed warm-ups and ten timed repetitions,
and capture median, p95, rows, shared/local buffers, temporary spill, and index sizes. Use planner
defaults for acceptance; forced plan settings may explain a result but cannot justify a
recommendation. Capture `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` for the current inner SQL and
wall-clock latency for the actual PGMQ function call; the copied inner query reveals the nested
plan, while the function call includes dynamic SQL, locking, leasing, and result costs. Run
leasing samples inside a rolled-back transaction or restore the same deterministic fixture
before every sample so one candidate does not inherit consumed or newly invisible rows.

The matrix covers `read_grouped`, `read_grouped_rr`, and `read_grouped_head`; quantities 1, 10,
and 50; one, ten, one hundred, and 10,000 groups; and representative depths through 100,000
rows. For each query, include an all-visible backlog, an invisible head per group, a
fully invisible backlog, sparse visibility, and an empty queue. Exercise one and sixteen
concurrent pollers. Measure a standard empty poll and the matching five-second long-poll call at
a 100 ms inner interval so repeated-query amplification is visible.

Measure inserts with group headers and repeated claim/retry/visibility cycles. Report throughput,
WAL if available, table/index size before and after churn plus vacuum, and storage per row. Run
the adapter's existing 10k/100k safe-drain matrix as end-to-end evidence for grouped heads and
legacy quantity-one modes. Evaluate the group-expression/`msg_id` candidate separately from any
variant that keys or includes `vt`; because every lease changes `vt`, the latter has a distinct
write-amplification profile and cannot inherit the base candidate's result. Do not add this
workload to ordinary Keiro CI.

Predeclare the recommendation gate. The candidate must improve median latency or shared-buffer
work by at least 20 percent in a named large-backlog Keiro workload without worsening the other
measure by more than 10 percent. No relevant read/poll cell may regress by more than 10 percent
in median or 20 percent at p95. Insert and repeated-lease throughput may not regress by more than
10 percent. The adapter safe-drain gate must remain within its existing 20 percent limit. If
results are noisy, strategy-specific, or outside these bounds, publish the data and make no
general recommendation. A scan-node change alone never passes.

The intended supplemental name is `q_<queue>_group_lookup_idx`. Keep upstream
`q_<queue>_fifo_idx` GIN and all pgmq functions unchanged. Do not route the supplement through
`ensureFifoIndex`, `withFifoIndexProvision`, normal startup, or `keiro-ops`.


### Milestone 3 — publish accurate provisioning prose and lifecycle evidence

Correct the Haddocks for `QueueProvision`, `provisionFifoIndex`, `withFifoIndexProvision`,
`ensureFifoIndex`, and `ensureOrderedJobQueue`: they request upstream's conventional GIN index,
and name-based presence does not prove grouped-read acceleration. If the Milestone 2 gate passes,
link the separately owned operator procedure and state its precise supported strategy/workload.
If it does not pass, say that no supplemental index is recommended.

Use disposable standard, unlogged, and real-pg_partman partitioned queues to validate any
accepted procedure. Verify identifier quoting, expected/conflicting/invalid definitions,
ordinary and partitioned-parent build locks, existing child attachment, and a child created
after the parent index. Do not advertise `CREATE INDEX CONCURRENTLY` for a partitioned parent
unless the owning plan has a tested procedure. An unexpected object with the desired name is an
error, not an `IF NOT EXISTS` success.

Verify upstream GIN and function definitions remain intact, repeated reconciliation still
reports conventional index presence, and removing only the supplement restores the stock
baseline. Acceptance is truthful Haddocks, green provisioning tests, the performance gate
recorded with reproducible evidence, and either a scoped operator handoff or an explicit
negative/pending recommendation.


## Concrete Steps

Run Milestone 1 validation from the Keiro root:

```bash
cabal build all
cabal test keiro-pgmq-test --test-show-details=direct
```

For Milestones 2 and 3, use Mori to resolve the owning checkouts and read their current plans and
source before running anything:

```bash
mori path mori://shinzui/pgmq-hs
mori path mori://shinzui/shibuya-pgmq-adapter
```

Run the pgmq-hs SQL probe only against a disposable database. It must emit machine-readable
stock and candidate measurements and restore the starting index set. Record PostgreSQL and
pg_partman versions, commit IDs, settings, queue type, data distribution, warm-ups, samples, and
actual output. Do not invent a transcript when the required environment is unavailable.

Run the existing end-to-end FIFO drain evidence from the adapter checkout after its Plan 7
implementation, with `PG_CONNECTION_STRING` pointing at a disposable database:

```bash
BENCH_SAFE_FIFO_RUNS=3 nix develop -c cabal bench shibuya-pgmq-adapter-bench \
  --benchmark-options='--stdev Infinity -p safe-fifo-drain'
```

Use Conventional Commits. Every implementation commit carries both active trailers:

```text
ExecPlan: docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md
Intention: intention_01m2b1p3vhe179jtr5qz6ghqks
```


## Validation and Acceptance

The retention constructor cases pass and Haddocks cover time/numeric retention, active/archive
controls, and maintenance-time loss of unprocessed rows. The signed 32-bit partition classifier
matches PGMQ 1.13, while time strings remain explicitly server-validated. The minimum
retention-versus-partition span is described as Keiro policy, not proof of no loss. Existing
telemetry, DLQ, ordering, and provisioning tests remain green.

Ordinary provisioning is accurately documented as upstream GIN with name-based presence
reporting. Any supplemental index is separately named and explicitly installed and removed by
the owning project. Coexistence evidence preserves GIN and function definitions. The three query
shapes, empty/hidden/visible polls, long-poll amplification, concurrency, insert/lease churn,
storage, DDL locks, and partition lifecycle satisfy the predeclared gate. Otherwise the accepted
outcome is no recommendation. No migration, helper override, automatic conversion, or version
bump is introduced.


## Idempotence and Recovery

Milestone 1 is an additive constructor/documentation change with a retained raw constructor;
its pure tests are repeatable. The supplemental index is explicit operator state. Inspect its
definition and ownership before creation or removal, handle conflicting or invalid objects
through the owning tested procedure, and never drop upstream GIN or replace a function. Failed
concurrent builds on ordinary tables and interrupted partition-parent builds require the
recovery documented by that procedure. Build locks, child-index state, storage, and vacuum
effects must be reported rather than assumed harmless. This work introduces no migration or
dependency bump.


## Interfaces and Dependencies

At completion, `Keiro.PGMQ.Job`, re-exported through `Keiro.PGMQ`, additionally exports:

```haskell
data PartitionSpecConfigError
    = EmptyPartitionInterval
    | EmptyRetentionInterval
    | NonPositivePartitionInterval !Integer
    | NonPositiveRetentionInterval !Integer
    | PartitionIntervalOutsidePostgresInteger !Integer
    | MixedPartitionUnits !Text !Text
    | RetentionBelowPartitionInterval !Integer !Integer

mkPartitionSpec :: Text -> Text -> Either PartitionSpecConfigError PartitionSpec
```

`PartitionSpec`, `QueueKind`, `QueueProvision`, `partitionedProvision`,
`withFifoIndexProvision`, `queueProvisionConfigs`, `ensureFifoIndex`, and
`ensureOrderedJobQueue` keep their signatures. This plan must not edit `Job`, `JobOrdering`, or
`JobTuning`; those belong to Plan 116.

Index evidence and operator guidance are owned by
`mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`.
Upstream SQL and conventional FIFO provisioning remain unchanged. Plan 116's `FifoHeads` and
`mori://shinzui/shibuya-pgmq-adapter/plans/7-add-grouped-head-fifo-polling-to-the-pgmq-adapter`
make grouped-head and adapter safe-drain measurements part of acceptance but do not make the
supplemental index a release dependency. Retain existing pgmq family bounds unless an actual API
change elsewhere requires a separately verified update.

Revision note (2026-09-12): Removed replacement-index migration/release assumptions and brittle
scan assertions; aligned M2/M3, interfaces, and recovery with explicit supplemental-index
ownership.

Revision note (2026-09-16): Refreshed the plan against current Keiro, pgmq-hs, PGMQ 1.13, the
implemented DLQ work, and the new grouped-head adapter path. Corrected the constructor's numeric
classifier and added explicit full-workload performance, write-amplification, polling,
concurrency, storage, lock, partition, and recommendation gates so an optional index cannot ship
on plan-node evidence alone.

Revision note (2026-09-16): Implemented the bounded partition constructor and truthful public
provisioning documentation, recorded the upstream plan's lack of evidence as an explicit
no-recommendation outcome, added ADR 45, and completed validation.
