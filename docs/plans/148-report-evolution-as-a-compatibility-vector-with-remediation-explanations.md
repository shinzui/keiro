---
id: 148
slug: report-evolution-as-a-compatibility-vector-with-remediation-explanations
title: "Report evolution as a compatibility vector with remediation explanations"
kind: exec-plan
created_at: 2026-07-28T10:48:59Z
intention: "intention_01kym5dc4ve69sxsjtzd81pbbz"
master_plan: "docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md"
---

# Report evolution as a compatibility vector with remediation explanations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today `keiro-dsl diff --since <git-ref>` classifies every spec change with exactly one word
— `ADDITIVE`, `WARNING`, or `BREAKING` — and exits non-zero only on `BREAKING`. That single
label is honest but incomplete. The same edit can be safe on one persistence surface and
dangerous on another: adding a constructor to a status union is decodable by the new binary
reading old private history, yet an *old* binary still running during a rolling deploy fails
the moment a new replica emits the new arm, a closed public consumer may reject it forever,
and a snapshot shape may want a version bump even though event replay is unaffected. One
global label either blocks safe changes or lets the report hide a real risk behind the word
"additive". This is section 7 of the research note
`docs/research/14-structural-consumer-type-tradeoffs.md` ("Usage-Aware Evolution Gives Up a
Simple Universal Label"), which this plan implements, and it is required by the Evolution
Contract of `docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`
(IR-1): usage-aware, per-surface classification with rollout advisories.

After this plan, every diff finding carries a **compatibility vector**: an explicit
per-surface classification over six named surfaces (private-history-read,
old-binary-read-new-events, snapshot-hydration, public-consumer, persisted-identity,
consumer-build) plus a
rollout advisory (for example `producer-last`, `stop-the-world`, `drain-required`). A new
`diff --explain` mode prints, for each finding, the containing path, the compatibility
direction that fails, and the available remedies (version bump, upcaster, deployment order,
contract revision, replay-only edge). A new `--report-out` flag writes the full report as
JSON for tooling. Observable acceptance uses repository-native changes on separately owned
surfaces: a private event/schema addition, a snapshot/fold change, and an existing public
contract change produce context-specific vectors and containing paths. It does not introduce a
nominal enum-to-`Text` contract shortcut merely to reproduce Mori's Experiment D.

The hard constraint is **no weakening**: anything classified `BREAKING` today remains
`BREAKING`; the vector refines the existing three-way classification, it never relaxes it;
`diff` continues to exit non-zero exactly when a surface the operator gates on is breaking,
and the default gate reproduces today's blocking behavior bit for bit. A formerly additive
finding may become `WARNING` when the newly explicit direction or rollout constraint exposes a
real obligation, but never the reverse.


## Progress

- [x] 2026-07-28: Milestone 1: vector core — `CompatibilitySurface`, `SurfaceVerdict`, `RolloutConstraint`,
      `CompatibilityVector` and opaque `ChangeContext` types in `Keiro.Dsl.Diff`; mandatory
      codes/`ckVector` on `ChangeKind`; per-code registry and label-derivation invariant green.
- [x] 2026-07-28: Milestone 2: coarse multi-use findings split into exact context-sensitive findings;
      private-event, snapshot-invalidation, and existing public-contract fixtures cover distinct
      vectors without changing `ContractType`.
- [x] 2026-07-28: Milestone 3: CLI — vector rendering, `--gate`, `--explain`, `--report-out`; remediation
      registry with totality test; golden output tests; consumer-neutral fixture matrix;
      diff-test.sh extended with the matrix and the no-weakening negative test.
- [x] 2026-07-28: Milestone 4 documentation and ADR edits — `docs/guides/evolution-and-replayability.md` and
      `docs/guides/evolve-events-safely.md` updated; ADR 0004 inventory amended; `docs/adr/log.md`
      updated via okf; Proposal Test answers recorded.
- [ ] Milestone 4 validation — strict `just adr-validate`, unit, conformance, shell, and diff-hygiene gates green.
- [ ] ADR distillation pass completed before marking the plan complete.


## Surprises & Discoveries

- The research scenario's public enum arm is not expressible in current `ContractType`, but
  adding `CEnum` and lowering it to `Text` would erase nominal/public ownership for an unrelated
  fixture. Existing contract changes already exercise the public-consumer vector.
- A vector keyed only by `DiagnosticCode` cannot classify the same code differently at distinct
  roots, and a `Map` with defaults hides newly added surfaces. The revised API carries explicit
  `ChangeContext`, mandatory codes, explicit record fields, and a set of rollout constraints.
- The current aggregate-event grammar has no explicit unknown-field decode policy. Generated
  event fields are strict when reading old history, while Aeson object decoders ignore extra
  keys in the opposite direction. The implementation therefore records old-binary risk only
  where the present spec provides evidence (the typed enum event use in the compatibility
  matrix) instead of manufacturing a reject/ignore fact.
- Adding `containers` to the executable solely to union requested gates would have violated this
  plan's no-new-dependency constraint. `gateWith` now owns that union in the library, where
  `containers` was already a dependency, and the CLI consumes the resulting opaque `Set`.


## Decision Log

- Decision: The vector is carried on every finding and the headline label
  (`ADDITIVE`/`WARNING`/`BREAKING`) is *derived* from the vector under a gate — a set of
  surfaces whose breaking verdicts block the merge. The default gate is
  {private-history-read, snapshot-hydration, public-consumer, persisted-identity,
  consumer-build}. The first four are the surfaces today's classification already blocks on;
  consumer-build is included so a future source-incompatible finding cannot pass by default,
  while no existing finding is breaking on that new surface. Old-binary-read-new-events
  is deliberately outside the default gate because today's differ never blocks on
  rolling-deploy direction. A breaking verdict on a non-gated surface is shown in the
  rendered vector and promotes an otherwise-clean finding to `WARNING`; a rollout constraint
  does the same. This is what makes "the vector refines, never relaxes" checkable: no existing
  finding is demoted and default exit codes are preserved, while operators opt into stricter
  gating with `--gate`.
  Rationale: hard constraint (a) of the MasterPlan scope; research note section 7 says the
  fix is better explanation and policy, "not weaker classification".
  Date: 2026-07-28

- Decision: Add a fifth surface, `persisted-identity`, beyond the research note's four.
  Rationale: roughly half of today's `Breaking` corpus (DerivedIdentityChanged,
  IdPrefixChanged, DedupeIdentityChanged, QueueIdentityChanged, RouterStableNameChanged,
  WorkflowStableNameChanged, …) is about re-keying persisted identities, not decoding.
  Folding those into private-history-read would blur the direction question the vector
  exists to answer. The vector shape is append-extensible (see the JSON decision below), so
  adding a surface now exercises the extension mechanism plan 149 will rely on.
  Date: 2026-07-28

- Decision: Add a sixth, compile-forcing `consumer-build` surface for source and generated-code
  compatibility. It is an explicit field and a valid `--gate` value, not an entry defaulted into
  a map. Existing findings use `VNotApplicable` unless they already impose a source rebuild;
  plan 149 adds mapping-specific rows.
  Rationale: Binding symbols, constructors, modules, and canonical names can change without
  changing persisted bytes. Overloading those obligations onto persisted identity would make the
  vector less reusable for consumers with independently owned domain packages.
  Date: 2026-07-28

- Decision: Do not touch the replay-impact JSON contract
  (`{"verdict":"replay-neutral"}` / `{"verdict":"affected","aggregates":{...}}`, fixed by
  `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`). The vector
  report gets its own new flag, `--report-out FILE`. Rationale: constraint (c). A repo-wide
  grep for the contract keys found no in-repo programmatic parser (the consumer is the
  operator workflow described in `keiro/src/Keiro/ReplayAudit.hs` and
  `docs/user/replay-safety.md`), which means external scripts may parse it; the safest
  backward-compatible extension is to add a sibling artifact and leave the existing file
  byte-compatible.
  Date: 2026-07-28

- Decision: Do not extend `ContractType` with `CEnum Name -> Text` for this plan. Exercise
  public-consumer dimensions using the contract changes already modeled by the DSL.
  Rationale: Private structural types and public DTOs are independently owned. Erasing a nominal
  enum to `Text` solely to satisfy a research scenario is an API distortion and creates an
  unrelated grammar/scaffold commitment.
  Date: 2026-07-28

- Decision: Context-sensitive vector and remediation registries
  (`classifyCompatibility`, `remediationFor`) keyed by `ChangeContext` plus `DiagnosticCode`,
  with unit tests enforcing totality over every code/context the differ can
  emit — the same registry-coverage style `familyRegistry` already uses. New codes such as
  `EnumCtorAdded` and codes for currently uncoded additive findings are appended at the end of the shared
  `DiagnosticCode` enum in `keiro-dsl/src/Keiro/Dsl/Validate.hs`; no existing code is
  renamed, reused, or reordered. Every finding, including additive findings, has a stable code;
  no generic all-compatible default is permitted (constraint (b); ADR 0004 says tooling depends on the code,
  not prose).
  Date: 2026-07-28

- Decision: Enum-constructor additions are reported per use site (one finding per containing
  path) instead of one finding with a usage suffix, using the new `EnumCtorAdded` code. The
  private-event-use finding becomes `WARNING`: its breaking verdict is on the non-gated
  old-binary-read-new-events surface and its rollout constraint is actionable. The
  snapshot-register-use finding is also `WARNING`
  (snapshot-hydration advisory: invalidate/rebuild the cache). Public-contract changes retain
  their existing contract codes and independently classified public-consumer paths; an enum is
  not reused across the private/public boundary. This is an intentional additive-to-advisory
  strengthening; existing breaking findings and default blocking behavior do not weaken.
  Date: 2026-07-28

- Decision: Rollout constraints are a zero-or-more `Set`, with vocabulary taken from ADR 0004's
  rollout-ordering section and `docs/user/deploy-ordering.md`: `stop-the-world` (single-version
  aggregate codec cutover), `workers-first` (queue workers before producers),
  `drain-required` (router/process decide surfaces need a drained redelivery window),
  `producer-last` (consumers/firers must learn new shapes before producers write them). An empty
  set means no ordering constraint; there is no `RolloutAny` value that competes with others.
  Date: 2026-07-28

- Decision: Reuse a small append-only code vocabulary for previously uncoded additive findings
  (`DeclarationAdded`, `VersionBumped`, `CompatibilityStrengthened`, and the narrower enum,
  contract, retirement, and workflow-evolution codes) rather than allocate one code per prose
  sentence. Every finding still carries a mandatory code, and context plus code selects the
  vector; this keeps codes stable when details improve without collapsing the distinct
  compatibility surfaces.
  Rationale: The machine contract needs a stable change class, not a unique identifier for each
  emission site. Use-site paths and `ChangeContext` carry the site-specific facts.
  Date: 2026-07-28

- Decision: Keep ADDITIVE headline lines byte-compatible by omitting their newly mandatory code
  from text output; advisory and breaking lines retain their existing bracketed codes, while the
  JSON report includes a code for every finding.
  Rationale: Existing shell consumers may parse the additive line grammar. Mandatory internal
  codes and JSON completeness do not require changing that stable text surface.
  Date: 2026-07-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository is the `keiro` event-sourcing runtime. The package `keiro-dsl` (directory
`keiro-dsl/` at the repo root) is a toolchain for `.keiro` specification files: a `.keiro`
file declares a service's aggregates (event-sourced state machines), enums, contracts
(cross-service Kafka message schemas), workqueues, processes, routers, read models, and
workflows; the CLI (`keiro-dsl/app/Main.hs`) parses, validates, scaffolds Haskell from, and
*diffs* those specs. All paths below are repository-relative; the repo root is
`/Users/shinzui/Keikaku/bokuno/keiro` in this checkout.

The differ is `keiro-dsl/src/Keiro/Dsl/Diff.hs`. Its output type (lines 48–62) is:

```haskell
data Change = Additive ChangeKind | Advisory ChangeKind | Breaking ChangeKind

data ChangeKind = ChangeKind
    { ckNode :: !Name        -- the declaring node, e.g. "Reservation"
    , ckFacet :: !Text       -- e.g. "event", "enum-constructor", "contract-field"
    , ckSubject :: !Text     -- e.g. "ReservationMade.status"
    , ckCode :: !(Maybe DiagnosticCode)
    , ckDetail :: !Text      -- human prose
    }
```

`diffSpecs :: Spec -> Spec -> [Change]` (line 168) fans out over a closed
`familyRegistry :: [(NodeFamily, FamilyDiff)]` (lines 152–166) covering twelve node
families; every `Node` constructor maps to a family via the total `familyOf`, and the unit
suite enforces registry coverage. Helpers `additive`, `advisory`, `breaking` (lines
1363–1370) construct changes; `additive` currently takes no `DiagnosticCode`. Crucially, the
existing classification already encodes per-surface knowledge *implicitly* in prose: e.g.
`contractEventDiff` distinguishes a field add with a schemaVersion bump (Advisory,
"coordinate the cross-service rollout") from one without (Breaking); `routerDecideSurfaceDiff`
and `processDecideSurfaceDiff` are Advisories whose prose demands a drained redelivery
window; `transitionSurfaceDiff` (`AggFoldSurfaceChanged`) is a snapshot-invalidation
advisory. This plan makes those surfaces explicit and machine-readable.

`DiagnosticCode` is a shared registry in `keiro-dsl/src/Keiro/Dsl/Validate.hs` (the enum
starting at line 39) correlating `check` and `diff`; tests match on the code, not prose, and
`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (ADR 0004)
makes that a project rule. Codes are append-only for this plan.

The CLI diff subcommand is `run (Diff …)` in `keiro-dsl/app/Main.hs` (lines 150–175). It
resolves the spec against a git ref (`git show <ref>:<relpath>`), prints one line per change
via `renderChange` (`ADDITIVE: …` / `WARNING: … [Code]` / `BREAKING: … [Code]`), prints the
replay-impact verdict, optionally writes it as JSON (`--replay-impact-out FILE`), and exits
non-zero iff `any isBreaking changes`. Flags are plain optparse-applicative long options
(`strOption`/`switch`), so the new `--explain` (switch), `--gate SURFACE` (repeatable
option), and `--report-out FILE` (option) follow existing conventions; a new subcommand is
not needed.

The replay-impact channel is separate: `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` computes a
deliberately conservative "can the candidate binary interpret an already-stored aggregate
log differently" verdict, with the machine contract `{"verdict":"replay-neutral"}` or
`{"verdict":"affected","aggregates":{…}}` frozen by ADR 0004. Its consumer is the
operator-facing replay audit (`keiro/src/Keiro/ReplayAudit.hs`, `docs/user/replay-safety.md`);
grep found no in-repo `FromJSON` parser of it, which is why this plan leaves that file's
schema untouched and adds a separate `--report-out` (Decision Log).

Enums today: `EnumDecl` (`keiro-dsl/src/Keiro/Dsl/Grammar.hs` line 164) declares
constructors with wire spellings. `enumPairDiff` in Diff.hs classifies constructor removal
and wire-respelling as Breaking and constructor *addition* as one Additive finding whose
detail carries a usage suffix computed by `enumUsages` — which already knows the two private
use-site kinds: registers (`Agg.reg.r`) and event fields (`Agg.event.E.field`). Contracts
cannot reference enums: `ContractType = CTypeId !Text | CText | CInt` (Grammar.hs line 668),
lowered in `emitPayloadAdt` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` around line 545, where
`CTypeId` maps to `Text`).

Tests: the unit suite is `test-suite keiro-dsl-test` (`keiro-dsl/test/Main.hs`, ~2900 lines,
hspec; it has a `diffFixtures`/`replayImpactFixtures` pattern near line 1843 that parses two
fixture files under `keiro-dsl/test/fixtures/` and diffs them). The end-to-end merge-gate
test is `keiro-dsl/test/diff-test.sh`, a bash script run from the repo root that builds a
throwaway git repo, swaps fixture specs in, and asserts classifications, codes, and exit
statuses (it greps output substrings and checks process exit codes, so *adding* lines to
diff output is safe; changing the `ADDITIVE:`/`WARNING:`/`BREAKING:` line grammar is not).

Relevant ADRs (read during planning; summarized so you do not need unrelated ones):

- `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` — the gate
  inventory this plan amends. It fixes: diagnostic codes as the machine contract; the
  replay-impact JSON shape; and a rollout-ordering section whose vocabulary the rollout
  advisory reuses (stop-the-world/blue-green for aggregate codec version bumps because one
  codec version writes and decodes; workers before producers for versioned job queues;
  drained redelivery windows for router/process decide changes; consumers/firers learn new
  shapes before producers for timers, integration payloads, workflow results). Its
  amendment protocol: "the inventory is amended when a later child plan changes a gate's
  ownership" — a classification-output change qualifies.
- `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md` — the
  replay-only edge remedy; `--explain` names it as the remedy for `AggGuardTightened`.
- `docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md` — snapshot
  seeds are keyed by (state-codec version, fold fingerprint, spec identity); this is why the
  snapshot-hydration surface is usually Advisory (stale seeds are rejected, not silently
  misread) and why the remedy prose says "bump `state-codec version=`".

No keiro-local ADR covers per-surface classification yet; this plan amends ADR 0004 rather
than creating a new record, because ADR 0004 already owns the classification inventory.
Cross-repository context is not required to implement this plan.

Coordination (self-contained summary): this is EP-5 of MasterPlan 25
(`docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md`).
It has no hard dependencies and de-risks the IR-1 plans. Integration point owned here: the
**vector output shape**. Plan
`docs/plans/149-implement-the-ir-1-spec-layer-resolved-type-graph-structural-and-opaque-declarations-check-and-diff.md`
(EP-6) will later classify recursively nested structural type expressions and must be able
to emit findings in this shape with deeper root-to-leaf paths — hence findings carry a
`paths` list of textual containing paths and the JSON vector is an object keyed by surface
name so new surfaces and deeper paths append without breaking consumers.

Definitions used below:

- **Surface**: one compatibility question asked of a change. The six surfaces:
  *private-history-read* (can the new binary decode and replay already-stored private
  events), *old-binary-read-new-events* (during a rolling deploy, can a still-running old
  binary decode what the new binary emits), *snapshot-hydration* (can persisted snapshot
  seeds still hydrate, or do they need a version bump/rebuild), *public-consumer* (can
  independent consumers of a declared contract keep decoding), *persisted-identity* (do
  replays/retries still derive the same persisted stream, dedupe, dispatch, and outbox
  identities), and *consumer-build* (must generated/consumer Haskell be updated or recompiled
  even though wire identity is unchanged). The build surface is explicit so later consumer-owned
  mapping diagnostics do not overload persisted identity.
- **Verdict**: per surface, one of `compatible`, `advisory`, `breaking`, `n/a`.
- **Gate**: the set of surfaces whose `breaking` verdict makes the process exit non-zero.
- **Rollout advisory**: a deployment-ordering obligation attached to the whole finding.


## Plan of Work

### Milestone 1 — the vector core and current-finding migration inside `Keiro.Dsl.Diff`

Scope: introduce the vector types, attach a vector to every `Change` the differ already
produces, and assert in tests that headline labels are exactly derivable from vectors
under the default gate. At the end of this milestone the library computes vectors, existing
breaking/advisory headlines are not demoted, and enum additions with a rolling-deploy obligation
are deliberately promoted to advisory; default exit behavior is unchanged.

In `keiro-dsl/src/Keiro/Dsl/Diff.hs` add and export:

```haskell
data CompatibilitySurface
    = PrivateHistoryRead
    | OldBinaryReadNewEvents
    | SnapshotHydration
    | PublicConsumer
    | PersistedIdentity
    | ConsumerBuild
    deriving stock (Eq, Ord, Show, Enum, Bounded)

data SurfaceVerdict = VCompatible | VAdvisory | VBreaking | VNotApplicable
    deriving stock (Eq, Show)

data RolloutConstraint
    = RolloutStopTheWorld | RolloutWorkersFirst
    | RolloutDrainRequired | RolloutProducerLast
    deriving stock (Eq, Ord, Show)

data CompatibilityVector = CompatibilityVector
    { cvPrivateHistoryRead :: !SurfaceVerdict
    , cvOldBinaryReadNewEvents :: !SurfaceVerdict
    , cvSnapshotHydration :: !SurfaceVerdict
    , cvPublicConsumer :: !SurfaceVerdict
    , cvPersistedIdentity :: !SurfaceVerdict
    , cvConsumerBuild :: !SurfaceVerdict
    , cvRollout :: !(Set RolloutConstraint)
    }
    deriving stock (Eq, Show)
```

Use explicit fields so adding a surface breaks every construction site and JSON encoder at
compile time. `VNotApplicable` remains explicit. Rollout is zero-or-more constraints;
`Set.empty` means no rollout ordering. Provide named smart constructors for recurring fully
specified vectors, but no default that silently fills missing surfaces.

Also introduce the `ChangeContext` record in this milestone, keep its constructor private, and
expose the named surface/ownership smart constructors and read-only accessors described in
Milestone 2. The classifier therefore never has a phase in which it accepts an unstructured or
contradictory bag of facts.

For every pre-existing diff code, classify `ConsumerBuild` explicitly as `VNotApplicable` unless
the finding already names a generated/source compatibility obligation; those codes use
`VAdvisory` and `RemedyRecompileConsumers`. This preserves today's headlines while making the
extension point compile-forcing. Plan 149 adds its mapping-specific source/binding rows on this
surface.

Make `ckCode :: !DiagnosticCode` mandatory (remove its current `Maybe`), and extend
`ChangeKind` with `ckVector :: !CompatibilityVector` and
`ckPaths :: ![Text]` (containing root-to-leaf paths; for existing findings this is the
single path already implied by `ckNode`/`ckFacet`/`ckSubject`, e.g.
`"Reservation.event.ReservationMade.qty"` — construct it in one place). Change the three
helper constructors to receive a `ChangeContext` and mandatory `DiagnosticCode`; remove the
uncoded `additive` path. Existing call sites become compile failures until their context and
code are explicit.

Do not derive or use `Ord SurfaceVerdict`: `VNotApplicable` is not a severity above or below
the other verdicts. `deriveLabel` performs the explicit case analysis below, preventing a later
consumer from accidentally using constructor order as policy.

Add the per-code vector registry:

```haskell
classifyCompatibility :: ChangeContext -> DiagnosticCode -> CompatibilityVector
```

Populate it for every code the differ emits, translating the knowledge already in the prose.
Representative rows (complete the rest by reading each emission site's detail text — the
prose states the surface and the ADR 0004 rollout section states the ordering):

- Decode-surface breaks (`EvtFieldAddedWithoutBump`, `EvtFieldRemovedSameVersion`,
  `EvtFieldTypeChanged`, `EvtVersionDecreased`, `EvtVersionMissingUpcaster`,
  `UpcasterChainGap`, `EvtRemovedNotDeprecated`, `EnumCtorRemoved`,
  `EnumWireSpellingChanged`, `WireSpecChanged`): private-history-read `VBreaking`,
  snapshot-hydration `VAdvisory` (stale seeds are rejected by the ADR 0003 discriminator,
  not misread), rollout `RolloutStopTheWorld` (one codec version writes and decodes).
- Identity re-keying (`DerivedIdentityChanged`, `IdPrefixChanged`, `DedupeIdentityChanged`,
  `QueueIdentityChanged`, `RouterStableNameChanged`, `WorkflowStableNameChanged`,
  `WorkflowShapeChanged`, `WorkflowBodyChanged`, `WorkflowPatchRemoved`,
  `WorkflowContinueSeedChanged`): persisted-identity `VBreaking`, rollout `Set.empty`
  (ordering does not fix re-keying; the remedy is not deploying it).
- Contract surface (`ContractEventRemoved`, `ContractFieldChanged`,
  `ContractDiscriminatorChanged`, `ContractTopicChanged`,
  `ContractSchemaVersionDecreased`): public-consumer `VBreaking`, private surfaces
  `VNotApplicable`, rollout `RolloutProducerLast`. `ContractSchemaVersionBumped`:
  public-consumer `VAdvisory`, rollout `RolloutProducerLast`.
- Queue payloads (`WqPayloadFieldChanged`): private-history-read `VBreaking` (persisted
  jobs), rollout `RolloutWorkersFirst`. `WqOrderingChanged`/`WqProvisionChanged`/
  `WqGroupKeyChanged`: persisted-identity or private-history-read `VBreaking` per prose,
  rollout `RolloutWorkersFirst`.
- Advisories: `AggFoldSurfaceChanged` → snapshot-hydration `VAdvisory`,
  private-history-read `VAdvisory` (replay reinterprets the log), rollout `Set.empty`.
  `AggGuardTightened` → private-history-read `VAdvisory`, rollout `Set.empty` (remedy is
  the replay-only twin, ADR 0002). `RouterDecideSurfaceChanged`,
  `ProcessDecideSurfaceChanged` → all surfaces `VCompatible`, rollout
  `RolloutDrainRequired`. `ProcessTimerPayloadChanged` → private-history-read `VAdvisory`
  (old-shape rows fire under new code), rollout `RolloutProducerLast`. `TimerWindowChanged`,
  `ProjectionChanged`, `EmitMappingChanged`, `DecodePostureChanged`,
  `IntakePersistenceChanged`, `PublisherPolicyChanged`, `DispatchRetargeted`,
  `DeprecatedEventReplayHazard`, `EventRetirementInProgress`, `EventUndeprecated` → map the
  prose; none may carry `VBreaking` on a default-gated surface (that is the invariant test).
- Read models (`ReadModelVersionDecreased`, `ReadModelShapeChangedWithoutBump`,
  `ReadModelFeedChanged`, `ReadModelConsistencyWeakened`): these break rebuild/served-shape
  or caller guarantees over persisted projection state — persisted-identity or
  private-history-read `VBreaking` per the emission site, rollout `Set.empty`.

Add the derivation and gate:

```haskell
defaultGate :: Set CompatibilitySurface   -- everything except OldBinaryReadNewEvents
deriveLabel :: Set CompatibilitySurface -> CompatibilityVector -> Label -- Additive|Advisory|Breaking
gatedBreaking :: Set CompatibilitySurface -> Change -> Bool
```

`deriveLabel gate v` is `Breaking` iff any gated surface is `VBreaking`; else `Advisory` iff
any surface (gated or not) is `VAdvisory` or the rollout set is non-empty or a non-gated
surface is `VBreaking`; else `Additive`. Do **not** rewrite the differ to construct changes
through `deriveLabel` — the existing constructors stay authoritative for this milestone.
Instead enforce coherence by test (below), so any registry row that would relabel an
existing finding fails loudly. Exception carve-out: because `RouterDecideSurfaceChanged`
etc. are already `Advisory` and their vectors carry `RolloutDrainRequired`, derivation
matches. Where a
registry row cannot match an existing headline under this rule, fix the row, not the rule.

Tests in `keiro-dsl/test/Main.hs`:

- *Registry totality*: for every fixture pair already exercised by the suite (reuse the
  `diffFixtures` helper and the in-memory `modifyRouter`/`modifyProcess`-style cases), every
  produced `Change` has a mandatory code and its `ChangeContext`/code pair classifies, and
  every `Change` satisfies `deriveLabel defaultGate (ckVector k) == constructorOf change`.
  This is the machine-checked **no-weakening invariant** after the intentional enum-addition
  strengthening: the vector cannot demote any existing finding under the default gate.
- *Gate monotonicity property* (QuickCheck over vectors): enlarging the gate never turns
  `Breaking` into a lesser label — `deriveLabel g v == Breaking` implies
  `deriveLabel (g <> g') v == Breaking`.

Acceptance: `cabal test keiro-dsl-test` passes; `bash keiro-dsl/test/diff-test.sh` still
passes after updating the enum-addition expectation from `ADDITIVE` to `WARNING`; all existing
non-zero exits remain non-zero and all existing zero exits remain zero.

### Milestone 2 — per-use-site context refinement and mandatory-code completion

Scope: refine every classification to the exact facts from its containing use site and split
findings that currently summarize multiple uses while preserving the mandatory stable codes
introduced in Milestone 1. Use the opaque `ChangeContext` record introduced in Milestone 1, containing the root/path, direction,
snapshot-cache participation, record unknown-field policy when applicable, public/private
ownership, schema-version facts, and rollout environment facts already present in the old/new
specs. Complete its named smart constructors/accessors for private
event, snapshot, queue, public-contract, persisted-identity, and consumer-build contexts, so later
consumers cannot manufacture contradictory ownership/surface facts. `classifyCompatibility`
consumes this context plus the code; it is not a global lookup that assumes one vector for every
emission site of a code.

Rework additive emission helpers to construct one context per use site. For enum-arm additions already supported by
the DSL, emit one finding per private event/register use site with complete paths. An event use
is compatible for new-binary/private-history reads but breaking for old-binary/new-event reads;
a snapshot-register use is explicitly invalidate/rebuild Advisory. Public-consumer coverage
uses existing contract field/event/schema change codes and fixtures. `ContractType`, parser,
pretty-printer, and scaffold output are unchanged.

Tests enumerate every emitted code/context pair; fail if a finding lacks a code or classification.
Add explicit cases showing that an additive field can still break old-binary reads when the old
record rejects unknown fields, and that a snapshot finding describes cache rebuild rather than
an event upcaster. Existing breaking findings remain breaking under the default gate.

Acceptance: `cabal test keiro-dsl-test` and existing contract conformance tests pass with no
contract grammar or generated DTO change.

### Milestone 3 — CLI rendering, `--gate`, `--explain`, `--report-out`, goldens, consumer-neutral matrix

Scope: make the vector visible and actionable. At the end, the CLI prints vectors, an
operator can gate on extra surfaces, `--explain` prints remediation blocks, `--report-out`
writes machine JSON, and the private-event/snapshot/public-contract matrix is checked in with
golden output plus a diff-test.sh scenario.

In `keiro-dsl/app/Main.hs`, extend the `Diff` command with `--gate SURFACE` (a `many`
  `strOption`; accepted spellings are the kebab-case surface names
  `private-history-read`, `old-binary-read-new-events`, `snapshot-hydration`,
  `public-consumer`, `persisted-identity`, `consumer-build`; unknown spellings are a usage
  error listing the valid set), `--explain` (switch) and `--report-out FILE` (option). Behavior:

- The headline line grammar is unchanged (`ADDITIVE:`/`WARNING:`/`BREAKING:` … `[Code]`).
  After any finding whose vector is not uniformly `VCompatible`/`VNotApplicable`, print one
  indented continuation line:
  `    vector: private-history-read=compatible old-binary-read-new-events=breaking … rollout=producer-last`
  (omit `n/a` surfaces for readability; print rollout only when the set is non-empty). Adding lines
  is safe for `diff-test.sh`, which greps substrings.
- Exit: non-zero iff any change is breaking on the *effective* gate = `defaultGate` plus
  the `--gate` surfaces. With no `--gate` flags this is exactly `any isBreaking changes` —
  assert that equivalence in the unit suite (constraint (a)).
- `--explain`: after the findings, print one block per finding whose vector is non-uniform
  or whose headline is not `ADDITIVE`, containing the containing path(s) (`ckPaths`), the
  failing direction stated as a sentence (name the surface and which side fails), and the
  remedies from a new registry in Diff.hs:

```haskell
data Remedy = RemedyVersionBump | RemedyUpcaster | RemedyDeploymentOrder RolloutConstraint
            | RemedyContractRevision | RemedyReplayOnlyEdge | RemedyStateCodecBump
            | RemedyRecompileConsumers | RemedyRunConformance
            | RemedyDoNotDeploy Text  -- rename/re-key class: revert or migrate operationally
remediationFor :: ChangeContext -> DiagnosticCode -> NonEmpty Remedy
```

  Render each remedy as one imperative line; `RemedyReplayOnlyEdge` cites
  `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`.
  `RemedyRecompileConsumers` and `RemedyRunConformance` are intentionally generic extension
  points for later source-binding diagnostics such as plan 149's checked consumer mappings; they
  do not weaken or replace a version/upcaster remedy on a wire break.
  Totality test: every code the differ can emit reaches a registry arm; non-emptiness is carried
  by the result type rather than re-established by every caller.
- `--report-out FILE`: write JSON (new `ToJSON` instances in Diff.hs or a small
  `Keiro.Dsl.DiffReport` module — prefer the new module to keep Diff.hs pure):

```json
{
  "schema": "keiro-dsl/diff-report/1",
  "gate": ["private-history-read", "snapshot-hydration", "public-consumer", "persisted-identity", "consumer-build"],
  "breaking": true,
  "findings": [
    { "label": "breaking", "node": "ReservationFeed", "facet": "contract-field",
      "subject": "ReservationChanged.status", "code": "ContractFieldChanged",
      "paths": ["ReservationFeed.event.ReservationChanged.status"],
      "vector": { "private-history-read": "n/a", "old-binary-read-new-events": "n/a",
                  "snapshot-hydration": "n/a", "public-consumer": "breaking",
                  "persisted-identity": "n/a", "consumer-build": "n/a",
                  "rollout": ["producer-last"] },
      "detail": "…", "remedies": ["bump the contract schemaVersion", "revise the contract"] }
  ]
}
```

  Document in the module haddock: consumers must ignore unknown keys; `vector` keys and
  `paths` entries are append-only. This is the shape plan 149 adopts for recursive nested
  classification. The `--replay-impact-out` file is untouched.

Fixtures and goldens: create a consumer-neutral matrix from existing fixture families: an enum
arm addition used by a private event and snapshot register, plus an existing public-contract
field/schema change in a separate contract-owned type. Render the full report through pure
library functions shared with the CLI and pin it under
`keiro-dsl/test/fixtures/compatibility-vector.diff.golden`. The golden must show complete paths,
context-sensitive vectors, snapshot invalidate/rebuild prose, and a public-consumer finding
without sharing a private enum type across the boundary.

Extend `keiro-dsl/test/diff-test.sh` with two scenarios: (a) the consumer-neutral matrix —
assert the output contains all roots and the substrings `public-consumer=breaking`,
`snapshot-hydration=advisory`, and `old-binary-read-new-events=breaking`; (b) the no-weakening negative test —
re-assert that the existing `reservation-fieldadd.keiro` swap still exits non-zero with
`BREAKING` and `EvtFieldAddedWithoutBump` *and* additionally that running with
`--gate old-binary-read-new-events` also exits non-zero (gates only ever add).

Acceptance: `cabal test keiro-dsl-test` green including the new golden;
`bash keiro-dsl/test/diff-test.sh` prints its final `PASS` line.

### Milestone 4 — documentation, ADR 0004 amendment, log maintenance

Scope: the written contract catches up with the tool. At the end, the guides describe the
vector, ADR 0004's inventory records the output change, and strict OKF validation passes.

- `docs/guides/evolution-and-replayability.md`: update gate 2 of "The gates, at a glance"
  (lines ~69–80) to say `diff` classifies each finding as a per-surface compatibility
  vector with a rollout advisory, keeps the ADDITIVE/WARNING/BREAKING headline, exits
  non-zero on the gated surfaces (default gate = today's behavior, `--gate` adds surfaces),
  and offers `--explain` and `--report-out`. Add a short subsection (near the
  guard-tightening walkthrough at ~line 260) showing the consumer-neutral transcript excerpt.
  Sweep the rest of the guide's `ADDITIVE`/`WARNING`/`BREAKING` mentions (the summary table
  around lines 560–575 keeps its labels — they are still the headlines) and adjust prose
  that claims the label is the whole answer.
- `docs/guides/evolve-events-safely.md`: verified during planning to not describe diff
  output at all (it is the hand-written-codec guide). Add one closing sentence next to the
  existing pointer (lines 81–83): for DSL services, `keiro-dsl diff` reports per-surface
  compatibility vectors and `--explain` remediation; link the evolution guide's new
  subsection.
- `docs/user/deploy-ordering.md`: read it; if its vocabulary differs from the rollout
  advisory spellings, reconcile (prefer changing this plan's spellings pre-release over
  editing the operator doc).
- ADR 0004 (`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`),
  per its amendment protocol: (1) in the Decision section after the inventory table, add a
  paragraph defining the compatibility-vector output contract — six surfaces, verdict
  values, rollout-constraint vocabulary (zero-or-more; cross-reference its own rollout-ordering bullets), default
  gate, `--gate` semantics, the `keiro-dsl/diff-report/1` JSON schema id with
  append-only/ignore-unknown rules, and the statement that headlines and codes remain the
  machine contract with vectors as a refinement; (2) add inventory rows for context-sensitive
  private enum-arm additions, snapshot-cache invalidation, and existing public-contract changes.
  Update the frontmatter `timestamp` to the amendment time (keep
  `docId: ADR-4` and `date` of original acceptance; follow the file's existing style).
- Maintain the reserved log: add a `docs/adr/log.md` entry for the amendment using
  `okf log add` (run `okf log add --help` for exact arguments; match the existing entry
  style, e.g. `* **Update**: Record the compatibility-vector refinement of the diff
  classification contract.`), then run strict enforcement (Concrete Steps below). Do not
  edit `log.md` by hand if `okf log add` succeeds.
- Distillation pass: review this plan's Decision Log / Surprises; the vector contract
  itself lands in ADR 0004 above, so expect no additional ADR unless implementation
  surprises produce one.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless
stated otherwise. The project builds with cabal inside the flake dev environment (if your
shell is not already in it: `nix develop` first). Note the recipe file is `Justfile`
(capital J); `just --list` shows recipes.

Build and unit-test the DSL package (the tight loop for Milestones 1–3):

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test
```

Expected on success: the hspec run ends `0 failures`. The unit suite does not need the
database. The repo-wide gates `just haskell-build` / `just haskell-test` exist but
`haskell-test` does not include `keiro-dsl-test`, so run it explicitly as above.

Run the end-to-end merge-gate script (needs `cabal list-bin keiro-dsl` to resolve, i.e.
after `cabal build keiro-dsl`):

```bash
bash keiro-dsl/test/diff-test.sh
```

Expected final line: `PASS: diff --since gates the decode and identity surface` (extend the
message if you touch the script's summary).

Run the consumer-neutral matrix through the checked-in unit and shell fixtures. The abbreviated
output must contain separate private event, snapshot invalidate/rebuild, and public contract
findings, and the JSON report must preserve all context facts and zero-or-more rollout
constraints. No grammar or scaffold conformance test is added by this milestone.

ADR validation after Milestone 4 (strict OKF profile enforcement, including log freshness):

```bash
just adr-validate
```

which runs
`okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`
and must exit 0. If it reports a stale log, add the entry with `okf log add` (see
Milestone 4) and re-run.

Commit per milestone with conventional-commit messages on the current branch, e.g.:

```text
feat(dsl): attach per-surface compatibility vectors to diff findings
feat(dsl): classify diff findings from explicit use-site context
feat(dsl): render vectors and add diff --gate/--explain/--report-out
docs(adr): record the compatibility-vector diff output contract in ADR 0004
```


## Validation and Acceptance

**Soundness gate — the Proposal Test.** The research note's ten questions
(`docs/research/14-structural-consumer-type-tradeoffs.md`, "A Proposal Test for Future
Keiro Improvements") are answered for this change; questions 4 and 10 are the point of the
plan. 1 *Authority*: no codec or contract grammar changes hands; each private/public owner keeps
its existing schema authority. 2 *Replay*:
the differ and replay-impact computation are read-only over specs; the replay-impact
contract is untouched. 3 *Visibility*: no new guard/update syntax; nothing is hidden behind
checked DSL syntax. 4 *Compatibility direction*: this is the deliverable — the report now
distinguishes old-history reads (private-history-read), rolling deploys
(old-binary-read-new-events), snapshots (snapshot-hydration), queues (rollout
`workers-first` + private-history-read on `Wq*` codes), and public consumers
(public-consumer), verified by the consumer-neutral golden. 5 *Ownership*: private and public
findings stay separate and no type is shared across the boundary. 6 *Completeness*: explicit
vector fields make a new surface break constructors/encoders, while totality tests fail the
build if any emitted context/code pair lacks a vector or remedy; a new `DiagnosticCode` without rows fails
`keiro-dsl-test`. 7 *Migration*: no stored bytes change; the JSON extension is a new file
(`--report-out`) and the existing replay-impact file is byte-compatible. 8 *Recovery*: the
feature is report-only; a bad deploy of the tool cannot corrupt data, and `--gate` only
adds strictness. 9 *Performance*: the differ is a CLI over two parsed specs; vector lookup
is O(1) per finding — no measurable surface. 10 *Negative proof*: the no-weakening negative
test (below) plus the invariant test demonstrate the guarantee fails loudly if the
machinery is incomplete.

**No-weakening negative test (must exist and fail-before/pass-after appropriately).** A
fixture that is Breaking today must remain Breaking with vector output: diff-test.sh's
`reservation-fieldadd.keiro` scenario continues to exit non-zero printing
`BREAKING` with `EvtFieldAddedWithoutBump`, both without flags and with
`--gate old-binary-read-new-events`. In the unit suite, the invariant test asserts for the
whole exercised corpus that `deriveLabel defaultGate . ckVector` reproduces every
constructor label, so a registry row that would demote any Breaking finding fails the
suite. The gate-monotonicity QuickCheck property asserts gating can only add breakage.

**Observable acceptance.** Running `bash keiro-dsl/test/diff-test.sh` shows distinct findings
and paths for a private event addition, snapshot-cache invalidation, and an independently owned
public contract change. The event vector exposes old-binary/new-event risk, the snapshot vector
says invalidate/rebuild, the contract vector exposes public-consumer risk, and the JSON contains
the explicit context and rollout-constraint array.

**Regression.** `cabal test keiro-dsl-test`, `cabal test keiro-dsl-conformance-contract`,
and `bash keiro-dsl/test/diff-test.sh` all pass. `just adr-validate` exits 0 after the ADR
amendment. Existing golden/pinned scaffold output is unchanged because this plan adds no grammar
or scaffold feature.


## Idempotence and Recovery

Every step is additive and repeatable. Code edits are guarded by the test suite; re-running
cabal builds/tests is always safe. The diff-test.sh script builds in a `mktemp -d` repo and
cleans up on exit, so re-runs cannot pollute the working tree. Golden files are ordinary
checked-in text: if a rendering change is intentional, regenerate the golden by copying the
new rendered output after eyeballing the diff, and say why in a commit message. The ADR
amendment is a text edit plus `okf log add`; if `okf log add` is run twice, remove the
duplicate log entry and re-run `just adr-validate` (validation catches both staleness and
malformed entries). Milestone 2 changes classification metadata only; it can be reverted
independently of the vector core and never requires a contract grammar rollback.


## Interfaces and Dependencies

No new package dependencies. Everything lands in the existing `keiro-dsl` package
(`keiro-dsl/keiro-dsl.cabal`); JSON uses the already-depended `aeson`, and the CLI uses the
already-depended `optparse-applicative`.

At the end of Milestone 1, `Keiro.Dsl.Diff` additionally exports:
`CompatibilitySurface(..)`, `SurfaceVerdict(..)`, `RolloutConstraint(..)`, abstract
`ChangeContext` plus its named smart constructors/accessors,
`CompatibilityVector(..)`, `classifyCompatibility`, `defaultGate`,
`deriveLabel`, `gatedBreaking`, and `ChangeKind` makes `ckCode :: DiagnosticCode` mandatory and
gains `ckVector :: CompatibilityVector` and `ckPaths :: [Text]`.

At the end of Milestone 2, `ContractType` is unchanged; `DiagnosticCode` has appended
`EnumCtorAdded` and codes for every formerly uncoded additive finding (append-only), and every
change constructor requires `ChangeContext` and a code.

At the end of Milestone 3, a new module `Keiro.Dsl.DiffReport` (added to the library's
`exposed-modules`) owns `remediationFor :: ChangeContext -> DiagnosticCode -> NonEmpty Remedy`, the pure renderers
shared by CLI and tests (`renderFinding`, `renderVectorLine`, `renderExplainBlock`), the
surface-name spellings (`surfaceName :: CompatibilitySurface -> Text` and its inverse used
by `--gate`), and the `ToJSON` report encoding with schema id `keiro-dsl/diff-report/1`.
`keiro-dsl/app/Main.hs`'s `Diff` constructor gains the parsed `--gate`/`--explain`/
`--report-out` values. The report JSON contract (object-keyed vector, `paths` array,
ignore-unknown-keys, append-only) is the integration point consumed by
`docs/plans/149-implement-the-ir-1-spec-layer-resolved-type-graph-structural-and-opaque-declarations-check-and-diff.md`,
which owns recursive nested traversal while this plan owns the output shape.


---

Revision note: Removed the Mori-specific `CEnum -> Text` grammar shortcut; made vectors explicit
records, rollout constraints zero-or-more, classification context-sensitive, and codes mandatory
for additive findings; snapshots now report invalidate/rebuild, 2026-07-28.

Revision note: Added reusable recompile-consumer and run-conformance remedies so later mapped
consumer-type diagnostics can remain explicit without inventing a second remediation API; added
an explicit compile-forcing `consumer-build` surface instead of overloading persisted identity,
2026-07-28.

Revision note: Removed accidental verdict ordering, made all six surfaces and rollout arrays
explicit in the CLI/JSON contract, and promoted enum additions with rolling-deploy risk from
additive to advisory without changing default blocking behavior, 2026-07-28.
