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
5. The database-backed replay audit in plan 142 will cover the distinct
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
| Deprecated event without a replay-only emitter | `DeprecatedEventReplayHazard` Warning | Advisory with the same code | Real-log inversion remains plan 142's audit responsibility |
| Deprecated event with a replay-only emitter | `EventRetirementInProgress` Warning | Replay-safe cutover Advisory | Transducer boundary validates the replay-only edge |
| Guard tightening | Replay-only edge discipline from ADR 0002 | `AggGuardTightened` prints the retained twin | Real-log relevance remains plan 142's audit responsibility |
| Fold/control-state change | Snapshot contract from ADR 0003 | `AggFoldSurfaceChanged` Advisory | Snapshot discriminator rejects stale seeds |
| New scaffolded workqueue payload | No payload-evolution grammar yet | Existing workqueue shape changes keep their normal classifications | Generated `QueueCodec` starts at schema version 1 with a `keiroJobCodec` `{v,t,data}` envelope; existing bare-payload queues must drain before adoption |

Plan 142 must extend it with replay-impact verdicts, targeted real-log audit
coverage, and sampled seed verification.

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
- Once plan 142 lands, non-neutral transducer changes also require its targeted
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
