---
id: 163
slug: productize-event-history-migration-bootstrap-backup-restore-and-checkpoint-tooling
title: "Productize event-history migration bootstrap backup restore and checkpoint tooling"
kind: exec-plan
created_at: 2026-07-31T14:46:36Z
---

# Productize event-history migration bootstrap backup restore and checkpoint tooling

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, teams can move an existing event-sourced service onto the Keiro/Kiroku runtime
with supported operator tooling rather than one-off SQL. The tooling creates a checksummed portable
history archive, verifies stream/global continuity and codecs before writing, bootstraps an empty
target, imports or restores history idempotently, seeds explicitly approved subscription
checkpoints, and produces a machine-readable migration report. Backup and restore use the same
format and verifier as migration, so the recovery path is exercised by normal adoption work.

An operator can prove success by exporting a source, verifying the archive offline, importing it
twice into a disposable target, observing that the second pass is a no-op, replaying registered
aggregates/read models, and comparing source/target counts and canonical digests before cutover.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: define and version the portable archive, integrity manifest, migration policy,
  and read-only source adapters.
- [ ] Milestone 2: implement consistent export/backup and offline verification with deterministic
  digests and resumable artifacts.
- [ ] Milestone 3: implement empty-target bootstrap, staged idempotent import/restore, and explicit
  checkpoint seeding with safety gates.
- [ ] Milestone 4: add replay verification, failure/recovery integration tests, operator docs,
  migration schema/locks, telemetry, and full validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-31: MasterPlan 13 and its completed children harden framework DDL migrations, lockfiles,
  status/verify commands, and migration ownership. They do not move application event history or
  seed subscription checkpoints.
- 2026-07-31: Keiro has replay, snapshot, read-model rebuild, and dead-letter primitives, but no
  portable archive contract tying event identity, stream order, global order, metadata, source
  checkpoint provenance, and post-import replay verification together.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add `keiro-migrate history` commands while keeping history operations separate from
  the default schema-migration apply path.
  Rationale: Operators already find migration ownership and verification through `keiro-migrate`,
  but importing domain history must always require an explicit subcommand and policy file.
  Date: 2026-07-31

- Decision: Use a versioned directory archive containing a canonical JSON manifest, chunked
  newline-delimited records, per-chunk SHA-256 digests, and one whole-history digest.
  Rationale: The format must stream, resume, diff, copy with ordinary tools, and detect truncation
  or mutation without loading the history into memory.
  Date: 2026-07-31

- Decision: Preserve event IDs, stream IDs, stream versions, source global order, event type,
  payload bytes, metadata, and recorded time. If the target cannot preserve the source global
  position exactly, record a total source-to-target position map and use target positions for
  seeded checkpoints.
  Rationale: Identity and per-stream order are replay semantics. Pretending remapped global
  positions were preserved would make checkpoint seeding and audit evidence unsafe.
  Date: 2026-07-31

- Decision: Import only into an empty, schema-verified target event store in the first release.
  Rationale: Merging two non-empty global histories requires conflict and ordering semantics that
  are outside safe migration/bootstrap. A strict empty-target gate makes idempotent retry tractable.
  Date: 2026-07-31

- Decision: Checkpoints are never copied implicitly. A policy file names each subscription,
  source position, mapped target position, and disposition (`replay-from-start`, `seed`, or
  `omit`), and the report records the choice.
  Rationale: A checkpoint is a claim that all preceding events have been handled under the target
  handler semantics. History presence alone cannot justify that claim.
  Date: 2026-07-31

- Decision: Keep this audit follow-on as a standalone ExecPlan rather than reopening the completed
  migration-hardening MasterPlan.
  Rationale: Moving domain history is distinct from framework DDL integrity and needs an explicit,
  independently visible implementation boundary.
  Date: 2026-07-31


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`keiro-migrations/app/Main.hs` implements the `keiro-migrate` executable. The
`Keiro.Migrations` modules embed and apply framework SQL, while migration manifests/locks and
expected schemas protect DDL integrity. MasterPlan 13 documents the combined Keiro/Kiroku ledger,
safe apply path, `status`, `verify`, and operator ownership boundaries.

The event store is owned by `mori://shinzui/kiroku/packages/kiroku-store`. Keiro consumes its
`RecordedEvent`, `EventId`, `GlobalPosition`, stream read, transaction, and subscription APIs in
`keiro/src/Keiro/Command.hs`, `Projection.hs`, `DeadLetter/Replay.hs`, and read-model modules.
Before implementation, use Mori to locate the released Kiroku source and determine which public
APIs can export a consistent global range, append with supplied identities, and manage
checkpoints. Any required new bulk-import primitive belongs to Kiroku and must be released before
Keiro selects a dependency bound.

`keiro/src/Keiro/Snapshot.hs` treats snapshots as disposable accelerators; they are not required to
restore authoritative history. `ReadModel/Rebuild.hs` rebuilds materialized views after history is
available. `ReplayDigest.hs` provides canonical JSON digest support but the archive must hash exact
stored bytes and metadata as well as decoded domain views.

[ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) governs any new staging or
journal tables. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires archive and policy errors to fail before target writes. The completed
[MasterPlan 13](../masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md)
is historical context for DDL migration integrity; this standalone plan owns event-history movement.

“Archive” is the immutable portable representation. “Bootstrap” means apply verified framework
schema to an empty target and import history. “Restore” means reconstruct an empty target from a
Keiro archive. “Checkpoint seed” is an explicit target subscription position chosen by policy, not
an automatic copy. “Position map” relates source and target global positions when exact preservation
is unavailable.


## Plan of Work

Milestone 1 defines `docs/reference/history-archive-v1.md`, JSON schemas/fixtures, and library types
under `keiro-migrations/src/Keiro/Migrations/History/`. The manifest includes archive version,
source adapter and store schema versions, consistent lower/upper bounds, creation time, chunk
inventory/digests, event/stream counts, metadata policy, source checkpoints as evidence, and whole
history digest. Records preserve exact payload/metadata bytes using base64 where necessary. Add a
source-adapter interface and implement only the current Kiroku adapter first. If Kiroku lacks safe
consistent export or identity-preserving import, implement that minimal primitive in
`mori://shinzui/kiroku/packages/kiroku-store`, release it, and verify its registry/tag before
changing Keiro bounds.

Milestone 2 adds `keiro-migrate history export` and `history verify`. Export opens a repeatable-read
snapshot, captures a fixed head, streams ascending global pages into staged chunk files, fsyncs and
hashes them, writes the manifest last, then atomically renames the staging directory. `--resume`
may continue only if source identity, bounds, prior chunks, and tool/archive versions match.
Verification checks JSON schema, chunk and whole digests, event ID uniqueness, contiguous stream
versions, monotonic unique source global positions, bounds/counts, required metadata, and optional
application-supplied decoders without contacting a target. Redact secrets from reports and never
log payload bodies by default.

Milestone 3 adds `history bootstrap`, `history import`, `history restore`, and
`history seed-checkpoints`. Bootstrap first runs the existing schema `verify/status/apply` path,
then asserts the target event store, subscriptions, snapshots, and relevant Keiro operational
tables are empty. Import verifies the complete archive before writes, loads chunks through a
durable staging/journal protocol, validates each staged batch, commits authoritative events in
order, and records source/target position mappings plus completed chunk digests. Repeating the same
archive is a no-op; a different archive identity or conflicting row fails. Snapshots and read
models are rebuilt, not imported, in v1. Checkpoint seeding requires a checked policy file and
refuses positions not represented in the completed import or names already advanced on target.

Milestone 4 adds `history replay-verify` and an end-to-end disposable-PostgreSQL suite. Register
aggregate decoders/folds, replay imported streams, compare per-stream final digests and failure
locations, then optionally invoke supported read-model rebuilds. Test corrupt/truncated chunks,
duplicate IDs, stream gaps, source mutation during export, target non-emptiness, crash between
chunks, exact retry, wrong archive retry, global-position remapping, unsafe checkpoint policy, and
successful backup/restore parity. Add migrations for import journal/map tables, expected schema and
lock updates, metrics, structured JSON reports, operator runbook, migration ownership guidance,
and changelog. Record durable archive/import invariants in a new ADR.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Locate Kiroku first:

```bash
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
```

Exercise the library, CLI, migrations, and disposable database:

```bash
cabal test keiro-migrations-test --test-options='--match=history.*archive'
cabal run keiro-migrate -- history export --source "$SOURCE_DATABASE_URL" --output "$ARCHIVE_DIR"
cabal run keiro-migrate -- history verify --archive "$ARCHIVE_DIR" --format json
cabal run keiro-migrate -- history bootstrap --target "$TARGET_DATABASE_URL" --archive "$ARCHIVE_DIR" --policy migration-policy.json
cabal run keiro-migrate -- history import --target "$TARGET_DATABASE_URL" --archive "$ARCHIVE_DIR" --policy migration-policy.json
cabal run keiro-migrate -- history replay-verify --target "$TARGET_DATABASE_URL" --archive "$ARCHIVE_DIR" --format json
cabal test keiro-migrations-test
cabal test keiro-test
cabal build all
nix flake check
```

The second import must report all chunks already complete with zero new events. `replay-verify`
must report matching event/stream counts, archive digest, mapped head, and zero replay failures.
Use disposable URLs and a `mktemp -d` archive in tests; never point automated acceptance commands
at a production database. Replace placeholders with the test harness commands and actual counts
during implementation.


## Validation and Acceptance

1. Export captures a fixed consistent source range while concurrent later appends are excluded.
   The manifest is written only after every chunk is durable, and identical source/range/options
   produce the same content digest.
2. Offline verification detects any byte mutation, truncation, missing/extra chunk, duplicate event
   ID, stream version gap/duplicate, non-monotonic global position, or manifest/count mismatch
   before a target write.
3. Bootstrap/import refuses a non-empty or schema-drifted target. A verified archive imports event
   identities, stream order, payload/metadata, and recorded times exactly; global positions are
   either exact or covered by a complete persisted mapping.
4. Crash/restart resumes at the last committed chunk. Re-importing the same archive is a no-op;
   importing a different archive or conflicting identity into the journal fails without partial
   overwrite.
5. Checkpoints are omitted unless the policy explicitly names them. Each seeded target position is
   mapped from an imported source position, cannot move an existing target checkpoint backward or
   skip unverified history, and is included in the signed/digested report.
6. Snapshots/read models are not trusted as authoritative archive contents. Full aggregate replay
   succeeds on target, per-stream final digests match, and supported projections can rebuild.
7. Backup followed by restore into a second empty target yields the same archive/history digest and
   replay results. Reports contain no payload bodies or connection secrets by default.
8. New database objects pass migration manifest/lock/native parity and expected-schema checks.
   Documentation distinguishes DDL migration, history import, checkpoint policy, and cutover.


## Idempotence and Recovery

Export writes into a uniquely resolved staging directory and publishes by atomic rename; an
incomplete staging directory can be verified and resumed or moved aside, never mistaken for a
complete archive. Verification is read-only. Import is append-only into an asserted-empty target
and journals each chunk digest in the same transaction as its events/mappings, making exact retry
safe.

History import is materially destructive only if an operator later abandons the target; the tool
must not offer an automatic “wipe and retry” flag. On failure, preserve staging/journal evidence,
fix the source archive or target schema, and resume only when identities match. To restart from
scratch, the operator creates a new empty target database or follows an explicit documented
database disposal procedure outside this command. Checkpoint seeding writes only after complete
import verification and can be previewed with `--dry-run`.


## Interfaces and Dependencies

`Keiro.Migrations.History.Archive`, `.Export`, `.Verify`, `.Import`, and `.CheckpointPolicy` must
expose typed equivalents of:

```haskell
newtype ArchiveVersion = ArchiveVersion Natural
newtype ArchiveId = ArchiveId Text

data HistoryRecord = HistoryRecord
  { sourceGlobalPosition :: Int64
  , eventId :: UUID
  , streamName :: Text
  , streamVersion :: Int64
  , eventType :: Text
  , payloadBytes :: ByteString
  , metadataBytes :: ByteString
  , recordedAt :: UTCTime
  }

data CheckpointDisposition = ReplayFromStart | SeedAt Int64 | Omit

verifyArchive :: ArchivePath -> IO (Either (NonEmpty ArchiveError) VerifiedArchive)
importArchive :: ImportOptions -> VerifiedArchive -> IO (Either ImportError ImportReport)
```

Only `VerifiedArchive` may enter import. The Kiroku adapter must use released APIs from
`mori://shinzui/kiroku/packages/kiroku-store`; required upstream changes need an authoritative
release/tag check before dependency bounds change. SHA-256 and canonical JSON dependencies should
reuse Keiro's existing cryptographic/canonicalization stack where their byte contracts match; the
archive hashes exact record encodings, not decoded/re-encoded JSON. The CLI extends
`keiro-migrations/app/Main.hs` but keeps history commands explicitly namespaced.


Revision note: Detached this plan from the completed migration-hardening MasterPlan and clarified
that event-history movement is an independent implementation unit, 2026-07-31.
