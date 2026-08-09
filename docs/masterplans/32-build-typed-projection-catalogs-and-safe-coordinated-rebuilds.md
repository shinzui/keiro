---
id: 32
slug: build-typed-projection-catalogs-and-safe-coordinated-rebuilds
title: "Build typed projection catalogs and safe coordinated rebuilds"
kind: master-plan
created_at: 2026-08-07T23:36:45Z
intention: "intention_01kzf95908e14b29bxjb4yhfe0"
---

# Build typed projection catalogs and safe coordinated rebuilds

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

After this initiative, a Keiro application describes each projection fleet once as a
validated typed catalog. The catalog connects typed event sources, live inline or
asynchronous apply behavior, replay behavior, physical PostgreSQL targets, logical query
models, atomic rebuild groups, subscription and dedup identities, and reset policy. A
successful validation produces typed per-source projection views for ordinary command
application and an existential fleet view for registration, replay, and operations. A
missing owner, duplicate claim, unknown identity, dependency cycle, cross-group writer, or
unsafe replay combination fails deterministically before any startup registration or
rebuild effect occurs.

Operators gain a supported offline rebuild for both inline and async projections. Keiro
fences live writers at the group boundary, prepares every foreign-key-related target in
one transaction, preserves reconcile-only brownfield tables, captures fixed replay heads,
applies relevant events in global-position order, persists resumable progress and catalog
fingerprints, verifies the result, and promotes the whole group atomically. Dry-run output
comes from the same catalog that drives execution. A zero-apply replay succeeds only when
all sources reached their captured heads and no relevant event existed; one arbitrary dedup
row is no longer treated as proof that every projection ran.

The runtime API remains additive while adoption is proven. Existing
`InlineProjection`, `AsyncProjection`, `ReadModel`, and low-level rebuild call sites keep a
documented bridge. `keiro-dsl` then generates the runtime declarations and classifies
ownership, target, group, source, and policy evolution. `jitsurei`, the user guides, and the
pending embeddable `keiro-ops` surface adopt the catalog last. The accepted request is
[IR-20](../improvement-requests/make-projection-ownership-and-rebuild-catalogs-one-typed-declaration.md).

Application schemas, migrations, DDL, row codecs, and SQL handler bodies remain
application-owned. Keiro may migrate only its registry and rebuild-progress tables. Static
or runtime proof that an unrestricted `Hasql.Transaction.Transaction` writes only declared
targets is explicitly out of scope, as are implicit application-table creation, online
shadow-table cutover, dynamic plugin discovery, and replaying external side effects. A
future target-scoped SQL capability or online rebuild mode may build on the catalog without
being claimed by this initiative.


## Decomposition Strategy

Five child plans separate the stable declarations from their effectful consumers.

EP-1 (plan 209) defines the pure runtime vocabulary and validation boundary. It separates
logical query models, physical targets, rebuild groups, projection definitions, target reset
policy, and projection replay policy; builds typed source views and existential fleet
entries; validates all identities and ownership claims; and renders a deterministic
inventory. That plan is independently useful before any database behavior changes: a
consumer can construct a catalog, observe its inventory, and mutation-test every structural
diagnostic while continuing to execute projections through the compatibility bridge.

EP-2 (plan 210) makes rebuild groups the actual database lifecycle and writer-fencing unit.
It implements atomic multi-target preparation, valid mixed clear/preserve policy,
group-level registration and liveness, inline and async fencing, derived dedup/checkpoint
resets, atomic abandon/promotion, and the migration from the current one-read-model fence.
This is separated from history scanning because concurrency and SQL lifecycle correctness
can be proved with a small controlled replay body.

EP-3 (plan 211) supplies the history runner: source-owned decoding, relevance, immutable
captured heads, global-position ordering across sources, bounded transactional pages,
durable fingerprints and progress, crash resume, per-source and per-adapter completion,
verification, and failed-run evidence. It absorbs and supersedes the unimplemented
[plan 162](../plans/162-rebuild-inline-projections-deterministically-from-event-history.md),
retaining that plan's valuable inline fence, fixed range, decode failure, and resumability
requirements while generalizing them to catalogued groups and async projections.

EP-4 (plan 212) changes `keiro-dsl` only after the runtime types and replay contract are
stable. It extends checked read-model/projection notation, generates catalog and typed
source views, compiles them in conformance packages, persists catalog evolution facts, and
classifies target, ownership, policy, source, group, and ordering changes through the
existing diff and replay-impact machinery.

EP-5 (plan 213) proves adoption. It migrates `jitsurei` and an explicit multi-table
brownfield fixture, writes the compatibility/migration guide, exposes inventory and rebuild
actions through the application embedding boundary, and reconciles the rebuild hook in
[plan 208](../plans/208-make-keiro-ops-embeddable-and-document-the-operational-surface.md).
It soft-depends on EP-4 because hand-written runtime adoption and ops integration can proceed
without DSL generation, while the final docs should describe both paths when available.

One giant implementation plan was rejected because pure validation, database locking,
history replay, language evolution, and operator adoption have distinct failure modes and
test infrastructure. A DSL-first approach was rejected because generated code must consume,
not define, runtime semantics. Extending `ReadModel q r` with target lists was rejected
because a query contract, a physical table, and an atomic lifecycle group are different
identities; Mori's fabricated `ReadModel () ()` values demonstrate the cost of conflating
them. Copying Mori's catalog records verbatim was rejected because its application-specific
lists and replay adapters are evidence for the abstraction, not a reusable typed API.

Relevant local decisions are
[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md),
which requires single-catalog validation, cross-version diff, and runtime assembly to remain
independent gates;
[ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md),
which keeps framework migration verification distinct from application schema ownership; and
[ADR 20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md),
which requires generated service conformance to consume one runtime-owned facade rather than
restating application inventories. The motivating cross-repository decision is
`mori://shinzui/mori/okf/adrs/concepts/ADR-20`, which requires one owner per live
read-model table and preserve-in-place replay for incomplete brownfield history. The current
registry cannot yet resolve that artifact kind, but the canonical handle and producing record
are established in Mori. No local ADR yet defines projection target ownership, rebuild-group
identity, or the arbitrary-SQL proof boundary; EP-1 must create that durable record and later
plans must amend it if implementation changes the contract.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Define and validate the typed projection catalog runtime contract | docs/plans/209-define-and-validate-the-typed-projection-catalog-runtime-contract.md | None | None | Complete |
| 2 | Coordinate projection target groups, fencing, and rebuild policies | docs/plans/210-coordinate-projection-target-groups-fencing-and-rebuild-policies.md | EP-1 | None | Complete |
| 3 | Replay catalogued projections deterministically and resumably | docs/plans/211-replay-catalogued-projections-deterministically-and-resumably.md | EP-1, EP-2 | None | Complete |
| 4 | Generate projection catalogs from keiro-dsl and classify their evolution | docs/plans/212-generate-projection-catalogs-from-keiro-dsl-and-classify-their-evolution.md | EP-1, EP-3 | None | Complete |
| 5 | Adopt projection catalogs in operations, examples, and migration guidance | docs/plans/213-adopt-projection-catalogs-in-operations-examples-and-migration-guidance.md | EP-3 | EP-4 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 has no hard dependencies. It adds a pure catalog and adapters around the current public
types, so it can land without a database migration or replay runner.

EP-2 hard-depends on EP-1 because group identity, target reset policy, projection replay
policy, and the validated catalog are the inputs to every lifecycle operation. It must not
invent parallel records in `Keiro.ReadModel.Rebuild`.

EP-3 hard-depends on EP-1 and EP-2. History replay requires the typed/existential source
descriptions from EP-1 and the fenced group start, abandon, and atomic promotion operations
from EP-2. Implementing a scanner before the fence exists would reproduce plan 162's unsafe
interleaving gap. It has a non-blocking dependency-side companion in
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1`, which requests a cheap public
global head and SQL-bounded fan-in pages. EP-3 must still ship against the verified released
Kiroku surface; a later bounded API replaces its compatibility reader only when available.

EP-4 hard-depends on EP-1 and EP-3. Generated values must target the stable runtime
constructors, and generated rebuild helpers must call the completed runner rather than emit
another temporary projection-name list. EP-4 may begin its grammar/diff design once EP-1's
types are frozen, but it cannot merge until EP-3 fixes the final replay and fingerprint
surface.

EP-5 hard-depends on EP-3 because an example or operator command cannot advertise catalog
rebuilds until execution is safe. It soft-depends on EP-4: hand-written catalogs and
`keiro-ops` integration can be implemented in parallel with DSL generation, but the final
migration guide, generated example, and documentation sweep should reconcile with EP-4.
After EP-3, EP-4 and the runtime/ops portion of EP-5 can proceed concurrently.
EP-5 also has an external integration gate on repository-local plan 208: its runtime adapter,
examples, and documentation can land first, but the operator-command checklist and this
MasterPlan cannot be marked complete until `keiro-ops` exists and mounts that adapter.


## Integration Points

The catalog modules are shared by every child plan. EP-1 owns the public modules
`keiro/src/Keiro/Projection/Catalog.hs` and, if separation improves readability,
`keiro/src/Keiro/Projection/Catalog/Validate.hs`. It owns identity newtypes, target and
group declarations, typed source views, existential entries, deterministic diagnostics,
catalog fingerprints, inventory values, and compatibility adapters. EP-2 and EP-3 extend
behavior in `Keiro.ReadModel.Rebuild` or subordinate modules but consume EP-1's types
unchanged. EP-4 generates those constructors; EP-5 presents their inventory.

`InlineProjection`, `AsyncProjection`, and normal command application are shared by EP-1,
EP-2, and EP-3. EP-1 defines catalog-to-typed-view selection. EP-2 owns the group fence and
typed fenced outcomes inside the existing write transaction. EP-3 owns only the explicitly
unfenced replay capability and may not create another live application path. Existing
constructors remain available as an unmanaged compatibility boundary until EP-5 documents
their migration.

`ReadModel q r`, physical targets, and registry state are shared by EP-1 and EP-2. EP-1
defines a query-model-to-group binding without putting target lists into `ReadModel` itself.
EP-2 owns any evolution of `keiro.keiro_read_models` or new group registry table and the
queries that validate liveness. Application target tables never enter Keiro migrations.

Keiro-owned database migrations are shared by EP-2 and EP-3. EP-2 owns the group lifecycle
schema and its native/legacy migration, manifest, lock, and expected-schema updates. EP-3
owns rebuild-run, captured-head, fingerprint, and progress persistence, extending EP-2's
schema in a later migration rather than editing a released migration. Both must follow
[ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md).

Replay source ordering is shared by EP-1 and EP-3. EP-1 represents `AllStreams` and category
sources, source-owned codecs, explicit relevance/decoders, and whether several sources may
feed a group. EP-3 defines the only accepted completion algorithm: captured exclusive-start
and inclusive-target bounds, global-position merge across distinct category sources, rejection
of redundant `$all`/category overlap, per-adapter participation, and verification. EP-4 mirrors
these facts but does not redefine them. The event-store-side range primitive is requested by
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1`; Keiro owns multi-category merge,
projection progress, and completion regardless of which Kiroku read implementation is selected.

The Keiro DSL semantic graph, scaffolder, diff, replay-impact report, scaffold ledger, and
service conformance facade are owned by EP-4. It extends
`keiro-dsl/src/Keiro/Dsl/Grammar.hs`, validation, scaffold generation, and report schemas.
EP-5 consumes generated output in examples but must not hand-edit generated modules or add a
second example-only catalog.

The operator embedding boundary is shared with external MasterPlan 31. EP-5 owns the
projection-catalog adapter and inventory/rebuild command behavior. Existing plan 208 retains
the `keiro-ops` command tree, hooks for workflows and replay audit, rendering, preview,
`--force`, and JSON contracts. Whichever initiative implements second must reconcile
`AppHooks`. Its previously proposed `Map Text (OpsEnv -> IO ExitCode)` rebuild map has been
removed from the plan; the command stays absent until a validated catalog view is available.

Cross-plan decisions requiring durable ADR treatment are the four-identity separation,
group-level fence and atomic promotion, reset-policy versus replay-policy split, captured-head
completion proof, arbitrary-SQL proof boundary, and continued consumer ownership of
application schema. EP-1 creates the initial ADR; EP-2 and EP-3 amend it in the same changes
if implementation changes those decisions.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: public catalog vocabulary, typed/existential views, compatibility bridge, and ADR.
- [x] EP-1: deterministic closed-world validation, fingerprints, inventories, and live mutation tests.
- [x] EP-2: group registry and atomic clear/preserve preparation with derived dedup/checkpoint resets.
- [x] EP-2: inline and async group fencing, atomic promotion/abandonment, policy/concurrency evidence.
- [x] EP-3: fixed-head ordered replay with total decode/relevance results and bounded transactions.
- [x] EP-3: durable fingerprint/progress resume, completion proof, verification, and failure evidence.
- [x] EP-4: checked DSL notation and generated runtime catalog/source views compile in conformance.
- [x] EP-4: diff, replay-impact, scaffold-ledger, and workspace evolution classifications are complete.
- [x] EP-5: hand-written and generated adoption examples, compatibility migration guide, and docs.
- [x] EP-5: catalog-backed operator inventory/rebuild integration reconciles with MasterPlan 31.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-08-07: Kiroku's released public surface provides global-position-ordered
  `readAllForward` and `readCategory` vectors with exclusive cursors, but no streaming helper for
  either fan-in read. EP-3 therefore owns explicit bounded paging and a k-way category merge; it
  does not depend on an imagined streaming API.
- 2026-08-08: Kiroku already has an internal `currentGlobalPositionStmt`, but its public Store
  effect exposes neither that cheap head nor an inclusive upper bound on fan-in pages. Filed
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1` for those reusable primitives.
  The request is deliberately non-blocking because the released vector reads are sufficient for
  a Keiro compatibility reader.
- 2026-08-07: `keiro-ops` does not yet exist in the worktree because MasterPlan 31's package plan
  has not landed. EP-5 can prove the runtime adapter and jitsurei adoption after EP-3, but its
  command integration is an explicit external gate on plan 208.
- 2026-08-07: The local Mori corpus contains the motivating plan and ADR, but the current registry
  cannot resolve those artifact kinds. The documents retain their intended canonical handles
  instead of replacing them with cross-repository file paths.
- 2026-08-08: The existing async dedup store is keyed by the physical
  `AsyncProjection.name`, not by subscription or query-model identity. EP-1 therefore keeps
  those logical IDs separate and validates the compatibility bridge; EP-2 can move lifecycle
  state to group identity without silently changing current dedup semantics.
- 2026-08-08: PostgreSQL shared group-row locks give a clean serialization
  boundary for both command-backed inline writes and async dedup/application.
  One-second held-writer fixtures showed preparation beginning 200 ms later
  waits beyond 500 ms, while later writers return typed fenced outcomes without
  append, dedup, checkpoint, or target changes.
- 2026-08-08: Kiroku 0.3.1.0 remains the current Hackage/upstream release, so EP-3 shipped against
  the existing `>=0.3 && <0.4` bound. Its released exclusive-cursor reads were sufficient behind
  one compatibility layer; the Kiroku IR remains an optimization rather than a prerequisite.
- 2026-08-08: Atomic page/progress rollback and committed-page resume were demonstrated without a
  process-kill surface: a deterministic third-event decode failure exercises pre-commit rollback,
  while a verification failure exercises resume after every page committed.
- 2026-08-08: Candidate language 5 initially reused the `Stable` support label, which silently
  demoted published v4 and rewrote its scaffold ledgers. EP-4 corrected the model to keep v4
  published stable, represent v5 as candidate, and select development authoring separately.
- 2026-08-08: The starter conformance suite encoded mutable `new <kind>` invocations instead of a
  historical language contract. A frozen-corpus manifest entry now keeps that v4 evidence under
  compile, ledger, disk, and Cabal checks without replaying it through candidate defaults.
- 2026-08-08: EP-5 landed the operator-neutral adapter and application adoption before the external
  command package. `ProjectionCatalogOperations` now supplies versioned JSON inventory, pure and
  registered-state preview, and start/inspect/resume/abandon. `keiro-ops` is still absent, so only
  the command mount, text rendering, and `--force` acceptance remain gated on MasterPlan 31.
- 2026-08-09: MasterPlan 31 plan 208 supplied `Keiro.Ops.Embed.AppHooks`, mounted the existing
  `ProjectionCatalogOperations` value in `jitsurei-demo ops`, and proved text/JSON preview plus
  `--force` command behavior. No second catalog or application-owned rebuild map was introduced.
- 2026-08-08: The jitsurei brownfield proof showed why completion and promotion verification are
  separate. Replay reached its exclusive fixed head and rebuilt every derived target, but an
  application-marked unsafe preserved root still blocked promotion and kept appends fenced until
  operator repair and exact-run resume.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Separate query models, physical targets, rebuild groups, and projection definitions.
  Rationale: They have different identities and cardinalities. Mori's fabricated query-less
  `ReadModel` values are direct evidence that the current one-table query wrapper is not an
  honest physical-target or lifecycle abstraction.
  Date: 2026-08-07

- Decision: Split target reset policy from projection replay policy.
  Rationale: Preserve versus clear describes table preparation; replayable versus live-only
  describes behavior. Treating side effects as a table class cannot model one live handler
  whose safe replay adapter intentionally omits timer or external work.
  Date: 2026-08-07

- Decision: Keep typed per-source views beside an existential fleet view.
  Rationale: `runCommandWithProjections` must retain its event type, while validation,
  inventory, and heterogeneous replay need one fleet collection. Erasing everything would
  replace compile-time correctness with `Dynamic`; refusing existentials would keep the
  application-maintained adapter list.
  Date: 2026-08-07

- Decision: Define completeness as captured-head traversal plus required-adapter accounting,
  not dedup-row presence.
  Rationale: One named dedup row proves idempotent application of one event, not that every
  source and projection completed. Conversely, a source with no relevant event is complete
  after its captured range is exhausted.
  Date: 2026-08-07

- Decision: Preserve unrestricted Hasql handlers as an explicit unchecked boundary.
  Rationale: The initial catalog can make declarations closed and orchestration safe, but it
  cannot infer or confine arbitrary SQL honestly. A future scoped capability is additive.
  Date: 2026-08-07

- Decision: Supersede plan 162 with EP-3 and integrate, rather than duplicate, plan 208.
  Rationale: Plan 162 contains necessary replay decisions but assumes one `ReadModel`; EP-3
  generalizes them. Plan 208 owns the broader ops embedding surface, so this initiative owns
  only the catalog-backed rebuild hook and must reconcile at that boundary.
  Date: 2026-08-07

- Decision: Register catalog syntax under the candidate `language keiro-dsl 5` and keep language versions 1–4
  immutable.
  Rationale: The published stable language is 4. Adding required ownership declarations and new
  generated runtime meaning to that released preamble would violate the append-only language
  registry; EP-4 must introduce a new syntax profile and an explicit upgrade path.
  Date: 2026-08-07

- Decision: Amend pre-release language 5 in place; do not allocate language 6.
  Rationale: Language 5 has not been published or used externally. The former unsupported-version
  fixture was a parser sentinel rather than a contract. Existing version-4 corpora remain valid
  primary evidence, and EP-4 adds a focused version-5 conformance lane without rewriting unrelated
  generated banners.
  Date: 2026-08-08

- Decision: Model published stable, active candidate, and authoring default as separate facts.
  Rationale: Candidate development must not demote released contracts or churn their evidence.
  Language 4 remains stable, candidate 5 is the development authoring default, and historical
  starter corpora are frozen rather than replayed through a changing `new` command.
  Date: 2026-08-08

- Decision: Keep the catalog rebuild command absent until the typed adapter and `keiro-ops` both
  exist.
  Rationale: A temporary free-form rebuild map would become a second inventory and safety bypass.
  EP-5 and plan 208 may land in either order, but neither substitutes a parallel public contract.
  Date: 2026-08-07

- Decision: Request bounded fan-in replay pages from Kiroku without making them an EP-3 gate.
  Rationale: Kiroku owns the reusable global-head and one-source range read, while Keiro owns
  catalog routing, k-way merge, progress, and promotion. Current released Kiroku calls can express
  the same range with a carefully tested compatibility loop, so release timing must not stall the
  catalog initiative.
  Date: 2026-08-08

- Decision: Version the replay contract independently as `keiro/projection-replay/v1` and keep
  page size operational.
  Rationale: The catalog fingerprint covers the whole read-side inventory, while the runner format,
  adapter order, and verifier versions govern resume. Transaction chunk size may change safely.
  Date: 2026-08-08

- Decision: Expose operations as an opaque `ProjectionCatalogOperations` value with pure reports,
  a read-only registered preview, and explicit mutation functions.
  Rationale: This preserves one catalog authority while leaving rendering, confirmation, exit
  codes, and database connection policy to MasterPlan 31. Callers cannot smuggle a second target,
  handler, source, subscription, or dedup inventory into execution.
  Date: 2026-08-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

EP-1 through EP-4 provide the complete runtime and generated declaration path: one validated
catalog feeds live writers, atomic group preparation, fixed-head replay, exact resume, application
verification, and proof-gated atomic promotion, while candidate language 5 generates the same
catalog and classifies its evolution. The principal lesson is that source exhaustion and adapter
evaluation are separate evidence: an all-irrelevant history can be complete with zero applies,
while one arbitrary dedup row proves neither. EP-5 has now adopted the catalog in hand-written
jitsurei and the generated candidate-language-5 conformance service, published the migration and
operations contract, landed the operator-neutral adapter, and mounted it through `keiro-ops`
without accepting a second fleet list. EP-4 also made release maturity
distinct from authoring defaults: v4 remains published stable, unreleased v5 is amended in place,
and historical v4 corpora no longer churn when candidate authoring advances. All five child plans
are complete; plan 208's embedded command mount closes the final cross-MasterPlan integration gate.
