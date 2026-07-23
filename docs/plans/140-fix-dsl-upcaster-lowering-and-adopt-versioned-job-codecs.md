---
id: 140
slug: fix-dsl-upcaster-lowering-and-adopt-versioned-job-codecs
title: "Fix DSL upcaster lowering and adopt versioned job codecs"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
intention: intention_01ky7q57fbevsszaj32g77f6vt
master_plan: "docs/masterplans/24-close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review.md"
---

# Fix DSL upcaster lowering and adopt versioned job codecs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

When a keiro-dsl aggregate has more than one event kind and evolves one of them, the
generated upcaster wiring lies to the hole author. keiro's codec deliberately hands every
upcaster the stored event-type tag so multi-event codecs can migrate by the authoritative
wire tag (`keiro-core/src/Keiro/Codec.hs:59-65`); the scaffolder throws that tag away —
it emits `(m, const upcast<Event>Vm)` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:1565-1567`) —
while schema-version stamps are aggregate-global (`Scaffold.hs:1539,1550-1552` sets
`schemaVersion = maxEventVersion`; `encodeForAppendWithMetadata`,
`keiro-core/src/Keiro/Codec.hs:192-228`, stamps that one number on *every* kind). So a
version-m upcaster receives every event kind's payload stored at m, the hole stub never
says so (`Scaffold.hs:1849-1862`), and the generated harness only ever feeds the declaring
event's own current-shape payload through the chain
(`keiro-dsl/src/Keiro/Dsl/Harness.hs:405-421`). The failure gradation is verified:
unfilled or strict-matching upcasters fail loudly (`UpcasterError` /
`HydrationDecodeFailed` blocking whole streams); purely-additive upcasters leave benign
junk keys on other kinds; and overlapping field names plus a transforming upcaster corrupt
values *silently* — a shared `"amount"` field renamed-and-scaled for one kind rescales the
other kind's amounts 100× straight into the fold.

Separately, plan 55 built a versioned pgmq job codec — `keiroJobCodec`, a
`{"v","t","data"}` envelope with the upcaster chain and a `JobPayloadFromFuture`
rolling-deploy retry (`keiro-pgmq/src/Keiro/PGMQ/Codec.hs:76-106`) — and nothing adopted
it: plans 56/57 chose `aesonJobCodec`, and the DSL's workqueue vertical wires the plain
unversioned `mkJobCodec encode parse` (the gap plan 63 recorded honestly in its Coverage
Gaps). Every scaffolded queue is therefore unversioned from birth, and the first payload
evolution has no envelope to hang a version on.

After this plan: each generated upcaster rung is a per-event *dispatch* — the declaring
event's hole sees only its own kind's payloads and every other kind passes through
untouched, making the correct thing automatic; the generated hole stubs and harness state
the real contract; harness upcast assertions run *genuine* serialized old payloads
(golden fixtures, shared format with plan 139), not current-shape stand-ins; and
scaffolded workqueue jobs get a `keiroJobCodec`-backed versioned codec from birth, with
drain-first migration guidance for existing queues. You can see it working in the
regenerated conformance fixtures (the dispatch is visible in the generated Codec module),
in a new two-kind corruption test that fails under the old lowering and passes under the
new one, and in the queue conformance suites now exchanging enveloped payloads.


## Progress

- [x] (2026-07-23T17:59:28Z) M1: per-rung dispatch lowering emitted; codec-level two-kind corruption regression green; hole stub documents the contract; conformance fixture regenerated; `DuplicateUpcasterSource` validator rule relaxed in step; 24 suites green.
- [x] (2026-07-23T17:59:28Z) M2: `diff --emit-goldens` implemented and idempotence-checked; scaffold `--goldens` embeds golden payloads into the generated harness; conformance-v2 runs a genuine v1 payload; mutation fails as intended; 24 suites green.
- [x] (2026-07-23T17:59:28Z) M3: scaffolder emits `keiroJobCodec`-backed queue codec module; queue/dispatch conformance verticals migrated and green; the exact `{v,t,data}` PGMQ body boundary is asserted; drain-first guidance is in generated docs and CHANGELOG; ADR-0001 semantics remain untouched.
- [x] (2026-07-23T17:59:28Z) Close-out: master plan 24 EP-3 box ticked; contracts recorded for plan 141; ADR 0004 distilled.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Audit of the hurried work (2026-07-23): the first generated `QueueCodec`
  exported `reservation_workJobCodec` while both migrated consumers imported
  `reservationWorkJobCodec`; it could not compile. Normalizing underscore
  segments to lower camel case fixed the symbol and the skeleton fixture now
  compiles the same generated module.
- Audit of the hurried work (2026-07-23): adding `QueueCodec` changed the
  complete workqueue scaffold set, but the committed fresh-skeleton fixture
  omitted the new module. The focused suite failed with a missing-file error
  until the fixture and Cabal module/dependency lists were updated.
- Golden mutation proof (2026-07-23): changing the v1 fixture key from
  `reservationId` to `reservationIdentifier`, regenerating, and running
  `keiro-dsl-conformance-v2` produced two named failures:

  ```text
  FAIL  golden TransferReservationCreated.v1 decodes
  FAIL  golden TransferReservationCreated.v1
  ```

  Restoring the fixture and regenerating returned the suite to green.
- Acceptance correction (2026-07-23): the queue conformance suites are pure
  executables and do not provision PostgreSQL, contrary to this plan's initial
  wording. This does not leave an untested transform: `Keiro.PGMQ.Job.enqueue`
  writes `MessageBody (encodeJob job.jobCodec p)` directly and both consumer
  paths apply `decodeJob` directly. The conformance suite now pins the exact
  `{v,t,data}` `Value`, its decode round trip, and compilation into a live
  `Job`; no database claim is made.


## Decision Log

- Decision: Fix the lowering with a generated per-rung dispatch wrapper (holes keep the
  simple `Value -> Either Text Value` signature; the wrapper routes by `EventType` and
  passes other kinds through), rather than widening every hole signature to
  `EventType -> Value -> Either Text Value`.
  Rationale: The wrapper makes the correct behavior automatic — a hole author cannot
  forget to pass through foreign kinds, which is precisely the silent-corruption path.
  Tag-taking holes would push the every-kind contract onto every author forever and turn
  each hole into a mandatory case-split. The pass-through is derivable from the current
  spec alone: at rung m, exactly the events declaring `upcast from v<m>` transform; a kind
  whose shape did not change at m→m+1 is by construction identical on both sides of that
  rung, so identity is correct — no version history is needed. Recorded fallback (not
  taken): if a future grammar admits shapes where pass-through is wrong, switch to
  tag-passing holes with loud stub docs.
  Date: 2026-07-23

- Decision: The dispatch lowering merges same-source-version upcasts from *different*
  events into one rung, so plan 139's `DuplicateUpcasterSource` check is relaxed in the
  same change: it stays an Error when a single event somehow declares two rungs from one
  source, but two *different* events sharing a source version becomes legal and lowers to
  one dispatching rung. This is the coordinated edit to `Validate.hs` (owned by plan 139)
  that plan 139's Decision Log pre-authorizes for this plan; it lands only after plan 139
  has landed (EP-3's soft dependency on EP-2 in master plan 24).
  Rationale: With `const` lowering, duplicate sources meant a dead upcaster; with
  dispatch, they are the natural expression of "two kinds changed shape in the same
  release". The boundary `mkCodec` check stays satisfied because the merged rung has a
  unique source version.
  Date: 2026-07-23

- Decision: Golden capture mechanism is `keiro-dsl diff --since <ref> --emit-goldens
  <dir>`: at diff time — the only moment the *old* spec is still available — synthesize,
  for each event whose version bumps in the diff, an old-shape payload from the old spec's
  field list and wire clause, and write `<Event>.v<oldN>.json` if absent (deterministic
  placeholder values by field category). The scaffold-time-snapshot alternative was
  rejected: the scaffolder sees only the current shape and cannot reconstruct old wire
  shapes.
  Rationale: The old spec fully determines the old wire *shape* (kind discriminator, field
  names, casing); values are representative samples, which is exactly what a
  decodability-of-shape assertion needs. Files are never overwritten, so a hand-captured
  genuine production payload (always preferable when available) wins over the synthesized
  one. Format and path convention are owned by plan 139's Decision Log:
  `…/golden-payloads/<context>/<Aggregate>/<EventName>.v<N>.json`.
  Date: 2026-07-23

- Decision: The versioned job codec is emitted as a new generated module
  `<genPrefix>.QueueCodec` compiled against the live `keiro-core`/`keiro-pgmq` (like the
  existing `QueuePolicy` module), leaving `Queue.hs` self-contained (base/text/aeson only)
  so the scaffolder's symbol-free firewall on the payload module holds. Queues are
  versioned from birth at schema version 1 with an empty upcaster list; payload-evolution
  grammar (versions/upcasts on workqueue payloads) is deliberately out of scope — the
  envelope shipped now is what makes adding it later a non-breaking change.
  Rationale: The cost of the envelope is near zero on day one; the cost of *not* having it
  is the documented drain-or-dead-letter migration every existing queue now faces
  (`keiro-pgmq/src/Keiro/PGMQ/Codec.hs:22-26`).
  Date: 2026-07-23

- Decision: M3's acceptance is the exact `JobCodec` JSON boundary plus live
  `Job` assembly, not a claimed database integration test.
  Rationale: Inspection found the existing queue conformance programs do not
  provision PostgreSQL. The runtime adds no intermediate encoding:
  `Keiro.PGMQ.Job.enqueue` wraps `encodeJob` directly in `MessageBody` and its
  consumer paths call `decodeJob` on the stored payload. Pinning the envelope
  value and round trip therefore proves the changed boundary without inventing
  test evidence. Database queue mechanics are independent of the codec.
  Date: 2026-07-23


## Outcomes & Retrospective

EP-3 is complete. Generated aggregate codecs now merge same-source event
upcasters into one `EventType` dispatcher, pass unrelated kinds through
unchanged, and keep event-specific holes simple. `diff --emit-goldens` captures
old wire shapes without overwriting hand-captured payloads; `scaffold --goldens`
embeds them into self-contained harnesses and labels the fallback stand-in
honestly. Generated workqueues now expose schema-v1 `keiroJobCodec` adapters,
with lower-camel symbols, complete manifests/skeleton fixtures, and the
drain-first adoption warning.

Validation completed with 230 unit examples, all 24 `keiro-dsl` suites, focused
v2/queue/queue-runtime/dispatch/skeleton suites, CLI write-once idempotence, and
the golden mutation failure. ADR 0004 now records the dispatch, golden, and job
codec boundaries. ADR 0001 did not change because the job codec changes only
message-body bytes, below the span and acknowledgement contract.


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`) contains the keiro runtime and its
spec toolchain. Packages touched here: `keiro-dsl` (the `.keiro` toolchain — `Scaffold.hs`
emits generated Haskell, `Harness.hs` emits a generated assertion module, `Validate.hs`
is the checker, `Grammar.hs` the AST; the CLI subcommands are `parse`, `check`,
`scaffold`, `diff`, `new` — `keiro-dsl/app/Main.hs:41-60`), `keiro-pgmq` (typed pgmq job
layer; `Keiro.PGMQ.Codec` defines `JobCodec`, `mkJobCodec`, `aesonJobCodec`,
`keiroJobCodec`), and `keiro-core` (`Keiro.Codec` — the versioned event codec).

Architectural ground truth. keiki (at `/Users/shinzui/Keikaku/bokuno/keiki`) has no
separate decide/evolve — one edge set is both forward stepping and replay; replay
re-inverts each stored event to a command and re-checks the edge guard
(`keiki/src/Keiki/Core.hs:1223-1228`; failures surface as `HydrationNoInvertingEdge` etc.,
`keiro/src/Keiro/Command.hs:457-462`). Upcasters run at decode-time *forever*: hydration
(`keiro/src/Keiro/Command.hs:410`), the workflow journal (`keiro/src/Keiro/Workflow.hs:690`),
and `keiroJobCodec` decode through the chain on every read; no stored-data migration
exists. A wrong upcaster therefore does not corrupt a table once — it corrupts every
future replay's view of the log.

The lowering bug, precisely. `Upcaster = (Int, EventType -> Value -> Either Text Value)`
(`keiro-core/src/Keiro/Codec.hs:65`) — the tag parameter exists *specifically* so
multi-event codecs can migrate by the authoritative wire tag (the haddock at lines 59-64
says so). The scaffolder emits `upcasters = [(m, const upcast<Event>V<m>), …]`
(`upcastersExpr`, `Scaffold.hs:1565-1567`; per-event entries from `upcasterEntries`,
1558-1563; checked-in evidence:
`keiro-dsl/test/conformance-v2/Generated/HospitalCapacity/Reservation/Codec.hs:50` reads
`upcasters = [(1, const upcastTransferReservationCreatedV1)]`). The codec's
`schemaVersion` is the aggregate-global max event version (`maxEventVersion`,
`Scaffold.hs:1550-1552`, emitted at 1539) and is stamped on every appended event of every
kind; per-event `rcVersion` is never stamped anywhere. On decode, `migrateToCurrent`
(`Codec.hs:266-289`) runs every payload stamped m through rung m and all higher rungs. So
in the conformance-v2 vertical, a stored v1 `TransferReservationConfirmed` payload is
piped through `upcastTransferReservationCreatedV1` — today that hole
(`conformance-v2/HospitalCapacity/Reservation/Holes.hs:75-79`) happens to be an
insert-if-absent, which merely plants a junk `triageNote` key on Confirmed payloads; the
verified worst case is two kinds sharing a field name (say `amount`) where one kind's
upcaster renames-and-scales it — the other kind's values are silently rescaled into the
fold. The generated hole stub (`Scaffold.hs:1849-1862`) says only "bring a payload up one
version" — nothing about receiving other kinds. The generated harness "upcast" assertion
(`Harness.hs:405-421`, `upcastDecl`) feeds the declaring event's own *current-shape*
payload tagged at the old version through `decodeRaw` — a wiring proof only; its haddock
admits the grammar records no per-version field delta. That limitation was recorded in
plan 60's outcomes and nowhere else.

The job-codec gap, precisely. `keiroJobCodec` (`keiro-pgmq/src/Keiro/PGMQ/Codec.hs:85-106`)
wraps payloads in `{"v": <schemaVersion>, "t": <event-type>, "data": <payload>}`, replays
the codec's upcaster chain on decode, and returns `JobPayloadFromFuture` (retry, not
dead-letter) when a worker meets a newer envelope — with documented
workers-before-producers deploy ordering (lines 15-20). Switching a *non-empty* queue from
bare payloads to the envelope malformed-dead-letters in-flight messages; the module header
says drain first or use a transitional codec (lines 22-26). The scaffolder currently emits
no `JobCodec` at all: `scaffoldWorkqueue` (`Scaffold.hs:654-668`) generates `Queue.hs`
(payload record + `encode<Payload>`/`parse<Payload>`, deliberately self-contained —
base/text/aeson only) and `QueuePolicy.hs` (retry/ordering/provisioning against the live
`Keiro.PGMQ.Job`); the hand-owned service module then assembles
`jobCodec = mkJobCodec encode<Payload> parse<Payload>` — see the conformance fixtures
`keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs:29-33`
and `keiro-dsl/test/conformance-queue-runtime/Main.hs:40`. (Plan 63's design text spoke of
emitting a literal `JobCodec`; the landed scaffolder stops at the encode/parse pair — the
adoption gap is the same either way and is recorded in plan 63's Coverage Gaps.)

ADR context: `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` fixes the
pgmq job processing telemetry contract — exactly one Consumer-kind `<jobName> process`
span per delivery on both execution paths, with specified attributes and status mapping.
The job-codec change in M3 is payload-level (what bytes go in the pgmq message body); it
must not alter span names, kinds, attributes, or the ack-decision vocabulary. No other
pre-existing ADR constrains the implementation; ADR 0004 is extended during close-out
because it inventories the evolution gates this plan changes.

Ownership boundaries from master plan 24 (Integration Points): this plan owns
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` and `Harness.hs`. Plan 139 owns `Validate.hs` and
the deprecation/upcaster-chain diff rules; plan 138 adds the fold-fingerprint lowering
(one confined edit to `stateCodecExpr`) and a transition-surface diff advisory. This plan
makes exactly one pre-authorized edit outside its files — the `DuplicateUpcasterSource`
relaxation in `Validate.hs`, after plan 139 lands (see Decision Log). Conformance
fixtures regenerate once per landed plan; the 24-suite keiro-dsl green bar (all
`test-suite` stanzas in `keiro-dsl/keiro-dsl.cabal`) is the shared acceptance floor.

Term definitions. "Rung" — one `(sourceVersion, migration)` entry in `upcasters`;
`migrateToCurrent` applies rungs sourceVersion, sourceVersion+1, … in sequence. "Stamp" —
the aggregate-global `schemaVersion` written into event metadata on append. "Hole" — a
typed signature the scaffolder emits into the hand-owned `Holes.hs` module for a human to
fill; the firewall rule is that generated modules never contain behaviour, holes never get
overwritten. "Golden payload" — a checked-in JSON file holding a payload exactly as an old
binary wrote it (path convention owned by plan 139:
`keiro-dsl/test/golden-payloads/<context>/<Aggregate>/<EventName>.v<N>.json`).
"Envelope" — keiroJobCodec's `{"v","t","data"}` wrapper.


## Plan of Work

### Milestone 1 — per-rung dispatch lowering

Scope: the generated codec stops discarding the wire tag. At the end, each rung is a
generated dispatch function; each hole receives only its own kind; foreign kinds pass
through; the stub says so; a regression test proves the corruption is gone; and the
validator matches the new semantics.

Edit `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`. Replace `upcastersExpr` (1565-1567) and extend
`emitCodecValue` (1529-1543): group `upcasterEntries` (1558-1563) by source version m;
for each group emit, into the generated Codec module, a rung function

```haskell
upcastRungV<m> :: EventType -> Value -> Either Text Value
upcastRungV<m> (EventType "<EventA>") v = upcast<EventA>V<m> v
upcastRungV<m> (EventType "<EventB>") v = upcast<EventB>V<m> v
upcastRungV<m> _ v = Right v
```

and lower `upcasters = [(<m>, upcastRungV<m>), …]` with unique, sorted sources. The final
catch-all arm carries a generated comment: "kinds whose shape did not change at
v<m>→v<m+1> pass through unchanged; their stamped version reflects the aggregate-global
schema version, not their own shape history." Hole signatures stay
`Value -> Either Text Value`. Rewrite the stub text in `holeUpcasterStubs` (1849-1862) to
state the contract: "This hole receives ONLY <Event> payloads stored at aggregate schema
version <m>; other event kinds pass through the generated rung dispatch automatically.
Migrate the payload to the v<m+1> shape; reject malformed input with Left." Update
`upcasterImport` (1572-1575) if the emitted names change.

Relax the validator in step (the pre-authorized `Validate.hs` edit; only after plan 139
lands): `DuplicateUpcasterSource` no longer fires when two *different* events declare
`upcast from` the same version — that shape now lowers to one dispatching rung. Keep an
error if the same event is somehow duplicated. Update plan 139's fixture expectation for
`reservation-dup-upcast-source.keiro`: it now passes `check` and must instead be covered
by a conformance-style test proving both upcasters run (see below). Update the guidance
text plan 139 added so it now describes when sharing a source version is appropriate (two
kinds genuinely re-shaped in the same release) versus when a later event should take
aggregate-max+1 (its old payloads span older stamps). Record the semantic in this plan's
Decision Log entry above and in the Surprises section if reality diverges.

Regression test (red-then-green; this is the heart of the milestone). In
`keiro-dsl/test/Main.hs`, add a two-kind corruption test at the codec level: construct (in
test code, mirroring the generated shapes — or scaffold a scratch fixture with two events
sharing a field name where one declares an upcaster that renames/scales that field) and
assert that decoding a stored old-version payload of the *other* kind through the chain
leaves its fields byte-identical. Under the `const` lowering this test fails (the foreign
upcaster transforms it); under the dispatch lowering it passes. Also assert both upcasters
run for their own kinds when two events share a source version.

Regenerate every conformance vertical whose generated Codec carries upcasters (at
authoring time: `conformance-v2`; check every `keiro-dsl-scaffold-record*.txt` for others)
and re-run the full bar. The conformance-v2 `Holes.hs` upcaster keeps its current body —
its insert-if-absent defensiveness is no longer load-bearing, which the regenerated stub
text now explains.

Acceptance: `cabal test keiro-dsl` (all 24 suites) green; the regenerated
`conformance-v2/Generated/HospitalCapacity/Reservation/Codec.hs` shows the dispatch rung;
the corruption test's before/after outputs are captured in Surprises & Discoveries.

### Milestone 2 — harness runs genuine old payloads

Scope: the generated harness's upcast assertions stop feeding current-shape stand-ins and
start decoding checked-in golden payloads; `diff` learns to emit goldens at
version-bump time. At the end, "old payloads still decode" is a CI fact, not a wiring
hope.

Add `--emit-goldens DIR` to the `diff` subcommand (`keiro-dsl/app/Main.hs:54-56` wires the
option; the logic lives beside the differ's entry point — a new small module
`Keiro.Dsl.Goldens` keeps `Diff.hs` inside plan 139's ownership untouched): for each event
whose version bumps between the old and new spec, synthesize the *old* shape from the old
spec — the `kind` discriminator per the wire clause, each old field rendered camelCase,
deterministic placeholder values by category (ids: `<prefix>_` + a fixed ULID-style
suffix; enums: the first declared wire value; `int`: 1; `bool`: true; text: `"sample"`) —
and write `<DIR>/<context>/<Aggregate>/<EventName>.v<oldN>.json` only if the file does not
already exist (hand-captured genuine payloads always win). Print one line per file
written.

Add `--goldens DIR` to the `scaffold` subcommand (default: a `golden-payloads` directory
next to the spec file, if present). `Keiro.Dsl.Harness.harnessFor` gains the golden set:
for each golden matching one of the aggregate's events, `upcastDecl` (405-421) emits — in
place of the current self-feed for that event/version — an assertion that embeds the
golden's JSON as a string literal, parses it at runtime with aeson (the generated harness
already imports the codec's aeson surface), and runs
`decodeRaw <agg>Codec (EventType "<Event>") <N>` over it, labelled
`"golden <Event>.v<N> decodes"`. When no golden exists for a declared upcast, keep the
current-shape wiring assertion but relabel it `"upcast <Event> chain wired
(current-shape stand-in; add a golden payload)"` so the weaker proof is visible in
harness output. Embedding at scaffold time keeps generated modules self-contained (no
runtime file IO, no path coupling); the checked-in golden remains the source of truth and
regeneration re-embeds it.

Create the golden for the existing vertical by hand if plan 139 has not already landed it
(same file, same content — coordinate by path:
`keiro-dsl/test/golden-payloads/hospital-capacity/Reservation/TransferReservationCreated.v1.json`,
the v1 shape without `triageNote`). Re-scaffold conformance-v2 with `--goldens
keiro-dsl/test/golden-payloads/hospital-capacity` wired the way the record file captures
(update `keiro-dsl-scaffold-record.hospital-capacity.txt` accordingly so future
regenerations reproduce it).

Tests: a unit test for the synthesizer (old spec + new spec → expected JSON text, byte
equality); a harness-emission test asserting the generated text embeds the golden and
labels the stand-in honestly; the conformance-v2 suite now prints
`PASS  golden TransferReservationCreated.v1 decodes`. Mutation check: edit the golden to
an impossible shape (e.g. rename `reservationId`), re-run conformance-v2, watch the
harness assertion fail, revert.

Acceptance: `cabal test keiro-dsl` green; `cabal run -v0 keiro-dsl -- diff <spec> --since
HEAD --emit-goldens <dir>` writes a file for a version-bumping spec change and writes
nothing for a no-bump change.

### Milestone 3 — keiroJobCodec-backed generated queue codecs

Scope: scaffolded workqueue verticals become versioned from birth. At the end, the
generated layer exposes a ready-made `JobCodec` built on the envelope, the conformance
services use it, and the migration story for existing queues is written where users will
see it.

Extend `scaffoldWorkqueue` (`Scaffold.hs:654-668`) with a third emitted module,
`<genPrefix>/QueueCodec.hs` (Generated kind, same origin), compiled against the live
runtime like `QueuePolicy.hs` is:

```haskell
module <genPrefix>.QueueCodec (<stem>PayloadCodec, <stem>JobCodec) where

import Data.List.NonEmpty (NonEmpty (..))
import Keiro.Codec (Codec (..), EventType (..))
import Keiro.PGMQ.Codec (JobCodec, keiroJobCodec)
import <genPrefix>.Queue (<Payload>, encode<Payload>, parse<Payload>)

<stem>PayloadCodec :: Codec <Payload>
<stem>PayloadCodec =
  Codec
    { eventTypes = EventType "<Payload>" :| []
    , eventType = \_ -> EventType "<Payload>"
    , schemaVersion = 1
    , encode = encode<Payload>
    , decode = \_ -> parse<Payload>
    , upcasters = []
    }

<stem>JobCodec :: JobCodec <Payload>
<stem>JobCodec = keiroJobCodec <stem>PayloadCodec
```

with a generated module header that carries the operational contract verbatim: versioned
`{"v","t","data"}` envelope; when the schema version is ever raised, deploy upgraded
workers before upgraded producers (`JobPayloadFromFuture` retries cover the rolling
window — size `maxRetries * defaultRetryDelay` to cover it); and NEVER switch a non-empty
existing queue from a bare-payload codec to this one — drain it first or run a
transitional codec, otherwise in-flight messages are malformed and dead-lettered
(condensed from `keiro-pgmq/src/Keiro/PGMQ/Codec.hs:15-26`). Note in the header that this
change is telemetry-neutral: span names, kinds, attributes, and ack vocabulary are fixed
by `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` and the codec sits
strictly below them. The schema version 1 / empty upcasters shape is mkCodec-clean, which
matters because plan 139's boundary check validates event codecs and future reuse of
`<stem>PayloadCodec` must not trip it.

Migrate the conformance fixtures: the hand-owned
`conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs` and
`conformance-queue-runtime/Main.hs` switch from `mkJobCodec encode… parse…` to importing
`<stem>JobCodec` from the generated module; register the new generated module in the
relevant `test-suite` stanzas of `keiro-dsl/keiro-dsl.cabal` (`other-modules`). These
existing suites do not provision a database. Instead, pin the exact runtime
boundary: `Keiro.PGMQ.Job.enqueue` writes
`MessageBody (encodeJob job.jobCodec p)` without another transform and the
consumer paths call `decodeJob` on that payload. The queue conformance suite
must assert the exact `{"v":1,"t":…,"data":…}` `Value` and its decode round
trip, while the queue-runtime and dispatch-full suites compile the generated
codec into live `Job` values.

CHANGELOG entry (repo `CHANGELOG.md`, Unreleased): scaffolded workqueues now emit
versioned job codecs; existing services that adopt the generated `QueueCodec` module on a
queue with in-flight bare payloads MUST drain first (link the module docs); fresh queues
need nothing.

Acceptance: `cabal test keiro-dsl-conformance-queue-runtime` and
`cabal test keiro-dsl-conformance-dispatch-full` green; the queue conformance
pins the exact PGMQ message body; full 24-suite bar green; grep of the
regenerated fixtures shows no remaining `mkJobCodec` use in workqueue service wiring.

Close-out: tick master plan 24's EP-3 progress box and registry row; record the
externally visible contracts (dispatch rung semantics, golden convention consumption,
generated QueueCodec shape and its drain-first rule) in this Decision Log for plan 141 to
quote; run the ADR distillation pass (the dispatch-lowering contract is a candidate row
in the evolution-gate inventory ADR; ADR-0001 needs no change — confirm and say so in
Outcomes).


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
# M1
cabal build keiro-dsl
cabal test keiro-dsl-test                       # includes the new corruption regression
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation-v2.keiro \
  --out keiro-dsl/test/conformance-v2
git diff --stat keiro-dsl/test/conformance-v2   # Codec.hs + Holes stub text only
cabal test keiro-dsl                            # all 24 suites

# M2
cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/reservation-v2.keiro \
  --since HEAD --emit-goldens keiro-dsl/test/golden-payloads
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation-v2.keiro \
  --out keiro-dsl/test/conformance-v2 \
  --goldens keiro-dsl/test/golden-payloads/hospital-capacity
cabal test keiro-dsl-conformance-v2

# M3
cabal test keiro-dsl-conformance-queue
cabal test keiro-dsl-conformance-queue-runtime
cabal test keiro-dsl-conformance-dispatch-full
cabal test keiro-dsl                            # full bar again
```

Expected shapes: the M1 scaffold re-run leaves a `git diff` showing `upcastRungV1` in the
generated Codec and the new stub paragraph in `Holes`-stub emission (the checked-in
hand-owned Holes.hs itself does not change — only future stubs do); conformance-v2 output
gains `PASS  golden TransferReservationCreated.v1 decodes`; the queue suite
asserts the exact enveloped body and its decode round trip.

Red-then-green: run the M1 corruption test before changing `upcastersExpr` and paste its
failure into Surprises & Discoveries; likewise run the conformance-v2 golden assertion
against the old harness emission (it does not exist yet — the absence of the label is the
"red") and after M2 show the label present.


## Validation and Acceptance

(1) Corruption regression: with two event kinds sharing a field name and one kind's
upcaster transforming that field, decoding the *other* kind's old-stamped payload yields
byte-identical fields — fails before M1, passes after. (2) Same-release double bump: two
events declaring `upcast from` the same version each get their own transformation applied
(both assertions green) and `check` accepts the spec after the coordinated relaxation.
(3) The generated stub text contains the sentence "receives ONLY <Event> payloads"; the
generated rung contains the pass-through arm with its comment. (4) `diff --emit-goldens`
writes exactly one file for the v1→v2 reservation evolution, with the old shape (no
`triageNote`), and re-running it writes nothing (file exists). (5) The conformance-v2
harness prints the golden PASS line; corrupting the golden fails the suite. (6) The
queue conformance suite pins the exact `{"v":1,"t":…,"data":…}` body and its decode
round trip at the `JobCodec` boundary, while the runtime/dispatch fixtures compile that
codec into live `Job` values; no scaffolded or fixture code still assembles `mkJobCodec`
for a workqueue service. (7) The full 24-suite keiro-dsl bar is green
(`cabal test keiro-dsl`).


## Idempotence and Recovery

Scaffolding is idempotent over `@generated` files and never touches hand-owned holes;
re-running every command above is safe. `--emit-goldens` never overwrites, so re-runs are
no-ops; deleting a bad synthesized golden and re-running regenerates it. The M1 validator
relaxation must land in the same commit as the lowering change (an intermediate state
where the validator allows shapes the lowering mishandles, or vice versa, is the one
sequencing hazard — see plan 139's landing-order decision; if this plan somehow lands
first, keep `DuplicateUpcasterSource` strict until the dispatch lowering is in). M3 is
purely additive for existing deployments — the generated `QueueCodec` module is new and
unused until a service imports it; the drain-first rule applies only at adoption time and
is documented at the adoption site. Rolling back M3 in a service that already enqueued
enveloped messages requires the same drain-first care in reverse; say so in the CHANGELOG
entry.


## Interfaces and Dependencies

At the end of M1, generated Codec modules contain per-rung dispatchers
`upcastRungV<m> :: EventType -> Value -> Either Text Value` wired as
`upcasters = [(<m>, upcastRungV<m>), …]`; hole signatures remain
`Value -> Either Text Value`. At the end of M2, the CLI accepts
`diff … --emit-goldens DIR` and `scaffold … --goldens DIR`, and
`Keiro.Dsl.Goldens` exposes the synthesizer used by both. At the end of M3, scaffolded
workqueues emit `<genPrefix>.QueueCodec` with
`<stem>PayloadCodec :: Keiro.Codec.Codec <Payload>` and
`<stem>JobCodec :: Keiro.PGMQ.Codec.JobCodec <Payload>` built via `keiroJobCodec`.

Dependencies: no new packages (the harness embeds goldens as literals; the synthesizer
writes plain files). Coordination: plan 139 (golden path convention — its Decision Log
owns the format; the `DuplicateUpcasterSource` relaxation — pre-authorized there, executed
here after it lands; this plan's regenerated codecs must pass its boundary `mkCodec`
check, which the merged unique-source rungs do); plan 138 (disjoint `stateCodecExpr`
edit in the same file — rebase carefully, do not reformat neighbours). ADR:
`docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` constrains M3 to
payload-level changes only. Companion guide:
`docs/guides/evolution-and-replayability.md` describes the payload-evolution procedure
these gates enforce; plan 141 owns all user-doc edits.


---

Revision note (2026-07-23, implementation close-out): Completed all three milestones
after auditing the hurried partial implementation. The audit corrected the generated
queue-codec symbol and fresh-skeleton fixture, replaced an inaccurate database-test claim
with the exact `JobCodec` boundary proof, and validated the result with all 24 DSL suites,
CLI golden idempotence, and a deliberate golden-mutation failure. ADR 0004 records the
durable dispatch, golden, and queue-codec contracts.
