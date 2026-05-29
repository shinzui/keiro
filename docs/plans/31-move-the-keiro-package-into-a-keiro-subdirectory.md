---
id: 31
slug: move-the-keiro-package-into-a-keiro-subdirectory
title: "Move the keiro package into a keiro subdirectory"
kind: exec-plan
created_at: 2026-05-28T23:26:49Z
---

# Move the keiro package into a keiro subdirectory

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This repository is a Cabal multi-package workspace. A "Cabal package" is the unit named in a `.cabal` file and listed in the workspace file `cabal.project`; other packages depend on it through their `build-depends` fields. Today the workspace is asymmetric and confusing: the `keiro-core` package lives in its own subdirectory (`keiro-core/`, with its sources under `keiro-core/src/`), but the main `keiro` package lives directly at the repository root — its cabal file is `keiro.cabal` at the top level and its sources are under the top-level `src/`. A newcomer opening the repository sees both a top-level `src/` and a `keiro-core/src/` and cannot tell which package owns which, or why one package gets a folder and the other does not.

After this change, every package lives in its own clearly named subdirectory. The `keiro` package moves wholesale into a new `keiro/` folder: `keiro/keiro.cabal`, `keiro/src/`, `keiro/test/`, plus the package's `keiro/README.md` and `keiro/CHANGELOG.md`. The repository root keeps only workspace-level files (`cabal.project`, `mori.dhall`, `Justfile`, `flake.nix`, `docs/`, and a short orientation `README.md`) and the package subdirectories `keiro/`, `keiro-core/`, `keiro-migrations/`, and `jitsurei/`. The layout becomes uniform and self-explanatory.

The package itself is **not renamed**. It is still the Cabal package named `keiro`, it still exposes the same modules (`Keiro`, `Keiro.Command`, `Keiro.Snapshot`, and so on), and downstream packages and external users keep writing `build-depends: keiro` and `import Keiro.Command` exactly as before. Only the on-disk location of the package's files changes, plus the one line in `cabal.project` that points at it.

This also advances a second goal: preparing the packages for release on Hackage (the public Haskell package repository). Hackage publishes one package per uploaded source tarball, and a package's tarball — produced by `cabal sdist` — may only contain files that live **inside that package's own directory**. Files referenced by a cabal file's `extra-doc-files` field (here, `README.md` and `CHANGELOG.md`) must therefore sit beside the cabal file, not above it. Moving `keiro.cabal` together with its `README.md` and `CHANGELOG.md` into `keiro/` keeps those `extra-doc-files` paths valid and lets `cabal sdist keiro` produce a self-contained, Hackage-uploadable tarball. The same is already true for `keiro-core/`.

You can see the change working by running, from the repository root, `cabal build all` (the whole workspace still compiles), `cabal test keiro-test` / `cabal test jitsurei-test` / `cabal test keiro-migrations-test` (all existing suites still pass), and `cabal sdist keiro keiro-core` (both packages produce source tarballs whose contents include their own `README.md` and `CHANGELOG.md`, proving each package directory is self-contained for Hackage).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Move the `keiro` package files (`src/`, `test/`, `keiro.cabal`, `README.md`, `CHANGELOG.md`) into a new `keiro/` subdirectory with `git mv` to preserve history. All 27 files recorded as renames (`R`) by `git status --short`. (done 2026-05-28)
- [x] M1: Update `cabal.project` so the `packages` list points at `keiro` instead of `.`. (done 2026-05-28)
- [x] M1: Add a short workspace-level `README.md` at the repository root describing the multi-package layout. (done 2026-05-28)
- [x] M1: Fix the one stale path reference inside the moved `keiro/README.md` (it named `keiro.cabal`; now names `keiro/keiro.cabal`). (done 2026-05-28)
- [x] M1: Verify the package graph with `mori show --full` (unchanged — still lists `keiro-core` and `keiro`) and `cabal build all` (succeeded, warnings only). (done 2026-05-28)
- [x] M2: Ran the full validation set. `keiro-migrations-test` passed (1 example, 0 failures). `keiro-test` (81 examples, 51 failures) and `jitsurei-test` (16 examples, 15 failures) fail on a **pre-existing environment precondition** unrelated to this move — the DB-backed integration suites need a kiroku-migrated ephemeral database that nothing in `cabal test` provisions. Proven independent of the move: the pre-built test binary fails identically when run from the old repository-root working directory (see Surprises & Discoveries). (done 2026-05-28)
- [x] M2: Proved Hackage-readiness with `cabal sdist keiro keiro-core`. Both tarballs were written under `dist-newstyle/sdist/`, and `keiro-0.1.0.0.tar.gz` contains `keiro-0.1.0.0/README.md`, `keiro-0.1.0.0/CHANGELOG.md`, `keiro-0.1.0.0/keiro.cabal`, `keiro-0.1.0.0/src/Keiro.hs`, and `keiro-0.1.0.0/test/Main.hs`. (done 2026-05-28)
- [x] M2: Updated the living sections (Surprises, Decision Log, Outcomes) with observed results. (done 2026-05-28)
- [x] M3 (follow-up): Closed the pre-existing gap so the DB-backed suites self-provision their schema. First pass wired `runAllKeiroMigrations` (LaxCheck) into the `withTestStore`/`withTwoContexts` helpers of `keiro/test/Main.hs` and `jitsurei/test/Main.hs`, and fixed one jitsurei test that needed `initializeJitsureiTables` after dispatch began running the target inline projection. All suites passed. (done 2026-05-28)
- [x] M4 (follow-up): Reworked the fixture to the ephemeral-pg "suite-level template databases" best practice (per-example migration was the anti-pattern that guide explicitly calls out). Added a shared `keiro-test-support` library package (`Keiro.Test.Postgres`) exposing `withMigratedSuite`/`withFreshStore`/`withFreshStores2`: one cached server per suite, one migrated template database, and a `CREATE DATABASE … TEMPLATE` clone per example. Both test suites now depend on it instead of `codd`/`attoparsec`/`containers`/`keiro-migrations`/`ephemeral-pg` directly. Registered the package in `cabal.project` and `mori.dhall`. All suites pass and run faster: `keiro-test` 81/0 (~30s → ~9.5s), `jitsurei-test` 16/0 (~9s → ~2.3s), `keiro-migrations-test` 1/0; `mori` lists three packages; `cabal build all` clean. (done 2026-05-28)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The build and the structural goal went exactly as planned: `cabal build all` succeeded after the move with only pre-existing warnings, `mori show --full` still listed `keiro-core` and `keiro` unchanged, and no edits to `keiro/keiro.cabal`, `Justfile`, `flake.nix`, `mori.dhall`, or the sibling cabal files were needed.

- **The DB-backed integration suites `keiro-test` and `jitsurei-test` fail in this environment, and the failure is a pre-existing precondition unrelated to the move.** They fail because the ephemeral PostgreSQL the tests start has no kiroku base schema (`streams`, `events`, `stream_events`):

```text
1) Keiro.Command creates a stream and appends the first command event
     expected successful command, got Left (ConnectionError "... ServerError \"42P01\"
     \"relation \\\"stream_events\\\" does not exist\" ...")
```

  Root cause, established by reading the dependencies: the test helper `withTestStore` in `keiro/test/Main.hs` does only `Pg.withCached $ \db -> Store.withStore (defaultConnectionSettings (connectionString db)) action` and applies no migrations; `Kiroku.Store.Connection.withStore` deliberately does not create schema (its own comment: "Runtime queries still require migrations to have created the schemas before the store is opened"); and `EphemeralPg.withCached` caches only the clean `initdb` output (no schema). The suites therefore require a separately provisioned / pre-migrated database that this shell does not have, and `keiro-test`'s suite does not even list `keiro-migrations` in `build-depends`, so it cannot apply them itself.

  Proof that the move did not cause this: the already-compiled `keiro-test` binary (built from the relocated tree) fails with the **identical** `relation "stream_events" does not exist` error whether run from the new package directory or from the old repository root, bypassing `cabal` and the file layout entirely:

```text
# run from repository root (the pre-move working directory):
$ .../keiro-0.1.0.0-keiro-test ... --match ".../creates a stream and appends the first command event/"
1 example, 1 failure   # same 42P01 relation "stream_events" does not exist
```

  Corroboration: `cabal test keiro-migrations-test` **passes** (`1 example, 0 failures`) in the same shell, which spins up its own ephemeral PostgreSQL and applies the codd migrations itself — so PostgreSQL tooling works here; only the un-provisioned `keiro-test`/`jitsurei-test` suites are blocked.

- `cabal sdist` confirmed the Hackage-readiness goal directly. The relocated `keiro` package's tarball carries its own docs because they now sit inside the package directory:

```text
$ tar tzf dist-newstyle/sdist/keiro-0.1.0.0.tar.gz | grep -E 'README|CHANGELOG'
keiro-0.1.0.0/CHANGELOG.md
keiro-0.1.0.0/README.md
```

- Minor Git note: because `README.md` was both moved into `keiro/README.md` and replaced at the root by a new workspace README, Git records the root `README.md` as modified plus `keiro/README.md` as added rather than a pure rename. The package README content is preserved verbatim in `keiro/README.md` (only the one `keiro.cabal` → `keiro/keiro.cabal` path reference changed).

- **Follow-up (M3): closing the test gap.** Wiring `runAllKeiroMigrations` into the test helpers made `keiro-test` go fully green (81/0) but left one `jitsurei-test` failure. The failure was a real assertion, not a schema-load error: the fulfillment process-manager dispatch returned `commandResults = [PMCommandFailed (StoreFailed (... relation "jitsurei_order_summary" does not exist ...))]`. The cause is a recent behavior change (commit `283cc5d`, "run target inline projections on dispatch"): dispatching now also runs the target's inline order-summary projection, which writes to the application table `jitsurei_order_summary`. That table is created by `initializeJitsureiTables` (via `initializeOrderSummaryTable`), which this test — unlike its sibling at `jitsurei/test/Main.hs:180` — did not call. Adding `initializeJitsureiTables` at the top of the test fixed it (16/0). This was latent: before the helpers applied migrations, the test errored on the missing kiroku base schema long before reaching the projection, so the stale fixture never surfaced.

- The per-test migration cost is modest: `keiro-test` runs in ~30s (81 examples, each restoring a clean cached cluster and applying ~4 codd migrations), `jitsurei-test` in ~9s. Acceptable for correctness and isolation; each test still gets a pristine database.


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep the package name `keiro`; do not introduce a new `keiro-runtime` package, an umbrella re-export package, or a rename. This plan is a pure on-disk relocation of the existing `keiro` package from the repository root into a `keiro/` subdirectory.
  Rationale: The user's goal is to remove the confusing asymmetry between the root-level `keiro` package and the subdirectory `keiro-core` package, not to re-architect the package graph. Renaming or adding packages would force `jitsurei`, `keiro-migrations`, and any external user to change their `build-depends`, and would change the public import story, for no benefit the user asked for. A location-only move achieves the clarity goal with the smallest possible blast radius.
  Date: 2026-05-28

- Decision: Move `README.md` and `CHANGELOG.md` into `keiro/` along with `keiro.cabal`, and create a new short orientation `README.md` at the repository root.
  Rationale: `keiro.cabal` lists `README.md` and `CHANGELOG.md` in `extra-doc-files`; those paths are resolved relative to the cabal file's directory. After the move, the cabal file is at `keiro/keiro.cabal`, so the documents must live at `keiro/README.md` and `keiro/CHANGELOG.md` for `cabal sdist keiro` to include them — a hard requirement for the stated Hackage goal, because a source tarball cannot reference files above the package directory. The existing root `README.md` is already written as the `keiro` package's README (it describes what the package provides and its runtime stack), so moving it is correct. A small new root `README.md` is added so the GitHub repository landing page is not empty and so it can orient readers to the new multi-package layout, reinforcing the "not confusing" goal.
  Date: 2026-05-28

- Decision: Do not edit `keiro/keiro.cabal`'s `hs-source-dirs`, `Justfile`, `flake.nix`, `mori.dhall`, `jitsurei/jitsurei.cabal`, or `keiro-migrations/keiro-migrations.cabal`.
  Rationale: Research confirmed `keiro.cabal` uses `hs-source-dirs: src` (library) and `hs-source-dirs: test` (test suite), which are relative to the cabal file and therefore resolve to `keiro/src` and `keiro/test` automatically after the move. `Justfile` and `flake.nix` reference only Cabal target names (`keiro`, `keiro-test`, `cabal build all`, `haskellPackages.keiro`), never source paths. `mori.dhall` records package names and descriptions but no source paths. The sibling cabal files depend on `keiro` by package name. None of these are affected by an on-disk move, so touching them would add risk without purpose.
  Date: 2026-05-28

- Decision (follow-up M3): Make the DB-backed test suites self-provision their schema by applying `runAllKeiroMigrations` (with `LaxCheck`) to a freshly provisioned ephemeral database before opening a store, rather than relying on an externally pre-migrated/warmed database.
  Rationale: After the move the suites still could not run in a clean shell because nothing applied the kiroku/keiro schema (root-caused in Surprises & Discoveries). `keiro-migrations-test` already proved the codd-on-ephemeral pattern, so the suites reuse it. `LaxCheck` is correct because ephemeral test databases keep no checked-in codd expected-schema representation, so strict verification would (noisily) flag environment-specific role/db-setting differences. This closes the gap the original plan had explicitly deferred; it is recorded here because the user asked to fix the tests after the move landed.
  Date: 2026-05-28

- Decision (follow-up M4, supersedes the per-example mechanism of M3): Provision the schema using the ephemeral-pg "suite-level template databases" pattern — start one cached server per suite, migrate a single template database once, and clone a clean database per example with `CREATE DATABASE … TEMPLATE …` — implemented in a shared `keiro-test-support` library rather than re-running migrations inside each example's helper.
  Rationale: The M3 first pass re-ran `runAllKeiroMigrations` for every example, which is exactly the anti-pattern the ephemeral-pg guide `docs/suite-template-databases.md` warns against for migration-heavy suites; the user flagged that it did not follow ephemeral-pg best practices. The template pattern keeps the same per-example isolation (each example still gets a pristine, empty, migrated database) but moves server startup and migration to once-per-suite, cutting `keiro-test` from ~30s to ~9.5s and `jitsurei-test` from ~9s to ~2.3s. Constraints honored: migrations run through short-lived codd connections that are released before the first clone (the template must have no active sessions when PostgreSQL copies it); each example connects only to its clone; the `Store` (with its notifier/publisher LISTEN connections) is torn down before the clone is dropped with `DROP DATABASE … WITH (FORCE)`. The fixture lives in a shared package because both `keiro-test` and `jitsurei-test` need it, avoiding ~80 lines of duplication and the `..`-relative `hs-source-dirs` that would break `cabal sdist`.
  Date: 2026-05-28

- Decision: Proceed without an Intention ID and therefore without an `Intention:` git trailer.
  Rationale: When asked at the start of the session, the user did not supply an Intention ID and chose to move directly to the work. Per the exec-plan skill, absence of an Intention means commits carry only the `ExecPlan:` trailer.
  Date: 2026-05-28


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (both milestones complete, 2026-05-28).** The `keiro` package was relocated from the repository root into a `keiro/` subdirectory: `keiro/keiro.cabal`, `keiro/src/` (23 modules), `keiro/test/Main.hs`, `keiro/README.md`, and `keiro/CHANGELOG.md` now live together, moved with `git mv` to preserve history. The workspace is symmetric — every package (`keiro/`, `keiro-core/`, `keiro-migrations/`, `jitsurei/`) is now its own subdirectory — which is the "no longer confusing" goal the plan existed to deliver. The only workspace edit was `cabal.project`'s first `packages` entry (`.` → `keiro`); a short new workspace-level `README.md` was added at the root, and a single stale `keiro.cabal` → `keiro/keiro.cabal` reference inside the moved package README was corrected. The package name, module names, `reexported-modules`, and dependency graph are unchanged, so `jitsurei` and any external consumer keep `build-depends: keiro` and `import Keiro.*` exactly as before.

Verified against the original purpose: `cabal build all` succeeds through the new layout; `mori show --full` is unchanged; `cabal sdist keiro keiro-core` produces self-contained tarballs whose `keiro` archive includes its own `README.md` and `CHANGELOG.md` — the concrete demonstration of the Hackage-preparation goal, because the package's docs now travel inside the package directory rather than above it.

**Gap, then closed in follow-up M3 (2026-05-28).** Immediately after the location-only move, the DB-backed integration suites `keiro-test` and `jitsurei-test` did not pass in a clean shell because they required a kiroku-migrated ephemeral database that the test harness did not provision (see Surprises & Discoveries for the full root-cause analysis and the proof — identical failure from the old repository-root working directory — that this was pre-existing and independent of the relocation). At the user's request this gap was then closed, and on a second pass reworked to follow ephemeral-pg best practices. The fixture now uses the "suite-level template databases" pattern, implemented in a new shared `keiro-test-support` library (`Keiro.Test.Postgres`, exposing `withMigratedSuite`/`withFreshStore`/`withFreshStores2`): one cached PostgreSQL server per suite, one migrated template database, and a `CREATE DATABASE … TEMPLATE` clone per example. Both `keiro-test` and `jitsurei-test` depend on `keiro-test-support` (no longer on `codd`/`attoparsec`/`containers`/`keiro-migrations`/`ephemeral-pg` directly), and the package is registered in `cabal.project` and `mori.dhall`. One stale jitsurei fixture was also fixed (it needed `initializeJitsureiTables` after dispatch began running the target inline projection). All suites pass: `keiro-test` 81/0 (~9.5s), `jitsurei-test` 16/0 (~2.3s), `keiro-migrations-test` 1/0, with `cabal build all` clean and `mori` listing three library packages.

**Lesson.** When a relocation cannot change runtime behavior, the cheapest airtight regression check is to run the already-compiled artifact from the pre-change working directory: if it behaves identically, the relocation is exonerated without a costly rebuild of the prior commit.


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. It is a Cabal multi-package workspace. "Cabal" is the standard Haskell build tool; a "package" is one library or program described by a `.cabal` file; the workspace file `cabal.project` lists which package directories Cabal should build together. The terms `build-depends` (a cabal-file field naming the packages a package needs) and `hs-source-dirs` (a cabal-file field naming the directories that hold a package's Haskell source, resolved relative to the directory containing the cabal file) are used throughout this plan.

The workspace currently contains these packages:

- `keiro` — the main framework library. Its cabal file is the top-level `keiro.cabal`. Its library sources are under the top-level `src/` (23 tracked files: `src/Keiro.hs` plus `src/Keiro/*` such as `Keiro/Command.hs`, `Keiro/Snapshot.hs`, `Keiro/ReadModel.hs`, `Keiro/Projection.hs`, `Keiro/ProcessManager.hs`, `Keiro/Router.hs`, `Keiro/Inbox*`, `Keiro/Outbox*`, `Keiro/Timer*`, `Keiro/Telemetry.hs`). Its single test file is the top-level `test/Main.hs`, declared by the `keiro-test` test suite. `keiro.cabal` also re-exports several modules from `keiro-core` (see below) via its `reexported-modules` field.
- `keiro-core` — stable contract modules (`Keiro.Codec`, `Keiro.EventStream`, `Keiro.Integration.Event`, `Keiro.Prelude`, `Keiro.Snapshot.Policy`, `Keiro.Stream`). Its cabal file is `keiro-core/keiro-core.cabal` and its sources are under `keiro-core/src/`. This package was carved out of `keiro` by a prior plan checked into the repository at `docs/plans/29-introduce-keiro-core-package.md`; that plan is the direct precedent for the `git mv`-based mechanics used here. The `keiro` library depends on `keiro-core` and re-exports its modules, so an application depending on `keiro` keeps seeing module names like `Keiro.Codec`.
- `keiro-migrations` — SQL schema migrations. Cabal file `keiro-migrations/keiro-migrations.cabal`, sources under `keiro-migrations/src/`. It does **not** depend on `keiro`.
- `jitsurei` — guide-backed worked examples. Cabal file `jitsurei/jitsurei.cabal`, sources under `jitsurei/src/`, plus `jitsurei/app/` executables and a `jitsurei/test/` suite. Its library, `jitsurei-demo` executable, and `jitsurei-test` suite all list `keiro` in `build-depends` by package name.

The workspace file `cabal.project` currently begins:

```text
packages:
  .
  keiro-core
  keiro-migrations
  jitsurei
```

The leading `.` is the entry that picks up the root-level `keiro.cabal`. After this plan, that entry becomes `keiro`.

The top-level `keiro.cabal` declares `extra-doc-files: README.md` and `CHANGELOG.md`. "extra-doc-files" is a cabal-file field listing documentation files bundled into the package's source tarball; these paths are resolved relative to the cabal file's directory and, for a Hackage upload, must not point above that directory. The repository root therefore currently holds `README.md` and `CHANGELOG.md` that belong to the `keiro` package. `keiro-core/` has no README or CHANGELOG of its own.

Build and environment tooling that a reader might worry about, and why none of it needs changing for this move:

- `Justfile` (note the capital J; there is no lowercase `justfile`) defines recipes such as `haskell-test` which run `cabal test keiro-test`, `cabal test jitsurei-test`, and `cabal build all`. These name Cabal targets, not source paths.
- `flake.nix` (Nix build/dev-shell definition) references `haskellPackages.keiro` and the environment variable `PGDATABASE=keiro`; both are names, not paths.
- `mori.dhall` (a local project-registry descriptor consumed by the `mori` tool) lists the package names `keiro-core` and `keiro` and the project description, but records no source directories.
- There is no `.github/` directory and no `hie.yaml` in this repository, so there is no CI workflow or HLS cradle file referencing source paths to update.

"Hackage" is the public Haskell package repository at hackage.haskell.org. "sdist" is the source-distribution tarball that `cabal sdist` produces for a package and that one uploads to Hackage; it contains exactly the files inside the package directory that the cabal file references.

This plan uses these terms:

`relocation` means moving a file or directory to a new path without changing its contents (beyond, in one documentation file, a single stale path reference). No module is renamed and no Haskell code logic changes.

`workspace-level file` means a file that configures the whole multi-package build (`cabal.project`, `mori.dhall`, `Justfile`, `flake.nix`) or documents the repository as a whole (the new root `README.md`), as opposed to a file owned by one package.


## Plan of Work

The work is small and naturally falls into two milestones: the relocation itself (Milestone 1) and the full validation including Hackage-readiness proof (Milestone 2). Both run entirely from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

### Milestone 1 — Relocate the `keiro` package into `keiro/`

Scope: physically move the `keiro` package's files into a new `keiro/` directory, repoint `cabal.project` at the new location, add a workspace-level root `README.md`, and correct one stale path reference in the moved package README. At the end of this milestone, the repository root no longer contains `src/`, `test/`, `keiro.cabal`, or the package's `README.md`/`CHANGELOG.md`; instead `keiro/` contains `keiro/keiro.cabal`, `keiro/src/`, `keiro/test/`, `keiro/README.md`, and `keiro/CHANGELOG.md`. The workspace still resolves the same package graph.

First, create the destination directory and move the package with `git mv` so Git records the moves as renames and preserves history. Moving a directory with `git mv src keiro/src` moves the whole tree, so individual module files do not need separate commands.

```bash
mkdir -p keiro
git mv src keiro/src
git mv test keiro/test
git mv keiro.cabal keiro/keiro.cabal
git mv README.md keiro/README.md
git mv CHANGELOG.md keiro/CHANGELOG.md
```

No edit is required inside `keiro/keiro.cabal`. Its library stanza uses `hs-source-dirs: src` and its `keiro-test` suite uses `hs-source-dirs: test`; because those are relative to the cabal file's directory, they now resolve to `keiro/src` and `keiro/test`. Its `extra-doc-files: README.md` / `CHANGELOG.md` now resolve to `keiro/README.md` and `keiro/CHANGELOG.md`, which is exactly where the `git mv` commands placed them.

Second, repoint the workspace at the new directory. Edit `cabal.project` and change the first package entry from `.` to `keiro`:

```diff
 packages:
-  .
+  keiro
   keiro-core
   keiro-migrations
   jitsurei
```

Leave the `source-repository-package` stanzas and `allow-newer` block in `cabal.project` untouched; they reference external dependency checkouts and are unrelated to this move.

Third, correct the one stale reference inside the moved package README. `keiro/README.md` contains the sentence "The package metadata lives in `keiro.cabal`." Because the file now sits next to its cabal file inside `keiro/`, but the surrounding prose speaks from the repository-root perspective ("From the repository root: …"), update that sentence to name the new path so a reader at the root can find the file:

```diff
-The package metadata lives in `keiro.cabal`.
+The package metadata lives in `keiro/keiro.cabal`.
```

Do not otherwise rewrite `keiro/README.md`; its build commands (`cabal build all`, `cabal test all`, `cabal test jitsurei-test`) are still run from the repository root and remain correct.

Fourth, add a short workspace-level `README.md` at the repository root so the repository landing page is not empty and so the multi-package layout is self-explanatory. Keep it brief and factual — a one-paragraph description of the workspace plus a list of the four package directories and what each contains, and a pointer that the `keiro` package's own README lives at `keiro/README.md`. Its exact text is given in Concrete Steps.

Milestone 1 acceptance: `git status --short` shows the files as renames (`R`) plus the new root `README.md`, and `cabal build all` succeeds from the repository root. Running `mori show --full` still lists the two packages `keiro-core` and `keiro` exactly as before (the move changes no names, so `mori.dhall` is unchanged and this command is a confirmation, not an edit).

### Milestone 2 — Validate the workspace and prove Hackage-readiness

Scope: confirm that the relocation broke nothing and that the relocated package is self-contained enough to be packaged for Hackage. Nothing is edited in this milestone unless validation surfaces a problem; it is the proof stage.

Run the full build and every test suite from the repository root:

```bash
cabal build all
cabal test keiro-test
cabal test jitsurei-test
cabal test keiro-migrations-test
```

`keiro-test` exercises the relocated package directly. `jitsurei-test` proves that a sibling package which depends on `keiro` by name still resolves it after the move. `keiro-migrations-test` proves the rest of the workspace is unaffected. (Note from prior experience recorded in `docs/plans/29-introduce-keiro-core-package.md`: `keiro-migrations-test` prints a large schema-diff diagnostic containing the words `Error: DB and expected schemas do not match` during its repeatability check and then reports success; that diagnostic is expected and is not a failure. Read the final `examples, failures` summary line to judge pass/fail.)

Then prove Hackage-readiness — the second purpose of this plan — by producing source tarballs for the two library packages and confirming each tarball is self-contained, in particular that it includes the package's own `README.md` and `CHANGELOG.md` (which is only possible because those files now live inside each package directory):

```bash
cabal sdist keiro keiro-core
```

Inspect the produced `keiro` tarball's file list and confirm it contains `keiro-0.1.0.0/README.md` and `keiro-0.1.0.0/CHANGELOG.md`. The exact command and expected output are in Concrete Steps. This is the observable behavior that demonstrates the Hackage-preparation goal: before this plan, `cabal sdist keiro` would either omit those docs or fail because they sat above the package directory; after it, the tarball carries them.

Milestone 2 acceptance: all four `cabal` test/build commands succeed (each test suite's summary line reports `0 failures`), and `cabal sdist keiro keiro-core` produces two `.tar.gz` files under `dist-newstyle/sdist/` whose `keiro` tarball lists `README.md` and `CHANGELOG.md`. Record the observed summary lines in Surprises & Discoveries / Outcomes, then commit.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. Begin by confirming a clean starting point:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git status --short
```

If `git status --short` shows unrelated user changes, leave them alone; this plan only touches the files named below. If it shows that the move has already partially happened (for example `keiro/keiro.cabal` already exists), skip the corresponding `git mv` commands and continue from the first step not yet done (see Idempotence and Recovery).

Step 1 — move the package files:

```bash
mkdir -p keiro
git mv src keiro/src
git mv test keiro/test
git mv keiro.cabal keiro/keiro.cabal
git mv README.md keiro/README.md
git mv CHANGELOG.md keiro/CHANGELOG.md
```

After these commands, confirm the new layout:

```bash
git status --short
```

Expected (the `R` prefix means Git recorded a rename; exact percentages vary):

```text
R  CHANGELOG.md -> keiro/CHANGELOG.md
R  README.md -> keiro/README.md
R  keiro.cabal -> keiro/keiro.cabal
R  src/Keiro.hs -> keiro/src/Keiro.hs
R  src/Keiro/Command.hs -> keiro/src/Keiro/Command.hs
... (the remaining src/Keiro/* files) ...
R  test/Main.hs -> keiro/test/Main.hs
```

Step 2 — repoint `cabal.project`. Open `cabal.project` and change the first line under `packages:` from `  .` to `  keiro`, leaving every other line intact. The result should read:

```text
packages:
  keiro
  keiro-core
  keiro-migrations
  jitsurei
```

Step 3 — fix the stale path reference in the moved package README. In `keiro/README.md`, change the sentence that reads "The package metadata lives in `keiro.cabal`." to "The package metadata lives in `keiro/keiro.cabal`." Make no other change to that file.

Step 4 — create the workspace-level root README. Write a new file `README.md` at the repository root with this content:

````markdown
# keiro workspace

This repository is a Cabal multi-package workspace for the keiro event-sourcing
framework and workflow engine. Each package lives in its own subdirectory and is
listed in `cabal.project`.

## Packages

- `keiro/` — the main framework library (event-sourcing command cycle,
  snapshots, read models, projections, process managers, timers, inbox/outbox,
  and telemetry). See `keiro/README.md` for the full package overview.
- `keiro-core/` — stable, dependency-light contract modules (`Keiro.Codec`,
  `Keiro.EventStream`, `Keiro.Integration.Event`, `Keiro.Prelude`,
  `Keiro.Snapshot.Policy`, `Keiro.Stream`) shared by the other packages.
- `keiro-migrations/` — SQL schema migrations for the PostgreSQL event store.
- `jitsurei/` — guide-backed, runnable worked examples that depend on `keiro`.

## Building

From this directory:

```bash
cabal build all
cabal test all
```

Design history and implementation plans live under `docs/`.
````

Step 5 — confirm the package graph and build. The `mori` tool reads `mori.dhall`; because no package name changed, its output should be identical to before the move:

```bash
mori show --full
```

The packages section should still report:

```text
Packages (2)
  keiro-core  Library  Haskell
  keiro       Library  Haskell
```

Then build the whole workspace:

```bash
cabal build all
```

This should finish without `Failed to build`. If the Cabal solver reports it cannot find the `keiro` package, verify that `cabal.project` lists `keiro` (not `.`) under `packages` and that `keiro/keiro.cabal` exists.

Step 6 — run every test suite:

```bash
cabal test keiro-test
cabal test jitsurei-test
cabal test keiro-migrations-test
```

Each suite ends with a summary line of the form `N examples, 0 failures` (the `keiro-migrations-test` run prints a large schema-diff diagnostic first, including the words `Error: DB and expected schemas do not match`, and then still reports success — judge by the final summary line, not the diagnostic).

Step 7 — produce and inspect the source tarballs to prove Hackage-readiness:

```bash
cabal sdist keiro keiro-core
```

Expected output names the two tarballs, for example:

```text
Wrote tarball sdist to .../dist-newstyle/sdist/keiro-0.1.0.0.tar.gz
Wrote tarball sdist to .../dist-newstyle/sdist/keiro-core-0.1.0.0.tar.gz
```

List the contents of the `keiro` tarball and confirm the package docs are inside it:

```bash
tar tzf dist-newstyle/sdist/keiro-0.1.0.0.tar.gz | grep -E 'README\.md|CHANGELOG\.md'
```

Expected:

```text
keiro-0.1.0.0/CHANGELOG.md
keiro-0.1.0.0/README.md
```

Seeing both paths confirms the package directory is self-contained for a Hackage upload.

Step 8 — commit. Use a Conventional Commit message with the required `ExecPlan:` trailer:

```text
refactor: move the keiro package into a keiro/ subdirectory

Relocate the root-level keiro package (src, test, keiro.cabal, README,
CHANGELOG) into a keiro/ folder so every workspace package lives in its own
subdirectory, matching keiro-core. Repoint cabal.project at the new path and
add a workspace-level root README. No package, module, or dependency name
changes; downstream build-depends: keiro and Keiro.* imports are unaffected.
Keeping README/CHANGELOG beside keiro.cabal keeps cabal sdist tarballs
self-contained for a future Hackage release.

ExecPlan: docs/plans/31-move-the-keiro-package-into-a-keiro-subdirectory.md
```

This section must be updated with the actual observed transcripts (summary lines, tarball paths) as the work proceeds.


## Validation and Acceptance

Acceptance is not merely that files moved. The workspace must demonstrate that it still builds and tests cleanly through the new layout, and that the relocated package is now packageable for Hackage.

First, the whole workspace must build through the new `cabal.project` path entry:

```bash
cabal build all
```

This proves the solver resolves the `keiro` package from `keiro/keiro.cabal` and that `keiro/src` and `keiro/test` are picked up via the cabal file's relative `hs-source-dirs`.

Second, every existing test suite must still pass:

```bash
cabal test keiro-test
cabal test jitsurei-test
cabal test keiro-migrations-test
```

`keiro-test` exercises the relocated package itself. `jitsurei-test` proves a sibling that lists `keiro` in `build-depends` still resolves it — the strongest evidence that the package name and import surface are unchanged. `keiro-migrations-test` proves the unrelated parts of the workspace are intact.

Observed (2026-05-28): `keiro-migrations-test` passes (`1 example, 0 failures`). `keiro-test` and `jitsurei-test` fail in this environment, but for a reason that predates and is independent of this move: they connect to an ephemeral PostgreSQL that has no kiroku schema, because the test harness applies no migrations (`relation "stream_events" does not exist`). This was confirmed by running the pre-built `keiro-test` binary from the old repository-root working directory and observing the identical failure (see Surprises & Discoveries for full evidence). A reader validating this plan in an environment where those suites already pass should still see them pass after the move, because nothing the move changed can affect runtime database provisioning. Treat a `relation ... does not exist` failure as the missing-schema precondition, not as a regression from the relocation.

Third, the relocated package must produce a self-contained Hackage source tarball:

```bash
cabal sdist keiro keiro-core
tar tzf dist-newstyle/sdist/keiro-0.1.0.0.tar.gz | grep -E 'README\.md|CHANGELOG\.md'
```

The `grep` must print both `keiro-0.1.0.0/CHANGELOG.md` and `keiro-0.1.0.0/README.md`. This is the behavior that demonstrates the Hackage-preparation purpose: the package's documentation now travels inside the package's own tarball because it lives inside the package directory.

Fourth, a human can confirm the structural goal directly by listing the repository root and the new package directory:

```bash
ls
ls keiro
```

The root listing should no longer contain `src`, `test`, or `keiro.cabal`, and `keiro/` should contain `keiro.cabal`, `src`, `test`, `README.md`, and `CHANGELOG.md`. The repository root should contain a `README.md` (the new workspace-level one) and the four package directories `keiro`, `keiro-core`, `keiro-migrations`, and `jitsurei`. This is the visible "no longer confusing" outcome the plan exists to produce.


## Idempotence and Recovery

The `git mv` commands in Step 1 are **not** idempotent: each works only while the source still exists at its original path. If a move has already happened (for example after a partial or re-run), running it again fails with a message like `fatal: bad source, source=src, destination=keiro/src`. Before re-running, inspect the current state:

```bash
git status --short
ls keiro src test keiro.cabal README.md CHANGELOG.md 2>/dev/null
```

If some files already moved, run only the `git mv` commands for the files still at the root. The goal state is: `keiro/keiro.cabal`, `keiro/src/`, `keiro/test/`, `keiro/README.md`, and `keiro/CHANGELOG.md` exist, and none of `src/`, `test/`, `keiro.cabal`, `README.md` (the package one), or `CHANGELOG.md` remain at the root (a new workspace `README.md` at the root is expected and correct).

Steps 2–7 (editing `cabal.project`, fixing the README sentence, writing the root README, building, testing, and `cabal sdist`) are all safe to repeat. Editing `cabal.project` to `keiro` when it already says `keiro` is a no-op. Re-writing the root `README.md` overwrites it with the same content. `cabal build`, `cabal test`, and `cabal sdist` are read-or-regenerate operations with no harmful side effects; `cabal sdist` simply overwrites the tarballs under `dist-newstyle/sdist/`.

If `cabal build all` fails after the move, the most likely cause is `cabal.project` still listing `.` (so Cabal looks for a cabal file at the root that is no longer there) or a `git mv` that did not complete. Verify `cabal.project` lists `keiro` and that `keiro/keiro.cabal` exists. Do not use `git reset --hard` or `git checkout --` to recover unless the user explicitly asks for a destructive rollback; prefer completing the remaining `git mv` commands forward.

If a non-destructive rollback is needed, the inverse of Step 1 restores the original layout (`git mv keiro/src src`, etc.) and reverting `cabal.project`'s first entry to `.`; because the moves are tracked renames, this is safe and history-preserving.


## Interfaces and Dependencies

This plan introduces no new code interfaces, no new modules, and no new package dependencies. It is a relocation. What must remain true after it:

The Cabal package named `keiro` must still exist, now defined by `keiro/keiro.cabal`, and must still expose exactly the modules it exposes today: the top-level facade `Keiro`, the runtime modules `Keiro.Command`, `Keiro.Snapshot`, `Keiro.Snapshot.Codec`, `Keiro.Snapshot.Schema`, `Keiro.ReadModel`, `Keiro.ReadModel.Rebuild`, `Keiro.ReadModel.Schema`, `Keiro.Projection`, `Keiro.ProcessManager`, `Keiro.Router`, `Keiro.Inbox`, `Keiro.Inbox.Kafka`, `Keiro.Inbox.Schema`, `Keiro.Inbox.Types`, `Keiro.Outbox`, `Keiro.Outbox.Kafka`, `Keiro.Outbox.Schema`, `Keiro.Outbox.Types`, `Keiro.Timer`, `Keiro.Timer.Schema`, `Keiro.Timer.Types`, and `Keiro.Telemetry`; plus the `keiro-core` modules it re-exports via `reexported-modules` (`Keiro.Codec`, `Keiro.EventStream`, `Keiro.Integration.Event`, `Keiro.Prelude`, `Keiro.Snapshot.Policy`, `Keiro.Stream`). No `exposed-modules` or `reexported-modules` entry in `keiro/keiro.cabal` changes.

The `keiro` package must still declare its library `hs-source-dirs: src` and its `keiro-test` test suite `hs-source-dirs: test` and `main-is: Main.hs`; these are unchanged in text and resolve to `keiro/src` and `keiro/test` by virtue of the cabal file's new location.

The dependency graph is unchanged:

```text
keiro-core
  depends on: aeson, aeson-casing, base, bytestring, generic-lens, keiki,
              kiroku-store, lens, scientific, text, time, uuid

keiro
  depends on: keiro-core plus runtime dependencies (effectful, hasql,
              hasql-pool, hasql-transaction, keiki, keiki-codec-json,
              kiroku-store, shibuya-core, streamly, streamly-core,
              the hs-opentelemetry-* packages, and others already listed)

jitsurei
  depends on: keiro   (unchanged — by package name)

keiro-migrations
  independent of: keiro and keiro-core   (unchanged)
```

The only workspace-level interface that changes is `cabal.project`'s `packages` list, whose first entry moves from `.` to `keiro`. The `mori.dhall` registry descriptor, the `Justfile` recipes, the `flake.nix` outputs, `jitsurei/jitsurei.cabal`, and `keiro-migrations/keiro-migrations.cabal` are all unchanged because they reference the package only by name or by Cabal target, never by source path.

Before committing implementation work for this plan, use a Conventional Commit message and include the required trailer (no `Intention:` trailer, per the Decision Log):

```text
refactor: move the keiro package into a keiro/ subdirectory

ExecPlan: docs/plans/31-move-the-keiro-package-into-a-keiro-subdirectory.md
```


## Revision Notes

- 2026-05-28 (follow-up M3): After the location-only move landed and was validated, the user asked to fix the DB-backed test suites that the plan had deliberately left out of scope. The suites now self-provision their schema: `withTestStore`/`withTwoContexts` in `keiro/test/Main.hs` and `withTestStore` in `jitsurei/test/Main.hs` apply `runAllKeiroMigrations` (LaxCheck) to each ephemeral database before opening a store, reusing the `keiro-migrations-test` pattern; `keiro-migrations`, `codd`, `attoparsec`, and `containers` were added as test dependencies in `keiro/keiro.cabal` and `jitsurei/jitsurei.cabal`. A stale jitsurei test was also corrected to call `initializeJitsureiTables` now that dispatch runs the target inline projection (commit `283cc5d`). Progress (new M3 item), Surprises & Discoveries, Decision Log, and Outcomes & Retrospective were all updated to reflect this; the change is additive and does not alter the relocation described in M1/M2. Reason: the original "Gap" in Outcomes is now resolved, so all three suites pass (`keiro-test` 81/0, `jitsurei-test` 16/0, `keiro-migrations-test` 1/0).

- 2026-05-28 (follow-up M4): The user noted the M3 fix did not follow ephemeral-pg best practices — re-running migrations per example is the anti-pattern the library's `docs/suite-template-databases.md` guide warns against. Reworked the fixture to the recommended "suite-level template databases" pattern in a new shared `keiro-test-support` library package: `Keiro.Test.Postgres` exposes `withMigratedSuite` (one cached server + one migrated template database per suite), `withFreshStore`, and `withFreshStores2` (clone a clean database per example via `CREATE DATABASE … TEMPLATE`, open a store, drop it after). `keiro/test/Main.hs` and `jitsurei/test/Main.hs` now wrap `main` in `withMigratedSuite` and use `around (withFreshStore fixture)` / `around (withFreshStores2 fixture)`; their inline codd helpers were deleted and their direct `codd`/`attoparsec`/`containers`/`keiro-migrations`/`ephemeral-pg` test deps replaced with `keiro-test-support`. The package is registered in `cabal.project` and `mori.dhall`. Progress (new M4 item), Decision Log, Surprises, and Outcomes were updated. Reason: honor the documented best practice and cut suite runtime (`keiro-test` ~30s → ~9.5s, `jitsurei-test` ~9s → ~2.3s) while keeping per-example database isolation. All suites still pass and `cabal build all` is clean.
