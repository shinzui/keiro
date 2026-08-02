---
type: Architecture Decision Record
title: Evolution changes are gated at the earliest sound boundary
description: Each evolution hazard is checked at the earliest boundary with enough evidence, while later boundaries independently defend runtime assembly.
timestamp: 2026-08-02T15:22:00Z
docId: ADR-4
status: Accepted
date: 2026-07-23
---

# 4. Evolution changes are gated at the earliest sound boundary

Date: 2026-07-23

Status: Accepted


## Context

Event-sourced evolution crosses several evidence boundaries. A single `.keiro`
spec can prove that a codec shape is internally impossible, but it cannot know
which rungs existed in the previous release or whether production streams still
contain a retired event. A cross-spec diff can see declarations disappear, but
it cannot guarantee that hand-written runtime assembly matches either spec.
Startup validation can inspect the actual codec and transducer, but it cannot
prove that a genuine historical payload still decodes or inverts. Treating any
one of these layers as the complete evolution gate created the gaps found by
the July 2026 review.


## Decision

Evolution checks live at the earliest boundary with enough evidence, and later
boundaries independently defend runtime assembly:

1. `keiro-dsl check` rejects properties provably invalid in one spec.
2. `keiro-dsl diff` classifies hazards that require old and new declarations.
3. `validateEventStreamWith` validates the actual runtime codec and transducer;
   every resulting `EventStreamWarning` fails validated construction.
4. Versioned old-payload JSON fixtures exercise `decodeRaw` against the current
   codec in conformance CI.
5. The database-backed replay audit covers the distinct
   question that static fixtures cannot answer: whether real stored histories
   still invert and fold under the candidate binary.

Machine-readable `DiagnosticCode` values correlate `check` and `diff`.
Human-readable text explains the operational remedy, but tooling depends on
the code rather than prose.

Aggregate type syntax and capabilities follow the same rule. Parsing establishes
only a `TypeExpr`; `check` resolves it at the declaration or guard use site and
rejects unknown types, unsupported direct shapes, invalid register initials,
cross-type comparisons, and unsupported comparison capabilities. These codes are
append-only. Scaffolding reuses the checked resolver as defense in depth but is
not the first place an aggregate author learns that a type cannot be lowered.

Language-version-2 scalar expressions follow the same rule. `check` resolves
every root, required structural path, contextual literal, operand, operator,
guard, and write before generation. A transition also resolves to exactly one
behavior owner. Successful generation lowers that checked tree directly to the
Keiki structure used for both concrete execution and symbolic translation;
scaffolding cannot turn an invalid expression into a hand-written TODO or let a
Hole replace generated behavior.

Language dispatch is earlier than every semantic gate, but dispatch alone is
not sufficient when a released successor changes runtime behavior. Parsing a
source or composing a same-version workspace constructs `CheckedService`, which
pairs the normalized graph with one effective runtime-semantics contract.
Validation, scaffold/harness planning, fold fingerprints, diff, and replay
impact receive that value. A mixed-version workspace or a mismatched
source/service execution is refused before any output path is created.

The language frontend makes those early boundaries machine-visible. A malformed or unsupported
preamble fails in `SourceSelectionPhase`; an unexpected body token, misplaced/duplicate preamble,
or disabled grammar production fails in `BodyParsingPhase`; invalid surface ownership or ordering
fails in `LoweringPhase`. Each failure carries a stable code and exact primary source span before
Megaparsec details are hidden. Human messages and the released `ParseFailure` rendering remain
compatibility projections, so tooling branches on phase/code rather than scraping prose. Semantic
validator `DiagnosticCode` values remain downstream because their evidence exists only after
lowering.

The landed inventory is:

| Change class | Single-spec `check` | Cross-spec `diff` | Runtime boundary / CI |
|---|---|---|---|
| Effective language runtime semantics change | The parser selects a supported contract and workspace composition requires one effective version | Contract-aware fold/diff planning reports runtime-semantic changes independently of source provenance | Generated fold fingerprints add a discriminator only when runtime/fold behavior can differ; scaffold history persists the checked contract and replay impact consumes it |
| Invalid schema version, duplicate event tags, out-of-range rung | Not all are expressible in the DSL | Not required | `mkCodec` fails validated stream construction |
| Different event kinds change at the same source version | Allowed; chain continuity still applies | Version bumps remain Additive only with their declared upcasts | Scaffolder merges them into one unique rung that dispatches by `EventType`; `mkCodec` validates the resulting codec |
| Upcaster accidentally rewrites another event kind at the same aggregate version | Not author-expressible in generated code | No separate classification needed | Generated rung dispatch passes foreign kinds through byte-for-byte; codec-level conformance invokes each owning upcaster |
| Missing aggregate rung | `UpcasterChainGap` Error | Vanished historical rung is Breaking `UpcasterChainGap` | `mkCodec` rejects startup; versioned JSON golden fails decode |
| Event payload version bump | Contiguous upcaster required | `diff --emit-goldens` captures the old wire shape while both specs exist | `scaffold --goldens` embeds the fixture and the generated harness exercises `decodeRaw`; a stand-in is labelled as weaker when no golden exists |
| `retiring` event without a live emitter | `EventRetirementInProgress` Error | Retirement start is Advisory | Generated shape remains the ordinary live machine |
| Deprecated event without a replay-only emitter | `DeprecatedEventReplayHazard` Warning | Advisory with the same code | Targeted real-log audit proves whether stored streams still invert |
| Deprecated event with a replay-only emitter | `EventRetirementInProgress` Warning | Replay-safe cutover Advisory | Transducer boundary validates the replay-only edge |
| Guard tightening | Replay-only edge discipline from ADR 0002 | `AggGuardTightened` prints the retained twin and affected replay surface | Targeted real-log audit fails without a required twin and passes with it |
| Fold/control-state, generated guard/write, or transition-ownership change | Snapshot contract from ADR 0003 | `AggFoldSurfaceChanged` Advisory plus a deterministic replay-impact target | Generated fold fingerprint changes and the snapshot discriminator rejects stale seeds; audit named histories before cutover |
| Forward/replay state divergence (dishonest wire/inversion boundary, later mapped-register bindings) | `validateTransducer` in the generated harness proves the declared structure; honesty of `WireCtor`/`InCtor` is not spec-expressible | Not required | Generated harness steps fixture commands forward, decodes the emitted chain through the generated codec, replays via `applyEventsEither`, and compares final vertex and every register in conformance CI; the DB-backed replay audit and the advisory post-append verification remain the stored-history and production gates |
| New scaffolded workqueue payload | No payload-evolution grammar yet | Existing workqueue shape changes keep their normal classifications | Generated `QueueCodec` starts at schema version 1 with a `keiroJobCodec` `{v,t,data}` envelope; existing bare-payload queues must drain before adoption |
| Replay-impacting aggregate change | — | `replay-neutral`, or deterministic per-aggregate event types and snapshot-stream inclusion | `AuditTargeted` reads only selected streams; replay failure or seed divergence exits 1 |
| Version-2 Hole predicate/update change | The checked envelope is visible, but arbitrary terms are not | Per-transition `FoldVersion` is composed into the generated aggregate fingerprint; ownership verification reports opaque predicates as unverified | Bump the token, re-scaffold/rebuild, and audit affected histories; retaining the token is a contract violation backed only by sampled seed/full-replay divergence |
| Version-1 Hole-only or other hand-written fold change with a missed version bump | Invisible | Invisible | One in 1000 accepted seeds is full-replayed through its immutable seed version; divergence increments `keiro.snapshot.seed.divergence` |
| Router/process decide surface | — | `RouterDecideSurfaceChanged` / `ProcessDecideSurfaceChanged` Advisory | Drain the subscription redelivery window; hole-only changes keep the same manual rule |
| Process timer payload | — | `ProcessTimerPayloadChanged` Advisory | Firers must decode every pending unversioned shape or the timer exhausts attempts and dead-letters |
| Invalid mapped declaration (missing provenance, ambiguous or recursive reference, non-injective nullability, invalid default, encoding collision, unsupported guard, or missing register initial) | Stable mapped diagnostic at the owning declaration or use site | Not required | Correct the single-spec contract before generation; opaque mode remains an explicit, separately checked boundary |
| Invalid direct aggregate type or capability (unknown type, direct Json/container shape, malformed Time or Natural initial, mismatched comparison, or unsupported ordering) | Stable aggregate diagnostic at the declaration, initial, or guard use site | Canonical resolved identities feed the existing aggregate diff and fold surfaces | Correct the spec before generation; a clean spec has total Time/Natural type, import, package, codec, snapshot, and sample lowering |
| Invalid version-2 scalar expression (unknown/ambiguous root, unsupported path, invalid literal, mixed operands, unsupported operator, non-Bool guard, or wrong write type) | Stable `AggregateExpression*` diagnostic at the exact source row; reserved collection forms fail as `CollectionExpressionUnsupported` | Not required | Correct the source before scaffolding; successful checking yields one typed term/predicate tree used by concrete execution and symbolic translation |
| Mixed generated/Hole transition authority | `AggregateTransitionOwnershipConflict` rejects `implementation hole` beside a DSL guard or write | Generated assembly retains command, event, target, and mode envelope checks | Choose one owner. Keep generated ownership for checked scalar behavior, or move all predicate/update behavior into the stable Hole and supply its `FoldVersion` |
| Invalid version-2 event-output authority or eventless state change | `EventOutputCommandMismatch` rejects a `fields(Command)` copy owned by another command; `AggregateEventlessStateChange` rejects a transition that changes vertex or registers without persisted events | Mapping ownership and eventless semantics contribute to the fold/obligation fingerprint | Generated total identity copies have no output Hole; explicit fields remain hand-owned. An empty accepted edge is a no-op only when vertex and registers are unchanged |
| Incomplete finite aggregate behavior evidence | `behavior-obligations` inventories every live transition from a live-reachable state, every reachable rejection cell, and every replay-only edge without claiming consumer fill status | Scaffold/workspace records report added and removed stable semantic keys while preserving create-once Haskell | The consumer-compiled `keiro/behavior-conformance/1` gate rejects pending, missing, duplicate, stale, false, or misattributed witnesses after codec-crossing forward/replay execution; unverified evidence remains separately gateable |
| Invalid nominal binding declaration (incomplete provenance, invalid Haskell/qualified/canonical identity, invalid TypeID prefix, unsupported or empty representation, missing register initial, or cross-category collision) | Stable `Nominal*` diagnostic at the owning declaration; version-1 use fails earlier as `LanguageFeatureRequiresVersion` | Not required | Correct the declaration before generation; GHC and conformance validate hand-written function bodies |
| Nominal binding, fixture, canonical, initial, or representation change | Required facts are checked but consumer behavior is not inspected | Separate consumer-build, snapshot-hydration, wire-history, and replay findings target each containing use; fixture-only changes request evidence without claiming runtime change | Recompile and rerun conformance, invalidate register snapshots when named, and audit affected old event histories for opaque binding changes |
| Bound-ID adoption at an existing event use | The new declaration and TypeID prefix are valid | `NominalIdDecoderTightened` is a private-history-read advisory even when valid wire bytes and prefix are unchanged | A committed valid pre-adoption payload must decode, and a targeted real-log audit must pass; already-valid bytes need no fabricated upcast |
| Enforced ID-domain adoption, removal, or change | The effective language contract selects one checked domain; current construction, JSON, literals, and consumer conversion validate before use | `IdDomainContractChanged` classifies private history, old-binary reads, snapshot hydration, public consumers, persisted identity, consumer builds, and producer-last rollout independently | Generated historical event codecs alone retain the internal legacy constructor; generated/consumer harnesses prove exact runtime/Keiki agreement and binding representation probes; snapshots miss under ADR 0003 and real affected streams are audited before cutover |
| Language-4 public-contract TypeID admission | `ContractInvalidTypeIdPrefix` rejects an invalid declared prefix before scaffolding; versions 1 through 3 retain their released permissive contract graph | For an unchanged `typeid` field, `ContractTypeIdDomainChanged` reports public-consumer and consumer-build breakage plus producer-first and drain-required rollout; a source field edit remains only `ContractFieldChanged` | Generated `KindID prefix` DTOs keep canonical JSON text for valid values and reject malformed, wrong-prefix, non-canonical, and non-v7 input at the field path; make producers conform, drain or remediate invalid in-flight messages, then re-scaffold and compile consumers and run contract conformance |
| Invalid closed policy, duplicate, external-name, intake-coupling, contract-topology, or aggregate-wire surface | Values that cannot lower or generate a working service are rejected under every language version; usable-but-ambiguous values are rejected by `keiro-dsl/runtime-semantics/3` under language 4, including numeric floors, shadows, stable identities, Kafka/PostgreSQL names, intake envelope/schema references, topic aliases, and unsupported wire words | Not required; these are internally decidable properties of one checked graph | Correct the spec before scaffolding. Emit source/key/discriminant names remain documented as descriptive-only because no typed source namespace exists; generation must not pretend they were resolved |
| Mapped structural wire change | Single-spec shape remains valid | Recursive mapped diagnostic at every complete command, event, and register root path; event history, old-binary rollout, snapshot hydration, and consumer build are classified independently | Version and upcast affected events, rebuild affected snapshots, and recompile affected consumers according to the finding's compatibility vector |
| Mapped source, binding, fixture, canonical identity, or opaque-codec provenance change | Required facts and identities are checked | Declaration-level build or identity finding; opaque codec-version changes remain historical-read hazards even when no structural shape is visible | Recompile consumers, bump binding provenance, or migrate the declared opaque codec as directed; no Haskell source inspection is claimed |
| Structural binding correctness | The declaration names one total binding and a non-empty fixture corpus | Binding-version and canonical-identity changes are consumer-build findings | Generated conformance checks domain→shape→domain and shape→domain→shape for every fixture; a transposed-field mutation must fail |
| Generated mapped-payload codec | The resolved graph rejects non-injective and ambiguous wire shapes | Recursive mapped changes classify every containing event/register root and rollout surface | Generated conformance round-trips every fixture and containing event, then compares current encoded bytes with a committed JSON golden |
| Structural fixture branch coverage | The checked declaration requires a non-empty fixture symbol but cannot execute consumer code | Fixture provenance changes are visible consumer-build changes | Generated conformance requires every enum/union arm and both optional branches; missing/null/unknown-field cases are separately schema-generated, and an omitted-arm mutation must fail |
| Structural adoption coverage and brownfield codec evidence | `check --coverage-report` emits named structural, opaque, and `Json` private-event roots plus separate consumer-JSON register cache boundaries; `--fail-on-opaque` is an explicit local policy | `diff --coverage-report` emits previous counts and named deltas; `CoverageOpaqueBoundaryAdded` is advisory unless `--fail-on-opaque-increase` is selected | A consumer-compiled historical-codec comparison classifies finite fixtures as canonical JSON parity or explicit version/upcaster work; it never becomes a runtime fallback or upgrades opaque mode |
| Scaffold mapping drift | Mapping facts are internally validated before generation | `diff` classifies wire, canonical, binding-version, codec-version, and consumer-build changes | The scaffold record persists canonical mapping rows and reports binding/wire/initial/projection drift before generated files are accepted |
| Synthesized mapped old-payload golden | — | `diff --emit-goldens` traverses the complete checked old shape and labels synthesized output as a weak stand-in | Replace it with a hand-captured historical payload when available; emission never overwrites existing evidence |
| Private enum constructor addition | — | One `EnumCtorAdded` finding per containing event/register path; event use is old-binary/new-event breaking and register use is snapshot-hydration advisory | Deploy consumers before producers and invalidate/rebuild affected snapshots |
| Snapshot-cache invalidation | Snapshot contract from ADR 0003 | `snapshot-hydration=advisory` identifies rebuild rather than event upcast work | The three-component discriminator rejects stale seeds; bump `state-codec version=` for invisible hand-owned changes |
| Public contract change | Single-spec ownership checks only | Existing contract codes classify `public-consumer` independently from private history and identity | Deploy compatible consumers before producers or revise/version the contract |
| Workspace ownership or authority change | Workspace composition establishes one owner and one manifest authority per service (ADR 0014) | `OwnershipMoved` and `WorkspaceAuthorityChanged` are consumer-build advisories beside, never instead of, merged-graph wire findings | Re-scaffold the whole workspace so its record follows ownership and authority; existing wire findings keep their own remediation and gates |

Every cross-spec finding carries a compatibility vector over six surfaces:
`private-history-read`, `old-binary-read-new-events`,
`snapshot-hydration`, `public-consumer`, `persisted-identity`, and
`consumer-build`. Each verdict is `compatible`, `advisory`, `breaking`, or
`n/a`. Rollout constraints are a zero-or-more set using the vocabulary below:
`stop-the-world`, `workers-first`, `drain-required`, `producer-last`, and
`producer-first`. The
default gate contains every surface except `old-binary-read-new-events`, which
preserves the previous merge-blocking behavior; repeated `--gate` flags only
add surfaces. ADDITIVE/WARNING/BREAKING headlines and append-only
`DiagnosticCode` values remain the stable text contract, while the vector is
their context-sensitive refinement. `--report-out` writes schema
`keiro-dsl/diff-report/1`; object keys and containing paths are append-only and
readers must ignore unknown keys. The existing replay-impact JSON contract is
unchanged.

For a `.keiro-workspace` input, the cross-spec boundary is the two composed
service graphs, not any individual member file. The old graph is reconstructed
from the manifest and member blobs at the requested git revision; the new graph
comes from the working tree. Shared declarations are therefore classified at
every use site across every member. Changing only a declaration's owning member
emits `OwnershipMoved`; changing the manifest's service, effective context,
module root, or layout emits `WorkspaceAuthorityChanged`. Both codes carry only
a `consumer-build=advisory` verdict and cannot block any gate. They never
suppress accompanying wire or persisted-identity findings — for example, a
context rename still emits the existing `DerivedIdentityChanged` breaks for
read-model registry and subscription names. Workspace reports retain schema
`keiro-dsl/diff-report/1` and add only ignore-unknown `workspace`,
`declaration`, and `useSites` keys. ADR 0014 defines the workspace identity,
single-owner rule, and manifest authority used at this boundary.

The replay-impact machine contract is
`{"verdict":"replay-neutral"}` or
`{"verdict":"affected","aggregates":{...}}`; affected event arrays are sorted.
Generated DSL services expose one context-wide
`auditTargets :: [SomeAuditTarget]` in declaration order. Audit discovery is
read-only, indexed, budget-bounded, parallel, and resumable; `AuditFull` is for
one-time cutovers and forensics. Correctness compares RFC 8785 canonical bytes;
SHA-256 digests are review identifiers. Any replay failure, rejected discovered
stream, or seeded/full divergence makes `auditExitCode` return 1.

The same evidence boundaries determine rollout ordering:

- An aggregate codec has one version for both writing and decoding. A version
  bump therefore cannot run against a stream category with mixed old and new
  replicas; use stop-the-world or blue/green cutover. After the first
  new-version event, rollback is roll-forward-only because old code returns
  `VersionAhead`.
- Versioned job queues deploy workers before producers. A future envelope is
  retried as `JobPayloadFromFuture`, consuming the configured delivery budget;
  changing a non-empty queue between bare and `{v,t,data}` shapes requires a
  drain or a transitional dual decoder.
- Router and process-manager decide changes require a drained redelivery
  window. Deterministic target-command ids intentionally confirm overlaps as
  benign duplicates, so mixed-version fan-out otherwise merges silently.
- Timer payloads, cross-service integration payloads, and workflow step results
  have no automatic migration boundary. Firers/consumers must learn new shapes
  before producers write them, old decoders remain until backlogs drain, and a
  changed workflow result gets a new step name.
- Tightening an unchanged public contract `typeid` field to language-4
  admission reverses that generic consumer-first order: every producer must
  emit the frozen TypeID-v7 domain first, then legacy-invalid in-flight
  messages must drain or be remediated before strict generated consumers deploy.
- Non-neutral transducer changes require the targeted
  real-log audit before traffic switches. Full-store replay remains a
  one-time-cutover and forensics mode, not a routine deploy gate.


## Consequences

- Hand-written streams receive the same codec fail-fast behavior as generated
  streams; generator validation is defense in depth, not the sole gate.
- `check` may warn rather than reject when the missing fact is operational
  history, such as whether live streams still contain a deprecated event.
- A decode golden proves decode compatibility only. It must never be described
  as proof that an old event still has an inverting edge or folds identically.
- Golden synthesis never overwrites an existing file, so hand-captured
  production payloads remain authoritative.
- The generated job codec changes payload bytes only. It does not alter the
  span and acknowledgement contract in ADR 0001.
- `mkEventStreamUnchecked` remains the explicit emergency-forensics bypass and
  skips every layer at the stream boundary; it is not a production rollout
  workaround.
- The inventory is amended when a later child plan changes a gate's ownership
  or closes one of the named audit residuals.
- Aggregate type support cannot be introduced only in a generator template.
  The parser, resolver, use-site capability check, and every lowering consumer
  must agree before the type is admitted by `check`.
