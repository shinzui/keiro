---
type: Architecture Decision Record
title: Evolution changes are gated at the earliest sound boundary
description: Each evolution hazard is checked at the earliest boundary with enough evidence, while later boundaries independently defend runtime assembly.
timestamp: 2026-07-28T19:50:11Z
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

The landed inventory is:

| Change class | Single-spec `check` | Cross-spec `diff` | Runtime boundary / CI |
|---|---|---|---|
| Invalid schema version, duplicate event tags, out-of-range rung | Not all are expressible in the DSL | Not required | `mkCodec` fails validated stream construction |
| Different event kinds change at the same source version | Allowed; chain continuity still applies | Version bumps remain Additive only with their declared upcasts | Scaffolder merges them into one unique rung that dispatches by `EventType`; `mkCodec` validates the resulting codec |
| Upcaster accidentally rewrites another event kind at the same aggregate version | Not author-expressible in generated code | No separate classification needed | Generated rung dispatch passes foreign kinds through byte-for-byte; codec-level conformance invokes each owning upcaster |
| Missing aggregate rung | `UpcasterChainGap` Error | Vanished historical rung is Breaking `UpcasterChainGap` | `mkCodec` rejects startup; versioned JSON golden fails decode |
| Event payload version bump | Contiguous upcaster required | `diff --emit-goldens` captures the old wire shape while both specs exist | `scaffold --goldens` embeds the fixture and the generated harness exercises `decodeRaw`; a stand-in is labelled as weaker when no golden exists |
| `retiring` event without a live emitter | `EventRetirementInProgress` Error | Retirement start is Advisory | Generated shape remains the ordinary live machine |
| Deprecated event without a replay-only emitter | `DeprecatedEventReplayHazard` Warning | Advisory with the same code | Targeted real-log audit proves whether stored streams still invert |
| Deprecated event with a replay-only emitter | `EventRetirementInProgress` Warning | Replay-safe cutover Advisory | Transducer boundary validates the replay-only edge |
| Guard tightening | Replay-only edge discipline from ADR 0002 | `AggGuardTightened` prints the retained twin and affected replay surface | Targeted real-log audit fails without a required twin and passes with it |
| Fold/control-state change | Snapshot contract from ADR 0003 | `AggFoldSurfaceChanged` Advisory | Snapshot discriminator rejects stale seeds |
| Forward/replay state divergence (dishonest wire/inversion boundary, later mapped-register bindings) | `validateTransducer` in the generated harness proves the declared structure; honesty of `WireCtor`/`InCtor` is not spec-expressible | Not required | Generated harness steps fixture commands forward, decodes the emitted chain through the generated codec, replays via `applyEventsEither`, and compares final vertex and every register in conformance CI; the DB-backed replay audit and the advisory post-append verification remain the stored-history and production gates |
| New scaffolded workqueue payload | No payload-evolution grammar yet | Existing workqueue shape changes keep their normal classifications | Generated `QueueCodec` starts at schema version 1 with a `keiroJobCodec` `{v,t,data}` envelope; existing bare-payload queues must drain before adoption |
| Replay-impacting aggregate change | — | `replay-neutral`, or deterministic per-aggregate event types and snapshot-stream inclusion | `AuditTargeted` reads only selected streams; replay failure or seed divergence exits 1 |
| Hole-only or hand-written fold change with a missed version bump | Invisible | Invisible | One in 1000 accepted seeds is full-replayed through its immutable seed version; divergence increments `keiro.snapshot.seed.divergence` |
| Router/process decide surface | — | `RouterDecideSurfaceChanged` / `ProcessDecideSurfaceChanged` Advisory | Drain the subscription redelivery window; hole-only changes keep the same manual rule |
| Process timer payload | — | `ProcessTimerPayloadChanged` Advisory | Firers must decode every pending unversioned shape or the timer exhausts attempts and dead-letters |
| Invalid mapped declaration (missing provenance, ambiguous or recursive reference, non-injective nullability, invalid default, encoding collision, unsupported guard, or missing register initial) | Stable mapped diagnostic at the owning declaration or use site | Not required | Correct the single-spec contract before generation; opaque mode remains an explicit, separately checked boundary |
| Mapped structural wire change | Single-spec shape remains valid | Recursive mapped diagnostic at every complete command, event, and register root path; event history, old-binary rollout, snapshot hydration, and consumer build are classified independently | Version and upcast affected events, rebuild affected snapshots, and recompile affected consumers according to the finding's compatibility vector |
| Mapped source, binding, fixture, canonical identity, or opaque-codec provenance change | Required facts and identities are checked | Declaration-level build or identity finding; opaque codec-version changes remain historical-read hazards even when no structural shape is visible | Recompile consumers, bump binding provenance, or migrate the declared opaque codec as directed; no Haskell source inspection is claimed |
| Synthesized mapped old-payload golden | — | `diff --emit-goldens` traverses the complete checked old shape and labels synthesized output as a weak stand-in | Replace it with a hand-captured historical payload when available; emission never overwrites existing evidence |
| Private enum constructor addition | — | One `EnumCtorAdded` finding per containing event/register path; event use is old-binary/new-event breaking and register use is snapshot-hydration advisory | Deploy consumers before producers and invalidate/rebuild affected snapshots |
| Snapshot-cache invalidation | Snapshot contract from ADR 0003 | `snapshot-hydration=advisory` identifies rebuild rather than event upcast work | The three-component discriminator rejects stale seeds; bump `state-codec version=` for invisible hand-owned changes |
| Public contract change | Single-spec ownership checks only | Existing contract codes classify `public-consumer` independently from private history and identity | Deploy compatible consumers before producers or revise/version the contract |

Every cross-spec finding carries a compatibility vector over six surfaces:
`private-history-read`, `old-binary-read-new-events`,
`snapshot-hydration`, `public-consumer`, `persisted-identity`, and
`consumer-build`. Each verdict is `compatible`, `advisory`, `breaking`, or
`n/a`. Rollout constraints are a zero-or-more set using the vocabulary below:
`stop-the-world`, `workers-first`, `drain-required`, and `producer-last`. The
default gate contains every surface except `old-binary-read-new-events`, which
preserves the previous merge-blocking behavior; repeated `--gate` flags only
add surfaces. ADDITIVE/WARNING/BREAKING headlines and append-only
`DiagnosticCode` values remain the stable text contract, while the vector is
their context-sensitive refinement. `--report-out` writes schema
`keiro-dsl/diff-report/1`; object keys and containing paths are append-only and
readers must ignore unknown keys. The existing replay-impact JSON contract is
unchanged.

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
