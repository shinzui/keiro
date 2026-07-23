---
id: 19
slug: restore-the-migration-integrity-gates-under-pg-migrate-surfaced-by-the-2026-07-migration-review
title: "Restore the migration integrity gates under pg-migrate surfaced by the 2026-07 migration review"
kind: master-plan
created_at: 2026-07-23T03:02:16Z
intention: intention_01ky8hzdgxe7etqkgzfma64nj5
---

# Restore the migration integrity gates under pg-migrate surfaced by the 2026-07 migration review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

MasterPlan 13 (July 6) built ten integrity gates around keiro's and kiroku's migration machinery — checksum manifests, embed parity, body lint, ledger uniqueness, canaries, strict CLI dispatch, drift exit codes, retry policy, advisory-lock serialization, and a startup handshake — all designed and verified against codd v0.1.8 as the migration runner. Mid-July the project retired codd for pg-migrate (`pg-migrate ^>=1.1` with `pg-migrate-embed` and `pg-migrate-import-codd`; codd survives only behind the `legacy-codd-tools` cabal flag). The runner swap was never reviewed. The July 2026 migration review audited pg-migrate itself with the same lenses MasterPlan 13 applied to codd, produced a gate-survival table, and adversarially verified the highest-risk operational claim against the actual migration bodies in both repos.

The good news is structural: pg-migrate's core is sound and in several ways strictly stronger than codd — transactional apply commits the migration and its ledger row atomically, applied-status is checksum-keyed rather than filename-keyed, verification fails closed on edits/reorders/gaps, the advisory lock moved into the library, codd's in-memory retry crash class is impossible by construction, and the codd-history import path is double-anchored and fails closed on partial or renamed-schema ledgers. But four gates were lost or weakened in the swap, and one operational trap was confirmed. Lost: live schema-drift verification (`verify` now checks only the ledger, never actual schema objects — MIG-1, the drift half of MasterPlan 13's EP-4 deliverable); the migration body lint for unqualified DDL (MIG-2); and the `missingMigrations` startup handshake (MIG-3) — all now exist only in the flag-gated legacy build. Weakened: keiro's embed module lacks the `RecompilePlugin` pragma kiroku carries, so an incremental build can ship a stale embed that silently omits a new migration (MIG-4), and post-cutover native migrations have no repo-side checksum manifest (MIG-7, accepted-risk candidate). The trap (MIG-5, verified with corrected mechanics): nothing stops `keiro-migrate up` from running against an existing codd-ledgered production database — on current databases it aborts harmlessly at kiroku's 0006 (an accidental tripwire) but poisons the native ledger and blocks the codd import until manual cleanup; on databases whose codd history predates 2026-06-14 the run instead succeeds silently, building an empty parallel `keiro` schema that a subsequently deployed service reads while the real data sits invisible in the `kiroku` schema — a silent operational outage. No data is destroyed in either variant, but with 10-15 services being rewritten onto keiro, each with a production cutover driven by bespoke code (the CLI does not even mount the shipped codd-import subcommand), the operator-error surface is unacceptable.

After this initiative is complete: `keiro-migrate verify` (or a sibling subcommand) again detects live schema drift against the expected schema, in the default build; a future migration with unqualified DDL fails CI, not production; services again have a supported native `missingMigrations` startup handshake; incremental builds cannot ship stale embeds; `keiro-migrate up` refuses to initialize a fresh native ledger over a codd-ledgered database unless explicitly overridden, and the recovery procedure for a poisoned ledger is documented; the codd import is mountable from the CLI so each service's cutover follows one tested path instead of bespoke code; and the cutover runbook includes the sentinel-ledger fixup step with a corrected fixup header.

In scope: the seven findings (MIG-1 through MIG-7), fixes in keiro-migrations and (where the fix belongs upstream) pg-migrate, runbook and guide corrections, and regression tests including an integration test for the preflight guard. Out of scope: codd itself (retired — its bugs are moot, which is why the review's codd findings are not re-litigated here); the kiroku-repo migration packages except where a gate spans both ledgers (the combined-ledger uniqueness gate survived by construction and needs no work); PostgreSQL 17 expected-schema snapshots (pre-existing recorded future work); and any schema-shape change to either package.


## Decomposition Strategy

Three child plans, split by the lifecycle stage each gate protects: continuous verification, build integrity, and the one-time cutover.

EP-1 (plan 122) restores the runtime/CI verification gates: live schema-drift verification in the default toolchain (MIG-1), the body lint re-wired over the embedded migration entries using the still-existing pure guard validators (MIG-2), and a native `missingMigrations` exported from `Keiro.Migrations` built on pg-migrate's `migrationStatusWith` (MIG-3).

EP-2 (plan 123) restores build-time integrity: the one-line `RecompilePlugin` pragma in keiro's embed module (MIG-4) and the decision on native manifest coverage for post-cutover migrations (MIG-7) — either regenerate a native lockfile in CI or record acceptance of runtime checksum-keying as the gate, in the Decision Log and the migration-ownership guide.

EP-3 (plan 124) makes the cutover safe: a preflight on the `up` path that refuses to initialize an empty native ledger when a codd ledger exists in the database (MIG-5), with an explicit override and a documented recovery procedure for both trap variants; mounting a codd-import subcommand in the `keiro-migrate` CLI (built over `frameworkCoddHistoryMappings` — pg-migrate ships the import machinery but no reusable CLI parser, see Surprises & Discoveries); and the runbook corrections (sentinel-fixup step, fixup header comment) (MIG-6).

Alternatives considered. One plan per finding (seven plans) was rejected as far too granular — MIG-4 is one pragma. Two plans (gates vs cutover) was rejected because EP-1 is test-infrastructure-heavy while EP-2 is a build-system change with a policy decision; keeping them separate lets EP-2 land in an afternoon. Doing the preflight in pg-migrate core rather than keiro-migrations is left as an open design choice inside EP-3 (a keiro-side preflight needs no upstream release; an upstream `preApplyCheck` hook would serve kiroku-store-migrations too) — the plan records the tradeoff and decides.

ADR context: `docs/adr/` contains only `0001-keiro-pgmq-job-processing-telemetry-contract.md`, not relevant — no relevant ADR exists for this initiative. Candidate ADRs at completion: the migration gate inventory and which build (default vs legacy flag) enforces each; the cutover preflight policy.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Restore live schema verification, body lint, and the startup handshake under pg-migrate | docs/plans/122-restore-live-schema-verification-body-lint-and-the-startup-handshake-under-pg-migrate.md | None | None | In Progress |
| 2 | Add the embed recompile plugin and native manifest coverage | docs/plans/123-add-the-embed-recompile-plugin-and-native-manifest-coverage.md | None | None | Not Started |
| 3 | Guard up against codd-ledgered databases and mount the codd import in the CLI | docs/plans/124-guard-up-against-codd-ledgered-databases-and-mount-the-codd-import-in-the-cli.md | None | EP-1 | Not Started |


## Dependency Graph

No hard dependencies; all three plans can proceed in parallel.

EP-3 is soft-dependent on EP-1 only for documentation: the cutover runbook it rewrites should reference the restored `verify` drift check as the post-cutover validation step. If EP-1 has not landed, EP-3 references the gate as forthcoming and EP-1 completes the reference.


## Integration Points

`keiro-migrations/app/Main.hs` (the CLI): EP-1 may add or extend a verification subcommand; EP-3 adds the codd-import subcommand and the preflight to `up`. Both extend the same optparse parser — additive subcommands, coordinate only on merge order. EP-3 owns the `up` path changes exclusively.

`docs/user/migrations.md`, `docs/user/migration-ownership.md`, `docs/user/upgrading-to-the-keiro-schema.md`: EP-1 documents the restored verify and handshake; EP-2 updates migration-ownership's manifest-coverage statement; EP-3 rewrites the cutover sequence in upgrading-to-the-keiro-schema. Sections are disjoint; each plan names the exact sections it owns.

pg-migrate (repository `/Users/shinzui/Keikaku/bokuno/pg-migrate`): only EP-3 may need an upstream change (the preflight hook, if the plan decides against a keiro-side implementation); EP-1 consumes existing public API (`migrationStatusWith`) and must not require an upstream release. If EP-3 does change pg-migrate, it states the new version bound for all three keiro-migrations consumers of the family (`pg-migrate`, `pg-migrate-embed`, `pg-migrate-import-codd`).

Cross-plan decision for ADR promotion: the gate-survival table from the review (which MasterPlan 13 gate is enforced where under pg-migrate) becomes the ADR's core content once EP-1/EP-2 settle each gate's new home.


## Progress

- [ ] EP-1: Live schema-drift verification restored in the default build; drifted-database test exits nonzero naming the drifted objects.
- [ ] EP-1: Body lint runs over embedded entries in the default test suite; an unqualified fixture migration fails it.
- [ ] EP-1: Native `missingMigrations` exported and documented; fresh-database handshake test returns the full embedded list.
- [ ] EP-2: `RecompilePlugin` pragma added; stale-embed reproduction documented or test-pinned.
- [ ] EP-2: Native manifest coverage decision recorded and implemented (lockfile in CI or documented acceptance).
- [ ] EP-3: `up` preflight refuses codd-ledgered databases without override; both trap variants covered by integration tests.
- [ ] EP-3: codd-import subcommand mounted in keiro-migrate; cutover runbook corrected (sentinel fixup step, fixup header, recovery procedure).


## Surprises & Discoveries

- Plan authoring (2026-07-23), affects EP-1: the pure lint validators no longer live in kiroku — `Kiroku.Store.Migrations.Guards` was reduced to a re-export shim of `Codd.Extras.Guards` and then deleted (kiroku `15e6fe2`, 2026-07-10). The real source is `/Users/shinzui/Keikaku/bokuno/codd-extras/src/Codd/Extras/Guards.hs`, whose library depends on codd; EP-1 (docs/plans/122) copies the pure functions rather than adding a codd-family dependency to the default build.
- Plan authoring (2026-07-23), affects EP-2: `migrations.lock` cannot be extended to cover native migrations — it is embedded as codd-import evidence (`keiroCoddManifestText`) and the strict import fails on unexpected entries. This forces the separate `migrations.native.lock` design; recorded as the deciding rationale in docs/plans/123.
- Plan authoring (2026-07-23), affects EP-1: the checked-in `expected-schema/v18` snapshot predates migration `0018` (no `keiro_dead_letters` in it) — it is a valid legacy-world artifact but stale as a native gate; EP-1 freezes it and adds a new native snapshot.
- Plan authoring (2026-07-23), affects EP-3: the sentinel ledger fixup remaps 14 rows, not 16 (two legacy files never had sentinel names); pg-migrate ships no reusable codd-import CLI parser (`--mapping` is application-interpreted), so EP-3 (docs/plans/124) builds a keiro-shaped `import-codd-history` subcommand over `frameworkCoddHistoryMappings` instead of mounting a shipped parser; and the preflight is implemented keiro-side pre-lock with the TOCTOU accepted (the guarded hazard is operator error, not a concurrent race — `Database.PostgreSQL.Migrate.Runner`'s in-lock surface is not exposed).
- EP-1 implementation (2026-07-23), affects all child plans: migrations `0019-keiro-snapshots-state-shape-hash.sql` and `0020-keiro-workflow-children-failure-reason.sql` landed after plan authoring. The current native component contains 20 Keiro migrations and the composed plan contains 28 entries, so EP-1 now gates all 20 bodies and all 28 startup-handshake entries. EP-2 must generate native manifest coverage for 20 files, and EP-3 must treat the two new native migrations as pending after a 23-row codd history import.


## Decision Log

- Decision: Decompose by lifecycle stage (continuous verification, build integrity, cutover) into three plans.
  Rationale: Matches who consumes each gate (CI, build system, cutover operator); disjoint acceptance; parallelizable.
  Date: 2026-07-23

- Decision: codd findings from MasterPlan 13's era are moot; this initiative targets only what the pg-migrate swap lost plus the cutover trap.
  Rationale: The user retired codd for pg-migrate precisely to address codd's defects; re-fixing codd-era issues would be wasted motion.
  Date: 2026-07-23

- Decision: Record the review's verified-sound results (transactional apply atomicity, checksum keying, fail-closed verification, advisory lock, import double-anchoring) as regression-protected ground truth.
  Rationale: The restored gates must not duplicate what pg-migrate already enforces; child plans build on, not around, the library's guarantees.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)
