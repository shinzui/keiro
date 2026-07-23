# Evolution And Replayability

This guide is for a developer changing a keiro service that is **already
deployed** — one whose event log, snapshots, timers, workflow journals, and
queues hold data written by the previous version of the code. It walks every
change class (new events, field changes, retiring events, decision changes, fold
changes, state-shape changes, persisted payloads, integration contracts,
workflow bodies), and for each one gives the safe procedure, states precisely
which gate catches a mistake today, and — where the honest answer is *nothing
catches it* — says so, with a pointer to the hardening plan that will close the
gap. It applies whether you author services by hand or through the
[`keiro-dsl` typed-spec toolchain](../user/typed-spec-toolchain.md); the
DSL-specific gates are called out as such, because a hand-authored service does
not get them.

Mechanics that other documents already cover are cross-linked, not repeated:
[Codecs And Event Evolution](../user/codecs-and-event-evolution.md) for the
codec API, [Evolve Events Safely](evolve-events-safely.md) for a worked
upcaster, [Replayability Safety](../user/replay-safety.md) for the
`ValidatedEventStream` boundary, [Snapshots](../user/snapshots.md) for the
snapshot subsystem, and [Durable Workflows](durable-workflows.md) for workflow
versioning. Where one of those documents states something this review found to
be wrong, this guide states the correct fact and notes that the doc fix is
tracked in
[`docs/plans/141`](../plans/141-correct-the-evolution-documentation-and-deploy-ordering-guidance.md).

## The ground truth: why evolution discipline is not optional

Three architectural facts make every change below a change to the
*interpretation of data you have already stored*.

**One edge set is both execution and replay.** A keiki transducer has no
separate decide/evolve pair. The same edges that turn a command into events
going forward are used to rebuild state: hydration *re-inverts* each stored
event back to the command that produced it and *re-checks the edge's guard
against the recovered command*
(`applyEventStreamingEither`, keiki `src/Keiki/Core.hs`, the
`models (guard e) (regs, ci)` check). Editing a guard, an output template, or a
register update is therefore not "just logic" — it edits how every event
already in the log replays. There is no version of "the events are fine, I only
changed the code" in this architecture.

**Upcasters run at decode time, forever.** A stored payload is never rewritten.
`decodeRecorded` reads the `schemaVersion` stamp from event metadata
(defaulting to 1 when absent), replays the upcaster chain up to the codec's
current version, and only then decodes — on every hydration, for the life of
the stream (`keiro-core/src/Keiro/Codec.hs`). The same applies to workflow
journal pre-load (`keiro/src/Keiro/Workflow.hs`) and to `keiroJobCodec` job
payloads (`keiro-pgmq/src/Keiro/PGMQ/Codec.hs`). A rung can never be deleted
while any payload at its source version persists: the chain walk fails with
`GapInUpcasterChain` the moment it is missing.

**There is no data-migration story.** Kiroku is append-only. Keiro ships no
tool that rewrites stored payloads to a new shape. The only mechanism that
removes events from a stream's read path is operator-driven stream truncation
behind a covering snapshot
([Operations — stream truncation](../user/operations.md#stream-truncation)),
which is a recovery tool, not a migration tool.

The consequence: **a schema or logic change ships alongside all the data the
old code wrote, and the new code must be able to replay all of it.** The rest
of this guide is the discipline that makes that true.

## The gates, at a glance

Five gates stand between an evolution mistake and production. Know what each
one actually checks, because none of them checks everything:

1. **The compiler.** Exhaustiveness of pattern matches over your event/command
   types. Nothing about stored data.
2. **`keiro-dsl check` and `keiro-dsl diff --since <git-ref>`** (DSL services
   only). `check` validates a single spec (contiguous upcaster holes, no
   emitted deprecated events, disposition tables). `diff` compares the spec
   against a git ref and classifies changes over the *persisted decode surface*
   (event fields and types, enums, wire spec, contract events, workqueue
   payloads, process inputs, workflow inputs/outputs) and the *identity
   surface* (stable names, id prefixes, dedupe keys, queue identities),
   exiting non-zero on BREAKING. It does **not** compare transition guards,
   register writes, or any hole body — decision and fold logic are invisible
   to it.
3. **The generated harness** (DSL services only). Round-trips current-shape
   events, asserts `validateTransducer` is clean, and asserts each upcaster
   hole is filled. Caveat: the upcaster assertion feeds a *current-shape*
   payload tagged at the old version through the chain — it proves the rung is
   wired and filled, **not** that a genuine old payload decodes. Golden
   old-payload tests are your job (planned to be generated by
   [`docs/plans/139`](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md)).
4. **`mkEventStream` / `mkEventStreamOrThrow`** at startup
   ([Replayability Safety](../user/replay-safety.md)). Runs keiki's structural
   replay-safety checks with head-recoverability and state-changing-ε
   force-enabled, plus snapshot-configuration coherence. It validates the *new
   machine in isolation* — never the new machine against old logs, and (today)
   never the codec: `mkCodec` exists in `keiro-core/src/Keiro/Codec.hs` and
   would catch duplicate upcaster rungs and chain gaps at startup, but no
   production path calls it
   ([`docs/plans/139`](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md)
   wires it into the boundary).
5. **Runtime witnesses.** Hydration failures are loud, typed errors
   (`HydrationDecodeFailed`, `HydrationReplayFailed` with a
   `HydrationNoInvertingEdge`/`HydrationAmbiguousInversion`/
   `HydrationQueueMismatch`/`HydrationTruncatedChain` reason —
   `keiro/src/Keiro/Command.hs`). After every append, a default-on replay
   verification re-plays the just-committed batch; a divergence increments
   `keiro.snapshot.apply.divergence` and stamps a `keiro.replay.divergence`
   attribute on the command span — **advisory telemetry only**: the command
   still succeeds, and nothing is dead-lettered. If you do not alert on that
   counter, this witness does not exist for you.

The summary table at the end of this guide maps every change class onto these
gates.

## Adding a new event type

The one genuinely easy change. Old streams do not contain the new event, so
nothing old breaks.

1. Add the constructor to your event type, an emitting transition, the wire tag
   to the codec's `eventTypes`, an `encode` arm, and a `decode` arm — all in
   one change. (With the DSL: add the `event` block and the `emit`, then
   `scaffold`; the codec is regenerated atomically.)
2. Add a round-trip test for the new event
   ([testing checklist](../user/codecs-and-event-evolution.md#testing-codecs)).
3. Deploy everywhere **before** relying on the event, and treat the deploy as
   roll-forward-only once the first new event is appended: an old binary
   hydrating a stream that contains the new tag fails loudly with
   `UnknownEventType` → `HydrationDecodeFailed`.

What the gates catch: `diff` classifies the addition ADDITIVE. Forgetting the
tag in `eventTypes` fails the *first append* with `EncodeFailed` (loud,
immediate). Forgetting the decode arm fails the *next hydration* of a stream
containing the event (loud, delayed). `mkEventStream` checks neither — the
codec is outside its scope today.

## Changing an existing event's payload fields

This is the change class the codec machinery was built for. The mechanics —
`schemaVersion`, upcaster chains, `decodeRaw` testing — are in
[Codecs And Event Evolution](../user/codecs-and-event-evolution.md) and the
worked example in [Evolve Events Safely](evolve-events-safely.md). Two
signature notes, because that document predates the current API: `decode` takes
the stored event-type tag (`EventType -> Value -> Either Text e`) and an
upcaster is `(Int, EventType -> Value -> Either Text Value)` — the tag is
supplied so multi-event codecs can migrate by the authoritative wire tag. The
doc refresh is tracked in
[`docs/plans/141`](../plans/141-correct-the-evolution-documentation-and-deploy-ordering-guidance.md).

The safe procedure, by sub-case:

**Adding an optional field** (hand-written codecs, or keiki-codec-json with a
`Maybe` passthrough / `fcOnMissing` default): no version bump needed. Old
payloads decode with the default. Note the DSL cannot express this for
aggregate events — every generated field decode is strict — so under the DSL
*every* field addition is a version bump with an upcaster, and `diff` enforces
it (`EvtFieldAddedWithoutBump` is BREAKING).

**Adding a required field, removing, renaming, or retyping a field**: bump the
event's version and write the upcaster.

1. Declare the new shape at `vN` with `upcast from v(N-1)` (DSL), or bump
   `schemaVersion` and add the `(N-1, upcaster)` rung (hand-written).
2. The upcaster receives the *old* JSON and must return the *new* shape:
   default the added field, fold the removed field's information elsewhere if
   the fold needs it, move the renamed key, convert the retyped value.
3. Write a golden test that feeds a **genuine old payload** (copied from a real
   stored event, not re-encoded from current code) through `decodeRaw` at the
   old version. This is the single most valuable evolution test you can write,
   and no generated gate does it for you today.
4. Deploy roll-forward-only (see [Deploy ordering](#deploy-ordering-rules)).

What the gates catch: for DSL services, `diff` catches all four unguarded
variants as BREAKING (`EvtFieldAddedWithoutBump`, `EvtFieldRemovedSameVersion`,
`EvtFieldTypeChanged`, and version jumps without a contiguous upcaster). For
hand-written services, **no gate exists before runtime**: an unguarded required
add / rename / retype surfaces as `HydrationDecodeFailed` the first time an old
stream is touched — in production, possibly days later. An unguarded *removal*
is worse: old payloads still decode (unknown keys are ignored), the fold just
silently loses the data — wrong state, no error.

> **Nothing catches these today.**
> *Silent field removal / tolerant rename on hand-written codecs* — decodable
> but wrong state. The committed-golden-fixture convention that would catch it
> is part of
> [`docs/plans/139`](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md).
> *Two DSL evolutions that generate broken codecs while `diff` reports
> ADDITIVE:* (a) **two events bumped in one release** — the generated codec
> gets two upcaster rungs keyed by the same source version; the chain walk
> takes the first match, so one event's upcaster silently never runs and the
> other's runs on both kinds' payloads. (b) **sequential single-step bumps
> across releases** (v2 in release N, v3 in release N+1) — the spec's
> `upcast from` clause is single-valued, so the v1→v2 rung *vanishes from the
> generated codec* and every v1-stamped payload fails `GapInUpcasterChain` at
> hydration. Both would be caught at startup by `mkCodec`, which nothing calls
> today; the boundary wiring and the DSL validator rules are
> [`docs/plans/139`](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md),
> the spec-side multi-rung fix is
> [`docs/plans/140`](../plans/140-fix-dsl-upcaster-lowering-and-adopt-versioned-job-codecs.md).

One more DSL sharp edge to know while it lasts: the codec's `schemaVersion` is
aggregate-global (the max event version), and the generated upcaster lowering
**discards the event-type tag** — so a version-m rung receives *every* event
kind's payload stored at m, not just the event that declared it. Fill upcaster
holes to pass through payloads of other kinds untouched. The failure gradation:
an unfilled or strict upcaster fails loudly at hydration (the common case); a
purely additive upcaster (only defaults missing keys) is benign for other
kinds; **silent value corruption requires overlapping field names between two
kinds stored at the same version** — rare, but nothing prevents it. The
lowering fix (pass the tag into the hole signature) is
[`docs/plans/140`](../plans/140-fix-dsl-upcaster-lowering-and-adopt-versioned-job-codecs.md).

## Retiring an event type: deprecation is not enough

The intuitive lifecycle — "this event is historical, stop writing it, keep
decoding it" — has a trap that no gate catches today, and it is worth
understanding exactly.

Keeping the tag decodable (the DSL's `deprecated event`, which keeps the event
in the codec and forbids transitions from emitting it) protects only the
**codec layer**. Hydration then replays the decoded event through the
transducer — and replay needs an *edge whose output inverts it*. If you also
removed the transition that used to emit the event, there is no such edge, and
the next command on **any live stream whose history contains the event** fails
with `HydrationReplayFailed HydrationNoInvertingEdge`. The deploy passes
`check`, `diff` (which classifies deprecation ADDITIVE — its removal
diagnostic even suggests deprecation as the fix), the harness, and
`mkEventStream`; the failure appears in production on first contact with an
affected stream. Upcasters cannot rescue you: they migrate a payload *within*
its stored tag and cannot re-tag an old event as a new one.

The failure modes of getting this half-right are, fortunately, asymmetric:

- **Remove the emit but keep the transition** (so it becomes an output-free
  edge that still changes state): rejected **loudly at service startup** — the
  force-enabled `StateChangingEpsilon` check in `mkEventStream` refuses the
  stream (`keiro-core/src/Keiro/EventStream/Validate.hs`). You cannot ship
  this variant by accident.
- **Remove the transition entirely, or replace the event with a new one and
  drop the old edge**: passes every gate. This is the silent time bomb.

The safe procedure today:

1. **Do not retire an event that live (non-terminal) streams still contain.**
   Deprecation is safe only for events confined to streams that will never be
   hydrated again (terminal aggregates, or streams truncated behind a covering
   snapshot).
2. Until then, **keep the emitting transition in the transducer** — intact,
   with its emit — even after new code paths stop reaching it. The startup
   validator keeps you honest here: the variants it accepts are exactly the
   replayable ones.
3. When the event is genuinely confined to terminal streams, mark it
   `deprecated` (DSL) or drop the emitting transition (hand-written) and keep
   the decode arm forever.

> **Nothing catches this today.** The transition-removal and
> replacement-event variants of retiring a live event pass every gate and fail
> in production. The diff/validator rule that refuses deprecation of an event
> whose aggregate is non-terminal — and points at the safe pattern above — is
> [`docs/plans/139`](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md);
> the pre-deploy replay audit that catches the variant a developer ships
> anyway — against the streams that actually contain the event —
> is [`docs/plans/142`](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md).

## Changing decisions: guards, outputs, and dispatch

"Same events, different decisions" sounds replay-neutral. In keiro it is not,
for two separate reasons.

**Reason one: decide logic is the replay surface.** Because replay re-inverts
events and re-checks guards (see [ground truth](#the-ground-truth-why-evolution-discipline-is-not-optional)):

- *Tightening a guard* can make a historical event fail inversion —
  `HydrationReplayFailed HydrationNoInvertingEdge` on streams whose history
  satisfied the old guard but not the new one.
- *Loosening or overlapping guards* can make one historical event invert to
  two edges — `HydrationAmbiguousInversion`.
- *Changing an output template* changes what the inversion solves against.

These failures are loud but delayed to the next hydration of an affected
stream. **The guard-tightening case now has a first-class remedy**
([`docs/plans/143`](../plans/143-add-first-class-replay-only-transitions-for-guard-evolution.md)):
a `replay-only` transition. Marked with a `replay-only` prefix on the
transition line, it lowers to a keiki `ReplayOnly` edge — never taken by a
new command, but available to inversion when no live edge attributes a stored
event (inversion is two-phase: live edges are tried first, so a live edge
always wins attribution and an imperfectly complemented twin cannot create
ambiguity). The procedure when you tighten a guard:

1. Tighten the live transition's guard to the new rule.
2. Run `keiro-dsl diff --since <ref>`. The `AggGuardTightened` advisory
   computes the removed region — `old-guard ∧ ¬new-guard`, expressed inside
   the guard grammar — and prints a **paste-ready** `replay-only` twin
   carrying that region with the old transition's writes/emits/goto.
3. Decide: if stored streams may exercise the removed region (the replay
   audit of
   [`docs/plans/142`](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md)
   answers this against real data once landed), paste the twin — history
   stays replayable and the retired rule remains visible in the spec. If no
   stored data is affected (or you choose truncation), skip the twin.
4. The scaffolder lowers the marker to `B.replayOnly` in the transducer
   skeleton; hand-written services call `Keiki.Builder.replayOnly` in the
   edge body (or set `mode = ReplayOnly` on a raw `Edge`).

The validator keeps the pattern disciplined: a `replay-only` transition with
no `emit` is an error (`ReplayOnlyEmitsNothing` — it can invert nothing), and
one whose (source, command) pair has no live sibling is a warning
(`ReplayOnlyCommandStillLive` — the command is fully retired there; the
fuller procedure is event retirement,
[`docs/plans/139`](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md)).
A deprecated event may keep being emitted by a `replay-only` transition —
replay-only transitions are not the write path — which supersedes the
guarded-but-inert retained-edge contortion as the sanctioned shape.

**Twins are not forever — they end in retirement.** Each tightening can add a
twin; the endgame mirrors upcasters (rungs live *while payloads at their
version persist*, not forever). Once every stream containing the removed
region's events is terminal or truncated — the same condition as event
retirement, and exactly what the replay audit of
[`docs/plans/142`](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md)
proves — delete the twin. Deleting it earlier re-creates exactly the break it
fixed.

Output-template changes and guard *loosening* have no computed remedy: treat
them like schema edits (new event or new event version for the new
behaviour), and remember `diff`'s tightening detection is conservative — it
fires on any guard change without a twin, and the advisory's audit-or-paste
choice covers the loosening case too.

**Reason two: redelivery windows.** Process-manager and router dispatch is
made idempotent by deterministic event ids derived from
`(dispatcher, key, source event id, target, occurrence)`
(`keiro/src/Keiro/Router.hs`). If you change *which commands* a reaction emits
and deploy while source events from the old code are still in redelivery
(worker retry, dead-letter replay), a redelivered event dispatches the *new*
command under the *same* deterministic id — and the store confirms it as a
benign duplicate of the old dispatch. The result is a silently mixed
half-old/half-new fan-out. Dead-letter replay
(`keiro/src/Keiro/DeadLetter/Replay.hs`) has the same property by design: it
re-runs the *current* handler against the stored source event.

> **What is and is not gated.** Guard changes are now flagged at `diff` time:
> the `AggGuardTightened` advisory prints the computed `replay-only` twin
> (plan 143, above). What no gate yet *proves* is whether stored data
> actually exercises a removed region: the golden payloads of
> [`docs/plans/139`](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md)
> prove old shapes still *decode*, never that they still *invert* — the
> pre-deploy replay audit that replays real streams through the candidate
> binary (and whose digest mode makes even an inversion that silently *shifts
> to a different edge* reviewable) is
> [`docs/plans/142`](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md).
> Decide-change redelivery mixing has no gate either; the `diff` advisory on
> process/router mapping changes is also
> [`docs/plans/142`](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md).
> Until those land: drain PM/router redelivery and replay any dead letters
> **before** deploying a decide change (see
> [Deploy ordering](#deploy-ordering-rules)).

## Changing the fold: same events, different state — and what snapshots do to you

Changing an edge's register `update` (the fold) with unchanged event schemas is
the **worst gap in the stack**, verified end to end.

Without snapshots, a fold change simply reinterprets history: the next full
replay computes the new state from the same events. That is the intended
semantics — state is derived. The danger arrives with snapshots:

- The snapshot compatibility gate is the pair
  `(state_codec_version, regfile_shape_hash)`
  (`keiro/src/Keiro/Snapshot.hs`, lookup in `Keiro/Snapshot/Schema.hs`). The
  shape hash — `regFileShapeHash` — covers the register **slot list** (names,
  canonical type names, order; keiki `src/Keiki/Shape.hs`) and nothing else.
  It is *not* sensitive to fold logic.
- So after a fold change, every existing snapshot still matches. Hydration
  seeds from state computed under the **old** fold and replays only the tail
  under the new one. The command runs against silently wrong state. Replicas
  that happen to full-replay (snapshot miss) disagree with replicas that
  seeded. No error, no witness — the post-append verification replays only the
  just-appended batch from the (already stale) hydrated state, so it proves
  nothing here.
- **It compounds.** That same post-append path
  (`verifyAndSnapshot`, `keiro/src/Keiro/Command.hs`) then persists the
  stale-derived state as a *fresh* snapshot at the new head version whenever
  the policy fires. Each command pushes the snapshot forward, the stale prefix
  is re-blessed at ever-higher versions, and the "just fall back to full
  replay" escape hatch recedes: there is no version-0 replay left to fall back
  *to* unless you delete the snapshot row or change the discriminator.

The safe procedure today:

1. **Any fold change on a snapshot-enabled stream requires a manual
   `stateCodecVersion` bump** in the same deploy. The bump changes the
   discriminator, every old snapshot stops matching, and every stream does one
   full replay under the new fold. This is a performance event on large
   streams — schedule accordingly.
2. Rebuild any read models whose projections depend on the changed fold
   ([Read Models](../user/read-models-and-projections.md)).
3. If you cannot bump (emergency), delete the affected `keiro_snapshots` rows;
   the miss path is benign.

A correction to the current [Snapshots](../user/snapshots.md) document (fix
tracked in
[`docs/plans/141`](../plans/141-correct-the-evolution-documentation-and-deploy-ordering-guidance.md)):
it states that changing "the register-file **or state** shape" changes the
`shapeHash` automatically with `defaultStateCodec`. Only the *register-file*
half is true. `defaultStateCodec` derives the hash from the register slot list
alone (`keiro/src/Keiro/Snapshot/Codec.hs`); the control-state type `s` is
protected only by its decoder failing, and fold logic is protected by nothing.

> **Nothing catches this today.** No gate — not `diff` (transition writes are
> invisible to it), not the harness, not `mkEventStream`, not any runtime
> witness — connects a fold change to snapshot invalidation. The
> fold-sensitive snapshot discriminator and the interim `diff` advisory are
> [`docs/plans/138`](../plans/138-gate-snapshot-staleness-on-fold-changes.md);
> for fold changes that discriminator *cannot* see (hand-written or
> Holes-only bodies with a missed manual bump), the pre-deploy replay audit's
> seeded-vs-full-replay comparison is the detection backstop —
> [`docs/plans/142`](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md).

## Changing the state shape

Two halves, with different protection:

**Register file** (add/remove/rename/retype/reorder a slot): the shape hash
changes, every old snapshot stops matching (`SnapshotNotFound`), and hydration
transparently full-replays from version 0. Graceful — a performance event, not
a correctness event. Two caveats: a *mixed-version deployment* thrashes the
single snapshot row per stream (either side's writer may replace the other's —
deliberate, to permit rollback); and a user-defined slot type using the default
`CanonicalTypeName` changes its hash when its *defining module moves*
(spurious full replay — pin `canonicalTypeName` if that matters), while
changing the type's *internal fields* does **not** change the hash — for that
you are back to decode-failure protection only.

**Control state `s`**: not part of the hash at all. An undecodable old
snapshot is a benign miss (full replay). A *decodable-but-different* one — an
added field with a default, a still-parsing constructor rename — is served as
stale state, with the same compounding behaviour as a fold change. Treat any
semantic change to `s` as requiring a `stateCodecVersion` bump, exactly like a
fold change
([`docs/plans/138`](../plans/138-gate-snapshot-staleness-on-fold-changes.md)
also covers hashing `s`'s shape).

## Persisted payloads outside the event log

The event log is not the only place your old shapes live. Each of these
surfaces outlives a deploy and has its own (often weaker) evolution story:

**Timer payloads (`keiro_timers`).** A process-manager timer carries an opaque
JSON payload built at schedule time (`keiro/src/Keiro/Timer/Types.hs`); the
fire action decodes it — possibly weeks later, under newer code. There is no
versioning and no upcast hook. A fire decoder that rejects the old shape
throws, the attempt counter climbs, and after `maxAttempts` the timer row is
dead-lettered (`Dead`, with `last_error`). Safe procedure: fire decoders must
stay backward-compatible with every payload shape that may still be scheduled,
or you must drain/re-schedule timers as part of the deploy. The DSL's `diff`
flags process-input field changes as BREAKING, which covers the spec'd payload
indirectly; hand-written timer payloads have no gate.

**Workflow journals.** Step *results* are persisted as raw JSON under the step
name. Changing a journaled step's result type makes replay throw
`WorkflowStepDecodeError`; the resume worker counts each throw as a crash, and
after the default five attempts the instance is **terminally failed with no
supported recovery API today** (`resurrectFailedWorkflow` is a deliverable of
[`docs/plans/115`](../plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md)
under
[`docs/masterplans/16`](../masterplans/16-harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review.md);
until it lands, recovery is manual SQL). The workflow snapshot's fixed sentinel
shape hash (`keiro.workflow.stepmap.v1`) deliberately does not protect per-step
types — the step decode is the intended failure point. The safe procedure is
never to change a journaled result type in place: **rename the step**
([Durable Workflows](durable-workflows.md#versioning-a-running-workflow-rename-a-step-or-patch)).
Awakeable payloads are journaled step results too (`awk:<uuid>`) and follow the
same rule.

**pgmq job payloads.** `keiro-pgmq` ships two codecs
(`keiro-pgmq/src/Keiro/PGMQ/Codec.hs`): `aesonJobCodec` (raw, unversioned) and
`keiroJobCodec` (a versioned `{v,t,data}` envelope with the full upcaster-chain
story and a `JobPayloadFromFuture` rolling-deploy retry). Know that **every
current consumer, including the DSL scaffolder, uses the unversioned one** —
so today a job payload shape change breaks in-flight messages, which decode as
`JobPayloadMalformed` and dead-letter to the DLQ. The DSL `diff` catches
spec'd workqueue payload changes (BREAKING) pre-merge, but the runtime has no
versioning until you adopt `keiroJobCodec` yourself. Do not switch a non-empty
queue between the two codecs — the wire shape differs; drain first. Scaffolder
adoption of the versioned codec is
[`docs/plans/140`](../plans/140-fix-dsl-upcaster-lowering-and-adopt-versioned-job-codecs.md).

**Dead-letter rows.** Rejected PM/router dispatches store identity and error
text, never the command payload — they are immune to command schema evolution.
Operator replay re-runs your *current* handler against the stored source event,
so it inherits the decide-change caveat above.

## Integration events across bounded contexts

The [integration envelope](../user/integration-events.md) carries
`schemaVersion` end to end — stamped into the `keiro-schema-version` Kafka
header on publish, parsed back on consume, persisted in inbox rows. What it
does **not** carry is any automatic migration: **there is no upcaster machinery
on the inbox path**. `decodeJsonIntegrationEvent` is a plain `FromJSON` decode;
version dispatch on the consumer side is entirely your code, and a decode
failure routes wherever the intake's disposition table sends it (typically
`decodeFailed => deadLetter`). The `schemaReference` registry fields are
plumbed through verbatim and enforced by nothing.

The safe procedure is contract-first, additive-first:

1. Model the topic in a DSL `contract` block on both sides where possible.
   `diff` then gates the producer: a field added without a `schemaVersion`
   bump is BREAKING; with a bump it is a WARNING telling you to coordinate the
   rollout; removals, type changes, discriminator and topic changes are
   BREAKING.
2. **Additive change (new optional field):** deploy the producer first;
   tolerant consumers ignore unknown fields. **Structural change:** treat it
   as a new contract version — new topic or explicit version dispatch in the
   consumer — and deploy the consumer's ability to decode the new shape
   *before* the producer emits it. In both directions, remember old messages
   remain in flight: a consumer that starts *requiring* a new field breaks on
   the backlog.
3. Never change `messageId`/`idempotencyKey` derivation on a live contract —
   `diff` flags both as BREAKING because they re-key dedupe identity, and
   redelivered messages stop matching their dedupe records (duplicates).

> **Nothing catches this today.** `diff` sees one repository's spec. No gate
> compares a consumer's contract block against the producer's, and no gate
> enforces deploy ordering — skew is caught by consumer dead letters in
> production. Cross-repo contract conformance is explicitly out of scope for
> [`docs/masterplans/24`](../masterplans/24-close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review.md)
> (documented as manual rules here, a future initiative to automate).

## Evolving workflows

The full treatment is in
[Durable Workflows](durable-workflows.md#versioning-a-running-workflow-rename-a-step-or-patch);
the evolution-relevant rules in brief:

- **One step changed:** rename its `StepName`. A renamed step has no journaled
  history, so it runs fresh. Never change a journaled result type in place
  (see [journals above](#persisted-payloads-outside-the-event-log)).
- **Cross-cutting change:** wrap it in `patch (PatchId "...")` and add the id
  to `activePatches` in the same deploy; in-flight instances keep the old
  branch forever, fresh instances take the new one. Remove the id from
  `activePatches` only after deleting the `patch` call; never reuse a retired
  `PatchId`. The DSL `diff` sanctions exactly these shapes: a body change
  fully wrapped in a new patch is ADDITIVE, an unguarded body change and a
  removed patch id are BREAKING.
- **Ordinal names (`sleep:0`, `sleep:1`, …)** are positional: reordering the
  calls re-pairs in-flight instances with the wrong journaled completions —
  silently, if the types happen to match. Prefer the named forms for anything
  that must survive a code edit. `diff` catches body reordering for DSL specs;
  hand-written workflows have no gate.
- **Unbounded workflows:** `continueAsNew` is the evolution escape hatch — the
  next generation starts with a fresh journal and only the carried seed, so
  accumulated journal shape debt is dropped at each rotation. Changing the
  *seed type* is BREAKING in `diff` (the next generation must decode the
  previous generation's seed).
- **Known runtime bug (until
  [`docs/plans/115`](../plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md)
  lands):** the patch set is recorded only when a generation's journal looks
  fresh. An asynchronous append racing a `continueAsNew` rotation (a duplicate
  awakeable signal, a child completion) defeats that check, after which
  **every `patch` call in that instance silently decides `False` forever**.
  If you combine `patch` with `continueAsNew` today, audit rotated instances'
  `__workflow_patches__` records after deploys.

## Deploy-ordering rules

Collected here because they exist nowhere else
([`docs/plans/141`](../plans/141-correct-the-evolution-documentation-and-deploy-ordering-guidance.md)
adds them to the reference docs):

- **Aggregate codec version bumps are roll-forward-only, and are not
  rolling-deploy-safe.** `Keiro.Codec` cannot read a version above its own
  (`VersionAhead`), and cannot write an old version while decoding a new one.
  Once the first vN event is appended, any vN-1 replica fails hydration of
  that stream. Ship bumps in a fast, full rollout; never roll back past the
  first new-version append.
- **New event *types* are roll-forward-only** for the same reason
  (`UnknownEventType` on old replicas), though only for streams that already
  contain the new event.
- **`keiroJobCodec` bumps: deploy workers before producers.** A worker seeing
  a future envelope returns `JobPayloadFromFuture` and the job is retried
  (consuming delivery attempts — size `maxRetries * retryDelay` to cover the
  deploy window). Never switch a non-empty queue between `aesonJobCodec` and
  `keiroJobCodec`.
- **Integration contracts:** producer-first for additive fields;
  consumer-decode-capability-first for structural changes; and the consumer
  must keep decoding the *old* shape until the backlog drains.
- **Decide changes over PM/router reactions: drain before deploy.** Let
  subscription redelivery quiesce and replay or explicitly discard dead
  letters before shipping a change to what a reaction dispatches; otherwise
  redelivered source events silently mix old and new fan-out under the same
  deterministic ids.
- **Fold changes with snapshots: bump `stateCodecVersion` in the same deploy**
  and expect a full-replay cost spike (see
  [fold changes](#changing-the-fold-same-events-different-state--and-what-snapshots-do-to-you)).
- **Any transducer change: consult the replay-impact verdict, and audit the
  affected data before switching traffic** (once
  [`docs/plans/142`](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md)
  lands). `diff` either proves the deploy replay-neutral (no old edge or decode
  surface changed — no audit needed, the common case) or names the affected
  event types; run the candidate binary's *targeted* audit — only streams
  containing those types — against a production-copy or staging database.
  Non-zero exit (a stream that fails replay, or a snapshot seed that diverges
  from full replay) means do not deploy. The full-store sweep is for one-time
  keiki-runtime cutovers, not routine deploys; between deploys, the sampled
  runtime seed-verification metric is the alert to watch.

## Gate coverage summary

"Loud/delayed" means a typed runtime error on the next touch of affected data
— visible, but in production. **Silent** means wrong behaviour with no error.
DSL-only gates do not exist for hand-authored services.

| Change | check/diff (DSL) | Startup (`mkEventStream`) | Runtime | Silent risk today | Fix tracked |
|---|---|---|---|---|---|
| Add event type | ADDITIVE | — (codec unchecked) | `EncodeFailed` / `HydrationDecodeFailed` if miswired | rollback only | [139](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md) |
| Add optional field (tolerant codec) | n/a (DSL: must version) | — | decodes with default | meaning drift only | — |
| Required add / rename / retype, unguarded | BREAKING | — | `HydrationDecodeFailed` (loud/delayed) | hand-written: no pre-deploy gate | [139](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md) |
| Field removal, unguarded | BREAKING | — | decodes fine | **silent wrong state** (hand-written) | [139](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md) |
| Version bump + upcaster | ADDITIVE | — (chain unchecked) | `GapInUpcasterChain`/`UpcasterError` if wrong | two DSL codec-gen bugs report ADDITIVE | [139](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md), [140](../plans/140-fix-dsl-upcaster-lowering-and-adopt-versioned-job-codecs.md) |
| Deprecate event, live streams affected | ADDITIVE (misleading) | ε-variant rejected loudly | `HydrationNoInvertingEdge` (loud/delayed) | **passes every gate** (transition-removal variant) | [139](../plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md), [142](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md) (audit) |
| Guard/output change vs old logs | invisible | new machine only | `HydrationReplayFailed` (loud/delayed) | inversion-compatible edits are silent | [142](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md) (replay audit + digest diff) |
| Decide change over redelivery window | invisible | — | deduped as benign duplicates | **silent mixed fan-out** | [142](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md) (advisory) + drain rule |
| Fold change, snapshots enabled | invisible | — | none — witness blind here | **silent stale state, compounding** | [138](../plans/138-gate-snapshot-staleness-on-fold-changes.md), [142](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md) (audit backstop) |
| Register slot change | n/a | — | full replay (benign) | mixed-deploy snapshot thrash | — |
| State type `s` decodable change | invisible | — | none | **silent stale snapshot** | [138](../plans/138-gate-snapshot-staleness-on-fold-changes.md), [142](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md) (audit backstop) |
| Timer payload shape | input fields BREAKING | — | timer dead-letter (loud/delayed) | hand-written: none | [142](../plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md) (payload-block advisory) |
| Workflow step result type | BREAKING (body) | — | `WorkflowStepDecodeError` → terminal fail, no recovery API | recovery gap | [115](../plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md) |
| Job payload (aesonJobCodec) | workqueue BREAKING | — | DLQ flood (loud) | unversioned runtime | [140](../plans/140-fix-dsl-upcaster-lowering-and-adopt-versioned-job-codecs.md) |
| Contract field change | BREAKING / advisory | — | consumer dead letters | cross-repo skew unchecked | [24](../masterplans/24-close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review.md) (out of scope, manual rules here) |
| Workflow body reorder without patch | BREAKING | — | wrong journaled pairing | hand-written ordinals: **silent** | [115](../plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md) (patch race) |

The master plan closing the tracked gaps is
[`docs/masterplans/24`](../masterplans/24-close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review.md).
Until its children land, the rows marked **silent** are exactly the changes
where this guide's procedures are your only protection.
