---
id: 13
slug: migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide
title: "Migration hardening: integrity gates, safe apply path, operator tooling, and the migration ownership guide"
kind: master-plan
created_at: 2026-07-06T18:39:36Z
intention: "intention_01kwwbahspe0tazeaa1gk5w65b"
---

# Migration hardening: integrity gates, safe apply path, operator tooling, and the migration ownership guide

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Keiro is an event-sourcing framework whose PostgreSQL schema evolution lives in two
sibling packages: `keiro-migrations` (in this repository, at `keiro-migrations/`) and
`kiroku-store-migrations` (in the kiroku repository, at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations`). Both embed
timestamped SQL files at compile time and apply them through **codd** (the Haskell
migration runner `mzabani/codd`, pinned at tag `v0.1.8` in `cabal.project`). Keiro's
`keiro-migrate` executable applies kiroku's event-store migrations and keiro's framework
migrations through **one combined codd ledger**. Every user of the framework runs these
executables against their own databases, which is why the migration machinery must be
hardened beyond what a single in-house project would need: a defect here corrupts a
*user's* production database, not ours.

Two prior initiatives built the foundation this plan hardens: keiro's MasterPlan 12
(`docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md`) gave
keiro its own `keiro` schema, qualified DDL, a portable strict drift gate, and the alpha
remediation runbook; kiroku's MasterPlan 10
(`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md`)
gave kiroku a scaffolder (`kiroku-store-migrate new`), its own portable drift gate, and an
operator runbook — and **explicitly deferred apply-path hardening (advisory locks, retry
policy) as future work**. This initiative is that future work, plus the integrity
invariants that a source-code review of codd `v0.1.8` showed are still only conventions.

The review verified the following facts against the pinned codd tag (checkout at
`/Users/shinzui/Keikaku/hub/haskell/codd-project`, tag `v0.1.8`, paths relative to the
tag's repository root). These facts drive every child plan and are restated in each one:

1. codd keys a migration's applied-status by **filename only** — no body checksum
   anywhere in the pipeline (`src/Codd/Internal.hs`, `hasMigBeenApplied` looks up
   `WHERE name=?`). Editing a shipped migration body is undetectable.
2. The ledger table has `UNIQUE (name)` **and** `UNIQUE (migration_timestamp)`
   (`src/Codd/InternalSchema/V1.hs:17`). Keiro's combined kiroku+keiro ledger means a
   timestamp collision **across the two packages** breaks every consumer's migrate, and
   no current test checks uniqueness across the union.
3. `LaxCheck` returns `SchemasDiffer` without throwing (`src/Codd.hs:73-90`), and
   `keiro-migrate` discards that result (`keiro-migrations/app/Main.hs:44`) — production
   drift exits 0. `StrictCheck` throws on mismatch.
4. There is **no advisory locking** in codd's apply path (no hits for "advisory" in
   `src/`). Concurrent applies race; the loser hits the `UNIQUE (name)` violation.
5. codd's retry logic re-reads each migration on retry, and for **in-memory (embedded)
   migrations that path is `error "Re-reading in-memory streams is not yet implemented"`**
   (`src/Codd/Internal.hs:1218,1232`). Both packages pass embedded migrations, and both
   executables inherit `defaultRetryPolicy = RetryPolicy 2 (ExponentialBackoff 1s)`
   (`src/Codd/Types.hs:95`) unless `CODD_RETRY_POLICY` is set — so any transient failure
   in production triggers a retry that crashes with an unrelated error.
6. codd sorts in-memory migrations by timestamp itself (`src/Codd/Internal.hs:1255`), so
   `allKeiroMigrations`' simple `kiroku <> keiro` concatenation is safe. (A worry
   removed, not a fix needed.)
7. codd `v0.1.8` already contains internal-schema **V5, which renames `codd_schema` to
   `codd`** (`src/Codd/Internal.hs:912-913,927`) and auto-upgrades the internal schema
   during any apply run. Fresh databases migrated under the current pin have their ledger
   at `codd.sql_migrations`; the first `v0.1.8` migrate against an older database renames
   `codd_schema` → `codd` automatically. Every README, ledger-fixup template, and runbook
   in both repositories that says `codd_schema.sql_migrations` is **stale today**.

**After this initiative** the framework's migration story is hardened along four axes.
First, *integrity invariants are enforced, not documented*: a checked-in SHA-256
manifest (`migrations.lock`) makes editing a shipped migration body a CI failure; a
parity test makes a stale Template-Haskell embed a CI failure; a body lint rejects
unqualified DDL, `search_path` pins, and `CREATE INDEX CONCURRENTLY` without codd's
`-- codd: no-txn` directive; a combined-ledger uniqueness test covers the kiroku+keiro
union; a post-apply canary asserts the ledger's location and contents; and regression
tests freeze the ledger-fixup and alpha-remediation upgrade paths. Second, *the apply
path users run is safe*: unknown CLI arguments are rejected instead of silently
migrating, schema drift exits nonzero, embedded-migration retries are pinned to a single
try, and a shared PostgreSQL advisory lock serializes concurrent applies. Third,
*operators get first-class tooling*: `verify` strict-checks a live database against the
expected schema embedded in the executable (no repo checkout needed), `status` lists
applied vs pending migrations from the ledger, and a startup handshake API
(`missingMigrations`) lets applications fail fast when started against an un-migrated
database. Fourth, *developers get an ownership guide*: a new user doc that draws the line
between framework-owned migrations (the `kiroku` and `keiro` schemas, evolved only by
these packages) and application-owned migrations (projections, read models, and app
tables in application schemas), and shows exactly how to author, compose, and operate
both — the deliverable the user explicitly asked for.

**How you can see it working when the initiative is complete.** Editing one byte of any
shipped `.sql` file makes `cabal test keiro-migrations-test` (or the kiroku equivalent)
fail with a checksum message naming the file; adding a `.sql` file without recompiling
fails the parity test instead of silently applying a stale set; `keiro-migrate nwe
"typo"` prints a usage error and exits nonzero instead of migrating; two concurrent
`keiro-migrate` runs against one database both succeed, serialized by the advisory lock;
`keiro-migrate verify` against a drifted database exits nonzero and prints the differing
objects; `keiro-migrate status` lists every applied migration and says "0 pending" after
a successful apply; a service calling `missingMigrations` at startup against a fresh
database gets the full embedded list back; and a developer reading
`docs/user/migration-ownership.md` can answer "where do my projection tables' migrations
live, how do I name them, and how do I run them together with the framework's?" without
asking.

**In scope:** the `keiro-migrations` package (tests, runners, executable, `lock`
subcommand, docs), the `kiroku-store-migrations` package in the kiroku repository (same
surface), the kiroku pin bumps in this repository's `cabal.project`, the new
`docs/user/migration-ownership.md` guide plus updates to `docs/user/migrations.md`,
both package READMEs, and the stale `codd_schema` references everywhere (including
`.claude/skills/cohort-migrate` if present). **Out of scope:** a PostgreSQL 17
expected-schema snapshot and CI matrix (kiroku's bootstrap claims PG 17+ but only a
`v18` snapshot exists — recorded as future work, see Decision Log); the cross-project
shared scaffold library (that is `docs/plans/52-shared-codd-migration-scaffold-library-design-capture.md`,
design-captured and not greenlit — this initiative deliberately keeps its shared guard
code package-local so plan 52 can absorb it later); upstream codd fixes (the in-memory
re-read `error` should be reported upstream but we work around it); and any change to
the schema *shape* of either package (no new framework tables or DDL semantics).


## Decomposition Strategy

The initiative was split by functional concern, following the principles that each work
stream must produce an independently verifiable behavior and that cross-plan coupling is
minimized. Four concerns emerged — enforced integrity invariants, apply-path safety,
operator tooling, and developer documentation — with the integrity concern split into
two plans along the repository boundary because each plan's implementer works in a
different working tree, test suite, and commit stream, and because keiro's plan consumes
a library module that kiroku's plan publishes (a real hard dependency, not a file split).

1. **Integrity gates for kiroku-store-migrations** (EP-1, kiroku repository). The
   checksum manifest, embed-parity test, body lint, ledger canary, and a ledger-fixup
   regression test — all authored as pure validator functions in a new exposed library
   module `Kiroku.Store.Migrations.Guards` so that EP-2 (and framework consumers) can
   reuse them instead of forking a third copy. kiroku goes first because keiro depends
   on kiroku, never the reverse.

2. **Integrity gates for keiro-migrations** (EP-2, this repository). Bumps the kiroku
   pin to consume `Guards`, mirrors the manifest/parity/lint/canary, adds the
   **combined-ledger timestamp-uniqueness test across `allKeiroMigrations`** (the union
   is a keiro-only concern — only keiro maintains the combined ledger), ports kiroku's
   `scaffolderSpec` (keiro has a scaffolder but no round-trip test), and adds the
   upgrade-path regression tests for keiro's ledger fixup and the MasterPlan-12 alpha
   remediation script.

3. **Apply-path hardening** (EP-3, both repositories). One concern — "the executable a
   user runs cannot hurt them" — spanning both twin executables: strict CLI dispatch,
   drift exit codes, `KEIRO_MIGRATE_NO_CHECK` value parsing, the `singleTryPolicy`
   override that neutralizes the embedded-migration retry crash, and the shared
   advisory-lock serialization (one lock key, defined in kiroku, imported by keiro, so
   `kiroku-store-migrate` and `keiro-migrate` serialize against *each other* on the same
   database).

4. **Operator tooling** (EP-4, both repositories). `verify` and `status` subcommands
   built on the strict CLI dispatch EP-3 establishes (hence the hard dependency), the
   embedded expected-schema tree that `verify` needs, and the `missingMigrations`
   startup-handshake API. The grants convention for runtime roles is resolved here as
   documentation-first (see Decision Log).

5. **The migration ownership guide** (EP-5, this repository). The developer-facing
   deliverable: `docs/user/migration-ownership.md` plus updates to existing docs. It
   documents the final state of EP-1 through EP-4 (guards, lock, verify/status,
   handshake), so it finalizes last.

**Alternatives considered.** Splitting by repository throughout (kiroku-everything then
keiro-everything) was rejected: it would put unrelated concerns (test invariants and CLI
behavior) in one plan and make neither independently verifiable as a behavior. Merging
EP-3 and EP-4 ("everything in the executables") was rejected because EP-3 is
risk-reduction with no new surface (safe to ship alone) while EP-4 adds new user-facing
subcommands and API — different review and documentation surfaces, and EP-4 legitimately
builds on EP-3's dispatcher. Folding the upgrade-path regression tests into a sixth plan
was rejected to respect repo locality: kiroku's fixup test belongs with kiroku's gates
(EP-1), keiro's fixup + remediation tests with keiro's gates (EP-2). Building the shared
guard code as a new standalone package was rejected in deference to the not-yet-greenlit
plan 52; an exposed module inside `kiroku-store-migrations` delivers the reuse now and
can be extracted later.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Integrity gates for kiroku-store-migrations: checksum manifest, embed parity, body lint, and ledger canary | docs/plans/90-integrity-gates-for-kiroku-store-migrations-checksum-manifest-embed-parity-body-lint-and-ledger-canary.md | None | None | Complete |
| 2 | Integrity gates for keiro-migrations: shared guards, combined-ledger uniqueness, and upgrade-path regression tests | docs/plans/91-integrity-gates-for-keiro-migrations-shared-guards-combined-ledger-uniqueness-and-upgrade-path-regression-tests.md | EP-1 | None | Not Started |
| 3 | Harden the migration apply path: strict CLI, drift exit codes, single-try retries, and advisory-lock serialization | docs/plans/92-harden-the-migration-apply-path-strict-cli-drift-exit-codes-single-try-retries-and-advisory-lock-serialization.md | None | EP-1, EP-2 | Not Started |
| 4 | Operator tooling: embedded expected-schema verify, ledger status, and a startup migration handshake | docs/plans/93-operator-tooling-embedded-expected-schema-verify-ledger-status-and-a-startup-migration-handshake.md | EP-3 | EP-1, EP-2 | Not Started |
| 5 | Write the migration ownership guide: framework-owned vs application-owned migrations | docs/plans/94-write-the-migration-ownership-guide-framework-owned-vs-application-owned-migrations.md | EP-4 | EP-1, EP-2 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 is a root: it works entirely inside the kiroku repository and depends on nothing
here. EP-3 is also a root in principle — its CLI and runner changes do not require the
integrity gates — but it carries soft dependencies on EP-1 and EP-2 because all three
plans edit the same runner modules (`Kiroku/Store/Migrations.hs`,
`Keiro/Migrations.hs`) and the same executables (`app/Main.hs` in each package);
sequencing EP-3 after the gates avoids merge friction and lets EP-3's concurrent-apply
test reuse EP-1's exported embedded-names accessor. If parallel execution is desired,
EP-1 and EP-3 can proceed concurrently with care around those two files.

EP-2 hard-depends on EP-1 for a real artifact: the `Kiroku.Store.Migrations.Guards`
module, which keiro imports instead of duplicating validator logic. Consuming it
requires EP-1's work to be committed in the kiroku repository and the kiroku pin in this
repository's `cabal.project` (the two `source-repository-package` stanzas pointing at
`https://github.com/shinzui/kiroku.git`) to be bumped to the new SHA.

EP-4 hard-depends on EP-3 because `verify` and `status` are new subcommands of the
strict argument dispatcher EP-3 introduces; adding them to today's
"anything-that-isn't-`new`-migrates" dispatcher would be dangerous (a typo'd `verify`
would apply migrations). EP-4's soft dependencies on EP-1/EP-2 are for the ledger
canary's dual-schema detection idiom, which `status` reuses.

EP-5 hard-depends on EP-4 because the guide documents `verify`, `status`, the handshake,
and the grants convention; writing it earlier would document features that do not exist.
Its soft dependencies on EP-1/EP-2 cover the guard specs it tells consumers to adopt.

Parallelism summary: start EP-1 immediately; EP-3 may run concurrently with EP-1/EP-2 if
the shared-file integration points below are respected, otherwise run EP-1 → EP-2 → EP-3
→ EP-4 → EP-5 strictly. Every kiroku-repository change lands there first, then the
corresponding keiro-side plan bumps the pin.


## Integration Points

**The `Kiroku.Store.Migrations.Guards` module.** Defined by EP-1 as an exposed library
module of `kiroku-store-migrations` containing *pure* validator functions (no hspec
dependency): sentinel-timestamp detection, duplicate-timestamp detection, body lint, and
checksum-manifest parsing/rendering. EP-2 imports it in `keiro-migrations`' test suite
and `lock` subcommand; EP-5 documents it as the module consumers adopt in their own CI.
The functions take plain values (`[FilePath]`, `[(FilePath, ByteString)]`, a lint
configuration naming the required schema qualifier) and return violation descriptions
(`[Text]`), so callers wrap them in whatever test framework they use. If plan 52's
shared library is later greenlit, it absorbs this module; nothing here should
anticipate that beyond keeping the functions pure and configuration-driven.

**The runner modules and embedded-names accessors.** `keiro-migrations/src/Keiro/Migrations.hs`
and `kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` are touched by three plans:
EP-1/EP-2 add an exported `embeddedMigrationNames :: [FilePath]` (and expose the
name/bytes pairs for checksum tests), EP-3 wraps the `run*` helpers with the advisory
lock and the `singleTryPolicy` override, EP-4 adds `missingMigrations`. Land in that
order; keep each addition in its own top-level definitions so the diffs do not overlap.
The Template-Haskell embed comment discipline (touch the comment when `sql-migrations/`
changes) continues to apply to every plan that adds a `.sql` fixture.

**The executable dispatchers.** `keiro-migrations/app/Main.hs` and
`kiroku-store-migrations/app/Main.hs` currently dispatch `("new" : rest)` and treat
*everything else* as "apply migrations". EP-1/EP-2 add a `lock` subcommand (regenerate
`migrations.lock`); EP-3 replaces the fall-through with a strict dispatcher that accepts
exactly `new`, `lock`, `up` (and bare invocation for backward compatibility) and rejects
everything else; EP-4 extends the dispatcher with `verify` and `status`. EP-3 owns the
dispatcher's shape; EP-1/EP-2 must add `lock` as a new explicit case without changing
the fall-through (that is EP-3's job).

**The advisory lock key.** EP-3 defines a single exported constant in
`kiroku-store-migrations` (an `Int64` lock key; see EP-3 for the value and rationale)
used by both executables' apply paths via `pg_advisory_lock`. It must be shared —
`keiro-migrate` applies kiroku's migrations too, so the two executables must serialize
against each other on the same database, not merely against themselves. keiro imports
the constant after the EP-3 pin bump.

**The kiroku pin in `cabal.project`.** EP-2, EP-3, and EP-4 each contain kiroku-side
work followed by keiro-side work; each bumps the two kiroku `source-repository-package`
stanzas' `tag:` fields in `cabal.project` to the kiroku SHA that contains their
kiroku-side commits (the same mechanic as the existing commit
`chore(deps): bump kiroku pin to f25776f`). Bump once per plan, after the kiroku-side
work of that plan is complete.

**The `migrations.lock` manifest format.** EP-1 defines it (one line per migration:
`<sha256-hex>  <filename>`, sorted by filename, trailing newline, generated by the
`lock` subcommand); EP-2 uses the identical format for keiro. The format lives in one
place — `Guards`' render/parse functions — so it cannot drift between the packages.

**The ledger location (codd internal-schema V5).** codd `v0.1.8` stores its ledger at
`codd.sql_migrations` on fresh databases and auto-renames `codd_schema` → `codd` on
older ones during any apply. EP-1 defines the dual-schema detection idiom (query
`pg_namespace` for `codd` first, then `codd_schema`) in its ledger-canary test and
corrects kiroku's README and ledger-fixup template headers; EP-2 does the same for
keiro's README, fixup, and remediation verification queries; EP-4's `status` subcommand
reuses the idiom; EP-5 documents it for operators (including a check of
`.claude/skills/cohort-migrate` for stale references).


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. Reconcile these against the child plans' own Progress sections as
implementation proceeds.

- [x] EP-1: `Kiroku.Store.Migrations.Guards` module with pure validators (timestamps, lint, checksums) and the existing test guards rewired through it
- [x] EP-1: `migrations.lock` checksum manifest checked in, `kiroku-store-migrate lock` regenerates it, tamper test fails on a one-byte body edit
- [x] EP-1: Embed-parity test (embedded names == on-disk `sql-migrations/` listing) and exported `embeddedMigrationNames`
- [x] EP-1: Body lint wired for the `kiroku.` qualifier (bootstrap grandfathered), `search_path` ban, `CONCURRENTLY` ⇒ `-- codd: no-txn`
- [x] EP-1: Post-apply ledger canary (dual `codd`/`codd_schema` detection) and ledger-fixup regression test (sentinel-ledger fixture → fixup → migrate is a no-op)
- [x] EP-1: kiroku README/CHANGELOG updated, including the `codd` vs `codd_schema` ledger-location correction
- [ ] EP-2: kiroku pin bumped; keiro guards rewired through `Kiroku.Store.Migrations.Guards`; `scaffolderSpec` ported
- [ ] EP-2: keiro `migrations.lock` + `keiro-migrate lock`; embed-parity test; body lint for the `keiro.` qualifier
- [ ] EP-2: Combined-ledger timestamp-uniqueness test across `allKeiroMigrations` (kiroku ∪ keiro)
- [ ] EP-2: Ledger canary for the combined ledger; keiro ledger-fixup and alpha-remediation regression tests with row-survival assertions
- [ ] EP-2: keiro README/docs `codd_schema` corrections
- [ ] EP-3: kiroku strict CLI dispatch; `singleTryPolicy` override in embedded runners; shared advisory-lock constant + lock wrapper; concurrent-apply test
- [ ] EP-3: keiro strict CLI dispatch; drift exits nonzero (LaxCheck result inspected); `KEIRO_MIGRATE_NO_CHECK` value parsed; pin bumped; lock reused
- [ ] EP-4: Expected-schema trees embedded in both executables; `verify` subcommand strict-checks a live database without applying
- [ ] EP-4: `status` subcommand lists applied vs pending from the ledger (dual-schema aware)
- [ ] EP-4: `missingMigrations` startup handshake exported from both packages; grants convention documented
- [ ] EP-5: `docs/user/migration-ownership.md` published; `docs/user/migrations.md`, READMEs, and cross-links updated; stale `codd_schema` references swept

## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-07-06 (from planning research): codd `v0.1.8` — the *currently pinned* version —
  already ships internal-schema V5, which renames `codd_schema` to `codd`
  (`src/Codd/Internal.hs:912-913` at the tag) and auto-upgrades during any apply. This
  was assumed to be a future codd version during the MasterPlan-12 era; the fixup
  templates and READMEs written then are stale for fresh databases *today*. All child
  plans treat the ledger location as dual (`codd` first, `codd_schema` fallback).
- 2026-07-06 (from planning research): codd's retry path crashes on embedded migrations
  (`error "Re-reading in-memory streams is not yet implemented"`,
  `src/Codd/Internal.hs:1218,1232` at `v0.1.8`) and the executables inherit a 2-retry
  default policy. Test suites never see this because they pass `singleTryPolicy`
  explicitly. EP-3 pins the runners to single-try.
- 2026-07-06 (from EP-1 implementation): kiroku-store-migrations currently has seven
  SQL migration files, not the eight described during planning. The generated
  `migrations.lock` and the test suite are correct for the working tree:

  ```text
  Wrote migrations.lock (7 migrations)
  ```

- 2026-07-06 (from EP-1 implementation): EP-1 used `crypton` for SHA-256 because
  `cryptohash-sha256` and `base16-bytestring` were not registered in mori, while
  `kazu-yamamoto/crypton` was registered with local docs and source. EP-2 should
  reuse `Kiroku.Store.Migrations.Guards.sha256Hex` and manifest render/parse helpers
  rather than adding a separate hash dependency.
- 2026-07-06 (from EP-1 implementation): this hasql version executes multi-statement
  scripts with `Session.script :: Text -> Session ()`; it does not use the
  `Session.sql` name present in older plan prose.

## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Enforce the "never edit a shipped migration" rule with a checked-in SHA-256
  manifest (`migrations.lock`) verified by the test suites, regenerated only by an
  explicit `lock` subcommand.
  Rationale: codd keys applied-status by filename with no body checksum, and codd's
  no-txn resume machinery makes editing a partially-applied migration silently corrupt
  application order. A manifest turns an undetectable corruption vector into a reviewed
  CI failure. The MasterPlan-12 EP-1 body rewrite is exactly the kind of event that
  should require an explicit, reviewable lockfile regeneration.
  Date: 2026-07-06

- Decision: Publish the shared validator logic as an exposed module
  (`Kiroku.Store.Migrations.Guards`) inside `kiroku-store-migrations`, not as a new
  package, with keiro consuming it via the existing pin.
  Rationale: `docs/plans/52-shared-codd-migration-scaffold-library-design-capture.md`
  (the cross-project scaffold library) is design-captured but not greenlit; creating a
  package now would preempt that review. An exposed module delivers the reuse today —
  keiro already depends on `kiroku-store-migrations` — and plan 52 can absorb it later.
  The functions are pure and configuration-driven so consumers (and plan 52) can reuse
  them without hspec or codd in scope.
  Date: 2026-07-06

- Decision: Split integrity gates into two plans along the repository boundary (EP-1
  kiroku, EP-2 keiro) rather than one cross-repo plan.
  Rationale: different working trees, test suites, and commit streams; a real hard
  dependency (the `Guards` module plus pin bump) rather than an arbitrary file split;
  and keiro-only concerns (combined-ledger uniqueness, the remediation regression test)
  that have no kiroku counterpart.
  Date: 2026-07-06

- Decision: Pin the embedded-migration runners to `singleTryPolicy` regardless of
  `CODD_RETRY_POLICY`, and document the override.
  Rationale: codd `v0.1.8` cannot retry in-memory migrations — the retry path is
  `error "Re-reading in-memory streams is not yet implemented"` — so any retry masks the
  original failure with an unrelated crash. Failing once, loudly, with the real error is
  strictly better than pretending to have retries. Report upstream separately; revisit
  if codd implements in-memory re-reads.
  Date: 2026-07-06

- Decision: Serialize concurrent applies with a session-level PostgreSQL advisory lock
  taken by the executables around the codd apply, with one lock key shared by both
  packages (defined in kiroku, imported by keiro).
  Rationale: codd has no locking; concurrent applies fail on the ledger's
  `UNIQUE (name)` and then hit the retry crash. Framework users run migrate-on-startup
  in multi-replica deployments, so this failure mode is theirs, not ours. A shared key
  is required because `keiro-migrate` also applies kiroku's migrations — the two
  executables must serialize against each other on the same database.
  Date: 2026-07-06

- Decision: Resolve the runtime-role grants gap documentation-first (a grants section in
  the ownership guide and READMEs, with copy-paste `GRANT` statements per schema), not
  with `ALTER DEFAULT PRIVILEGES` in the bootstrap migrations.
  Rationale: baking a grant target into framework migrations requires inventing a
  well-known role name for every deployment, which is a bigger design decision than this
  initiative should make unilaterally, and a wrong default silently over-grants.
  Documenting the exact statements (and when to re-run them — after any upgrade that
  adds tables) closes the operational gap now; a first-class grants mechanism can be a
  future initiative if consumers ask.
  Date: 2026-07-06

- Decision: Scope out the PostgreSQL 17 snapshot/CI matrix.
  Rationale: kiroku's bootstrap claims PG 17+ (with the `uuidv7()` fallback) but both
  drift gates only have `v18` snapshots and local ephemeral-pg runs PG 18. A `v17` gate
  needs CI infrastructure for a second PostgreSQL major, which is orthogonal to the
  integrity/apply-path work here. Either add the matrix or drop the 17 claim in a future
  plan; the ownership guide states the tested-version reality plainly.
  Date: 2026-07-06

- Decision: EP-5 (the ownership guide) hard-depends on EP-4.
  Rationale: the guide documents `verify`, `status`, the handshake, and the grants
  convention; publishing it before those exist would document vaporware. The guide's
  structural content (ownership boundary, composition, authoring rules) is stable and
  can be drafted early, but the plan finalizes last.
  Date: 2026-07-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

- 2026-07-06: EP-1 is complete in the kiroku repository. It delivered the reusable
  `Kiroku.Store.Migrations.Guards` module, exported embedded migration names/sources,
  added `migrations.lock` plus `kiroku-store-migrate lock`, wired embed parity,
  checksum, body-lint, codd-ledger canary, and ledger-fixup regression tests, and
  updated kiroku README/CHANGELOG with dual-ledger guidance. Validation in the kiroku
  repository:

  ```text
  cabal build kiroku-store-migrations
  Exit: 0

  cabal test kiroku-store-migrations-test
  11 examples, 0 failures
  ```


## Revision Notes

- 2026-07-06: Updated after EP-1 implementation to mark EP-1 complete, check off its
  aggregate milestones, record the seven-migration count, document the `crypton` and
  `Session.script` implementation discoveries, and capture validation evidence.
