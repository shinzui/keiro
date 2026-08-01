# The Guarantee Ledger: DSL and Hand-Written Services

Keiro supports two authoring paths. A DSL service describes its machine in a
`.keiro` specification and uses `keiro-dsl` to check, scaffold, diff, and test
it. A hand-written service constructs the same runtime types directly in
Haskell. Both are supported: the in-repository `jitsurei` package is a complete
hand-written service whose Cabal library lists its Haskell modules and direct
Keiro dependencies (`jitsurei/jitsurei.cabal:41-78`), and the package contains
no `.keiro` file.

This guide is for an adopter choosing between those paths and for a maintainer
trying to describe the DSL's value without overstating it. The short answer is
that replay safety is enforced below the DSL for every validated service, while
cross-version comparison and generated conformance evidence require a spec.
The distinction matters: a checked claim that does not describe the code that
runs creates false confidence and is worse than an explicit, hand-owned
contract.

Keiro is event-sourced: persisted events are the durable state, and *replay*
reconstructs current state by applying those events to a typed state machine
(`keiro-core/src/Keiro/EventStream/Validate.hs:1-10`). A *register* is a named,
typed state slot. An *upcaster* converts an older stored payload version to the
next version while decoding. A *snapshot* is a cached replay result, and
*hydration* loads a snapshot when valid and replays the remaining events. A
generated *hole* is create-once Haskell that the service owns and fills in. A
*golden* is a captured JSON payload used as a compatibility fixture.


## The layered gate model

Keiro's evolution policy is to check a hazard at the earliest boundary with
enough evidence, while later boundaries validate the runtime independently.
[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
records that architecture, and [The gates, at a glance](evolution-and-replayability.md#the-gates-at-a-glance)
is its adopter-facing walkthrough (`docs/guides/evolution-and-replayability.md:62-113`).

The six gates divide into two layers. The compiler is gate 1. DSL `check` and
cross-version `diff` are gate 2, and the generated harness is gate 3. Validated
event-stream construction at startup is gate 4, the real-log replay audit is
gate 5, and typed runtime failures plus advisory verification telemetry are
gate 6 (`docs/guides/evolution-and-replayability.md:67-110`). Gates 1, 4, 5,
and 6 are available to every service. Gates 2 and 3 require a `.keiro` spec.
No one gate checks everything.


## What is enforced below the DSL

Keiki's `validateTransducer` is the pure validation umbrella for the state
machine that actually runs. Its structured warning vocabulary includes five
replay-soundness families (`shinzui/keiki` `src/Keiki/Core.hs:1983-2033`):

- `HiddenInput` means an edge consumes command information that its events do
  not carry, so replay cannot reconstruct the command.
- `HeadUnrecoverable` means a multi-event edge puts required command data only
  in later events even though streaming replay inverts the first event.
- `InversionAmbiguity` means two edges share a first wire constructor, so an
  observed event does not identify one inverting edge.
- `UnguardedInputRead` means an edge reads a command field without first
  establishing the matching command constructor.
- `StateChangingEpsilon` means an edge changes control state or registers but
  emits no durable event.

The default umbrella runs those checks alongside determinism and reachability,
and a clean result means the machine can replay the logs it produces, subject
to honest constructor descriptions (`shinzui/keiki`
`src/Keiki/Core.hs:2127-2188`). This is a property of the Keiki value, not of
whether that value came from a spec.

Keiro-core makes that validation part of the service boundary. Command runners
accept `ValidatedEventStream`, whose constructor is deliberately absent from
the module export list and documented as intentionally private
(`keiro-core/src/Keiro/EventStream/Validate.hs:32-44,74-85`).
`validateEventStreamWith` runs codec, snapshot, and transducer checks, while
`forceReplayContract` always enables head recoverability and state-changing
epsilon checks even if caller options try to disable them
(`keiro-core/src/Keiro/EventStream/Validate.hs:102-128`). `mkEventStream` and
`mkEventStreamOrThrow` are the public construction paths
(`keiro-core/src/Keiro/EventStream/Validate.hs:130-177`). The explicit escape
hatch, `mkEventStreamUnchecked`, skips every Keiki and Keiro check and is
documented for tests and emergency forensics only
(`keiro-core/src/Keiro/EventStream/Validate.hs:179-189`).

A `.keiro` spec does not buy these guarantees: every validated hand-written
stream gets them too. Conversely, bypassing `ValidatedEventStream` gives them
up regardless of whether a spec exists.


## What exists only in the DSL — and how far it reaches

The DSL adds cross-version evidence. `keiro-dsl diff` loads the old spec text
with `git show`, reads the current spec text, parses both, emits requested
goldens and replay-impact data, and classifies every finding over six distinct
compatibility surfaces. The default gate preserves the earlier blocking
behavior; `--gate`, `--explain`, and `--report-out` add operator-selected
surfaces, remediation detail, and a stable JSON report. That
lets CI ask questions a single runtime value cannot answer: whether the new
binary reads old history, whether old and new replicas can coexist during a
rollout, whether a snapshot must be rebuilt, and whether a public consumer
surface changed. Those directions are distinct; “compatible” is not one
universal label.

The generated harness supplies a second DSL-only layer. It validates the
filled transducer, round-trips current event shapes, checks representative
transitions, compares forward execution with replay over every final register,
and decodes genuine old payload goldens when provided. For structural mapped
types it also checks both binding laws, declared wire-policy cases, fixture
branch coverage, and generated projection-witness agreement; opaque mappings
receive boundary checks only. Golden emission must happen while both shapes
exist because the current spec cannot reconstruct an older payload, and
generated goldens never overwrite hand-captured payloads.

The checked nominal registry also makes same-declaration ID and enum equality a
DSL-visible contract. Generated guards use one declaration-tagged textual key;
the checker rejects cross-declaration and nominal-to-`Text` comparisons before
Haskell generation. Consumer `KindID` IDs and finite enums carry exact symbolic
domains and reconstructible models. Legacy generated IDs still admit arbitrary
`Text`, so they retain correct concrete equality but are reported as a one-way,
unverified projection until the successor construction contract closes that
domain.

These guarantees stop at the spec-visible surface, but language version 2
moves scalar aggregate behavior onto that surface. Its generated `Expressions`
and `Transducer` modules execute the checked guard/write Keiki tree directly;
a Holes module can supply event fields but cannot replace generated behavior.
An explicitly `implementation hole` transition remains hand-owned only for its
predicate and updates, within a generated command/event/target/mode envelope,
and contributes a required manual `FoldVersion`. The generated ownership and
predicate-verification report keeps an opaque Hole visibly unverified.

Version 1 retains the historical create-once whole-transducer Hole, and
upcaster bodies remain hand-owned stubs in both versions. `diff` reads spec
text, not arbitrary Haskell bodies, so version-1 Hole/upcaster changes and the
contents of a version-2 Hole remain outside semantic comparison. The DSL's
cross-version guarantee is therefore still a matter of degree, not a binary
“checked versus unchecked” claim.

[ADR 0002](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
describes the replay-only remedy when a guard tightens, and
[ADR 0003](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md)
defines snapshot compatibility. Event payload encoding and snapshot-cache
encoding are separate surfaces: `defaultStateCodec` serializes the consumer's
state through its JSON instances and registers through Keiki's register-file
JSON codec. Landed structural mappings generate the private event codec and
feed their wire/binding identity into snapshot invalidation, but they do not
execute or claim structural coverage over the consumer-JSON snapshot cache.


## The ledger: what a hand-written service gives up, ranked by silence

The ranking starts with failures that can serve wrong state without an error,
then moves toward failures that are loud but delayed.

### Rank 1: silent wrong state

First, snapshot invalidation becomes a manual contract wherever fold behavior
is hand-owned. A version-2 Hole exposes a per-transition `FoldVersion` that the
generated aggregate fingerprint composes automatically; the author must bump
it whenever the Hole predicate or updates change. Version-1 Holes and fully
hand-written services must instead bump `stateCodecVersion` or use
`defaultStateCodecWithFold (FoldVersion "...")`. `stateCodecVersion` remains the
encoding version. Either token path makes an old seed a normal cache miss and
forces one full replay; forgetting the manual bump can still accept a stale
snapshot with no error.

Second, removing a field under a tolerant JSON decoder can still decode while
silently changing meaning. DSL evolution classifies the unguarded removal as
breaking; a hand-written service has no equivalent pre-deploy comparison
(`docs/guides/evolution-and-replayability.md:567`). Third, reordering a durable
workflow body without a recorded patch can pair journaled results with the
wrong hand-written ordinal, also silently
(`docs/guides/evolution-and-replayability.md:579`).

### Rank 2: the unrecoverable golden-capture window

`diff --emit-goldens` synthesizes old payloads while both old and new specs are
available. Once only the new shape remains, it cannot recreate the old one
(`keiro-dsl/src/Keiro/Dsl/Goldens.hs:1-7`). A hand-written service that changes
its codec without first capturing representative historical bytes permanently
loses that easy source of compatibility evidence.

### Rank 3: loud failures move from CI to production

The generated harness can expose codec and fold mistakes before deployment
through current-shape round trips, old-payload decoding, forward/replay
equality, and—when mapped types are present—binding, wire-policy, branch, and
projection assertions. Without equivalent hand-owned tests, the first witness
may be the next production hydration.
`HydrationDecodeFailed`, `HydrationReplayFailed`, and `EncodeFailed` are typed
`CommandError` constructors, so the failures are loud and recoverable, but
they arrive after affected data is touched (`keiro/src/Keiro/Command.hs:174-203`).

### Rank 4: the replay audit needs a conservative target

The DSL can emit the affected event types for a targeted real-log audit. A
hand-written service has no spec from which to derive that set, so it must
supply a conservative set explicitly or select `AuditFull`; full audit is
reserved for one-time cutovers and forensics
(`keiro/src/Keiro/ReplayAudit.hs:3-16,80-84`). The audit still exists, but its
selection becomes more expensive or more dependent on human completeness.


## What a hand-written service keeps

A hand-written service keeps the Haskell compiler's exhaustiveness checks. It
keeps full startup validation when it constructs streams through
`mkEventStream` or `mkEventStreamOrThrow`: Keiro validates the actual codec,
snapshot configuration, and transducer, and malformed versions, duplicate
tags or upcaster sources, out-of-range rungs, and incomplete chains fail before
stored streams are touched (`keiro-core/src/Keiro/EventStream/Validate.hs:1-30,107-177`).
It keeps the real-log replay audit with an explicitly supplied affected set
(`keiro/src/Keiro/ReplayAudit.hs:3-16`). It also keeps typed hydration and
encoding failures (`keiro/src/Keiro/Command.hs:174-203`).

The default command options also keep post-append replay verification enabled.
A divergence is counted and attached to the command span, but it is advisory:
the already-committed command still succeeds
(`keiro/src/Keiro/Command.hs:238-252,282-297,873-895`). The runtime does not
turn that witness into a deployment gate for you. If you do not collect and
alert on `keiro.snapshot.apply.divergence`, the witness effectively does not
exist for your operators (`docs/guides/evolution-and-replayability.md:99-110`).


## How this relates to the gate-coverage table

The [gate-coverage summary](evolution-and-replayability.md#gate-coverage-summary)
maps individual change classes to their static, startup/CI, and runtime gates
(`docs/guides/evolution-and-replayability.md:556-579`). This ledger answers a
different question: which layers an authoring path receives. Use the table to
plan one concrete evolution; use this ledger to decide what evidence must be
re-created when a service has no spec.


## Verifying this guide

Every behavior claim above names a current `file:line` source. Line numbers
drift as the tree evolves, so after pulling a newer revision, relocate the named
declaration and confirm the cited behavior still holds. A roadmap item is not
an enforcement claim: until its implementation is present in the cited code,
it remains future work.
