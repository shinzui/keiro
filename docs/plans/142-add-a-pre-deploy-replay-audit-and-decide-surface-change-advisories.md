---
id: 142
slug: add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories
title: "Add a pre-deploy replay audit and decide-surface change advisories"
kind: exec-plan
created_at: 2026-07-23T12:19:38Z
master_plan: "docs/masterplans/24-close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review.md"
---

# Add a pre-deploy replay audit and decide-surface change advisories

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Every keiro command (aggregate) and action (process manager) first rebuilds its register
state by replaying the stream's stored events through the *current* keiki transducer:
decode each payload through the upcaster chain, re-invert the event back to the command
that produced it, re-check the edge's guard, fold the register writes — optionally seeded
from a snapshot. The sibling plans close the decode layer (docs/plans/139, docs/plans/140)
and the spec-visible snapshot discriminator (docs/plans/138), but two failure classes
remain with **no mechanical gate against the data a service has actually stored**:

1. *Inversion breaks or shifts.* A removed or re-pointed transition, a tightened guard,
   or a changed output template makes a stored event fail inversion
   (`HydrationReplayFailed HydrationNoInvertingEdge` / `HydrationAmbiguousInversion`) — or,
   worse, invert *unambiguously to a different edge* so replay succeeds with silently
   different register writes. Pre-merge gates see at most an advisory
   (`AggFoldSurfaceChanged`, docs/plans/138) or a warning
   (`DeprecatedEventReplayHazard`, docs/plans/139); startup validation checks the new
   machine in isolation, never against old logs. The failure detonates at the first
   command or action on an affected stream, in production.

2. *The seed is stale and the discriminator cannot know.* docs/plans/138 makes every
   spec-visible fold change invalidate old snapshots, but a fold change made only in the
   hand-owned Holes module, or in a hand-written service's update/guard bodies, remains a
   manual `stateCodecVersion` bump — and a missed bump silently serves old-fold state
   forever.

After this plan, a **replay audit** exists: a read-only library (plus generated per-service
wiring) that, pointed at a real database — a production copy, a staging environment, a
pre-cutover replica — replays **every live stream through the candidate binary's
transducer** and reports, per stream: full replay succeeded or the exact typed failure;
whether the snapshot-seeded state diverges from the full-replay state (a stale seed, caught
regardless of who forgot which bump); and a stable state digest, so running the audit under
the currently deployed binary and under the candidate and diffing the digests turns *every*
reinterpretation of history — intended or not — into a reviewable line. Running the audit
before switching traffic is the fleet's standard pre-deploy gate for any transducer change.

Secondarily, this plan adds the `keiro-dsl diff` advisories the evolution guide promised
for decide-surface changes: process/router dispatch mapping and timer-payload shape changes
currently produce **no diff output at all**, yet deploying them over a redelivery window
silently merges half-old/half-new fan-out (deterministic dispatch ids confirm the overlap
as benign duplicates). The advisories name the drain-before-deploy procedure at exactly the
moment the change is made.

You can see it working by running the new keiro-test examples: a stream whose history
contains an event with no inverting edge in the candidate machine is reported
`ReplayFailed` *before deploy*; a snapshot written under an old fold with an unbumped
discriminator is reported as `SeedDivergence`; and `keiro-dsl diff` on a fixture pair that
changes a router's dispatch block prints a `RouterDecideSurfaceChanged` advisory.


## Progress

- [ ] M1: `Keiro.ReplayAudit` library shipped (`auditStream`, `auditCategory`,
      `SomeAuditTarget`, report rendering); `hydrateFull`/`hydrateSeeded`/`Hydrated`
      exported from `Keiro.Command`; three keiro-test scenarios green (no-inverting-edge
      caught, stale-seed divergence caught, clean audit with stable digests).
- [ ] M2: scaffolder emits `Generated/<Ctx>/ReplayAudit.hs` audit targets for every
      aggregate node; conformance runtime vertical runs an audit against its provisioned
      database; jitsurei reference assembly added; 24 keiro-dsl suites green.
- [ ] M3: `RouterDecideSurfaceChanged`, `ProcessDecideSurfaceChanged`,
      `ProcessTimerPayloadChanged` diff advisories implemented with fixture pairs;
      diff tests green.
- [ ] Close-out: CHANGELOG entries; master plan 24 EP-5 boxes ticked; contracts recorded
      here for docs/plans/141 to quote; ADR distillation pass (audit rows in the
      evolution-gate inventory).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: The old-log compatibility gate is a database-backed audit tool, not a
  synthetic CI harness of generated old-log fixtures.
  Rationale: Whether a stored event still inverts depends on the *actual history* of each
  stream (guards are re-checked against state folded from every prior event), which no
  synthesized fixture set can enumerate. The golden payloads of docs/plans/139 and
  docs/plans/140 prove decode-ability of old shapes in CI; only replay against real data
  proves replay-ability. The full generated-fixture harness remains the recorded follow-on
  it already was in master plan 24.
  Date: 2026-07-23

- Decision: The audit calls the hydrate *primitives* (`hydrateFull`, `hydrateSeeded`),
  never the public `hydrate`.
  Rationale: `hydrate` deliberately masks a failing seeded replay by falling back to full
  replay (`keiro/src/Keiro/Command.hs:306`) — correct for serving commands, wrong for an
  audit whose job is to *report* that the seed no longer replays or diverges. The
  primitives and the `Hydrated` record become additive exports of `Keiro.Command`.
  Date: 2026-07-23

- Decision: Stale-seed detection compares the *encoded* `(state, registers)` of the
  seeded replay against the full replay (byte equality of the canonical JSON via the
  stream's `StateCodec` encode), not Haskell `Eq`.
  Rationale: `EventStream` state types do not universally carry `Eq`; the codec's encoder
  exists exactly when a snapshot exists, which is the only case with a seed to compare.
  The digest is the SHA-256 of the same canonical encoding, so "seeded == full" and
  "digest stable across binaries" share one canonicalization.
  Date: 2026-07-23

- Decision: The decide-surface advisories compare the *pretty-printed spec surface*
  (router `resolve`/`dispatch` declarations, process `handle` block, timer `payload`
  block) and are Advisories, never Breaking.
  Rationale: Decide changes are usually intentional; the hazard is temporal (redelivery
  windows), so the right gate is a loud reminder of the drain procedure at diff time, in
  the same style as `AggFoldSurfaceChanged` (docs/plans/138). Hole-only decide changes
  remain invisible to diff by construction — the advisory text says so, and the
  deploy-ordering rule (drain on any decide change) is the covering procedure.
  Date: 2026-07-23

- Decision: A runtime cross-version dispatch witness (stamping a decide fingerprint on
  dispatched commands and flagging benign-duplicate confirmations whose stored
  fingerprint differs) is explicitly out of scope; recorded as a follow-on candidate.
  Rationale: It touches the Router dedupe path that master plan 14 hardened, needs a
  metadata read on every duplicate confirmation, and the drain rule plus the diff
  advisory cover the hazard procedurally. Revisit if fleet telemetry shows drain
  discipline failing in practice.
  Date: 2026-07-23

- Decision: Workflow journals are out of the audit's scope.
  Rationale: Journal step results are decoded type-directed at each step's use site
  inside the workflow body — there is no way to decode them without executing the body,
  and replay-to-cursor without side effects is not an existing engine capability.
  Workflow evolution is governed by rename-the-step / patch discipline
  (`docs/guides/evolution-and-replayability.md`) and by master plan 16
  (docs/plans/115 for recovery). The audit covers aggregate and process-manager saga
  streams — the two keiki-transducer use cases.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation. At completion, feed the audit's rows into
the evolution-gate inventory ADR named by master plan 24: old-log inversion — audited
pre-deploy; stale seed — detected by audit regardless of manual-bump discipline;
reinterpretation — reviewable via digest diff; decide-surface change — advised at diff.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`) contains the keiro event-sourcing
runtime. Packages relevant here: `keiro` (the Postgres runtime: `Keiro.Command`,
`Keiro.Snapshot`, `Keiro.ProcessManager`, `Keiro.Router`), `keiro-core` (pure contracts:
`Keiro.EventStream`, `Keiro.Codec`, `Keiro.EventStream.Validate`), `keiro-dsl` (the
`.keiro` spec toolchain), `jitsurei` (the worked example application), and
`keiro-test-support` (database test fixtures). The event store is kiroku, a separate
released package (source at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`,
package `kiroku-store`); keiro talks to it through the `Store` effect.

Architectural ground truth. A keiki transducer (library at
`/Users/shinzui/Keikaku/bokuno/keiki`) is used for exactly two durable-state purposes in
keiro, and both share one machinery:

* **Aggregates handling commands.** `runCommandWithSql` hydrates the stream, steps the
  transducer, appends (`keiro/src/Keiro/Command.hs:536-582`).
* **Process managers handling actions.** A PM's durable state is an ordinary aggregate —
  its *saga* aggregate. `runProcessManagerOnce` advances manager state by calling
  `runCommandWithSql` on the manager's own event stream
  (`keiro/src/Keiro/ProcessManager.hs:471-477`; the `ProcessManager` record carries
  `eventStream :: ValidatedEventStream …` and `streamFor :: Text -> Stream …`,
  `ProcessManager.hs:183-194`). In the DSL, a `process` node references its state
  aggregate via `SagaRef` (`keiro-dsl/src/Keiro/Dsl/Grammar.hs:438-446`, node field
  `procSaga`, `Grammar.hs:559-575`); only `aggregate` nodes declare events and snapshot
  blocks (`Grammar.hs:394-406`).

So an audit that covers "every stream of every aggregate `EventStream` the service
defines" covers process-manager state by construction. Routers are stateless
(`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:1041-1109` emits no stream for them); workflow
journals use a separate fixed codec and are out of scope (see Decision Log).

Hydration, precisely. `hydrate` (`keiro/src/Keiro/Command.hs:286-322`) looks up a
snapshot seed when the stream has a `stateCodec`, replays the suffix from the seed via
`hydrateSeeded`, and *falls back to `hydrateFull` when the seeded replay fails*
(`Command.hs:306`) — the fallback is why a service keeps running while an audit must not
use `hydrate` directly. `hydrateFull` (`Command.hs:324-338`) is `hydrateSeeded` from
`initialState`/`initialRegisters`/version 0. Both run in `Eff es` with `Store :> es` and
return `Either CommandError (Hydrated rs s)` where `Hydrated` carries
`state`, `registers`, `streamVersion` (`Command.hs:274-278`). Replay failures surface as
`HydrationReplayFailed` with a `HydrationNoInvertingEdge` / `HydrationAmbiguousInversion`
/ `HydrationQueueMismatch` / `HydrationTruncatedChain` reason and decode failures as
`HydrationDecodeFailed` (`Command.hs:199-208`, `457-462`). None of `hydrate`,
`hydrateFull`, `hydrateSeeded`, `Hydrated` is currently exported
(`Command.hs:48-63` export list).

Snapshots, precisely. `lookupSnapshotSeed` (`keiro/src/Keiro/Snapshot.hs:80-102`)
returns a `SnapshotHit` seed only when the stored row's discriminator matches the
stream's `StateCodec`. After docs/plans/138 lands the discriminator is three-component
(`stateCodecVersion`, register `shapeHash`, `stateShapeHash` + optional fold
fingerprint); before it lands it is two-component. This plan is correct in either world:
the audit compares whatever seed the lookup accepts against the full replay, which is
precisely the check that catches a seed the discriminator wrongly accepted (the manual
contract's failure mode). `StateCodec` (`keiro-core/src/Keiro/EventStream.hs:102-108`)
carries `encode :: state -> Value`, used for the byte comparison and the digest.

Stream enumeration. kiroku's read API exposes `readCategory` (paged reads of every
message in a category from a global position) and `lookupStreamNames` (resolve internal
stream ids to `StreamName`) —
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Read.hs:147-230`
(the module's own haddock at `Read.hs:205-207` describes collecting distinct
`originalStreamId`s from category batches and resolving them in one call). The audit
enumerates a category's streams that way: page `readCategory`, collect distinct ids,
resolve names once per batch.

The decide-surface diff gap, precisely. `keiro-dsl diff` pairs every node kind but diffs
only identity/shape surfaces: `routerPairDiff` (`keiro-dsl/src/Keiro/Dsl/Diff.hs:232-248`)
fires on stable-name, key, and target changes and **never inspects `rtResolve` or
`rtDispatch`** (`RouterNode` fields, `Grammar.hs:601-614`); `processPairDiff`
(`Diff.hs:810-869`) diffs input shape, bundled identity, and a timer-window advisory but
not the `handle` reaction surface and **not the timer `payload` block** (the generated
timer request builds an unversioned `object [...]` from that block — evidence:
`keiro-dsl/test/conformance-process-full/Generated/SurgeDemo/SurgeFlow/Process.hs:48-56`;
timer rows are opaque unversioned JSONB, `keiro/src/Keiro/Timer/Types.hs:28-35`).
Meanwhile PM/router dispatch idempotency is a deterministic id per
(dispatcher, key, source event, target, occurrence)
(`keiro/src/Keiro/Router.hs:149-189`) with duplicates confirmed benign
(`Router.hs:243-285`) — so a decide change deployed over a redelivery window merges
half-old/half-new fan-out with no signal. The evolution guide
(`docs/guides/evolution-and-replayability.md`, "Changing decisions" section) documents
the drain rule and promised the diff advisory; this plan delivers it.

Ownership boundaries from master plan 24 (Integration Points). This plan owns
`keiro/src/Keiro/ReplayAudit.hs` (new), the additive `Keiro.Command` exports, and — in
`keiro-dsl` — the audit-target emission in `Scaffold.hs` plus a third disjoint share of
`Diff.hs` (decide-surface rules; docs/plans/138 owns the transition-surface advisory,
docs/plans/139 owns deprecation + upcaster-chain rules). `DiagnosticCode` constructor
additions to `Validate.hs` are append-only, same convention as the siblings. Scaffold.hs
is also edited by docs/plans/138 (`stateCodecExpr`) and docs/plans/140 (upcaster
lowering, `scaffoldWorkqueue`) — this plan adds a new emission function and does not
touch theirs; rebase without reformatting neighbours. Conformance fixtures regenerate
once per landed plan; the 24-suite keiro-dsl green bar is the shared acceptance floor.

Relevant ADRs: `docs/adr/` contains only
`0001-keiro-pgmq-job-processing-telemetry-contract.md`, unrelated. The
snapshot-discriminator and evolution-gate-inventory ADRs may exist by execution time
(created by docs/plans/138/139); if the inventory ADR exists, this plan's close-out adds
the audit rows to it.

Term definitions. "Live stream" — a stream the service will hydrate again (non-terminal,
or terminal but still receiving reads that can miss a snapshot). "Seed" — the
`(state, registers, streamVersion)` a snapshot row decodes to. "Digest" — SHA-256 hex of
the canonical JSON encoding of a stream's final `(state, registers)`; comparable across
runs and binaries. "Decide surface" — the spec-visible mapping from an input event to
dispatched commands/timers (router `resolve`+`dispatch`, process `handle`, timer
`payload`), as opposed to hole-owned bodies.


## Plan of Work

### Milestone 1 — the replay audit library in keiro

Scope: `keiro` gains `Keiro.ReplayAudit`; `Keiro.Command` exports its hydrate
primitives; keiro-test proves the three detection scenarios end to end. At the end, any
service that can construct its `ValidatedEventStream`s can audit a database.

Edit `keiro/src/Keiro/Command.hs`: add `hydrate`, `hydrateFull`, `hydrateSeeded`, and
`Hydrated (..)` to the export list under a new `-- * Hydration primitives (replay audit)`
section. No behaviour change; extend the module haddock's pipeline description with one
sentence naming the audit as a consumer.

Add `keiro/src/Keiro/ReplayAudit.hs` (register in `keiro.cabal`'s library stanza).
Public surface:

```haskell
data AuditTarget phi rs s ci co = AuditTarget
    { eventStream :: !(ValidatedEventStream phi rs s ci co)
    , category :: !Text
    , mkStream :: !(StreamName -> Maybe (Stream (EventStream phi rs s ci co)))
    }

data SomeAuditTarget where
    SomeAuditTarget ::
        (BoolAlg phi (RegFile rs, ci), Eq co) =>
        AuditTarget phi rs s ci co -> SomeAuditTarget

data StreamAuditResult = StreamAuditResult
    { streamName :: !StreamName
    , outcome :: !AuditOutcome
    }

data AuditOutcome
    = ReplayOk { streamVersion :: !StreamVersion, digest :: !(Maybe Text) }
    | ReplayFailed { commandError :: !CommandError }
    | SeedDivergence
        { seedVersion :: !StreamVersion
        , seededDigest :: !Text
        , fullDigest :: !Text
        }

data AuditReport = AuditReport
    { targetCategory :: !Text
    , results :: ![StreamAuditResult]
    , streamsAudited :: !Int
    , failures :: !Int
    , divergences :: !Int
    }

auditStream :: … => AuditTarget … -> Stream … -> Eff es StreamAuditResult
auditCategory :: … => AuditTarget … -> Eff es AuditReport
auditTargets :: [SomeAuditTarget] -> Eff es [AuditReport]
renderAuditReport :: AuditReport -> Text          -- one line per non-OK stream
auditExitCode :: [AuditReport] -> Int             -- 0 clean, 1 failures/divergences
```

(Effect constraints follow what the compiler demands from the hydrate primitives —
`IOE :> es, Store :> es` plus the snapshot lookup's requirements; mirror `hydrate`'s
context.) Semantics of `auditStream`, in order:

1. Run `hydrateFull`. On `Left err`, return `ReplayFailed err` — this is the
   no-inverting-edge / ambiguous-inversion / decode-failure detector.
2. If the stream has a `stateCodec` *and* `lookupSnapshotSeed` returns a hit, run
   `hydrateSeeded` from the seed. If the seeded replay fails, or its final
   `(state, registers)` encodes differently (byte comparison of the codec's canonical
   encoding) from the full replay's, return `SeedDivergence` with both digests — this is
   the stale-seed detector, and it works whether the seed was accepted by a two- or
   three-component discriminator, closing the manual-contract residual of
   docs/plans/138.
3. Otherwise return `ReplayOk` with the full-replay version and, when a `stateCodec`
   exists, the digest (SHA-256 hex over the canonical encoding; reuse the SHA-256
   helper already available via keiki's `Keiki.Shape` dependency or `cryptohash`-free
   equivalent already in the dependency tree — do not add a new package; if none is
   importable, vendor the same digest approach `regFileShapeHash` uses).

`auditCategory` enumerates streams by paging `readCategory` from position zero,
collecting distinct stream ids per batch, resolving them with `lookupStreamNames`, and
auditing each name `mkStream` accepts (count and report names it rejects, so a
mis-wired `mkStream` cannot silently audit nothing). The audit is **read-only by
construction**: it calls only read paths and `lookupSnapshotSeed`; it must never call
`verifyAndSnapshot` or any append/write. State the guarantee in the module header.

Tests in `keiro/test/Main.hs`, new `describe "Keiro.ReplayAudit"` group using the
existing `withMigratedSuite` template-database fixture (suite-level, not per-example —
repository convention). Three examples:

1. *No-inverting-edge caught pre-deploy.* Build machine A with an edge emitting event
   `E`; append a history containing `E`. Build machine B identical minus that edge
   (the transition-removal retirement variant that passes every static gate — see
   docs/plans/139's Context). `auditStream` under B reports `ReplayFailed` with a
   `HydrationNoInvertingEdge` reason; under A reports `ReplayOk`.
2. *Stale seed caught regardless of discipline.* Reuse the stale-fold scenario from
   docs/plans/138's Milestone 1 tests: two machines differing in one edge's update with
   *equal* discriminators (the documented residual). Run commands under machine 1 past
   the snapshot interval so a seed persists; `auditStream` under machine 2 reports
   `SeedDivergence` (the seeded digest differs from the full digest). This is the
   companion detection for the residual docs/plans/138 pins as accepted.
3. *Clean audit, stable digest.* A service with history and a valid snapshot reports
   `ReplayOk` for every stream; running the audit twice yields identical digests; and
   `auditCategory` finds exactly the streams that were written.

Acceptance: `cabal test keiro-test` green with the three examples; the module compiles
into `keiro`'s public library surface; CHANGELOG entry under Unreleased (additive:
`Keiro.ReplayAudit`, new `Keiro.Command` exports).

### Milestone 2 — generated audit wiring and the reference assembly

Scope: DSL services get their audit targets generated; one conformance runtime vertical
proves the audit against a provisioned database; jitsurei shows the hand-written
assembly. At the end, wiring the audit into a service is an import, not a design task.

Edit `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`: add an emission function (new, disjoint from
the sibling plans' edits) that, for each context, generates
`Generated/<Ctx>/ReplayAudit.hs` containing
`auditTargets :: [Keiro.ReplayAudit.SomeAuditTarget]` — one entry per `aggregate` node
(including saga aggregates of `process` nodes), wiring the node's generated
`ValidatedEventStream`, its stream category (the spec's category string), and a
`mkStream` that parses the category's stream-name shape (reuse the same stream-name
construction the generated node modules already use). The module is `Generated` kind,
compiled against the live runtime (like `QueuePolicy.hs`), and carries a header stating
the pre-deploy contract: run the audit against a production-copy or staging database
under the candidate binary before switching traffic; non-zero exit means do not deploy.

Register the new generated module in the conformance verticals' `other-modules` and
regenerate fixtures. Extend one runtime vertical that already provisions a database and
appends events (`conformance-process-runtime` or `conformance-v2` — pick the one whose
Main already runs commands; follow its existing fixture pattern) to finish by running
`auditTargets` and asserting every report is clean — the end-to-end proof that generated
wiring, enumeration, and hydration compose.

jitsurei: add a reference assembly for hand-written services — a small
`Jitsurei.ReplayAudit` module (or an addition to `jitsurei/test/Main.hs`) that builds
`SomeAuditTarget` values for the Order aggregate and the escalation PM's saga aggregate
(`jitsurei/src/Jitsurei/EscalationProcess.hs:157-167` is the snapshot-enabled one) and
runs them in the test suite. This doubles as the documentation example docs/plans/141
will cite.

Acceptance: all 24 keiro-dsl suites green; `cabal test jitsurei-test` green (or the
jitsurei suite's actual name — `jitsurei/test/Main.hs`'s cabal stanza); the extended
runtime vertical's output shows the audit summary line.

### Milestone 3 — decide-surface and timer-payload diff advisories

Scope: the promised `diff` advisories exist with machine-readable codes and honest text.
At the end, no spec-visible decide or timer-payload change passes `diff` silently.

Add three `DiagnosticCode` constructors in `keiro-dsl/src/Keiro/Dsl/Validate.hs`
(append-only, same block as the siblings' additions): `RouterDecideSurfaceChanged`,
`ProcessDecideSurfaceChanged`, `ProcessTimerPayloadChanged`.

In `keiro-dsl/src/Keiro/Dsl/Diff.hs` (this plan's disjoint share — new top-level
functions only):

* Extend `routerPairDiff` (`Diff.hs:232-248`) with a rule comparing the pretty-printed
  `rtResolve` and `rtDispatch` of old vs new (render via `Keiro.Dsl.PrettyPrint`, the
  same formatting-insensitivity approach as docs/plans/138's fold surface). On change,
  emit one `advisory` with `RouterDecideSurfaceChanged` and detail: "router dispatch
  surface changed: a source event redelivered across the deploy dispatches under the
  same deterministic ids, so half-old/half-new fan-out merges silently. Drain or pause
  the router's subscription and replay or discard dead letters before deploying; see
  docs/user/deploy-ordering.md." (Wording is a contract for docs/plans/141 to quote.)
* Extend `processPairDiff` (`Diff.hs:810-869`) with the same-shaped rule over the
  spec-visible `handle` surface (`ProcessDecideSurfaceChanged`, same drain detail) and a
  separate rule over the timer `payload` block (`ProcessTimerPayloadChanged`, detail:
  "timer payload shape changed: rows scheduled before the deploy carry the old shape,
  unversioned, and fire under new code — the fire decoder must accept every historically
  scheduled shape or the timer dead-letters after maxAttempts").
* All three are Advisories: `check`'s exit code and `diff`'s breaking classification are
  unchanged; hole-only decide changes remain invisible (each advisory's text ends by
  saying the drain rule applies to those too).

Fixture pairs in `keiro-dsl/test/fixtures/`: copy the incident-paging router fixture
with an altered `dispatch-each` block; copy `hospital-surge.keiro` with an altered
`handle` dispatch and, separately, an altered timer `payload` field list. Tests in
`keiro-dsl/test/Main.hs` follow the existing `diffFixtures` pattern, matching on codes:
each pair yields exactly its advisory and no `Breaking`; formatting-only edits yield
nothing.

Acceptance: `cabal test keiro-dsl-test` green; full 24-suite bar green; manual spot
check prints the advisory:

```bash
cabal run -v0 keiro-dsl -- diff <new-fixture> --since <ref>
```

Close-out: tick master plan 24's EP-5 progress boxes and registry row; record the
externally visible contracts (audit semantics and exit code, generated module shape,
advisory wordings) in this Decision Log for docs/plans/141 to quote; CHANGELOG entries;
run the ADR distillation pass (add the audit and advisory rows to the evolution-gate
inventory ADR if it exists by then, else note them for its creator).


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
# M1
cabal build keiro
cabal test keiro-test

# M2
cabal build keiro-dsl
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/hospital-surge.keiro \
  --out keiro-dsl/test/conformance-process-full
cabal test keiro-dsl          # all 24 suites
cabal test jitsurei-test      # or: (cd jitsurei && cabal test)

# M3
cabal test keiro-dsl-test
cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/<router-decide-fixture>.keiro --since HEAD
```

Expected shapes: keiro-test ends `0 failures` with the three new ReplayAudit examples
listed; the scaffold re-run's `git diff` shows only the new `ReplayAudit.hs` generated
module (plus record-file updates); the diff spot check prints one
`warning[RouterDecideSurfaceChanged]` line and exits zero.

Red-then-green checkpoints: write M1's no-inverting-edge example first and run it
against `hydrate` (not the primitives) to demonstrate the masking fallback — it must
report success where the audit must report failure; capture that transcript in
Surprises & Discoveries as the evidence for the primitives decision. Likewise M1's
stale-seed example must fail (report `ReplayOk`) if pointed at `hydrate`, and pass with
the seeded-vs-full comparison.


## Validation and Acceptance

Behavioural acceptance. (1) A stream whose history contains an event with no inverting
edge in the audited machine is reported `ReplayFailed` with the
`HydrationNoInvertingEdge` reason, against a real store, with no writes performed
(assert the snapshot row and stream head are unchanged after the audit). (2) A snapshot
written under a different fold with an equal discriminator is reported `SeedDivergence`
with two differing digests. (3) A clean service audits `ReplayOk` on every stream with
digests stable across two runs. (4) `auditCategory` on a category with N distinct
streams reports exactly N results. (5) The generated `Generated/<Ctx>/ReplayAudit.hs`
compiles in the conformance verticals and its `auditTargets` cover every aggregate node
of the context (assert count in a scaffold test). (6) The three diff advisories fire on
their fixture pairs with the exact codes, and formatting-only edits fire nothing.
(7) The 24-suite keiro-dsl bar, keiro-test, and the jitsurei suite are green.


## Idempotence and Recovery

The audit is read-only; running it repeatedly against any database is safe by
construction, and interrupting it mid-run has no effect to recover from. All code
changes are additive (new module, new exports, new generated module, new diff rules);
re-running builds, tests, and scaffolds is safe. If the `Keiro.Command` export addition
collides textually with a sibling plan's edit (docs/plans/138 touches the snapshot
write path in the same package), rebase — the export list addition is append-only. If
the digest helper choice proves wrong (no importable SHA-256 without a new dependency),
fall back to the FNV-1a-64 fold precedent from
`keiro-dsl/src/Keiro/Dsl/ReadModelShape.hs:33-58` for the digest only — the divergence
*comparison* is byte equality of encodings and does not depend on the hash — and record
the substitution in the Decision Log.


## Interfaces and Dependencies

At the end of M1, `keiro` exports `Keiro.ReplayAudit` with the types and functions shown
in Milestone 1, and `Keiro.Command` additionally exports `hydrate`, `hydrateFull`,
`hydrateSeeded`, `Hydrated (..)`. At the end of M2, scaffolded contexts contain
`Generated/<Ctx>/ReplayAudit.hs` exposing `auditTargets :: [SomeAuditTarget]`. At the
end of M3, `Keiro.Dsl.Validate.DiagnosticCode` has constructors
`RouterDecideSurfaceChanged`, `ProcessDecideSurfaceChanged`,
`ProcessTimerPayloadChanged`, consumed by new rules in `Keiro.Dsl.Diff`.

Dependencies: no new third-party packages (see Idempotence for the digest fallback).
Coordination: docs/plans/138 (shared keiro snapshot-path files and the stale-fold test
scenario this plan reuses; land order free — the audit's seed comparison is valid with
either discriminator), docs/plans/139/140 (disjoint `Diff.hs`/`Scaffold.hs` shares;
regenerate conformance fixtures once per landed plan), docs/plans/141 (quotes this
plan's Decision Log wordings; documents the audit as the standard pre-deploy gate in
`docs/user/deploy-ordering.md`). Companion guide:
`docs/guides/evolution-and-replayability.md` names this plan as the old-log replay gate
and the decide-surface advisory owner.
