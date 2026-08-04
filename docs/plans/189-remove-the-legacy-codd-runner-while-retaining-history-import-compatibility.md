---
id: 189
slug: remove-the-legacy-codd-runner-while-retaining-history-import-compatibility
title: "Remove the legacy Codd runner while retaining history import compatibility"
kind: exec-plan
created_at: 2026-08-03T21:05:17Z
---

# Remove the legacy Codd runner while retaining history import compatibility

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro already runs all new migrations through pg-migrate, but the repository still makes
the retired Codd runner available through a manual Cabal flag and pins Codd as a Git source
package. After this work, an ordinary checkout, source distribution, and Cabal plan no
longer contain or offer the Codd runner, `codd-extras`, the old Codd schema-snapshot writer,
or the timestamp-based Codd migration scaffolder. Migration authors and operators have one
implementation to understand: pg-migrate.

This removal must not strand an existing database. A database first managed by
`keiro-migrations 0.1.0.0` can still contain a Codd ledger even though Codd is no longer the
runner. Keiro therefore continues to recognize that ledger, refuse an unsafe native `up`,
and import its verified history through the Hasql-only `pg-migrate-import-codd` adapter.
The two unique legacy upgrade drills—the historical filename realignment and the
data-preserving schema relocation—move into the default migration suite before any Codd
code is deleted. A user can see the result by running the normal migration tests, observing
that the cutover cases pass, and inspecting a Cabal build plan that contains
`pg-migrate-import-codd` but no `codd` or `codd-extras` package.


## Progress

- [ ] Move the sentinel-ledger realignment drill into
  `keiro-migrations/test/Main.hs` and prove that the realigned history imports through
  pg-migrate without replaying the historical SQL.
- [ ] Move the `0.1.0.0` schema-relocation drill into the default suite and prove that rows
  survive remediation, history import, and application of the native migration tail.
- [ ] Remove the `legacy-codd-tools` Cabal surface, Codd-only modules, executable, test
  target, snapshot tree, duplicate timestamped SQL tree, and the Codd Git source pin.
- [ ] Update active documentation, code comments, ADR 0009, ADR 0010, and the ADR bundle
  log while preserving historical plans and changelogs as records of what happened.
- [ ] Run focused migration tests, package/build-plan checks, repository-wide verification,
  strict ADR validation, and a final Codd-reference audit.


## Surprises & Discoveries

- Discovery: `pg-migrate-import-codd` is named for the source ledger format but does not
  depend on the Codd Haskell package. Its package description says it reads supported Codd
  ledger shapes with Hasql and delegates writes to pg-migrate; its Cabal dependencies are
  Hasql, pg-migrate, pg-migrate-cli, and ordinary support libraries. This means history
  compatibility can remain after the Codd runner leaves the build.
  Evidence: Mori resolves the adapter as
  `mori://shinzui/pg-migrate/packages/pg-migrate-import-codd`; its released 1.1.0.0 Cabal
  file contains no `codd` dependency.
  Date: 2026-08-03

- Discovery: the default suite already applies the exact legacy payloads directly through
  Hasql and synthesizes both `codd.sql_migrations` and `codd_schema.sql_migrations`
  fixtures. It already tests atomic import, partial-source rejection, strict-source
  rejection, the fresh-ledger guard, and poisoned-ledger recovery. The legacy runner is
  therefore unnecessary to construct either remaining upgrade drill.
  Evidence: `applyLegacyPayloads`, `installCoddLedger`, and the tests under “combined Codd
  history import” are in `keiro-migrations/test/Main.hs`.
  Date: 2026-08-03

- Discovery: `keiro-migrations/sql-migrations/` is not an input to the supported history
  importer. `Keiro.Migrations.History.Codd.keiroCoddSourcePayloads` pairs the sixteen old
  filenames with the first sixteen payloads from the native pg-migrate manifest, and the
  default suite verifies those payload bytes against `migrations.lock`. The timestamped
  directory is consumed only by `Keiro.Migrations.LegacyCodd` and its disabled test suite.
  Evidence: `keiro-migrations/src/Keiro/Migrations/History/Codd.hs` and the “preserves every
  legacy payload byte recorded by migrations.lock” default test.
  Date: 2026-08-03

- Discovery: even with `legacy-codd-tools` false, the top-level
  `source-repository-package` stanza makes Codd appear as a configured package in Cabal's
  plan. Removing only the conditional `build-depends` would leave the visible source pin
  behind.
  Evidence: `dist-newstyle/cache/plan.json` records the flag as false while also listing
  `codd-0.1.8`; `cabal.project` declares the source repository unconditionally.
  Date: 2026-08-03


## Decision Log

- Decision: Remove the Codd runner and `codd-extras`, but retain Codd-ledger detection and
  verified history import.
  Rationale: “Codd as an executable migration engine” is obsolete, while “Codd as the
  format of durable production history” remains part of the documented direct-upgrade
  contract for `keiro-migrations 0.1.0.0`. The latter uses
  `pg-migrate-import-codd`, which is a Hasql adapter rather than the retired runner.
  Date: 2026-08-03

- Decision: Port the filename-fixup and schema-remediation drills before deleting the
  legacy suite.
  Rationale: These are the only tests in `keiro-migrations/test-legacy/Main.hs` that are not
  already covered behaviorally by native apply, repeatability, concurrency, lint,
  live-schema verification, authoring, and history-import tests. Moving them first makes
  the subtraction independently reviewable and prevents a temporary loss of upgrade
  evidence.
  Date: 2026-08-03

- Decision: Delete the duplicate `keiro-migrations/sql-migrations/` tree but retain
  `keiro-migrations/migrations.lock`, the native migration files, the ledger fixup, and the
  remediation script.
  Rationale: The supported importer embeds legacy names and checksums from
  `migrations.lock` while obtaining exact payloads from the byte-identical native files.
  The default parity test guards that relationship. Keeping a second executable copy of
  the SQL would imply that Codd remains an alternative runner and create another stale-file
  risk. The lockfile and the two operator scripts are still required transition evidence.
  Date: 2026-08-03

- Decision: Preserve historical ExecPlans, MasterPlans, ADR references, and changelog
  entries that accurately describe the Codd era; edit only active instructions and present
  tense claims.
  Rationale: Historical records are evidence, not supported entry points. Rewriting them
  would erase the reasons the cutover machinery exists and produce noisy unrelated diffs.
  Date: 2026-08-03

- Decision: Update ADR 0009 and ADR 0010 rather than create a third migration ADR during
  plan authoring.
  Rationale: ADR 0009 already owns the pg-migrate/live-schema boundary and presently says
  the legacy flag survives. ADR 0010 owns the continuing import and preflight boundary.
  Implementation changes the current consequences of those accepted decisions but does
  not introduce an unrelated architecture topic. The implementer must reconsider whether
  a new ADR is needed during the final distillation pass if new durable context emerges.
  Date: 2026-08-03


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Work from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`; every path below is
repository-relative. The relevant package is `keiro-migrations`. A migration runner executes
SQL and records what ran. Codd was Keiro's former runner. pg-migrate is the current runner
and stores native history in `pgmigrate.migrations`. A history importer does not execute
old SQL: it verifies that an old ledger and its payload evidence correspond to declared
native migrations, then records audited native history so pg-migrate will not replay those
migrations.

`cabal.project` currently declares `https://github.com/mzabani/codd.git` at tag `v0.1.8` as
an unconditional `source-repository-package`. `keiro-migrations/keiro-migrations.cabal`
declares the manual, default-false `legacy-codd-tools` flag. Enabling that flag exposes
`Keiro.Migrations.ExpectedSchema`, `Keiro.Migrations.LegacyCodd`, and
`Keiro.Migrations.New`; adds `codd`, `codd-extras`, `file-embed`, and related dependencies;
enables `keiro-write-expected-schema`; and enables `keiro-migrations-legacy-test`. The
implementation files are:

- `keiro-migrations/src/Keiro/Migrations/ExpectedSchema.hs`, which embeds Codd's old JSON
  object representation under `keiro-migrations/expected-schema/v18/`;
- `keiro-migrations/src/Keiro/Migrations/LegacyCodd.hs`, which executes the historical SQL
  with Codd and reads Codd migration status;
- `keiro-migrations/src/Keiro/Migrations/New.hs`, the superseded timestamp-based migration
  scaffolder;
- `keiro-migrations/app/WriteExpectedSchema.hs`, the Codd snapshot writer; and
- `keiro-migrations/test-legacy/Main.hs`, the disabled legacy suite.

The default path is already native. `keiro-migrations/migrations/manifest` orders the SQL
files in `keiro-migrations/migrations/`. `Keiro.Migrations.Internal.Definition` embeds that
manifest through pg-migrate-embed. `keiro-migrate new` is the supported authoring command,
and `Keiro.Migrations.SchemaCheck` plus
`keiro-migrations/expected-schema/native/keiro-v18.txt` implement the supported live-schema
gate. The default `keiro-migrations/test/Main.hs` suite covers native application,
repeatability, concurrency, checksums, body lint, live schema, startup status, Codd-ledger
preflight, and Codd-history import.

The continuing compatibility layer consists of
`keiro-migrations/src/Keiro/Migrations/History/Codd.hs`, the `import-codd-history` command
in `keiro-migrations/app/Main.hs`, and `preflightFreshLedgerOverCodd` in
`keiro-migrations/src/Keiro/Migrations.hs`. The first combines Kiroku's seven historical
rows with Keiro's sixteen rows, exact payload bytes, and the frozen
`keiro-migrations/migrations.lock`. The CLI imports them atomically through
`pg-migrate-import-codd`. The preflight refuses to initialize empty native history over an
old ledger. These files and the `pg-migrate-import-codd` dependencies in the library,
executable, and default test suite remain in scope and must not be mistaken for the Codd
runner.

Two operator artifacts also remain. The idempotent
`keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql` converts
early sentinel filenames to the released historical names expected by strict import. The
idempotent
`keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql` moves
`keiro_*` tables from the incorrect `kiroku` schema used by release `0.1.0.0` into the
owned `keiro` schema without copying or dropping their rows. The operator sequence remains
remediation, filename fixup when necessary, history import, native verification, then
native `up`.

The relevant durable decisions are
[`docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md`](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md)
and
[`docs/adr/0010-keiro-guards-fresh-native-history-over-codd-ledgers.md`](../adr/0010-keiro-guards-fresh-native-history-over-codd-ledgers.md).
ADR 0009 says pg-migrate owns ledger integrity while Keiro owns its native live-schema
snapshot; that replacement makes the Codd snapshot implementation removable. ADR 0010
says Keiro must guard and import old Codd history before native `up`; that decision remains
in force and defines the compatibility code this plan preserves. The ADR bundle is governed
by `docs/adr/profile.dhall`, which was read and type-checked during plan creation. No
cross-repository ADR is needed. Dependency source and documentation were located with Mori;
the only continuing cross-repository package reference is
`mori://shinzui/pg-migrate/packages/pg-migrate-import-codd`.

The worktree contained pre-existing package-version and changelog edits when this plan was
created. They belong to the user. Implementation must preserve them and must not revert or
fold unrelated release work into the Codd-removal changes.


## Plan of Work

Milestone 1 preserves the unique filename-realignment evidence in the default suite. In
`keiro-migrations/test/Main.hs`, add a test beside “combined Codd history import” that uses
the existing `applyLegacyPayloads` and `installCoddLedger` fixtures to create an applied
historical database, rewrites the affected Keiro ledger rows to the old sentinel names,
runs the checked-in ledger-fixup SQL, and calls `importCoddHistory` with
`frameworkCoddSourceConfig` and `frameworkCoddHistoryMappings`. Port only the small fixture
data and Hasql statements needed to rewrite and inspect names from
`keiro-migrations/test-legacy/Main.hs`; do not port Codd types, Codd settings, or the Codd
runner. Assert that the sentinel names existed before the fixup, the exact released names
exist afterward, the import succeeds for all mapped Kiroku and Keiro rows, strict native
verification passes, and no historical SQL is replayed. The focused default test must pass
while the legacy target still exists, proving the replacement before subtraction.

Milestone 2 preserves the `0.1.0.0` data-relocation evidence in the default suite. Add a
test that directly applies the embedded legacy payloads through Hasql, installs the
appropriate historical ledger fixture, moves the Keiro tables back under `kiroku` to model
the old release, and inserts representative snapshot and timer rows. Run the checked-in
remediation script twice to prove idempotence, then import the historical ledger and run the
native migration plan. Port the schema-move fixture, seed SQL, row-survival queries, and
table-presence helpers from the legacy test without importing any Codd module. Assert that
all Keiro tables finish under `keiro`, none remain under `kiroku`, both seeded rows survive
unchanged, `verifyMigrationPlan` or the public equivalent reports no ledger issues after
the native tail, and `verifyExpectedSchema` reports no live-schema drift. This test is the
observable proof that removing the old runner does not remove direct-upgrade support.

Milestone 3 removes the obsolete implementation. Delete the Codd-only source modules,
snapshot writer executable source, and legacy test source named in Context and Orientation.
Delete `keiro-migrations/expected-schema/v18/` while retaining
`keiro-migrations/expected-schema/native/keiro-v18.txt`. Delete the duplicate
`keiro-migrations/sql-migrations/` tree after the default legacy-byte parity test passes;
retain `migrations.lock`, all native migration files, the fixup, and the remediation script.
In `keiro-migrations/keiro-migrations.cabal`, remove the flag, conditional modules and
dependencies, disabled executable and test-suite stanzas, and the deleted files from
`extra-source-files`. Keep `Keiro.Migrations.History.Codd` exposed and keep
`pg-migrate-import-codd` in every component that imports it. In `cabal.project`, remove the
entire Codd `source-repository-package` stanza. Run `cabal check`, build the package, and
inspect a newly generated build plan to prove `codd` and `codd-extras` are absent while
`pg-migrate-import-codd` remains.

Milestone 4 aligns active guidance and durable decisions. Update
`keiro-migrations/README.md`, `docs/user/migration-ownership.md`, and
`docs/user/migrations.md` so they no longer advertise `-flegacy-codd-tools`, the old schema
writer, the timestamped SQL directory, or the old snapshot. Preserve and clarify the
history-import instructions. Update stale present-tense Codd ownership comments such as the
one in `keiro/src/Keiro/Workflow.hs` and any generated DSL comments that still tell authors
to delegate current migration work to Codd. Do not rewrite completed ExecPlans,
MasterPlans, research records, or old changelog entries merely because they contain the
word “Codd.” Add a current changelog entry to `keiro-migrations/CHANGELOG.md` and the root
`CHANGELOG.md` if the repository's active release section expects one, taking care not to
overwrite the user's existing version edits.

Update ADR 0009 to say the legacy Codd schema-verification implementation has now been
removed because the native gate replaced it. Update ADR 0010 to distinguish removal of the
runner from retention of its durable-ledger compatibility path. Preserve their `docId`
values, advance their RFC 3339 `timestamp` fields, and append one log entry per changed ADR
with `okf log add`. The plan itself is not complete until strict ADR validation passes.

Milestone 5 performs the closure audit. Run the focused migration suite and
repository-wide verification. Generate a source distribution and confirm it contains the
native schema snapshot, `migrations.lock`, remediation, fixup, and native SQL, but not the
deleted Codd-only trees or sources. Search active code, Cabal configuration, user guides,
and README files for `codd`, classifying each remaining match: it must describe a ledger,
history import, safety preflight, compatibility error, or accurate historical record. There
must be no remaining import of module `Codd`, no `codd` or `codd-extras` build dependency,
no Codd Git source pin, and no documented command that enables the removed flag.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`. Before editing, record the
pre-existing worktree state and do not modify unrelated paths:

```bash
git status --short
```

After each of Milestones 1 and 2, run the focused suite with direct output:

```bash
cabal test keiro-migrations:keiro-migrations-test --test-show-details=direct
```

The expected transcript ends with zero failures and includes the newly named filename
realignment and `0.1.0.0` remediation examples:

```text
...
0 failures
```

After deleting the legacy components, check package metadata and build the supported
surface:

```bash
cd keiro-migrations
cabal check
cd ..
cabal build keiro-migrations:lib:keiro-migrations keiro-migrations:exe:keiro-migrate
cabal test keiro-migrations:keiro-migrations-test --test-show-details=direct
```

Regenerate the solver plan rather than trusting a stale `dist-newstyle/cache/plan.json`,
then inspect package names:

```bash
cabal build keiro-migrations:lib:keiro-migrations keiro-migrations:exe:keiro-migrate --dry-run
jq -r '."install-plan"[] | ."pkg-name"' dist-newstyle/cache/plan.json | sort -u | rg '^(codd|codd-extras|pg-migrate-import-codd)$'
```

The only output from the package-name filter must be:

```text
pg-migrate-import-codd
```

If Cabal retains stale configured entries after the project stanza is removed, generate the
plan in a new temporary build directory rather than deleting the user's build cache:

```bash
keiro_plan_dir=$(mktemp -d)
cabal build --builddir="$keiro_plan_dir" keiro-migrations:lib:keiro-migrations --dry-run
jq -r '."install-plan"[] | ."pkg-name"' "$keiro_plan_dir/cache/plan.json" | sort -u | rg '^(codd|codd-extras|pg-migrate-import-codd)$'
```

Create and inspect the source distribution without uploading it:

```bash
cabal sdist keiro-migrations
tar -tf dist-newstyle/sdist/keiro-migrations-*.tar.gz | rg 'expected-schema|migrations.lock|ledger-fixups|remediation|sql-migrations|LegacyCodd|WriteExpectedSchema'
```

The listing must contain `expected-schema/native/keiro-v18.txt`, `migrations.lock`, the
ledger fixup, and the remediation script. It must not contain
`expected-schema/v18/`, `sql-migrations/`, `LegacyCodd.hs`, or
`WriteExpectedSchema.hs`. Because the version may already have been changed by unrelated
release work, use the produced archive name rather than assuming a fixed version.

For each ADR whose timestamp changes, append the bundle log entry using its stable handle:

```bash
okf log add docs/adr ADR-9 --kind Update --message "Record removal of the superseded Codd schema-verification toolchain" --date 2026-08-03
okf log add docs/adr ADR-10 --kind Update --message "Clarify that Codd ledger compatibility remains after runner removal" --date 2026-08-03
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Use the actual implementation date instead of `2026-08-03` if execution occurs later.
Finish with the repository gate and the active-reference audit:

```bash
just verify
rg -n 'legacy-codd-tools|keiro-write-expected-schema|keiro-migrations-legacy-test|import Codd|codd-extras|mzabani/codd' \
  cabal.project keiro-migrations keiro docs/user README.md Justfile
```

The final search must return no supported command, module import, dependency, or source pin.
References inside historical changelog prose are acceptable only if the search scope is
expanded deliberately and each match remains factually historical.

Every implementation commit must use Conventional Commits and include this trailer:

```text
ExecPlan: docs/plans/189-remove-the-legacy-codd-runner-while-retaining-history-import-compatibility.md
```


## Validation and Acceptance

Acceptance requires all of the following observable behavior.

On a synthetic current Codd ledger, the default suite imports all combined Kiroku and Keiro
history without executing the historical SQL again. On a synthetic sentinel-name ledger,
the import initially fails safely or the fixture proves the names are incompatible, the
checked-in realignment script changes only the expected names, and import then succeeds. On
a synthetic `0.1.0.0` layout, the remediation moves tables into `keiro`, preserves seeded
snapshot and timer rows, tolerates a second run, and allows history import followed by the
native tail. Native ledger verification and live-schema verification both pass at the end.

`keiro-migrate import-codd-history --help` still exists, and `keiro-migrate up` still blocks
when a Codd ledger exists with absent or empty native history. The existing default tests
for both behaviors remain green. `keiro-migrate new`, `verify`, `verify-schema`, and `up`
continue to use pg-migrate.

Neither `codd` nor `codd-extras` appears in a fresh Cabal plan or source distribution. The
manual `legacy-codd-tools` flag, `keiro-write-expected-schema`, and
`keiro-migrations-legacy-test` no longer exist. The only adapter package with Codd in its
name is `pg-migrate-import-codd`, and its presence is expected because it reads durable old
ledger state without depending on the Codd runner.

`cabal check`, the focused migration test, `just verify`, and strict ADR validation all
exit successfully. The final source distribution contains every artifact required by the
documented upgrade runbook and contains none of the deleted alternative-runner machinery.


## Idempotence and Recovery

The new integration tests operate only on ephemeral PostgreSQL databases. They may be
rerun without cleanup and must never point at a durable user database. The checked-in
filename fixup and schema remediation are already designed to be idempotent; the new tests
must execute each twice or otherwise prove repeat behavior where the script's contract
requires it.

Make the change additively: land or at least validate the default-suite replacements before
deleting the legacy suite. If a ported test fails, keep the old target intact while fixing
the fixture. Do not weaken strict import, skip row-survival assertions, or remove an
operator artifact merely to make deletion easier.

File removal is recoverable from Git, but the working tree contains unrelated user edits.
Never use `git reset --hard`, `git checkout --`, or broad restore commands. If a deletion
overlaps an unrelated modification, stop and preserve that content explicitly. A stale
Cabal plan is not evidence that removal failed; use the temporary `--builddir` procedure in
Concrete Steps rather than deleting `dist-newstyle`.

The implementation does not modify a real database schema or ledger. If validation reveals
that `sql-migrations/` or another proposed deletion is used by a supported path not found
during plan creation, record the discovery and decision in this plan, retain the artifact,
and update every affected section before proceeding.


## Interfaces and Dependencies

The supported runner dependencies remain `pg-migrate ^>=1.1.0.0`,
`pg-migrate-embed ^>=1.1.0.0`, and `pg-migrate-cli ^>=1.1.0.0`. The compatibility adapter
remains `pg-migrate-import-codd ^>=1.1.0.0`, identified canonically as
`mori://shinzui/pg-migrate/packages/pg-migrate-import-codd`. Its released package reads
Codd ledger versions through Hasql and has no dependency on `mzabani/codd`. Do not change
these bounds as incidental cleanup; if a compatibility change becomes necessary, verify
the latest authoritative Hackage release and upstream tags before editing them.

At the end of the plan, `Keiro.Migrations.History.Codd` continues to expose:

```haskell
frameworkCoddHistoryMappings :: NonEmpty HistoryMapping

frameworkCoddSourceConfig
  :: ConnectionProvider
  -> Bool
  -> Text
  -> Confirmation
  -> Either CoddDefinitionError CoddSourceConfig
```

`Keiro.Migrations` continues to expose the read-only safety boundary:

```haskell
preflightFreshLedgerOverCodd
  :: Settings.Settings
  -> IO (Either MigrationError CoddLedgerPreflight)
```

`keiro-migrations/app/Main.hs` continues to expose the operator command
`import-codd-history --reason TEXT --confirm` and the
`--allow-fresh-ledger-over-codd` escape hatch restricted to `up`. These names refer to the
source ledger format and remain accurate.

The following interfaces must no longer be buildable or exposed:
`Keiro.Migrations.LegacyCodd`, `Keiro.Migrations.ExpectedSchema`,
`Keiro.Migrations.New`, the `keiro-write-expected-schema` executable, the
`keiro-migrations-legacy-test` test suite, and the `legacy-codd-tools` Cabal flag. There
must be no Haskell import whose module name begins with `Codd` and no dependency named
`codd` or `codd-extras` in this repository's active package configuration.
