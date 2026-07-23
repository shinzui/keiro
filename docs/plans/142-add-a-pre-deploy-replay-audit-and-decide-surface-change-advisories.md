---
id: 142
slug: add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories
title: "Add a pre-deploy replay audit and decide-surface change advisories"
kind: exec-plan
created_at: 2026-07-23T12:19:38Z
intention: intention_01ky7q57fbevsszaj32g77f6vt
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
remain with **no mechanical check against the data a service has actually stored**:

1. *Inversion breaks or shifts.* A removed or re-pointed transition, a tightened guard,
   or a changed output template makes a stored event fail inversion
   (`HydrationReplayFailed HydrationNoInvertingEdge` / `HydrationAmbiguousInversion`) — or,
   worse, invert *unambiguously to a different edge* so replay succeeds with silently
   different register writes. Pre-merge gates see at most an advisory; startup validation
   checks the new machine in isolation, never against old logs. The failure detonates at
   the first command or action on an affected stream, in production.

2. *The seed is stale and the discriminator cannot know.* docs/plans/138 makes every
   spec-visible fold change invalidate old snapshots, but a fold change made only in the
   hand-owned Holes module, or in a hand-written service's update/guard bodies, remains a
   manual `stateCodecVersion` bump — and a missed bump silently serves old-fold state
   forever.

A naive answer — "full-replay the whole store before every deploy" — does not survive
contact with reality: production categories hold tens of millions of events, and a
routine deploy gate cannot be a store-wide scan. This plan therefore builds a
**differential, budget-bounded replay audit** plus an **amortized runtime witness**, so
that full replay of everything is reserved for the single moment it is proportionate (the
one-time cutover of an existing service onto the keiki runtime) and never required for a
routine deploy:

* **Tier 0 — replay-neutrality verdict, zero data touched.** The interpretation of
  stored data changes *only* when a transition's guard/writes/output surface or the
  codec surface changes. `keiro-dsl diff` gains a replay-impact verdict: when no old
  edge and no decode surface changed, the deploy is proved replay-neutral and **no audit
  is needed at all** — the common case (new events, new edges, additive evolutions).
* **Tier 1 — targeted audit, cost proportional to the change.** When edges did change,
  the diff emits the *affected event-type set* (every type an added/removed/changed edge
  could produce, under the old or new template — a conservative, sound over-approximation).
  The audit then replays **only streams containing affected types** (plus all
  snapshot-bearing streams of the aggregate when its fold surface changed), under a
  budget, in parallel, resumable. A guard edit on one event type costs that type's
  streams — not the store.
* **Tier 2 — full sweep, opt-in.** `AuditFull` replays an entire category: parallel
  across streams, checkpointed/resumable, intended for the one-time keiki-runtime
  cutover of an existing service or post-incident forensics. Replay of one event is
  microseconds of CPU; even large categories are a bounded offline job on a replica —
  but it is never the routine gate.
* **The amortized backstop — sampled runtime seed verification.** For the fold changes
  no fingerprint or diff can see (hole bodies, hand-written code), a small configurable
  fraction of snapshot-seeded hydrations asynchronously full-replays that one stream and
  compares — emitting a divergence metric. No operator action, no deploy gate; the fleet
  converges to verified within hours of any deploy, and a missed manual bump becomes an
  alert instead of silent wrong state.

Every audited stream reports: replay succeeded or the exact typed failure; whether the
snapshot-seeded state diverges from full replay; and a stable state digest, so running
the audit under the deployed binary and the candidate and diffing digests turns *every*
reinterpretation of history — intended or not — into a reviewable line.

Secondarily, this plan adds the `keiro-dsl diff` advisories the evolution guide promised
for decide-surface changes: process/router dispatch mapping and timer-payload shape
changes currently produce **no diff output at all**, yet deploying them over a redelivery
window silently merges half-old/half-new fan-out (deterministic dispatch ids confirm the
overlap as benign duplicates). The advisories name the drain-before-deploy procedure at
exactly the moment the change is made.

You can see it working by running the new keiro-test examples: a stream whose history
contains an event with no inverting edge in the candidate machine is reported
`ReplayFailed` by a *targeted* audit that never read the unaffected streams; a snapshot
written under an old fold with an unbumped discriminator is reported as `SeedDivergence`
(by the audit, and by the sampled runtime witness's metric); `keiro-dsl diff` on an
additive evolution prints `replay-neutral`; and a fixture pair changing a router's
dispatch block prints a `RouterDecideSurfaceChanged` advisory.


## Progress

- [x] M1 (2026-07-23T18:42:11Z): `Keiro.ReplayAudit` core shipped (`auditStreams` with selection/budget/
      parallelism/watermark, `AuditTargeted`/`AuditFull` modes, digests, report
      rendering); `hydrateFull`/`hydrateSeeded`/`Hydrated` exported from
      `Keiro.Command`; keiro-test scenarios green (no-inverting-edge caught by a
      targeted audit, stale-seed divergence caught, clean audit with stable digests,
      targeted selection provably skips unaffected streams).
- [x] M2 (2026-07-23T20:12:00Z): `keiro-dsl diff` replay-impact verdict (`replay-neutral` vs affected
      event-type set, machine-readable); scaffolder emits `Generated/<Ctx>/ReplayAudit.hs`
      audit targets; multi-aggregate process conformance compiles the generated
      assembly; jitsurei's migrated-store test proves targeted skipping and full
      Order/escalation-saga replay.
- [x] M3 (2026-07-23T21:05:00Z): sampled runtime seed verification landed on
      `RunCommandOptions` (one in 1000 snapshot hits by default; zero disables);
      bounded full replay runs asynchronously through the exact seed version,
      emits `keiro.snapshot.seed.divergence` plus structured digests, and never
      writes a snapshot; 352 runtime examples green.
- [x] M4 (2026-07-23T22:14:00Z): `RouterDecideSurfaceChanged`,
      `ProcessDecideSurfaceChanged`, and `ProcessTimerPayloadChanged` diff
      advisories compare canonical pretty-printed spec surfaces; fixture pairs,
      formatting-only negative coverage, the manual CLI path, and all DSL suites
      are green.
- [x] Close-out (2026-07-23T22:46:00Z): CHANGELOG and present-tense user
      guidance updated; plan 143's divert-store residual proved; externally
      visible contracts frozen here; ADR 0004 distilled; master plan 24
      registry, progress, and outcomes completed; repository flake checks green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Kiroku's public `readCategory` API is correct for pagination but would read every
  event in a category merely to discover a small affected stream set. The landed
  selector instead uses Kiroku's documented `events(event_type)`,
  `stream_events(original_stream_id, stream_version)`, and
  `streams(category)` indexes through read-only Hasql statements; replay still uses
  the public Store API. This is the plan's explicitly permitted dedicated-SQL
  substitution.

- `Keiki.Shape` uses SHA-256 internally but does not export its helper. With the
  user's explicit permission to add a dependency in preference to a bespoke
  implementation, the audit uses Aeson's RFC 8785 canonical encoder,
  `cryptohash-sha256`, and `base16-bytestring`. Correctness still uses canonical
  byte equality; the hash is a stable compact review identifier.

- The full M1 database bar passed:

  ```text
  Keiro.ReplayAudit
    catches a removed inverting edge while skipping unaffected streams [✔]
    reports a stale accepted snapshot seed as a divergence [✔]
    keeps clean digests stable and resumes without re-auditing [✔]

  Finished in 80.4740 seconds
  349 examples, 0 failures
  ```

- No existing keiro-dsl conformance executable provisioned PostgreSQL. Retrofitting
  the pure `conformance-process-full` executable with a migrated store also exposed
  that its Cabal test runner was linked against the non-threaded RTS, while Kiroku's
  pool requires `registerDelay`. The vertical remains the live compile proof for the
  generated two-target assembly; Jitsurei's established migrated-store harness is
  the runtime proof, visibly skipping the unaffected saga in targeted mode and then
  full-replaying both Order and escalation-saga targets.

- Generated target assembly originally used a total raw `StreamName` wrapper. That
  would have made a category wiring mistake invisible, so `streamInCategory` now
  checks Kiroku's actual category parse before constructing the phantom-typed stream;
  a rejected name is counted by the audit rather than silently accepted.

- The complete M2 bars passed: all 25 Cabal test components selected by
  `cabal test keiro-dsl` passed, including 237 DSL examples and every generated
  conformance tree; Jitsurei passed 17 examples with targeted `selected=[1,0]`,
  `skipped=[0,1]` followed by full `selected=[1,1]`; and the category-safe runtime
  helper raised the Keiro suite to 350 passing examples.

- Starting an unbounded full replay after snapshot hydration would race the command's
  own append: the background reader could observe a newer head than the served seed
  and report a false divergence. The verifier therefore replays through the immutable
  seed-version boundary using the same paging/fold implementation. The forced sample
  emitted seeded/full SHA-256 digests while the command succeeded at version 3 and the
  snapshot row remained at version 2; rate zero emitted nothing. The full suite passed
  352 examples in 70.3315 seconds.

- Canonical surface rendering kept M4 independent of source layout and parser
  locations: the new rules compare only router resolve/dispatch declarations,
  process handles, and timer payloads. The focused suite passed 241 examples,
  the manual `diff --since HEAD` check printed
  `ProcessDecideSurfaceChanged` and exited zero, and every Cabal component selected
  by `cabal test keiro-dsl` passed.


## Decision Log

- Decision: The audit is differential and budget-bounded, not a full-store replay; the
  full sweep exists only as an opt-in mode for one-time cutovers and forensics.
  Rationale: Production categories hold tens of millions of events (user constraint,
  2026-07-23); a routine deploy gate cannot scan the store. The differential design is
  *sound*, not merely cheaper: replay semantics of stored data change only when an
  edge's guard/writes/output surface or the decode surface changes, so a
  diff-proved-neutral deploy needs no audit, and a non-neutral deploy can only affect
  streams containing the affected event types (see the affected-set decision). The
  one-time full sweep aligns with the fleet plan: when an existing microservice first
  moves onto the keiki runtime there is a migration/cutover window anyway, and that is
  the single proportionate moment for store-wide certainty.
  Date: 2026-07-23

- Decision: The affected event-type set is computed conservatively from the spec diff:
  every event type that any added, removed, or surface-changed transition could produce
  under its old *or* new output template, plus every event type whose codec surface
  (fields, wire clause, version, upcaster) changed; if the aggregate's fold surface
  changed at all, all snapshot-bearing streams of that aggregate are additionally
  selected. Edge comparison is syntactic equality of the pretty-printed
  guard/writes/emits/target surface (the docs/plans/138 fold-surface rendering);
  guard-implication refinement ("weaker guards are compatible") is recorded as a
  possible follow-on, not a commitment.
  Rationale: Soundness argument, stated so a reviewer can check it: an edge whose
  printed surface is unchanged inverts exactly the events it inverted before, applies
  the same writes, and re-checks the same guard — replay of streams containing only
  such edges' events is bitwise identical, so excluding them cannot hide a regression.
  A changed edge can affect (a) inversion of the event types it emits, old or new, and
  (b) downstream guard checks *within streams that contain those events* — both inside
  the selected set. Hand-written services have no spec to diff, so they get no Tier-0/1
  narrowing: their options are targeted-by-event-type selection (caller-supplied) or the
  full sweep, and the plan says so honestly in the generated and library docs.
  Date: 2026-07-23

- Decision: The stale-seed residual (hole-only / hand-written fold changes with a missed
  manual bump) is covered by a *sampled runtime witness*, not by pre-deploy sweeps: a
  configurable fraction of snapshot-seeded hydrations asynchronously full-replays the
  stream and compares encoded states, emitting a divergence metric (extending the
  existing post-append witness vocabulary, `keiro.snapshot.apply.divergence` /
  `keiro.replay.divergence`).
  Rationale: Nothing signals *when* a hole-body fold change ships — no fingerprint sees
  it, so no deploy-time trigger exists even in principle; scheduled sweeps would pay
  store-scale cost for a needle. Sampling attaches the check to exactly the streams
  being served, costs a bounded background replay per N hydrations, converges
  fleet-wide within hours of any deploy, and turns the documented-silent residual of
  docs/plans/138 into an alertable metric. The landed default is one in 1000 compatible
  snapshot hits and `0` is the off switch.
  Date: 2026-07-23

- Decision: A sample compares the decoded snapshot seed with a full replay bounded at
  that seed's stream version, not with an unbounded replay to whatever head the
  background thread happens to observe.
  Rationale: The seed boundary is immutable and directly tests whether the accepted
  row describes the event prefix it claims. An unbounded replay could overlap the
  command append and compare different versions, creating a false positive. The
  bounded path shares `hydrateSeeded`'s paging, decode, gap, and inversion logic and
  differs only by a `takeWhile streamVersion <= seedVersion` cutoff.
  Date: 2026-07-23

- Decision: Use `random`'s atomic process-wide generator for the one-in-N decision and
  Effectful's low-level `async` with a cloned effect environment for the read-only
  replay. Synchronous sampling/spawn failures are swallowed with `trySync`; process
  cancellation remains propagating.
  Rationale: This is a real statistically distributed sampler without bespoke global
  mutable state. Mori confirmed Effectful's `async` clones the effect environment;
  Hackage reports `random` 1.3.1 current and its source documents
  `uniformRM ... globalStdGen` since 1.2.1, so the bound is `>=1.2.1 && <1.4`.
  Upstream tags include v1.3.0; no 1.3.1 tag was published.
  Date: 2026-07-23

- Decision: The replay-impact verdict's guard rule is sharpened from "guard text
  changed → affected" to residue satisfiability: an edge whose guard changed is
  affected only when `old-guard ∧ complement(new-guard)` is satisfiable; an
  unsatisfiable residue (loosening, refactor, equivalence) is proved replay-neutral.
  Rationale: Raised by the user's golden-test question (2026-07-23). Golden replay
  traces cannot soundly detect guard tightening — detection requires a checked-in
  trace to land inside the removed region, which is defined by a *future* predicate
  over command dimensions the trace generator had no reason to vary (in the
  black-acuity example the old guard never mentioned `patientAcuity`). The sound
  equivalent is symbolic: DSL guards are fully spec-visible (`Expr` atoms are
  registers, fields, enums, spec-level rules — `Grammar.hs:238-258`), so residue
  satisfiability is decidable over the comparison fragment, and the complement is the
  same `complementExpr` docs/plans/143 builds for the twin. A satisfiable residue is
  *exactly* the region to paste as the replay-only twin or to target-audit.
  Implementation note: start with a conservative satisfiability check (unsat only for
  syntactic equivalence and recognizable complement/subsumption shapes; anything else
  → affected) and record its precision limits here — over-approximation keeps the
  verdict sound while the checker sharpens. Golden traces stay valuable for the
  variants where one trace per edge *is* sound coverage (edge removal, re-pointing,
  output-template changes) and are already implied by docs/plans/140's harness work.
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
  Aeson's `Data.Aeson.RFC8785.encodeCanonical` supplies the standard canonical
  encoding and `cryptohash-sha256` supplies the plan's specified digest without
  duplicating security-sensitive primitives. "Seeded == full" remains canonical-byte
  equality, so the digest is an operator-facing identifier rather than the correctness
  predicate.
  Date: 2026-07-23

- Decision: Add bounded dependencies on `cryptohash-sha256` 0.11.102.x and
  `base16-bytestring` 1.0.2.x, and raise `aeson`'s lower bound to 2.2.2 for its
  RFC 8785 module.
  Rationale: The user explicitly preferred a proper dependency over a hacked local
  implementation. The versions and APIs were checked against Hackage and their
  upstream release tags after Mori confirmed they were not present in the local
  dependency corpus.
  Date: 2026-07-23

- Decision: Targeted discovery uses dedicated, read-only SQL over Kiroku's documented
  indexed schema, and checkpoints are the maximum global position of the last selected
  stream at the discovery snapshot.
  Rationale: Paging `readCategory` would transfer tens of millions of full payloads just
  to filter their types, defeating the initiative's scale constraint. The selector
  joins the category, event-type, and global-log indexes and returns only stream ids and
  watermarks; `lookupStreamNames` and the public hydrate primitives remain the execution
  path. Ordering streams by their latest global position makes `maxStreams` resumable
  from one opaque Kiroku cursor without re-auditing an unchanged stream. A stream that
  receives a later event may be selected again intentionally because its history
  changed.
  Date: 2026-07-23

- Decision: The replay-impact JSON contract is
  `{"verdict":"replay-neutral"}` or
  `{"verdict":"affected","aggregates":{"<Agg>":{"eventTypes":[...],
  "includeSnapshotStreams":<bool>}}}` with one keyed entry per affected aggregate and
  event arrays emitted in ascending order. The human verdict is always printed, but neither form changes the
  diff command's exit classification.
  Rationale: Deployment tooling needs a stable, deterministic input to construct
  `AuditTargeted`; replay impact is an advisory cost/narrowing decision, while the
  existing Breaking changes remain the compatibility gate.
  Date: 2026-07-23

- Decision: The context-wide generated module exports exactly
  `auditTargets :: [SomeAuditTarget]`, ordered by aggregate declaration. Its
  `mkStream` uses `streamInCategory` with the generated category constant, and
  process saga aggregates appear through their ordinary aggregate declaration.
  Rationale: The generated list is the single typed runtime assembly shared by full
  and targeted audits. Category validation makes wrong wiring observable through
  `rejectedStreams`; deriving saga targets from aggregate declarations avoids a
  second, drift-prone registry.
  Date: 2026-07-23

- Decision: Hand-written services receive target assembly but no automatic
  affected-set narrowing; the jitsurei example therefore exposes both Order and the
  escalation saga and demonstrates a caller-supplied targeted set plus `AuditFull`.
  Rationale: Without old/new specs there is no sound mechanical basis for naming
  affected event types. Operators must pass a conservative set they derived
  themselves or use the full category mode.
  Date: 2026-07-23

- Decision: Keep `conformance-process-full` as a pure compile/run conformance target
  and put M2's store-backed end-to-end proof in Jitsurei's existing migrated-store
  harness.
  Rationale: The conformance executable was not provisioned for PostgreSQL and linked
  a non-threaded RTS, which is incompatible with Kiroku's pool timer. Jitsurei already
  owns the correct threaded resource lifecycle and exercises the exact same public
  generated-assembly shape; retrofitting a second database harness into a pure
  scaffolding test would add infrastructure without strengthening the contract.
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

- Decision: Freeze the operational wording attached to the three advisory
  codes. `RouterDecideSurfaceChanged` says: "router dispatch surface changed:
  a source event redelivered across the deploy dispatches under the same
  deterministic ids, so half-old/half-new fan-out merges silently. Drain or
  pause the router's subscription and replay or discard dead letters before
  deploying; see docs/user/deploy-ordering.md." The process advisory uses the
  same text with "process" in place of "router".
  `ProcessTimerPayloadChanged` says: "timer payload shape changed: rows
  scheduled before the deploy carry the old shape, unversioned, and fire under
  new code — the fire decoder must accept every historically scheduled shape
  or the timer dead-letters after maxAttempts". Each emitted message appends
  the explicit limitation that hole-only changes are invisible and the same
  drain rule applies.
  Rationale: These strings are operator guidance consumed by the completed
  deploy-ordering documentation. The stable diagnostic codes remain the
  tooling contract; the wording preserves the exact redelivery and pending-row
  failure modes that make the advisories actionable.
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

The closing gate is shipped. Routine DSL deploys now get a zero-data
`replay-neutral` proof or a deterministic affected set; generated services get
one category-safe audit assembly; and the candidate binary can audit only the
selected real streams under bounded parallelism with resumable checkpoints.
Replay failures and stale accepted seeds are distinct outcomes with exit 1,
while stable RFC 8785/SHA-256 digests make successful reinterpretations
reviewable across binaries. The full sweep remains deliberately opt-in.

The runtime backstop samples accepted seeds through their immutable stream
version, so a missed manual fold-fingerprint bump becomes
`keiro.snapshot.seed.divergence` without racing the command append or mutating
the snapshot row. Router/process decide and timer-payload edits now surface as
non-breaking coded advisories over normalized AST fragments; formatting-only
changes do not warn, and hole-only changes retain the documented drain rule.

Acceptance passed at every layer: 353 keiro runtime examples after the
plan-143 divert-store integration assertion, 241 focused DSL examples, every
component selected by `cabal test keiro-dsl`, 17 Jitsurei examples including
targeted `[1,0]` / skipped `[0,1]` and full `[1,1]` audit evidence, the manual
`diff --since` warning path, and `nix flake check`. ADR 0004 now owns the
durable gate inventory; transient dependency/API investigations remain here.


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
(`Command.hs:48-63` export list). The existing post-append witness (`verifyAndSnapshot`,
`Command.hs:696-737`) replays only the just-appended batch from the already-hydrated
state and emits `keiro.snapshot.apply.divergence` / the `keiro.replay.divergence` span
attribute on divergence — advisory telemetry, and structurally blind to a stale seed
(it starts *from* the possibly-stale state); Milestone 3's sampled witness extends this
vocabulary with a seed-vs-full comparison.

Snapshots, precisely. `lookupSnapshotSeed` (`keiro/src/Keiro/Snapshot.hs:80-102`)
returns a `SnapshotHit` seed only when the stored row's discriminator matches the
stream's `StateCodec`. After docs/plans/138 lands the discriminator is three-component
(`stateCodecVersion`, register `shapeHash`, `stateShapeHash` + optional fold
fingerprint); before it lands it is two-component. This plan is correct in either world:
the audit and the sampled witness compare whatever seed the lookup accepts against the
full replay, which is precisely the check that catches a seed the discriminator wrongly
accepted (the manual contract's failure mode). `StateCodec`
(`keiro-core/src/Keiro/EventStream.hs:102-108`) carries `encode :: state -> Value`, used
for the byte comparison and the digest.

Stream enumeration and targeting. kiroku's read API exposes `readCategory` (paged reads
of every message in a category from a global position) and `lookupStreamNames` (resolve
internal stream ids to `StreamName`) —
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Read.hs:147-230`
(the module's own haddock at `Read.hs:205-207` describes collecting distinct
`originalStreamId`s from category batches and resolving them in one call). Category rows
carry the event type, so targeted selection — "streams containing at least one event of
an affected type" — is a filtered pass over the same pagination, collecting distinct
stream ids only for matching rows; discovery during implementation may substitute a
dedicated SQL statement if the paged filter proves slow (record the substitution in the
Decision Log; kiroku's schema indexes the category stream).

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
`keiro/src/Keiro/ReplayAudit.hs` (new), the additive `Keiro.Command` exports, the
Milestone 3 witness edit in the snapshot-lookup/command path (coordinate with
docs/plans/138, which owns the discriminator files — the witness edit is confined to
the post-hydration path and a new options field), and — in `keiro-dsl` — the
replay-impact verdict and audit-target emission plus a third disjoint share of
`Diff.hs` (decide-surface rules; docs/plans/138 owns the transition-surface advisory,
docs/plans/139 owns deprecation + upcaster-chain rules). `DiagnosticCode` constructor
additions to `Validate.hs` are append-only, same convention as the siblings. Scaffold.hs
is also edited by docs/plans/138 (`stateCodecExpr`) and docs/plans/140 (upcaster
lowering, `scaffoldWorkqueue`) — this plan adds new emission functions and does not
touch theirs; rebase without reformatting neighbours. The replay-impact verdict reuses
docs/plans/138's `aggregateFoldSurface` rendering per transition (import it if 138 has
landed; otherwise implement the per-transition rendering locally and reconcile at
whichever lands second — record the choice in both Decision Logs). Conformance fixtures
regenerate once per landed plan; the 24-suite keiro-dsl green bar is the shared
acceptance floor.

Relevant ADRs consulted during implementation:
`docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`
defines the retained-edge remedy whose real-log relevance this audit checks;
`docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md`
defines the manual-contract residual caught by seeded-vs-full comparison; and
`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`
owns the gate inventory this plan extends at close-out. ADR 0001 remains unrelated.

Term definitions. "Live stream" — a stream the service will hydrate again (non-terminal,
or terminal but still receiving reads that can miss a snapshot). "Seed" — the
`(state, registers, streamVersion)` a snapshot row decodes to. "Digest" — SHA-256 hex
over RFC 8785 canonical JSON for a stream's final `(state, registers)`; comparable
across runs and binaries, but not itself the byte-equality correctness predicate.
"Replay-neutral" — a spec change under which every retained edge's
pretty-printed guard/writes/emits/target surface and the whole decode surface are
unchanged, so replay of existing data is bitwise identical by construction.
"Affected set" — the conservative over-approximation of event types whose stored
occurrences could replay differently (see Decision Log). "Decide surface" — the
spec-visible mapping from an input event to dispatched commands/timers (router
`resolve`+`dispatch`, process `handle`, timer `payload`), as opposed to hole-owned
bodies.


## Plan of Work

### Milestone 1 — the replay audit core in keiro

Scope: `keiro` gains `Keiro.ReplayAudit` with targeted and full modes; `Keiro.Command`
exports its hydrate primitives; keiro-test proves detection and — equally important —
proves the targeted mode *skips* what it may soundly skip.

Edit `keiro/src/Keiro/Command.hs`: add `hydrate`, `hydrateFull`, `hydrateSeeded`, and
`Hydrated (..)` to the export list under a new `-- * Hydration primitives (replay audit)`
section. No behaviour change; extend the module haddock's pipeline description with one
sentence naming the audit as a consumer.

Add `keiro/src/Keiro/ReplayAudit.hs` (register in `keiro.cabal`'s library stanza).
Public surface:

```haskell
data AuditMode
    = AuditFull
      -- ^ Every stream in the category. One-time cutovers and forensics only.
    | AuditTargeted !AffectedSet
      -- ^ Only streams containing at least one event whose type is in the set,
      --   plus (when the set says so) all snapshot-bearing streams.

data AffectedSet = AffectedSet
    { affectedEventTypes :: !(Set EventType)
    , includeSnapshotStreams :: !Bool   -- fold surface changed
    }

data AuditBudget = AuditBudget
    { maxStreams :: !(Maybe Int)        -- Nothing = unbounded
    , parallelism :: !Int
    , resumeFrom :: !(Maybe GlobalPosition)  -- checkpoint watermark
    }

data AuditTarget phi rs s ci co = AuditTarget
    { eventStream :: !(ValidatedEventStream phi rs s ci co)
    , category :: !Text
    , mkStream :: !(StreamName -> Maybe (Stream (EventStream phi rs s ci co)))
    }

data SomeAuditTarget where
    SomeAuditTarget ::
        (BoolAlg phi (RegFile rs, ci), Eq co) =>
        AuditTarget phi rs s ci co -> SomeAuditTarget

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
    , mode :: !Text                     -- "full" | "targeted"
    , results :: ![StreamAuditResult]   -- non-OK always retained; OK counted
    , streamsSelected :: !Int
    , streamsSkipped :: !Int            -- targeted mode: proven-unaffected streams
    , failures :: !Int
    , divergences :: !Int
    , checkpoint :: !(Maybe GlobalPosition)
    }

auditStream  :: … => AuditTarget … -> Stream … -> Eff es StreamAuditResult
auditStreams :: … => AuditMode -> AuditBudget -> AuditTarget … -> Eff es AuditReport
auditTargets :: AuditMode -> AuditBudget -> [SomeAuditTarget] -> Eff es [AuditReport]
renderAuditReport :: AuditReport -> Text
auditExitCode :: [AuditReport] -> Int   -- 0 clean, 1 failures/divergences
```

(Effect constraints follow what the compiler demands from the hydrate primitives —
`IOE :> es, Store :> es` plus the snapshot lookup's requirements; mirror `hydrate`'s
context. `GlobalPosition` is kiroku's category position type.) Semantics of
`auditStream`, in order:

1. Run `hydrateFull`. On `Left err`, return `ReplayFailed err` — the
   no-inverting-edge / ambiguous-inversion / shifted-inversion / decode-failure
   detector.
2. If the stream has a `stateCodec` *and* `lookupSnapshotSeed` returns a hit, run
   `hydrateSeeded` from the seed. If the seeded replay fails, or its final
   `(state, registers)` encodes differently (byte comparison of the codec's canonical
   encoding) from the full replay's, return `SeedDivergence` with both digests.
3. Otherwise return `ReplayOk` with the full-replay version and, when a `stateCodec`
   exists, the SHA-256 digest over RFC 8785 canonical JSON. Canonical-byte equality,
   not the digest, decides divergence.

`auditStreams` drives selection with dedicated read-only SQL over Kiroku's indexed
category/event-type/global-log schema. In `AuditTargeted` mode it returns only stream
ids containing an affected type (and, when `includeSnapshotStreams`, unions the
aggregate's snapshot-bearing streams); `AuditFull` returns every non-empty category
stream. Each selected row carries the stream's latest global position, so ordering by
that opaque cursor, resolving names with `lookupStreamNames`, and checkpointing the last
audited row makes `maxStreams` resumable without re-auditing an unchanged stream.
Accepted streams run through `parallelism` workers. Count and report names `mkStream`
rejects (a mis-wired `mkStream` must not silently audit nothing) and count skipped
streams (the targeted mode's savings must be visible in the report). The audit is
**read-only by construction**: it calls only read paths and `lookupSnapshotSeed`; it
must never call `verifyAndSnapshot` or any append/write. State the guarantee in the
module header, together with the tier ladder and the honest statement that hand-written
services without a spec get no automatic affected-set — they pass their own or use
`AuditFull`.

Tests in `keiro/test/Main.hs`, new `describe "Keiro.ReplayAudit"` group using the
existing `withMigratedSuite` template-database fixture (suite-level, not per-example —
repository convention). Four examples:

1. *No-inverting-edge caught by a targeted audit.* Build machine A with an edge emitting
   event `E`; append histories to several streams, only some containing `E`. Build
   machine B identical minus that edge (the transition-removal retirement variant that
   passes every static gate — docs/plans/139's Context). `auditStreams` under B with
   `AuditTargeted {affectedEventTypes = [E]}` reports `ReplayFailed` with a
   `HydrationNoInvertingEdge` reason for every `E`-bearing stream **and**
   `streamsSkipped` equal to the number of `E`-free streams — the audit finds the bug
   without reading the unaffected streams. Under machine A the same call is clean.
2. *Stale seed caught regardless of discipline.* Reuse the stale-fold scenario from
   docs/plans/138's Milestone 1 tests: two machines differing in one edge's update with
   *equal* discriminators (the documented residual). Run commands under machine 1 past
   the snapshot interval so a seed persists; `auditStream` under machine 2 reports
   `SeedDivergence` (the seeded digest differs from the full digest).
3. *Clean audit, stable digest, resumability.* A service with history and a valid
   snapshot reports `ReplayOk` for every stream; digests identical across two runs; a
   run with `maxStreams = 1` returns a `checkpoint` from which a second run completes
   the remainder with no stream audited twice.
4. *Full mode parity.* `AuditFull` over the same fixtures selects every stream
   (`streamsSkipped == 0`) and agrees with targeted mode on every overlapping verdict.

Acceptance: `cabal test keiro-test` green with the four examples; the module compiles
into `keiro`'s public library surface; CHANGELOG entry under Unreleased (additive:
`Keiro.ReplayAudit`, new `Keiro.Command` exports).

### Milestone 2 — the replay-impact verdict and generated wiring

Scope: `keiro-dsl diff` learns to say "this deploy cannot change replay" or to name
exactly what it can change; scaffolded services get their audit targets generated; one
conformance runtime vertical proves the pipeline end to end; jitsurei shows the
hand-written assembly.

Add the replay-impact computation (new module `Keiro.Dsl.ReplayImpact`, keeping
`Diff.hs`'s sibling-owned regions untouched): given the old and new spec, per aggregate:

* Render every transition's guard/writes/emits/target surface with the pretty-printer
  (reuse docs/plans/138's `aggregateFoldSurface` per-transition rendering when
  available — see Context for the landing-order reconciliation) and pair transitions
  across old/new.
* The verdict is **replay-neutral** iff every old transition's surface is present
  unchanged in the new spec (additions are fine) *and* the decode surface is unchanged
  (event fields, wire clauses, versions, upcaster declarations — the surfaces
  `eventDiff` already classifies). Otherwise emit the **affected set**: event types any
  changed/removed transition emits (old or new template) plus event types whose decode
  surface changed, and `includeSnapshotStreams = True` when the fold surface changed.

Wire it into the `diff` subcommand (`keiro-dsl/app/Main.hs`): a
`--replay-impact-out FILE` option writing machine-readable JSON
(`{"verdict": "replay-neutral"}` or
`{"verdict": "affected", "aggregates": {"<Agg>": {"eventTypes": [...],
"includeSnapshotStreams": bool}}}`), and a human line in the normal diff output
(`replay-neutral: stored-data replay is unchanged by this diff` — or the affected
summary with a pointer to the audit). This is advisory output only; it never flips the
exit classification.

Scaffolder: add an emission function (new, disjoint from the sibling plans' edits)
generating `Generated/<Ctx>/ReplayAudit.hs` with
`auditTargets :: [Keiro.ReplayAudit.SomeAuditTarget]` — one entry per `aggregate` node
(including saga aggregates of `process` nodes), wiring the node's generated
`ValidatedEventStream`, its category string, and a `mkStream` that parses the category's
stream-name shape (reuse the stream-name construction the generated node modules already
use). The module is `Generated` kind, compiled against the live runtime (like
`QueuePolicy.hs`), and carries a header stating the tiered contract: consume the diff's
replay-impact verdict; `replay-neutral` → no audit; affected → run `AuditTargeted` with
the emitted set against a production-copy or staging database under the candidate
binary; `AuditFull` at one-time cutovers; non-zero exit means do not deploy.

Register the new generated module in the conformance verticals' `other-modules` and
regenerate fixtures. Extend one runtime vertical that already provisions a database and
appends events (`conformance-process-runtime` or `conformance-v2` — pick the one whose
Main already runs commands; follow its existing fixture pattern) to finish by running a
targeted audit over its own written streams and asserting every report is clean — the
end-to-end proof that verdict, generated wiring, enumeration, and hydration compose.

jitsurei: add a reference assembly for hand-written services — a small
`Jitsurei.ReplayAudit` module (or an addition to `jitsurei/test/Main.hs`) that builds
`SomeAuditTarget` values for the Order aggregate and the escalation PM's saga aggregate
(`jitsurei/src/Jitsurei/EscalationProcess.hs:157-167` is the snapshot-enabled one) and
runs them in the test suite. This doubles as the documentation example docs/plans/141
will cite, including the honest hand-written caveat (no spec → no automatic narrowing).

Tests: unit tests for the verdict (additive evolution — new event, new edge — is
replay-neutral; a guard edit yields exactly that transition's event types; a wire-clause
change yields that event type; a write-expression change sets
`includeSnapshotStreams`); a fixture-pair test asserting `reservation.keiro` →
`reservation-v2.keiro` is *not* neutral (its event codec surface changed) while a
formatting-only edit *is*; scaffold test asserting the generated module names every
aggregate node of the context.

Acceptance: all 24 keiro-dsl suites green; `cabal test jitsurei-test` green (or the
jitsurei suite's actual cabal name); the extended runtime vertical's output shows the
audit summary line with `streamsSkipped` visible.

### Milestone 3 — sampled runtime seed verification

Scope: the amortized backstop for fold changes nothing can see at deploy time. At the
end, a missed manual `stateCodecVersion` bump surfaces as a metric within hours of
serving traffic, at bounded cost, with no operator action.

Add a sampling knob to the command path's options (`RunCommandOptions`,
`keiro/src/Keiro/Command.hs` — field name and default fixed at implementation, e.g.
`seedVerifySampleRate :: !Int` meaning "verify one in N snapshot-seeded hydrations";
`0` disables). After a hydration that was served from a snapshot seed, when the sampler
fires, run `hydrateFull` for the same stream *asynchronously* (off the command's
critical path — reuse the runtime's existing async/worker facility; never block or fail
the command) and compare the seeded `(state, registers)` encoding at the seed's version
boundary against the full replay's. On divergence, emit a metric in the existing
witness vocabulary (`keiro.snapshot.seed.divergence`, alongside
`keiro.snapshot.apply.divergence`) and a structured log line naming stream, seed
version, and both digests. Document on the field: this is the detection path for
fold-logic changes invisible to the discriminator (hand-written bodies, DSL holes); it
is sampling, so it bounds cost, not latency-to-detection — the deploy-ordering doc
(docs/plans/141) tells operators to alert on the metric.

Tests in `keiro/test/Main.hs`: with the sampler forced to fire (rate 1), the stale-fold
scenario from M1's example 2 produces the divergence metric (assert via the suite's
existing metrics-capture pattern) while the command itself still succeeds; with rate 0
nothing fires; the async verification does not write snapshots (assert row unchanged).

Acceptance: `cabal test keiro-test` green; the new option documented in the CHANGELOG
with its default and off switch.

### Milestone 4 — decide-surface and timer-payload diff advisories

Scope: the promised `diff` advisories exist with machine-readable codes and honest text.
At the end, no spec-visible decide or timer-payload change passes `diff` silently.

Add three `DiagnosticCode` constructors in `keiro-dsl/src/Keiro/Dsl/Validate.hs`
(append-only, same block as the siblings' additions): `RouterDecideSurfaceChanged`,
`ProcessDecideSurfaceChanged`, `ProcessTimerPayloadChanged`.

In `keiro-dsl/src/Keiro/Dsl/Diff.hs` (this plan's disjoint share — new top-level
functions only):

* Extend `routerPairDiff` (`Diff.hs:232-248`) with a rule comparing the pretty-printed
  `rtResolve` and `rtDispatch` of old vs new. On change, emit one `advisory` with
  `RouterDecideSurfaceChanged` and detail: "router dispatch surface changed: a source
  event redelivered across the deploy dispatches under the same deterministic ids, so
  half-old/half-new fan-out merges silently. Drain or pause the router's subscription
  and replay or discard dead letters before deploying; see
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
externally visible contracts (verdict JSON shape, audit semantics and exit code,
sampling-witness metric name, generated module shape, advisory wordings) in this
Decision Log for docs/plans/141 to quote; CHANGELOG entries; run the ADR distillation
pass (add the audit and advisory rows to the evolution-gate inventory ADR if it exists
by then, else note them for its creator).


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
# M1
cabal build keiro
cabal test keiro-test

# M2
cabal build keiro-dsl
cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/reservation-v2.keiro \
  --since HEAD --replay-impact-out /tmp/impact.json
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/hospital-surge.keiro \
  --out keiro-dsl/test/conformance-process-full
cabal test keiro-dsl          # all 24 suites
cabal test jitsurei-test      # or: (cd jitsurei && cabal test)

# M3
cabal test keiro-test

# M4
cabal test keiro-dsl-test
cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/<router-decide-fixture>.keiro --since HEAD
```

Expected shapes: keiro-test ends `0 failures` with the ReplayAudit and seed-witness
examples listed; the replay-impact run writes JSON with an `affected` verdict for the
v1→v2 evolution; the scaffold re-run's `git diff` shows only the new `ReplayAudit.hs`
generated module (plus record-file updates); the M4 diff spot check prints one
`warning[RouterDecideSurfaceChanged]` line and exits zero.

Red-then-green checkpoints: write M1's no-inverting-edge example first and run it
against `hydrate` (not the primitives) to demonstrate the masking fallback — it must
report success where the audit must report failure; capture that transcript in
Surprises & Discoveries as the evidence for the primitives decision. Likewise M1's
stale-seed example must report `ReplayOk` if pointed at `hydrate`, and reports
`SeedDivergence` with the seeded-vs-full comparison. For M2, run the verdict on a
formatting-only spec edit before implementing neutrality detection and confirm the
naive answer would have been "affected" — the neutral verdict is the feature.


## Validation and Acceptance

Behavioural acceptance. (1) A stream whose history contains an event with no inverting
edge in the audited machine is reported `ReplayFailed` with the
`HydrationNoInvertingEdge` reason by a **targeted** audit whose report shows the
unaffected streams were skipped, against a real store, with no writes performed (assert
the snapshot row and stream head are unchanged after the audit). (2) A snapshot written
under a different fold with an equal discriminator is reported `SeedDivergence` with two
differing digests — by the audit, and by the M3 sampled witness as a
`keiro.snapshot.seed.divergence` emission while the command still succeeds. (3) A clean
service audits `ReplayOk` on every selected stream with digests stable across two runs,
and a budget-capped run resumes from its checkpoint without re-auditing. (4) `diff`
declares an additive evolution `replay-neutral` and a guard edit `affected` with exactly
that transition's event types; the JSON round-trips into `AffectedSet`. (5) The
generated `Generated/<Ctx>/ReplayAudit.hs` compiles in the conformance verticals and its
`auditTargets` cover every aggregate node of the context (assert count in a scaffold
test). (6) The three diff advisories fire on their fixture pairs with the exact codes,
and formatting-only edits fire nothing. (7) The 24-suite keiro-dsl bar, keiro-test, and
the jitsurei suite are green.


## Idempotence and Recovery

The audit is read-only; running it repeatedly against any database is safe by
construction, and an interrupted run resumes from its reported checkpoint. The M3
witness is sampling-based, asynchronous, and write-free; disabling it (rate 0) restores
exactly today's behaviour. All code changes are additive (new modules, new exports, new
options field, new generated module, new diff rules); re-running builds, tests, and
scaffolds is safe. If the `Keiro.Command` export addition or the M3 options field
collides textually with docs/plans/138's edits in the same package, rebase — both are
append-only. If the paged category filter proves too slow for targeted selection on a
large replica, substitute a dedicated SQL statement over kiroku's category index and
record it in the Decision Log — the selection contract (distinct streams containing
affected types) is what matters, not the mechanism.


## Interfaces and Dependencies

At the end of M1, `keiro` exports `Keiro.ReplayAudit` with the types and functions shown
in Milestone 1 (`AuditMode`, `AffectedSet`, `AuditBudget`, `AuditTarget`,
`SomeAuditTarget`, `AuditOutcome`, `AuditReport`, `auditStream`, `auditStreams`,
`auditTargets`, `renderAuditReport`, `auditExitCode`), and `Keiro.Command` additionally
exports `hydrate`, `hydrateFull`, `hydrateSeeded`, `Hydrated (..)`. At the end of M2,
`keiro-dsl` ships `Keiro.Dsl.ReplayImpact` (verdict + affected-set computation), the
`diff --replay-impact-out` option, and scaffolded contexts contain
`Generated/<Ctx>/ReplayAudit.hs` exposing `auditTargets :: [SomeAuditTarget]`. At the
end of M3, `RunCommandOptions` carries the seed-verification sampling field and the
runtime emits `keiro.snapshot.seed.divergence`. At the end of M4,
`Keiro.Dsl.Validate.DiagnosticCode` has constructors `RouterDecideSurfaceChanged`,
`ProcessDecideSurfaceChanged`, `ProcessTimerPayloadChanged`, consumed by new rules in
`Keiro.Dsl.Diff`.

Dependencies: `aeson >= 2.2.2 && < 2.3` for RFC 8785 canonical JSON,
`cryptohash-sha256 >= 0.11.102 && < 0.12` for SHA-256, and
`base16-bytestring >= 1.0.2 && < 1.1` for lowercase hexadecimal rendering. These
bounds were checked against the authoritative package registry and upstream tags.
Coordination: docs/plans/138 (shared keiro command/snapshot-path files, the stale-fold
test scenario this plan reuses, and the per-transition surface rendering the
replay-impact verdict shares with `aggregateFoldSurface` — land order free, reconcile at
whichever lands second), docs/plans/139/140 (disjoint `Diff.hs`/`Scaffold.hs` shares;
regenerate conformance fixtures once per landed plan), docs/plans/141 (quotes this
plan's Decision Log wordings; documents the tier ladder — verdict, targeted audit,
cutover sweep, witness alerting — in `docs/user/deploy-ordering.md`). Companion guide:
`docs/guides/evolution-and-replayability.md` names this plan as the old-log replay gate
and the decide-surface advisory owner.
