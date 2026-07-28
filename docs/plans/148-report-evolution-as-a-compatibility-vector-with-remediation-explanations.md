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
per-surface classification over five named surfaces (private-history-read,
old-binary-read-new-events, snapshot-hydration, public-consumer, persisted-identity) plus a
rollout advisory (for example `producer-last`, `stop-the-world`, `drain-required`). A new
`diff --explain` mode prints, for each finding, the containing path, the compatibility
direction that fails, and the available remedies (version bump, upcaster, deployment order,
contract revision, replay-only edge). A new `--report-out` flag writes the full report as
JSON for tooling. The observable acceptance is the research note's Experiment D: adding one
union arm to an enum used by a private event, a snapshot-captured register, and a public
contract produces three findings with three containing paths and *distinct* per-surface
results, and no universal "additive" label hides the public-consumer risk.

The hard constraint is **no weakening**: anything classified `BREAKING` today remains
`BREAKING`; the vector refines the existing three-way classification, it never relaxes it;
`diff` continues to exit non-zero exactly when a surface the operator gates on is breaking,
and the default gate reproduces today's behavior bit for bit.


## Progress

- [ ] Milestone 1: vector core — `CompatibilitySurface`, `SurfaceVerdict`, `RolloutAdvisory`,
      `CompatibilityVector` types in `Keiro.Dsl.Diff`; `ckVector` on `ChangeKind`; per-code
      vector registry with totality test; label-derivation invariant test green.
- [ ] Milestone 2: per-use-site enum findings (`EnumCtorAdded`) and the minimal `enum`
      contract-field grammar extension (`CEnum`), with parser/pretty-printer round trip,
      `ContractEnumUnresolved` validation, and scaffold lowering.
- [ ] Milestone 3: CLI — vector rendering, `--gate`, `--explain`, `--report-out`; remediation
      registry with totality test; golden output tests; Experiment D fixture pair; diff-test.sh
      extended with the Experiment D scenario and the no-weakening negative test.
- [ ] Milestone 4: docs and ADR — `docs/guides/evolution-and-replayability.md` and
      `docs/guides/evolve-events-safely.md` updated; ADR 0004 inventory amended; `docs/adr/log.md`
      updated via okf; strict `just adr-validate` green; Proposal Test answers recorded.
- [ ] ADR distillation pass completed before marking the plan complete.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The vector is carried on every finding and the headline label
  (`ADDITIVE`/`WARNING`/`BREAKING`) is *derived* from the vector under a gate — a set of
  surfaces whose breaking verdicts block the merge. The default gate is
  {private-history-read, snapshot-hydration, public-consumer, persisted-identity}, i.e.
  exactly the surfaces today's classification already blocks on; old-binary-read-new-events
  is deliberately outside the default gate because today's differ never blocks on
  rolling-deploy direction. A breaking verdict on a non-gated surface is shown in the
  rendered vector (and promotes an otherwise-clean finding to at most `WARNING` only where
  this plan explicitly introduces a new finding), but never flips an existing headline. This
  is what makes "the vector refines, never relaxes" checkable: existing headlines and exit
  codes are preserved by construction, and operators opt into stricter gating with `--gate`.
  Rationale: hard constraint (a) of the MasterPlan scope; research note section 7 says the
  fix is better explanation and policy, "not weaker classification".
  Date: 2026-07-28

- Decision: Add a fifth surface, `persisted-identity`, beyond the research note's four.
  Rationale: roughly half of today's `Breaking` corpus (DerivedIdentityChanged,
  IdPrefixChanged, DedupeIdentityChanged, QueueIdentityChanged, RouterStableNameChanged,
  WorkflowStableNameChanged, …) is about re-keying persisted identities, not decoding.
  Folding those into private-history-read would blur the direction question the vector
  exists to answer. The vector shape is append-extensible (see the JSON decision below), so
  adding a surface now proves the extension mechanism plan 149 will rely on.
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

- Decision: Extend the contract grammar minimally with an enum-typed field
  (`CEnum Name` in `ContractType`), lowered to `Text` in the scaffolded contract payload ADT
  exactly like `CTypeId`. Rationale: Experiment D requires "a union used by … a public
  contract", and today `ContractType` is only `CTypeId | CText | CInt`
  (`keiro-dsl/src/Keiro/Dsl/Grammar.hs` line 668), so the scenario is inexpressible without
  it. Lowering to `Text` keeps the scaffold change one line and adds no new codec authority;
  the wire value is the enum's declared wire spelling. The full structural type-expression
  grammar belongs to plan 149 (EP-6); this plan owns only the output shape and this one
  minimal use-site.
  Date: 2026-07-28

- Decision: Per-code vector and remediation registries (`vectorFor`, `remediationFor`) keyed
  by `DiagnosticCode`, with unit tests enforcing totality over every code the differ can
  emit — the same registry-coverage style `familyRegistry` already uses. New codes
  (`EnumCtorAdded`, `ContractEnumUnresolved`) are appended at the end of the shared
  `DiagnosticCode` enum in `keiro-dsl/src/Keiro/Dsl/Validate.hs`; no existing code is
  renamed, reused, or reordered (constraint (b); ADR 0004 says tooling depends on the code,
  not prose).
  Date: 2026-07-28

- Decision: Enum-constructor additions are reported per use site (one finding per containing
  path) instead of one finding with a usage suffix, using the new `EnumCtorAdded` code. The
  private-event-use finding stays `ADDITIVE` (its breaking verdict is on the non-gated
  old-binary-read-new-events surface); the snapshot-register-use finding is `WARNING`
  (snapshot-hydration advisory: consider a state-codec version bump); the contract-use
  finding is `BREAKING` without a contract schemaVersion bump and `WARNING` with one,
  mirroring the existing contract field-add rule. The last two headlines are new findings on
  newly explicit or newly expressible surfaces, not relabelings of an existing breaking or
  passing verdict, so the no-weakening constraint holds.
  Date: 2026-07-28

- Decision: Rollout-advisory vocabulary is taken from ADR 0004's rollout-ordering section
  and `docs/user/deploy-ordering.md`, not invented: `any`, `stop-the-world` (single-version
  aggregate codec cutover), `workers-first` (queue workers before producers),
  `drain-required` (router/process decide surfaces need a drained redelivery window),
  `producer-last` (consumers/firers must learn new shapes before producers write them).
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

- **Surface**: one persistence/compatibility question asked of a change. The five surfaces:
  *private-history-read* (can the new binary decode and replay already-stored private
  events), *old-binary-read-new-events* (during a rolling deploy, can a still-running old
  binary decode what the new binary emits), *snapshot-hydration* (can persisted snapshot
  seeds still hydrate, or do they need a version bump/rebuild), *public-consumer* (can
  independent consumers of a declared contract keep decoding), *persisted-identity* (do
  replays/retries still derive the same persisted stream, dedupe, dispatch, and outbox
  identities).
- **Verdict**: per surface, one of `compatible`, `advisory`, `breaking`, `n/a`.
- **Gate**: the set of surfaces whose `breaking` verdict makes the process exit non-zero.
- **Rollout advisory**: a deployment-ordering obligation attached to the whole finding.


## Plan of Work

### Milestone 1 — the vector core inside `Keiro.Dsl.Diff` (no CLI change yet)

Scope: introduce the vector types, attach a vector to every `Change` the differ already
produces, and prove — by tests — that headline labels are exactly derivable from vectors
under the default gate. At the end of this milestone the library computes vectors and the
whole existing test corpus passes unchanged; nothing user-visible differs yet.

In `keiro-dsl/src/Keiro/Dsl/Diff.hs` add and export:

```haskell
data CompatibilitySurface
    = PrivateHistoryRead
    | OldBinaryReadNewEvents
    | SnapshotHydration
    | PublicConsumer
    | PersistedIdentity
    deriving stock (Eq, Ord, Show, Enum, Bounded)

data SurfaceVerdict = VCompatible | VAdvisory | VBreaking | VNotApplicable
    deriving stock (Eq, Ord, Show)

data RolloutAdvisory
    = RolloutAny | RolloutStopTheWorld | RolloutWorkersFirst
    | RolloutDrainRequired | RolloutProducerLast
    deriving stock (Eq, Show)

data CompatibilityVector = CompatibilityVector
    { cvVerdicts :: !(Map CompatibilitySurface SurfaceVerdict)  -- total over [minBound..]
    , cvRollout :: !RolloutAdvisory
    }
    deriving stock (Eq, Show)
```

Represent verdicts as a `Map` (total by smart constructor over `[minBound .. maxBound]`) so
plan 149 can append surfaces without touching every construction site; provide
`mkVector :: [(CompatibilitySurface, SurfaceVerdict)] -> RolloutAdvisory -> CompatibilityVector`
that fills unmentioned surfaces with `VNotApplicable`, and `uniformVector` for the trivial
all-compatible case.

Extend `ChangeKind` with two fields: `ckVector :: !CompatibilityVector` and
`ckPaths :: ![Text]` (containing root-to-leaf paths; for existing findings this is the
single path already implied by `ckNode`/`ckFacet`/`ckSubject`, e.g.
`"Reservation.event.ReservationMade.qty"` — construct it in one place). Keep the three
helper constructors' signatures working by giving them defaulting behavior: `breaking` and
`advisory` look their vector up from the code registry; `additive` uses `uniformVector`.
Add `additiveCoded :: Name -> Text -> Text -> DiagnosticCode -> Text -> Change` for the new
coded additive findings of Milestone 2.

Add the per-code vector registry:

```haskell
vectorFor :: DiagnosticCode -> CompatibilityVector
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
  `WorkflowContinueSeedChanged`): persisted-identity `VBreaking`, rollout `RolloutAny`
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
  private-history-read `VAdvisory` (replay reinterprets the log), rollout `RolloutAny`.
  `AggGuardTightened` → private-history-read `VAdvisory`, rollout `RolloutAny` (remedy is
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
  private-history-read `VBreaking` per the emission site, rollout `RolloutAny`.

Add the derivation and gate:

```haskell
defaultGate :: Set CompatibilitySurface   -- everything except OldBinaryReadNewEvents
deriveLabel :: Set CompatibilitySurface -> CompatibilityVector -> Label -- Additive|Advisory|Breaking
gatedBreaking :: Set CompatibilitySurface -> Change -> Bool
```

`deriveLabel gate v` is `Breaking` iff any gated surface is `VBreaking`; else `Advisory` iff
any surface (gated or not) is `VAdvisory` or the rollout is not `RolloutAny` or a non-gated
surface is `VBreaking`; else `Additive`. Do **not** rewrite the differ to construct changes
through `deriveLabel` — the existing constructors stay authoritative for this milestone.
Instead enforce coherence by test (below), so any registry row that would relabel an
existing finding fails loudly. Exception carve-out: because `RouterDecideSurfaceChanged`
etc. are already `Advisory` and their vectors carry `RolloutDrainRequired`, derivation
matches; for existing `Additive` findings the uniform vector derives `Additive`. Where a
registry row cannot match an existing headline under this rule, fix the row, not the rule.

Tests in `keiro-dsl/test/Main.hs`:

- *Registry totality*: for every fixture pair already exercised by the suite (reuse the
  `diffFixtures` helper and the in-memory `modifyRouter`/`modifyProcess`-style cases), every
  produced `Change` with a code has a `vectorFor` row that is not the placeholder, and
  every `Change` satisfies `deriveLabel defaultGate (ckVector k) == constructorOf change`.
  This is the machine-checked **no-weakening invariant**: the vector cannot relabel any
  existing finding under the default gate.
- *Gate monotonicity property* (QuickCheck over vectors): enlarging the gate never turns
  `Breaking` into a lesser label — `deriveLabel g v == Breaking` implies
  `deriveLabel (g <> g') v == Breaking`.

Acceptance: `cabal test keiro-dsl-test` passes; `bash keiro-dsl/test/diff-test.sh` still
passes with zero behavioral change (nothing renders vectors yet).

### Milestone 2 — per-use-site enum findings and the minimal contract-enum grammar

Scope: make the union-arm scenario expressible and reported per containing path. At the end,
`diffSpecs` reports one `EnumCtorAdded` finding per use site of a changed enum, and a
`.keiro` contract event field may be typed as a declared enum.

Grammar (`keiro-dsl/src/Keiro/Dsl/Grammar.hs`): extend
`data ContractType = CTypeId !Text | CText | CInt` with `| CEnum !Name`. Parser
(`keiro-dsl/src/Keiro/Dsl/Parser.hs`): where contract field types parse `typeid "…"`,
`text`, `int`, accept `enum <Name>`. Pretty-printer
(`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`): render it back as `enum <Name>`; add a
parse→print→parse round-trip case to the unit suite (the suite already has round-trip
patterns to copy). Validation (`keiro-dsl/src/Keiro/Dsl/Validate.hs`): append
`ContractEnumUnresolved` to the *end* of `DiagnosticCode` and reject, with `Error`
severity, a `CEnum` naming no declared enum. Scaffold
(`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, `emitPayloadAdt` around line 545): lower `CEnum _`
to `"Text"` exactly like `CTypeId`; the wire value is the enum's declared wire spelling
(state this in a comment). Diff (`renderContractType` in Diff.hs): render
`"enum '<Name>'"` so a `CTypeId`→`CEnum` retype is reported as the `ContractFieldChanged`
breaking type change it is.

Enum diff rework (`enumPairDiff` and `addedEnumDiff` in Diff.hs): for constructor
*additions*, replace the single usage-suffixed Additive finding with one finding per use
site, using a new appended code `EnumCtorAdded` and a use-site enumeration that extends the
existing `enumUsages` with contract use sites
(`<Contract>.event.<CtrEvent>.<field>` for every `CEnum` field naming the enum). Register
use sites additionally check whether the aggregate captures snapshots (the aggregate's
snapshot/state-codec declaration — see how `transitionSurfaceDiff`'s prose refers to
`state-codec version=`); if the aggregate declares no snapshot, the register use site's
snapshot-hydration verdict is `VNotApplicable` and the finding stays `ADDITIVE`. The three
finding shapes (all `ckCode = Just EnumCtorAdded`, each with its own `ckPaths`):

- event-field use: `additiveCoded`, vector {private-history-read `VCompatible`,
  old-binary-read-new-events `VBreaking`, rest n/a}, rollout `RolloutProducerLast`. Detail:
  the new binary decodes all old history, but an old replica cannot decode the new arm once
  a new replica emits it; deploy all readers before any emitter, or stop-the-world.
- snapshot-captured register use: `advisory` with vector {snapshot-hydration `VAdvisory`,
  old-binary-read-new-events `VBreaking`, rest n/a}, rollout `RolloutProducerLast`. Detail:
  the serialized snapshot state can now contain the new arm; bump `state-codec version=` if
  the captured shape changes meaning, per ADR 0003.
- contract-field use: if the containing contract's schemaVersion increased in this diff,
  `advisory` (public-consumer `VAdvisory`); otherwise `breaking` (public-consumer
  `VBreaking`). Rollout `RolloutProducerLast`. Detail: a closed consumer of the declared
  contract may reject the new arm indefinitely; bump schemaVersion and coordinate the
  cross-service rollout, or revise the contract.

An enum with *no* use sites keeps a single `additiveCoded` finding with the uniform vector,
so pure declarations do not vanish from the report. Constructor removal/respelling handling
is untouched (still Breaking — no weakening).

Tests: unit cases in `keiro-dsl/test/Main.hs` matching on `EnumCtorAdded` plus surface
verdicts for each of the three use-site kinds; a `ContractEnumUnresolved` rejection case; a
no-weakening case asserting `EnumCtorRemoved` is still `Breaking` with
private-history-read `VBreaking`.

Acceptance: `cabal test keiro-dsl-test` and `cabal test keiro-dsl-conformance-contract`
pass (the latter proves scaffolded contract modules still compile; the `CEnum` lowering is
additive so existing pinned scaffold output is byte-identical).

### Milestone 3 — CLI rendering, `--gate`, `--explain`, `--report-out`, goldens, Experiment D

Scope: make the vector visible and actionable. At the end, the CLI prints vectors, an
operator can gate on extra surfaces, `--explain` prints remediation blocks, `--report-out`
writes machine JSON, and the Experiment D scenario is a checked-in fixture pair with golden
output plus a diff-test.sh scenario.

In `keiro-dsl/app/Main.hs`, extend the `Diff` command with `--gate SURFACE` (a `many`
`strOption`; accepted spellings are the kebab-case surface names
`private-history-read`, `old-binary-read-new-events`, `snapshot-hydration`,
`public-consumer`, `persisted-identity`; unknown spellings are a usage error listing the
valid set), `--explain` (switch) and `--report-out FILE` (option). Behavior:

- The headline line grammar is unchanged (`ADDITIVE:`/`WARNING:`/`BREAKING:` … `[Code]`).
  After any finding whose vector is not uniformly `VCompatible`/`VNotApplicable`, print one
  indented continuation line:
  `    vector: private-history-read=compatible old-binary-read-new-events=breaking … rollout=producer-last`
  (omit `n/a` surfaces for readability; always print rollout when not `any`). Adding lines
  is safe for `diff-test.sh`, which greps substrings.
- Exit: non-zero iff any change is breaking on the *effective* gate = `defaultGate` plus
  the `--gate` surfaces. With no `--gate` flags this is exactly `any isBreaking changes` —
  assert that equivalence in the unit suite (constraint (a)).
- `--explain`: after the findings, print one block per finding whose vector is non-uniform
  or whose headline is not `ADDITIVE`, containing the containing path(s) (`ckPaths`), the
  failing direction stated as a sentence (name the surface and which side fails), and the
  remedies from a new registry in Diff.hs:

```haskell
data Remedy = RemedyVersionBump | RemedyUpcaster | RemedyDeploymentOrder RolloutAdvisory
            | RemedyContractRevision | RemedyReplayOnlyEdge | RemedyStateCodecBump
            | RemedyDoNotDeploy Text  -- rename/re-key class: revert or migrate operationally
remediationFor :: DiagnosticCode -> [Remedy]
```

  Render each remedy as one imperative line; `RemedyReplayOnlyEdge` cites
  `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`.
  Totality test: every code the differ can emit has a non-empty remedy list.
- `--report-out FILE`: write JSON (new `ToJSON` instances in Diff.hs or a small
  `Keiro.Dsl.DiffReport` module — prefer the new module to keep Diff.hs pure):

```json
{
  "schema": "keiro-dsl/diff-report/1",
  "gate": ["private-history-read", "snapshot-hydration", "public-consumer", "persisted-identity"],
  "breaking": true,
  "findings": [
    { "label": "breaking", "node": "ReservationFeed", "facet": "contract-field",
      "subject": "ReservationChanged.status", "code": "EnumCtorAdded",
      "paths": ["ReservationFeed.event.ReservationChanged.status"],
      "vector": { "private-history-read": "n/a", "old-binary-read-new-events": "n/a",
                  "snapshot-hydration": "n/a", "public-consumer": "breaking",
                  "persisted-identity": "n/a", "rollout": "producer-last" },
      "detail": "…", "remedies": ["bump the contract schemaVersion", "revise the contract"] }
  ]
}
```

  Document in the module haddock: consumers must ignore unknown keys; `vector` keys and
  `paths` entries are append-only. This is the shape plan 149 adopts for recursive nested
  classification. The `--replay-impact-out` file is untouched.

Fixtures and goldens: create `keiro-dsl/test/fixtures/experimentd.keiro` — one spec with an
enum (say `ReservationStatus { Pending=pending Confirmed=confirmed }`) used by (1) an event
field of an aggregate, (2) a register of the same aggregate with snapshots enabled, and (3)
a `CEnum` field of a contract event — and `experimentd-armadd.keiro`, identical plus the
arm `Archived=archived` and no schemaVersion bump. Model both on the existing
`reservation*.keiro` fixtures so they parse and check cleanly (run
`cabal run keiro-dsl -- check` on each while authoring). Add a golden test to
`keiro-dsl/test/Main.hs`: diff the pair, render the full report (headline lines, vector
lines, and the `--explain` blocks via the same pure rendering functions the CLI uses —
factor rendering out of `app/Main.hs` into the library so the test and the CLI share it),
and compare against a checked-in golden file
`keiro-dsl/test/fixtures/experimentd.diff.golden` (follow the suite's existing
file-comparison style; on mismatch print a diff). The golden must show three `EnumCtorAdded`
findings with three distinct paths and distinct vectors, exactly one of them `BREAKING`
(the contract path).

Extend `keiro-dsl/test/diff-test.sh` with two scenarios: (a) Experiment D — commit
`experimentd.keiro`, swap in `experimentd-armadd.keiro`, assert exit non-zero, assert the
output contains all three paths and the substrings `public-consumer=breaking` and
`old-binary-read-new-events=breaking`, and assert the event-path finding line begins
`ADDITIVE:` (no universal label, no hidden risk); (b) the no-weakening negative test —
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
  guard-tightening walkthrough at ~line 260) showing the Experiment D transcript excerpt.
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
  paragraph defining the compatibility-vector output contract — five surfaces, verdict
  values, rollout vocabulary (cross-reference its own rollout-ordering bullets), default
  gate, `--gate` semantics, the `keiro-dsl/diff-report/1` JSON schema id with
  append-only/ignore-unknown rules, and the statement that headlines and codes remain the
  machine contract with vectors as a refinement; (2) add an inventory row for "Union-arm
  addition at a classified use site" (check: `ContractEnumUnresolved` Error for dangling
  references; diff: per-use-site `EnumCtorAdded` vectors; runtime: old binaries reject
  unknown arms at decode). Update the frontmatter `timestamp` to the amendment time (keep
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

Contract-scaffold conformance after Milestone 2's `CEnum` lowering:

```bash
cabal test keiro-dsl-conformance-contract
```

Manual Experiment D run while developing Milestone 3 (mirrors what diff-test.sh automates —
a throwaway git repo so `--since HEAD` has a baseline):

```bash
EXE="$(cabal list-bin keiro-dsl)"
DEMO="$(mktemp -d)"; git -C "$DEMO" init -q
cp keiro-dsl/test/fixtures/experimentd.keiro "$DEMO/svc.keiro"
git -C "$DEMO" add svc.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm baseline
cp keiro-dsl/test/fixtures/experimentd-armadd.keiro "$DEMO/svc.keiro"
"$EXE" diff --since HEAD --explain --report-out "$DEMO/report.json" "$DEMO/svc.keiro"; echo "exit=$?"
```

Expected output shape (abbreviated; exact text is pinned by the golden):

```text
ADDITIVE: Reservation event ReservationMade.status: new enum arm 'Archived' … [EnumCtorAdded]
    vector: private-history-read=compatible old-binary-read-new-events=breaking rollout=producer-last
WARNING: Reservation reg status: new enum arm captured by the snapshot state codec … [EnumCtorAdded]
    vector: snapshot-hydration=advisory old-binary-read-new-events=breaking rollout=producer-last
BREAKING: ReservationFeed contract-field ReservationChanged.status: new enum arm without a schemaVersion bump … [EnumCtorAdded]
    vector: public-consumer=breaking rollout=producer-last
…explain blocks…
exit=1
```

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
feat(dsl): report enum arm additions per use site and allow enum contract fields
feat(dsl): render vectors and add diff --gate/--explain/--report-out
docs(adr): record the compatibility-vector diff output contract in ADR 0004
```


## Validation and Acceptance

**Soundness gate — the Proposal Test.** The research note's ten questions
(`docs/research/14-structural-consumer-type-tradeoffs.md`, "A Proposal Test for Future
Keiro Improvements") are answered for this change; questions 4 and 10 are the point of the
plan. 1 *Authority*: no codec changes hands; the spec remains the wire authority; `CEnum`
lowers to the declared wire spelling through the same generated payload ADT. 2 *Replay*:
the differ and replay-impact computation are read-only over specs; the replay-impact
contract is untouched. 3 *Visibility*: no new guard/update syntax; nothing is hidden behind
checked DSL syntax. 4 *Compatibility direction*: this is the deliverable — the report now
distinguishes old-history reads (private-history-read), rolling deploys
(old-binary-read-new-events), snapshots (snapshot-hydration), queues (rollout
`workers-first` + private-history-read on `Wq*` codes), and public consumers
(public-consumer), verified by the Experiment D golden. 5 *Ownership*: private and public
findings stay separate — the contract-use finding is a distinct finding on a distinct path;
no type is shared across the boundary. 6 *Completeness*: registry totality tests fail the
build if any emitted code lacks a vector or remedy row, mirroring `familyRegistry`'s
coverage discipline; a new `DiagnosticCode` without registry rows fails
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

**Observable acceptance (Experiment D).** Running the Milestone 3 manual transcript (or
`bash keiro-dsl/test/diff-test.sh`) shows: three `EnumCtorAdded` findings with three
distinct containing paths (`…event.….status`, `….reg.status`,
`…contract….ReservationChanged.status`); distinct vectors per the transcript above; exit
code 1 driven by the public-consumer surface; and the event-path finding still headlined
`ADDITIVE` while its vector line exposes `old-binary-read-new-events=breaking` — i.e. no
universal label, no hidden risk. `report.json` validates against the documented shape
(spot-check with `jq .findings[].vector "$DEMO/report.json"`).

**Regression.** `cabal test keiro-dsl-test`, `cabal test keiro-dsl-conformance-contract`,
and `bash keiro-dsl/test/diff-test.sh` all pass. `just adr-validate` exits 0 after the ADR
amendment. Existing golden/pinned scaffold output is unchanged (the `CEnum` arm is new; no
existing fixture uses it).


## Idempotence and Recovery

Every step is additive and repeatable. Code edits are guarded by the test suite; re-running
cabal builds/tests is always safe. The diff-test.sh script builds in a `mktemp -d` repo and
cleans up on exit, so re-runs cannot pollute the working tree. Golden files are ordinary
checked-in text: if a rendering change is intentional, regenerate the golden by copying the
new rendered output after eyeballing the diff, and say why in a commit message. The ADR
amendment is a text edit plus `okf log add`; if `okf log add` is run twice, remove the
duplicate log entry and re-run `just adr-validate` (validation catches both staleness and
malformed entries). If Milestone 2's grammar change causes unexpected conformance breakage,
it can be reverted independently of Milestone 1 — the vector core does not depend on
`CEnum`; only the Experiment D contract leg does.


## Interfaces and Dependencies

No new package dependencies. Everything lands in the existing `keiro-dsl` package
(`keiro-dsl/keiro-dsl.cabal`); JSON uses the already-depended `aeson`, and the CLI uses the
already-depended `optparse-applicative`.

At the end of Milestone 1, `Keiro.Dsl.Diff` additionally exports:
`CompatibilitySurface(..)`, `SurfaceVerdict(..)`, `RolloutAdvisory(..)`,
`CompatibilityVector(..)`, `mkVector`, `uniformVector`, `vectorFor`, `defaultGate`,
`deriveLabel`, `gatedBreaking`, and `ChangeKind` gains `ckVector :: CompatibilityVector`
and `ckPaths :: [Text]`.

At the end of Milestone 2, `Keiro.Dsl.Grammar.ContractType` has the `CEnum !Name`
constructor; `Keiro.Dsl.Validate.DiagnosticCode` has appended constructors `EnumCtorAdded`
and `ContractEnumUnresolved` (append-only; nothing renamed or reordered);
`Keiro.Dsl.Diff` exports `additiveCoded`.

At the end of Milestone 3, a new module `Keiro.Dsl.DiffReport` (added to the library's
`exposed-modules`) owns `remediationFor :: DiagnosticCode -> [Remedy]`, the pure renderers
shared by CLI and tests (`renderFinding`, `renderVectorLine`, `renderExplainBlock`), the
surface-name spellings (`surfaceName :: CompatibilitySurface -> Text` and its inverse used
by `--gate`), and the `ToJSON` report encoding with schema id `keiro-dsl/diff-report/1`.
`keiro-dsl/app/Main.hs`'s `Diff` constructor gains the parsed `--gate`/`--explain`/
`--report-out` values. The report JSON contract (object-keyed vector, `paths` array,
ignore-unknown-keys, append-only) is the integration point consumed by
`docs/plans/149-implement-the-ir-1-spec-layer-resolved-type-graph-structural-and-opaque-declarations-check-and-diff.md`,
which owns recursive nested traversal while this plan owns the output shape.
