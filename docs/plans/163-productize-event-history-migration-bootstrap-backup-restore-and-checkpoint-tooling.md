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

After this change, teams can move an existing Kiroku event history onto a fresh Keiro/Kiroku
deployment with supported operator tooling rather than one-off SQL. The tooling creates a
portable, checksummed archive of the event store's logical state; verifies identities, ordering,
JSON values, stream topology, and subscription evidence before writing; bootstraps an empty
target; imports or restores the archive idempotently; seeds only explicitly approved
subscription checkpoints; and emits a machine-readable report. It ships as a separate
`keiro-history` package and executable rather than expanding the schema-focused `keiro-migrate`
command. Backup and restore use the same archive reader and importer as migration, so routine
adoption and restore drills exercise the same recovery path.

### Benefits

The main benefit is a smaller cutover failure surface. Operators get one reviewed path with
pre-write verification, an empty-target gate, crash-safe retry, and evidence that the target
contains the same logical history and stream topology as the source. The portable archive also
decouples extraction from loading: it can be copied, independently verified, retained for audit,
and restored into disposable databases without keeping the source online. Using one versioned
format for migration and event-history backup prevents the usual problem where a recovery path is
documented but rarely exercised. Explicit checkpoint policy makes hidden data loss less likely,
because a cursor is treated as a claim about completed handling rather than as data that is safe
to copy automatically. Application-owned replay verification then proves that the candidate
service binary can still decode and fold the imported history before traffic moves.

### Costs and limits

This is a high-cost capability, not a small CLI addition. The first milestone requires a
cross-repository Kiroku API and release because `kiroku-store-0.3.1.0`, the current Hackage and
upstream-tagged release at plan validation time, has no consistent raw-history snapshot or
identity-, position-, timestamp-, and topology-preserving bulk import API. Keiro must then own a
long-lived archive compatibility contract, import journal migrations, negative-path database
tests, stable report schemas, and operator documentation. A separate `keiro-history` package also
adds a Cabal component, Hackage artifact, changelog, release-order dependency, Nix/CI wiring, Mori
registration, and public API surface that must version with the rest of Keiro. Application teams
must compile a thin service-specific verifier that supplies their aggregate codecs/folds and
read-model definitions; the generic history executable cannot discover or execute arbitrary
Haskell application code.

Operators also pay real runtime costs: export holds a repeatable-read snapshot, meaning a
PostgreSQL transaction sees one stable database view for the whole export. A long-lived snapshot
can delay PostgreSQL's vacuum cleanup. Archive creation and verification consume sequential I/O,
CPU, and storage; import needs a fresh target plus journal space; and full replay/read-model rebuild
time grows with history size. The runbook must therefore measure archive bytes per event,
export/import throughput, replay duration, peak memory, and snapshot age on representative data
before scheduling a maintenance window. The target service must remain stopped or otherwise
credential-fenced throughout import and checkpoint seeding; the tool's advisory lock coordinates
other history commands but cannot stop an unaware application writer.

The archive contains production payloads and metadata. SHA-256 detects accidental corruption but
does not encrypt data or authenticate a manifest that an attacker can replace. Version 1 therefore
creates restrictive files, prints a manifest digest for out-of-band custody, accepts an expected
manifest digest on verify/import, and requires an operator-managed encrypted and access-controlled
transport/storage system. Built-in encryption, signing, incremental backup, point-in-time recovery,
and key management are out of scope. The archive is an event-store logical backup, not a full
PostgreSQL backup: it intentionally excludes Keiro inbox/outbox rows, workflow/timer state, dead
letters, application tables, roles/grants, and database settings. PostgreSQL physical backup/PITR
remains required for full disaster recovery.

An operator can prove success by exporting a source, verifying the archive offline, importing it
twice into a disposable target, observing that the second pass is a no-op, comparing the complete
stream/event/link catalog and canonical history digest, running the application-owned full replay
against source and target, rebuilding selected read models, and restoring the same archive into a
second empty target with the same result.


## Progress

- [ ] Milestone 1: define the archive and trust model, scaffold the separate `keiro-history`
  package, implement and release the required Kiroku raw snapshot/import/schema-check primitives,
  and verify the released dependency before changing Keiro bounds.
- [ ] Milestone 2: implement consistent export/backup and offline verification with deterministic
  semantic digests, restrictive artifact handling, and safely resumable staging.
- [ ] Milestone 3: implement empty-target bootstrap/import/restore, durable phase/chunk journals,
  exact Kiroku position/topology restoration, and explicit checkpoint seeding.
- [ ] Milestone 4: expose application-owned source/target replay verification and read-model rebuild
  integration without pretending the generic CLI can load service codecs.
- [ ] Milestone 5: add failure/recovery and parity integration tests, performance/capacity evidence,
  telemetry, operator docs, migration schema/locks, ADR distillation, and full validation.


## Surprises & Discoveries

- 2026-07-31: MasterPlan 13 hardened the former codd-based DDL migration path. The completed
  MasterPlan 19 is the current pg-migrate authority: it restored native lockfiles, ledger and live
  schema checks, startup status, and cutover safety. Neither initiative moves application event
  history or seeds subscription checkpoints.
- 2026-07-31: Mori resolves the event store to
  `mori://shinzui/kiroku/packages/kiroku-store`. Hackage's preferred versions and the upstream tag
  list both identify `kiroku-store-0.3.1.0` as current. Its public reads return `Data.Aeson.Value`
  after an optional `decodeHook`, while appends apply an optional `enrichEvent` hook and choose the
  append timestamp. Those APIs cannot safely implement a raw backup or restore without changing
  stored semantics.
- 2026-07-31: A Kiroku `$all` read carries the source stream's surrogate id in
  `RecordedEvent.originalStreamId` and its source version in `originalVersion`; the
  `streamVersion` field on that read is the global position. Stream names require
  `lookupStreamNames`. Global positions are strictly increasing opaque cursors and are not
  guaranteed to be dense, so verification must reject reversals/duplicates but allow gaps.
- 2026-07-31: Event rows alone are not a complete Kiroku logical backup. `kiroku.streams` carries
  stable surrogate ids, creation/deletion state, and `truncate_before`; `kiroku.stream_events`
  carries source and link topology. Consumer-group partition assignment hashes the source stream
  surrogate id, so changing those ids can invalidate per-member checkpoint meaning.
- 2026-07-31: `Keiro.ReplayAudit.auditTargets` and `Keiro.ReadModel.Rebuild` already provide the
  service-level replay and rebuild primitives, but both require application-owned values. The
  generic history process cannot dynamically discover aggregate codecs, folds, stream
  constructors, projections, or application table truncation actions.
- 2026-07-31: `keiro-migrations` is a schema package with a deliberately small dependency closure,
  while `keiro` does not depend on it. A new `keiro-history` package can depend on both `keiro` and
  `keiro-migrations` without a cycle, keeping archive/filesystem/runtime dependencies out of the
  migration library and leaving `keiro-migrate` focused on DDL. The new package requires explicit
  `cabal.project`, Nix/CI, `mori.dhall`, `justfile`, and release-skill integration.


## Decision Log

- Decision: Ship archive, export, verification, import, restore, and checkpoint orchestration in a
  new `keiro-history` package with a `keiro-history` executable; do not add a `history` branch to
  `keiro-migrate`. Keep Kiroku raw snapshot/import primitives in the existing `kiroku-store`
  package, and keep only the Keiro-owned import-journal DDL in `keiro-migrations`.
  Rationale: History movement needs Kiroku runtime/database access, Aeson/hash/filesystem
  dependencies, long-running command behavior, and application replay integration. Those concerns
  do not belong in the schema package. `keiro-history` can depend on both `keiro` and
  `keiro-migrations` without creating a cycle, while one separate executable makes the sensitive
  operational boundary visible. This supersedes the earlier draft choice of
  `keiro-migrate history`.
  Date: 2026-07-31

- Decision: Use a versioned directory archive containing a canonical JSON manifest, chunked
  newline-delimited canonical JSON records, per-file SHA-256 digests, and a deterministic logical
  history digest that excludes volatile manifest fields such as creation time.
  Rationale: The format must stream, restart, diff, copy with ordinary tools, and distinguish
  repeatable logical content from one particular export attempt. Kiroku stores payload and metadata
  as JSONB, so the owned contract is canonical JSON value equality, not preservation of an input
  document's whitespace or key order.
  Date: 2026-07-31

- Decision: Archive Kiroku event rows, the complete stream catalog, every stream-event membership
  (including links), source/global positions, source stream ids, lifecycle markers, and checkpoint
  rows as evidence. Export/import bypass `decodeHook` and `enrichEvent` and operate on stored JSONB
  values.
  Rationale: Application hooks may decrypt, redact, enrich, or otherwise transform public values.
  Running them during backup/restore can leak plaintext or double-transform restored data. Stream
  topology and surrogate ids affect observable reads and consumer-group assignment and therefore
  cannot be reconstructed from events alone.
  Date: 2026-07-31

- Decision: Put consistent raw export, exact empty-store import, and Kiroku live-schema preflight
  behind released APIs owned by `mori://shinzui/kiroku/packages/kiroku-store`; do not issue
  Kiroku-internal write SQL from Keiro.
  Rationale: Kiroku owns the `kiroku` schema, trigger/sequence invariants, and stored representation.
  The current public append API cannot preserve timestamps, global positions, memberships, or raw
  values, and direct writes from Keiro would turn every Kiroku schema change into a hidden coupling.
  Date: 2026-07-31

- Decision: Version 1 supports Kiroku-to-Kiroku archives only and preserves event ids, stream ids
  and names, source versions, global positions (including gaps), stored JSON values, correlations,
  timestamps, link memberships, and lifecycle metadata exactly. Keep an identity source-to-target
  position map in the report/journal so a future non-Kiroku adapter can introduce explicit mapping
  without changing checkpoint evidence.
  Rationale: Empty-target exact restoration is safer and cheaper to reason about than implementing
  two ordering modes immediately. Other event stores may need mapping later, but that must be a new
  source-adapter/version capability rather than an accidental v1 behavior.
  Date: 2026-07-31

- Decision: Import only into a fresh schema-verified target, except that a partially populated
  target with a matching in-progress archive journal may resume. `keiro-history restore` and
  `keiro-history bootstrap` are thin orchestration presets over the same verified import engine;
  there is no second restore implementation.
  Rationale: Merging two non-empty global histories needs conflict and ordering semantics outside
  safe migration/bootstrap. One engine prevents backup restore and migration import from drifting.
  Date: 2026-07-31

- Decision: Checkpoints are never copied implicitly. A policy identifies subscription name,
  subscribed stream/category, consumer-group member and size, source position, identity-mapped
  target position, and disposition (`replay-from-start`, `seed`, or `omit`).
  Rationale: A checkpoint claims all preceding applicable events were handled under a particular
  handler and group topology. History presence alone cannot justify that claim, and restoring a
  member position under changed stream-id partitioning can skip work.
  Date: 2026-07-31

- Decision: Keep structural archive verification in the generic `keiro-history` executable, but
  run aggregate replay and read-model rebuild through its library called by a service-specific
  executable.
  Rationale: Haskell codecs/folds and application SQL actions are compile-time values. A generic CLI
  cannot load them honestly without inventing a plugin/build protocol; the existing replay and
  rebuild APIs already establish the correct application-owned boundary.
  Date: 2026-07-31

- Decision: Treat SHA-256 as accidental-corruption evidence, not authenticity or confidentiality.
  Version 1 relies on restrictive local permissions, an operator-supplied expected manifest digest,
  and external encrypted/authenticated custody; it is not a replacement for PostgreSQL PITR.
  Rationale: Bundling encryption, signing, keys, retention, and full operational-table recovery
  would greatly expand the threat model and still duplicate infrastructure operators already own.
  Date: 2026-07-31

- Decision: Keep this audit follow-on as a standalone ExecPlan rather than reopening a completed
  migration-hardening MasterPlan.
  Rationale: Moving domain history is distinct from DDL integrity. Its Kiroku prerequisite is an
  explicit first-milestone gate, and the remaining milestones form one incrementally testable
  operator workflow.
  Date: 2026-07-31


## Outcomes & Retrospective

- 2026-07-31: Plan validation completed without implementation. The capability is feasible, but
  the released Kiroku API is a hard prerequisite rather than an optional fallback. Validation
  corrected the archive's JSONB semantics, added missing causation/correlation and stream/link/
  lifecycle state, made global-position gaps legal, preserved stream ids for consumer groups,
  separated application replay from the generic CLI, defined the security/PITR boundary, and made
  engineering and operating costs explicit. No code or database migration has started.
- 2026-07-31: Package-boundary discussion moved the product surface out of
  `keiro-migrations` into a new `keiro-history` package and executable. Kiroku continues to own raw
  store primitives, and `keiro-migrations` continues to own only Keiro DDL. This adds release and
  build wiring but prevents a schema-only package and command from accumulating unrelated runtime,
  filesystem, replay, and backup responsibilities.


## Context and Orientation

`keiro-migrations/app/Main.hs` implements the schema-focused `keiro-migrate` executable. It parses
pg-migrate commands plus Keiro-owned `verify-schema` and `import-codd-history` commands and remains
unchanged by the history CLI work. `Keiro.Migrations` embeds and composes Kiroku and Keiro DDL
migrations; this package owns the new import-journal migration and expected-schema/lock updates,
but not archive or runtime code. The completed
[MasterPlan 19](../masterplans/19-restore-the-migration-integrity-gates-under-pg-migrate-surfaced-by-the-2026-07-migration-review.md)
is the current description of native manifests, pg-migrate ledger verification, Keiro live-schema
verification, and safe cutover ownership. [MasterPlan 13](../masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md)
is useful only as historical codd-era context.

Create `keiro-history/` as a new published Cabal package and add it to `cabal.project`. Its library
modules live under `keiro-history/src/Keiro/History/`; its executable entry point is
`keiro-history/app/Main.hs`; its tests and fixtures live under `keiro-history/test/`; and it has its
own `README.md` and `CHANGELOG.md`. The package depends on `keiro` for replay integration,
`keiro-migrations` for bootstrap/ledger/schema orchestration, and released Kiroku packages for raw
history operations. Neither `keiro` nor `keiro-migrations` depends on `keiro-history`, so the
existing libraries and `keiro-migrate` avoid a dependency cycle and do not acquire the new
filesystem/archive closure. Register the package in `mori.dhall`, add its test to `justfile` and
the default Nix/CI checks, and extend `agents/skills/release/SKILL.md` so it is published after both
`keiro` and `keiro-migrations`.

The event store is owned by `mori://shinzui/kiroku/packages/kiroku-store`, and its DDL component is
`mori://shinzui/kiroku/packages/kiroku-store-migrations`. Kiroku's current `RecordedEvent` contains
an event id/type, JSONB payload and optional metadata as `Data.Aeson.Value`, causation/correlation
ids, creation time, global position, source stream id, and original source version. A `$all` read
does not directly carry the source stream name and applies the configured `decodeHook` after SQL.
Normal append can accept an event id but chooses the append time and positions, applies
`enrichEvent`, and cannot create arbitrary link/catalog state. `Kiroku.Store.SQL` happens to be
exposed in 0.3.1.0, but that is not permission for Keiro to own Kiroku-internal writes.

Kiroku's logical state spans `kiroku.events`, `kiroku.streams`, and
`kiroku.stream_events`. `streams` includes the reserved `$all` row, stable ids, per-stream head,
creation/deletion timestamps, and `truncate_before`; `stream_events` includes source, `$all`, and
linked memberships. `kiroku.subscriptions` keys checkpoints by subscription name and
consumer-group member and also stores the subscribed stream, group size, and last-seen global
position. Dead letters are operational evidence and remain outside the v1 archive, as do all
Keiro-owned tables.

`keiro/src/Keiro/ReplayAudit.hs` can perform full or targeted replay when the caller supplies
`SomeAuditTarget` values. `keiro/src/Keiro/ReadModel/Rebuild.hs` owns the fenced rebuild lifecycle,
but the caller supplies each `ReadModel`, projection names, and application-specific replay loop.
`keiro/src/Keiro/ReplayDigest.hs` uses Aeson's `Data.Aeson.RFC8785.encodeCanonical` and SHA-256.
Archive code in `keiro-history` should use that same Aeson primitive directly; add a golden test
against the replay digest so both encodings remain identical.

[ADR 3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md) establishes
that snapshots are disposable cache seeds and event history is authoritative.
[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires
archive, policy, and replay errors to fail at the earliest boundary with enough evidence.
[ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) separates ledger
verification from live-schema verification, which is why the Kiroku import primitive needs its own
schema preflight rather than relying only on pg-migrate's ledger.
[ADR 10](../adr/0010-keiro-guards-fresh-native-history-over-codd-ledgers.md) supplies the existing
quiescent-cutover and explicit-override precedent. No existing ADR defines the archive, exact
restore, or checkpoint policy; implementation must create one after the invariants are proven.

“Archive” means the immutable logical event-store representation. “Bootstrap” applies verified
framework DDL to a fresh target and then calls the import engine. “Restore” is the backup-oriented
name for the same orchestration, not a separate loader. “Checkpoint seed” is an explicit target
cursor chosen by policy. “History digest” is a deterministic digest of logical archived records;
“manifest digest” identifies one manifest and anchors its chunk inventory for out-of-band custody.


## Plan of Work

Milestone 1 is a feasibility and ownership gate. In the Kiroku repository, add a public raw-history
module to `kiroku-store` that can hold one read-only repeatable-read snapshot across all pages,
return the fixed `$all` head, stream catalog, stored event values, every membership/link, and
subscription evidence without applying interpreter hooks. Add a Kiroku-owned import transaction
primitive that validates the live Kiroku catalog, imports one verified batch into an empty store
while preserving ids/positions/timestamps, restores memberships and lifecycle markers in explicit
phases, resets sequences/heads, and reports invariant failures without exposing arbitrary internal
SQL to Keiro. Prove empty-store, gap, link, deleted/truncated stream, consumer-group, hook-bypass,
crash rollback, and sequence-reset cases in Kiroku's disposable-PostgreSQL suite. Release the
package, verify Hackage preferred versions and upstream tags, and only then change Keiro's bound.
If these primitives cannot preserve the stated state, stop: the fallback is PostgreSQL-native
backup, not Keiro-issued direct writes.

In the same milestone, write `docs/reference/history-archive-v1.md` and checked JSON schemas and
fixtures under `keiro-history/test/fixtures/history-archive/v1/`. Scaffold
`keiro-history/keiro-history.cabal`, `keiro-history/src/Keiro/History/`,
`keiro-history/app/Main.hs`, and `keiro-history/test/Main.hs` and wire the package into
`cabal.project` without adding it as a dependency of `keiro` or `keiro-migrations`. The directory
format contains `manifest.json`, global-order event chunks, `streams.ndjson`,
`memberships.ndjson`, and `checkpoints.ndjson`. The manifest records format and adapter versions,
source schema/migration identity, opaque lower/upper cursors, export attempt time, file
inventory/digests, event/stream/link and checkpoint counts, a metadata handling statement, and the
logical history digest. Event rows preserve payload/metadata as nested canonical JSON values plus
causation/correlation ids; they do not base64-wrap JSONB or claim to preserve pre-JSONB textual
formatting.

Milestone 2 adds `Keiro.History.Archive`, `.Export`, `.Verify`, `.Digest`, and CLI parsing in the
new package for `keiro-history export` and `keiro-history verify`. Export opens the Kiroku raw
snapshot, captures a fixed head, streams ascending global pages into a permission-restricted
staging directory, writes canonical records with bounded memory, fsyncs and hashes files, writes
the manifest last, fsyncs the parent directory, and atomically renames staging to the final path on
the same filesystem.
Global cursors need only be strictly increasing; source stream versions are one-based and
contiguous within each retained source stream. Verification checks the JSON schemas, file and
logical digests, event-id uniqueness, source-stream ids/names/versions, membership references and
uniqueness, stream heads/lifecycle markers, bounds/counts, correlation fields, and checkpoint
topology without contacting a target. It never logs payload bodies or connection secrets.

Cross-process `--resume` cannot reuse a PostgreSQL snapshot after the exporting process dies.
Therefore resume opens a new repeatable-read snapshot, re-reads and re-hashes every already
completed logical prefix plus all mutable catalog/checkpoint files, and continues only if they
match the staged metadata and the original upper bound is still present. Later appends above that
bound are ignored; deletion, lifecycle, link, or checkpoint changes make resume fail closed and
instruct the operator to start a new export. This saves rewriting verified chunks but does not
pretend snapshot identity survived a crash.

Milestone 3 adds native Keiro migrations for `keiro.keiro_history_imports`,
`keiro.keiro_history_import_chunks`, and `keiro.keiro_history_position_map`, plus
`Keiro.History.Import` and `.CheckpointPolicy` in `keiro-history`. The SQL, manifest/native-lock,
and expected-schema changes remain in `keiro-migrations`, but their Haskell consumers live in the
new package. `keiro-history import` requires DDL to be present and verified;
`keiro-history bootstrap` calls the public `Keiro.Migrations` orchestration to run the combined
pg-migrate `up`, ledger verification, Keiro live-schema verification, and Kiroku import preflight
before delegating to import; `keiro-history restore` delegates to the same orchestration with
backup-oriented report wording. Every mutating command acquires one shared history advisory lock.
The runbook additionally requires application processes stopped and target write credentials
fenced because advisory locks are only cooperative.

Before its first write, import verifies the entire archive and optional expected manifest digest
and then, in one transaction, either establishes an import journal against an empty target or
recognizes the same in-progress/completed archive. A different archive or unjournaled target data
fails. Event chunks, link memberships, and final stream metadata are separate journaled phases;
each chunk digest is recorded in the same transaction as the Kiroku import primitive's writes.
Finalization validates every count, head, reference, sequence, canonical value, and identity
position map before marking the import complete. Repeating a completed import is a no-op. The
command never offers wipe-and-retry.

`keiro-history import`, `keiro-history bootstrap`, and `keiro-history restore` may invoke checkpoint
seeding after successful finalization when `--checkpoint-policy` is present;
`keiro-history seed-checkpoints` exposes the same engine independently. Its policy schema names
each subscription target, consumer-group member/size, archived source position, mapped target
position, and disposition. `replay-from-start` establishes or confirms position zero with the
declared topology; `seed` establishes or confirms the exact mapped position; `omit` writes
nothing. The command rejects unknown checkpoints, topology changes, positions absent from the
archive/map, a target position beyond verified history, any pre-existing conflicting/advanced
row, and any attempt to move backward. `--dry-run` renders the identical decision report without
writes.

Milestone 4 adds `Keiro.History.ReplayVerify` to the `keiro-history` library. It accepts
application-provided `[SomeAuditTarget]`, runs `AuditFull` against source and target with snapshots
disabled/absent, renders a stable JSON report, and compares accepted/rejected stream sets,
versions, failures, divergences, and final state digests. For an offline restore where the source
is unavailable, it still requires successful full target replay and relies on archive/import
parity for source equality. Add a documented service-owned executable pattern that depends on
`keiro-history` and compiles this library with the service's generated `auditTargets`. Read-model
rebuild remains an explicit application command built from `startRebuild`, replay through
`applyAsyncProjectionUnfenced`, verification, and `finishRebuild`; the generic history CLI only
records whether the operator supplied successful replay/rebuild reports.

Milestone 5 adds end-to-end disposable-PostgreSQL coverage for corrupt/truncated/extra chunks,
manifest substitution, duplicate ids, stream gaps/duplicates, legal global gaps, dangling or
duplicate memberships, link/lifecycle parity, source mutation during resume, raw-hook bypass,
target non-emptiness, concurrent command exclusion, application-writer precondition docs, crash at
every phase boundary, exact retry, wrong-archive retry, unsafe group checkpoint policy, source/
target replay parity, and backup/restore parity. Add structured metrics and reports, operator and
migration-ownership documentation, a changelog entry, migration manifest/native-lock/schema
snapshot updates, and a representative performance drill reporting events/second, bytes/event,
peak RSS, source snapshot age, and replay/rebuild duration without declaring an unmeasured SLA.
Add `keiro-history` to `mori.dhall`, `justfile`, the default Nix/CI package set, and the release
skill/package order after `keiro` and `keiro-migrations`. Create or update the archive/import ADR
after the implementation proves these invariants.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Reconfirm dependency ownership and the current
release before implementation:

```bash
mori registry search kiroku-store
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
mori path mori://shinzui/kiroku/packages/kiroku-store
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
git ls-remote --tags https://github.com/shinzui/kiroku.git 'kiroku-store-v*'
```

After the upstream milestone, validate Kiroku in its registered checkout and confirm the release
artifact before changing Keiro bounds:

```bash
KIROKU_ROOT="$(mori path mori://shinzui/kiroku | tail -n 1)"
cd "$KIROKU_ROOT"
cabal test kiroku-store-test
cabal test kiroku-store-migrations-test
```

Kiroku-repository commits must use the cross-repository trailer
`ExecPlan: mori://shinzui/keiro/plans/163-productize-event-history-migration-bootstrap-backup-restore-and-checkpoint-tooling`.
Keiro-repository commits use
`ExecPlan: docs/plans/163-productize-event-history-migration-bootstrap-backup-restore-and-checkpoint-tooling.md`.
The artifact-level URI may not resolve until Mori's registry is refreshed; the intended canonical
URI is still the durable cross-repository reference.

Exercise archive, CLI, migrations, and disposable database behavior in this repository:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-history-test
cabal test keiro-migrations-test --test-options='--match=history'
cabal run keiro-history -- export --source-database-url "$SOURCE_DATABASE_URL" --output "$ARCHIVE_DIR" --purpose migration --json
cabal run keiro-history -- verify --archive "$ARCHIVE_DIR" --expected-manifest-sha256 "$MANIFEST_SHA256" --json
cabal run keiro-history -- bootstrap --database-url "$TARGET_DATABASE_URL" --archive "$ARCHIVE_DIR" --checkpoint-policy migration-policy.json --expected-manifest-sha256 "$MANIFEST_SHA256" --json
cabal run keiro-history -- import --database-url "$TARGET_DATABASE_URL" --archive "$ARCHIVE_DIR" --checkpoint-policy migration-policy.json --expected-manifest-sha256 "$MANIFEST_SHA256" --json
cabal run keiro-history -- seed-checkpoints --database-url "$TARGET_DATABASE_URL" --archive "$ARCHIVE_DIR" --policy migration-policy.json --dry-run --json
cabal run keiro-history -- restore --database-url "$RESTORE_DATABASE_URL" --archive "$ARCHIVE_DIR" --expected-manifest-sha256 "$MANIFEST_SHA256" --json
cabal test keiro-migrations-test
cabal test keiro-history-test
cabal test keiro-test
cabal build all
nix flake check
```

The second import must report the same archive id, every phase/chunk already complete, and zero new
events, streams, memberships, or checkpoints. Bootstrap and restore reports must contain matching
event/stream/membership counts, history digest, exact mapped head, and manifest digest. The
service-specific verifier must report equal source/target full-replay stream sets and digests with
zero failures/divergences before cutover. Use disposable URLs and a `mktemp -d` archive in tests;
never point automated acceptance commands at a production database. Replace fixture placeholders
with actual counts and captured concise output during implementation.

If implementation creates or changes the planned ADR, validate its profiled OKF bundle:

```bash
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
just check-adr
```


## Validation and Acceptance

1. `keiro-history` is an independently buildable/publishable package with a `keiro-history`
   executable. `keiro-migrate --help` remains schema-focused and has no history branch;
   `keiro-migrations` gains only the journal DDL and its lock/schema evidence. The new package is
   present in `cabal.project`, `mori.dhall`, Nix/CI, `justfile`, and the release workflow after its
   `keiro` and `keiro-migrations` dependencies.
2. A Kiroku release exposes and tests raw snapshot/import primitives that bypass hooks, own all
   Kiroku schema writes, verify the required live catalog, and preserve ids, positions, timestamps,
   stream/link topology, lifecycle state, and sequence/head invariants. Keiro selects that released
   version only after Hackage and the upstream tag agree.
3. Export captures the event, stream, membership, lifecycle, and checkpoint-evidence files from one
   repeatable-read snapshot at a fixed opaque head. Concurrent later appends are excluded. Equal
   logical state produces the same history digest even though attempt timestamps differ.
4. Resume re-reads and hashes the staged prefix and mutable catalog under a new snapshot. It accepts
   later appends above the fixed head but rejects deletion, changed rows/topology/checkpoints, a
   missing upper bound, changed options/version, or any staged-byte mismatch.
5. Offline verification detects any byte mutation, truncation, missing/extra file, manifest
   substitution when an expected digest is supplied, duplicate event id, source-version gap or
   duplicate, global-position reversal/duplicate, dangling/duplicate membership, illegal stream
   head/lifecycle marker, topology mismatch, or manifest/count mismatch before a target write.
   Legal gaps in opaque global positions pass.
6. Bootstrap/import refuses a schema-drifted, concurrently locked, or non-empty target. A verified
   Kiroku archive restores exact event ids, stream ids/names, source/global positions, stored JSONB
   values, causation/correlation, times, links, deleted/truncated state, and heads. Import never
   invokes enrichment/decode hooks.
7. Crash/restart resumes at the last committed phase/chunk. Re-importing the same archive is a
   no-op; a different archive, altered digest, or unjournaled/conflicting row fails without
   overwrite. No command offers an automatic wipe.
8. Checkpoints are omitted unless policy explicitly names their target and complete group topology.
   Dry-run and apply agree. Seeded positions exist in the completed identity map, cannot conflict,
   move backward, or exceed verified history, and remain idempotent on exact retry.
9. Snapshots, read models, dead letters, inbox/outbox, workflow/timer state, and application tables
   are absent from the archive and are described as such. The application-owned full replay
   succeeds against target; when source is available, stream sets, versions, and final state digests
   match. Supported projections rebuild through the fenced lifecycle.
10. Backup followed by restore into a second empty target yields the same event/stream/membership
   catalog, exact positions/heads, history digest, and replay results. This proof does not claim
   point-in-time or full-database recovery.
11. Archive directories/files are created with restrictive permissions where the platform permits;
    reports contain no payloads or connection secrets; documentation states that hashes are not
    encryption/authentication and demonstrates out-of-band expected-manifest-digest use.
12. A representative large fixture records events/second, bytes/event, peak RSS, source snapshot
    duration/age, import duration, replay duration, and rebuild duration. Memory stays bounded by
    configured page/chunk/concurrency limits, and the runbook turns the measurements into source
    vacuum, free-space, and maintenance-window guidance rather than an invented universal SLA.
13. New database objects pass migration manifest/native-lock checks, expected-schema validation,
    strict ADR profile validation when applicable, all package tests, `cabal build all`, and
    `nix flake check`. Documentation distinguishes DDL migration, logical history backup/import,
    checkpoint policy, application replay, PostgreSQL PITR, and cutover/rollback.


## Idempotence and Recovery

Export writes into a unique staging directory beside the requested final directory and publishes
only by same-filesystem atomic rename after every file and the parent directory are durable. An
incomplete stage is never a valid archive. `--resume` performs the new-snapshot prefix/catalog
revalidation described above; if it fails, preserve or move the stage for evidence and start a new
output path. Offline verification is read-only.

Import is append-only into either a genuinely empty target or a target whose partial state is fully
accounted for by the same archive journal. The shared advisory lock prevents two history commands
from interleaving, and each phase/chunk journal record commits with its Kiroku writes. Because an
ordinary application does not honor that lock, the operator must stop the target service and fence
its credentials before the initial emptiness check and keep it fenced through final verification
and checkpoint seeding.

The tool never mutates the source and never offers target cleanup. On failure, retain archive,
reports, and import journals; correct schema/capacity/policy issues and resume only when identities
and digests match. To restart from scratch, create a new empty target database or follow a separate,
explicitly reviewed disposal procedure outside this command. Keep the source read-only and
available until target replay/read-model verification and cutover acceptance complete; rollback
before new target writes means returning traffic to that source. After target-only writes begin,
rollback requires a separately planned forward migration and is not promised by this tooling.

Checkpoint seeding happens only after complete import verification and supports `--dry-run`.
Application replay is read-only. Read-model rebuild uses its existing fence and abandonment path so
queries never expose a partial rebuild. Full operational recovery still follows the service's
PostgreSQL physical backup/PITR procedure because this archive intentionally omits operational and
application-owned tables.


## Interfaces and Dependencies

The new `keiro-history` library should expose typed equivalents of the following. Names may adjust
to local style, but fields and semantic distinctions are required:

```haskell
newtype ArchiveVersion = ArchiveVersion Natural
newtype ArchiveId = ArchiveId Text

data HistoryRecord = HistoryRecord
  { sourceGlobalPosition :: Int64
  , eventId :: UUID
  , sourceStreamId :: Int64
  , sourceStreamName :: Text
  , sourceStreamVersion :: Int64
  , eventType :: Text
  , payload :: Value
  , metadata :: Maybe Value
  , causationId :: Maybe UUID
  , correlationId :: Maybe UUID
  , recordedAt :: UTCTime
  }

data StreamRecord = StreamRecord
  { sourceStreamId :: Int64
  , streamName :: Text
  , streamHead :: Int64
  , createdAt :: UTCTime
  , deletedAt :: Maybe UTCTime
  , truncateBefore :: Int64
  }

data MembershipRecord = MembershipRecord
  { eventId :: UUID
  , memberStreamId :: Int64
  , memberStreamVersion :: Int64
  , sourceStreamId :: Int64
  , sourceStreamVersion :: Int64
  }

data SourceCheckpoint = SourceCheckpoint
  { subscriptionName :: Text
  , subscribedStream :: Text
  , consumerGroupMember :: Int32
  , consumerGroupSize :: Int32
  , lastSeen :: Int64
  }

data CheckpointDisposition = ReplayFromStart | SeedAt Int64 | Omit

verifyArchive :: VerifyOptions -> ArchivePath -> IO (Either (NonEmpty ArchiveError) VerifiedArchive)
importArchive :: ImportOptions -> VerifiedArchive -> IO (Either ImportError ImportReport)
```

The released Kiroku API must expose typed raw equivalents plus a snapshot bracket and transaction
import primitives; Keiro must not import a Kiroku `Internal` module or duplicate its DDL:

```haskell
withHistorySnapshot
  :: ConnectionSettings
  -> (HistorySnapshot -> IO a)
  -> IO (Either HistoryExportError a)

readHistoryPage
  :: HistorySnapshot
  -> GlobalPosition
  -> Int32
  -> IO (Vector StoredHistoryEvent)

validateHistoryImportTargetTx
  :: ExpectedImportState
  -> Tx.Transaction (Either HistoryImportError VerifiedImportTarget)

importHistoryEventsTx
  :: VerifiedImportTarget
  -> Vector StoredHistoryEvent
  -> Tx.Transaction (Either HistoryImportError ImportBatchResult)

restoreMembershipsTx
  :: VerifiedImportTarget
  -> Vector StoredMembership
  -> Tx.Transaction (Either HistoryImportError ())

finalizeHistoryImportTx
  :: VerifiedImportTarget
  -> StoredCatalog
  -> Tx.Transaction (Either HistoryImportError ImportSummary)
```

The exact upstream API may use a session/token rather than these names, but it must hold one
repeatable-read snapshot, make raw-hook bypass explicit, keep the target proof scoped to the same
transaction/import identity, and prevent callers from constructing a forged
`VerifiedImportTarget`. Keiro refreshes that proof in each chunk transaction from expected counts,
heads, and phases in its matching journal; the proof means “empty or exactly the journaled prefix,”
not “still empty after the first chunk.”

Only `VerifiedArchive` may enter import. Aeson's `Data.Aeson.RFC8785.encodeCanonical` defines JSON
value bytes; SHA-256 and lower-case base16 reuse the same packages as `Keiro.ReplayDigest` without
adding a package-layering inversion. The archive hashes exact canonical record/file encodings, not
decoded/re-encoded application views. `keiro-history` adds the required Aeson/hash/filesystem,
Kiroku, `keiro`, and `keiro-migrations` dependencies; `keiro-migrations` adds no archive/runtime
dependencies. The application verification API is `Keiro.History.ReplayVerify` in
`keiro-history` and consumes `SomeAuditTarget`; service executables provide those values and any
read-model rebuild actions.

`keiro-history/keiro-history.cabal` exposes the archive/import/replay library, defines the
`keiro-history` executable, and defines `keiro-history-test`. It depends on released
`kiroku-store`/`kiroku-store-migrations`, `keiro`, and `keiro-migrations`; those packages do not
depend back on it. `keiro-migrations` owns only the SQL migration and expected-schema/native-lock
evidence for the import journal. Update the release workflow to publish `keiro-history` after both
internal dependencies are available on Hackage.

The executable has strict top-level `export`, `verify`, `bootstrap`, `import`, `restore`, and
`seed-checkpoints` subcommands. All human and JSON report formats carry an explicit schema version,
archive id, history digest, manifest digest, source/target heads, phase/chunk outcomes, checkpoint
decisions, and redacted error codes. JSON keys are append-only within a schema version and readers
must ignore unknown keys.


Revision note: Detached this plan from the completed migration-hardening MasterPlan and clarified
that event-history movement is an independent implementation unit, 2026-07-31.

Revision note: Validated the plan against the current Keiro/Kiroku code and released Kiroku 0.3.1.0;
made the upstream raw-history release a hard first milestone; corrected JSONB, global/source
position, topology, lifecycle, hook, replay-ownership, and resume assumptions; and added explicit
benefit, engineering/operating cost, security, backup-scope, and PITR boundaries, 2026-07-31.

Revision note: Moved the product surface from a proposed `keiro-migrate history` namespace into a
separate published `keiro-history` package and executable. Kept Kiroku raw operations in
`kiroku-store` and Keiro journal DDL in `keiro-migrations`, and added the resulting Cabal, Mori,
Nix/CI, test, and release-workflow costs, 2026-07-31.
