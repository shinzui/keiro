---
id: 41
slug: make-read-models-safely-readable-by-out-of-process-consumers
title: "Make read models safely readable by out-of-process consumers"
kind: master-plan
created_at: 2026-08-12T23:55:22Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
---

# Make read models safely readable by out-of-process consumers

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

This MasterPlan implements
`docs/improvement-requests/make-read-models-safely-readable-by-out-of-process-consumers.md`
(IR-22) in full — all four requested capabilities — before the 0.12.0.0 release.

Keiro's group-fenced offline rebuild is enforced entirely at Haskell call boundaries. A
non-Haskell process holding its own PostgreSQL connection and issuing `SELECT` against a
read-model target participates in none of them: during a rebuild of a group containing a
`ClearBeforeReplay` target it observes a truncated table, then a progressively refilling
one — a coherent, queryable, *historical* picture of the world — with nothing to tell it
anything is wrong. The requesting consumer (`mori://tan/notification-render-service`,
Keiro's only consumer today, splitting into a Keiro service plus a stateless TypeScript
render process that reads the read model over SQL) found the hazard in design review and
is hand-rolling a mitigation it would delete in favor of a sanctioned one. With wide
adoption the goal after 0.12, every future out-of-process reader would otherwise
rediscover and re-solve the same hazard, each differently, most wrongly.

After this MasterPlan completes: an external SQL reader has a sanctioned read surface
that fails loudly — with a documented, distinguishable error — whenever the backing
group is not in live service, instead of silently returning historical rows; a
documented, compatibility-promised status relation exposes each rebuild group's
identity, applied position, and live-service state to any SQL client; a catalog rebuild
can replay into a new versioned target alongside the live one and cut over atomically,
so external readers never lose service and the fence becomes a backstop rather than a
maintenance window; and an operator can reproject a single stream into a
row-per-aggregate model without taking a group-wide fence. The documentation states
plainly, in both the user guide and the runtime-patterns standard, that the in-process
fence does not protect out-of-process readers and names the sanctioned alternative.

This lands before 0.12.0.0 because every contract it defines — the error code, the
status relation's columns, the external-consumer declaration, the versioned rebuild
protocol's persisted metadata — becomes a compatibility promise at the first stable
release; defining them one release later means either breaking early adopters or
carrying compatibility shims forever. Whatever surface the external-consumer declaration
adds to the `.keiro` language must land while language 5 is still a candidate, because
candidate amendments are legal only pre-publication (the same constraint that gated
MasterPlan 36).

Excluded: IR-25 (declarative payload mappings, deferred to language 6), any change to
the in-process fence semantics delivered by IR-20, and release mechanics. The rebuild
correctness fixes this work builds on are MasterPlan 39's, not this plan's.


## Decomposition Strategy

The four IR-22 capabilities map to four plans, ordered by the IR's own value ranking and
by dependency: the status relation (EP-1) is the shared vocabulary everything else
speaks; the fence (EP-2) is the correctness gap and consumes EP-1's liveness vocabulary;
versioned cutover (EP-3) is the availability capability that makes the fence a
non-event and extends both EP-1's relation and EP-2's read surface; per-stream
reprojection (EP-4) shrinks how often any of it matters. The IR's fourth deliverable —
documentation of the hazard — is not a separate plan: EP-2 owns the local documentation
(`docs/user/read-models-and-projections.md`), since the sanctioned read surface is what
the documentation must name, and the cross-repository runtime-patterns standard
(`keiro-runtime-patterns`) is recorded as an external follow-up in the Integration
Points section.

EP-3 deliberately revisits a stated ownership stance. The runtime-patterns standard
says Keiro never creates, migrates, or swaps application-owned tables; IR-22
conditionally asks for the framework to own a versioned target lifecycle, and the user
has decided (2026-08-12) to implement it rather than close it. That boundary change is a
first-order architectural decision and must produce a new ADR in `docs/adr/` defining
what Keiro now owns (versioned physical targets it creates and swaps) and what remains
application-owned (the declared table shape and its DDL evolution).

Relevant ADRs, read during planning:
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
(the four identities this MasterPlan attaches to: the fence is a group property, the
sanctioned read a query-binding property, the privacy a target property; IR-22 depends
on that separation, and its cross-repository motivation
`mori://shinzui/mori/okf/adrs/concepts/ADR-20` — one catalogued owner per live table —
is what makes an external read API well defined),
`docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
(group slices and adoption; versioned targets and the external-consumer declaration
extend the slice preimage and therefore interact with its prefix-bump rules),
`docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
(the cutover and reprojection operator surfaces must wrap library APIs), and
`docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md` (Keiro's own
schema — where the status relation lives — is migration-owned; the relation ships as a
keiro-migrations change).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Publish a documented projection status relation for external readers | docs/plans/254-publish-a-documented-projection-status-relation-for-external-readers.md | None | External: MP-39 EP-3/EP-4 | Not Started |
| 2 | Fence out-of-process read-model reads behind a sanctioned SQL surface | docs/plans/255-fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface.md | None | EP-1 | Not Started |
| 3 | Rebuild into versioned targets with atomic cutover | docs/plans/256-rebuild-into-versioned-targets-with-atomic-cutover.md | EP-1, EP-2; external: MP-39 EP-1, EP-2, EP-5 | None | Not Started |
| 4 | Add targeted per-stream reprojection to catalog operations | docs/plans/257-add-targeted-per-stream-reprojection-to-catalog-operations.md | None | EP-2 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 has no dependency inside this MasterPlan and should land first: it defines the
external vocabulary (group identity, applied position, live-service state) that EP-2's
error surface and EP-3's version visibility extend. It soft-depends on MasterPlan 39's
EP-3 and EP-4 (`docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md`)
only because those plans finalize the group lifecycle metadata (pre-canonical recovery,
adoption reporting) the relation exposes; it can be drafted and largely implemented
against current state.

EP-2 soft-depends on EP-1: the fence's "group is not live" error and the status
relation must agree on what liveness means and how a group is identified, but the fence
is implementable against the registration tables directly if EP-1 has not landed.

EP-3 hard-depends on EP-1 and EP-2 within this MasterPlan — it adds version columns to
the status relation and must keep the sanctioned read surface stable across cutover,
which is only meaningful once both exist — and hard-depends externally on MasterPlan
39's EP-1 and EP-2, because it rebuilds on the same replay path whose ordering and
resume-contract defects those plans fix; building the versioned protocol on the broken
pager would bake the corruption into the new path. It also hard-depends on MasterPlan
39's EP-5 (plan 258, added 2026-08-13): the offline promotion's dedup-backfill and
checkpoint-advance helpers that EP-5 introduces are the same primitives EP-3's promote
transaction reuses for the versioned path.

EP-4 soft-depends on EP-2: targeted reprojection deliberately takes no group-wide
fence, and its plan must state how an external reader's view (through EP-2's surface)
behaves during a targeted reprojection. It can proceed in parallel with EP-3.

The critical path is therefore EP-1, EP-2, EP-3, with EP-4 parallel to EP-3 after EP-2,
and MasterPlan 39 ahead of EP-3.


## Integration Points

The status relation (EP-1, extended by EP-3) is a keiro-schema database object shipped
through `keiro-migrations` per
`docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md`. EP-1 defines
its name, columns, and compatibility promise; EP-3 may only add columns (versioned
target visibility), never rename or repurpose, because the relation is an external
contract from the moment EP-1 documents it.

The external-consumer declaration and the generated read surface (EP-2, consumed by
EP-3) span the runtime catalog (`keiro/src/Keiro/Projection/Catalog.hs` and the
registration schema in `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`) and, if the chosen
shape includes it, the `.keiro` language surface in `keiro-dsl` (grammar, validation,
lowering, generated catalog output, diff, fingerprints). EP-2 defines the declaration
and the read-surface identity (function names, documented SQLSTATE); EP-3 must preserve
that identity across cutover — external readers must observe the same functions
returning new-version rows after an atomic swap, which constrains EP-3 to route the
generated surface through an indirection EP-2 must design for (the read function
resolves the current live physical target rather than baking in a table name). This
shared indirection is the single most important interface in the MasterPlan; EP-2 owns
it, EP-3 consumes it, and any change requires updating both plans.

Any `.keiro` language addition from EP-2 amends candidate language 5 and must land
before the Candidate-to-Stable registry flip in the release mechanics; the slice
fingerprint consequences fall under
`docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
prefix-bump rules (pre-0.12 formats are still unreleased, so clean breaks are legal).

`ProjectionCatalogOperations` (`keiro/src/Keiro/ReadModel/Rebuild/*`, the operator
library surface wrapped by `keiro-ops`) is extended by EP-3 (cutover protocol,
versioned lifecycle commands) and EP-4 (per-stream reprojection). EP-3 defines any new
lifecycle vocabulary; EP-4 reuses it. Both wrap through `keiro-ops` per
`docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`.

Cross-repository follow-ups this MasterPlan records but does not own: the
runtime-patterns standard (`keiro-runtime-patterns`, currently stating the rebuild is
offline and Keiro never swaps tables) must be updated after EP-2 and EP-3 land — its
read-models and projection-catalogs pages both change; and
`mori://tan/notification-render-service` should be notified when EP-2 lands so it can
replace its hand-rolled SQL mitigation with the generated surface (its
`docs/SPLIT-PULL-ALTERNATIVE.md` documents the mitigation this work supersedes).

ADR obligations: EP-2 produces an ADR for the external read contract (declaration,
SQLSTATE, what is promised to non-Haskell readers); EP-3 produces the versioned-target
ownership ADR described in the Decomposition Strategy; EP-1 and EP-4 amend
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
and ADR-32 as their deliverables touch those contracts.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1 (254) M1: migration `0025-keiro-projection-group-status.sql` (cursor-binding table + status view + COMMENTs), schema-gate extension to views, keiro-migrations fixtures
- [ ] EP-1 (254) M2: registration/adoption reconcile the cursor-binding table (idempotent, no fingerprint change)
- [ ] EP-1 (254) M3: `Keiro.ReadModel.Rebuild.Status` accessor + live→rebuilding→live lifecycle proof
- [ ] EP-1 (254) M4-M5: column-contract docs with compatibility promise + SQL recipes, new ADR + ADR-9/ADR-26 amendments, changelogs, jitsurei psql transcript, `just verify`
- [ ] EP-2 (255) M1: `externalReaders` runtime declaration, validation diagnostics, fingerprint-stability proof (`catalog-v3:`/`slice-v2:` unchanged)
- [ ] EP-2 (255) M2: migration `0026.sql` (`keiro_read` schema); generated guard (`KR001`/`KR002`) + per-target views + per-binding read functions reconciled at registration; IR acceptance test + hazard characterization; psql transcript
- [ ] EP-2 (255) M3: language-5 `external-readers` clause (parser/pretty-print/validation/lowering/diff `CatalogQueryExternalReadersChanged`), fixtures, corpus regen, ADR-16 amendment
- [ ] EP-2 (255) M4: hazard docs, new ADR (external read contract), jitsurei adoption, changelogs, `just verify`
- [ ] EP-3 (256) M1: versioned DDL prototype (`LIKE ... INCLUDING ALL` coverage, concurrent-reader rename-swap proof, sequence resync, 63-byte naming)
- [ ] EP-3 (256) M2: persisted lifecycle (statuses `rebuilding-versioned`/`cutover`, `target_mode`, run-targets table, additive 254 columns) + guard serving-set regeneration
- [ ] EP-3 (256) M3: `PhysicalTargets` parametric write boundary (runtime + DSL scaffold holes)
- [ ] EP-3 (256) M4: converging replay (staging writes, catch-up rounds, contract-v4 resume)
- [ ] EP-3 (256) M5: atomic cutover (tail replay, verification, dedup backfill, checkpoint advance, rename swap, external-read view re-point) + concurrent-reader acceptance + crash-resume
- [ ] EP-3 (256) M6-M7: drain/drop + ops surface; ownership ADR, ADR-32 amendment, docs, four changelogs, `just verify`
- [ ] EP-4 (257) M1: `ReplayableStreamScoped` policy + `declareStreamScopedRows` combinator + fingerprint-neutrality proof
- [ ] EP-4 (257) M2: single-transaction reproject runner (group lock without lifecycle fence, in-tx stream read, delete-then-replay, completeness guard, nine typed refusals)
- [ ] EP-4 (257) M3-M4: operations wrappers + `keiro-ops rebuild reproject` with two-phase force and transcript
- [ ] EP-4 (257) M5: docs, ADR-26 amendment + ADR-32 exclusion note, changelogs, `just verify`


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- The expected-schema gate (`SchemaCheck.hs`) snapshots only `relkind='r'`, so
  shipping EP-1's view requires the format extension ADR-9 anticipated — explicit M1
  work in plan 254. The legacy single-model rebuild path transitions only
  `keiro_read_models` and leaves its singleton group row `live`, so the status view
  computes `service_state` as a fail-safe conjunction of group and model-row status.
- Generated code constructs `QueryModelBinding` positionally, so EP-2's new
  declaration field forces an emitter fix and corpus regeneration in the same
  milestone (plan 255 M1).
- The migration body lint forbids `search_path` and the schema gate has no `pg_proc`
  arm, so EP-2's generated objects cannot ship as migrations: the `keiro_read` schema
  ships as migration 0026 while its contents are registration-reconciled at startup —
  which is also what lets EP-3 re-point views transactionally at cutover.
- EP-4 drafting found that reading the stream before the reprojection transaction is
  unsound (a concurrent inline commit between read and lock would be silently
  erased); the plan reads in-transaction through kiroku-store's exported
  `readStreamForwardStmt`. Soft-deleted/truncated streams are refused because
  per-stream reads hide history that `$all` replay sees.


## Decision Log

- Decision: Implement all four IR-22 capabilities before 0.12.0.0, including the
  conditional capability 3 (versioned rebuild with atomic cutover).
  Rationale: user decision 2026-08-12 after the fix verification review. Every contract
  IR-22 defines becomes a compatibility promise at the first stable release, keiro has
  exactly one consumer today (the IR's requester), and the versioned-rebuild rewrite of
  the replay path should happen once, on top of MasterPlan 39's corrected runner, not
  twice.
  Date: 2026-08-12
- Decision: Order the capabilities status relation, fence, cutover, reprojection, with
  the status relation first.
  Rationale: the relation is pure vocabulary — cheap, dependency-free, and everything
  else references its definitions of group identity, position, and liveness.
  Date: 2026-08-12
- Decision: EP-3 hard-depends on MasterPlan 39 EP-1 and EP-2.
  Rationale: it rewrites the replay path those plans fix; building the versioned
  protocol on the defective pager or the order-blind resume contract would carry both
  defects into the new protocol's first release.
  Date: 2026-08-12
- Decision: The hazard documentation ships inside EP-2 rather than as a separate plan;
  the runtime-patterns (cross-repository) update is recorded as a follow-up, not a
  child plan.
  Rationale: the documentation's content is the sanctioned surface EP-2 builds, and
  this repository's MasterPlan cannot gate on another repository's change.
  Date: 2026-08-12
- Decision (post-drafting reconciliation): keiro-migrations numbering is EP-1 = 0025,
  EP-2 = 0026, EP-3 = next free at landing time; new-ADR handles are allocated with
  `okf id next` at landing time and never assumed in advance (three child plans
  allocate ADRs).
  Rationale: EP-1 and EP-2 were drafted in parallel and both claimed 0025/ADR-34; the
  dependency order fixes the sequence.
  Date: 2026-08-12
- Decision (post-drafting reconciliation): EP-2's generated guard is deliberately
  fail-safe — any status other than `live` raises `KR001`, unknown statuses included —
  and EP-3 owns both extensions the cutover needs: regenerating the guard to classify
  `rebuilding-versioned`/`cutover` as serving, and re-pointing the
  `keiro_read."target__<targetId>"` views (`CREATE OR REPLACE VIEW`) inside the
  cutover transaction, because PostgreSQL views bind table OIDs and do not follow
  renames. EP-3's original draft assumed per-call name resolution; corrected to
  match EP-2's frozen view-based contract.
  Rationale: EP-2 lands first and cannot know future lifecycle states; fail-safe
  defaults plus explicit later extension keeps external readers safe at every
  intermediate commit.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)
