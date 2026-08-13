---
id: 248
slug: give-pre-canonical-in-flight-rebuild-runs-a-supported-recovery-path
title: "Give pre-canonical in-flight rebuild runs a supported recovery path"
kind: exec-plan
created_at: 2026-08-12T23:55:34Z
intention: "intention_01kzw6dk7qe1qayx2qdz6vcqfd"
master_plan: "docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md"
---

# Give pre-canonical in-flight rebuild runs a supported recovery path

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today, a database that upgrades across migration `keiro-migrations/migrations/0024.sql`
while a catalog rebuild is in flight becomes permanently stuck: the whole projection
catalog refuses to register at every application startup, the interrupted rebuild can be
neither resumed nor abandoned, adoption refuses the group, and no fresh rebuild can ever
begin. The only way out is hand-written SQL against Keiro-owned tables, which
[ADR 28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
forbids. Worse, even an operator who follows the documented precondition — "abandon
active rebuilds before upgrading" — lands in the same trap, because an abandoned group is
`failed` and a `failed` group can never be adopted or given a fresh rebuild through any
supported API.

After this plan, an operator whose database was caught mid-rebuild by the upgrade
recovers entirely through supported commands, in this order:

```console
yourapp ops rebuild abandon OLD_RUN --code CODE --detail TEXT --force   # discard the stranded run; group stays fenced
yourapp ops rebuild adopt GROUP --force                                 # stamp the canonical slice; group stays fenced
yourapp ops rebuild start GROUP --run-id NEW_RUN ... --force            # fresh canonical rebuild; promotion returns the group to live
```

Concretely, someone can observe: `rebuild status OLD_RUN` and the non-forced `abandon`
preview render the stranded run (including its `$pre-canonical` marker) instead of
failing; forced `abandon` succeeds and records evidence; forced `adopt` accepts the
fenced group and stamps the canonical fingerprint; application startup registration
succeeds again; a fresh `rebuild start` replays, verifies, and promotes; and the group
and its query models return to live service. A new database-backed test proves the whole
sequence end to end, and a migration-level test pins the exact database shape that
`0024.sql` leaves behind.

This plan is EP-3 of MasterPlan 39
(`docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md`)
and gates the 0.12.0.0 release: 0.12 is the first stable release, and
[ADR 32](../adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md)
explicitly promised that "pre-canonical persisted values also need a supported
clean-break recovery path before the unreleased 0.12 format becomes stable". This plan
delivers that path.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-13 03:34Z) M1: keiro-migrations test pinning the exact post-0024 shape of a mid-rebuild database (passes immediately).
- [x] (2026-08-13 03:34Z) M1: new `keiro/test/PreCanonicalRecoverySpec.hs` reproducing every refusal and asserting the full recovery sequence (red), registered in `keiro/keiro.cabal` and `keiro/test/Main.hs`; committed failing.
- [x] (2026-08-13 03:37Z) M2: `preCanonicalRunSliceSentinel` and `canonicalSlicePrefix` constants in `Keiro.ReadModel.Rebuild.Group`, exported through the facade where needed.
- [x] (2026-08-13 03:37Z) M2: sentinel-aware `abandonCatalogRebuild` (new `abandonPreCanonicalGroupRebuild` + statement in Group.hs; sentinel branch in Runner.hs).
- [x] (2026-08-13 03:37Z) M2: `CatalogRebuildRunPreCanonical` constructor; `resumeCatalogRebuild` refuses sentinel runs with it; abandon/resume test stages green.
- [x] (2026-08-13 03:44Z) M3: adoption accepts fenced stale-format groups (`adoptTx` lock precondition); begin accepts `failed` groups (`beginGroupRebuild` status guard); full recovery spec green.
- [x] (2026-08-13 03:44Z) M3: amend `docs/adr/0032` and `docs/adr/0026` in the same change; `okf log add` entries; `okf validate` passes.
- [x] (2026-08-13 03:48Z) M4: sentinel-aware `Operations.inspectGroupRebuild`; `group_slice` column in keiro-ops run tables; keiro-ops recovery transcript test green.
- [ ] M5: user docs (`docs/user/read-models-and-projections.md`, `docs/user/operations.md`), changelogs (`keiro/CHANGELOG.md`, `keiro-ops/CHANGELOG.md` Unreleased), full `just verify` gate.
- [ ] MasterPlan 39 registry row for EP-3 updated to Complete; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The migration-level fixture applied the real 0024 ledger entry after two pre-0024 run
  shapes and passed with both `group_slice_fingerprint` values equal to
  `'$pre-canonical'` (`cabal test keiro-migrations-test`: 29 examples, 0 failures).
  The runtime recovery spec is red at the intended first missing contract: compilation
  stops because `CatalogRebuildRunPreCanonical` does not exist yet. This makes M2's typed
  refusal part of the executable definition rather than accepting the old contract
  mismatch accidentally.
- The M2 targeted run reached exactly the planned boundary: the running-run abandon and
  replaced-active-run refusal examples pass, the main recovery example advances through
  typed resume refusal and idempotent abandon, then fails at the first M3 operation with
  `AdoptGroupNotLive ... GroupFailed`. This proves the sentinel path does not depend on
  the catalog slice or resume contract while leaving adoption closed until M3.
- M3 needed no registration special case and no SQL mutation beyond the M2 abandon
  statement. Adoption's existing metadata update preserves the failed fence, and begin's
  existing statement clears failure evidence before preparing the new run. The full
  `keiro-test` suite passed (535 examples, 0 failures), and strict ADR validation passed
  with 33 concepts.
- The operator-neutral sentinel inspection branch must precede catalog membership as well
  as slice comparison: the run itself carries all evidence needed for status and abandon
  preview. The end-to-end human-table transcript passed, followed by the complete
  `keiro-ops-test` suite (39 examples, 0 failures).


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship recovery as sentinel-aware extensions of the existing lifecycle
  operations (`abandonCatalogRebuild`, `adoptCatalogGroups`, `beginGroupRebuild`) rather
  than a new dedicated recovery command.
  Rationale: abandon already means "discard this run and keep the group fenced for a
  fresh rebuild"; adoption already means "accept reviewed slice metadata"; start already
  means "begin a fresh fenced replay". Teaching each to handle the one extra state keeps
  a single vocabulary of operations, reuses the existing preview-then-`--force` keiro-ops
  ergonomics without any new parser surface, and avoids inventing a second sentinel or a
  second lifecycle path — MasterPlan 39's Integration Points require that this plan
  "must not invent a second sentinel" and define `'$pre-canonical'` handling exactly once.
  Date: 2026-08-12
- Decision: `0024.sql` stays byte-identical; no new refusal or warning migration; runtime
  recovery is the supported path. The "abandon before upgrading" precondition becomes a
  recommendation with the recovery runbook as its safety net.
  Rationale: (1) a migration-time `RAISE EXCEPTION` on active runs would strand the
  upgrade mid-ledger after the old binary is already replaced — a strictly worse trap
  than the one being fixed; (2) `keiro-migrations/README.md` forbids editing a shipped
  migration, and 0024 has been applied by master-line databases even though no Hackage
  release contains it; (3) once recovery exists, the post-upgrade state is loud (typed
  `RegisteredGroupStaleFingerprint` at every startup) and fully recoverable, so
  migration-time enforcement adds no safety.
  Date: 2026-08-12
- Decision: `beginGroupRebuild` accepts groups in `failed` status (in addition to
  `live`), still refusing `rebuilding` and unknown statuses, and still requiring the
  stored slice to match the catalog slice first.
  Rationale: a fresh rebuild is the documented remediation for a failed group, yet the
  status guard has refused non-live groups since commit `8a670c10`, making abandonment a
  one-way door for every catalog group — canonical or pre-canonical. The recovery path
  requires this transition anyway (an abandoned pre-canonical group must be able to start
  its fresh canonical rebuild), and begin's own preparation re-fences, truncates, and
  resets state, so starting from `failed` is exactly as safe as starting from `live`.
  The slice-drift check stays ahead of the status check, so a stale-slice failed group is
  told to adopt first. Amends ADR-26's lifecycle wording (`failed -> rebuilding` via an
  explicitly requested fresh run).
  Date: 2026-08-12
- Decision: Adoption accepts a group that is `failed` and whose stored fingerprint lacks
  the canonical `slice-v2:` prefix (stale-format), preserving its status, active-run
  evidence, and fence; every other non-live group is still refused with
  `AdoptGroupNotLive`.
  Rationale: a stale-format `failed` group can only be a stranded pre-canonical (or
  pre-slice-v2) group — canonical-era code writes only `slice-v2:` values — so the
  relaxation is exactly as wide as the trap. Adoption while `rebuilding` stays refused so
  a live run must first be abandoned; adoption of a canonical `failed` group stays
  refused because its stored slice is not evidence of a format break. Adoption still
  changes metadata only: returning the group to `live` here would un-fence half-replayed
  application data, so the fence is preserved until a fresh rebuild promotes.
  Date: 2026-08-12
- Decision: `resumeCatalogRebuild` refuses sentinel runs with a new typed
  `CatalogRebuildRunPreCanonical` error (never a contract comparison), and
  `Operations.inspectGroupRebuild` returns the report for sentinel runs instead of
  `CatalogOpsRunSliceMismatch`, before and without consulting the current catalog slice.
  Rationale: the sentinel proves the run predates the canonical contract; comparing it to
  anything is meaningless and today's accidental `CatalogRebuildContractMismatch` /
  `CatalogOpsRunSliceMismatch` errors break the keiro-ops `status` command and the
  non-forced `abandon` preview — the exact surfaces an operator needs during recovery.
  The sentinel check also precedes catalog-membership lookups so runs of groups that were
  renamed out of the catalog remain inspectable and abandonable.
  Date: 2026-08-12
- Decision: keiro-ops run tables (`status`, `resume`, `abandon`, `start` outputs) gain a
  `group_slice` column rendering the run's stored `group_slice_fingerprint`.
  Rationale: the operator must be able to see `$pre-canonical` in the preview that the
  two-phase force policy shows before mutation; the JSON envelope already carries the
  value, only the human table hides it. EP-4 (plan 249) owns the adoption preview/result
  tables and reconciles if it lands second; this column touches only the run report
  table.
  Date: 2026-08-12
- Decision: Recovery never computes or compares a resume contract for sentinel runs, so
  EP-2's pending `contract-v4:` bump (plan 247, soft dependency) cannot change recovery
  semantics; fixtures deliberately pin historical `contract-v2:` /
  `keiro/projection-replay/v2` values.
  Rationale: writing recovery against the final contract encoding, as MasterPlan 39
  sequencing requires, is achieved by not depending on the encoding at all.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Everything here can be verified in the working tree; no other plan needs to be read.

### The catalog rebuild subsystem in one page

A "projection catalog" is an application's single validated declaration of its read-model
world: event sources, target tables, projections, query models, and "rebuild groups" —
named sets of targets that are rebuilt together and act as one durable fence. The
runtime state lives in Keiro-owned PostgreSQL tables in the `keiro` schema:

- `keiro.keiro_projection_rebuild_groups` — one row per group: `group_id`,
  `slice_fingerprint` (the group's identity hash), `status` (`live`, `rebuilding`,
  `failed`), `active_run_id`, request/failure evidence columns. Created by
  `keiro-migrations/migrations/0022.sql` (there the identity column was still named
  `catalog_fingerprint`).
- `keiro.keiro_projection_rebuild_runs` — one row per rebuild attempt: `run_id`,
  `group_id`, `catalog_fingerprint` (whole-catalog provenance), `group_slice_fingerprint`
  (the slice the run was begun under), `contract_fingerprint` (the resume-compatibility
  hash), `runner_format`, `captured_head`, `status` (`running`, `failed`, `verified`,
  `promoted`), failure evidence. Created by `0023.sql`; the `group_slice_fingerprint`
  column was added by `0024.sql`.
- `keiro.keiro_projection_rebuild_sources` / `_adapters` / `_verifications` — durable
  replay progress per run.
- `keiro.keiro_read_models` — query-model registrations bound to groups.

The code lives in three layers. `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` owns group
lifecycle: `registerProjectionCatalog` (startup registration), `previewCatalogAdoption` /
`adoptCatalogGroups` (explicit metadata evolution), `beginGroupRebuild` (fence + prepare),
`finishGroupRebuild` / `abandonGroupRebuild` (promote / record failure and keep the
fence). `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` owns the replay runner:
`startCatalogRebuild`, `resumeCatalogRebuild`, `inspectCatalogRebuild`,
`abandonCatalogRebuild`, plus the persisted run statements. Both are re-exported through
the public facade `keiro/src/Keiro/ReadModel/Rebuild.hs`.
`keiro/src/Keiro/Projection/Catalog/Operations.hs` is the operator-neutral adapter
(`ProjectionCatalogOperations`) that `keiro-ops/src/Keiro/Ops/Rebuild.hs` wraps as the
embedded `rebuild list|preview|start|status|resume|abandon|adopt` commands, each mutation
using the two-phase policy from ADR-28: without `--force` render a preview and the exact
force invocation; with `--force` call the supported library mutation.

A "slice fingerprint" (`slice-v2:`-prefixed SHA-256 text) is the canonical identity of
one group's catalog slice; a "contract fingerprint" (`contract-v3:`-prefixed, computed by
`rebuildContract` in Runner.hs around line 826 from the slice plus the runner format
`keiro/projection-replay/v3`) fences resume compatibility for one run. Both formats are
defined by
[ADR 32](../adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md).

### What 0024 does and the sentinel it leaves behind

`keiro-migrations/migrations/0024.sql` is the pre-0.12 clean break that moved group
identity from whole-catalog fingerprints to group slices. It does exactly three things:
renames `groups.catalog_fingerprint` to `slice_fingerprint` (the legacy whole-catalog
hash value is kept as-is), adds `runs.group_slice_fingerprint` with default
`'$pre-canonical'` so every pre-existing run row is stamped with that sentinel, then
drops the default. The migration cannot infer an old run's true slice because the
database does not contain the historical catalog (ADR-32, Alternatives considered), so
the sentinel is honest: "this run predates slice identity".

The trap, verified against the current tree (all references re-checked at `HEAD`,
2026-08-12): the sentinel is handled by no code path, and the legacy hash left in
`groups.slice_fingerprint` fails every canonical comparison.

1. Resume and the runner's liveness proofs join on the two columns being equal —
   `groups.slice_fingerprint = runs.group_slice_fingerprint` in `resumeRunStmt`
   (`Runner.hs:1088`), `lockActiveRunStmt` (`Runner.hs:1111`), and `completionProofStmt`
   (`Runner.hs:1238`). Legacy hash ≠ `'$pre-canonical'`, so they can never match.
2. Before those statements even run, `resumeCatalogRebuild` (`Runner.hs:279-280`) and
   `abandonCatalogRebuild` (`Runner.hs:333-334`) compare the stored
   `contract_fingerprint` with the freshly computed `contract-v3:` value and refuse with
   `CatalogRebuildContractMismatch`. A pre-canonical run stores an old-format contract
   (`contract-v2:`-era text under `keiro/projection-replay/v2`), so both operations
   always refuse. Even if the contract matched, abandon's `abandonGroupStmt`
   (`Group.hs:795-820`) additionally requires `slice_fingerprint = <current catalog
   slice>` and `status = 'rebuilding'` on the group row — the legacy hash fails that too.
3. Adoption (`adoptCatalogGroups`, `Group.hs:382-439`) locks each requested group and
   refuses any whose status is not `GroupLive` with `AdoptGroupNotLive`
   (`Group.hs:429-438`). There is no force bypass; the keiro-ops `--force` flag only
   selects the mutation phase, it does not relax library preconditions.
4. Startup registration (`registerProjectionCatalogTx`, `Group.hs:262-300`) compares each
   catalog group's stored fingerprint with the current slice; a stored value without the
   `slice-v2:` prefix produces `RegisteredGroupStaleFingerprint` (`Group.hs:293-295`) and
   `Tx.condemn` rolls back the whole registration — the entire catalog is refused at
   every startup until the group is adopted, and adoption is refused by (3).
5. A fresh rebuild cannot begin either: `beginGroupRebuild` (`Group.hs:458-526`) refuses
   any group whose status is not `GroupLive` (`RebuildGroupNotLive`) and any stored slice
   differing from the catalog slice (`RebuildGroupSliceDrift`).

Consequently a group that is `rebuilding` or `failed` when 0024 runs is unreachable by
resume, abandon, adopt, register, and start — every supported API. The documented
precondition ("Before crossing an identity or runner format boundary, complete or
explicitly abandon every active catalog rebuild",
`docs/user/read-models-and-projections.md` around line 276) is enforced nowhere, and
following it does not even help: abandoning with the old binary leaves the group `failed`
with the legacy hash, which after upgrade still fails (3), (4), and (5).

A related pre-existing gap discovered while verifying (5): `beginGroupRebuild` has
required `GroupLive` since the subsystem's first commit (`8a670c10`), so even a fully
canonical group that an operator abandons can never begin a fresh rebuild.
[ADR 26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
describes the lifecycle as `live -> rebuilding -> live` or `live -> rebuilding ->
failed` and says a failed rebuild is "an offline state, not an automatic rollback" that
operators repair — but only run-level `resume` exists; group-level `failed` is a dead
end. This plan closes that gap because the recovery path requires the `failed ->
rebuilding` transition anyway.

Two states are explicitly out of scope: legacy unmanaged singleton groups
(`'$legacy-read-model:...'` ids with the `'$legacy-unmanaged'` fingerprint, created by
`0022.sql` for the pre-catalog compatibility path) are not catalog groups and are not
touched; and a group row whose id is absent from the current catalog never blocks
registration (registration iterates catalog groups only) — after abandoning its stranded
run it simply lingers as a `removed` row in the adoption preview, which EP-4
(`docs/plans/249-make-catalog-adoption-scoped-truthful-and-registry-complete.md`) owns.

### Relevant ADRs

- [ADR 32](../adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md)
  — canonical preimages, `slice-v2:`/`contract-v3:` prefixes, explicit preview-then-adopt
  evolution, and the 0024 clean break. It promises the recovery path this plan builds and
  is amended by this plan (sentinel semantics, adoption precondition, `failed ->
  rebuilding`).
- [ADR 28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  — every operator command wraps an exported library operation; destructive commands are
  two-phase (preview, then `--force`). The recovery path must therefore land as library
  behavior surfaced through the existing keiro-ops commands, never as documented SQL.
- [ADR 26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
  — group lifecycle and fencing; amended by this plan to add the `failed -> rebuilding`
  transition via an explicitly requested fresh run.
- [ADR 31](../adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md)
  — checkpoint policy as slice identity; read for background, not amended.

No cross-repository ADR bears on this plan.

### Sibling plans (coordination context, not required reading)

EP-2 (`docs/plans/247-capture-replay-adapter-application-order-in-the-rebuild-resume-contract.md`)
will bump the resume-contract prefix; this plan's recovery never computes a contract for
sentinel runs, so the two do not interact semantically — if EP-2 lands first, only test
baselines rebase. EP-4 (`docs/plans/249-make-catalog-adoption-scoped-truthful-and-registry-complete.md`)
will reshape the adoption preview/result types and fix the adoption transaction's
UPDATE-only silent no-op; this plan deliberately keeps `CatalogAdoptionPlan`,
`GroupAdoptionClass`, and `AdoptGroupNotLive` shapes unchanged and confines itself to the
lock precondition, so whichever plan lands second reconciles rendering only.


## Plan of Work

The work is five milestones: reproduce the trap with committed red tests; make abandon
and resume sentinel-aware; open adoption and fresh-start for the fenced group and amend
the ADRs; make the operator surface truthful; document, changelog, and gate.

### Milestone 1 — Reproduce the trap (red tests committed first)

Scope: two database-backed tests. First, a migration-level test in
`keiro-migrations/test/Main.hs` that runs the real ledger up to `0023`, seeds a
mid-rebuild database, applies `0024`, and pins the exact shape it leaves — this test
passes immediately and is the ground truth for the runtime fixture. Second, a new keiro
test module `keiro/test/PreCanonicalRecoverySpec.hs` that seeds that exact shape through
supported APIs plus row doctoring, proves every refusal, and asserts the full recovery
sequence — red today, green at the end of Milestone 3.

For the migration test, follow the existing prior-plan pattern of "upgrades singleton
read-model rows into deterministic rebuild groups" (`keiro-migrations/test/Main.hs:290`):
build a truncated component with
`take 23 (toList embeddedMigrationEntries)` (through `0023`), apply it with the kiroku
component, seed with a fixture script, then apply the full plan and assert the last
outcome is `AppliedNow` (`Prelude.drop 31 (reportOutcomes report) shouldBe [AppliedNow]`
— 8 kiroku + 23 keiro = 31 already applied). The fixture seeds both trap states under the
pre-0024 schema (note the group identity column is still `catalog_fingerprint` there, and
runs have no `group_slice_fingerprint`):

```sql
INSERT INTO keiro.keiro_projection_rebuild_groups
  (group_id, catalog_fingerprint, status, active_run_id, requested_by, request_reason, started_at)
VALUES
  ('upgrade-rebuilding', repeat('a', 64), 'rebuilding', 'upgrade-run-live', 'ops', 'mid-rebuild upgrade fixture', now()),
  ('upgrade-failed', repeat('b', 64), 'failed', 'upgrade-run-failed', 'ops', 'abandoned before upgrade', now());
UPDATE keiro.keiro_projection_rebuild_groups
  SET failed_at = now(), failure_code = 'operator.abandoned', failure_detail = 'abandoned with the old binary'
  WHERE group_id = 'upgrade-failed';
INSERT INTO keiro.keiro_projection_rebuild_runs
  (run_id, group_id, catalog_fingerprint, contract_fingerprint, runner_format, captured_head, page_size, status)
VALUES
  ('upgrade-run-live', 'upgrade-rebuilding', repeat('a', 64), 'contract-v2:' || repeat('c', 64), 'keiro/projection-replay/v2', 6, 100, 'running');
INSERT INTO keiro.keiro_projection_rebuild_runs
  (run_id, group_id, catalog_fingerprint, contract_fingerprint, runner_format, captured_head, page_size, status, failed_at, failure_code, failure_detail)
VALUES
  ('upgrade-run-failed', 'upgrade-failed', repeat('b', 64), 'contract-v2:' || repeat('d', 64), 'keiro/projection-replay/v2', 6, 100, 'failed', now(), 'operator.abandoned', 'abandoned with the old binary');
```

After the full plan applies, assert with one query per table that
`groups.slice_fingerprint` still holds the legacy values (`repeat('a',64)` /
`repeat('b',64)`) and both runs' `group_slice_fingerprint` equals `'$pre-canonical'`.
This test needs no code change to pass; its value is that it makes the runtime fixture
below un-arguable and will fail loudly if anyone later edits 0024's semantics.

For the runtime spec, create `keiro/test/PreCanonicalRecoverySpec.hs` modeled on
`keiro/test/CatalogOperationsSpec.hs` (same imports, `withFreshStore fixture`, the
`CatalogSpec qualified as Catalog` fixtures, local copies of `operationsFixtureSql`, the
`options`/`runId`/`expectValid`/`expectStore`/`shouldBeRight` helpers — specs in this
suite are self-contained by convention). Register the module in `keiro/keiro.cabal`
under `test-suite keiro-test` `other-modules` (alphabetical: between `GroupRebuildSpec`
and `PreimageSpec`) and call `PreCanonicalRecoverySpec.spec fixture` from
`keiro/test/Main.hs` beside the other catalog specs (around line 395).
Database-backed suites use the suite-level template-database fixture from
`keiro-test-support` (`Keiro.Test.Postgres.withMigratedSuite` already wraps the whole
keiro suite; each example gets a fresh copy via `withFreshStore`); never add per-example
migrations.

The spec's main scenario, "recovers a group stranded mid-rebuild by migration 0024":

1. Seed `operationsFixtureSql`, validate `operationsCatalog failingVerification` (the
   CatalogOperationsSpec catalog whose verification hook fails), register it, and run
   `startCatalogRebuild` with run id `recovery-run`. This produces the honest mid-rebuild
   state: group `rebuilding` with `active_run_id = 'recovery-run'`, run `failed` with
   real source/adapter/verification rows.
2. Doctor the rows to the exact post-0024 shape proven by the migration test:

   ```sql
   UPDATE keiro.keiro_projection_rebuild_runs
   SET group_slice_fingerprint = '$pre-canonical',
       contract_fingerprint = 'contract-v2:' || repeat('c', 64),
       runner_format = 'keiro/projection-replay/v2'
   WHERE run_id = 'recovery-run';
   UPDATE keiro.keiro_projection_rebuild_groups
   SET slice_fingerprint = repeat('a', 64)
   WHERE group_id = 'counter-group';
   ```

   (Use `rebuildGroupIdText Catalog.mainGroupId` for the group id parameter rather than a
   literal; the statements take text parameters like `setStoredSliceStmt` in
   `keiro/test/CatalogEvolutionSpec.hs:224`.)
3. Prove the refusals with the healthy catalog `operationsCatalog passingVerification`:
   - `registerProjectionCatalog` returns
     `Left (RegisteredGroupStaleFingerprint Catalog.mainGroupId legacyHash)`;
   - `resumeCatalogRebuild` returns `Left (CatalogRebuildRunPreCanonical (runId
     "recovery-run") Catalog.mainGroupId)` (before Milestone 2 this assertion is red — it
     currently returns `CatalogRebuildContractMismatch`);
   - `adoptCatalogGroups` on the still-`rebuilding` group returns
     `Left (AdoptGroupNotLive Catalog.mainGroupId GroupRebuilding (Just (runId
     "recovery-run")))` — this stays true after the fix;
   - `startCatalogRebuild` with a new run id returns `Left (CatalogRebuildStartFailed
     (RebuildGroupSliceDrift ...))`.
4. Run the recovery sequence and assert each step (all red before Milestones 2-3):
   - `abandonCatalogRebuild catalog (runId "recovery-run") (RebuildFailure
     "operator.pre-canonical" "discard run stranded by the 0024 upgrade")` returns
     `Right report` with `runStatus = RebuildRunFailed`; `lookupProjectionRebuildGroup`
     shows `GroupFailed` with the failure code, and a second identical abandon also
     returns `Right` without replacing the group evidence (idempotent);
   - `adoptCatalogGroups catalog (Catalog.mainGroupId :| [])` returns `Right` metadata
     whose `sliceFingerprint` is the current canonical slice and whose `status` is still
     `GroupFailed` (fence preserved);
   - `registerProjectionCatalog` now returns `Right`;
   - `startCatalogRebuild` with run id `recovery-fresh` and the passing catalog returns
     `Right` with `runStatus = RebuildRunPromoted`; the group is `GroupLive` and
     `lookupReadModel` shows the bound query model live again.

Add one focused sibling example, "abandons a pre-canonical run whose process died while
running": same seeding, but additionally doctor the run back to `status = 'running'`
(clear `failed_at`/`failure_code`/`failure_detail` to satisfy the run-status check
constraint) and assert the sentinel abandon still succeeds. And one negative example,
"never abandons a pre-canonical run that is no longer the group's active run": doctor a
promoted-run copy or point `active_run_id` elsewhere and assert
`Left (CatalogRebuildAbandonFailed (RebuildHandleNoLongerActive ...))`.

Acceptance for M1: `cabal test keiro-migrations-test` passes including the new pin test;
`cabal test keiro-test` fails with exactly the new spec's recovery-stage assertions
(refusal-stage assertions that describe post-fix behavior, like
`CatalogRebuildRunPreCanonical`, are also red). Commit the red spec together with the M1
migration test; the failing examples are the executable definition of done for M2-M3.

### Milestone 2 — Sentinel-aware abandon and resume (library)

Scope: `Keiro.ReadModel.Rebuild.Group` and `Keiro.ReadModel.Rebuild.Runner`. At the end,
the abandon and resume stages of the recovery spec pass; adoption/registration/fresh-start
stages remain red.

In `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`:

- Add two documented constants near the top-level statement section and export them from
  the module:

  ```haskell
  -- | Sentinel that migration 0024 stamps into
  -- @keiro_projection_rebuild_runs.group_slice_fingerprint@ for runs begun
  -- before canonical slice identity existed. Handled only by the recovery
  -- paths: always abandonable, never resumable, never a valid identity.
  preCanonicalRunSliceSentinel :: Text
  preCanonicalRunSliceSentinel = "$pre-canonical"

  -- | Prefix of the current canonical group-slice format (ADR-32).
  canonicalSlicePrefix :: Text
  canonicalSlicePrefix = "slice-v2:"
  ```

  Replace the two existing `"slice-v2:"` literals (`registerGroups` around line 293 and
  `adoptionClass` around line 377) with `canonicalSlicePrefix`.
- Add `abandonPreCanonicalGroupRebuild` beside `abandonGroupRebuild`. It is the
  slice-independent group transition for stranded runs; it takes no handle because a
  handle requires the group to exist in the current catalog, which recovery must not
  assume:

  ```haskell
  abandonPreCanonicalGroupRebuild ::
    (Store :> es) =>
    RebuildGroupId ->
    RebuildRunId ->
    RebuildFailure ->
    Eff es (Either GroupTransitionError GroupRebuildMetadata)
  ```

  Implementation: one transaction that locks the group row with
  `lockGroupForUpdateStmt`; if the row is missing or `active_run_id /= Just runId`,
  `Tx.condemn` and return `Left (RebuildHandleNoLongerActive groupId runId)`. If the
  status is `GroupRebuilding`, run a new `abandonPreCanonicalGroupStmt` — identical to
  `abandonGroupStmt` but without the `slice_fingerprint = $3` predicate (parameters:
  group id, run id, failure code, failure detail; still guarded by `status =
  'rebuilding'` and `active_run_id = $2`) — then `markGroupQueriesAbandonedStmt`, and
  return the metadata. If the status is already `GroupFailed` (the operator abandoned
  before upgrading), return `Right metadata` without touching the row, so recovery is
  idempotent and never replaces original evidence. Export the function from the module;
  it does not need to appear in the public facade because callers go through
  `abandonCatalogRebuild`.

In `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`:

- Add the constructor `CatalogRebuildRunPreCanonical !RebuildRunId !RebuildGroupId` to
  `CatalogRebuildError` with a Haddock line saying the run predates canonical slice
  identity and must be recovered via abandon → adopt → fresh start.
- In `resumeCatalogRebuild`, immediately after the `Just report` bind (before
  `rebuildContract` is consulted, so runs of groups renamed out of the catalog are still
  answered truthfully), add:

  ```haskell
  | report ^. #groupSliceFingerprint == preCanonicalRunSliceSentinel ->
      pure (Left (CatalogRebuildRunPreCanonical runId (report ^. #rebuildGroupId)))
  ```

- In `abandonCatalogRebuild`, add the sentinel branch in the same position: when the
  report carries the sentinel and `runStatus` is `RebuildRunRunning` or
  `RebuildRunFailed`, call `abandonPreCanonicalGroupRebuild`, map `Left` to
  `CatalogRebuildAbandonFailed`, on `Right` call `recordFailure` with the operator's
  code/detail (as the canonical path does) and return `inspectCatalogRebuild runId`. When
  the sentinel run is terminal (`verified`/`promoted`), return
  `Left (CatalogRebuildRunNotActive runId)` — a terminal run is provenance, not a fence,
  and its group is already `live`. Import `preCanonicalRunSliceSentinel` and
  `abandonPreCanonicalGroupRebuild` from the Group module (extend the existing import
  list at `Runner.hs:64-77`).
- Export `preCanonicalRunSliceSentinel` from the facade
  `keiro/src/Keiro/ReadModel/Rebuild.hs` (add to the "Catalog rebuild groups" export
  group) so tests and applications can name the sentinel without retyping the literal.

Acceptance for M2: `cabal build all` clean; in `cabal test keiro-test` the recovery
spec's abandon examples and the resume-refusal assertion pass; the adoption,
registration, and fresh-start assertions still fail; every pre-existing spec
(`GroupRebuildSpec`, `ProjectionReplaySpec`, `CatalogEvolutionSpec`,
`CatalogOperationsSpec`) still passes — in particular ProjectionReplaySpec's "refuses to
resume an active v2 replay contract" example still passes because its doctored run keeps
a real slice value, not the sentinel.

### Milestone 3 — Adoption, registration, and the fresh rebuild; ADR amendments

Scope: the two lifecycle preconditions in `Group.hs`, making the whole recovery spec
green, plus the ADR amendments that must land in the same change as the contract they
alter.

In `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`:

- `adoptCatalogGroups`, inner `lockAll` (around lines 423-439): replace the single
  `status /= GroupLive` refusal with an explicit adoptability predicate — a group is
  adoptable when `status == GroupLive`, or when `status == GroupFailed` and its stored
  `sliceFingerprint` does not start with `canonicalSlicePrefix`. Everything else
  (including `GroupRebuilding` and canonical `GroupFailed`) still returns
  `AdoptGroupNotLive groupId status activeRunId` and condemns. No other change: the
  update statements already preserve `status`, `active_run_id`, and failure evidence, so
  an adopted stranded group stays fenced.
- `beginGroupRebuild` (around lines 484-491): change the status guard to refuse only
  when the status is neither `GroupLive` nor `GroupFailed` (i.e. `GroupRebuilding` and
  `UnknownGroupStatus` keep refusing with `RebuildGroupNotLive`). Keep the guard order:
  the slice-drift check stays first, so a stale-slice failed group is refused with
  `RebuildGroupSliceDrift` until adopted. `beginGroupStmt` already overwrites
  `active_run_id`, clears failure evidence, and re-fences, so no SQL change is needed.

Registration needs no change: after adoption the stored slice is canonical, so
`registerProjectionCatalog` passes; before adoption it keeps refusing with
`RegisteredGroupStaleFingerprint`, which is the intended loud "recover me" signal.

Add regression coverage beyond the recovery spec:

- In `keiro/test/CatalogEvolutionSpec.hs`, extend the non-live refusal example (or add a
  sibling) to prove that a **canonical** `failed` group — abandon a begun rebuild on a
  registered `slice-v2:` group — is still refused by `adoptCatalogGroups` with
  `AdoptGroupNotLive`, and that a **stale-format** `failed` group (doctor the stored
  slice with `setStoredSliceStmt` to `"slice-v1:" <> ...` after abandoning) is adopted
  with status preserved.
- In `keiro/test/GroupRebuildSpec.hs`, extend the abandon example (around line 140):
  after the abandon assertions, call `beginGroupRebuild` again with a new run id and
  assert `Right`, the group `rebuilding`, and the old failure evidence cleared — the
  general `failed -> rebuilding` reopening.

Amend the ADRs in this same change (ADR workflow: strict profile, preserved `docId`,
advanced `timestamp`, bundle log):

- `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
  — in the Decision section, extend the migration-0024 paragraph: the sentinel
  `'$pre-canonical'` is a terminal recovery marker handled by exactly one path — such a
  run is always abandonable (slice- and catalog-independent, evidence-preserving,
  idempotent), never resumable (typed `CatalogRebuildRunPreCanonical`), and never a valid
  lifecycle identity; a `failed` group whose stored fingerprint predates the canonical
  prefix may be adopted while it stays fenced; a fresh rebuild may begin on a `failed`
  group once its slice matches the catalog. Soften "Operators must complete or abandon
  active catalog rebuilds before applying it" to state that the precondition is
  recommended, is enforced nowhere, and that the supported recovery path (abandon →
  adopt → fresh start) exists for databases upgraded mid-rebuild. Update the sentence in
  the v3/v2 cutover paragraph that says stale-format groups are adopted "while the group
  is `live`" to include the fenced-failed case. Record in Consequences that the
  clean-break recovery promise is fulfilled.
- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
  — update the lifecycle sentence (around line 159) to `live -> rebuilding -> live` on
  promotion, `live -> rebuilding -> failed` on abandonment, and `failed -> rebuilding`
  when an operator explicitly requests a fresh rebuild; both `rebuilding` and `failed`
  keep writers fenced.

Then:

```bash
okf log add docs/adr --kind Update -m "Record the pre-canonical sentinel recovery path: always-abandonable stranded runs, fenced stale-format adoption, and typed resume refusal (ADR-32)."
okf log add docs/adr --kind Update -m "Add the failed -> rebuilding lifecycle transition for explicitly requested fresh rebuilds (ADR-26)."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Acceptance for M3: `cabal test keiro-test` fully green including the entire
`PreCanonicalRecoverySpec`; `okf validate` passes.

### Milestone 4 — Truthful operator surface (Operations + keiro-ops)

Scope: make the two-phase keiro-ops commands work on stranded runs. At the end an
operator can drive the whole recovery from the embedded CLI, previews included.

In `keiro/src/Keiro/Projection/Catalog/Operations.hs`:

- `inspectGroupRebuild` (around lines 273-289): before the current-slice lookup, if
  `report ^. #groupSliceFingerprint == preCanonicalRunSliceSentinel`, return
  `Right (catalogRunReport report)`. This must precede the
  `groupSliceFingerprint catalog (report ^. #rebuildGroupId)` case so a sentinel run of a
  group renamed out of the catalog is inspectable rather than `CatalogOpsUnknownGroup`.
  Import the sentinel from `Keiro.ReadModel.Rebuild`.

In `keiro-ops/src/Keiro/Ops/Rebuild.hs`:

- `runResult` (around line 337): add a `group_slice` column after `status`, rendering
  `run.groupSliceFingerprint`, so the non-forced previews of `status`, `resume`,
  `abandon`, and the forced outcomes show `$pre-canonical` explicitly. No parser or
  policy change: `abandon` already previews via `inspectGroupRebuild` and mutates via the
  library, so Milestones 2-3 flow through automatically (ADR-28's thin-adapter rule).

In `keiro-ops/test/Main.hs`, inside the `"catalog rebuild adoption"` describe block, add
an example "recovers a pre-canonical stranded run through preview and force": seed the
`opsCatalog` group as in the existing adoption test, strand a run by starting a rebuild
under a variant of `opsCatalog` whose rebuild group carries a failing verification hook
(mirror `operationsCatalog failingVerification` in
`keiro/test/CatalogOperationsSpec.hs`; the base `opsCatalog` declares
`verificationHooks = []`) — this leaves the group `rebuilding` with a `failed` run. Then
doctor the run/group rows to the 0024 shape (same two UPDATEs as the keiro spec, with
`'ops-group'` and the stranded run id). The doctored legacy fingerprint is stale-format
regardless of which variant stamped it, so run every recovery step below under the plain
`opsCatalog` operations: adoption stamps that catalog's slice and the fresh start must
validate against the same slice. Assert:

- `OpsRebuild.runCommand (opsEnv False store) operations (Status opsRunId)` returns
  `Succeeded` with a `group_slice` cell equal to `$pre-canonical` (today this is `Failed
  "CatalogOpsRunSliceMismatch ..."`);
- non-forced `Abandon` returns `PreviewRequired` whose invocation ends with
  `'--force'`; forced `Abandon` returns `Succeeded` with run status `RebuildRunFailed`;
- non-forced `Adopt` returns `PreviewRequired` with the group classified `stale-format`;
  forced `Adopt` returns `Succeeded` with the group row showing `failed` and a
  `slice-v2:` fingerprint;
- forced `Start` with a new run id returns `Succeeded` with status `RebuildRunPromoted`.

Acceptance for M4: `cabal test keiro-ops-test` green including the new example;
`cabal test keiro-test` stays green.

### Milestone 5 — Documentation, changelogs, full gate

Scope: user-facing documentation and release notes; final verification.

- `docs/user/read-models-and-projections.md` — rewrite the upgrade-boundary paragraph
  (around line 276): completing or abandoning active rebuilds before upgrading is
  recommended, not enforced; a database upgraded mid-rebuild is recoverable through the
  supported sequence; describe the sentinel and state that a stranded run is always
  abandonable, a fenced stale-format group adoptable, and a failed group restartable.
- `docs/user/operations.md` — in the Read Models section after the command list, add a
  short "Recover a rebuild stranded by the 0.12 identity migration" runbook: the three
  commands from the Purpose section, what each preview shows (including the
  `group_slice` column), and the note that startup registration keeps refusing with
  `RegisteredGroupStaleFingerprint` until adoption. Also state generally that `rebuild
  start` accepts a `failed` group after abandonment.
- `keiro/CHANGELOG.md` Unreleased — under Added: `CatalogRebuildRunPreCanonical`,
  `preCanonicalRunSliceSentinel`, and the recovery semantics (sentinel-aware abandon,
  fenced stale-format adoption, `failed -> rebuilding` fresh starts); under Fixed: a
  database upgraded by migration 0024 while a catalog rebuild was `rebuilding` or
  `failed` is now recoverable through supported APIs.
- `keiro-ops/CHANGELOG.md` Unreleased — under Fixed/Added: `rebuild status` and the
  `abandon` preview work on pre-canonical runs; run tables gain the `group_slice`
  column; the documented recovery runbook.
- Update MasterPlan 39's Exec-Plan Registry row for EP-3 and this plan's living
  sections; write Outcomes & Retrospective; confirm no further ADR distillation is
  pending (the durable decisions landed in M3).

Acceptance for M5: `just verify` passes from the repository root (it runs the Haskell
build/tests, jitsurei, ADR strict validation, and `cabal test keiro-migrations-test`).


## Commit and Trailer Convention

Use Conventional Commits (`test(rebuild): ...`, `feat(rebuild): ...`, `fix(rebuild): ...`,
`docs(rebuild): ...`) — one commit per milestone is a good default, with Milestone 1
committed first and red. Every commit carries these trailers:

```text
MasterPlan: docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md
ExecPlan: docs/plans/248-give-pre-canonical-in-flight-rebuild-runs-a-supported-recovery-path.md
Intention: intention_01kzw6dk7qe1qayx2qdz6vcqfd
```

Commit directly to the current branch; do not create a feature branch.


## Concrete Steps

All commands run from the repository root (`/Users/shinzui/Keikaku/bokuno/keiro`; the
checkout root on other machines). The database-backed suites start their own ephemeral
PostgreSQL through `keiro-test-support`; no manual database setup is required.

```bash
# after Milestone 1 (expected: migrations green, keiro-test red in the new spec)
cabal build all
cabal test keiro-migrations-test
cabal test keiro-test --test-options='-m "pre-canonical"'
```

Expected M1 output shape (abridged):

```text
keiro-migrations-test: ... 0024 stamps in-flight rebuild runs with the pre-canonical sentinel ... ✓
keiro-test: pre-canonical rebuild recovery
  recovers a group stranded mid-rebuild by migration 0024 ✗
    expected Right, got Left (CatalogRebuildContractMismatch ...)
```

```bash
# after Milestone 2 (abandon/resume stages green; adoption/registration/fresh-start red)
cabal build all
cabal test keiro-test --test-options='-m "pre-canonical"'

# after Milestone 3 (whole suite green; ADRs amended)
cabal test keiro-test
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce

# after Milestone 4
cabal test keiro-ops-test

# after Milestone 5 (full gate)
just verify
```

Interpreting results: hspec prints each example with ✓/✗ and a final
`N examples, M failures`; any non-zero failure count fails the cabal test exit code.
`just verify` ends by running `cabal test keiro-migrations-test`; it fails fast on the
first broken gate.


## Validation and Acceptance

Acceptance is behavioral, phrased over the committed tests and CLI transcripts:

1. Failing-before/passing-after: `keiro/test/PreCanonicalRecoverySpec.hs` is committed in
   Milestone 1 and fails at the recovery stages (`abandon` returns
   `CatalogRebuildContractMismatch`, `adopt` returns `AdoptGroupNotLive`, `register`
   returns `RegisteredGroupStaleFingerprint`, fresh `start` returns
   `RebuildGroupSliceDrift`/`RebuildGroupNotLive`). After Milestone 3 the identical file
   passes unmodified.
2. Migration fidelity: the keiro-migrations test proves that applying the real ledger to
   a database seeded mid-rebuild leaves `groups.slice_fingerprint` holding the legacy
   hash and `runs.group_slice_fingerprint = '$pre-canonical'` for both a `rebuilding`
   and a `failed` group — the exact shape the runtime spec doctors in.
3. Refusals that must stay: registration still refuses stale-format groups until
   adoption; adoption still refuses `rebuilding` groups and canonical `failed` groups;
   resume never resumes a sentinel run (now with the typed
   `CatalogRebuildRunPreCanonical`); abandon refuses a sentinel run that is terminal or
   no longer the group's active run.
4. Operator transcript (keiro-ops test, human-table mode): `rebuild status RUN` on a
   stranded run succeeds and shows `group_slice = $pre-canonical`; non-forced `abandon`
   prints the run preview and the exact force invocation and exits unsuccessfully;
   forced `abandon`, forced `adopt`, forced `start` complete the recovery; the final
   status output shows `RebuildRunPromoted`. Illustrative preview shape:

   ```text
   run           group      status            group_slice     captured_head  sources  adapters  verifications
   stranded-run  ops-group  RebuildRunFailed  $pre-canonical  6              1        1         1
   rerun with: 'keiro-ops' 'rebuild' 'abandon' 'stranded-run' '--code' ... '--force'
   ```

5. Lifecycle reopening: GroupRebuildSpec proves an ordinary abandoned (canonical) group
   can begin a fresh rebuild; CatalogEvolutionSpec proves canonical `failed` groups are
   still not adoptable while stale-format `failed` groups are.
6. The full gate `just verify` passes, including strict ADR profile enforcement over the
   amended ADR-26/ADR-32 and the bundle log.


## Idempotence and Recovery

Every step is safe to repeat. The tests run against fresh template-database copies per
example, so re-running suites never accumulates state. The recovery operations themselves
are designed idempotent and the spec asserts it: re-abandoning an already-failed
pre-canonical run succeeds without replacing evidence; re-adopting an unchanged slice is
the documented idempotent outcome (ADR-32); re-registering after adoption is idempotent;
`rebuild start` refuses a duplicate run id with `CatalogRebuildRunAlreadyExists`, so a
retried fresh start needs a new `--run-id` (document this in the runbook). If a milestone
is interrupted mid-edit, `git status` plus this plan's Progress checklist is sufficient to
resume; no migration or destructive repository operation is involved (0024 itself is
deliberately untouched). If the ADR edits fail strict validation, fix frontmatter
(`timestamp` must advance, `docId` must remain `ADR-32`/`ADR-26`) and re-run the
`okf validate` command; `okf log add` appends, so avoid duplicate log entries by checking
`docs/adr/log.md` before retrying.


## Interfaces and Dependencies

Libraries and services: only existing dependencies are used — `hasql`/
`hasql-transaction` for statements, `effectful` for the `Store` effect,
`keiro-test-support` (`Keiro.Test.Postgres`) for the suite-level ephemeral-pg
template-database fixture, `pg-migrate` via `keiro-migrations` for the migration test,
and `okf` for ADR bundle enforcement. No new package or dependency bound changes.

At the end of Milestone 2 these exist with exactly these signatures:

```haskell
-- Keiro.ReadModel.Rebuild.Group (internal; sentinel re-exported by the facade)
preCanonicalRunSliceSentinel :: Text
canonicalSlicePrefix :: Text

abandonPreCanonicalGroupRebuild ::
  (Store :> es) =>
  RebuildGroupId ->
  RebuildRunId ->
  RebuildFailure ->
  Eff es (Either GroupTransitionError GroupRebuildMetadata)

-- Keiro.ReadModel.Rebuild.Runner / re-exported by Keiro.ReadModel.Rebuild
data CatalogRebuildError
  = -- existing constructors unchanged ...
  | CatalogRebuildRunPreCanonical !RebuildRunId !RebuildGroupId
```

At the end of Milestone 3, `adoptCatalogGroups` and `beginGroupRebuild` keep their
existing exported signatures; only their documented preconditions change (fenced
stale-format `failed` groups adoptable; `failed` groups startable after slice match). At
the end of Milestone 4, `Keiro.Projection.Catalog.Operations.inspectGroupRebuild` keeps
its signature and gains the sentinel case, and `Keiro.Ops.Rebuild.runResult` renders the
additional `group_slice` column.

Coordination: soft dependency on plan 247 (EP-2) is satisfied vacuously — recovery never
computes a resume contract for sentinel runs, so the contract prefix bump does not touch
this plan; if 247 lands first, only re-run the suites. Plan 249 (EP-4) owns the adoption
preview/result type shapes and the operator table format for adoption; this plan
deliberately changes neither, reports refusals through the existing
`AdoptGroupNotLive`/`GroupAdoptionClass` vocabulary, and whichever plan lands second
reconciles rendering (per MasterPlan 39, Integration Points).
