---
id: 311
slug: recognise-runtime-managed-read-objects-in-schema-verification-to-fix-bug-12
title: "Recognise runtime-managed read objects in schema verification to fix BUG-12"
kind: exec-plan
created_at: 2026-10-13T14:48:11Z
intention: "intention_01m4tvqj93e5z8ymnhpaw8z574"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-13T14:48:11Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-13T15:01:56Z
      mode: "update"
      note: "Self-guarding registry lookup with privilege fallback, keiro-managed rows only, Milestone 0 fixture committed pending"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:20:56Z
      mode: "update"
      note: "Correct noncompiling test examples and schema privilege guard; strengthen fallback/drift acceptance and align documentation, closure, and release guidance"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T03:29:55Z
      mode: "implement"
      note: "Implement registry-aware verification and reproduce BUG-12 with runtime and operator regression coverage"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:21:51Z
      verdict: "approved"
      note: "Approved after correcting Eq MigrationError and Session.sql compile blockers, reproducing and fixing the schema-USAGE guard, and strengthening acceptance; baseline schema tests pass"
---

# Recognise runtime-managed read objects in schema verification to fix BUG-12

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Every `keiro-ops` invocation first compares the live `keiro` and `keiro_read` PostgreSQL
schemas with an expected snapshot that is embedded in the `keiro-migrations` library. Any
difference is printed as a "schema drift" warning, and a command that mutates state refuses
to run unless the operator passes `--allow-schema-drift`. That gate exists so an operator
never mutates a database that a different binary shaped.

The embedded snapshot is generated from Keiro's migrations alone. Keiro's runtime, however,
also creates objects inside the `keiro` schema: when a service declares an all-rows
external-read contract (a small projection exposed to an outside reader through a
versioned SQL function), contract reconciliation creates the view
`keiro.external_read_<function>_binding`. The snapshot comparison lists every view in the
`keiro` schema, the expected snapshot carries no such view, and so every deployment with
such a contract sees `schema drift: unexpected view keiro.external_read_<function>_binding`
on every invocation and has every mutating operator command refused for the life of the
deployment. Operators learn to pass `--allow-schema-drift` routinely, and a genuine drift
hides behind the expected warning. Bug report
[BUG-12](../bug-reports/12-ops-schema-verification-flags-keiro-managed-binding-view.md)
records this from a consumer's PostgreSQL 18 test cluster.

After this plan, schema verification treats an object that Keiro's own runtime created and
recorded in its managed-object registry (`keiro.keiro_managed_read_objects`) as part of
Keiro's schema. A service with an all-rows contract runs `keiro-ops rebuild versioned
resume <run-id>` without a warning and without the flag, `keiro-migrate verify-schema`
prints `schema verification succeeded` against the same database, and a view in the
`keiro` schema that Keiro did not create is still reported as drift. Regression
coverage spans three layers: registry and comparison tests in `keiro-migrations`, an
end-to-end test in `keiro`
that reconciles a real all-rows contract and then verifies the schema, and an executable
test in `keiro-ops` that runs a forced mutation against a database carrying a registered
binding view.


## Progress


- [x] 2026-10-13: reviewed the plan against runtime, migration, operator, and dependency
      source; reproduced the missing-schema-privilege guard failure on PostgreSQL 18.6;
      corrected the plan. This entry records review-only validation; implementation evidence follows.
- [x] 2026-10-14 03:35Z: Milestone 0: reproduce BUG-12 with a compiled fixture on master, retain the failing
      transcript under `docs/bug-reports/evidence/`, commit the fixture as a pending `xit`
      example together with the `keiro-test` dependency, set the report `confirmed`, and log it.
- [x] 2026-10-14 03:36Z: Milestone 1: make `Keiro.Migrations.SchemaCheck` registry-aware (`managedObjectSnapshotKeys`,
      `compareSchemaSnapshotWithManaged`, the guarded lookup inside `verifyExpectedSchema`).
- [x] 2026-10-14 03:37Z: Milestone 1: add pure comparison, hand-altered-database, restricted-role, and
      absent-registry tests to `keiro-migrations/test/Main.hs`; all four pass.
- [x] 2026-10-14 03:36Z: Milestone 1: record the fix under `[Unreleased]` in `keiro-migrations/CHANGELOG.md`.
- [x] 2026-10-14 03:40Z: Milestone 2: flip the Milestone 0 fixture in `keiro/test/ExternalReadSpec.hs` from
      `xit` to `it`; it passes.
- [x] 2026-10-14 03:40Z: Milestone 2: add the executable regression to `keiro-ops/test/Main.hs`; it passes.
- [x] 2026-10-14 03:40Z: Milestone 2: record the operator-visible change under `[Unreleased]` in
      `keiro-ops/CHANGELOG.md`.
- [x] 2026-10-14 03:38Z: Milestone 3: update `docs/user/operations.md` and `docs/user/migrations.md`, advance
      their timestamps, and log the user-documentation bundle.
- [x] 2026-10-14 03:38Z: Milestone 3: update ADR 9 with the registry-aware verification decision, advance its
      timestamp, log the ADR bundle, and pass strict validation.
- [x] 2026-10-14 03:38Z: Milestone 3: record the fix under `[Unreleased]` in the root `CHANGELOG.md`.
- [x] 2026-10-14 04:03Z: Milestone 3: set BUG-12 `fixed` with `fixedVersion: unreleased` and a `resolution`,
      update the index coverage row, log the bundle, and pass strict validation.
- [x] 2026-10-14 04:03Z: Milestone 3: `nix develop -c just verify` passes; fill Outcomes & Retrospective.


## Surprises & Discoveries


Implementation fixture compilation found that `ExternalReadSpec` does not import
`map` from its restricted Prelude. The two fixture assertions now use `<$>`; this
changes no verifier behavior. The Nix shell supplies GHC 9.12.4, PostgreSQL 18.6,
and Z3 4.16.0. Hackage and upstream cohort tags both confirm 0.20.0.0 for the
added local test dependency.

The 2026-10-13 correctness review found that table `SELECT` does not imply schema
`USAGE`. A disposable PostgreSQL 18.6 cluster, started and stopped by a Python probe
inside `nix develop`, created the registry and granted a probe role table `SELECT` but
no access to the `keiro` schema. Under `SET ROLE`, the original guard accepted the role,
then the proposed registry query failed. Adding the schema privilege check rejected it:

```text
 original_guard | schema_usage | revised_guard
----------------+--------------+---------------
 t              | f            | f
ERROR: permission denied for schema keiro
psql exit: 3
```

This is evidence for the guard correction, not the compiled BUG-12 reproduction required
by Milestone 0. PostgreSQL permits catalog inspection without schema `USAGE`, which is
why the previous catalog-only verifier worked for this role.

The restricted-role example also used `Session.sql`, which is absent from the repository's
Hasql 1.10 API. The Mori guide `mori://hasql/hasql/docs/hasql-1.10-migration` records the
rename to `Session.script :: Text -> Session ()`; existing calls in
`keiro-migrations/test/Main.hs` already use `Session.script`. The corrected example uses
that API and resets the role with the existing IO-level `finally` import even if the
session fails.

The original Milestone 0 fixture also compared `Either MigrationError [Text]` with
`shouldBe Right []`. `MigrationError` from
`mori://shinzui/pg-migrate/packages/pg-migrate` has `Show` but no `Eq` instance, so that
fixture would fail to compile before it could reproduce BUG-12. Unwrap it with the
existing `expectUsage` helper in `keiro/test/ExternalReadSpec.hs`, then compare only the
rendered drift list. In `keiro-migrations/test/Main.hs`, use its existing `requireRight`
helper for the same reason.


## Decision Log


- Decision: the managed-object registry `keiro.keiro_managed_read_objects`, not a naming
  pattern such as `external_read_%_binding`, decides which live objects are Keiro's own.
  Rationale: the registry is written in the same transaction that creates the view, records
  the schema, name, and kind of every runtime-managed read object, and is private to Keiro.
  A naming pattern would hide a foreign view that happens to match it and would have to be
  extended by hand for every future runtime-managed object kind.
  Date: 2026-10-13
- Decision: the exclusion is applied in the comparison step, not in `snapshotSchema`.
  Rationale: `snapshotSchema` is also used to regenerate the checked-in expected snapshot
  (`KEIRO_REGENERATE_EXPECTED_SCHEMA=1`), and that snapshot must remain a faithful dump of
  what the migrations build. Filtering at comparison time keeps the raw snapshot honest and
  keeps the change observable in one pure function.
  Date: 2026-10-13
- Decision: every registry row with `managed_by = 'keiro'` counts, whatever its `state`
  (`active`, `pending-retirement`, `retired`); rows with `managed_by = 'consumer'` do not.
  Rationale: retirement marks objects retired but does not drop them
  ([ADR 36](../adr/0036-external-readers-use-versioned-guarded-sql-contracts.md)), so a
  retired binding view is still Keiro's. A `consumer`-managed row describes an
  application-owned object (today only `contract-type`, which is never snapshotted); the
  defect is about objects Keiro's own runtime creates, and the tighter filter is strictly
  more conservative at no cost. Today only `binding-view` rows map to a snapshot line; the
  other kinds (`guard-function`, `wrapper-function`, `contract-type`) are not snapshotted,
  and the mapping says so explicitly rather than guessing a future format.
  Date: 2026-10-13
- Decision: the registry lookup guards itself with one catalog statement that is true only
  when `keiro.keiro_managed_read_objects` exists as a table and the connected role holds
  `SELECT` on it and `USAGE` on its schema; otherwise the managed set is empty and
  verification behaves exactly as it did before this plan.
  Rationale: a database that predates migration 0027 has no registry table, and today's
  check reads only `pg_catalog`, which every role can read. Without the guard, a missing
  table or a role lacking either privilege would turn every invocation into
  `schema verification failed`, which blocks even read-only `keiro-ops` commands. With it,
  the pre-0027 database keeps its ordinary `MissingObject` list and the restricted role sees
  the binding view reported as drift: fail-closed rather than fail-stop. Resolving the
  relation through `pg_class` avoids the error the text form of `has_table_privilege`
  raises for a missing relation.
  Date: 2026-10-13; amended after the correctness review's PostgreSQL privilege probe.
- Decision: test absent-registry fallback and preserve migration-owned differences even
  when the same key appears in the managed set.
  Rationale: ignoring runtime additions must not hide a missing or changed object from the
  migration snapshot. The table-absence guard is a separate branch from denied privileges
  and needs its own database test.
  Date: 2026-10-13
- Decision: a registry row whose object no longer exists is not reported by this plan.
  Rationale: BUG-12 is a false positive. Reporting a missing managed object is a new
  capability with its own questions (the next reconciliation recreates the view with
  `CREATE OR REPLACE VIEW`; a retired row may legitimately outlive a view an operator
  dropped). It is recorded as a follow-up in Outcomes & Retrospective, not folded in.
  Date: 2026-10-13
- Decision: the public type of `verifyExpectedSchema` does not change.
  Rationale: `keiro-ops` (`keiro-ops/src/Keiro/Ops.hs`) and `keiro-migrate`
  (`keiro-migrations/app/Main.hs`) both call it and need no code change; the fix is a
  behaviour change inside `keiro-migrations` plus two new exports, which is a PVP minor
  bump recorded under `[Unreleased]`. The release plan that cuts the next cohort chooses
  the version number.
  Date: 2026-10-13
- Decision: the PostgreSQL-major restriction in `verifyExpectedSchema`
  (`UnsupportedPostgresVersion` for anything other than 18) stays as it is.
  Rationale: the bug report names it as a separate limitation and does not assert it as a
  defect; ADR 9 records PostgreSQL 18 as the only native expected-schema baseline.
  Date: 2026-10-13
- Decision: Milestone 0 commits its fixture as a pending `xit` example instead of leaving
  the edits uncommitted until Milestone 2.
  Rationale: this checkout is shared with parallel review sessions that commit to `master`.
  An uncommitted change to `keiro/keiro.cabal` and `keiro/test/ExternalReadSpec.hs` could be
  swept into another session's commit or conflict with its edits. A pending example keeps
  every commit green while the evidence transcript records the failing run.
  Date: 2026-10-13
- Decision: BUG-12 moves to `confirmed` only after the compiled fixture in Milestone 0 fails
  on master with the exact unexpected view, and to `fixed` with `fixedVersion: unreleased`
  only after `just verify` passes in Milestone 3.
  Rationale: the bundle profile reserves `confirmed` for reproduction by the owning
  repository, and a plan that is written but not implemented does not change a status
  (see the coverage notes in `docs/bug-reports/index.md`).
  Date: 2026-10-13


## Outcomes & Retrospective


BUG-12 is fixed in the working tree and remains unreleased. The registry-aware
comparison permits only unexpected runtime binding views recorded as Keiro-managed;
it preserves missing and changed migration-owned objects, unregistered and
consumer-managed additions, and conservative fallback for absent or unreadable
registries. Raw snapshots and the existing public verifier signature are unchanged.

The compiled runtime fixture failed at baseline commit
`b82e308eb3d0570501928309b909e7b4b2ec6656` with exactly the unexpected binding view,
after its pre-reconciliation assertion passed. The transcript is retained at
`docs/bug-reports/evidence/BUG-12-master-binding-view-drift.txt`. It was committed
pending in `58a5d155`, the library fix in `b13d814d`, and passing runtime/operator
regressions in `943a2a09`.

Validation ran in the Nix development shell with GHC 9.12.4, PostgreSQL 18.6,
and Z3 4.16.0. The focused runtime block passed all seven examples; the operator
executable block passed both success and genuine-drift refusal examples. The full
migration suite passed all 40 examples, including all four new regressions.
A disposable PostgreSQL cluster migrated with the built CLI also proved:

```text
active: exit 0; schema verification succeeded
pending-retirement: exit 0; schema verification succeeded
retired: exit 0; schema verification succeeded
unregistered neighbour: exit 1; schema drift: unexpected view keiro.external_read_rogue_v1_binding (actual: columns=1:id bigint)
```

The repository-wide gate completed successfully on 2026-10-14:

```bash
nix develop -c just verify
```

```text
keiro-test: 756 examples, 0 failures
keiro-retention: 15 examples, 0 failures
keiro-pgmq-test: 80 examples, 0 failures, 2 pending
keiro-ops-test: 51 examples, 0 failures
keiro-dsl-test: 806 examples, 0 failures
keiro-migrations-test: 40 examples, 0 failures
just verify: exit 0
```

All DSL conformance suites, Jitsurei checks, documentation bundles, repository
policies, hydration and mutation proofs, replay compatibility, and mapped-consumer
adoption checks included in that gate passed. The two pre-existing PGMQ pending
examples require a deterministic polling fault injector and a pg_partman-enabled
fixture, respectively; none of this plan's regressions is pending. Only documentation
and bug-closure metadata changed after the full gate.

ADR 9 now records the durable registry authority, comparison-only exception,
lifecycle rule, and privilege fallback. Operations and migration documentation and
all three changelogs describe the behavior. BUG-12 is `fixed` with `fixedVersion: unreleased`; strict closure validation
passed with all 12 bug-report concepts valid. Every implementation milestone is
complete.

Missing or altered runtime-only object definitions remain a deliberate follow-up:
a registry row establishes which additions are allowed, not whether their live
definition is correct. Installed operator binaries must be rebuilt against the
fixed migration library; version selection and cohort bounds remain release work.


## Context and Orientation


Keiro is a Haskell package set for event-sourced services on PostgreSQL. This plan touches
three of its packages, all built with Cabal inside the repository's Nix development shell:

- `keiro-migrations` owns the `keiro` and `keiro_read` schemas. Its migrations live in
  `keiro-migrations/migrations/`, and its library module
  `keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` implements live-schema
  verification. The CLI in `keiro-migrations/app/Main.hs` exposes that verification as
  `keiro-migrate verify-schema`.
- `keiro` is the runtime library. `keiro/src/Keiro/ReadModel/External.hs` reconciles
  external-read contracts and creates the objects this plan is about.
- `keiro-ops` is the operator console. `keiro-ops/src/Keiro/Ops.hs` runs the schema
  verification before every command.

The following terms are used throughout.

An **expected schema snapshot** is the checked-in text file
`keiro-migrations/expected-schema/native/keiro-v18.txt`. Each line is
`kind<TAB>name<TAB>definition`, for example `table<TAB>keiro_outbox<TAB>kind=r` or
`view<TAB>keiro_read.projection_group_status_v1<TAB>columns=1:group_id text,...`. The
file is generated by applying every migration to a fresh PostgreSQL 18 database and running
`snapshotSchema` for the `keiro` and `keiro_read` schemas; the test
"checked-in snapshot matches what the migrations build" in
`keiro-migrations/test/Main.hs` regenerates it when `KEIRO_REGENERATE_EXPECTED_SCHEMA` is
set. The file currently holds twenty-five tables and exactly one view,
`keiro_read.projection_group_status_v1`. The library embeds it at compile time as
`expectedSchemaSnapshot`.

**Schema drift** is one named difference between that snapshot and a live database, as the
type `SchemaDrift` in `SchemaCheck.hs`: `MissingObject` (expected, not live),
`UnexpectedObject` (live, not expected), or `ChangedObject` (both, different definition).
`compareSchemaSnapshot :: Text -> Text -> [SchemaDrift]` is the pure comparison keyed on
`kind<TAB>name`. `verifyExpectedSchema :: Settings -> IO (Either MigrationError [SchemaDrift])`
opens a connection, refuses any PostgreSQL major other than 18, snapshots both schemas with
`snapshotSchema`, and compares. The SQL in `schemaSnapshotStatement` lists tables
(`relkind = 'r'`), their columns, constraints, indexes, and every view (`relkind = 'v'`)
in the requested schema. Functions and composite types are not listed.

The **keiro-ops mutation gate** is in `runInvocation` in `keiro-ops/src/Keiro/Ops.hs`. It
calls `verifyExpectedSchema`, prints each drift to standard error prefixed with
`warning: `, and, when the command `isMutation` and the drift list is non-empty and
`--allow-schema-drift` was not passed, exits with
`refusing mutation because the live schema differs from this binary; inspect the warnings
or pass --allow-schema-drift`. The same list is handed to command handlers as
`schemaDrift` in `OpsEnv`.

An **external-read contract** is a declaration in a service's projection catalog
(`Keiro.Projection.Catalog`, type `ExternalReadContract`) that publishes one projection
query to readers outside the Haskell process through a versioned, guarded SQL function in
`keiro_read`. It comes in two kinds. A **keyed** contract (`KeyedExternalRead`) wraps an
application-provided function. An **all-rows** contract (`AllRowsExternalRead`) exposes a
whole small table; for it, Keiro itself creates a private **binding view** named
`keiro.external_read_<function>_binding` (`bindingViewName` and `bindingViewSql` in
`External.hs`, using `CREATE OR REPLACE VIEW ... WITH (security_barrier = true,
security_invoker = false)`), revokes `PUBLIC` from it, and makes the public wrapper function
`keiro_read.<function>` read from it. `toSpec` in `externalReadSpecs` supplies the binding
table only for `InventoryAllRowsExternalRead`; a keyed contract has no binding view.
This happens inside **contract reconciliation** (`reconcileExternalReadContracts` and its
transactional variants), which runs at catalog registration, adoption, versioned-rebuild
start, and promotion. It is runtime work, not a migration, so no snapshot line describes
the view.

The **managed-object registry** is the table `keiro.keiro_managed_read_objects`, created by
`keiro-migrations/migrations/0027.sql`. Its primary key is
`(object_schema, object_name, object_kind, object_signature)`; `object_kind` is one of
`guard-function`, `binding-view`, `wrapper-function`, `contract-type`; `managed_by` is
`keiro` or `consumer`; `state` is `active`, `pending-retirement`, or `retired`;
`contract_id` and `contract_version` are both null or both set. `reconcileBinding` in
`External.hs` first checks ownership with `managedObjectAuthority` (a live object with no
registry row is an `ExternalReadUnmanagedObjectCollision`), then creates the view, then
upserts the row `('keiro', 'external_read_<function>_binding', 'binding-view', '', ...,
managed_by = 'keiro', state = 'active')` through `upsertManagedObjectStmt`. Retirement
(`retireContractStmt`) sets the contract's rows to `retired` and does not drop the view.

The defect is therefore a mismatch of authorities: verification knows only the objects the
migrations create, while the registry knows the objects the runtime created. The fix makes
verification consult the registry before calling a live object unexpected.

Three ADRs govern this work and are summarised here so the plan stands alone.

[ADR 9, Keiro owns live schema verification under pg-migrate](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md)
decides that live-schema verification is a Keiro-owned gate separate from pg-migrate's
ledger check, that the expected snapshot is a checked-in sorted text file covering tables,
columns, constraints, indexes, and the ordered column signature of views in `keiro` and
`keiro_read`, that it targets PostgreSQL 18, and that `SchemaCheck` exposes two layers:
`snapshotSchema` for callers owning a session and `verifyExpectedSchema` for callers with
connection settings. Milestone 3 extends this ADR with the registry-aware rule; it does not
change the snapshot format.

[ADR 28, Operator commands wrap supported library APIs and respect schema ownership](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
decides that `keiro-ops` verifies the schema with `verifyExpectedSchema` before opening the
operational environment, that read-only commands may continue after warnings, and that
mutations refuse drift unless `--allow-schema-drift` is passed. This plan keeps that gate
unchanged; it changes what counts as drift.

[ADR 36, External readers use versioned guarded SQL contracts](../adr/0036-external-readers-use-versioned-guarded-sql-contracts.md)
decides the shape of external-read contracts, that Keiro reconciles managed objects
individually and records them, that an all-rows binding projects exactly the composite
type's columns, and that retirement marks objects retired without dropping them. It is the
reason every registry state counts as Keiro-owned.

No cross-repository ADR is relevant.

Existing tests to pattern after: the `describe "native expected schema"` block in
`keiro-migrations/test/Main.hs` (pure classification, snapshot regeneration, and
"detects named drift after a hand-altered database", which migrates a fresh database with
`withKeiroPg`, runs `verifyExpectedSchema`, alters the schema with `Session.script`, and
checks the rendered drift lines); the first `it` in `keiro/test/ExternalReadSpec.hs`, which
runs `allRowsFixtureSql`, validates `Catalog.bridgeCatalog` (one all-rows contract
`counter_reader` version 1 whose function is `counter_reader_v1`), registers it, runs
`activateV1Sql`, and reconciles, after which `keiro.external_read_counter_reader_v1_binding`
exists; and "emits parseable JSON and refuses a mutation after schema drift" in
`keiro-ops/test/Main.hs`, which runs the built `keiro-ops` executable against a fresh
database, adds a column with `executeSql`, and expects the forced `wf gc run-once` to be
refused.

Dependency facts that matter: `keiro-test-support` already depends on `keiro-migrations`,
but the `keiro-test` suite in `keiro/keiro.cabal` does not list `keiro-migrations` in its
`build-depends`, so Milestone 0 adds it. `keiro-ops` already depends on both.


## Plan of Work


### Milestone 0: confirm BUG-12 with a compiled fixture


The report arrived from a consumer and was validated from source on master; the bundle
profile reserves `confirmed` for a reproduction by this repository. This milestone writes
the end-to-end regression test first, watches it fail on unmodified master with the exact
unexpected view, records that failure as evidence, and then commits the test as a pending
example so this shared checkout never carries an uncommitted or failing test.

Add `keiro-migrations ^>=0.20.0.0` to the `build-depends` of `test-suite keiro-test` in
`keiro/keiro.cabal`. In `keiro/test/ExternalReadSpec.hs`, import
`Keiro.Migrations.SchemaCheck (renderSchemaDrift, verifyExpectedSchema)` and add a new
`it` inside the existing `describe "managed external read contracts"` block:

```haskell
      it "leaves schema verification clean after reconciling an all-rows contract" $ \connectionString ->
        withPool connectionString $ \pool ->
          Store.withStore (Store.defaultConnectionSettings connectionString) $ \store -> do
            let settings = ConnectionSettings.connectionString connectionString
            runScript pool allRowsFixtureSql
            beforeDrifts <- verifyExpectedSchema settings >>= expectUsage
            (renderSchemaDrift <$> beforeDrifts) `shouldBe` []
            catalog <- expectValid Catalog.bridgeCatalog
            register store catalog
            runScript pool activateV1Sql
            expectStore store (reconcileExternalReadContracts catalog) >>= shouldBeRight
            runStatement pool () bindingExistsStmt `shouldReturn` True
            afterDrifts <- verifyExpectedSchema settings >>= expectUsage
            (renderSchemaDrift <$> afterDrifts) `shouldBe` []
```

`expectUsage` is already defined in this spec and fails an example on `Left` using
only `Show`; it avoids requiring an unavailable `Eq MigrationError` instance.

`bindingExistsStmt` is a small `Statement () Bool` beside the other statements at the
bottom of the file: `SELECT to_regclass('keiro.external_read_counter_reader_v1_binding')
IS NOT NULL`. The `before` check proves the fixture itself (schemas `app` and
`app_contract`) does not disturb the `keiro` and `keiro_read` schemas; if it ever reports
drift, record the offending line in Surprises & Discoveries before continuing, because the
remaining assertions would then be measuring the wrong thing.

Run the suite for that block. On master the final assertion fails with one rendered drift,
`schema drift: unexpected view keiro.external_read_counter_reader_v1_binding (actual:
columns=1:id bigint,2:total bigint)`. Save the command, the commit hash, the environment
line (`nix develop` shell, GHC version, PostgreSQL version from `nix develop -c postgres
--version`), and the failing assertion verbatim to
`docs/bug-reports/evidence/BUG-12-master-binding-view-drift.txt`, following the layout of
`docs/bug-reports/evidence/BUG-11-master-keyword-segment-ghc-61689.txt`.

Then change that example's `it` to `xit` and put the comment
`-- Pending until plan 311 Milestone 2 lands the registry-aware comparison.` on the line
above it. hspec runs an `xit` example as pending: the suite stays green and the summary
counts one pending example. Re-run the match to confirm.

Then edit `docs/bug-reports/12-ops-schema-verification-flags-keiro-managed-binding-view.md`:
set `status: confirmed`, advance `generated.at` to the current UTC time, and append a short
paragraph after the "Tracked by plan 311" paragraph stating that the owning repository
reproduced the drift on master with the compiled fixture and names the evidence file. Update
the BUG-12 row in `docs/bug-reports/index.md` to `confirmed` with the same note, add a log
entry with `okf log add docs/bug-reports --kind Update -m "..."`, and run
`just bug-reports-validate`. Commit the evidence file, the three bundle files,
`keiro/keiro.cabal`, and the spec together.

Acceptance: the evidence file exists and names the unexpected view; the bundle validates
strictly; the `keiro` suite reports the new example as pending; the working tree is clean.


### Milestone 1: registry-aware comparison in keiro-migrations


This milestone changes `keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` so that
verification consults the managed-object registry, and proves it at the library level
without needing the runtime.

Add two exports to the module header: `managedObjectSnapshotKeys` and
`compareSchemaSnapshotWithManaged`. Keep every existing export.

Define the pure comparison with an exclusion set and make the old name a specialisation:

```haskell
-- | Compare canonical snapshots by their @kind<TAB>name@ object identity. A live
-- object whose key is in the managed set is Keiro's own runtime object and is
-- never reported as unexpected; it is still compared when the expected snapshot
-- also lists it.
compareSchemaSnapshotWithManaged :: Set Text -> Text -> Text -> [SchemaDrift]
compareSchemaSnapshotWithManaged managed expected actual =
  mapMaybe driftFor allKeys
  where
    expectedObjects = snapshotObjects expected
    actualObjects = snapshotObjects actual
    allKeys =
      Set.toAscList
        (Map.keysSet expectedObjects `Set.union` Map.keysSet actualObjects)

    driftFor key =
      case (Map.lookup key expectedObjects, Map.lookup key actualObjects) of
        (Just (expectedLine, _), Nothing) ->
          Just (MissingObject expectedLine)
        (Nothing, Just (actualLine, _))
          | Set.member key managed -> Nothing
          | otherwise -> Just (UnexpectedObject actualLine)
        (Just (_, expectedValue), Just (_, actualValue))
          | expectedValue /= actualValue ->
              Just
                ChangedObject
                  { driftKey = key,
                    expectedDefinition = expectedValue,
                    actualDefinition = actualValue
                  }
        _ -> Nothing

compareSchemaSnapshot :: Text -> Text -> [SchemaDrift]
compareSchemaSnapshot = compareSchemaSnapshotWithManaged Set.empty
```

Define the registry lookup as a session, mapping each Keiro-managed registry row to the
snapshot key it accounts for. Only `binding-view` rows have a snapshot line today, because
the snapshot lists views but not functions or types; the mapping returns `Nothing` for every
other kind so a future object kind is a deliberate decision rather than an accident. The
lookup guards itself: one catalog statement answers whether the registry is a table the
connected role may read, and when it is not, the set is empty and verification behaves as it
did before this plan. The module already uses multiline string literals for
`schemaSnapshotStatement`, so the same form works here:

```haskell
-- | Snapshot keys of the objects Keiro's runtime created and recorded in
-- @keiro.keiro_managed_read_objects@ with @managed_by = 'keiro'@. Every state
-- counts: retirement marks a managed object retired without dropping it. Rows
-- whose kind has no snapshot line (functions and types) map to nothing. When
-- the registry table does not exist, or the connected role lacks table @SELECT@
-- or schema @USAGE@, the set is empty and verification reports every live object
-- as before.
managedObjectSnapshotKeys :: Session (Set Text)
managedObjectSnapshotKeys = do
  readable <- Session.statement () registryReadableStatement
  if readable
    then Set.fromList . mapMaybe snapshotKey <$> Session.statement () managedObjectsStatement
    else pure Set.empty
  where
    snapshotKey (schema, name, kind)
      | kind == "binding-view" = Just ("view\t" <> schema <> "." <> name)
      | otherwise = Nothing

-- | True only when @keiro.keiro_managed_read_objects@ is a table the connected
-- role may read. Resolving the relation through @pg_class@ avoids the error
-- that the text form of @has_table_privilege@ raises for a missing relation.
registryReadableStatement :: Statement () Bool
registryReadableStatement =
  Statement.preparable
    """
    SELECT coalesce(
      ( SELECT pg_catalog.has_table_privilege(c.oid, 'SELECT')
                 AND pg_catalog.has_schema_privilege(n.oid, 'USAGE')
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'keiro'
          AND c.relname = 'keiro_managed_read_objects'
          AND c.relkind = 'r' ),
      false)
    """
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

managedObjectsStatement :: Statement () [(Text, Text, Text)]
managedObjectsStatement =
  Statement.preparable
    """
    SELECT object_schema, object_name, object_kind
    FROM keiro.keiro_managed_read_objects
    WHERE managed_by = 'keiro'
    """
    Encoders.noParams
    ( Decoders.rowList
        ( (,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
        )
    )
```

The view key uses `schema.name` because `schemaSnapshotStatement` renders view lines as
`view<TAB>nspname.relname<TAB>columns=...` while table lines carry the bare `relname`; the
test in this milestone pins that shape.

Change `liveSnapshotSession` inside `verifyExpectedSchema` so that, after snapshotting both
schemas, it reads the managed set (the lookup guards itself, so no further condition is
needed here) and returns it alongside the text. Then compare with
`compareSchemaSnapshotWithManaged managed expectedSchemaSnapshot actual`:

```haskell
    liveSnapshotSession :: Session (Either MigrationError (Set Text, Text))
    liveSnapshotSession = do
      serverVersionNumber <- Session.statement () serverVersionStatement
      let majorVersion = fromIntegral serverVersionNumber `div` 10000
      if majorVersion == (18 :: Int)
        then do
          privateSchema <- snapshotSchema "keiro"
          publicSchema <- snapshotSchema "keiro_read"
          managed <- managedObjectSnapshotKeys
          pure (Right (managed, privateSchema <> publicSchema))
        else pure (Left (UnsupportedPostgresVersion majorVersion))
```

Update the module's Haddock on `verifyExpectedSchema` to say that runtime-managed
binding views recorded as Keiro-managed are allowed additions and that a role without
table `SELECT` or schema `USAGE` gets the previous behaviour. Only unexpected `binding-view` keys are suppressed; missing
and changed migration-owned objects remain drift. Registry identity does not validate the
live definition or `definition_hash` of a runtime-only view.

Add four tests to the `describe "native expected schema"` block of
`keiro-migrations/test/Main.hs`. The first is pure:

```haskell
    it "treats a managed live object as expected and still reports its unregistered neighbours" $ do
      let expected = Text.unlines ["table\twidgets\tkind=r"]
          actual =
            Text.unlines
              [ "table\twidgets\tkind=r",
                "view\tkeiro.external_read_demo_v1_binding\tcolumns=1:id bigint",
                "view\tkeiro.external_read_rogue_v1_binding\tcolumns=1:id bigint"
              ]
          managed = Set.fromList ["view\tkeiro.external_read_demo_v1_binding"]
      compareSchemaSnapshotWithManaged managed expected actual
        `shouldBe` [UnexpectedObject "view\tkeiro.external_read_rogue_v1_binding\tcolumns=1:id bigint"]
      compareSchemaSnapshot expected actual `shouldSatisfy` ((== 2) . length)
```

In the same pure example, include a migration-owned view key in both the expected
snapshot and the managed set. Assert that a changed column signature still produces the
exact `ChangedObject`, and that removing the live line still produces the exact
`MissingObject`. Also assert empty-set equivalence with `compareSchemaSnapshot` over
these cases. These assertions prevent implementing the exclusion by deleting managed
keys from either snapshot before comparison.

The second mirrors "detects named drift after a hand-altered database": migrate a fresh
database with `withKeiroPg`, assert a clean verification, then run one script that creates
a binding view with a Keiro-managed registry row, a second view with no row, and a third
view with a `consumer`-managed row, and assert that only the second and third are reported;
then set the Keiro-managed row to `pending-retirement` and finally `retired`,
asserting the same drift list at each state:

```sql
CREATE VIEW keiro.external_read_demo_v1_binding
  WITH (security_barrier = true, security_invoker = false)
  AS SELECT 1::bigint AS id, 10::bigint AS total;
INSERT INTO keiro.keiro_managed_read_objects
  (object_schema, object_name, object_kind, object_signature,
   managed_by, definition_hash, surface_generation, state)
VALUES ('keiro', 'external_read_demo_v1_binding', 'binding-view', '',
        'keiro', 'test-definition', 1, 'active');
CREATE VIEW keiro.external_read_rogue_v1_binding AS SELECT 1::bigint AS id;
CREATE VIEW keiro.external_read_foreign_v1_binding AS SELECT 1::bigint AS id;
INSERT INTO keiro.keiro_managed_read_objects
  (object_schema, object_name, object_kind, object_signature,
   managed_by, definition_hash, surface_generation, state)
VALUES ('keiro', 'external_read_foreign_v1_binding', 'binding-view', '',
        'consumer', 'test-definition', 1, 'active');
```

followed, after the first assertion, by the pending state (assert the same drift list
before applying the retirement update):

```sql
UPDATE keiro.keiro_managed_read_objects
SET state = 'pending-retirement', updated_at = now()
WHERE object_name = 'external_read_demo_v1_binding';
```

Then retire the object:

```sql
UPDATE keiro.keiro_managed_read_objects
SET state = 'retired', retired_at = now(), updated_at = now()
WHERE object_name = 'external_read_demo_v1_binding';
```

All three assertions check `map renderSchemaDrift drifts` with `shouldBe` against the two lines
`schema drift: unexpected view keiro.external_read_foreign_v1_binding (actual: columns=1:id bigint)`
and `schema drift: unexpected view keiro.external_read_rogue_v1_binding (actual: columns=1:id bigint)`,
in that order, because drifts are emitted in ascending key order. The registry rows need no
contract because `contract_id` and `contract_version` may both be null; `definition_hash`
and `surface_generation` only have to be non-empty and positive.

The third proves the privilege fallback at the session level, because `verifyExpectedSchema`
owns its connection and cannot switch roles. Migrate a fresh database, create the demo view
and its Keiro-managed row as above, create a role that may use the `keiro` schema but may not
read the registry, and compare the managed set as the owner and as that role:

```sql
DO $probe$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'keiro_verify_probe') THEN
    CREATE ROLE keiro_verify_probe NOLOGIN;
  END IF;
END
$probe$;
GRANT keiro_verify_probe TO CURRENT_USER;
GRANT USAGE ON SCHEMA keiro TO keiro_verify_probe;
```

```haskell
    it "returns no managed keys for a role that cannot read the registry" $ do
      plan <- requirePlan
      withKeiroPg $ \database -> do
        let settings = Pg.connectionSettings database
        _ <- runMigrationPlan defaultRunOptions settings plan >>= requireRight
        withConnection settings $ \connection -> do
          useSession connection (Session.script registryProbeSql)
          owner <- useSession connection managedObjectSnapshotKeys
          owner `shouldBe` Set.fromList ["view\tkeiro.external_read_demo_v1_binding"]
          restricted <-
            useSession
              connection
              (Session.script "SET ROLE keiro_verify_probe" *> managedObjectSnapshotKeys)
              `finally` useSession connection (Session.script "RESET ROLE")
          restricted `shouldBe` Set.empty
```

`registryProbeSql` is the demo view, its row, and the role script above in one literal. The
`DO` block keeps the role creation repeatable, and `GRANT ... TO CURRENT_USER` lets a
test administrator switch to the probe role; creating the role still requires
`CREATEROLE` or superuser rights, supplied by the disposable fixture. `SET ROLE` lasts
for the connection, which is why the example resets it on the same session; `ephemeral-pg` discards the cluster
afterwards in any case. The owner assertion pins that the privileged path still returns the
key, so the fallback is not masking a broken query.

Extend this example with a second permission configuration, applied as the administrator:

```sql
REVOKE USAGE ON SCHEMA keiro FROM keiro_verify_probe;
GRANT SELECT ON keiro.keiro_managed_read_objects TO keiro_verify_probe;
```

Now run the helper on a fresh connection under `SET ROLE keiro_verify_probe` and again
expect `Set.empty`. Using a fresh connection avoids previously prepared queries affecting
schema-lookup evidence. The schema has no `PUBLIC` usage grant; preserve that fixture
condition. For each permission configuration, also snapshot `keiro` and `keiro_read` in
the restricted session and compare them with the returned set. Expect exactly the demo
binding view as `UnexpectedObject`, not a session error. Reset the role using `finally`
as above. Finally grant schema `USAGE` back and prove that the probe role with both grants
gets the demo key and a clean comparison. This tests the actual privilege boundary rather
than merely distinguishing an owner from every other role.

The fourth example, named "falls back to ordinary drift when the registry is absent",
uses a fresh `withKeiroPg` database. Before migrating, run `managedObjectSnapshotKeys`
and expect `Set.empty`, then call `verifyExpectedSchema` and require `Right` with a
`MissingObject` for `table<TAB>keiro_managed_read_objects<TAB>kind=r`. Next migrate normally,
create the demo view and its registry row, and drop only
`keiro.keiro_managed_read_objects` in this disposable database, without `CASCADE`. This
covers an existing `keiro` schema with an absent registry table. Read the raw snapshots,
assert the helper returns `Set.empty`, unwrap `verifyExpectedSchema` with the existing
`requireRight`, and compare the drift list with
`compareSchemaSnapshot expectedSchemaSnapshot actual`. The result must include
both the missing registry table and the unexpected demo view. Neither absence case may
produce `DatabaseSessionFailed`. The test covers lookup fallback, not historical migration
compatibility, and must never run against an operator's database.

Add to `keiro-migrations/CHANGELOG.md` under `## [Unreleased]`:

```markdown
### Bug Fixes

- `verify-schema` and `Keiro.Migrations.SchemaCheck.verifyExpectedSchema` no longer
  report a view that Keiro's runtime created and recorded in
  `keiro.keiro_managed_read_objects`, such as the
  `keiro.external_read_<function>_binding` view behind an all-rows external-read
  contract, as unexpected drift. Only rows with `managed_by = 'keiro'` count; a role
  without table `SELECT` or schema `USAGE` keeps the previous behaviour. New exports
  `managedObjectSnapshotKeys` and `compareSchemaSnapshotWithManaged`;
  `compareSchemaSnapshot` is unchanged.
```

Commit this milestone on its own. Acceptance: `cabal test keiro-migrations:keiro-migrations-test`
passes, including the four new tests and the unchanged "detects named drift after a
hand-altered database" test, which proves migration-owned missing and changed objects
are still reported; the new neighbour assertions prove unregistered objects remain drift.


### Milestone 2: end-to-end and operator regressions


With the library fixed, flip the Milestone 0 fixture in `keiro/test/ExternalReadSpec.hs`
from `xit` back to `it`, delete the pending comment, and watch it pass; this milestone also
adds the operator-level proof.

In `keiro-ops/test/Main.hs`, inside `describe "keiro-ops executable"`, add:

```haskell
    it "does not treat a registered binding view as schema drift" $ \connectionString -> do
      executable <- keiroOpsExecutable
      executeSql
        connectionString
        """
        CREATE VIEW keiro.external_read_demo_v1_binding
          WITH (security_barrier = true, security_invoker = false)
          AS SELECT 1::bigint AS id, 10::bigint AS total;
        INSERT INTO keiro.keiro_managed_read_objects
          (object_schema, object_name, object_kind, object_signature,
           managed_by, definition_hash, surface_generation, state)
        VALUES ('keiro', 'external_read_demo_v1_binding', 'binding-view', '',
                'keiro', 'test-definition', 1, 'active');
        """
      (listExit, _, listError) <-
        readProcessWithExitCode
          executable
          ["--database-url", Text.unpack connectionString, "wf", "list", "--json"]
          ""
      listExit `shouldBe` ExitSuccess
      listError `shouldBe` ""
      (mutationExit, _, mutationError) <-
        readProcessWithExitCode
          executable
          [ "--database-url", Text.unpack connectionString,
            "wf", "gc", "run-once", "--retention", "0s", "--force", "--json" ]
          ""
      mutationExit `shouldBe` ExitSuccess
      mutationError `shouldSatisfy` not . Text.isInfixOf "schema drift" . Text.pack
      mutationError `shouldSatisfy` not . Text.isInfixOf "refusing mutation" . Text.pack
```

`keiro-ops/test/Main.hs` does not enable `MultilineStrings` today, so either add
`{-# LANGUAGE MultilineStrings #-}` as its first line, exactly as
`keiro/test/ExternalReadSpec.hs` does, or build the script with `Text.unlines`. Either way
it must stay one script so the view and its registry row are created together. The forced garbage-collection pass on an empty workflow table completes with an
empty result and exit code 0, which is the same success path the existing JSON tests take.

Add to `keiro-ops/CHANGELOG.md` under `## [Unreleased]`:

```markdown
### Bug Fixes

- Schema verification no longer warns about, or refuses mutations because of, the
  `keiro.external_read_<function>_binding` view that Keiro creates for an all-rows
  external-read contract. Binding views recorded with `managed_by = 'keiro'` are allowed runtime
  additions when verification can read the registry; `--allow-schema-drift` is again reserved for schemas this
  binary was not built for. Fixed in `keiro-migrations`; no `keiro-ops` source change.
```

Commit the `keiro` spec flip, the `keiro-ops` test, and the changelog together.
Acceptance: `cabal test keiro:keiro-test` with the "managed external read contracts" match
and `cabal test keiro-ops:keiro-ops-test` with the "keiro-ops executable" match both pass;
the pre-existing refusal test in the same block still passes, so a hand-added column is
still refused.


### Milestone 3: documentation, ADR, changelog, and bug-report closure


Update the operator-facing documentation so the new rule is stated where operators read
about the gate. In `docs/user/operations.md`, after the sentence "Mutations fail closed on
drift unless the operator explicitly supplies `--allow-schema-drift`...", add a paragraph:
binding views recorded in `keiro.keiro_managed_read_objects` with `managed_by = 'keiro'`,
such as `keiro.external_read_<function>_binding`, are allowed runtime additions when the
verifier has table `SELECT` and schema `USAGE`. State explicitly that consumer-managed
and unregistered objects are still drift, migration-owned missing or changed objects
remain checked, and a missing or unreadable registry preserves the previous comparison. In
`docs/user/migrations.md`, extend the `verify-schema` bullet the same way. Both pages carry a `generated` block; `operations.md` also has a `timestamp`.
Add the missing `timestamp` to `migrations.md` and advance the revision times
to the current UTC time, add one entry with `okf log add docs/user -m "..."`, and run
`just user-documentation-validate`.

Update [ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md): in
its Decision section, after the paragraph describing the two layers of `SchemaCheck`, add
a paragraph recording that the expected snapshot describes only what the migrations build,
that Keiro's runtime also creates read objects inside `keiro` and records each one in
`keiro.keiro_managed_read_objects` in the same transaction, and that `verifyExpectedSchema`
therefore suppresses only `UnexpectedObject` for a `binding-view` key recorded with
`managed_by = 'keiro'`, in every lifecycle state. Missing and changed migration-owned
objects and unregistered additions remain drift. The lookup uses a catalog existence and
privilege guard, requiring an ordinary table plus table `SELECT` and schema `USAGE`; it
does not infer readability from a snapshot line. A registry row without a live runtime
object is not reported, and a runtime-only view's definition is not validated by this
identity-based exception. Add
a Consequences bullet that a service with an all-rows external-read contract runs operator
mutations without `--allow-schema-drift`, and a References bullet pointing at this plan.
Advance the ADR's `timestamp`, run `okf log add docs/adr --kind Update -m "..."`, and run
`just adr-validate`. Do not allocate a new ADR; the decision belongs to ADR 9's topic.

Add to the root `CHANGELOG.md` under `## [Unreleased]` a `### Bug Fixes` entry mirroring the
`keiro-migrations` one and naming BUG-12.

Run `nix develop -c just verify` after the implementation and documentation edits and
before changing BUG-12 from `confirmed` to `fixed`. Repair any failure before closure.

Then close the bug report: in `docs/bug-reports/12-ops-schema-verification-flags-keiro-managed-binding-view.md`
set `status: fixed`, add `fixedVersion: "unreleased"` and a one-sentence `resolution`
naming the registry-aware comparison and this plan, advance `generated.at`, and append a
paragraph to the body describing the fix and regression coverage across all three packages. Update the
BUG-12 row in `docs/bug-reports/index.md` (status `fixed`, plan 311, implementation note),
add a log entry, and run `just bug-reports-validate`. The profile requires `resolution` for
every terminal status and `fixedVersion` for `fixed`; `unreleased` is the agreed value
while the fix is only on master.

After that strict bug-report validation passes, fill in Outcomes & Retrospective
with the full-gate evidence and the "missing registered object" follow-up. Record one
provenance revision entry at the first plan write in this implementation session, not a
second entry at completion. Commit. If implementation changes after the successful full
gate, rerun the affected checks before retaining `fixed`.

Acceptance: `just verify` passes; the bug report validates as `fixed`; ADR 9 and the two
user pages describe the registry rule; the three changelogs carry the entry.


## Concrete Steps


All commands run from the repository root inside the Nix development shell. Enter it once
with `nix develop` or prefix each command with `nix develop -c`. Confirm the solver and
database are present first:

```bash
nix develop -c z3 --version
nix develop -c postgres --version
```

Expected: a Z3 version line and `postgres (PostgreSQL) 18.x`. `verifyExpectedSchema`
refuses any other major, so a different version means the environment, not the code, is
wrong.

Milestone 0, reproduce on master:

```bash
nix develop -c cabal build keiro:keiro-test
nix develop -c cabal test keiro:keiro-test --test-show-details=direct \
  --test-options='--match "managed external read contracts"'
```

Expected before the fix, in the new example:

```text
  leaves schema verification clean after reconciling an all-rows contract FAILED [1]
  ...
  expected: []
   but got: ["schema drift: unexpected view keiro.external_read_counter_reader_v1_binding (actual: columns=1:id bigint,2:total bigint)"]
```

Record it:

```bash
git rev-parse HEAD
nix develop -c ghc --version
# Paste the command, environment lines, and failing example verbatim into:
# docs/bug-reports/evidence/BUG-12-master-binding-view-drift.txt
# change the example's `it` to `xit` with the pending comment, then confirm the suite is green:
nix develop -c cabal test keiro:keiro-test --test-show-details=direct \
  --test-options='--match "managed external read contracts"'
okf log add docs/bug-reports --kind Update -m "BUG-12 is confirmed by the owning repository: reconciling the bridge catalog's all-rows contract on master after 0.20.0.0 makes verifyExpectedSchema report keiro.external_read_counter_reader_v1_binding as unexpected; the transcript is retained under evidence/ and the fixture is committed pending plan 311 Milestone 2."
nix develop -c just bug-reports-validate
git add docs/bug-reports keiro/keiro.cabal keiro/test/ExternalReadSpec.hs
git commit -m "test(keiro): add pending binding-view drift fixture and confirm BUG-12" \
  -m "ExecPlan: docs/plans/311-recognise-runtime-managed-read-objects-in-schema-verification-to-fix-bug-12.md" \
  -m "Intention: intention_01m4tvqj93e5z8ymnhpaw8z574"
```

Milestone 1, library fix and tests:

```bash
nix develop -c cabal build keiro-migrations:keiro-migrations-test
nix develop -c cabal test keiro-migrations:keiro-migrations-test --test-show-details=direct \
  --test-options='--match "native expected schema"'
```

Expected: every example in the block passes, including
`treats a managed live object as expected and still reports its unregistered neighbours`,
`ignores registered binding views and still reports unregistered and consumer-managed views`,
`returns no managed keys for a role that cannot read the registry`,
`falls back to ordinary drift when the registry is absent`, and the existing
`detects named drift after a hand-altered database`. Then commit:

```bash
git add keiro-migrations
git commit -m "fix(migrations): treat registry-recorded runtime read objects as expected schema" \
  -m "ExecPlan: docs/plans/311-recognise-runtime-managed-read-objects-in-schema-verification-to-fix-bug-12.md" \
  -m "Intention: intention_01m4tvqj93e5z8ymnhpaw8z574"
```

Milestone 2, end-to-end and operator regressions:

```bash
nix develop -c cabal build keiro:keiro-test keiro-ops:exe:keiro-ops keiro-ops:keiro-ops-test
nix develop -c cabal test keiro:keiro-test --test-show-details=direct \
  --test-options='--match "managed external read contracts"'
nix develop -c cabal test keiro-ops:keiro-ops-test --test-show-details=direct \
  --test-options='--match "keiro-ops executable"'
```

Expected: the `keiro` example that was pending since Milestone 0 now runs and passes; both
`keiro-ops` executable examples pass (the drift refusal and the new registered-view run).
Commit:

```bash
git add keiro/test/ExternalReadSpec.hs keiro-ops/test/Main.hs keiro-ops/CHANGELOG.md
git commit -m "test(ops): prove registered binding views no longer trip schema verification" \
  -m "ExecPlan: docs/plans/311-recognise-runtime-managed-read-objects-in-schema-verification-to-fix-bug-12.md" \
  -m "Intention: intention_01m4tvqj93e5z8ymnhpaw8z574"
```

Milestone 3, documentation and closure:

```bash
okf log add docs/user -m "Operations and migrations: objects recorded in keiro.keiro_managed_read_objects, such as all-rows binding views, are not schema drift."
nix develop -c just user-documentation-validate
okf log add docs/adr --kind Update -m "ADR-9: live-schema verification treats registry-recorded runtime read objects as expected."
nix develop -c just adr-validate
nix develop -c just verify
# Only after the full gate passes, set BUG-12 fixed and update its index row.
okf log add docs/bug-reports --kind Update -m "BUG-12 is fixed on master: verifyExpectedSchema consults keiro.keiro_managed_read_objects; regression coverage in keiro-migrations, keiro, and keiro-ops."
nix develop -c just bug-reports-validate
git add CHANGELOG.md docs
git commit -m "docs: record registry-aware schema verification and close BUG-12" \
  -m "ExecPlan: docs/plans/311-recognise-runtime-managed-read-objects-in-schema-verification-to-fix-bug-12.md" \
  -m "Intention: intention_01m4tvqj93e5z8ymnhpaw8z574"
```

`just verify` stops at the first failing recipe; read the log to the end before assuming a
single defect, and re-run after each fix.


## Validation and Acceptance


The change is effective when all of the following hold.

A fresh PostgreSQL 18 database migrated by `keiro-migrations`, with a view
`keiro.external_read_demo_v1_binding` and a matching `binding-view` row in
`keiro.keiro_managed_read_objects`, passes `keiro-migrate verify-schema` with
`schema verification succeeded`, both while the row is `active` and after it is set to
`retired`. The same database with an additional view
`keiro.external_read_rogue_v1_binding` and no row for it prints exactly one line,
`schema drift: unexpected view keiro.external_read_rogue_v1_binding (actual: columns=1:id bigint)`,
and exits non-zero. A database with a hand-added column on `keiro.keiro_timers` is still
reported as changed, exactly as before. A view with a `consumer`-managed registry row is
reported. Roles missing either table `SELECT` or schema `USAGE` receive an empty managed set from
`managedObjectSnapshotKeys`; snapshotting and comparison in those sessions report the
binding view as drift instead of failing. A non-owner with both privileges gets the
managed key and a clean comparison. An absent registry, both with and without the schema
present, returns an empty managed set and the original missing/unexpected drift results.
A missing or changed migration-owned view remains drift even if its key is registered.
`pending-retirement`, as well as `active` and `retired`, remains an allowed registry state.

In the `keiro` test suite, registering `Catalog.bridgeCatalog`, activating revision
`counter-v1`, and reconciling creates `keiro.external_read_counter_reader_v1_binding` and
leaves `verifyExpectedSchema` returning `Right []`.

The built `keiro-ops` executable, pointed at a database carrying a registered binding view,
runs `wf list --json` with empty standard error and runs
`wf gc run-once --retention 0s --force --json` with exit code 0 and no `schema drift` or
`refusing mutation` text, while the pre-existing refusal after `ALTER TABLE keiro.keiro_timers
ADD COLUMN ops_test_drift text` is unchanged.

The three test commands in Concrete Steps pass, `nix develop -c just verify` passes, and
`just bug-reports-validate`, `just adr-validate`, and `just user-documentation-validate`
pass with BUG-12 at `fixed`.


## Idempotence and Recovery


Every step is additive and repeatable. The tests create their own fresh databases through
`keiro-test-support` and `ephemeral-pg`, so a failed run leaves nothing behind. The
`SchemaCheck` edit keeps every existing export and the type of `verifyExpectedSchema`, so
callers compile unchanged; reverting the commit restores the previous behaviour exactly.
If the Milestone 0 `before` check reports drift from the fixture itself, stop and record
the line in Surprises & Discoveries rather than loosening the assertion. Milestone 0 commits
its fixture as pending, so a clean tree after every milestone is the expected state on this
shared checkout. If verification reports `schema verification failed: DatabaseSessionFailed ...`
on a database without the registry table or for a restricted role, the guard in
`registryReadableStatement` is wrong; it must resolve the relation through `pg_class` and
return false rather than raise. Bug-report, ADR, and user-doc edits are validated by
their strict `okf` recipes; a validation failure names the field to repair. Bump a frontmatter
`timestamp` only in the same change that edits the page's body.


## Interfaces and Dependencies


`keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` ends Milestone 1 exporting:

```haskell
data SchemaDrift = MissingObject Text | UnexpectedObject Text | ChangedObject {..}
compareSchemaSnapshot :: Text -> Text -> [SchemaDrift]
compareSchemaSnapshotWithManaged :: Set Text -> Text -> Text -> [SchemaDrift]
managedObjectSnapshotKeys :: Session (Set Text)
expectedSchemaSnapshot :: Text
renderSchemaDrift :: SchemaDrift -> Text
snapshotSchema :: Text -> Session Text
verifyExpectedSchema :: Settings -> IO (Either MigrationError [SchemaDrift])
```

`compareSchemaSnapshot` equals `compareSchemaSnapshotWithManaged Set.empty`. The managed
set contains snapshot keys in the exact `kind<TAB>name` form used by `snapshotObjects`;
for a `binding-view` row with `managed_by = 'keiro'` that is
`"view\t" <> object_schema <> "." <> object_name`. `managedObjectSnapshotKeys` is
self-guarding: it returns the empty set when the registry table is absent or the connected
role lacks table `SELECT` or schema `USAGE`. These steady-state absence and privilege
cases must not raise. This is not a guarantee against concurrent DDL, privilege changes,
connection failures, or a structurally damaged registry. The private
`registryReadableStatement` and `managedObjectsStatement` are not exported. The
module already imports `Data.Set` qualified as `Set`, `Data.Map.Strict` qualified as `Map`,
`Hasql.Session`, `Hasql.Statement`, `Hasql.Encoders`, and `Hasql.Decoders`; `Data.Set (Set)`
must be imported for the signatures.

`keiro/keiro.cabal`, `test-suite keiro-test`, gains `keiro-migrations ^>=0.20.0.0` in its
`build-depends` in Milestone 0. No library component changes.

`keiro-ops` has no source change; its behaviour changes through its existing
`keiro-migrations ^>=0.20.0.0` dependency when rebuilt against the fixed library.
That bound means `>=0.20.0.0 && <0.21`, so it can select a `0.20.x` fix but also permits
the unfixed `0.20.0.0`; a `0.21` cohort requires a bound update in the release work.
An installed executable does not acquire the fix until rebuilt or replaced. The release
work must select the fixed version and update cohort bounds as required; this plan changes
no package version or release policy.

Runtime behaviour relied upon: `Keiro.ReadModel.External.reconcileBinding` creates the view
and upserts its registry row in one transaction; `retireContractStmt` sets `state = 'retired'`
without dropping the view; migration `0027.sql` defines the registry with the constraints
named in Context and Orientation. None of that changes.


## Revision Notes


- 2026-10-13: hardened after a safety review of the first draft, before any implementation.
  The registry lookup now guards itself with one catalog statement covering both table
  existence and the connected role's `SELECT` privilege, so a restricted role falls back to
  the previous fail-closed behaviour instead of aborting verification; only
  `managed_by = 'keiro'` rows count, with a `consumer`-managed view pinned as still reported;
  and Milestone 0 commits its fixture as a pending `xit` example rather than leaving
  uncommitted edits on a checkout shared with parallel sessions. Decision Log entries three
  and four were rewritten, a new entry was added for the pending fixture, and Progress,
  Context, Plan of Work, Concrete Steps, Validation, Idempotence, and Interfaces were updated
  to match.

- 2026-10-13: correctness review against the current tree corrected the fixture
  assertions to avoid `Eq MigrationError`, replaced `Session.sql` with `Session.script`,
  and extended the registry guard to require schema `USAGE`, with
  PostgreSQL 18.6 evidence above. Expanded acceptance for both privilege failures,
  authorised non-owners, absent registries, every lifecycle state, and preservation of
  missing/changed migration objects. Replaced stale snapshot-based ADR guidance, narrowed
  documentation promises to the actual binding-view rule, moved full verification before
  bug closure, made validation commands explicitly use Nix, and clarified release bounds
  and executable rebuilding. Implementation and BUG-12 status remain unchanged.

- 2026-10-14: implementation started; corrected the fixture mapping expression for
  this spec’s restricted Prelude and recorded the verified environment and dependency.

- 2026-10-14: Milestone 0 complete: saved exact failing evidence, confirmed BUG-12,
  validated its bundle, and verified the pending regression leaves the suite green.

- 2026-10-14: Milestone 1 complete: guarded registry lookup, comparison exports,
  four regressions, and migration changelog; full migration suite passes (40 examples).

- 2026-10-14: user documentation and ADR 9 now record the registry rule and its
  exclusions; both strict bundles pass (34 user concepts, 51 ADRs). Added the
  previously absent migrations-page timestamp and the root changelog entry.

- 2026-10-14: Milestone 2 complete: enabled the runtime regression and verified the
  operator executable success/refusal paths. Seven runtime and two operator examples pass.

- 2026-10-14: full `just verify` gate passed; final outcomes record all three regression
  layers, CLI state/rogue-view checks, and the existing PGMQ pending-test limitations.
  Durable decisions were distilled into ADR 9; BUG-12 closure follows the full gate.

- 2026-10-14: strict BUG-12 closure validation passed; checked off the full-gate
  and closure items. Plan 311 is complete with no outstanding implementation work.
