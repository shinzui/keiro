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
`keiro` schema that Keiro did not create is still reported as drift. Three regression
tests prove it: a registry-level test in `keiro-migrations`, an end-to-end test in `keiro`
that reconciles a real all-rows contract and then verifies the schema, and an executable
test in `keiro-ops` that runs a forced mutation against a database carrying a registered
binding view.


## Progress


- [ ] Milestone 0: reproduce BUG-12 with a compiled fixture on master, retain the failing
      transcript under `docs/bug-reports/evidence/`, set the report `confirmed`, and log it.
- [ ] Milestone 1: make `Keiro.Migrations.SchemaCheck` registry-aware (`managedObjectSnapshotKeys`,
      `compareSchemaSnapshotWithManaged`, the guarded lookup inside `verifyExpectedSchema`).
- [ ] Milestone 1: add the pure comparison test and the hand-altered-database test to
      `keiro-migrations/test/Main.hs`; both pass.
- [ ] Milestone 1: record the fix under `[Unreleased]` in `keiro-migrations/CHANGELOG.md`.
- [ ] Milestone 2: add `keiro-migrations` to the `keiro-test` suite's `build-depends` and
      make the Milestone 0 fixture in `keiro/test/ExternalReadSpec.hs` pass.
- [ ] Milestone 2: add the executable regression to `keiro-ops/test/Main.hs`; it passes.
- [ ] Milestone 2: record the operator-visible change under `[Unreleased]` in
      `keiro-ops/CHANGELOG.md`.
- [ ] Milestone 3: update `docs/user/operations.md` and `docs/user/migrations.md`, advance
      their timestamps, and log the user-documentation bundle.
- [ ] Milestone 3: update ADR 9 with the registry-aware verification decision, advance its
      timestamp, log the ADR bundle, and pass strict validation.
- [ ] Milestone 3: record the fix under `[Unreleased]` in the root `CHANGELOG.md`.
- [ ] Milestone 3: set BUG-12 `fixed` with `fixedVersion: unreleased` and a `resolution`,
      update the index coverage row, log the bundle, and pass strict validation.
- [ ] Milestone 3: `nix develop -c just verify` passes; fill Outcomes & Retrospective.


## Surprises & Discoveries


(None yet.)


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
- Decision: every registry row counts, whatever its `state` (`active`,
  `pending-retirement`, `retired`) and whatever its `managed_by` (`keiro`, `consumer`).
  Rationale: retirement marks objects retired but does not drop them
  ([ADR 36](../adr/0036-external-readers-use-versioned-guarded-sql-contracts.md)), so a
  retired binding view is still Keiro's. A `consumer`-managed row is still an object Keiro's
  reconciliation accounts for. Today only `binding-view` rows map to a snapshot line; the
  other kinds (`guard-function`, `wrapper-function`, `contract-type`) are not snapshotted,
  and the mapping says so explicitly rather than guessing a future format.
  Date: 2026-10-13
- Decision: the registry is read only when the live snapshot already contains
  `table<TAB>keiro_managed_read_objects`.
  Rationale: a database that predates migration 0027 has no registry table. Querying it
  would turn the whole verification into a session failure; skipping the lookup keeps the
  ordinary `MissingObject` drift list for that database.
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
- Decision: BUG-12 moves to `confirmed` only after the compiled fixture in Milestone 0 fails
  on master with the exact unexpected view, and to `fixed` with `fixedVersion: unreleased`
  only after `just verify` passes in Milestone 3.
  Rationale: the bundle profile reserves `confirmed` for reproduction by the owning
  repository, and a plan that is written but not implemented does not change a status
  (see the coverage notes in `docs/bug-reports/index.md`).
  Date: 2026-10-13


## Outcomes & Retrospective


(To be filled during and after implementation.)


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
`build-depends`, so Milestone 2 adds it. `keiro-ops` already depends on both.


## Plan of Work


### Milestone 0: confirm BUG-12 with a compiled fixture


The report arrived from a consumer and was validated from source on master; the bundle
profile reserves `confirmed` for a reproduction by this repository. This milestone writes
the end-to-end regression test first, watches it fail on unmodified master with the exact
unexpected view, and records that failure as evidence. The test is left in the working tree
and is committed in Milestone 2 together with the fix, so no commit carries a failing test.

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
            before <- verifyExpectedSchema settings
            fmap (map renderSchemaDrift) before `shouldBe` Right []
            catalog <- expectValid Catalog.bridgeCatalog
            register store catalog
            runScript pool activateV1Sql
            expectStore store (reconcileExternalReadContracts catalog) >>= shouldBeRight
            runStatement pool () bindingExistsStmt `shouldReturn` True
            after <- verifyExpectedSchema settings
            fmap (map renderSchemaDrift) after `shouldBe` Right []
```

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

Then edit `docs/bug-reports/12-ops-schema-verification-flags-keiro-managed-binding-view.md`:
set `status: confirmed`, advance `generated.at` to the current UTC time, and append a short
paragraph after the "Tracked by plan 311" paragraph stating that the owning repository
reproduced the drift on master with the compiled fixture and names the evidence file. Update
the BUG-12 row in `docs/bug-reports/index.md` to `confirmed` with the same note, add a log
entry with `okf log add docs/bug-reports --kind Update -m "..."`, and run
`just bug-reports-validate`. Commit the evidence file and the three bundle files only.

Acceptance: the evidence file exists and names the unexpected view; the bundle validates
strictly; the working tree still holds the uncommitted cabal and spec edits.


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

Define the registry lookup as a session, mapping each registry row to the snapshot key it
accounts for. Only `binding-view` rows have a snapshot line today, because the snapshot
lists views but not functions or types; the mapping returns `Nothing` for every other kind
so a future object kind is a deliberate decision rather than an accident:

```haskell
-- | Snapshot keys of the objects Keiro's runtime created and recorded in
-- @keiro.keiro_managed_read_objects@. Every row counts regardless of its
-- @state@ or @managed_by@: retirement marks a managed object retired without
-- dropping it. Rows whose kind has no snapshot line (functions and types) map
-- to nothing.
managedObjectSnapshotKeys :: Session (Set Text)
managedObjectSnapshotKeys =
  Set.fromList . mapMaybe snapshotKey <$> Session.statement () managedObjectsStatement
  where
    snapshotKey (schema, name, kind)
      | kind == "binding-view" = Just ("view\t" <> schema <> "." <> name)
      | otherwise = Nothing

managedObjectsStatement :: Statement () [(Text, Text, Text)]
managedObjectsStatement =
  Statement.preparable
    "SELECT object_schema, object_name, object_kind FROM keiro.keiro_managed_read_objects"
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
schemas, it reads the registry only when the private snapshot contains the registry table,
and returns the managed set alongside the text. Then compare with
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
          managed <-
            if Map.member registryKey (snapshotObjects privateSchema)
              then managedObjectSnapshotKeys
              else pure Set.empty
          pure (Right (managed, privateSchema <> publicSchema))
        else pure (Left (UnsupportedPostgresVersion majorVersion))

    registryKey = "table\tkeiro_managed_read_objects"
```

Update the module's Haddock on `verifyExpectedSchema` to say that runtime-managed read
objects recorded in the registry are not drift.

Add two tests to the `describe "native expected schema"` block of
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

The second mirrors "detects named drift after a hand-altered database": migrate a fresh
database with `withKeiroPg`, assert a clean verification, then run one script that creates
a binding view and its registry row plus a second view with no row, and assert that only the
second is reported; then retire the registered row and assert the same:

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
```

followed, after the first assertion, by:

```sql
UPDATE keiro.keiro_managed_read_objects
SET state = 'retired', retired_at = now(), updated_at = now()
WHERE object_name = 'external_read_demo_v1_binding';
```

Both assertions check `map renderSchemaDrift drifts` with `shouldBe`
`["schema drift: unexpected view keiro.external_read_rogue_v1_binding (actual: columns=1:id bigint)"]`.
The registry row needs no contract because `contract_id` and `contract_version` may both be
null; `definition_hash` and `surface_generation` only have to be non-empty and positive.

Add to `keiro-migrations/CHANGELOG.md` under `## [Unreleased]`:

```markdown
### Bug Fixes

- `verify-schema` and `Keiro.Migrations.SchemaCheck.verifyExpectedSchema` no longer
  report a view that Keiro's runtime created and recorded in
  `keiro.keiro_managed_read_objects`, such as the
  `keiro.external_read_<function>_binding` view behind an all-rows external-read
  contract, as unexpected drift. New exports `managedObjectSnapshotKeys` and
  `compareSchemaSnapshotWithManaged`; `compareSchemaSnapshot` is unchanged.
```

Commit this milestone on its own. Acceptance: `cabal test keiro-migrations:keiro-migrations-test`
passes, including the two new tests and the unchanged "detects named drift after a
hand-altered database" test, which proves foreign objects are still reported.


### Milestone 2: end-to-end and operator regressions


With the library fixed, the Milestone 0 fixture in `keiro/test/ExternalReadSpec.hs` passes
without further change; this milestone commits it and adds the operator-level proof.

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
  external-read contract. Objects recorded in `keiro.keiro_managed_read_objects` are
  part of Keiro's schema; `--allow-schema-drift` is again reserved for schemas this
  binary was not built for. Fixed in `keiro-migrations`; no `keiro-ops` source change.
```

Commit the cabal change, the `keiro` spec, the `keiro-ops` test, and the changelog together.
Acceptance: `cabal test keiro:keiro-test` with the "managed external read contracts" match
and `cabal test keiro-ops:keiro-ops-test` with the "keiro-ops executable" match both pass;
the pre-existing refusal test in the same block still passes, so a hand-added column is
still refused.


### Milestone 3: documentation, ADR, changelog, and bug-report closure


Update the operator-facing documentation so the new rule is stated where operators read
about the gate. In `docs/user/operations.md`, after the sentence "Mutations fail closed on
drift unless the operator explicitly supplies `--allow-schema-drift`...", add one sentence:
objects that Keiro's runtime creates and records in `keiro.keiro_managed_read_objects`,
such as the `keiro.external_read_<function>_binding` view behind an all-rows external-read
contract, are part of Keiro's schema and are not reported as drift. In
`docs/user/migrations.md`, extend the `verify-schema` bullet the same way. Both pages carry
a `timestamp` (and `operations.md` a `generated` block) in their frontmatter; advance them
to the current UTC time, add one entry with `okf log add docs/user -m "..."`, and run
`just user-documentation-validate`.

Update [ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md): in
its Decision section, after the paragraph describing the two layers of `SchemaCheck`, add
a paragraph recording that the expected snapshot describes only what the migrations build,
that Keiro's runtime also creates read objects inside `keiro` and records each one in
`keiro.keiro_managed_read_objects` in the same transaction, and that `verifyExpectedSchema`
therefore treats a live object with a registry row as expected rather than unexpected while
still reporting every unregistered object; note that the registry is consulted only when the
snapshot shows the table, and that a registry row without a live object is not reported. Add
a Consequences bullet that a service with an all-rows external-read contract runs operator
mutations without `--allow-schema-drift`, and a References bullet pointing at this plan.
Advance the ADR's `timestamp`, run `okf log add docs/adr --kind Update -m "..."`, and run
`just adr-validate`. Do not allocate a new ADR; the decision belongs to ADR 9's topic.

Add to the root `CHANGELOG.md` under `## [Unreleased]` a `### Bug Fixes` entry mirroring the
`keiro-migrations` one and naming BUG-12.

Close the bug report: in `docs/bug-reports/12-ops-schema-verification-flags-keiro-managed-binding-view.md`
set `status: fixed`, add `fixedVersion: "unreleased"` and a one-sentence `resolution`
naming the registry-aware comparison and this plan, advance `generated.at`, and append a
paragraph to the body describing the fix and the three regression tests. Update the
BUG-12 row in `docs/bug-reports/index.md` (status `fixed`, plan 311, implementation note),
add a log entry, and run `just bug-reports-validate`. The profile requires `resolution` for
every terminal status and `fixedVersion` for `fixed`; `unreleased` is the agreed value
while the fix is only on master.

Run the full gate, `nix develop -c just verify`, and fix anything it reports. Fill in
Outcomes & Retrospective, record the "missing registered object" follow-up there, and record
a provenance revision entry. Commit.

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
  expected: Right []
   but got: Right ["schema drift: unexpected view keiro.external_read_counter_reader_v1_binding (actual: columns=1:id bigint,2:total bigint)"]
```

Record it:

```bash
git rev-parse HEAD
nix develop -c ghc --version
# paste the command, the environment lines, and the failing example verbatim into
docs/bug-reports/evidence/BUG-12-master-binding-view-drift.txt
okf log add docs/bug-reports --kind Update -m "BUG-12 is confirmed by the owning repository: reconciling the bridge catalog's all-rows contract on master after 0.20.0.0 makes verifyExpectedSchema report keiro.external_read_counter_reader_v1_binding as unexpected; the transcript is retained under evidence/."
just bug-reports-validate
git add docs/bug-reports
git commit -m "docs(bug-reports): confirm BUG-12 with a compiled binding-view drift reproduction" \
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
`ignores registered binding views and still reports an unregistered view`, and the existing
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

Expected: the `keiro` example that failed in Milestone 0 now passes; both `keiro-ops`
executable examples pass (the drift refusal and the new registered-view run). Commit:

```bash
git add keiro/keiro.cabal keiro/test/ExternalReadSpec.hs keiro-ops/test/Main.hs keiro-ops/CHANGELOG.md
git commit -m "test(ops): prove registered binding views no longer trip schema verification" \
  -m "ExecPlan: docs/plans/311-recognise-runtime-managed-read-objects-in-schema-verification-to-fix-bug-12.md" \
  -m "Intention: intention_01m4tvqj93e5z8ymnhpaw8z574"
```

Milestone 3, documentation and closure:

```bash
okf log add docs/user -m "Operations and migrations: objects recorded in keiro.keiro_managed_read_objects, such as all-rows binding views, are not schema drift."
just user-documentation-validate
okf log add docs/adr --kind Update -m "ADR-9: live-schema verification treats registry-recorded runtime read objects as expected."
just adr-validate
okf log add docs/bug-reports --kind Update -m "BUG-12 is fixed on master: verifyExpectedSchema consults keiro.keiro_managed_read_objects; regression coverage in keiro-migrations, keiro, and keiro-ops."
just bug-reports-validate
nix develop -c just verify
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
reported as changed, exactly as before.

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
the line in Surprises & Discoveries rather than loosening the assertion. If the registry
query is reached on a database without the table, the guard in `liveSnapshotSession` is
wrong; the symptom is `schema verification failed: DatabaseSessionFailed ...` instead of a
drift list, and the fix is to compare the key `table<TAB>keiro_managed_read_objects` against
the private snapshot exactly as written. Bug-report, ADR, and user-doc edits are validated by
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
for a `binding-view` row that is `"view\t" <> object_schema <> "." <> object_name`. The
module already imports `Data.Set` qualified as `Set`, `Data.Map.Strict` qualified as `Map`,
`Hasql.Session`, `Hasql.Statement`, `Hasql.Encoders`, and `Hasql.Decoders`; `Data.Set (Set)`
must be imported for the signatures.

`keiro/keiro.cabal`, `test-suite keiro-test`, gains `keiro-migrations ^>=0.20.0.0` in its
`build-depends`. No library component changes.

`keiro-ops` has no source change; its behaviour changes through its existing
`keiro-migrations ^>=0.20.0.0` dependency. If the fix ships in a `keiro-migrations` minor
release ahead of the next cohort, `keiro-ops` picks it up through that bound without a
rebuild of its own sources.

Runtime behaviour relied upon: `Keiro.ReadModel.External.reconcileBinding` creates the view
and upserts its registry row in one transaction; `retireContractStmt` sets `state = 'retired'`
without dropping the view; migration `0027.sql` defines the registry with the constraints
named in Context and Orientation. None of that changes.
