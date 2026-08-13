---
id: 255
slug: fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface
title: "Fence out-of-process read-model reads behind a sanctioned SQL surface"
kind: exec-plan
created_at: 2026-08-12T23:55:46Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
master_plan: "docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md"
---

# Fence out-of-process read-model reads behind a sanctioned SQL surface

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan implements capability 1 of
`docs/improvement-requests/make-read-models-safely-readable-by-out-of-process-consumers.md`
(IR-22), as EP-2 of
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md`
(MasterPlan 41). Read both before starting; this plan repeats everything needed to
execute, but the IR carries the requester's full motivation.


## Purpose / Big Picture

Keiro's read-model rebuild fence is enforced entirely at Haskell call boundaries.
A non-Haskell process that holds its own PostgreSQL connection and issues `SELECT`
against a read-model table participates in none of them. During a rebuild of a group
containing a `ClearBeforeReplay` target, that external reader observes a table that
was just truncated, then a table progressively refilling from the beginning of
history — a coherent, queryable, *historical* picture of the world — and nothing
errors. For the requesting consumer (`mori://tan/notification-render-service`, a
stateless TypeScript render process reading a Keiro read model over SQL), that means
successfully rendering and delivering wrong content, with no retry and no alert,
because from the system's point of view nothing failed.

After this plan, an application can mark a catalog-bound read model as externally
readable — in a `.keiro` spec with a new `external-readers = [ "consumer-name" ]`
clause, or in a hand-written catalog by populating a new `externalReaders` field on
`QueryModelBinding`. Catalog registration then creates, in a new Keiro-owned
PostgreSQL schema named `keiro_read`, a SQL function per externally readable query
model. Any SQL client can call that function. While the model's rebuild group is in
live service the function returns the model's current rows; while the group is
rebuilding or failed the function raises a documented, frozen error code —
SQLSTATE `KR001` — whose message names the model, the group, its status, and the
active rebuild run. A reader can therefore always distinguish "the model is
rebuilding" from "no row matched", which is the entire point.

You can see it working from psql: start a rebuild of a `ClearBeforeReplay` group,
call the generated function from a second connection and watch it raise `KR001`;
promote the rebuild and watch the same call return correct current rows. A DB-backed
test proves the same sequence in CI.

This plan also fixes the read surface's shape for the future: generated functions
never reference application tables directly. They read through a per-target view in
`keiro_read` that names "the current live physical relation of this target", which is
the indirection `docs/plans/256-rebuild-into-versioned-targets-with-atomic-cutover.md`
will later re-point during atomic cutover without changing anything an external
reader sees.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] M1: Add `ExternalReaderName` + `mkExternalReaderName` to
      `keiro/src/Keiro/Projection/Catalog.hs` and the `externalReaders` field to
      `QueryModelBinding`.
- [ ] M1: Thread the field through `QueryFacts`, `buildInventory`,
      `InventoryQueryModel`, and `renderInventory`; add the
      `ExternalReadBinding` derived accessor.
- [ ] M1: Add runtime validation diagnostics `DuplicateExternalReaderName` and
      `ExternalReadBackingUnresolved` with stable code text.
- [ ] M1: Compile-fix every `QueryModelBinding` construction site (`jitsurei`,
      `keiro/test/*`, `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emitter with an empty
      list) and regenerate the conformance corpus.
- [ ] M1: Pure tests: validation diagnostics, name derivation, fingerprint
      stability (`catalog-v3:`/`slice-v2:` unchanged when `externalReaders` toggles).
- [ ] M2: keiro-migrations `0026.sql` creating schema `keiro_read` (+ manifest,
      native lock, changelog entry, `docs/user/migrations.md` grants).
- [ ] M2: New module `Keiro.Projection.Catalog.ExternalRead`: name derivation,
      DDL rendering (guard, views, functions), `reconcileExternalReadSurfaceTx`.
- [ ] M2: Wire reconciliation into `registerProjectionCatalogTx` and the adoption
      transaction; add the `ExternalReadSchemaMissing` typed errors.
- [ ] M2: DB-backed `keiro/test/ExternalReadSurfaceSpec.hs` written red-first
      (hazard characterization, KR001 during rebuild, rows after promotion, KR002,
      guard composition, reconciliation idempotence and removal).
- [ ] M2: Capture the psql acceptance transcript into this plan.
- [ ] M3: `.keiro` clause `external-readers = [ "..." ]`: grammar field, parser,
      pretty-printer, DSL validation diagnostics, scaffold lowering, ledger fact,
      diff finding + compatibility classification, harness fact.
- [ ] M3: Fixtures, `keiro-dsl/test/Main.hs` tests, fixture inventories
      (`test/Main.hs` non-stable list + `conformance-baseline.json`), corpus
      regeneration, `docs/corpus/keiro-dsl-corpus.md` counts.
- [ ] M3: Amend `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
      frozen clause-spelling list; `docs/user/typed-spec-toolchain.md`;
      `agents/skills/keiro-dsl-authoring/NOTATION.md`.
- [ ] M4: `docs/user/read-models-and-projections.md` out-of-process reader section;
      capabilities docs; jitsurei adoption + guide transcript.
- [ ] M4: New ADR via `okf id next` (external read contract; 254 and 256 also allocate ADRs — take whatever handle is next free at landing time), ADR-26 related-decisions line,
      `okf validate` + `okf log add`.
- [ ] M4: CHANGELOG entries (keiro, keiro-dsl, keiro-migrations); MasterPlan 41
      registry status; `just verify` green; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Ship the generated SQL read API (IR-22 capability 1, first shape) and
  exclude privilege-based fencing (second shape).
  Rationale: privilege fencing requires Keiro to own `GRANT`/`REVOKE` against roles
  it does not manage — this repository deliberately keeps roles and grants
  operator-owned (`docs/user/migrations.md` "Runtime role privileges";
  `docs/plans/87-scope-codd-expected-schema-to-the-keiro-namespace-and-remove-the-role-and-owner-leak.md`
  removed roles from the expected schema on purpose). A permission-denied error is
  also not attributable: a reader cannot distinguish "rebuilding" from
  "misconfigured grant", failing IR-22's loud-and-attributable bar. Finally,
  revoke-at-prepare/restore-at-promote fights EP-3's zero-downtime cutover, where
  the fence becomes a backstop rather than a window. The declaration deliberately
  records opaque consumer *names*, not roles, so a privilege layer could still be
  added later without changing the catalog surface.
  Date: 2026-08-12
- Decision: All generated objects live in a dedicated schema `keiro_read`. The
  schema itself ships as keiro-migrations `0026.sql`; its *contents* (guard
  function, per-target views, per-binding functions) are created and reconciled by
  `registerProjectionCatalog`/`adoptCatalogGroups` inside their existing
  transactions, not by migrations.
  Rationale: the per-binding objects are a function of the application's catalog,
  which migrations cannot know; registration is already the transactional point
  where query bindings are persisted, so surface and registration can never skew.
  The migration body lint (`keiro-migrations/test/Lint.hs`) forbids any mention of
  `search_path` in migration files, which conflicts with `SECURITY DEFINER`
  hygiene (`SET search_path` on the function), so function DDL cannot ship as a
  migration anyway; runtime-issued DDL is not linted. `keiro-migrate verify-schema`
  snapshots only tables/columns/constraints/indexes in schema `keiro` (no `pg_proc`
  arm, `relkind = 'r'` only), so dynamic objects cause no drift; a dedicated schema
  additionally makes reconciliation safe ("everything in `keiro_read` is
  Keiro-generated and may be dropped") and lets operators grant external consumers
  `USAGE` on `keiro_read` alone, with no privileges on `keiro`, `kiroku`, or
  application schemas.
  Date: 2026-08-12
- Decision: `externalReaders` is excluded from the `catalog-v3:` and `slice-v2:`
  fingerprint preimages; no prefix bump.
  Rationale: per `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
  a group slice contains the facts affecting preparation, writers, query bindings,
  replay, and verification. External readability affects none of those: it is
  reconciled to match the catalog at every registration and never gates replay
  resume or lifecycle transitions. Excluding it means toggling external readability
  cannot strand an in-flight rebuild or force slice adoption — the same reasoning
  by which ADR-26 excludes query-contract type identities. The change is still
  reviewable: it appears in inventory rendering, the DSL ledger facts, and a
  dedicated diff finding.
  Date: 2026-08-12
- Decision: Freeze SQLSTATE class `KR` ("Keiro Read") with `KR001` = read model not
  in live service and `KR002` = read model unknown to the read surface. Message
  text begins `keiro read model "<name>" ...`; DETAIL carries group id, group
  status, and active run id; HINT tells the reader to retry after promotion.
  Rationale: the SQL standard reserves class codes beginning `0`–`4` and `A`–`H`;
  classes beginning `5`–`9` and `I`–`Z` are implementation-defined, and PostgreSQL
  itself uses none starting with `K`. Two codes because "not live" is retryable
  and "unregistered" is a deployment error; conflating them would re-blur exactly
  the distinction IR-22 demands.
  Date: 2026-08-12
- Decision: Ship two composition levels: a zero-discipline per-binding function
  (`keiro_read."read__<name>__v<version>"()` returning all declared rows) and the
  documented guard-plus-view contract (`keiro_read.assert_read_model_live(name)`
  followed, in the same transaction, by arbitrary consumer SQL against
  `keiro_read."target__<targetId>"`).
  Rationale: Keiro cannot reproduce an application's keyed query SQL — the query
  body is application-owned Haskell/SQL — and a set-returning plpgsql function
  materializes the whole target before outer `WHERE` filtering, which is wrong for
  large models. The guard/view contract gives keyed readers index-driven SQL with
  the identical fence semantics; the per-binding function gives small models and
  the acceptance test a surface that cannot be misused. A fence embedded inside a
  view was rejected: a view cannot raise when zero rows match, silently recreating
  the original hazard.
  Date: 2026-08-12
- Decision: The `.keiro` surface lands in this plan (clause
  `external-readers = [ "..." ]` on catalog-bound read models), nested inside the
  language-5 `group` branch, with no new `LanguageFeature`, no new
  `RuntimeCapability`, and no new reserved word.
  Rationale: MasterPlan 41 records that any language addition must land while
  language 5 is still Candidate (pre-registry-flip) — deferring would push it to
  language 6. Nesting inside the `group` clause branch makes it implicitly
  language-5 gated, the exact precedent set by `backing =` in
  `docs/plans/234-bind-catalog-read-models-to-one-explicit-physical-target.md`, and
  ADR-16's "registration is not release" rule allows amending candidate language 5
  in place. Not reserving the word follows plan 233's durable rule; a dashed
  spelling can never collide with `ident` anyway.
  Date: 2026-08-12
- Decision: Do not extend the versioned operator JSON envelopes
  (`keiro/catalog-inventory/v2` etc.) in this plan; only the human `renderInventory`
  text gains the reader list. No new generated Haskell constant is emitted either —
  callers use the runtime accessor `externalReadBindings`.
  Rationale: EP-1 (plan 254) and EP-3 (plan 256) both touch external/operator
  visibility surfaces; bumping the inventory envelope once, with the version
  columns EP-3 adds, avoids two breaking envelope revisions in one release. The
  external-facing contract of *this* plan is SQL, not JSON.
  Date: 2026-08-12
- Decision: The per-target view (`keiro_read."target__<targetId>"`) is the shared
  cutover indirection owned by this plan and consumed by plan 256; its exact
  contract is specified in "The cutover indirection" below. Any change to it
  requires updating both plans.
  Rationale: MasterPlan 41 names this the single most important interface of the
  initiative; freezing it here keeps the read functions' external identity stable
  across physical target versions.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a multi-package Haskell cabal project. The packages touched here
are `keiro` (the runtime), `keiro-dsl` (the `.keiro` typed-specification toolchain),
`keiro-migrations` (Keiro's own PostgreSQL schema, applied by the `keiro-migrate`
runner), and the `jitsurei` demo application. Everything below is stated from
scratch; no prior plan needs to be read to execute this one.

### The projection catalog and its four identities

A *projection catalog* is an application's single typed declaration of its entire
read side, defined in `keiro/src/Keiro/Projection/Catalog.hs`. Per
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
(ADR-26) it separates four identities:

- a *query-model binding* (`QueryModelBinding q r`, line ~350) pairs a typed
  `ReadModel q r` (the query contract callers use) with the rebuild group and the
  target tables the query observes;
- a *physical target* (`TargetDeclaration`) names one application-owned PostgreSQL
  table (`QualifiedTable { schemaName, tableName }`) and its reset policy —
  `ClearBeforeReplay` (truncated before replay) or `PreserveAndReconcile`;
- a *rebuild group* (`RebuildGroupDeclaration`) is the set of targets that move
  through one offline-rebuild lifecycle atomically;
- a *projection definition* is the single owner of one or more targets and holds
  the live handlers.

The catalog is validated by `validateProjectionCatalog` into a
`ValidatedProjectionCatalog`; only that type reaches registration and rebuild code.
Validation is pure and accumulates sorted `CatalogDiagnostic` values with stable
codes (see `CatalogDiagnosticCode` and `diagnosticCodeText`). The validated value
exposes a normalized `CatalogInventory` whose `InventoryQueryModel` rows carry
`registryName`, `version`, `shapeHash`, `rebuildGroupId`, `observedTargets`,
`freshness`, and `cursor`.

Fingerprints: `catalogFingerprint` hashes the whole inventory with prefix
`catalog-v3:`; `groupSliceFingerprint` hashes only one group's slice of facts with
prefix `slice-v2:` (`queryPreimage` at line ~2077 shows exactly which query facts
participate). Per
`docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
(ADR-32), the slice is the durable lifecycle-compatibility fence, changing the
preimage contract requires a prefix bump, and reviewed slice changes go through the
preview-then-adopt workflow (`previewCatalogAdoption` / `adoptCatalogGroups`).

MasterPlan 41 relies on the identity separation this way: the fence is a *group*
property, the sanctioned read is a *query-binding* property, and the privacy being
protected belongs to the *target*. The cross-repository decision
`mori://shinzui/mori/okf/adrs/concepts/ADR-20` (one catalogued owner per live
read-model table) is what makes an external read API well defined: there is exactly
one writer whose liveness determines whether a table may be read.

### The registration schema and the in-process fence

`keiro/src/Keiro/ReadModel/Rebuild/Group.hs` persists the lifecycle in two tables in
Keiro's own `keiro` schema (owned by `keiro-migrations` per
`docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md`, ADR-9):

- `keiro.keiro_projection_rebuild_groups` — one row per rebuild group: `group_id`,
  `slice_fingerprint`, `status` (`'live'` | `'rebuilding'` | `'failed'`),
  `active_run_id`, request metadata, timestamps.
- `keiro.keiro_read_models` — one row per registered query model: `name` (the
  registry name), `version`, `shape_hash`, `rebuild_group_id`, `status` (the
  runtime writes `'live'`, `'rebuilding'`, `'abandoned'`), `last_built_at`.

`registerProjectionCatalog` (called once at application startup, e.g.
`jitsurei/src/Jitsurei/Database.hs`) registers groups and query bindings in one
transaction (`registerProjectionCatalogTx`). `beginGroupRebuild` prepares a rebuild
in one transaction: it takes `FOR UPDATE` on the group row
(`lockGroupForUpdateStmt`), sets the group `'rebuilding'`, marks the bound query
rows `'rebuilding'` (`markGroupQueriesRebuildingStmt`), truncates every
`ClearBeforeReplay` target in one multi-table `TRUNCATE` (`truncateTargets`), and
resets replayable dedup/subscription state. Promotion (`finishGroupRebuildTx`,
reachable only through the replay runner's completion proof) sets everything back to
`'live'` in one transaction. A failed run (`abandonGroupRebuild`) keeps the fence.

Every in-process enforcement point is a Haskell call: `runQuery`
(`keiro/src/Keiro/ReadModel.hs`, `validateMetadata`) refuses a model whose
registered status is not `Live`; live writers acquire `FOR SHARE` on the group rows
in sorted order inside the same transaction as their SQL
(`lockProjectionGroupsTx`, Group.hs line ~596) and back off with a typed fenced
outcome when the group is not `'live'`.

### The defect mechanism

An out-of-process reader executes none of that Haskell. Its `SELECT` against a
target table succeeds at every point in the rebuild. Immediately after preparation
commits, the table is empty (and note `TRUNCATE` is not MVCC-safe: even a snapshot
taken *before* the truncate commit reads the table as empty afterwards). During
replay, the table holds a coherent prefix of history. Nothing distinguishes any of
this from "the model legitimately has few rows". The runtime already *knows* the
answer — group liveness is a durable catalog fact — but there is no sanctioned way
for a database-level reader to see it, and the documentation
(`docs/user/read-models-and-projections.md`) does not tell them they must.

The requesting service is hand-rolling exactly the missing piece — a versioned SQL
read function that checks group liveness transactionally and raises (documented in
its repository at `docs/SPLIT-PULL-ALTERNATIVE.md`;
`mori://tan/notification-render-service`) — and will delete it in favor of the
generated surface this plan builds.

### The design in one pass

*Declaration.* `QueryModelBinding` gains
`externalReaders :: ![ExternalReaderName]` — an empty list means "not externally
readable" (today's behavior); a non-empty list marks the binding externally
readable and records the named consumers for attribution and review. Reader names
are opaque identities (validated non-empty, no surrounding whitespace), not
PostgreSQL roles. In candidate language 5, a catalog-bound `readmodel` block may
declare `external-readers = [ "notification-render-kernel" ]`.

*Generated objects.* At registration (and at slice adoption), Keiro reconciles the
`keiro_read` schema to match the validated catalog, inside the same transaction as
the registration itself:

- one guard function, `keiro_read.assert_read_model_live(model_name text)`:
  `plpgsql`, `VOLATILE`, `SECURITY DEFINER`, `SET search_path` to empty. It looks
  up `keiro.keiro_read_models` by name (raising `KR002` if absent), then takes
  `SELECT ... FOR SHARE` on the model's row in
  `keiro.keiro_projection_rebuild_groups` and raises `KR001` unless both the group
  row and the model row read `'live'`;
- one view per backing target of an externally readable binding,
  `keiro_read."target__<targetId>"`, defined as
  `SELECT * FROM "<schema>"."<table>"` — the cutover indirection;
- one function per externally readable binding,
  `keiro_read."read__<registryName>__v<version>"()`, `RETURNS SETOF
  keiro_read."target__<targetId>"`, `plpgsql`, `VOLATILE`, `SECURITY DEFINER`,
  empty `search_path`, whose body is: `PERFORM` the guard with the binding's
  registry name, then `RETURN QUERY SELECT * FROM` the view.

*Why this is actually race-free.* The guard's `FOR SHARE` conflicts with
preparation's and promotion's `FOR UPDATE`/`UPDATE` on the same group row. If
preparation committed first, a locking read returns the newest committed row
version even under `READ COMMITTED`, so the guard sees `'rebuilding'` and raises.
If the guard acquires the lock first, preparation blocks until the reader's
transaction ends, so the reader's table reads in that transaction happen strictly
before any truncation. Because the functions are `VOLATILE`, each inner statement
takes a fresh snapshot, so the table read's snapshot is at least as new as the
guard's check, and the held lock guarantees the state cannot change in between. A
`REPEATABLE READ` reader whose group row changed since its snapshot gets a
serialization failure from the locking read — also loud. A plain status check
without the row lock would *not* be sufficient, precisely because `TRUNCATE` is not
MVCC-safe. This argument must be preserved in the new ADR and the user docs.

*Error contract.* `KR001`, message
`keiro read model "<name>" is not in live service`, DETAIL
`rebuild group "<group>" has status "<status>" (active run "<run-id|none>")`, HINT
`Retry after the rebuild group is promoted back to live service.` `KR002`, message
`keiro read model "<name>" is not registered with the keiro read surface`. The
SQLSTATE values and the message prefix up to the model name are frozen contract;
DETAIL/HINT are informative and may gain fields. The liveness vocabulary
(`live`/`rebuilding`/`failed` at group scope) is shared with plan 254's status
relation — both read `keiro.keiro_projection_rebuild_groups.status`; if plan 254
lands first, confirm the words match its documented contract before freezing docs.

*Composition contract for keyed reads.* A consumer with its own WHERE clause runs,
in one transaction: `SELECT keiro_read.assert_read_model_live('<name>');` then any
number of `SELECT`s against `keiro_read."target__<targetId>"`. Same-transaction is
mandatory (the guard's row lock is what freezes liveness for the duration).
Generated views carry `GRANT SELECT TO PUBLIC` (recreated with the view on each
reconciliation); functions rely on PostgreSQL's default `EXECUTE` for `PUBLIC`.
Access is gated by schema privilege: only roles granted `USAGE ON SCHEMA
keiro_read` can reach any of it, and consumers need *no* privileges on `keiro`,
`kiroku`, or application schemas because the `SECURITY DEFINER` functions and the
views (which execute with their owner's rights against underlying tables) run as
the registering application role. The docs must say plainly that selecting a
`target__` view without the guard in the same transaction reproduces the unfenced
hazard.

*Identifier derivation.* Function name `read__<registryName>__v<version>`; view
name `target__<targetId>`; both rendered as quoted identifiers via
`Keiro.Connection.quoteIdentifier`. PostgreSQL truncates identifiers to 63 bytes,
so the derivation is total: if the UTF-8 encoding exceeds 63 bytes, keep the first
54 bytes (on a UTF-8 boundary) and append `_` plus the first 8 hex characters of
the SHA-256 of the full logical name (reuse `Crypto.Hash.SHA256` +
`Data.ByteString.Base16` as `Keiro.Projection.Catalog.Preimage` does). Expose the
derivation as pure functions so tests, docs, and consumers agree.

*Backing-target resolution.* The rows a binding's function returns are the rows of
its one physical backing table. A generated language-5 binding always has one (per
ADR-26 and plan 234's `backing =` clause, the generated `ReadModel`'s
`schema`/`tableName` are rewritten from the backing target). For hand-written
catalogs the same fact is recovered by matching the binding's
`ReadModel` `schema`/`tableName` pair against the declared `qualifiedTable` of its
observed targets; an externally readable binding whose pair matches no observed
target (or, impossibly, several — `DuplicateQualifiedTable` already prevents it) is
a new validation diagnostic, `ExternalReadBackingUnresolved`.

### The cutover indirection (shared interface with plan 256)

This is the contract plan 256 consumes; both plans must be updated together if it
changes.

- External identity, frozen by this plan: the schema name `keiro_read`; the guard
  function name and signature `assert_read_model_live(text) RETURNS void`; the
  read-function naming scheme `read__<registryName>__v<version>` with the 63-byte
  derivation rule; the SQLSTATEs `KR001`/`KR002`; and the view naming scheme
  `target__<targetId>` meaning *the current live physical relation of that
  target*.
- Read functions and consumer SQL reference targets **only** through
  `keiro_read."target__<targetId>"` — never a raw application table name.
- Plan 256 performs cutover by re-pointing that view at the new physical relation
  (`CREATE OR REPLACE VIEW` when the column set is unchanged) inside its cutover
  transaction, in the same transaction that flips its version metadata. It must
  not rename, drop, or re-sign the read functions or the guard.
- A rebuild that changes the column set is by definition a query-model
  version/shape change: it produces a *new* function name (`__v<n+1>`), and the
  old function is dropped at the registration that adopts the new catalog. Plan
  256 owes no compatibility for shape-changing cutovers beyond that.
- The guard's serving set is deliberately fail-safe under this plan: any group or
  model status other than `'live'` raises `KR001`, unknown future statuses
  included. Plan 256 owns extending that set — when it introduces
  `rebuilding-versioned` and `cutover`, it regenerates the guard in the same
  change to classify those two as serving (the live table serves throughout a
  versioned rebuild); `rebuilding` and `failed` keep raising. This plan must not
  anticipate those statuses.

### What already gates this repository (run these; do not fight them)

`just verify` is the full gate; it includes `adr-validate` (OKF strict profile
enforcement over `docs/adr`), `capabilities-validate`,
`conformance-corpus-policy` (the committed generated corpus must match
regeneration), and `haskell-verify`. Database-backed suites use the suite-level
template-database fixture from `keiro-test-support`
(`Keiro.Test.Postgres.withMigratedSuite` caches one migrated template database and
clones it per example via `withFreshStore`/`withFreshDatabase`); never write
per-example migrations. New native migrations are a three-file diff
(`keiro-migrations/migrations/NNNN.sql`, a `migrations/manifest` line, a
`migrations.native.lock` SHA-256 line) plus a CHANGELOG bullet; the body lint
forbids `search_path` anywhere in a migration file and requires recognized DDL
statements to target the `keiro.` qualifier (a bare `CREATE SCHEMA` is not a
lint-recognized statement and passes).

Relevant ADRs, summarized above where used: ADR-26 (identities), ADR-32
(fingerprints/slices/adoption), ADR-9 (schema ownership and verify-schema scope),
`docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
(ADR-28: operator commands wrap library APIs — nothing here adds console SQL), and
`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
(ADR-16: candidate language 5 is amended in place; its frozen clause-spelling list
must gain `external-readers`). Cross-repository:
`mori://shinzui/mori/okf/adrs/concepts/ADR-20`. The runtime-patterns standard
(the `keiro-runtime-patterns` corpus, pages `read-models-and-projections` and
`projection-catalogs`) states the rebuild is offline and must be updated after this
plan lands; that update is a cross-repository follow-up recorded in MasterPlan 41's
Integration Points, not work done in this repository.


## Plan of Work

Work proceeds in four milestones. Each is independently verifiable and keeps
`cabal build all` and the affected test suites green at its end. Commits follow
Conventional Commits and carry the trailers listed under "Commit and trailer
convention" in Concrete Steps.

### Milestone 1 — the runtime declaration and its identity ruling

Scope: the `keiro` package learns what "externally readable" means, without yet
generating any SQL. At the end, an application (or test) can declare
`externalReaders` on a binding; validation enforces the new invariants; the
inventory renders the declaration; and — the load-bearing ruling — catalog and
slice fingerprints are provably unchanged by the declaration. Everything still
compiles across the repo, including the DSL's generated-code emitter and the
committed conformance corpus.

In `keiro/src/Keiro/Projection/Catalog.hs`:

- Add `newtype ExternalReaderName` with `mkExternalReaderName :: Text -> Either
  CatalogIdentityError ExternalReaderName` (reuse `mkIdentity`) and
  `externalReaderNameText`. Export all three plus the new field, accessor, and
  diagnostic constructors from the module header.
- Add `externalReaders :: ![ExternalReaderName]` to `QueryModelBinding` between
  `observedTargets` and `claimSite` (generated code constructs this record
  positionally; field order is contract). Thread it through `QueryFacts`
  (`collectQueryFacts`), `InventoryQueryModel` (`buildInventory`, storing the
  *sorted, deduplicated* name list), and `renderInventory`'s query line (append a
  `commaSeparated` reader list column).
- Do **not** touch `queryPreimage`, `inventoryPreimage`, or `groupSliceFingerprint`.
  The preimages must not change; that is the ruling recorded in the Decision Log.
- Add two `CatalogDiagnosticCode` constructors with `diagnosticCodeText` entries:
  `DuplicateExternalReaderName` → `catalog.duplicate-external-reader-name`
  (the same name declared twice on one binding) and
  `ExternalReadBackingUnresolved` → `catalog.external-read-backing-unresolved`
  (an externally readable binding whose `ReadModel` `schema`/`tableName` matches no
  observed target's `qualifiedTable`). Implement both in a new
  `externalReadDiagnostics` block appended to the `diagnostics` composition in
  `validateProjectionCatalog`, following the shape of `querySupplyDiagnostics`.
- Add the derived accessor used by milestone 2 and by applications:

```haskell
data ExternalReadBinding = ExternalReadBinding
  { externalRegistryName :: !Text,
    externalVersion :: !Int,
    externalQueryModelId :: !QueryModelId,
    externalBackingTarget :: !InventoryTarget,
    externalReaderNames :: ![ExternalReaderName]
  }

externalReadBindings :: ValidatedProjectionCatalog -> [ExternalReadBinding]
```

  sorted by registry name, one row per binding with a non-empty reader list, with
  the backing target resolved by the qualified-table match described in Context.

Compile-fix every construction site the compiler names. Known sites:
`jitsurei/src/Jitsurei/ReadModels.hs` (record syntax; add `externalReaders = []`
for now — milestone 4 turns it on), `keiro/test/CatalogSpec.hs`,
`keiro/test/CatalogEvolutionSpec.hs` and any other keiro test constructing
bindings, and — in `keiro-dsl` — the emitter `queryExpr` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (line ~4346), which must gain a positional
`[]` argument between the observed-target list and the claim site so generated
code matches the new field order. Then regenerate the committed corpus
(`just corpus-regen`) so the three checked-in
`Generated/*/ProjectionCatalog.hs` conformance modules pick up the new arity, and
run `just conformance-corpus-policy`.

Tests (pure, in `keiro/test/CatalogSpec.hs` and `keiro/test/PreimageSpec.hs`):
duplicate-reader and unresolved-backing diagnostics fire with the right codes and
claim sites; a valid externally readable binding validates and appears in
`externalReadBindings` with the right backing target; and the fingerprint-stability
test — build the same catalog twice, once with `externalReaders = []` and once
with a non-empty list, and assert `catalogFingerprintText` and every
`groupSliceFingerprintText` are *equal* while `renderCatalogInventory` output
differs. Also unit-test the identifier derivation functions here if you add them in
this milestone (they may also land in milestone 2 with their module).

Acceptance: `cabal build all` clean; `cabal test keiro-test` green (new tests
included); `cabal test keiro-dsl:tests` green after corpus regeneration.

### Milestone 2 — the generated SQL surface, its schema, and the red-first proof

Scope: the `keiro_read` schema exists via migration; a new runtime module renders
and reconciles the generated objects inside registration and adoption; a DB-backed
spec proves the IR's acceptance sequence — written red-first so the hazard and the
fix are both evidenced. This is the heart of the plan.

First the migration. Create `keiro-migrations/migrations/0026.sql`:

```sql
CREATE SCHEMA IF NOT EXISTS keiro_read;

COMMENT ON SCHEMA keiro_read IS
  'Keiro-generated external read surface. Contents are created and reconciled by catalog registration; do not create objects here by hand.';
```

Append `0026.sql` to `keiro-migrations/migrations/manifest` and its SHA-256 line to
`keiro-migrations/migrations.native.lock` (run
`cabal run keiro-migrate -- check --manifest keiro-migrations/migrations/manifest`
and the `keiro-migrations-test` suite, which gates the lockfile; the expected-schema
snapshot `keiro-migrations/expected-schema/native/keiro-v18.txt` is *unchanged*
because the snapshot only covers schema `keiro`). Add the CHANGELOG bullet
(keiro-migrations, `Unreleased`/`Added`). Update `docs/user/migrations.md`'s
"Runtime role privileges" section with the two new grants and their meaning:

```sql
GRANT USAGE, CREATE ON SCHEMA keiro_read TO your_app_role;   -- the registering service
GRANT USAGE ON SCHEMA keiro_read TO your_external_reader_role; -- each SQL consumer
```

and note that external readers need no other privileges. (The registering role
needs `UPDATE` on `keiro` tables for the guard's `FOR SHARE`; the existing
documented grants already give it.)

Then the runtime module. Create `keiro/src/Keiro/Projection/Catalog/ExternalRead.hs`
(add to `exposed-modules` in `keiro/keiro.cabal`) exporting:

```haskell
externalReadSchemaName :: Text            -- "keiro_read"
guardFunctionName :: Text                 -- "assert_read_model_live"
sqlstateReadModelNotLive :: Text          -- "KR001"
sqlstateReadModelUnregistered :: Text     -- "KR002"
externalReadFunctionName :: Text -> Int -> Text   -- registry name, version
externalReadViewName :: TargetId -> Text
renderExternalReadSurfaceSql :: ValidatedProjectionCatalog -> [Text]
reconcileExternalReadSurfaceTx :: ValidatedProjectionCatalog -> Tx.Transaction ()
```

`renderExternalReadSurfaceSql` returns the deterministic, ordered DDL statement
list (pure; used by reconciliation, tests, and reviewable output). The guard,
rendered once whenever `externalReadBindings` is non-empty:

```sql
CREATE OR REPLACE FUNCTION keiro_read.assert_read_model_live(model_name text)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $keiro_guard$
DECLARE
  model record;
  grp record;
BEGIN
  SELECT rebuild_group_id, status INTO model
  FROM keiro.keiro_read_models
  WHERE name = model_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'keiro read model "%" is not registered with the keiro read surface', model_name
      USING ERRCODE = 'KR002';
  END IF;
  SELECT status, active_run_id INTO grp
  FROM keiro.keiro_projection_rebuild_groups
  WHERE group_id = model.rebuild_group_id
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'keiro read model "%" is not registered with the keiro read surface', model_name
      USING ERRCODE = 'KR002',
            DETAIL = format('rebuild group "%s" has no registration row', model.rebuild_group_id);
  END IF;
  IF grp.status <> 'live' OR model.status <> 'live' THEN
    RAISE EXCEPTION 'keiro read model "%" is not in live service', model_name
      USING ERRCODE = 'KR001',
            DETAIL = format('rebuild group "%s" has status "%s" (active run "%s")',
                            model.rebuild_group_id, grp.status, coalesce(grp.active_run_id, 'none')),
            HINT = 'Retry after the rebuild group is promoted back to live service.';
  END IF;
END;
$keiro_guard$;
```

Per externally readable binding, in deterministic (registry-name) order — view
first, then function, with all names produced by the derivation functions and
quoted via `Keiro.Connection.quoteIdentifier`:

```sql
CREATE VIEW keiro_read."target__<targetId>" AS
  SELECT * FROM "<schemaName>"."<tableName>";
GRANT SELECT ON keiro_read."target__<targetId>" TO PUBLIC;

CREATE FUNCTION keiro_read."read__<registryName>__v<version>"()
RETURNS SETOF keiro_read."target__<targetId>"
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $keiro_read$
BEGIN
  PERFORM keiro_read.assert_read_model_live('<registryName>');
  RETURN QUERY SELECT * FROM keiro_read."target__<targetId>";
END;
$keiro_read$;
```

(Single quotes inside the registry name must be SQL-escaped by doubling; add that
tiny literal-escaping helper next to the identifier quoting.)

`reconcileExternalReadSurfaceTx` runs inside an existing transaction and is a full
drop-and-recreate reconciliation:

1. `SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'keiro_read'` — if the
   schema is absent and the catalog declares no external readers, return without
   touching anything (existing installations that never adopt the feature are
   unaffected even before migration 0026 is applied). If the schema is absent and
   the catalog *does* declare readers, fail with the typed error added below.
2. Enumerate and drop current contents: functions via
   `SELECT p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid) FROM
   pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'keiro_read'` then `DROP FUNCTION keiro_read."<name>"(<args>)`
   for each; views via `pg_class` with `relkind = 'v'` in that namespace and
   `DROP VIEW`. Functions drop before views (return types depend on view row
   types).
3. Execute `renderExternalReadSurfaceSql` output via `Tx.sql` (the same mechanism
   `truncateTargets` uses).

Wire it in `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`:

- `registerProjectionCatalogTx`: after `deleteOrphanLegacyGroupsStmt`, on the
  success path, call `reconcileExternalReadSurfaceTx catalog`. Add constructor
  `ExternalReadSchemaMissing` to `CatalogRegistrationError` for the schema-absent
  case (message must name migration 0026 and `keiro-migrate`).
- The adoption transaction in `adoptCatalogGroups` (`adoptTx`): after the
  query-registration updates, call the same reconciliation (version bumps rename
  functions). Add `AdoptExternalReadSchemaMissing` to `CatalogAdoptionError`.

Now the spec, red-first. Create `keiro/test/ExternalReadSurfaceSpec.hs`, add it to
`other-modules` in the `keiro-test` stanza and to `keiro/test/Main.hs` after
`GroupRebuildSpec.spec fixture` (it takes the `Fixture`). Copy the local
`expectStore`/`shouldBeRight`/`expectValid` helpers from `GroupRebuildSpec.hs`.
Build a minimal catalog in the spec: one app table created with raw `Tx.sql` DDL
(e.g. `app_reads.external_demo(id text primary key, body text)`), one
`ClearBeforeReplay` target, a singleton rebuild group, one replayable inline owner
(mirror `GroupRebuildSpec`'s fixture catalog), and one query binding with
`externalReaders = [must (mkExternalReaderName "spec-reader")]`.

Write the acceptance test *first* and run it before implementing reconciliation:
it must fail with PostgreSQL's `undefined_function` (SQLSTATE `42883`) because the
generated function does not exist yet. Commit the red state together with the
start of the implementation work, then make it green. The tests:

1. *Hazard characterization* (documents the defect this plan closes; passes before
   and after): register the catalog, insert two rows, `beginGroupRebuild`, then
   from a second store on the same database run a raw
   `SELECT count(*) FROM app_reads.external_demo` — it returns `0` with no error.
2. *Acceptance — loud fence*: with reconciliation implemented, register, insert
   rows, call `keiro_read."read__<name>__v1"()` from the second store and get the
   rows; `beginGroupRebuild`; the same call now fails and the error's SQLSTATE is
   `KR001` (assert on the hasql `ServerError` code, message prefix, and that the
   DETAIL contains the group id and status `rebuilding`); promote via
   `finishGroupRebuild handle (completionTokenForHandle handle)` (the spec-level
   promotion path `GroupRebuildSpec` already uses); the same call returns the
   correct current rows again.
3. *Unknown model*: calling the guard with an unregistered name raises `KR002`.
4. *Guard composition*: in one transaction on the second store, run the guard then
   a keyed `SELECT` against `keiro_read."target__<targetId>"`; during a rebuild
   the guard statement raises `KR001` before any row read.
5. *Reconciliation*: registering twice is idempotent (functions exist once, same
   behavior); re-registering a catalog whose binding dropped its readers removes
   the function (`42883` afterwards) and the view.

The "second store" is a separate connection pool: open it with
`withFreshDatabase`'s connection string via the same store constructor the fixture
uses (`withFreshStoreWith`-style), or acquire a raw hasql connection mirroring
`keiro-test-support`'s `staticConnectionSettings` usage — either satisfies
"separate process holding its own connection" for fencing purposes because the
fence is per-transaction, not per-process.

Also capture the psql transcript (see Validation and Acceptance) against the
jitsurei database once milestone 4 turns on jitsurei's declaration — or against a
scratch database now — and paste the real output into this plan.

Acceptance: `cabal test keiro-test` green including the new spec;
`cabal test keiro-migrations-test` green (lockfile, lint, expected-schema all
pass); `cabal build all` clean.

### Milestone 3 — the candidate language-5 surface

Scope: the `external-readers` clause exists end-to-end in `keiro-dsl`: parsed,
printed, validated, lowered into the generated catalog, visible in ledger facts and
diff, exercised by fixtures and the compiled corpus. Language 5 is Candidate, so
this amends `profileV4`-era behavior in place per ADR-16 — no new language, no new
feature flag, no reserved word.

Grammar and parser:

- `keiro-dsl/src/Keiro/Dsl/Grammar.hs`: add `rmExternalReaders :: ![Text]` to
  `ReadModelNode` (line ~1228). No new sum type, so no `HasLocs` change in
  `Workspace.hs`. Fix construction sites the compiler names.
- `keiro-dsl/src/Keiro/Dsl/Parser/ReadModel.hs`: inside the `Just group` branch
  (after the `backing` clause, line ~51), parse
  `option [] (symbol "external-readers" *> symbol "=" *> brackets (many <stringLit>))`
  using the same quoted-string parser the `subscription =` clause uses (see
  `Parser/ProjectionCatalog.hs`). Nesting inside the `group` branch makes the
  clause implicitly language-5 gated, exactly like `backing` (plan 234). Do not
  touch `reservedWords` in `Parser/Core.hs`.
- `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` `docReadModel` (line ~385): render
  `external-readers = [ "a", "b" ]` immediately after the `backing` line when the
  list is non-empty, so `parse . render` round-trips.

Validation (`keiro-dsl/src/Keiro/Dsl/Validate.hs`):

- New `DiagnosticCode` constructors in the `CatalogReadModel*` family (line
  ~211–262): `CatalogReadModelExternalReaderDuplicate`,
  `CatalogReadModelExternalReaderInvalid` (empty or whitespace-wrapped literal),
  `CatalogReadModelExternalReadersEmpty` (clause present with an empty list —
  declare readers or remove the clause). The suite's diagnostic-code round-trip
  test picks new constructors up automatically.
- Implement the three rules inside the `catalogBinding` block of
  `validateReadModel` (line ~2773), active only when the model is catalog-bound.

Lowering and records:

- `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` `queryExpr` (~4346): replace milestone 1's
  literal `[]` with
  `renderList (smart "mkExternalReaderName") (sort (rmExternalReaders readModel))`.
- `keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` `projectionCatalogFactsWith`
  `nodeFacts` (~320–345): when the list is non-empty, emit a fourth ledger row
  `external-readers|<model>|<comma-separated sorted readers>|<line>` (emitting only
  when non-empty keeps every existing ledger byte-identical).
- `keiro-dsl/src/Keiro/Dsl/Harness.hs` `emitReadModelHarness`: extend the grouped
  models' expected catalog facts so the generated harness asserts the runtime
  inventory row carries the declared readers (compiler- and test-driven; mirror how
  `expectedFreshness` is asserted).

Diff (`keiro-dsl/src/Keiro/Dsl/Diff.hs`, `DiffReport.hs`):

- Add `CatalogQueryExternalReadersChanged` and a new `externalReadChanges` block in
  `readModelPairDiff` (mirror `policyChanges`, line ~1233) comparing sorted reader
  sets; do *not* fold it into the breaking `bindingIdentity` tuple — this change is
  registration-reconciled, not persisted-identity-breaking.
- Add an explicit arm in `classifyCompatibility` (line ~307): read the existing
  vectors and classify as the mildest vector that still requires regeneration and
  redeployment but not a rebuild (it must not map to
  `persistedIdentityBreakingVector`). Add a `remediationFor` arm in
  `DiffReport.hs` (~275) saying the surface reconciles at the next registration and
  the named readers should be notified of additions/removals.

Fixtures, inventories, corpus, docs:

- New fixtures under `keiro-dsl/test/fixtures/`:
  `catalog-readmodel-external-readers.keiro` (valid; two readers),
  `catalog-readmodel-external-readers-duplicate.keiro`, and
  `catalog-readmodel-external-readers-empty.keiro`. Register every new language-5
  fixture in **both** inventories: the literal list in `keiro-dsl/test/Main.hs`
  (~1739, "keeps only the named source-version compatibility fixtures outside
  stable v4") and `keiro-dsl/test/conformance-baseline.json` `fixtureExceptions`.
- Tests in the "language-5 projection catalogs" describe block
  (`keiro-dsl/test/Main.hs` ~2012): `errorCodesOf` for each diagnostic; a
  generated-text assertion that the emitted `ProjectionCatalog.hs` contains
  `mkExternalReaderName "..."`; a round-trip test; and — cloned verbatim from the
  freshness-isolation test at ~2188 — an isolation test proving an
  `external-readers` edit produces exactly `CatalogQueryExternalReadersChanged`,
  leaves fold and aggregate-source fingerprints and `deriveShapeHash` unchanged
  (the shape preimage in `ReadModelShape.hs` is columns-only by construction), and
  changes only the new ledger row.
- Extend the corpus source
  `keiro-dsl/test/fixtures/projection-catalog.keiro` (the `CatalogDemo` corpus
  input): add `external-readers = [ "demo-reporting" ]` to one read model, run
  `just corpus-regen`, confirm drift confined to `conformance-projection-catalog`
  outputs, and extend that corpus's hand-owned `Main.hs` with a runtime assertion
  that `externalReadBindings` on the generated validated catalog names the reader
  and the expected function name. Run `just conformance-corpus-policy`.
- Update `docs/corpus/keiro-dsl-corpus.md` (fixture tables and the hard counts),
  `docs/user/typed-spec-toolchain.md` (the catalog read-model reference block,
  ~1500–1620: clause syntax, semantics, the note that it changes no fingerprints
  and reconciles at registration), and
  `agents/skills/keiro-dsl-authoring/NOTATION.md` (`## readmodel` section).
- Amend ADR-16's frozen candidate clause-spelling paragraph to include
  `external-readers` (bump its `timestamp`, run the ADR gate and
  `okf log add` as required by the profile — see Concrete Steps).

Acceptance: `cabal test keiro-dsl:tests` green (the `:tests` suffix is mandatory —
bare `cabal test keiro-dsl` runs a single component); corpus policy green;
`cabal build all` clean.

### Milestone 4 — documentation, ADR, adoption evidence, and the full gate

Scope: the hazard and the sanctioned surface are documented where users will look;
the durable contract gets its ADR; jitsurei demonstrates adoption end-to-end; all
changelogs and the MasterPlan registry are updated; `just verify` passes.

Documentation:

- `docs/user/read-models-and-projections.md`: add an "Out-Of-Process Readers"
  section after "Register And Fence Catalog Groups" that states plainly: *the
  in-process fence does not protect out-of-process readers* — a plain `SELECT`
  against a target table during a rebuild returns truncated or partially replayed
  rows with no error — and names this surface as the sanctioned way to read a
  Keiro read model over SQL. Document: the declaration (both the `.keiro` clause
  and `externalReaders`), the generated names, both composition levels with SQL
  examples, the full `KR001`/`KR002` contract table, the same-transaction rule and
  *why* (condense the race-freedom argument), the performance caveat on the
  set-returning function, the grants, and the explicit warning about reading
  `target__` views without the guard. Note that the `keiro-runtime-patterns`
  standard (cross-repository) still describes the rebuild as offline-only and is
  updated as a follow-up recorded in MasterPlan 41 — do not edit it from this
  repository.
- `docs/capabilities/read-models-and-projections.md` and
  `docs/capabilities/typed-projection-catalogs.md`: add the capability facts
  (`just capabilities-validate` gates the format).
- Jitsurei: set
  `externalReaders = [identityOrError mkExternalReaderName "jitsurei-reporting"]`
  on the order-summary binding in `jitsurei/src/Jitsurei/ReadModels.hs`, and extend
  the rebuild rehearsal in `docs/guides/run-and-operate-jitsurei.md` with the psql
  fence demonstration (transcript below).

ADR work (follow `agents/skills/exec-plan/ADR.md`; `docs/adr` is a profile-governed
OKF bundle):

- Create the new ADR — allocate the handle with `okf id next` at landing time
  (plans 254 and 256 also allocate new ADRs, so do not assume a number; name the
  file from the allocated handle) — titled along the lines of "Out-of-process reads use
  a generated, group-fenced SQL surface". It must record: the declaration and its
  identities (query-binding property; opaque reader names, not roles); the
  generated object inventory and naming derivation; the frozen SQLSTATE and
  message contract; the same-transaction composition contract with the full
  locking/snapshot correctness argument (FOR SHARE vs FOR UPDATE, VOLATILE
  snapshot ordering, TRUNCATE non-MVCC); the cutover indirection promise to plan
  256; the fingerprint-exclusion ruling; the schema-ownership line (schema by
  migration, contents by registration; grants operator-owned); and the deliberate
  exclusion of privilege-based fencing with its rationale.
- Add one line to ADR-26's "Related decisions" pointing at the new ADR (bump its
  `timestamp`).
- Run the strict profile gate and log maintenance (Concrete Steps).

Changelogs: `keiro/CHANGELOG.md` (`Unreleased`/`Added`: declaration, module,
generated surface, SQLSTATEs; `Breaking Changes`: the `QueryModelBinding` field for
hand-written catalogs and the new `CatalogRegistrationError`/`CatalogAdoptionError`
constructors), `keiro-dsl/CHANGELOG.md` (the clause, diagnostics, diff finding),
`keiro-migrations/CHANGELOG.md` (already written in milestone 2 — verify).
Update MasterPlan 41's Exec-Plan Registry row for this plan and its Progress
section. Write this plan's Outcomes & Retrospective and perform the ADR
distillation pass.

Acceptance: `just verify` green from the repository root.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/keiro`) inside the flake dev shell.

Build and targeted suites, after each milestone as named above:

```bash
cabal build all
cabal test keiro-test
cabal test keiro-dsl:tests
cabal test keiro-migrations-test
```

Run only the new DB spec while iterating:

```bash
cabal test keiro-test --test-options='--match "external read"'
```

Corpus maintenance (milestones 1 and 3):

```bash
just corpus-regen
just conformance-corpus-policy
```

Migration authoring (milestone 2): write
`keiro-migrations/migrations/0026.sql` by hand, append the filename line to
`keiro-migrations/migrations/manifest`, compute the lock line with
`shasum -a 256 keiro-migrations/migrations/0026.sql` and append
`<sha256>  0026.sql` to `keiro-migrations/migrations.native.lock`, then:

```bash
cabal run keiro-migrate -- check --manifest keiro-migrations/migrations/manifest
cabal test keiro-migrations-test
```

ADR gate (milestones 3 and 4, after any `docs/adr` change):

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf log add docs/adr <docId> "<one-line change note>"   # whenever an ADR timestamp advances
```

(Verify the exact `okf log add` invocation against the bundle's existing `log.md`
entries before running it.)

The psql acceptance transcript (milestone 2/4). With the local dev database up
(`just up` starts process-compose with PostgreSQL on the repo-local socket
directory; `PGHOST=db`), the jitsurei demo registered (`just jitsurei-migrate`
then `cabal run jitsurei-demo`), and a rebuild rehearsal started per
`docs/guides/run-and-operate-jitsurei.md`, run in a second terminal:

```text
$ PGHOST=db psql -d jitsurei -X
jitsurei=# \set VERBOSITY verbose
jitsurei=# SELECT count(*) FROM keiro_read."read__jitsurei-order-summary__v1"();
 count
-------
     2
(1 row)

-- after `rebuild start` has fenced the jitsurei-order-reporting group:
jitsurei=# SELECT count(*) FROM keiro_read."read__jitsurei-order-summary__v1"();
ERROR:  KR001: keiro read model "jitsurei-order-summary" is not in live service
DETAIL:  rebuild group "jitsurei-order-reporting" has status "rebuilding" (active run "<run-id>")
HINT:  Retry after the rebuild group is promoted back to live service.

-- after the rehearsal promotes the group:
jitsurei=# SELECT count(*) FROM keiro_read."read__jitsurei-order-summary__v1"();
 count
-------
     2
(1 row)
```

Row counts and the run id will differ; the SQLSTATE, message shape, and the
error/success sequence are the acceptance. Replace this expected transcript with
the real captured one when it is produced.

Full gate, last step of milestone 4:

```bash
just verify
```

### Commit and trailer convention

Use Conventional Commits (`feat(catalog): ...`, `feat(dsl): ...`,
`feat(migrations): ...`, `test(...)`, `docs(...)`), committing per coherent step,
and include on every commit the trailers:

```text
MasterPlan: docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md
ExecPlan: docs/plans/255-fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface.md
Intention: intention_01kzw6dkhje7qvw6w321pwyv12
```


## Validation and Acceptance

The change is accepted when all of the following observable behaviors hold.

1. IR-22 acceptance sequence, as a DB-backed test
   (`keiro/test/ExternalReadSurfaceSpec.hs`) and as the psql transcript above:
   begin a rebuild of a group containing a `ClearBeforeReplay` target; from a
   separate connection, the sanctioned read raises SQLSTATE `KR001` whose message
   names the model and whose DETAIL names the group, status `rebuilding`, and the
   active run id — not zero rows, not partial rows; after promotion the identical
   call returns correct current state. Before the implementation exists, the same
   test fails with `42883` (undefined function) — the red-first evidence.
2. The hazard characterization test shows the defect this plan closes: a raw
   `SELECT` against the target table during the same fenced window returns `0`
   rows with no error.
3. An unregistered name raises `KR002`, distinguishable from `KR001`.
4. The guard composes: `SELECT keiro_read.assert_read_model_live('<name>')`
   followed in the same transaction by keyed SQL against
   `keiro_read."target__<targetId>"` raises during the fence and returns rows
   when live.
5. Fingerprint stability: a test proves `catalog-v3:` and `slice-v2:` values are
   byte-identical with and without `externalReaders`; registration of a catalog
   that only toggled external readability is accepted without slice adoption, and
   reconciliation adds/removes the SQL objects.
6. DSL end-to-end: a language-5 spec with
   `external-readers = [ "demo-reporting" ]` checks cleanly, scaffolds a
   `ProjectionCatalog` whose generated binding carries the reader, round-trips
   through the pretty-printer, and produces exactly
   `CatalogQueryExternalReadersChanged` in `keiro-dsl diff` when edited, with fold,
   aggregate-source, and shape fingerprints unchanged. The three new diagnostics
   fire on their fixtures. A language-4 spec cannot reach the clause (it is inside
   the `group` branch, which languages 1–4 cannot parse).
7. `cabal test keiro-migrations-test` proves migration 0026 applies on a fresh
   database, the lockfile and lint gates pass, and the expected-schema snapshot is
   unchanged.
8. `just verify` passes at the end, covering the ADR profile gate, capabilities
   docs, corpus policy, and the full Haskell build/test matrix.


## Idempotence and Recovery

Every step is re-runnable. `reconcileExternalReadSurfaceTx` is drop-and-recreate
inside the registration/adoption transaction: a failure anywhere rolls back the
whole registration (PostgreSQL DDL is transactional), leaving the previous surface
intact; re-running registration reconverges. Registering the same catalog twice
produces the identical surface. The migration is `CREATE SCHEMA IF NOT EXISTS` —
re-applying is a no-op, and pg-migrate's checksum ledger prevents divergent
re-application. Corpus regeneration (`just corpus-regen`) is deterministic; if a
regeneration goes wrong, `git checkout -- keiro-dsl/test/conformance-*` restores
the committed corpus. The `keiro-test` fixture clones a template database per
example, so failed DB tests never leak state between examples.

Two operational cautions to record in the docs rather than to engineer around:
reconciliation takes `ACCESS EXCLUSIVE` locks on the objects it drops, so external
readers may block briefly during application startup; and a long-running external
reader transaction that has called the guard holds a `FOR SHARE` lock on the group
row, delaying `beginGroupRebuild` (`FOR UPDATE`) until it finishes — identical in
kind to the delay in-process writers already impose.

If milestone 3 must be abandoned mid-way (e.g., a release freeze), milestones 1–2
stand alone: the runtime declaration and SQL surface are complete without the
language clause. The reverse is not true; do not start milestone 3 before
milestone 1 is merged.


## Interfaces and Dependencies

No new Haskell dependencies. The runtime work uses existing packages: `hasql` /
`hasql-transaction` (DDL via `Tx.sql`, statements via `Tx.statement`),
`cryptohash-sha256` + `base16-bytestring` (already used by
`Keiro.Projection.Catalog.Preimage`) for the identifier-derivation hash, and
`Keiro.Connection.quoteIdentifier` for identifier quoting. PostgreSQL 18 is the
supported baseline (ADR-9); the plpgsql features used (`RAISE ... USING ERRCODE`,
`SECURITY DEFINER`, `SET search_path`, `RETURNS SETOF <view>`) are far older.

At the end of milestone 1, `Keiro.Projection.Catalog` additionally exports:

```haskell
newtype ExternalReaderName
mkExternalReaderName :: Text -> Either CatalogIdentityError ExternalReaderName
externalReaderNameText :: ExternalReaderName -> Text
-- QueryModelBinding gains: externalReaders :: ![ExternalReaderName]
-- InventoryQueryModel gains: externalReaders :: ![ExternalReaderName]  (sorted, deduplicated)
data ExternalReadBinding   -- registry name, version, query id, backing InventoryTarget, readers
externalReadBindings :: ValidatedProjectionCatalog -> [ExternalReadBinding]
-- CatalogDiagnosticCode gains: DuplicateExternalReaderName | ExternalReadBackingUnresolved
```

At the end of milestone 2, `Keiro.Projection.Catalog.ExternalRead` (new exposed
module) exports:

```haskell
externalReadSchemaName :: Text
guardFunctionName :: Text
sqlstateReadModelNotLive :: Text      -- "KR001"
sqlstateReadModelUnregistered :: Text -- "KR002"
externalReadFunctionName :: Text -> Int -> Text
externalReadViewName :: TargetId -> Text
renderExternalReadSurfaceSql :: ValidatedProjectionCatalog -> [Text]
reconcileExternalReadSurfaceTx :: ValidatedProjectionCatalog -> Tx.Transaction ()
```

and `Keiro.ReadModel.Rebuild.Group` gains the `ExternalReadSchemaMissing` /
`AdoptExternalReadSchemaMissing` error constructors.

At the end of milestone 3, `keiro-dsl`'s `ReadModelNode` carries
`rmExternalReaders :: ![Text]`, `DiagnosticCode` carries the three
`CatalogReadModelExternalReader*` constructors plus
`CatalogQueryExternalReadersChanged`, and generated `ProjectionCatalog` modules
construct bindings with the reader list.

Plan-level dependencies: none hard. Soft dependency on
`docs/plans/254-publish-a-documented-projection-status-relation-for-external-readers.md`
(shared liveness vocabulary — this plan reads and documents
`keiro.keiro_projection_rebuild_groups.status` values `live`/`rebuilding`/`failed`;
reconcile wording if 254 lands first). Forward interface consumed by
`docs/plans/256-rebuild-into-versioned-targets-with-atomic-cutover.md`: the cutover
indirection specified in Context and Orientation; plan 256 re-points
`keiro_read."target__<targetId>"` views and must leave function identities, the
guard, and the SQLSTATE contract untouched.
