---
id: 22
slug: make-the-test-infrastructure-exercise-real-crash-and-production-semantics
title: "Make the test infrastructure exercise real crash and production semantics"
kind: master-plan
created_at: 2026-07-23T04:18:29Z
---

# Make the test infrastructure exercise real crash and production semantics

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Every hardening initiative since June 2026 (MasterPlans 9 through 19) leans on "crash-window tests" running on ephemeral-pg (`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`) and keiro-test-support. The July 2026 test-infrastructure review asked whether those tests can go false-green, and the answer reframes their confidence: none of them crashes anything. The claimed crash is one of: hand-built stranded state with backdated timestamps, a thrown `SimulatedCrash` exception, or `killThread` — which delivers an async exception and runs the graceful bracket cleanup a real `kill -9` skips. `pg_terminate_backend` appears nowhere in any suite (grep-verified); no test kills a backend, the postmaster, or restarts the server. MasterPlan 9's objective sentence ("backed by a crash-window test that kills the process between the two statements") overstates what landed. The simulations are decent — they drive the production SQL API for the pre-crash step — but nothing verifies simulated state matches real post-crash state, and the equivalence will silently drift as claim protocols evolve (TIN-1). Compounding it: the fixture runs `fsync=off`/`synchronous_commit=off`, so naively-added real kill tests would pass because committed transactions were *lost* — inverting their meaning (TIN-2); the "transient database blip" guarantee is backed by a `pendingWith` example (green in CI) plus a table-rename statement-error simulation, leaving real connection death — including the push worker's LISTEN connection dying and never re-subscribing — unexercised (TIN-5); and the ephemeral-pg `Snapshot`/`restart` APIs someone would reach for to build real crash tests leave a stale process handle that ends with the datadir deleted under a live postmaster (TIN-6, latent). Environment fidelity gaps: every suite runs on a `--no-locale` C-collation cluster (read-model `ORDER BY`/collation assertions can pass here and order differently in production, TIN-3) and as a trust-authenticated superuser (production privilege failures on the `keiro`/`kiroku` schemas are uncatchable, and keiro's migrations contain no GRANTs at all, TIN-4). Robustness: a port-allocation TOCTOU plus a check-free readiness fallback cause rare loud 60s flakes (TIN-7); orphaned postmasters survive SIGKILL of the runner with no reaper (TIN-8); the initdb cache key omits minor version/binary identity — reviewed and acceptable (TIN-9). Verified sound and to be preserved: template freshness (migrations really re-run each suite), clone isolation, cache-write atomicity, and shutdown ordering.

After this initiative: each recovery-guarantee class has at least one genuine kill test — `pg_terminate_backend` of a dedicated connection between the two statements of the guarantee, on a durability-enabled configuration — pinning the simulations to reality; the LISTEN-death and connection-death paths are really exercised; pending examples in hardening suites fail CI; suites can run under a production-like locale and a non-superuser role with the documented GRANT set; and the fixture's startup/cleanup is robust under parallel CI. In scope: TIN-1 through TIN-9 across ephemeral-pg, keiro-test-support, and the keiro/keiro-pgmq/keiro-migrations suites; a durable-config export; the ephemeral-pg handle fixes. Out of scope: rewriting the existing (valuable) simulations — real kills augment, not replace them; postmaster-kill/WAL-replay tests beyond what the durable config makes meaningful (decided per plan); the benchmark durability distortion (accepted, documented).


## Decomposition Strategy

Three child plans by concern. EP-1 (plan 132) is the heart: fix the ephemeral-pg snapshot/restart stale-handle trap first (TIN-6 — prerequisite, in the ephemeral-pg repo), export a durability-enabled config from keiro-test-support (TIN-2), then add one real backend-kill test per guarantee class (outbox claim, timer claim, workflow journal append, inbox intake, shard lease — `pg_terminate_backend` from a second connection at the documented window), a real LISTEN-death/re-subscribe test for the push worker, and turn the keiro-pgmq `pendingWith` fault-injection example into a real test or a CI failure (TIN-1, TIN-5). EP-2 (plan 133) owns environment fidelity: a locale/collation-parameterized fixture option with at least one read-model ordering test under a production locale (TIN-3), and a non-superuser smoke suite that provisions the documented role/GRANT set and runs a representative command/subscription/outbox cycle (TIN-4 — this also forces writing down the production GRANT set, which today exists nowhere). EP-3 (plan 134) owns fixture robustness: port-bind retry and a socket-probe readiness check replacing the silent fallback (TIN-7), a stale-instance reaper keyed by pidfiles under the cache root (TIN-8), and recording TIN-9's cache-key review as documentation.

Alternatives considered. Making real-kill tests a per-subsystem obligation inside MasterPlans 20/21/23 was rejected: the infrastructure (durable config, kill helpers, handle fixes) must exist once, centrally, with the per-guarantee tests as its acceptance; later initiatives then reuse the helpers. Deleting the simulations in favor of kills was rejected: simulations are fast and precise; kills pin them.

ADR context: no relevant ADR exists in keiro's `docs/adr/` (0001 is pgmq telemetry). Candidate ADR: the testing contract — what "crash-window tested" must mean (real kill + durable config) for any future guarantee claim.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Add real crash-window tests on a durability-enabled fixture | docs/plans/132-add-real-crash-window-tests-on-a-durability-enabled-fixture.md | None | None | Not Started |
| 2 | Test under production locale and a non-superuser role | docs/plans/133-test-under-production-locale-and-a-non-superuser-role.md | None | None | Not Started |
| 3 | Harden ephemeral-pg startup port allocation and orphan cleanup | docs/plans/134-harden-ephemeral-pg-startup-port-allocation-and-orphan-cleanup.md | None | None | Not Started |


## Dependency Graph

No hard dependencies between the three plans; EP-1 contains its own internal ordering (ephemeral-pg handle fix → durable config → kill tests). EP-2 and EP-3 both touch ephemeral-pg's `Config.hs` surface (initdb args parameterization vs port/readiness) — disjoint functions, one release. The ephemeral-pg release train is shared: EP-1's handle fixes, EP-2's locale parameterization, EP-3's startup hardening ship together or sequentially; the last-landing plan bumps keiro-test-support's bound.


## Integration Points

ephemeral-pg repo: EP-1 (Snapshot.hs/EphemeralPg.hs handle threading), EP-2 (initdb-args/locale surface — already parameterized, may need only documentation), EP-3 (Port.hs, Process/Postgres.hs, cache-root reaper). One release; each plan states the version it targets.

`keiro-test-support/src/Keiro/Test/Postgres.hs`: EP-1 adds `durableConfig` + kill helpers; EP-2 adds locale/role-parameterized fixture entry points. Both extend the module additively; EP-1 lands the helper naming convention first if concurrent.

CI policy (Justfile / `just verify`): EP-1 owns the "pending examples fail hardening suites" change — the mechanism (hspec `--fail-on=pending` flag or equivalent) must be recorded and applied to keiro, keiro-pgmq, keiro-migrations suites.

Cross-plan decision for ADR promotion: the crash-window testing contract; the production GRANT set (EP-2 writes it down for the first time — also feeds the migration-ownership guide).


## Progress

- [ ] EP-1: ephemeral-pg snapshot/restart return live handles; config threaded; regression test.
- [ ] EP-1: `durableConfig` exported; kill helpers in keiro-test-support; one real backend-kill test per guarantee class passes; LISTEN-death re-subscribe test passes; pending examples fail hardening suites in CI.
- [ ] EP-2: Locale-parameterized fixture; production-locale ordering test; non-superuser role smoke suite with documented GRANT set.
- [ ] EP-3: Port-bind retry + socket-probe readiness; stale-instance reaper; cache-key review documented.


## Surprises & Discoveries

- Review (2026-07-23): the MP-9 objective sentence overstates what landed — its own EP-4-7 pattern note accurately describes simulation, but no suite performs any real kill; `pg_terminate_backend` is absent from the entire codebase (grep-verified independently).
- Review (2026-07-23): the crash-window simulations do use the production SQL API for the pre-crash step, and clone/template freshness is genuinely sound — the gap is fidelity verification, not wholesale invalidity.
- Plan authoring (2026-07-23), affects EP-2: a production GRANT snippet already exists in `docs/user/migration-ownership.md:136-144` — documentation-first, never executed by any test, and likely incomplete (no default privileges, no function grants, no pgmq schema); EP-2 (docs/plans/133) promotes it to an executable, test-applied script rather than writing one from scratch.
- Plan authoring (2026-07-23), affects EP-1: kiroku's listener already implements reconnect + re-LISTEN with capped backoff (`Kiroku/Store/Notification.hs`); the gap is that no test exercises it against a real terminated backend — EP-1's LISTEN-death test is a fidelity pin of existing recovery logic, not a fix.


## Decision Log

- Decision: Backend-kill (`pg_terminate_backend`) on a durable config is the standard real-crash mechanism; postmaster-kill/WAL-replay tests are optional per-plan extensions.
  Rationale: Backend kill exercises the connection-death semantics the findings target (lock release, unfinalized acks, LISTEN loss) and works on the current fixture today; postmaster kills require the durable config EP-1 introduces and add wall-clock cost.
  Date: 2026-07-23

- Decision: Keep the existing simulations alongside the new kill tests.
  Rationale: Simulations are fast and window-precise; kills verify the simulations' fidelity. One kill test per guarantee class suffices as the pin.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)
