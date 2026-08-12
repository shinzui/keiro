---
id: 237
slug: canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution
title: "Canonicalize catalog fingerprint preimages and support catalog evolution"
kind: exec-plan
created_at: 2026-08-11T23:37:31Z
intention: "intention_01kzsjzp13e28vvrz7jfdve3dt"
master_plan: "docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md"
---

# Canonicalize catalog fingerprint preimages and support catalog evolution

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A keiro service declares its entire read-side fleet — projections, target tables,
rebuild groups, query models, subscriptions — in one typed "projection catalog". The
catalog's SHA-256 fingerprint is the identity that gates every dangerous operation:
registration refuses a drifted catalog at startup, `beginGroupRebuild` refuses to
`TRUNCATE` application tables and reset subscription checkpoints unless the stored
fingerprint matches, and an interrupted destructive replay refuses to resume under a
different contract. The 2026-08-11 pre-release review confirmed that this identity is
unsound in two ways that together make it both forgeable and a permanent trap:

1. **The fingerprint preimage is injectable.** The text that gets hashed is built by
   joining fields with `|`, `,`, `:` and newlines without any escaping, so two
   structurally different catalogs can hash to the same fingerprint, and a hostile or
   merely unlucky free-text field (a codec fingerprint containing `|`, a name
   containing a newline) can forge whole inventory lines. Everything the fingerprint
   is supposed to prove — drift refusal, the pre-TRUNCATE identity check, the write
   fence, resume compatibility — is silently defeasible.

2. **There is no evolution path.** Every rebuild-group row stores a digest of the
   *entire* catalog, and no code path ever updates it. Any inventory change at all —
   even adding a brand-new read model and group that touches nothing existing —
   changes that digest, so on the next deploy every pre-existing group refuses
   registration (`RegisteredGroupFingerprintDrift`, and the documented startup
   pattern refuses startup) *and* refuses the rebuild that would be the escape hatch
   (`RebuildCatalogFingerprintDrift`). The only remediation is hand-written SQL
   against keiro-owned tables, which
   `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
   forbids.

These are one design problem and must ship atomically: fixing the encoding changes
every fingerprint in existence, and without an evolution/adoption path that change
would itself trigger exactly the lockout it exists to prevent.

After this plan, a person can: (a) build two catalogs that today collide and observe
distinct fingerprints; (b) register a catalog, add a new read model and rebuild
group, redeploy, and watch registration succeed with the existing groups untouched
and still serving; (c) change an existing group's own definition and watch
registration and rebuild still refuse until an explicit, previewable
`keiro-ops rebuild adopt --force` step is taken; (d) interrupt a destructive replay,
deploy an unrelated additive catalog change, and resume the replay — while a genuine
change to the interrupted group still refuses resume; and (e) see all of this
through supported keiro-ops commands with the standard preview-then-`--force`
discipline, never through SQL.

**Timing is part of the design.** keiro 0.12.0.0 will be the first stable release
and fleet adoption starts immediately after it. The projection-catalog runtime
shipped entirely inside the 0.11 → 0.12 window: keiro-migrations 0.11.0.0
(2026-08-05, "No changes this release") predates migrations `0022.sql` and
`0023.sql` that create `keiro.keiro_projection_rebuild_groups` and the run tables,
so **no supported deployment can currently hold a persisted catalog fingerprint**.
0.12 is therefore the last point at which the fingerprint encoding can change as a
clean break. This plan must land before the 0.12.0.0 tag.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [x] M1 (prototyping): reproduce both defects with concrete fixtures; validate the
      canonical encoder and the slice-scoped lifecycle joins against the real schema;
      record evidence in Surprises & Discoveries. Completed 2026-08-12T11:04:39Z.
- [x] M2: `Keiro.Projection.Catalog.Preimage` canonical encoder; v2 catalog
      fingerprint; new `GroupSliceFingerprint`; pure regression tests (collision
      fixtures now distinct, order-insensitivity retained, slice stability under
      additive change). Completed 2026-08-12T11:11:51Z.
- [x] M3: migration `0024` (rename `catalog_fingerprint` → `slice_fingerprint` on
      groups; add `group_slice_fingerprint` to runs); regenerate expected schema;
      convert registration, begin, resume, finish, abandon, fence-lifecycle and
      completion-proof statements to slice-scoped identity; renamed error
      constructors; DB tests for additive re-registration and slice-drift refusal.
      Completed 2026-08-12T11:27:41Z.
- [x] M4: adoption API (`previewCatalogAdoption`, `adoptCatalogGroups`) in the
      rebuild library and `Keiro.Projection.Catalog.Operations`; DB tests for the
      full changed-slice adoption path, read-model reconciliation, and stale-format
      (hypothetical 0.11) row adoption. Completed 2026-08-12T11:46:09Z.
- [ ] M5: `keiro-ops rebuild adopt` command with preview-then-`--force`; slice
      fields in existing preview/list renderings; keiro-ops tests.
- [ ] M6: docs (`docs/user/read-models-and-projections.md`, API reference),
      changelogs (keiro, keiro-migrations, keiro-ops), ADR distillation (new ADR +
      pointer updates in ADR 0026), full `just verify`, masterplan progress update.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The focused M1 probe passed with four examples on 2026-08-12: both malformed
  inventory pairs compare equal under the current renderer, the additive catalog
  is refused by both registration and rebuild begin, and all adversarial
  canonical trees render distinctly. Evidence: `cabal test keiro-test
  --test-option=--match --test-option=probe` reported `4 examples, 0 failures`.
- The lifecycle join inventory matched the plan's M3 edit list. The group
  fingerprint column is read or written by `Group.hs` and `Schema.hs`; the run
  epoch equality is enforced by `resumeRunStmt`, `lockActiveRunStmt`, and
  `completionProofStmt` in `Runner.hs`; migrations 0022/0023 and the native schema
  snapshot are the only schema definitions. The DB-backed probe additionally
  proved that `beginGroupRebuild` reaches the stored-fingerprint refusal before
  any target-table preparation after registration drift.
- The canonical tree needed byte lengths, not character counts: the installed
  `bytestring` builder exposes strict-byte payload builders and decimal integer
  builders, while `cryptohash-sha256` hashes a strict `ByteString`. The promoted
  implementation encodes `Text` to UTF-8 once per payload, prefixes its strict
  byte length, and hashes the strict builder result. The full `keiro-test` suite
  passed with `473 examples, 0 failures`, including seven permanent preimage and
  slice regressions.
- The migration checker takes the manifest through `--manifest`; the positional
  command sketched in the plan is not accepted by the current executable.
  Migration `0024` also required the native checksum lock, native/Codd migration
  counts, and expected-schema snapshot to advance together. After regeneration,
  `keiro-migrations-test` passed with `28 examples, 0 failures`.
- Persisting the group slice on each rebuild run was sufficient to keep an active
  run resumable after an unrelated catalog addition while retaining drift fences
  for genuine codec changes. The full `keiro-test` suite passed with `474
  examples, 0 failures`, including the additive registration and active-run
  regression fixtures.
- Adoption must lock and validate the complete sorted request set before issuing
  any update. The implementation therefore separates its lock pass from the
  group-slice and query-registration reconciliation passes; a later non-live or
  missing group cannot leave an earlier group adopted. The new full-path,
  atomic-refusal, and stale-format scenarios brought `keiro-test` to `477
  examples, 0 failures`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix the preimage with a length-prefixed (netstring-style) canonical
  encoding rather than escaping delimiters.
  Rationale: Length prefixes are injection-proof by construction — every
  variable-length component is preceded by its exact byte length or child count, so
  no field content can move a structure boundary, and injectivity is provable by a
  short prefix-code argument. Escaping requires per-delimiter discipline at every
  one of ~40 field sites across two modules (`|`, `,`, `:`, `@`, newline) and a
  single missed site silently reopens the defect. The preimage is only hashed,
  never displayed, so human readability of the preimage has no value;
  `renderCatalogInventory` is retained unchanged as the operator-facing rendering
  and explicitly stops being the fingerprint preimage.
  Date: 2026-08-11

- Decision: Scope the per-group stored identity to the group's own slice (its
  targets, verifications, projections, referenced sources, referenced
  subscriptions and dedup keys, and bound query models) instead of the whole
  catalog. The whole-catalog fingerprint survives only as a report-level identity
  (`catalogInventoryReport`, run-row provenance); no lifecycle gate compares it.
  Rationale: Every gate the whole-catalog fingerprint powered is exactly what makes
  additive evolution impossible: an unrelated new group changed every stored row's
  expected value. The slice is precisely the set of facts that preparation, replay,
  promotion, and the write fence actually depend on (it is the same information
  `previewGroupRebuild` already reports), so drift refusal keeps its full safety
  meaning while unrelated changes stop disturbing it. A "registration-time
  whole-catalog check with a defined refresh" was evaluated and rejected: with
  slices stored, the only content such a check could have is "the catalog changed
  somewhere", which is the additive case we must allow, so the check would either
  be vacuous or reintroduce the lockout. A side effect accepted knowingly: two
  services sharing one keiro schema no longer conflict merely by having different
  catalogs; they conflict only if they claim the same group id with different
  slices, which is genuine drift.
  Date: 2026-08-11

- Decision: Registration refresh policy. Registration inserts new groups, accepts
  unchanged slices (idempotent, no row update needed beyond the insert-or-lock),
  refuses changed slices with a typed error naming the adoption command, and
  refuses stale-format stored values (any value without the current `slice-v1:`
  prefix that is not the `$legacy-unmanaged` sentinel) with a distinct typed error.
  Registration never updates a stored slice fingerprint automatically.
  Rationale: An automatic refresh on slice change would erase exactly the evidence
  the gate exists to protect (the stored identity of data that was built under the
  old definition). An automatic refresh on stale format would assert slice equality
  that cannot be verified against a v1 whole-catalog hash. Both therefore require
  the explicit, operator-visible adoption step. Unchanged slices need no refresh at
  all because nothing whole-catalog is stored on the group row anymore.
  Date: 2026-08-11

- Decision: Adoption is metadata-only and separate from rebuild. `adoptCatalogGroups`
  stamps the new slice fingerprint on named live groups and reconciles the bound
  `keiro.keiro_read_models` rows (version, shape hash, group binding) in one
  transaction; it never touches application tables. Rebuilding after adoption, when
  the change invalidates persisted rows, is the existing `rebuild start` command. No
  combined "begin rebuild while adopting" variant is added.
  Rationale: Two small previewable steps mirror the existing command granularity and
  keep each preview honest ("this changes only keiro-owned registration metadata"
  versus "this truncates these tables"). Whether a slice change invalidates
  persisted target rows is an application judgment keiro cannot make — e.g. adding a
  verification hook does not, a codec change does — so the operator decides whether
  `rebuild start` follows, and the preview says so explicitly. Adoption requires
  `live` status: a rebuilding group's active run depends on the stored slice, and a
  failed group's fence preserves failure evidence per ADR 0026.
  Date: 2026-08-11

- Decision: Fingerprint texts carry explicit format prefixes — `catalog-v2:<hex>`,
  `slice-v1:<hex>`, `contract-v2:<hex>` — and the runner format becomes
  `keiro/projection-replay/v2`.
  Rationale: Without a prefix, a stored v1 hex value is indistinguishable from a
  current-format value, so stale-format rows (a hypothetical 0.11 database) could
  only be reported as generic drift. With prefixes, registration can name the
  precise remediation, and every future encoding change inherits the same
  detectability. The runner format bump records that the persisted contract
  preimage layout — part of the persisted run-evidence format — changed.
  Date: 2026-08-11

- Decision: The rebuild-resume contract is derived from the group slice fingerprint
  (`contract-v2` = hash of a canonical record containing the slice fingerprint),
  replacing the whole-catalog fingerprint plus hand-joined source/adapter/
  verification lines.
  Rationale: The slice already canonically covers every replay-relevant fact
  (sources with codec fingerprints, adapter identities and order via projections,
  verifications, targets, bound query models), so re-listing them in a second
  ad-hoc encoding would be a second injection surface and a second thing to keep in
  sync. Deriving from the slice gives the desired evolution behavior for free: an
  unrelated additive catalog change leaves the contract identical (resume
  proceeds), while any change to the interrupted group's slice changes the contract
  (resume refuses).
  Date: 2026-08-11

- Decision: Schema change is a rename plus one addition, not a parallel column set:
  `keiro_projection_rebuild_groups.catalog_fingerprint` becomes `slice_fingerprint`
  (the `$legacy-unmanaged` sentinel value carries over; stale v1 hex values become
  detectable stale-format values, which is the correct classification for a
  hypothetical 0.11 row), and `keiro_projection_rebuild_runs` keeps
  `catalog_fingerprint` as begin-stamped provenance while gaining
  `group_slice_fingerprint` for the epoch-consistency joins.
  Rationale: 0.12 is a clean break with zero supported persisted rows, so honesty of
  names wins over column-level compatibility. Runs keep whole-catalog provenance
  because "which catalog started this run" is cheap, useful operator evidence, but
  it participates in no equality gate.
  Date: 2026-08-11

- Decision: Identity validation (`mkIdentity`) is deliberately not tightened to
  reject embedded delimiters or newlines.
  Rationale: The soundness defect lives in the encoding, not the values: free-text
  fields (codec fingerprints, subscription names, dedup names, shape hashes,
  verification ids/versions) can never be constrained without breaking legitimate
  users, so the encoding must be injection-proof regardless — and once it is,
  constraining ids buys no additional soundness. Tightening would also invalidate
  persisted ids for no benefit.
  Date: 2026-08-11

- Decision: Group rows removed from the catalog are reported by
  `previewCatalogAdoption` but never auto-deleted, and query-model registration
  drift for models bound to a group is remediated through that group's adoption.
  Rationale: Removal detection is a separate evidence boundary per ADR 0026
  (`compareCatalogBaseline`); a stale registered row is inert garbage, not a
  lockout, and deleting registration state implicitly would erase evidence.
  Query-model rows (version, shape hash, group binding) are part of the group's
  slice, so the slice adoption transaction is the natural single place to
  reconcile them; a model moving between groups is adopted by naming both groups
  in one `adoptCatalogGroups` call.
  Date: 2026-08-11

- Decision: The `0.11 → 0.12` compatibility posture is a documented clean break.
  Rationale: Repo evidence shows no production data can exist: keiro-migrations
  0.11.0.0 predates the tables (its changelog records "No changes this release",
  and migrations 0022/0023 appear only in the unreleased tree); the only in-repo
  registrant is jitsurei, whose database is ephemeral (recreated by
  `just jitsurei-migrate` and the suite-level test templates). The CHANGELOG gets
  an explicit note: catalogs registered by unreleased pre-0.12 snapshots
  re-register cleanly only via the stale-format adoption path
  (`keiro-ops rebuild adopt`), and in-flight rebuild runs must be completed or
  abandoned before upgrading, because the v1 contract fingerprint can never match
  a v2 value.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Everything below is verifiable in the working tree; no prior plan is required
reading. Paths are repository-relative from `/Users/shinzui/Keikaku/bokuno/keiro`.

### The catalog runtime in one paragraph

A **projection catalog** (`ProjectionCatalog` in
`keiro/src/Keiro/Projection/Catalog.hs`) is a closed-world declaration of a
service's read side: **sources** (event feeds with a free-text `codecFingerprint`),
**targets** (application-owned PostgreSQL tables with a reset policy), **rebuild
groups** (ordered sets of targets that move through one destructive-replay
lifecycle together, with application-supplied verification hooks), **projections**
(single owners of targets, with inline/async handlers), **query models** (typed
read contracts with a registry name, integer version, and free-text `shapeHash`),
**subscriptions**, and **dedup keys**. `validateProjectionCatalog` is a pure gate
producing a `ValidatedProjectionCatalog`; only validated catalogs reach
registration, replay, or operations. From the validated catalog,
`catalogInventory` derives a deterministic, sorted `CatalogInventory`, and
`fingerprintInventory` (line ~1512) hashes `renderInventory`'s text with SHA-256 to
produce the `CatalogFingerprint`. The **inventory** is the derived list-of-records
view; the **preimage** is the exact byte string fed to the hash.

### Where the fingerprint gates behavior

`keiro/src/Keiro/ReadModel/Rebuild/Group.hs` owns the durable lifecycle:

- `registerProjectionCatalogTx` (~line 235) runs at service startup (see
  `jitsurei/src/Jitsurei/Database.hs` and the documented pattern in
  `docs/user/read-models-and-projections.md` around line 198: registration failure
  refuses startup). Per catalog group it executes `registerGroupStmt` — an
  `INSERT ... ON CONFLICT (group_id) DO UPDATE SET group_id = EXCLUDED.group_id
  RETURNING ...`, i.e. an insert-or-lock that **never updates**
  `catalog_fingerprint` — and then compares the returned row's fingerprint against
  the current whole-catalog fingerprint, refusing with
  `RegisteredGroupFingerprintDrift` on mismatch. It then reconciles
  `keiro.keiro_read_models` rows (refusing version/shape/group drift with
  `RegisteredQueryModelDrift`), with one adoption carve-out:
  `adoptLegacyQueryRegistrationStmt` moves a live `$legacy-read-model:<name>`
  singleton (created by migration `0022.sql` for pre-catalog read models, with the
  `$legacy-unmanaged` sentinel fingerprint) into a named catalog group. That is the
  **only** adoption path in the codebase.
- `beginGroupRebuild` (~line 324) locks the group row `FOR UPDATE`, refuses
  `RebuildCatalogFingerprintDrift` when the stored fingerprint differs from the
  current catalog's, then — inside the same transaction — truncates
  clear-before-replay targets, deletes dedup rows, and resets subscription
  checkpoints via Kiroku's `resetSubscriptionCheckpointsTx` (the composition
  mandated by
  `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`).
  The returned `GroupRebuildHandle` carries the fingerprint; `finishGroupRebuildTx`
  and `abandonGroupRebuild` require row equality with it, and
  `lockProjectionGroupsTx` is the live-writer **write fence** (status-based, no
  fingerprint comparison).
- `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` drives fixed-head replay.
  `rebuildContract` (~line 745) computes the **resume contract**: a SHA-256 over
  `Text.unlines` of the runner format, the whole-catalog fingerprint, and
  `|`-joined source/adapter/verification lines — the same unescaped join pattern.
  `resumeCatalogRebuild` refuses `CatalogRebuildContractMismatch` when the stored
  `contract_fingerprint` differs. Every chunk transaction (`lockActiveRunStmt`),
  `resumeRunStmt`, and `completionProofStmt` additionally require
  `groups.catalog_fingerprint = runs.catalog_fingerprint` — the run/group epoch
  join.
- `keiro/src/Keiro/ReadModel/Schema.hs` (`ensureLegacyGroupStmt`,
  `transitionLegacyGroupStmt`, ~line 198) writes the `$legacy-unmanaged` sentinel
  for the unmanaged single-read-model compatibility path.

The schema: migration `keiro-migrations/migrations/0022.sql` creates
`keiro.keiro_projection_rebuild_groups` (`group_id TEXT PRIMARY KEY`,
`catalog_fingerprint TEXT NOT NULL`, `status` with CHECK `live|rebuilding|failed`,
run/failure columns) and backfills legacy singletons; `0023.sql` creates
`keiro_projection_rebuild_runs` (with `catalog_fingerprint` and
`contract_fingerprint`), `_sources`, `_adapters`, `_verifications`. The checked-in
schema snapshot is `keiro-migrations/expected-schema/native/keiro-v18.txt`,
embedded by `keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` and regenerated
in place by the migrations test under `KEIRO_REGENERATE_EXPECTED_SCHEMA=1`.

The operator surface: `keiro/src/Keiro/Projection/Catalog/Operations.hs` is the
supported library API (`ProjectionCatalogOperations`, `catalogInventoryReport`,
`previewGroupRebuild`, `previewRegisteredGroupRebuild`, `startGroupRebuild`,
`inspectGroupRebuild`, `resumeGroupRebuild`, `abandonGroupRebuild`), and
`keiro-ops/src/Keiro/Ops/Rebuild.hs` wraps it as the `rebuild
list|preview|start|status|resume|abandon` commands with the preview-then-`--force`
discipline from ADR 0028. Code-dependent commands mount through
`keiro-ops/src/Keiro/Ops/Embed.hs` (`projectionCatalog :: Maybe
ProjectionCatalogOperations`); jitsurei's embedding is `jitsurei/app/Main.hs`.

### Defect A, precisely

`mkIdentity` (Catalog.hs ~line 224) rejects only empty text and surrounding
whitespace; embedded `|`, `,`, `:`, `@`, and newlines are all legal in ids, and the
free-text fields (`codecFingerprint`, `subscriptionName`, `dedupName`,
`registryName`, `shapeHash`, verification id/version) are entirely unvalidated.
`renderInventory` (~line 1521) then joins fields with those same characters. Two
concrete collisions, used as regression fixtures in this plan:

- **Field-boundary shift.** `SourceDeclaration { sourceId = "a", sourceScope =
  AllStreams, codecFingerprint = "$all|c" }` and `SourceDeclaration { sourceId =
  "a|$all", sourceScope = AllStreams, codecFingerprint = "c" }` both render the
  line `source|a|$all|$all|c`. Two single-source catalogs built from them validate
  cleanly and share one `CatalogFingerprint` today.
- **Line forgery.** A `dedupName` containing a newline forges an entire inventory
  line: one catalog with `DedupKeyDeclaration { dedupKeyId = "d", dedupName =
  "x\ndedup|d2|y" }` renders identically to another catalog with the two keys
  `("d", "x")` and `("d2", "y")`.

The same field-boundary shift defeats `rebuildContract`: its `source|id|scope|codec`
lines are rendered identically, so when the colliding sources feed a replayable
projection, two different catalogs produce one resume contract for an interrupted
destructive replay.

### Defect B, precisely

`registerGroupStmt`'s `ON CONFLICT` sets only `group_id`; `beginGroupStmt`,
`finishGroupStmt`, and `abandonGroupStmt` never touch `catalog_fingerprint`. Since
the stored value digests the entire inventory and is stored identically on every
group row, any inventory change — including the purely additive "new read model in
a brand-new group" — invalidates every stored row simultaneously. Registration
refuses (`RegisteredGroupFingerprintDrift` → startup refusal per the documented
pattern), and the rebuild path that might re-establish identity refuses too
(`RebuildCatalogFingerprintDrift`), because it compares against the same stored
value that nothing can update. The existing test
`keiro/test/GroupRebuildSpec.hs` ("registers a validated fleet atomically and
refuses fingerprint drift") demonstrates the refusal with a codec-fingerprint
change; the additive-lockout variant is reproduced in Milestone 1.

An adjacent observation, explicitly **out of scope** here: once
`abandonGroupRebuild` marks a group `failed`, no library path returns it to `live`
(`beginGroupRebuild` requires `GroupLive`, `resumeRunStmt` requires the group to be
`rebuilding`). This is the pre-existing fence-preservation posture of ADR 0026, not
one of the two confirmed defects; it should be raised as its own improvement
request, and nothing in this plan may widen or narrow it.

### Relevant ADRs

- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
  — the catalog identity model this plan amends: it specifies that the inventory
  and fingerprint include identities/versions/policies but never closures, that
  group registration is "idempotent only for the same fingerprint", and that the
  resume contract combines the catalog fingerprint with normalized replay facts.
  This plan changes those mechanics (canonical encoding, slice scoping) while
  preserving every safety property the ADR argues for; the ADR is updated during
  distillation (Milestone 6).
- `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
  — every operator command wraps a supported exported library operation, never ad
  hoc SQL; destructive commands are preview-then-`--force`; missing operator
  primitives are added to the owning library first. This is why the remediation in
  this plan is a library API (`adoptCatalogGroups`) surfaced through keiro-ops, and
  why hand-SQL remediation is not an acceptable fallback.
- `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
  — checkpoint policy is part of catalog identity and must remain inside the
  fingerprint (and therefore inside the group slice), and checkpoint resets stay
  composed inside the preparation transaction. The slice definition below includes
  `checkpointOnMissing` for exactly this reason.

No cross-repository ADR applies beyond Kiroku's checkpoint decision already cited
by ADR 0031 (`mori://shinzui/kiroku/okf/adrs/concepts/ADR-4`); this plan does not
change any Kiroku-owned behavior.

### Test infrastructure you will use

DB-backed keiro tests use the suite-level ephemeral-pg template fixture from
`keiro-test-support/src/Keiro/Test/Postgres.hs`: `withMigratedSuiteWith` starts one
cached PostgreSQL server, migrates a single template database once (Kiroku + Keiro
migrations), and `withFreshStore fixture` clones a fresh database per example via
`CREATE DATABASE ... TEMPLATE ...`. Do **not** invent per-example migration.
`keiro/test/Main.hs` already threads the fixture into `CatalogOperationsSpec.spec
fixture`, `GroupRebuildSpec.spec fixture`, and `ProjectionReplaySpec.spec fixture`
(lines ~391–394); new DB specs join that list and the `keiro.cabal` test-suite
`other-modules`. `keiro-ops/test/Main.hs` uses the same fixture via
`withMigratedSuiteWith [pgmq]`. Catalog fixtures for tests live in
`keiro/test/CatalogSpec.hs` (`validCatalog`, `mainGroupId`, `counterTargetId`,
`catalogAsyncProjection`, ...); a realistic full catalog is
`jitsurei/src/Jitsurei/ReadModels.hs` (`jitsureiProjectionCatalogDefinition`,
~line 200: one category source, three targets with mixed reset policies and
dependencies, one group with a verification hook, one subscription with
`FromBeginning`, one dedup key, one query model).


## Plan of Work

The work is six milestones. M1 is a prototyping milestone (encouraged by the
ExecPlan specification for design-heavy work); M2–M5 are additive, independently
verifiable implementation waves; M6 closes documentation, changelogs, and ADR
distillation. Within one repository release window there is no compatibility
constraint between milestones, but each milestone leaves `cabal build all` and the
existing suites green.

### Milestone 1 — Prototyping: prove both defects and validate the design against the real schema

Scope: throwaway evidence, no shipped behavior change. What exists at the end: the
two Defect A collision fixtures demonstrated failing against the current encoder;
the Defect B additive lockout demonstrated against a real database; the canonical
encoder validated for injectivity; and the slice-scoped lifecycle joins validated
against the real `0022`/`0023` schema so M3's statement changes are not designed
blind.

Work, in a scratch spec file `keiro/test/CanonicalPreimageProbeSpec.hs` (wired
temporarily into `keiro/test/Main.hs` and `keiro.cabal`; deleted or promoted by
M2/M3 — do not leave a probe spec in the tree at plan completion):

1. Build the two collision pairs from "Defect A, precisely" as
   `ProjectionCatalog` values, validate them, and assert the *current* broken
   behavior: `catalogFingerprint a == catalogFingerprint b`. Run, observe pass —
   that is the reproduction. Record the output in Surprises & Discoveries, then
   flip the assertions to `shouldNotBe` and leave them failing locally as the M2
   target (do not commit failing tests; commit the probe with the reproduction
   assertions and a comment naming the M2 flip).
2. Reproduce the additive lockout end to end against `withFreshStore`: register
   `CatalogSpec.validCatalog`; build `additiveCatalog` = `validCatalog` plus one
   new source, target, group, projection set, and query model (no existing
   declaration touched); validate; call `registerProjectionCatalog` and assert it
   currently returns `Left (RegisteredGroupFingerprintDrift ...)` for
   `mainGroupId`; then assert `beginGroupRebuild additiveCatalog mainGroupId ...`
   returns `Left (RebuildCatalogFingerprintDrift ...)`. This is the exact lockout;
   keep this fixture — it becomes acceptance scenario (b) with inverted
   expectations.
3. Prototype the encoder as a self-contained module (the M2 module, written here
   first): the `Preimage` type and `renderPreimage` below, plus an adversarial
   injectivity fixture list (embedded delimiters, digit-prefixed content like
   `"3:abc"`, empty vs. missing fields, `PList [PText "a", PText "b"]` vs
   `PText "ab"` vs `PList [PText "ab"]`, `PRecord "t" []` vs `PText "t"`,
   newline-bearing content) asserted pairwise-distinct after rendering.
4. Validate the slice-join design against the real schema with plain SQL probes in
   the scratch spec (allowed here because it is a probe, not a shipped path):
   register a catalog, hand-`UPDATE` the group row's fingerprint column to a
   sentinel, and confirm which statements refuse (`begin`, `resume`,
   `lockActiveRun`, `completionProof`) — this maps every consumer of the
   `groups.catalog_fingerprint = runs.catalog_fingerprint` join and confirms the
   M3 rename list is complete. Cross-check against the grep inventory: the column
   is consumed in `Group.hs`, `Runner.hs`, `Schema.hs`, migrations `0022`/`0023`,
   and the expected-schema snapshot only.

Acceptance: probe suite passes with the reproduction assertions;
evidence recorded in Surprises & Discoveries. Promotion criteria: encoder
injectivity fixtures all distinct (promote the module as-is in M2); the additive
lockout reproduction runs green (promote the fixture to scenario (b) in M3);
the join map matches the M3 edit list (adjust M3 if not).

### Milestone 2 — Canonical encoding and the slice fingerprint (pure)

Scope: `keiro` library only, no schema or statement changes. What exists at the
end: an injection-proof canonical encoder used by the catalog fingerprint; a new
group-slice fingerprint; version-prefixed fingerprint spellings; pure regression
tests.

1. New module `keiro/src/Keiro/Projection/Catalog/Preimage.hs` (exposed module,
   `{-# OPTIONS_HADDOCK hide #-}` like the other internal-but-exposed modules;
   add to `keiro.cabal` exposed-modules):

   ```haskell
   -- | Canonical, injection-proof preimage encoding for catalog fingerprints.
   data Preimage
     = PText !Text
     | PList ![Preimage]
     | PRecord !Text ![Preimage]

   renderPreimage :: Preimage -> ByteString
   hashPreimage :: Text -> Preimage -> Text  -- prefix, tree -> "prefix:" <> hex sha256
   ```

   Byte-level definition (pin this exactly; tests depend on it):
   `renderPreimage (PText t)` = `"t" <> decimal (byteLength (utf8 t)) <> ":" <>
   utf8 t`; `renderPreimage (PList xs)` = `"l" <> decimal (length xs) <> ":" <>
   concatMap renderPreimage xs`; `renderPreimage (PRecord tag fs)` = `"r" <>
   decimal (byteLength (utf8 tag)) <> ":" <> utf8 tag <> "n" <> decimal (length
   fs) <> ":" <> concatMap renderPreimage fs`. Injectivity argument (include as a
   Haddock note): every node starts with a distinguishing letter, every
   variable-length payload is preceded by its exact byte length or child count, so
   the rendering is a prefix code over trees — two distinct trees first differ at
   some node, where either the letter, the declared length, or the payload bytes
   differ. Implement with `Data.ByteString.Builder`.

2. In `keiro/src/Keiro/Projection/Catalog.hs`, replace `fingerprintInventory`'s
   preimage: build `PRecord "keiro/catalog-inventory/v2"` over seven `PList`s
   (sources, targets, groups, projections, query models, subscriptions, dedup
   keys), each entry a `PRecord` tagged `"source"`/`"target"`/`"group"`/
   `"projection"`/`"query"`/`"subscription"`/`"dedup"` whose fields mirror today's
   renderers one-to-one, in the same order, reusing the existing scalar spellings
   (`renderScope`, `renderReset`, `missingCheckpointPolicyText`, `show` for the
   query version, `"inline"`/`"async"`-tagged handler records instead of
   `:`-joins). Lists of ids (dependsOn, orderedTargets, ownedTargets,
   observedTargets, handlers, verifications) become `PList`s of `PText`/records —
   never joined text. `catalogFingerprintText` now renders as
   `"catalog-v2:" <> hex`. `renderInventory`/`renderCatalogInventory` stay exactly
   as they are (operator rendering; update the module Haddock to say it is not
   the preimage).

3. Add the slice identity to `Keiro/Projection/Catalog.hs`:

   ```haskell
   newtype GroupSliceFingerprint = GroupSliceFingerprint Text  -- "slice-v1:" <> hex
   groupSliceFingerprintText :: GroupSliceFingerprint -> Text
   groupSliceFingerprint ::
     ValidatedProjectionCatalog -> RebuildGroupId -> Maybe GroupSliceFingerprint
   ```

   The slice preimage is `PRecord "keiro/catalog-group-slice/v1"` over: the group
   id; the group's `InventoryGroup` record (ordered targets, verifications); the
   `InventoryTarget` records of its ordered targets (qualified table, reset
   policy, dependsOn ids, owner); the `InventoryProjection` records with
   `rebuildGroupId == group` (already sorted); the `InventorySource` records
   referenced by those projections, sorted by source id (scope, codec
   fingerprint); the `InventoryQueryModel` records bound to the group (registry
   name, version, shape hash, observed targets); the `InventorySubscription` and
   `InventoryDedupKey` records referenced by the group's async handlers, sorted.
   This is exactly the information `previewGroupRebuild` reports — the facts that
   preparation, replay, promotion, and query transitions read. `Nothing` for a
   group id not in the catalog. Export both from the module's export list.

4. Tests (pure, in `keiro/test/CatalogSpec.hs` plus a new
   `keiro/test/PreimageSpec.hs` promoted from the M1 probe):
   the encoder injectivity fixtures; the two collision pairs now
   `shouldNotBe` on `catalogFingerprint`; the source-collision pair embedded in
   two full catalogs (colliding source feeding a replayable projection in
   `mainGroupId`) `shouldNotBe` on `groupSliceFingerprint`; order-insensitivity
   retained (`reverseCatalog` fixture: fingerprint and slice fingerprints equal);
   slice stability (`additiveCatalog` from M1: `groupSliceFingerprint mainGroupId`
   unchanged while `catalogFingerprint` changes); prefix spellings asserted
   (`Text.isPrefixOf "catalog-v2:"`, `"slice-v1:"`).

Note: after this milestone the DB-backed suites still pass — stored fingerprints
are created and compared within each fresh example database, so the new spelling
is self-consistent. Acceptance: `cabal test keiro-test` green with the new
assertions; the M1 collision reproductions now assert distinctness.

### Milestone 3 — Slice-scoped lifecycle: schema, registration, begin, resume, finish (Defect B core)

Scope: migration 0024, `Group.hs`, `Runner.hs`, `Schema.hs`,
`Catalog/Operations.hs` mechanical fields, DB tests for scenarios (b), (c-refusal),
and (d). What exists at the end: additive catalog changes re-register cleanly;
genuine slice drift is still refused everywhere it was before; interrupted replays
resume across unrelated changes and refuse across slice changes.

1. Create the migration with the standard CLI (never hand-name a file):

   ```bash
   cd /Users/shinzui/Keikaku/bokuno/keiro
   cabal run keiro-migrate -- new \
     --manifest keiro-migrations/migrations/manifest \
     --description "projection rebuild slice fingerprints"
   ```

   Content of the generated `0024-...sql`:

   ```sql
   -- Group identity becomes the group's own catalog slice; runs carry the
   -- slice they were begun under for the epoch-consistency joins, while
   -- catalog_fingerprint on runs remains begin-stamped provenance.
   ALTER TABLE keiro.keiro_projection_rebuild_groups
     RENAME COLUMN catalog_fingerprint TO slice_fingerprint;

   ALTER TABLE keiro.keiro_projection_rebuild_runs
     ADD COLUMN group_slice_fingerprint TEXT NOT NULL DEFAULT '$pre-canonical';

   ALTER TABLE keiro.keiro_projection_rebuild_runs
     ALTER COLUMN group_slice_fingerprint DROP DEFAULT;
   ```

   Run `cabal run keiro-migrate -- check keiro-migrations/migrations/manifest`,
   then regenerate the embedded snapshot in place (the file name stays
   `keiro-v18.txt`; the repo convention regenerates content, it does not version
   the filename):

   ```bash
   KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test
   cabal test keiro-migrations-test
   ```

2. `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`:
   - `GroupRebuildMetadata.catalogFingerprint` → `sliceFingerprint :: Text`.
     `GroupRebuildHandle.handleFingerprint` and
     `GroupCompletionToken.completionFingerprint` change type to
     `GroupSliceFingerprint`; `groupRebuildHandleFingerprint` is renamed
     `groupRebuildHandleSliceFingerprint`. `groupRebuildHandleFor` computes the
     handle fingerprint with `groupSliceFingerprint catalog groupId` (its existing
     `Maybe` shape absorbs the lookup).
   - Errors: `RegisteredGroupFingerprintDrift` becomes
     `RegisteredGroupSliceDrift !RebuildGroupId !Text !Text` (stored, current);
     add `RegisteredGroupStaleFingerprint !RebuildGroupId !Text` (stored value
     without the `slice-v1:` prefix and not `$legacy-unmanaged`; the Show/render
     text names `keiro-ops rebuild adopt`). `RebuildCatalogFingerprintDrift`
     becomes `RebuildGroupSliceDrift !RebuildGroupId !Text !Text`.
   - `registerProjectionCatalogTx`: per group, compute the slice fingerprint (the
     catalog's own group — `Maybe` is impossible for inventory groups; `error` on
     `Nothing` is acceptable as an invariant), insert-or-lock via
     `registerGroupStmt` (now inserting `slice_fingerprint`), then classify the
     returned row: equal → continue; `$legacy-unmanaged` → continue only through
     the existing legacy read-model adoption flow (legacy singleton group ids
     never appear in catalog group lists, so this arm is unreachable for catalog
     groups — assert with a comment, not code); no `slice-v1:` prefix →
     `Left RegisteredGroupStaleFingerprint`; otherwise
     `Left RegisteredGroupSliceDrift`. Query reconciliation is unchanged except
     the drift detail text now names the adoption command.
   - `beginGroupRebuild`: the `FOR UPDATE` comparison is now stored
     `slice_fingerprint` vs `groupSliceFingerprintText`; refusal is
     `RebuildGroupSliceDrift`. Everything else (status gate, preparation,
     checkpoint reset, missing-subscription condemnation) is untouched.
   - `finishGroupStmt` / `abandonGroupStmt`: `WHERE ... AND slice_fingerprint = $3`
     with the handle's slice text. `lookupGroupStmt`, `lockGroupForUpdateStmt`,
     `registerGroupStmt`, decoders: column rename only.
     `deleteOrphanLegacyGroupsStmt`: `groups.slice_fingerprint =
     '$legacy-unmanaged'`.
   - `keiro/src/Keiro/ReadModel/Schema.hs`: `ensureLegacyGroupStmt` and
     `transitionLegacyGroupStmt` write the sentinel into `slice_fingerprint`
     (mechanical).

3. `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`:
   - `runnerFormat = "keiro/projection-replay/v2"`.
   - `rebuildContract :: ValidatedProjectionCatalog -> RebuildGroupId -> Maybe
     Text`, defined as `hashPreimage "contract-v2" (PRecord
     "keiro/projection-replay/v2" [PText (groupSliceFingerprintText slice)])` for
     `Just slice`; callers (`startCatalogRebuild`, `resumeCatalogRebuild`,
     `abandonCatalogRebuild`) map `Nothing` to
     `CatalogRebuildGroupMissing groupId` instead of comparing against an
     empty-list hash.
   - `initializeRunTx` inserts both `catalog_fingerprint` (unchanged provenance:
     the whole-catalog `catalog-v2:` text) and the new
     `group_slice_fingerprint` (the handle's slice text); `insertRunStmt` gains
     the column.
   - `resumeRunStmt`, `lockActiveRunStmt`, `completionProofStmt`: the epoch join
     becomes `groups.slice_fingerprint = runs.group_slice_fingerprint`.
   - `RebuildRunReport` gains `groupSliceFingerprint :: Text` (decoded from the
     new column) and keeps `catalogFingerprint` as provenance;
     `inspectRunStmt`/`runReportDecoder` updated.

4. `keiro/src/Keiro/Projection/Catalog/Operations.hs`: `inspectGroupRebuild`'s
   guard compares the run's `groupSliceFingerprint` against
   `groupSliceFingerprint catalog (run's group)`; the error is renamed
   `CatalogOpsRunSliceMismatch !RebuildRunId !Text !Text`. `RebuildPreview` gains
   `sliceFingerprint :: Text`; `RegisteredRebuildPreview.registeredFingerprintMatches`
   becomes `registeredSliceMatches` comparing slice values. JSON renderers
   (`groupMetadataValue`, `runValue`) emit `slice_fingerprint` /
   `group_slice_fingerprint` keys alongside the retained provenance key.

5. DB tests:
   - Scenario (b), in `keiro/test/GroupRebuildSpec.hs`: promote the M1 additive
     fixture — register `validCatalog`; re-register `additiveCatalog` and assert
     `Right` with both group rows present, `mainGroupId`'s stored
     `sliceFingerprint` unchanged and status `GroupLive`; assert
     `lookupReadModel "catalog-counter-query"` still live and the new query row
     inserted; assert an inline/async write through
     `applyAsyncProjectionFromCatalog` still applies (existing groups keep
     serving; no SQL was run by the operator).
   - Scenario (c) refusal, same file: adapt the existing codec-drift test —
     `registerProjectionCatalog` with the drifted catalog now returns
     `Left (RegisteredGroupSliceDrift ...)`, and `beginGroupRebuild` with it
     returns `Left (RebuildGroupSliceDrift ...)`; the stored row keeps the
     original slice fingerprint.
   - Scenario (d), in `keiro/test/ProjectionReplaySpec.hs`: extend "retains
     committed pages across verification failure and rejects catalog drift on
     resume" into two cases: resume with a slice-changed catalog still returns
     `Left (CatalogRebuildContractMismatch ...)`; and a **new positive case** —
     interrupt a run (existing failure fixture), then resume with
     `additiveCatalog` (unrelated group added) and assert the resume proceeds and
     promotes, proving unrelated evolution no longer strands interrupted replays.

Acceptance: `cabal build all` green; `cabal test keiro-test` and
`cabal test keiro-migrations-test` green including the new cases.

### Milestone 4 — The adoption path (library API)

Scope: `Group.hs` + `Catalog/Operations.hs` + re-exports in
`keiro/src/Keiro/ReadModel/Rebuild.hs`. What exists at the end: a supported,
transactional, preview-then-mutate adoption API — the remediation ADR 0028
requires — plus DB tests for the full changed-slice path and the hypothetical-0.11
stale-format path.

1. In `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`:

   ```haskell
   data GroupAdoptionClass
     = AdoptionNew            -- registered row absent; registration will insert it
     | AdoptionUnchanged      -- stored slice equals the catalog's
     | AdoptionSliceChanged !Text !Text   -- stored, current: requires adoption
     | AdoptionStaleFormat !Text          -- stored value predates slice-v1
     deriving stock (Eq, Show, Generic)

   data CatalogAdoptionPlan = CatalogAdoptionPlan
     { groupStates :: ![(RebuildGroupId, GroupAdoptionClass)],  -- catalog groups, sorted
       removedGroups :: ![RebuildGroupId]  -- registered, non-legacy, absent from catalog
     }

   previewCatalogAdoption ::
     (Store :> es) => ValidatedProjectionCatalog -> Eff es CatalogAdoptionPlan

   data CatalogAdoptionError
     = AdoptGroupNotInCatalog !RebuildGroupId
     | AdoptGroupUnregistered !RebuildGroupId
     | AdoptGroupNotLive !RebuildGroupId !GroupLifecycleStatus !(Maybe RebuildRunId)
     deriving stock (Eq, Show, Generic)

   adoptCatalogGroups ::
     (Store :> es) =>
     ValidatedProjectionCatalog ->
     NonEmpty RebuildGroupId ->
     Eff es (Either CatalogAdoptionError [GroupRebuildMetadata])
   ```

   `previewCatalogAdoption` reads all group rows (new statement `SELECT group_id,
   slice_fingerprint, status, active_run_id FROM
   keiro.keiro_projection_rebuild_groups`), classifies each catalog group, and
   reports registered rows absent from the catalog — excluding rows whose stored
   value is `$legacy-unmanaged` (they belong to the legacy compatibility path and
   its orphan-delete). It is read-only.

   `adoptCatalogGroups` runs one transaction: for each named group (deduplicated,
   sorted — same lock-order discipline as `lockProjectionGroupsTx`), lock the row
   `FOR UPDATE`; refuse if unregistered or not `live`; update `slice_fingerprint`
   to the catalog's current slice text (adopting an unchanged group is a
   reported no-op, not an error — ADR 0028 requires idempotent no-ops to be
   outcomes); then reconcile the `keiro.keiro_read_models` rows bound to the
   group: for each catalog registration whose `rebuildGroupId` is a named group,
   update `version`, `shape_hash`, and `rebuild_group_id` to catalog values (new
   statement mirroring `adoptLegacyQueryRegistrationStmt`, extended to version
   and shape). Any refusal condemns the whole transaction. Return the updated
   metadata rows. A query model moving between groups is handled by naming both
   groups in one call, which the error on a half-named move makes discoverable
   (the source group's slice changed too, so registration keeps refusing until
   both are adopted).

2. Re-export the adoption surface from `keiro/src/Keiro/ReadModel/Rebuild.hs`, and
   wrap it in `keiro/src/Keiro/Projection/Catalog/Operations.hs` with report
   types following the module's existing style:
   `CatalogAdoptionReport { reportSchema = "keiro/catalog-adoption-preview/v1", ... }`
   with Aeson instances, plus
   `previewCatalogAdoption :: ProjectionCatalogOperations -> Eff es CatalogAdoptionReport`
   and
   `adoptCatalogGroups :: ProjectionCatalogOperations -> NonEmpty RebuildGroupId -> Eff es (Either CatalogOpsError CatalogAdoptionOutcome)`
   (map `CatalogAdoptionError` into `CatalogOpsError` with a new
   `CatalogOpsAdoptionRefused` constructor).

3. DB tests, in a new `keiro/test/CatalogEvolutionSpec.hs` (wired into
   `keiro/test/Main.hs` beside the other fixture specs and into `keiro.cabal`):
   - Scenario (c), full path: register `validCatalog`; build `changedCatalog`
     (codec fingerprint bump — the same fixture as the M3 refusal test); assert
     registration and begin both refuse; `previewCatalogAdoption` classifies
     `mainGroupId` as `AdoptionSliceChanged` with the exact stored/current texts;
     `adoptCatalogGroups changedCatalog (mainGroupId :| [])` returns `Right` with
     the updated slice; re-registration now succeeds; `beginGroupRebuild` now
     succeeds and a subsequent `startCatalogRebuild`/promotion completes (reuse
     the zero-event rebuild pattern from
     `keiro/test/CatalogOperationsSpec.hs` "keeps registered preview read-only
     and starts a zero-event rebuild from catalog facts").
   - Query-model reconciliation: `changedCatalog` variant bumping the read
     model's `version`/`shapeHash`; after adoption, the
     `keiro.keiro_read_models` row carries the new values and registration
     succeeds.
   - Refusals: adopting an unregistered group id; adopting while `rebuilding`
     (begin a rebuild first) → `AdoptGroupNotLive`, transaction condemned,
     nothing changed.
   - Stale format (hypothetical 0.11 database): register `validCatalog`, then
     simulate a pre-canonical row with test SQL
     (`UPDATE keiro.keiro_projection_rebuild_groups SET slice_fingerprint =
     '<64 hex chars>' WHERE group_id = 'counter-group'` — test fixture SQL, not a
     shipped path); assert registration refuses with
     `RegisteredGroupStaleFingerprint`; preview classifies `AdoptionStaleFormat`;
     adoption succeeds; registration succeeds. This test is the executable form
     of the CHANGELOG's upgrade note.

Acceptance: `cabal test keiro-test` green including the new spec.

### Milestone 5 — keiro-ops `rebuild adopt`

Scope: `keiro-ops/src/Keiro/Ops/Rebuild.hs` and `keiro-ops/test/Main.hs`. What
exists at the end: the operator remediation surface, mirroring the existing
command patterns exactly.

1. Extend `Command` with `Adopt !AdoptOptions` where
   `AdoptOptions = { groups :: NonEmpty RebuildGroupId }` parsed from one or more
   `GROUP` arguments (`some1`/`NE.fromList` over `groupArgument`); subcommand help:
   "Preview or adopt catalog slice changes for the named groups". `isMutation
   (Adopt _) = True`. Without `--force`: call the `previewCatalogAdoption`
   wrapper, render one row per catalog group (`group`, `state`
   (`new`/`unchanged`/`slice-changed`/`stale-format`), `stored_slice`,
   `current_slice`) plus removed groups, and return `PreviewRequired` with the
   exact re-invocation via the existing `forceInvocation` helper. With `--force`:
   call `adoptCatalogGroups` and render the updated metadata (idempotent no-ops
   included). The preview's human output must state that adoption changes only
   keiro-owned registration metadata and that a `rebuild start` is required
   separately if the change invalidates persisted rows.
2. Update `inventoryResult` and `registeredPreviewResult` to include
   `slice_fingerprint` and the renamed `registeredSliceMatches`.
3. Tests in `keiro-ops/test/Main.hs`: parse tests (`rebuild adopt` refused without
   a mounted catalog, accepted with `embeddedHooks`, mirroring the existing
   `rebuild list` cases at ~lines 110–116); a fixture-backed outcome test:
   register a catalog through the mounted operations, mutate it, run the command
   handler without force and assert `PreviewRequired` whose rendered rows show
   `slice-changed` and whose force invocation round-trips through the parser;
   run with force and assert `Succeeded` plus a subsequent successful
   registration. Follow the suite's existing JSON-assertion style so `--json`
   output is covered.

Acceptance: `cabal test keiro-ops-test` green; acceptance scenario (e) — the
transcript in Validation and Acceptance — reproducible.

### Milestone 6 — Documentation, changelogs, ADR distillation, full verify

1. `docs/user/read-models-and-projections.md`: rewrite the registration paragraph
   (~lines 198–213) to describe slice-scoped identity, the additive-change
   behavior, and the adoption flow (deploy → typed startup refusal → `keiro-ops
   rebuild adopt` preview/force → restart → optional `rebuild start`). Update
   `docs/user/api-reference.md` where it names the renamed types.
2. Changelogs: `keiro/CHANGELOG.md` (Breaking: canonical `catalog-v2` fingerprints
   and `slice-v1` group identity — every fingerprint changes; renamed
   constructors/fields; runner format v2; Added: slice fingerprints, adoption API;
   the clean-break upgrade note from the Decision Log, including "complete or
   abandon in-flight rebuild runs before upgrading");
   `keiro-migrations/CHANGELOG.md` (migration 0024 — and add the missing
   0022/0023 entries noticed during research); `keiro-ops/CHANGELOG.md`
   (`rebuild adopt`, renamed JSON keys).
3. ADR distillation per the exec-plan specification: create a new ADR in
   `docs/adr/` — "Catalog fingerprints are canonically encoded and group identity
   is slice-scoped" — recording the encoding, the slice definition, the
   refresh/adoption policy, and the rejected alternatives (escaping; whole-catalog
   refresh; adopt-on-begin), following the bundle's frontmatter profile
   (`docs/adr/profile.dhall`, next free docId); update
   `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`'s
   fingerprint and "idempotent only for the same fingerprint" language to point at
   it. Run `just adr-validate`.
4. Full gate: `just verify` from the repository root. Update the masterplan's
   Progress rows for EP-1 and note for EP-6 (plan 242) that `Runner.hs` changed
   under it and the contract computation must not be altered by its paging work.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.
The database-backed suites need no running PostgreSQL — the ephemeral-pg fixture
starts its own cached server.

Build everything and run the focused suites while iterating:

```bash
cabal build all
cabal test keiro-test --test-option=--match --test-option='Keiro.Projection.Catalog'
cabal test keiro-test --test-option=--match --test-option='catalog'
cabal test keiro-ops-test
cabal test keiro-migrations-test
```

Expected shape of a passing focused run (hspec summary; counts will differ):

```text
Finished in 42.10 seconds
118 examples, 0 failures
Test suite keiro-test: PASS
```

Milestone 1 reproduction evidence (before the fix, the collision probe passes with
equality assertions; after M2 the flipped assertions pass):

```text
catalog fingerprint preimage (probe)
  two boundary-shifted sources share one fingerprint [✔]
  a newline-bearing dedup name forges a second inventory line [✔]
catalog evolution (probe)
  an additive catalog change locks out registration and rebuild [✔]
```

Milestone 3 migration authoring and schema snapshot regeneration:

```bash
cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "projection rebuild slice fingerprints"
cabal run keiro-migrate -- check keiro-migrations/migrations/manifest
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test
cabal test keiro-migrations-test
git diff --stat keiro-migrations/
```

The regeneration run prints:

```text
regenerated keiro-migrations/expected-schema/native/keiro-v18.txt
```

and the diff must show exactly: the new migration file, the manifest append, the
snapshot's `keiro_projection_rebuild_groups.slice_fingerprint` /
`keiro_projection_rebuild_runs.group_slice_fingerprint` lines, and the changelog.

Final gate and documentation validation:

```bash
just adr-validate
just verify
```

`just verify` runs process-compose checks, the jitsurei demo suite, `cabal build
all`, every Haskell test suite, OKF validation, and the migrations test; it must
end with every step succeeding. The jitsurei demo (`just jitsurei`) doubles as an
end-to-end smoke test of registration with a realistic catalog against a real
database.

Commit after each milestone with conventional-commit messages, for example:

```text
feat(catalog)!: canonicalize fingerprint preimages with length-prefixed encoding
feat(rebuild)!: scope group identity to catalog slices and stamp runs
feat(rebuild): add previewCatalogAdoption and adoptCatalogGroups
feat(keiro-ops): add rebuild adopt with preview-then-force
docs(adr): record canonical catalog identity and slice-scoped evolution
```


## Validation and Acceptance

Acceptance is behavioral. Each scenario names the suite that encodes it; all are
exercised by the commands in Concrete Steps.

- **(a) Collision fixtures yield distinct fingerprints.** In
  `keiro/test/CatalogSpec.hs` / `keiro/test/PreimageSpec.hs`: the
  boundary-shifted source pair and the newline dedup pair — both of which hash
  identically before this plan — now satisfy `catalogFingerprint a `shouldNotBe`
  catalogFingerprint b`, and the source pair embedded in full catalogs yields
  distinct `groupSliceFingerprint`s for the group they feed. The encoder's
  adversarial fixture list renders pairwise-distinct bytes. Failure mode to
  recognize: if any pair compares equal, the canonical encoding has a hole; do
  not weaken the fixture.
- **(b) Additive evolution registers cleanly.** In
  `keiro/test/GroupRebuildSpec.hs`: register a catalog, re-register it plus a new
  source/target/group/projection/query model; expect `Right` (before this plan:
  `Left (RegisteredGroupFingerprintDrift ...)`), the pre-existing group row
  unchanged (`sliceFingerprint`, `GroupLive`), the pre-existing query model still
  served by `lookupReadModel`, a live write still applying, and no operator SQL
  anywhere in the path.
- **(c) Slice change is refused until explicit adoption.** In
  `keiro/test/GroupRebuildSpec.hs` and `keiro/test/CatalogEvolutionSpec.hs`: a
  codec-fingerprint (or query shape) change produces
  `Left (RegisteredGroupSliceDrift ...)` at registration and
  `Left (RebuildGroupSliceDrift ...)` at begin; after
  `adoptCatalogGroups` (preceded by a preview classifying the group
  `AdoptionSliceChanged`), registration and begin succeed and a rebuild promotes.
  Adoption refuses non-live groups and condemns atomically.
- **(d) Resume: still refuses genuine drift, no longer refuses unrelated
  change.** In `keiro/test/ProjectionReplaySpec.hs`: an interrupted run resumed
  with a slice-changed catalog returns
  `Left (CatalogRebuildContractMismatch ...)`; the same interrupted run resumed
  with an additive-only catalog proceeds and promotes.
- **(e) keiro-ops previews the adoption.** In `keiro-ops/test/Main.hs`: `rebuild
  adopt GROUP` without `--force` returns `PreviewRequired` whose table names the
  group, its classification, and both slice fingerprints, and whose printed
  re-invocation is the exact force command; with `--force` it reports the adopted
  rows; the standalone binary (no mounted catalog) refuses the subcommand at
  parse time. Human-visible transcript to reproduce manually from an embedding
  binary such as jitsurei's:

  ```text
  $ jitsurei ops rebuild adopt order-reporting
  group            state          stored_slice        current_slice
  order-reporting  slice-changed  slice-v1:9f2c…      slice-v1:47ab…
  adoption changes only keiro-owned registration metadata; run 'rebuild start'
  if the change invalidates persisted rows
  re-run to apply: 'keiro-ops' 'rebuild' 'adopt' 'order-reporting' '--force'
  ```

- **Regression floor.** The entire pre-existing behavior matrix stays green:
  same-fingerprint idempotent registration, legacy `$legacy-read-model` adoption
  and orphan deletion, mixed preserve/clear preparation with checkpoint resets
  and missing-subscription condemnation, the write fence under concurrent
  writers, promotion completion proofs. Command: `cabal test keiro-test`,
  `cabal test keiro-ops-test`, `cabal test keiro-migrations-test`, then
  `just verify`.


## Idempotence and Recovery

Every step is safe to repeat. Milestones are additive and each leaves the tree
buildable and green; re-running any test command is free. The migration is
forward-only and runs once per database; `pg-migrate` records it in the ledger and
reports it as already applied on re-run — never edit `0022.sql`/`0023.sql` or a
shipped migration; corrections are new forward migrations (repository rule in
`keiro-migrations/README.md`). The expected-schema regeneration writes the file in
place; if it captures drift you did not intend, `git checkout --
keiro-migrations/expected-schema` and re-run. Test databases are per-example
clones dropped automatically, so a failing DB test never leaves state behind.

Runtime recovery properties being built are themselves idempotent:
`registerProjectionCatalog` with an unchanged catalog remains a no-op;
`adoptCatalogGroups` on an already-adopted group reports a no-op outcome; a
half-failed adoption condemns its transaction, leaving rows untouched. If M3 lands
and a defect is found before M4, the tree is strictly safer than before (canonical
encoding, slice scoping) with the old remediation gap — acceptable mid-plan but
not releasable: the 0.12.0.0 tag requires M1–M6 complete, because the masterplan's
atomicity argument (encoding change without adoption path = self-inflicted
lockout) applies to the release, not to intermediate commits in this repository
whose only deployment (jitsurei, test templates) is recreated from migrations.


## Interfaces and Dependencies

No new package dependencies: SHA-256 and Base16 come from the already-used
`cryptohash-sha256` and `base16-bytestring`; the encoder uses `bytestring`'s
`Data.ByteString.Builder`. All work is in the existing packages `keiro`,
`keiro-migrations`, `keiro-ops` (plus tests and docs); `keiro-dsl` and `jitsurei`
need no code change (jitsurei re-registers cleanly because its database is
recreated by migration).

End-state signatures per module (names are normative; milestones note when each
must exist):

`Keiro.Projection.Catalog.Preimage` (new, M2):

```haskell
data Preimage = PText !Text | PList ![Preimage] | PRecord !Text ![Preimage]
renderPreimage :: Preimage -> ByteString
hashPreimage :: Text -> Preimage -> Text
```

`Keiro.Projection.Catalog` (M2): existing surface unchanged except
`catalogFingerprintText` now yields `"catalog-v2:" <> hex`, plus:

```haskell
newtype GroupSliceFingerprint  -- Eq, Ord, Show
groupSliceFingerprintText :: GroupSliceFingerprint -> Text   -- "slice-v1:" <> hex
groupSliceFingerprint ::
  ValidatedProjectionCatalog -> RebuildGroupId -> Maybe GroupSliceFingerprint
```

`Keiro.ReadModel.Rebuild.Group` (M3/M4), re-exported through
`Keiro.ReadModel.Rebuild`:

```haskell
data CatalogRegistrationError
  = RegisteredGroupSliceDrift !RebuildGroupId !Text !Text
  | RegisteredGroupStaleFingerprint !RebuildGroupId !Text
  | RegisteredQueryModelDrift !Text !Text
  | RegisteredQueryModelNotLive !Text

data RebuildStartError
  = RebuildGroupNotInCatalog !RebuildGroupId
  | RebuildGroupUnregistered !RebuildGroupId
  | RebuildGroupSliceDrift !RebuildGroupId !Text !Text
  | RebuildGroupNotLive !RebuildGroupId !GroupLifecycleStatus !(Maybe RebuildRunId)
  | RebuildSubscriptionCheckpointsMissing !RebuildGroupId ![SubscriptionName]

-- GroupRebuildMetadata: catalogFingerprint renamed sliceFingerprint :: Text
-- GroupRebuildHandle / GroupCompletionToken carry GroupSliceFingerprint
groupRebuildHandleSliceFingerprint :: GroupRebuildHandle -> GroupSliceFingerprint

data GroupAdoptionClass
  = AdoptionNew | AdoptionUnchanged
  | AdoptionSliceChanged !Text !Text | AdoptionStaleFormat !Text
data CatalogAdoptionPlan = CatalogAdoptionPlan
  { groupStates :: ![(RebuildGroupId, GroupAdoptionClass)],
    removedGroups :: ![RebuildGroupId] }
data CatalogAdoptionError
  = AdoptGroupNotInCatalog !RebuildGroupId
  | AdoptGroupUnregistered !RebuildGroupId
  | AdoptGroupNotLive !RebuildGroupId !GroupLifecycleStatus !(Maybe RebuildRunId)

previewCatalogAdoption ::
  (Store :> es) => ValidatedProjectionCatalog -> Eff es CatalogAdoptionPlan
adoptCatalogGroups ::
  (Store :> es) =>
  ValidatedProjectionCatalog -> NonEmpty RebuildGroupId ->
  Eff es (Either CatalogAdoptionError [GroupRebuildMetadata])
```

`Keiro.ReadModel.Rebuild.Runner` (M3): `RebuildRunReport` gains
`groupSliceFingerprint :: Text`; `rebuildContract` becomes `Maybe Text`
(module-local); `runnerFormat = "keiro/projection-replay/v2"`.

`Keiro.Projection.Catalog.Operations` (M3/M4): `RebuildPreview.sliceFingerprint`,
`RegisteredRebuildPreview.registeredSliceMatches`, `CatalogOpsError` gains
`CatalogOpsRunSliceMismatch` and `CatalogOpsAdoptionRefused`, plus the
report-typed `previewCatalogAdoption` / `adoptCatalogGroups` wrappers with
`reportSchema = "keiro/catalog-adoption-preview/v1"` /
`"keiro/catalog-adoption-outcome/v1"`.

`Keiro.Ops.Rebuild` (M5): `Command` gains `Adopt !AdoptOptions`,
`AdoptOptions { groups :: NonEmpty RebuildGroupId }`; `isMutation (Adopt _) = True`.

Schema (M3, migration `0024`): `keiro.keiro_projection_rebuild_groups.
slice_fingerprint` (renamed), `keiro.keiro_projection_rebuild_runs.
group_slice_fingerprint` (added; `catalog_fingerprint` retained as provenance).

Coordination: this plan owns the canonical encoding in both `renderInventory`'s
successor (the inventory preimage) and `rebuildContract`, per the masterplan's
integration notes; plan 242 (EP-6) later edits `Runner.hs` for paging and must not
alter the contract computation; plan 242's soft dependency on this plan is a
rebase-order preference only.
