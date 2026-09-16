---
id: 117
slug: preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe
title: "Preserve headers on DLQ redrive and make archive and purge visibility-safe"
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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-12T17:28:45Z
      mode: "update"
      note: "Audited local downstream changes and aligned handoffs with client-only ordering, optional additive indexes, and no SQL overrides."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-15T19:58:38Z
      mode: "update"
      note: "Refresh released pgmq-hs 0.6 ownership, keiro-ops caller coverage, and purge safety limitations."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:45:20Z
      mode: "implement"
      note: "Implemented and validated DLQ header preservation, then continued through visibility-safe archive and purge work"
---

# Preserve headers on DLQ redrive and make archive and purge visibility-safe

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Keiro's dead-letter queue (DLQ) stores messages whose processing failed. Operators use
`readDlq` to inspect them, `redriveDlq` to send them back for processing,
`archiveDlq` to retain them for audit, and `purgeDlq` to delete them.

Two defects remained after the pgmq-hs 0.6.0.0 upgrade. Redrive dropped the original
message headers, including the FIFO group (first-in, first-out ordering group), tenant
metadata, and producer trace context. Inspection hid rows for 30 seconds; the count-based
archive then skipped those rows, while purge deleted them anyway. This implementation
preserves headers, adds archive-by-ids, and makes ordinary purge refuse when metrics report
hidden rows.

All remaining implementation belongs in keiro: principally `keiro-pgmq`, with a required
`keiro-ops` caller update. The released pgmq-hs APIs already support these operations.
No pgmq-hs change, migration, SQL-function override, or further dependency upgrade is a
prerequisite. The purge guard is best effort: metrics and truncate are separate operations,
so this plan protects the sequential inspection runbook, not concurrent readers or writers.
An audit-safe full-queue runbook requires quiescing concurrent activity and accounting for
every row before purge.


## Progress


- [x] (2026-09-15) Refreshed against keiro source, Mori-discovered dependency source, Hackage versions, and upstream release tag v0.6.0.0; established keiro versus pgmq-hs ownership.
- [x] (2026-09-15) M1: Parsed and exposed original headers, preserved them on redrive, and passed header/legacy-wrapper regressions (`cabal test keiro-pgmq-test`: 61 examples, 0 failures, 2 pre-existing pending).
- [x] (2026-09-15) M2: Added archive-by-ids, typed guarded purge, explicit force purge, and visibility regressions (`keiro-pgmq-test`: 64 examples, 0 failures, 2 pre-existing pending).
- [x] (2026-09-15) M2: Updated keiro-ops purge result handling and tested refusal without deleting inspected rows (`keiro-ops-test`: 50 examples, 0 failures).
- [x] (2026-09-15) M3: Corrected the operator runbook and compatibility notes; passed the no-wait inspect/archive/purge example and both affected suites (`keiro-pgmq-test`: 65 examples, 0 failures, 2 pre-existing pending; `keiro-ops-test`: 50 examples, 0 failures).
- [x] (2026-09-15) Updated both affected changelogs, amended ADR 28 and its bundle log, passed strict ADR validation (43 concepts), built all packages, and completed the final source/caller audit.


## Surprises & Discoveries


The 2026-09-15 source audit confirms both defects remain in
`keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`: `parseDlqEnvelope` ignores `original_headers`,
`redriveOne` calls bare `Pgmq.sendMessage`, and `purgeDlq` discards the result of
unconditional `deleteAllMessagesFromQueue`. This refresh did not execute the regression
suite; these are source findings, not new runtime test results.

The upgrade is already represented by `>=0.6 && <0.7` family bounds in
`keiro-pgmq/keiro-pgmq.cabal`, including the test dependency on pgmq-migration.
Hackage's preferred-version responses for pgmq-effectful and pgmq-hasql both list 0.6.0.0
as the newest normal version. Upstream tag `v0.6.0.0` resolves to
`7269f4de0a6e4e6f138c849758c18c7324410ac2`. The relevant local API and migration files
have no diff from that tag. The old plan's trailing 0.4 bounds were stale.

The released migration history ends at `0006-preserve-partitioned-reentry-v1.13.0.sql`,
after `0004-upgrade-v1.12.0.sql` and `0005-upgrade-v1.13.0.sql`; the previous revision's
migration-0007 premise is obsolete. pgmq-hasql already projects and decodes the nullable
`defaultPartitionLength` metric. Keiro's guard needs only `queueLength` and
`queueVisibleLength`; it must neither decode SQL itself nor interpret the partition
estimate as a count of hidden rows.

There is a production caller omitted from the old plan:
`keiro-ops/src/Keiro/Ops/Pgmq.hs` matches the purge result as `()` in `runPurge`.
Its existing global `--force` flag authorizes mutations after preview; using it implicitly
to bypass the new visibility guard would defeat the operator fix.

Adding a field to exported `DlqEntry (..)` can break external constructors, and changing
`purgeDlq`'s result does not force every caller to inspect it: callers using `void` or
discarding a do-block result can still compile. A source search and migration guidance
are required in addition to compilation.

The first M1 regression reproduced the header loss before implementation: after redrive,
the main-queue row had `headers = Nothing` instead of the wrapper's group, fixed
`traceparent`, and tenant metadata. With wrapper parsing and header-aware resend in place,
the full pgmq suite passed with 61 examples, zero failures, and the same two pending
integration cases.

The M2 regressions confirm that a count-based archive sees zero rows immediately after
inspection, while `archiveDlqEntries` moves those same hidden ids without waiting and
returns no ids on empty, repeated, or unknown requests. A guarded purge reports one
hidden row and leaves the complete DLQ depth unchanged; `purgeDlqForce` remains the
explicit unconditional path. The operator's ordinary `--force` execution flag reaches
the guard and surfaces its refusal rather than bypassing it.


## Decision Log


Decision (2026-07-23, reaffirmed 2026-09-15): use only the wrapper's
`original_headers` for redrive. Missing or JSON-null values mean no preserved headers.
Never substitute the DLQ row's own headers: the worker adapter can merge the failing
consumer's trace context into them. The wrapper retains the original producer metadata.

Decision (2026-07-23, clarified 2026-09-15): retain the count-based archive's visible-row
semantics and add `archiveDlqEntries` for known ids. The existing batch archive SQL
has no visibility predicate. There is no need to add a new queue-enumeration primitive
or construct queue-table SQL in keiro to implement the inspection workflow.

Decision (2026-07-23, clarified 2026-09-15): `purgeDlq` returns a typed refusal or purge
count; `purgeDlqForce` retains unconditional deletion. The check is a metrics snapshot
followed by truncate, not a transactional guarantee. A future requirement to prevent
concurrent claims/inserts from being purged needs separate design of a generic atomic
operation in `mori://shinzui/pgmq-hs`, including locking semantics and concurrency tests.
Merely wrapping two calls in a transaction must not be advertised as sufficient.

Decision (2026-09-15): no work is required in pgmq-hs for the acceptance criteria below.
Its ownership remains the generic send/archive/metrics/purge primitives and their server
compatibility. Keiro owns wrapper interpretation, operator policy, public job helpers,
CLI presentation, documentation, and integration regressions. The 0.6 grouped-head APIs
and partition controls do not implement any of these keiro policies.

Decision (2026-09-15): keep keiro-ops mutation preview/confirmation behavior, call guarded
`purgeDlq` on execution, map `PurgeDlqBlocked` to `Failed`, and report the count for
`PurgeDlqPurged`. Do not turn the existing global `--force` into a hidden-row override.
The explicit unconditional escape hatch in this plan is the Haskell `purgeDlqForce`
API; a new CLI bypass flag is outside this plan.

Decision (2026-09-15): distill the operator policy into
[ADR 28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
rather than create a new record. The durable rule is that destructive authorization reaches
the owning library operation but does not override its typed safety refusal. The telemetry
contract in ADR 1 remains unchanged.


## Outcomes & Retrospective


Implementation is complete. Redrive now restores only the wrapper's original headers;
legacy missing/null wrappers remain headerless and conflicting DLQ-row headers are ignored.
Operators can archive inspected ids immediately, ordinary purge returns a typed deleted or
blocked count, and the distinctly named force API remains available only to Haskell callers.
The keiro-ops execution flag reaches the guarded operation and reports hidden-row refusal
without deleting inspected rows.

The no-wait proof dead-lettered two rows, inspected both, archived both ids, observed
`PurgeDlqPurged 0`, retained two archive rows, and left active depth zero. Final validation
passed `cabal build all`, `cabal test keiro-pgmq-test keiro-ops-test`, strict ADR profile
validation, and the source/caller audit. The pgmq suite reported 65 examples, zero failures,
and its two pre-existing pending integration cases; the ops suite reported 50 examples and
zero failures. No dependency bound, SQL function, schema migration, or upstream package was
changed. The best-effort metrics-snapshot concurrency limitation remains deliberate and is
now documented in the public runbook and ADR 28.


## Context and Orientation


`keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` contains the wrapper parser, public `DlqEntry`,
and all DLQ helpers. `keiro-pgmq/src/Keiro/PGMQ.hs` re-exports the module.
`keiro-pgmq/src/Keiro/PGMQ/Job.hs` writes DLQ wrappers in `sendDlq`;
`keiro-pgmq/src/Keiro/PGMQ/Metrics.hs` wraps the metrics operation.
`keiro-pgmq/test/Main.hs` contains the integration examples, `readMessages`,
`headerKey`, and `archiveCount` helpers. `keiro-ops/src/Keiro/Ops/Pgmq.hs`
implements the operator commands, with integration coverage in `keiro-ops/test/Main.hs`.

PGMQ stores live queue rows in `pgmq.q_<name>` and archive rows in `pgmq.a_<name>`.
A read advances `vt`, the timestamp until which the row is hidden from subsequent reads.
Keiro's read-based DLQ helpers use a 30-second timeout. Archive by id moves rows regardless
of that timestamp, using one SQL statement that deletes from the queue and inserts into
the archive. Purge truncates the active queue, including hidden rows, but leaves its
archive alone.

Both keiro writer paths preserve a wrapper with required `original_message` and
`dead_letter_reason`, and optional original id/time/read-count/header metadata.
The adapter's `mkDlqPayload` supplies the wrapper; its `mergeDlqHeaders` explains why
row-level trace context must not be used as a fallback. Locate dependency sources with:

```bash
mori registry search pgmq
mori registry show shinzui/pgmq-hs --full
mori registry docs shinzui/pgmq-hs
mori registry show shinzui/shibuya-pgmq-adapter --full
```

The canonical dependency project is `mori://shinzui/pgmq-hs`. Within it, inspect
`pgmq-effectful/src/Pgmq/Effectful/Effect.hs`,
`pgmq-hasql/src/Pgmq/Hasql/Statements/Types.hs`,
`pgmq-hasql/src/Pgmq/Hasql/Statements/Message.hs`,
`pgmq-hasql/src/Pgmq/Hasql/Statements/QueueObservability.hs`,
`pgmq-hasql/src/Pgmq/Hasql/Decoders.hs`,
`pgmq-migration/migrations/manifest`, and
`pgmq-migration/migrations/0001-install-v1.11.0.sql`.
These source-file artifact URIs are pending; the canonical project URI plus relative paths
identify them. The same convention applies to
`mori://shinzui/shibuya-pgmq-adapter`, whose relevant files are
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` and
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`.
Its operator guide is `mori://shinzui/shibuya-pgmq-adapter/docs/pgmq-dead-letter-queues`.

The relevant local ADR is
[docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md).
It requires one process span per delivery on both worker and one-shot paths.
This plan preserves original trace headers without adding process spans to DLQ helpers
or changing those processing paths. Keep the captured-span regressions intact.

The parent remains
`docs/masterplans/17-harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review.md`.
Sibling `docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md`
owns FIFO consumption policy, and
`docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md`
owns partition retention/provisioning. Neither is a prerequisite. Follow the current
test job constructors if those plans land first. Preserving a group header does not restore
a redriven message's old queue position: a fresh send gets a new id and read count.


## Plan of Work


### Milestone 1 — preserve original headers on redrive


Extend internal `DlqEnvelope` with `envelopeOriginalHeaders :: Maybe Value` and public
`DlqEntry` with `originalHeaders :: Maybe Value`. Parse the wrapper's
`original_headers` as optional, treating absent and null as `Nothing`; preserve other
JSON values unchanged. Populate the field in `toEntry`, including `Nothing` in its
malformed-wrapper branch. Keep the wrapper and raw body available for forensics.

In `redriveOne`, use `Pgmq.sendMessageWithHeaders` for `Just headers`, constructing
`SendMessageWithHeaders` with the physical queue name, original body,
`MessageHeaders headers`, and `delay = Nothing`. Keep bare `sendMessage` for
`Nothing`. Delete the DLQ row after sending as today. Redrive remains at-least-once:
a crash between send and delete can duplicate delivery.

Add tests in `keiro-pgmq/test/Main.hs` for FIFO group, valid fixed `traceparent`,
and application metadata preservation, using existing enqueue/Dead-handler helpers.
Assert `readDlq` exposes the original headers. Add wrappers with missing and explicit
null headers, and a row whose own headers conflict with wrapper headers; only the
wrapper must determine the result. Legacy wrappers must redrive without adopting row
headers. Retain malformed-wrapper behavior. Use separate fixtures for inspect and redrive
tests so inspection does not hide the redrive input.

Run `cabal test keiro-pgmq-test`. First write behavioral preservation tests that use
existing APIs and observe their failure against unchanged redrive; then implement the
fields and behavior and add field assertions. Do not stash unrelated work to demonstrate
the regression. Acceptance is verbatim header preservation and unchanged headerless
redrive, with existing processing/telemetry examples passing.


### Milestone 2 — archive inspected ids and guard purge, including the CLI


Add and export `archiveDlqEntries`. Empty input returns `[]` without a statement;
otherwise call `Pgmq.batchArchiveMessages` with
`BatchMessageQuery { queueName = job.jobQueue.dlqName, messageIds = ids }`.
Return the ids actually moved, treating unknown or already archived ids as omissions.
Do not promise returned-id order. Keep `archiveDlqEntry` and its existing
`archiveDlqEntryById` numeric convenience wrapper.

Add `PurgeDlqResult` and implement the guard as follows; import `QueueMetrics (..)`
so record selectors are available along with the existing effect imports:

```haskell
data PurgeDlqResult
  = PurgeDlqPurged !Int64
  | PurgeDlqBlocked !Int64
  deriving stock (Eq, Show)

purgeDlq :: (Pgmq :> es, IOE :> es) => Job p -> Eff es PurgeDlqResult
purgeDlq job = do
  metrics <- Pgmq.queueMetrics job.jobQueue.dlqName
  let invisible = metrics.queueLength - metrics.queueVisibleLength
  if invisible > 0
    then pure (PurgeDlqBlocked invisible)
    else PurgeDlqPurged <$> Pgmq.deleteAllMessagesFromQueue job.jobQueue.dlqName

purgeDlqForce :: (Pgmq :> es, IOE :> es) => Job p -> Eff es Int64
purgeDlqForce job = Pgmq.deleteAllMessagesFromQueue job.jobQueue.dlqName
```

The blocked count is from the metrics observation; the purged count is what PGMQ reports.
Neither is a concurrency guarantee. Exceptions from either operation propagate normally.
Do not consult `defaultPartitionLength`, or change pgmq-hasql's decoder.

Update `runPurge` in `keiro-ops/src/Keiro/Ops/Pgmq.hs` after its existing confirmation.
Return `Failed` with the hidden count and guidance to archive inspected ids or wait when
blocked; return success with the reported deleted count when purged. The global force flag
continues to authorize executing the guarded operation. Preserve preview and confirmation
behavior. Audit all `purgeDlq` and `DlqEntry` construction sites, including external
migration guidance for callers that silently discard results.

In `keiro-pgmq/test/Main.hs`, assert purge refuses immediately after inspection and
leaves all rows intact; force purge removes hidden rows; explicit-id archive moves hidden
rows and preserves archive contents; count-based archive returns zero for hidden-only
input; empty/idempotent/unknown-id batch archive has the documented outcome. Compare
returned ids as sets or sorted lists. Update existing purge assertions for the new result.

In `keiro-ops/test/Main.hs`, cover preview, successful purge, and inspect-then-execute
with the existing force flag: the last case returns `Failed` and leaves DLQ depth
unchanged. Existing archive-by-entry continues to work while a row is hidden.
Run both affected suites. Acceptance is observable refusal in both the library and operator
command, and successful archival of the exact inspected ids without waiting.


### Milestone 3 — document and prove the complete operator workflow


Rewrite the DLQ module haddock to explain the timeout on every read-based verb, preserved
headers, new queue position on redrive, typed purge outcomes, and the guard's concurrency
limit. The example inspects, archives the returned ids, verifies all requested ids were
moved, and only then considers purge. If archival omits ids, stop and investigate rather
than claiming retention succeeded.

For a full-queue audit, pause producers/other operators, archive every row that requires
retention, and verify the active depth is zero before purge. Reading a bounded batch and
then purging would still destroy uninspected visible rows. Retention guarantees for
partitioned archives remain subject to partition maintenance; coordinate that explanation
with plan 118 and do not promise indefinite retention.

Add a no-sleep test: dead-letter two rows, inspect both, archive their ids, then guarded
purge. Expect two inspected entries, both ids moved, `PurgeDlqPurged 0`, archive count
two, and active depth zero. Keep the existing archive-survives-purge example.

Update `keiro-pgmq/CHANGELOG.md` for the result type, record-field compatibility change,
force API, and header behavior; update `keiro-ops/CHANGELOG.md` for refusal semantics
under its existing execution flag. Run both affected suites and build the project.
Review the Decision Log for ADR distillation under the repository's current ADR profile
before declaring implementation done. This refresh establishes no new implemented
architecture and does not change the existing telemetry ADR.


## Concrete Steps


Run from the keiro repository root. The integration suites use
`keiro-test-support/src/Keiro/Test/Postgres.hs` to start an ephemeral PostgreSQL server
and migrate a template database, then clone it per example. PostgreSQL tools must be on
PATH; use the project's development shell if they are missing.

```bash
cabal test keiro-pgmq-test keiro-ops-test
```

The expected outcome is both suites reporting PASS and zero failures. Record the actual
example/pending counts at execution time. Two pgmq examples are currently marked pending
(transient polling fault injection and live partition configuration); do not add new pending
cases to conceal DLQ failures. If required tooling is absent, run:

```bash
nix develop -c cabal test keiro-pgmq-test keiro-ops-test
```

Implement M1, M2, and M3 in order, running the affected suites after each. Before completion:

```bash
rg -n 'purgeDlq|DlqEntry' keiro-pgmq keiro-ops
cabal build all
cabal test keiro-pgmq-test keiro-ops-test
git diff --check
```

Use Conventional Commits when committing implementation, with the plan and intention
trailers. Commit only changes belonging to this work:

```text
ExecPlan: docs/plans/117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md
Intention: intention_01m2b1p3vhe179jtr5qz6ghqks
```


## Validation and Acceptance


Headered messages return to the main queue with the wrapper's exact group, trace, and
application metadata. Missing/null wrapper headers remain headerless even if the DLQ row
has headers. Malformed wrappers remain inspectable and are not redriven.

An immediate inspection followed by guarded purge returns `PurgeDlqBlocked n` for
`n > 0` and deletes nothing. The same sequence through keiro-ops reports failure,
including when its normal mutation flag is supplied. Explicit force purge remains
unconditional through its distinctly named Haskell API.

Inspection followed by archive-by-ids retains every inspected row despite the timeout.
The no-wait two-row runbook finishes with two archive rows, no active rows, and
`PurgeDlqPurged 0`. Empty/repeated/unknown-id requests behave as documented.
These examples run without concurrent queue activity; no concurrency-safety claim is made.

Both affected suites pass without new pending tests, all project packages build, and the
existing job process-span contract remains intact. Record actual commands and outcomes in
Progress and Outcomes & Retrospective. No upstream package release or SQL change is part
of acceptance.


## Idempotence and Recovery


Tests use isolated databases. Retrying archive-by-id is safe: rows already archived are
omitted from the returned list. Keep inspected ids if a later operation fails so operators
can retry archival directly without waiting for visibility.

Redrive remains at-least-once and application handlers must tolerate duplicates.
A blocked purge changes nothing; wait for visibility to expire or archive known ids.
Waiting alone does not retain evidence: purge still permanently deletes remaining rows.
Force purge is intentionally destructive. Quiesce concurrent activity for the documented
audit workflow, and never treat a metrics snapshot as a lock.

M1 can ship independently of M2. Roll back the M2 library and keiro-ops caller together
if necessary because their result types must agree. No schema migration or dependency
rollback is required.


## Interfaces and Dependencies


Keep existing exports, including `archiveDlqEntryById`, and add:

```haskell
-- New field on exported DlqEntry p:
originalHeaders :: Maybe Value

archiveDlqEntries :: (Pgmq :> es, IOE :> es) => Job p -> [MessageId] -> Eff es [MessageId]
data PurgeDlqResult = PurgeDlqPurged !Int64 | PurgeDlqBlocked !Int64
purgeDlq :: (Pgmq :> es, IOE :> es) => Job p -> Eff es PurgeDlqResult
purgeDlqForce :: (Pgmq :> es, IOE :> es) => Job p -> Eff es Int64
```

`readDlq`, `redriveDlq`, `archiveDlq`, `archiveDlqEntry`, and
`archiveDlqEntryById` keep their existing types. Document compatibility for exported
record construction and for callers that ignored the old purge result.

The existing `>=0.6 && <0.7` bounds are sufficient.
`mori://shinzui/pgmq-hs/packages/pgmq-effectful` supplies
`sendMessageWithHeaders`, `batchArchiveMessages`, `queueMetrics`, and
`deleteAllMessagesFromQueue`, including their argument/result types through its public
umbrella. `mori://shinzui/pgmq-hs/packages/pgmq-hasql` owns statement encoding and the
1.12/1.13-compatible metrics projection.
`mori://shinzui/pgmq-hs/packages/pgmq-migration` already supplies the native 1.13 schema.
Keep those responsibilities upstream and consume their released interfaces in keiro.

Release verification on 2026-09-15 used Hackage's package preferred-version endpoints and
upstream Git tags. To repeat the check without relying on a stale local registry:

```bash
curl -fsSL https://hackage.haskell.org/package/pgmq-effectful/preferred.json
curl -fsSL https://hackage.haskell.org/package/pgmq-hasql/preferred.json
git ls-remote --tags https://github.com/shinzui/pgmq-hs.git
```

These registry/remote endpoints verify the release of `mori://shinzui/pgmq-hs`;
the canonical project and package URIs above identify the dependency.

Revision (2026-09-12): Aligned the sibling dependency handoff with client-only ordering
and optional additive indexes; DLQ behavior remains independently implementable.

Revision (2026-09-15): Refreshed against released pgmq-hs 0.6.0.0 and current keiro source.
Corrected dependency/migration premises, made repository ownership explicit, added the
keiro-ops caller and regressions, removed stale line numbers and fixed test counts, and
clarified best-effort purge, compatibility, and complete-audit limitations.

Revision (2026-09-15): Began implementation and completed Milestone 1. Recorded the
observed header-loss regression and the passing full-suite result after preserving wrapper
headers while keeping missing, null, and malformed legacy wrappers headerless.

Revision (2026-09-15): Completed Milestone 2 in the library and operator adapter. Added
archive-by-id batches, typed guarded and explicit-force purge outcomes, operator refusal
reporting, and visibility regressions with passing pgmq and ops suites.

Revision (2026-09-15): Completed Milestone 3 and the plan. Added the no-wait operator
workflow, public safety and compatibility documentation, both changelog entries, final
validation evidence, and ADR 28 distillation for conditional destructive operations.
