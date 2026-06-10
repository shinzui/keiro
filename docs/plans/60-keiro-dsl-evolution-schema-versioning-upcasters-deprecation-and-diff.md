---
id: 60
slug: keiro-dsl-evolution-schema-versioning-upcasters-deprecation-and-diff
title: "keiro-dsl evolution: schema versioning, upcasters, deprecation and diff"
kind: exec-plan
created_at: 2026-06-10T01:05:27Z
intention: "intention_01ktqdn85xe2btqzr2zghxgrpr"
master_plan: "docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md"
---

# keiro-dsl evolution: schema versioning, upcasters, deprecation and diff

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A keiro **service** is a bounded context built on event sourcing: its state is rebuilt by
replaying a log of **events** that were serialized to JSON and stored. Once an event shape
is in the log it is permanent — old payloads stay on disk forever — so changing an event
("add a field", "rename it", "drop it from the write path") is the single most dangerous
edit a service can make. Get it wrong and replay silently fails, or worse, decodes a stale
payload into the wrong value. keiro already has the runtime machinery to do this safely —
`Keiro.Codec` carries a `schemaVersion` and a chain of `upcasters` (pure functions that
rewrite an old payload into the next version's shape) — but nothing today tells an author
*when* a spec edit requires one, and nothing stops a breaking change from merging.

This ExecPlan, EP-2 of the `keiro-dsl` initiative, makes the `.kdsl` spec file a
**lifecycle source of truth** for event evolution. A `.kdsl` file is a typed, terse
specification of a keiro service (the full toolchain is built by EP-1 Foundations,
`docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`,
which this plan hard-depends on and whose engine signatures are restated below). After this
work, an author can:

1. Express a new event schema version directly in the spec —
   `event TransferReservationCreated v2 { … } upcast from v1 = HOLE` — declaring that v2 is
   the current write shape and that a v1-on-disk payload is brought forward by an
   **upcaster** whose body is a typed, harness-checked hole (the scaffolder emits the
   upcaster's *type signature*, never its logic, consistent with the project's scope
   decision that the tool never emits behavior-bearing code).
2. Mark a retired shape `deprecated event …` — removed from the write path but still
   decodable from the log.
3. Run `keiro-dsl check` and have the validator *reject* a spec that added a field to an
   event without bumping its version and supplying an upcaster, or removed an event without
   deprecating it, or declared a v2 with no upcaster hole — **before any Haskell is written**.
4. Run `keiro-dsl diff --since <git-ref>` and get every node-by-node spec change classified
   as **ADDITIVE** (safe — no on-disk payload can fail to decode) or **BREAKING** (an
   existing payload could now fail to decode and needs an upcaster or a deprecation). The
   command **exits non-zero on any unguarded breaking change**, so it can gate a merge.

The user-visible proof (the acceptance this plan is built around): start from a spec whose
`TransferReservationCreated` event is at v1. Add a field to it *without* bumping the version
or adding an upcaster, and `keiro-dsl diff --since HEAD` reports that change as BREAKING and
exits non-zero. Now wrap the same field-add as a v2 with an `upcast from v1 = HOLE` clause,
and the same command reports it ADDITIVE and exits zero. The scaffolder then emits a
`Keiro.Codec` whose `schemaVersion = 2` and `upcasters = [(1, upcastTransferReservationCreatedV1)]`,
with `upcastTransferReservationCreatedV1 :: Value -> Either Text Value` left as a typed hole
in a hand-owned module, and a golden round-trip harness test proving a v1 wire payload
decodes through that upcaster into the current value.

**Out of scope, stated explicitly:** read-model table migrations (the SQL that reshapes a
projection's Postgres table) are delegated to `codd` — already a keiro dependency, the
migration tool keiro uses — and are **not** handled here. This plan is exclusively about
*event payload* evolution (the `Keiro.Codec` schema-version/upcaster surface). It is a
**soft input** to the four node verticals (EP-3…EP-6,
`docs/plans/61-…`/`62-…`/`63-…`/`64-…`): each may attach version/upcast constructs to its
own events, so the grammar additions here are kept general — *any* event in *any* node can
be versioned, not just aggregate events.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

M1 — grammar + parser + validator for evolution constructs: **DONE 2026-06-10**

- [x] Extend `Keiro.Dsl.Grammar` `Event` with version fields (`evVersion :: Int`,
      `evUpcastFrom :: Maybe (Int, Hole)`, `evDeprecated :: Bool`) and a `Hole` placeholder. (2026-06-10)
- [x] Extend `Keiro.Dsl.Parser` to accept `event Name vN { … }` + `upcast from vM = HOLE` and
      `deprecated event Name …`; unversioned events default to `evVersion = 1`. (2026-06-10)
- [x] Extend `Keiro.Dsl.PrettyPrint` to render the new clauses; `parse . pretty == id` still
      holds (generator extended with version/upcaster/deprecated). (2026-06-10)
- [x] Add validator rules (`EvtVersionMissingUpcaster`, `DeprecatedEventStillEmitted`,
      `WireSchemaVersionMismatch`; plus `EvtFieldAddedWithoutBump`/`EvtRemovedNotDeprecated`
      registered for the diff path). (2026-06-10)
- [x] `keiro-dsl check` passes `reservation-v2.kdsl` (exit 0) and fails
      `reservation-v2-noupcast.kdsl` with `error[EvtVersionMissingUpcaster]` on the v2 line
      (exit 1). (2026-06-10)

M2 — `Keiro.Dsl.Diff` engine + `diff --since` CLI: **DONE 2026-06-10**

- [x] Write `Keiro.Dsl.Diff` exposing `diffSpecs :: Spec -> Spec -> [Change]` with
      `Change = Additive ChangeKind | Breaking ChangeKind` (`ckCode :: Maybe DiagnosticCode`). (2026-06-10)
- [x] Implement the additive-vs-breaking classifier (new event type → Additive; new version +
      contiguous upcaster → Additive; field added/removed at same version → Breaking; event
      removed-not-deprecated / aggregate removed → Breaking; deprecation → Additive). (2026-06-10)
- [x] Add the `diff --since <git-ref>` subcommand: `git rev-parse --show-toplevel` +
      `git show <ref>:<relpath>` → parse old → `diffSpecs old new` → print ADDITIVE/BREAKING →
      exit non-zero on any Breaking. (2026-06-10)
- [x] Unit tests over fixture pairs (field-add → Breaking; v2+upcaster → Additive; no-change →
      none) + `keiro-dsl/test/diff-test.sh` git-integration gate. (2026-06-10)

M3 — scaffold the `Codec` schemaVersion+upcaster wiring + harness: **DONE 2026-06-10**

- [x] `Keiro.Dsl.Scaffold`: the emitted `Keiro.Codec` derives `schemaVersion` from the max
      event version and `upcasters = [(m, upcast<Event>V<m>)]` from the `upcast from`
      clauses; the Codec imports the upcaster holes from the Holes module. Symbol-free
      (firewall holds). (2026-06-10)
- [x] Emit the upcaster signature `upcast<Event>V<m> :: Value -> Either Text Value` as a
      typed `HoleStub` (stub body `Left "HOLE: …"`); never the body. (2026-06-10)
- [x] `Keiro.Dsl.Harness`: emit a per-upcaster wiring-proof assertion — a source-version
      payload fed through `decodeRaw codec m …` runs the upcaster chain then decodes; red
      while the hole returns `Left`, green once filled. (See Surprises for why this proves
      wiring rather than re-deriving the exact old payload.) (2026-06-10)
- [x] Conformance: `keiro-dsl-conformance-v2` scaffolds `reservation-v2.kdsl`, the
      `Generated` modules (codec `schemaVersion = 2`, `upcasters = [(1, …)]`) compile against
      keiki/keiro, the firewall holds, and with the upcaster filled the harness is 6/6 green;
      reverting the upcaster to the hole turns the `upcaster wired` assertion red. (2026-06-10)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **M2: `git rev-parse --show-toplevel` is symlink-resolved but `makeAbsolute` is not.** On
  macOS `/tmp` is a symlink to `/private/tmp`; git returned `/private/tmp/evo-demo` while
  `makeAbsolute "/tmp/evo-demo/svc.kdsl"` kept `/tmp/…`, so `makeRelative` found no common
  prefix and left the path absolute — `git show HEAD:/tmp/…/svc.kdsl` then failed with
  "exists on disk, but not in 'HEAD'". Fix: use `canonicalizePath` (resolves symlinks) so
  both paths agree, yielding the repo-relative `svc.kdsl`.

- **M3: the grammar records only the current event shape, not the per-version field delta.**
  A `v2` event lists its full v2 field set; what was *added* at v2 (vs. v1) is not captured.
  So a generic harness cannot reconstruct a faithful v1-on-disk payload to round-trip. The
  emitted harness therefore proves the upcaster *chain is wired and must be filled* — it
  feeds a source-version-tagged payload through `decodeRaw codec m …` (which runs the
  upcaster then decodes) and asserts success; the hole's `Left` makes it red, a filled
  upcaster makes it green. Evidence: `keiro-dsl-conformance-v2` is 6/6 green with the
  upcaster filled; reverting it to the `Left "HOLE: …"` stub turns exactly the
  `upcaster wired` assertion red.

- **M3: a v2-added event field has no command source, so the transducer emits it as a
  literal.** `triageNote` was added to the `TransferReservationCreated` v2 event but not to
  the `RequestTransferReservation` command, so the hand-filled transducer supplies it with
  `triageNote = lit ""` in the emit's `TermFields`. This is the kind of behaviour the spec
  cannot derive — squarely a hole — and the upcaster mirrors it by defaulting `triageNote`
  on old payloads that lack the key.


## Decision Log

Record every decision made while working on the plan.

- Decision: The upcaster *body* is a typed hole, not generated code; the scaffolder emits
  only the upcaster's type signature (`…V<n> :: Value -> Either Text Value`) and wires it
  into the `Keiro.Codec` `upcasters` list.
  Rationale: This is the project-wide scope decision (carried from
  `docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md` and EP-1) applied to
  evolution: an upcaster is behavior-bearing (it may default a new field, rename a key, do
  per-status string surgery — see `upcastOrderPlacedV1` in
  `jitsurei/src/Jitsurei/OrderStream.hs`, which defaults a missing `sku` to `"UNKNOWN"` and
  reads an old `qty` key as `quantity`). Behavior-bearing logic is exactly the
  agent-written, harness-checked hole; the spec cannot derive it deterministically. The
  harness (a golden round-trip per version) is what pins it.
  Date: 2026-06-10

- Decision: `diff --since` reads the prior spec via `git show <ref>:<path>`, not a stored
  snapshot or a database.
  Rationale: git is already available in the repo and is the authoritative history of the
  spec file. Reading the blob at a ref is hermetic, needs no extra state, and lets the
  command diff against any commit/tag/branch the user names. The spec file path is known
  (the file passed on the command line, made repo-relative).
  Date: 2026-06-10

- Decision: The classification axis is *decode safety of on-disk payloads*, not source
  compatibility. ADDITIVE = no payload already in the log can fail to decode under the new
  spec; BREAKING = some existing payload could now fail to decode (or be silently
  misread) and needs an upcaster or a deprecation to remain safe.
  Rationale: event sourcing makes the log permanent; the only thing that actually breaks is
  reading old data. Framing the diff around `Keiro.Codec`'s decode path (which defaults a
  missing schema-version stamp to `1` and migrates forward — see
  `keiro-core/src/Keiro/Codec.hs:160-181`, `220-225`) keeps the classifier faithful to the
  runtime it gates.
  Date: 2026-06-10

- Decision: Read-model table migrations are out of scope and delegated to `codd`.
  Rationale: `codd` is already a keiro dependency and the established tool for Postgres
  schema migrations; reshaping a projection's table is a SQL concern orthogonal to event
  payload evolution. Conflating the two would put DDL generation in a tool whose firewall
  invariant forbids emitting behavior-bearing code. This plan handles only the
  `Keiro.Codec` (event payload) surface.
  Date: 2026-06-10

- Decision: Versioning lives on the `Grammar` `Event` node generally (not in an
  aggregate-specific type), so EP-3…EP-6 events can reuse it unchanged.
  Rationale: the MasterPlan marks EP-2 a *soft input* to the verticals — each may carry
  versioned events. Putting `version`/`upcastFrom`/`deprecated` on the shared `Event`
  constructor (defined by EP-1) means a vertical that emits a `Codec` gets the
  schema-version/upcaster wiring for free, and `diffSpecs` works across all node kinds.
  Date: 2026-06-10

- Decision: An unversioned `event …` declaration is `version = 1` implicitly; you only
  write `vN` when N > 1. The codec's `schemaVersion` is the maximum declared version across
  that event's family.
  Rationale: keeps the canonical EP-1 surface (`event TransferReservationCreated = fields(…)`)
  valid and unchanged, matching `Keiro.Codec`'s default-to-1 read behavior
  (`keiro-core/src/Keiro/Codec.hs:220-225`) and the real corpus where unversioned streams
  run at `schemaVersion = 1` (hospital-capacity Reservation) and an evolved one runs at
  `schemaVersion = 2` (`jitsurei/src/Jitsurei/OrderStream.hs:134`).
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**EP-2 complete (2026-06-10).** The `.kdsl` spec is now a lifecycle source of truth for
event-payload evolution. Against the original purpose: an author can declare
`event … vN { … } upcast from v(N-1) = HOLE` and `deprecated event …`; `keiro-dsl check`
rejects a `vN>1` without a contiguous upcaster; `keiro-dsl diff --since <ref>` classifies
each change ADDITIVE/BREAKING against the prior git blob and exits non-zero on any
unguarded breaking change (the headline gate); and `scaffold` lowers the constructs to a
`Keiro.Codec` with `schemaVersion = max event version` and
`upcasters = [(m, upcast<Event>V<m>)]`, the upcaster bodies left as typed holes and pinned
by a harness. The firewall invariant still holds (the codec/upcaster wiring contains no
keiki symbolic operator). The versioning fields live on the shared `Grammar.Event`, so
EP-3…EP-6 events inherit evolution for free.

**Scope honoured:** read-model table migrations remain delegated to `codd`; only the event
payload (`Keiro.Codec`) surface is handled here. **Limitation recorded (see Surprises):**
the grammar captures only the current event shape, so the harness proves the upcaster chain
is wired and must be filled rather than re-deriving the exact old payload — sufficient to
make a wrong/empty upcaster fail loudly. Two contract refinements: `parseSpec` keeps the
`FilePath` source-name form, and `diff --since` canonicalizes paths to match git's
symlink-resolved toplevel.


## Context and Orientation

Read this fully before touching code; it assumes no prior knowledge of keiro or the DSL.

### Terms of art

- **Event sourcing.** A service's state is not stored directly; instead an append-only log
  of **events** (facts that happened) is stored, and state is rebuilt by replaying them.
- **Event payload.** The JSON blob a single event serializes to on disk. Permanent: once
  written it is never rewritten.
- **Codec.** The one place a stream declares how its events are named, serialized, and
  migrated. In this repo it is `Keiro.Codec.Codec`
  (`keiro-core/src/Keiro/Codec.hs`). It carries a `schemaVersion :: Int` (the current
  payload version, stamped into event metadata on write) and `upcasters :: [Upcaster]`.
- **Upcaster.** One rung of a migration chain. Its type is
  `type Upcaster = (Int, Value -> Either Text Value)` — a source version paired with a pure
  function that rewrites a version-`n` JSON payload into the version-`(n+1)` shape, or
  rejects it with `Left`. Defined at `keiro-core/src/Keiro/Codec.hs:54-59`.
- **`.kdsl` file / spec.** A terse, typed text description of a keiro service, parsed by the
  toolchain into a `Keiro.Dsl.Grammar.Spec` value. `#` begins a comment; `!` after a state
  name marks it terminal; `HOLE` names an unfilled hole.
- **Hole.** A part of the spec the tool deliberately does not derive — a typed placeholder a
  human or coding agent fills, whose behavior the **harness** (generated tests) then pins.
  EP-2 introduces one new hole occupant: the upcaster body.
- **`-- @generated` module.** A scaffolded Haskell module the tool fully overwrites on each
  run. **Firewall invariant (project-wide):** no `-- @generated` line ever contains a keiki
  symbolic operator (`./=`, `.==`, `.||`, `lit`, `B.slot @"…" =:`, `B.requireGuard`); those
  live only in hand-owned, harness-checked modules. This plan adds nothing that violates it
  (a `Codec`/`upcasters` list contains no symbolic operators).
- **ADDITIVE vs BREAKING.** A spec change is ADDITIVE when no event payload already in the
  log can fail to decode under the new spec, and BREAKING when some existing payload could
  now fail to decode (or be silently misread). This is the axis `diff --since` classifies on.

### How `Keiro.Codec` migrates a stored event (the runtime this plan gates)

The decode path is the behavior the evolution constructs lower to. From
`keiro-core/src/Keiro/Codec.hs`:

- `data Codec e = Codec { eventTypes, eventType, schemaVersion :: !Int, encode, decode,
  upcasters :: ![Upcaster] }` — lines 77-84.
- `encodeForAppendWithMetadata` stamps `schemaVersion` into event metadata under the
  `schemaVersion` key (lines 129-144, `metadataFor` at 151-158).
- `decodeRecorded` reads the stamped version back — **defaulting to `1` when the stamp is
  absent** (`extractSchemaVersion`, lines 220-225) — then calls `decodeRaw`.
- `decodeRaw` runs `migrateToCurrent` then the current `decode` (lines 176-181).
- `migrateToCurrent` (lines 192-214) replays the upcaster chain from the stored version up
  to `schemaVersion`: a payload already at/above current is returned unchanged; a missing
  rung is `GapInUpcasterChain`; an upcaster's `Left` is `UpcasterError`; a source version
  `< 1` is `UnknownVersion`.

The consequence for classification: **adding a required field to the current event shape
without an upcaster is BREAKING** — an old payload lacking that field reaches the current
`decode`, which fails (`DecodeFailed`). Bumping the version and supplying an upcaster that
fills the field makes the old payload migrate forward first, so it decodes — ADDITIVE.

### A real evolved stream (the model to reproduce)

`jitsurei/src/Jitsurei/OrderStream.hs` is an in-repo aggregate that has *already been
evolved*. Its `orderCodec` declares `schemaVersion = 2` (line 134) and
`upcasters = [(1, upcastOrderPlacedV1)]` (line 168). The upcaster
`upcastOrderPlacedV1 :: Value -> Either Text Value` (lines 211-228) is the canonical example
of behavior-bearing migration logic: it reads an old `qty` key as the new `quantity`, and
**defaults a missing `sku` to `"UNKNOWN"`**. This is exactly the kind of decision the spec
cannot derive — which is why the upcaster body is a hole and `OrderStream.hs`'s shape is the
target the scaffolder + harness reproduce. By contrast,
`keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/Reservation/EventStream.hs`
is an *un*-evolved stream: `schemaVersion = 1`, `upcasters = []` (lines 63, 66). These two
bracket the before/after this plan must handle.

### What EP-1 Foundations gives us (restated; this plan extends it)

EP-1 (`docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`)
builds the package `keiro-dsl/` (module namespace `Keiro.Dsl.*`, `GHC2024`, deps
`megaparsec`/`optparse-applicative`/`prettyprinter`/`parser-combinators`), wired into
`/Users/shinzui/Keikaku/bokuno/keiro/cabal.project`. The shared engine this plan extends —
restated with the exact signatures EP-2 relies on:

- `Keiro.Dsl.Grammar` — the AST. Defines the shared declarations (`IdDecl`, `EnumDecl`,
  `RuleDecl`, the hole types, the `Expr` sublanguage) and the `Aggregate` node, which
  contains a list of `Event` declarations plus `RegDecl`, `Command`,
  `Transition { guard :: Maybe Expr, writes :: [(Name, Expr)], emits :: [Name], goto :: Name }`,
  `WireSpec` (carrying `schemaVersion`), and `ProjectionSpec`. The top-level `Spec` aggregates
  the context name, declarations, and node list. Every node carries a source line number.
  **EP-2 extends the `Event` constructor with version fields.**
- `Keiro.Dsl.Parser` — `parseSpec :: Text -> Either ParseError Spec` (megaparsec).
- `Keiro.Dsl.PrettyPrint` — `renderSpec :: Spec -> Text`, with `parseSpec (renderSpec s) == Right s`.
- `Keiro.Dsl.Validate` — `validateSpec :: Spec -> [Diagnostic]` (empty list = valid), where
  `Diagnostic { line :: Int, severity :: Severity, code :: DiagnosticCode, message :: Text }`,
  `Severity = Error | Warning`, and `DiagnosticCode` is an enum naming each rule (tests match
  on the code, not the prose). **EP-2 adds new `DiagnosticCode`s.**
- `Keiro.Dsl.Scaffold` — `scaffoldAggregate :: Context -> Aggregate -> [ScaffoldModule]` where
  `data ScaffoldModule = ScaffoldModule { modulePath :: FilePath, moduleText :: Text, kind :: ModuleKind }`
  and `data ModuleKind = Generated {- @generated, overwrite -} | HoleStub {- create-if-absent -}`.
  It emits the symbol-free deterministic layer, including the `Keiro.Codec` value, into
  `Generated` modules, and typed holes into `HoleStub` modules. **EP-2 extends the emitted
  `Codec` to carry `schemaVersion`/`upcasters`, and adds an upcaster-signature `HoleStub`.**
- `Keiro.Dsl.Harness` — `harnessFor :: Context -> Aggregate -> [ScaffoldModule]` emitting test
  modules (`validateTransducer` + golden wire fixtures + clock-free assertion). **EP-2 adds a
  per-version golden round-trip test.**
- The CLI (`keiro-dsl/app/Main.hs`, optparse-applicative) owns `parse`/`check`/`scaffold`.
  **EP-2 adds the `diff` subcommand.**

### The canonical aggregate surface (the spec the parser already accepts)

EP-1's parser round-trips this notation. EP-2 adds the version/deprecation clauses to the
`event` lines only; everything else is unchanged.

```text
context hospital-capacity

id  TransferReservationId  prefix=rsv
id  HospitalId             prefix=hosp
id  CommandId              prefix=cmd

enum DivertStatus  { Open=open PartialDivert=partial-divert TotalDivert=total-divert }

aggregate Reservation
  regs
    reservationState ReservationVertex     = Unrequested
  states Unrequested Held Confirmed Expired! Admitted! Released!

  command RequestTransferReservation { reservationId hospitalId commandId patientAcuity divertStatus lifeCriticalOverride:Bool }
  command ConfirmReservation         { reservationId hospitalId commandId }

  event TransferReservationCreated   = fields(RequestTransferReservation)
  event TransferReservationConfirmed { reservationId hospitalId commandId }

  Unrequested -- RequestTransferReservation -->
    guard divertStatus != TotalDivert || lifeCriticalOverride
    write reservationState := Held
    emit  TransferReservationCreated
    goto  Held
  Held -- ConfirmReservation --> write reservationState := Confirmed ; emit TransferReservationConfirmed ; goto Confirmed

  wire kind=ctorName fields=camelCase schemaVersion=1
  projection transfer_decisions consistency=Strong key=reservationId
    status-map { Created=>held Confirmed=>confirmed }
```

### The new evolution surface (what EP-2 adds to the grammar)

Two new constructs, both attached to `event` declarations. A versioned event names its
version with `vN` (N > 1; unversioned means v1) and supplies an upcaster hole from each
prior version:

```text
  # v2 adds a field; an upcaster brings v1 payloads forward.
  event TransferReservationCreated v2 { reservationId hospitalId commandId patientAcuity divertStatus lifeCriticalOverride:Bool triageNote:Text }
    upcast from v1 = HOLE
```

A retired shape is marked `deprecated` — it leaves the write path (no transition may `emit`
it) but stays in the codec's `eventTypes` so old payloads still decode:

```text
  deprecated event LegacyReservationOpened { reservationId hospitalId }
```

### Where the new code goes

All new code is inside the existing `keiro-dsl` package
(`/Users/shinzui/Keikaku/bokuno/keiro/keiro-dsl/`):

- `keiro-dsl/src/Keiro/Dsl/Grammar.hs` — extend the `Event` record (additive fields).
- `keiro-dsl/src/Keiro/Dsl/Parser.hs` — add the `vN`/`upcast from`/`deprecated` clauses.
- `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` — render them.
- `keiro-dsl/src/Keiro/Dsl/Validate.hs` — new evolution `DiagnosticCode`s.
- `keiro-dsl/src/Keiro/Dsl/Diff.hs` — **new module**, `diffSpecs`.
- `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` — extend `Codec` emission + upcaster `HoleStub`.
- `keiro-dsl/src/Keiro/Dsl/Harness.hs` — per-version golden round-trip test.
- `keiro-dsl/app/Main.hs` — the `diff` subcommand.
- `keiro-dsl/test/fixtures/` — new `.kdsl` fixtures for the diff cases.


## Plan of Work

The work proceeds in three milestones, each independently verifiable and each ending in a
runnable artifact. M1 makes the spec *express* evolution and the validator *enforce* it. M2
makes the tool *detect* unguarded breaking changes across git history. M3 makes the
scaffolder *lower* the constructs to a real `Keiro.Codec` and the harness *prove* the
round-trip. M2 is the milestone that delivers the headline acceptance.

### Milestone 1 — grammar, parser, and validator for versioning/deprecation

Scope: extend the shared grammar so an event can declare a version and an upcaster hole, or
be deprecated; teach the parser and pretty-printer the new clauses; and add validator rules
that reject the dangerous-by-omission cases before any diff or scaffold. At the end the
`.kdsl` language has evolution constructs and `keiro-dsl check` enforces their consistency.

Work, file by file:

- `keiro-dsl/src/Keiro/Dsl/Grammar.hs`: extend the `Event` record (defined by EP-1) with
  three additive fields — `version :: Int` (default 1), `upcastFrom :: Maybe (Int, Hole)`
  (the source version this version migrates *from*, paired with the upcaster hole), and
  `deprecated :: Bool`. Add a `data Hole = Hole | Filled Text` marker if EP-1 has not
  already introduced one (EP-1 uses `HOLE` in the surface; reuse its representation if
  present, otherwise add this minimal one). Keep these on the shared `Event` constructor so
  EP-3…EP-6 events inherit them.
- `keiro-dsl/src/Keiro/Dsl/Parser.hs`: in the `event` parser, accept an optional `vN`
  immediately after the event name (parse `N` as the `version`; absence means 1). After the
  field block, accept an optional `upcast from vM = HOLE` clause, setting
  `upcastFrom = Just (M, Hole)`. Add a leading `deprecated` keyword to the `event` parser
  that sets `deprecated = True`. Reject `v1` written explicitly with a parse error suggestion
  to omit it (keeps one canonical form), or accept it and normalize — choose accept+normalize
  to keep the round-trip total; record the choice in the Decision Log when implementing.
- `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`: render `vN` (only when N > 1), the `upcast from
  vM = HOLE` clause on its own indented line, and the `deprecated` prefix. Extend the
  `Arbitrary Spec` generator (in `keiro-dsl/test/`) so generated events sometimes carry a
  version + upcaster or a `deprecated` flag, and confirm `parseSpec (renderSpec s) == Right s`
  still holds.
- `keiro-dsl/src/Keiro/Dsl/Validate.hs`: add these rules, each with a new `DiagnosticCode`:
  1. `EvtVersionMissingUpcaster` (Error) — every event version `> 1` must carry an
     `upcastFrom` whose source is exactly `version - 1` (the upcaster chain must be
     contiguous; `Keiro.Codec.migrateToCurrent` reports `GapInUpcasterChain` otherwise —
     `keiro-core/src/Keiro/Codec.hs:202-205`). A `v2` with no `upcast from v1` is rejected.
  2. `EvtRemovedNotDeprecated` (Error) — this rule fires only in `diffSpecs` context (an
     event present in the old spec and absent in the new must be `deprecated`, not deleted).
     In single-spec `validateSpec` the analogous local check is `DeprecatedEventStillEmitted`
     (Error): a `deprecated` event must not appear in any transition's `emit` list (it has
     left the write path).
  3. `EvtFieldAddedWithoutBump` (Error) — purely *intra-spec* this cannot be seen (there is
     no prior shape to compare to), so it is enforced by `diffSpecs` (M2). Document in the
     validator that this code is emitted by the diff path, not the single-spec path, so the
     `DiagnosticCode` enum is the single registry of evolution rules.
  Also extend the EP-1 `wire`/`schemaVersion` cross-check: the `WireSpec.schemaVersion` (if
  the author writes one) must equal the maximum declared event version, else
  `WireSchemaVersionMismatch` (Warning) — keeps the explicit `wire schemaVersion=` line and
  the per-event `vN` from drifting.

Commands and acceptance: see *Validation and Acceptance*, M1 block. Headline: `check` passes
`reservation-v2.kdsl` (a v2 with an `upcast from v1 = HOLE`) and fails
`reservation-v2-noupcast.kdsl` (a v2 with no upcaster) with `EvtVersionMissingUpcaster` on
the v2 line.

### Milestone 2 — the `Keiro.Dsl.Diff` engine and `diff --since` CLI

Scope: compare two specs and classify every change as ADDITIVE or BREAKING, then wire a
`diff --since <git-ref>` subcommand that reads the prior spec from git, runs the diff, prints
the classified changes, and exits non-zero on any unguarded breaking change. This milestone
delivers the plan's headline acceptance.

Work:

- `keiro-dsl/src/Keiro/Dsl/Diff.hs` (new module) exposing
  `diffSpecs :: Spec {- old -} -> Spec {- new -} -> [Change]` with
  `data Change = Additive ChangeKind | Breaking ChangeKind` and a `ChangeKind` enum/record
  describing the concrete delta (node name, event name, and what changed) so messages are
  precise and tests match on structure. Classification rules (decode-safety axis — see the
  Decision Log), applied per node, per event family:
  - **New event type** (present in new, absent in old): **ADDITIVE** — no existing payload
    has that type tag, so nothing on disk fails. (`Keiro.Codec` rejects unknown tags only on
    encode/decode of *that* type; old payloads are untouched.)
  - **New event *version* with a contiguous upcaster** (`vN` added, `upcast from v(N-1)`
    present): **ADDITIVE** — old payloads migrate forward through the chain.
  - **Field added to an existing event version *without* a version bump** (same `version`,
    field set grew): **BREAKING** (`EvtFieldAddedWithoutBump`) — an old payload lacking the
    field reaches the current `decode` and fails. This is the core acceptance case.
  - **Field removed/renamed on an existing version without a bump**: **BREAKING** — the
    current `decode` expects a key the old payload may or may not match; treat as breaking.
  - **Event removed** (present in old, absent in new) **and not `deprecated`**: **BREAKING**
    (`EvtRemovedNotDeprecated`) — the tag drops out of `eventTypes`, so any stored payload of
    that type now fails `decodeRecorded`'s known-type check
    (`keiro-core/src/Keiro/Codec.hs:165-169`). The same removal *with* a `deprecated event`
    declaration retained is **ADDITIVE** — the tag stays decodable.
  - **`schemaVersion` bump with a complete contiguous upcaster chain**: **ADDITIVE**. A bump
    with a gap in the chain is **BREAKING** (would be `GapInUpcasterChain` at runtime).
  - **Enum constructor added** (a value that could appear in a future payload only):
    ADDITIVE. **Enum constructor removed** that an event field ranges over: BREAKING (an old
    payload may carry it and now fail to decode).
  - Non-event changes (a new transition, a new command, a projection key change) are
    classified ADDITIVE for the purposes of *this* command, which gates only event-payload
    decode safety; note in the output that they are not decode-relevant. (Read-model/table
    concerns are delegated to `codd`, out of scope.)
- `keiro-dsl/app/Main.hs`: add a `diff` subcommand with a required `--since <git-ref>` option
  and the spec file path positional argument. Its logic:
  1. Resolve the spec path to repo-relative (run `git -C <repo> rev-parse --show-toplevel`,
     make the path relative to it).
  2. Read the prior spec text: `git show <ref>:<relpath>` (capture stdout). If git errors
     (ref or path absent at that ref), report it and exit non-zero.
  3. `parseSpec` both the old text and the on-disk new text; a parse error in either is
     reported and exits non-zero.
  4. `let changes = diffSpecs old new`. Print each change as
     `ADDITIVE: …` or `BREAKING: …` with the node/event detail.
  5. **Exit non-zero if any `Breaking` change is present**, zero otherwise. (A spec with only
     additive changes, or none, exits zero.)
- Tests in `keiro-dsl/test/`: unit tests over in-memory `Spec` pairs covering every `Change`
  variant above (no git needed — call `diffSpecs` directly). One *integration* test that
  uses a temporary git repo: write `reservation.kdsl`, `git commit`, edit it (the field-add
  case), and run the `diff --since HEAD` code path end-to-end, asserting a BREAKING result
  and non-zero exit; then switch to the v2+upcaster edit and assert ADDITIVE + zero exit.

Commands and acceptance: see *Validation and Acceptance*, M2 block.

### Milestone 3 — scaffold the `Codec` schemaVersion/upcaster wiring + harness

Scope: lower the evolution constructs to a real `Keiro.Codec` and prove the round-trip. The
scaffolder emits a `Codec` whose `schemaVersion` is the max declared event version and whose
`upcasters` list references one hole-backed upcaster per declared version step; the upcaster
*bodies* are typed holes; the harness emits a golden round-trip per version. At the end,
scaffolding a two-version fixture yields compiling `Generated` modules plus a `Holes` module
that, once filled, makes the harness green.

Work:

- `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`: in the `Keiro.Codec` emitter (EP-1 already emits a
  `Codec` with `schemaVersion = 1`, `upcasters = []`), compute `schemaVersion` as the maximum
  event `version` in the aggregate, and build `upcasters` as a list
  `[(m, upcast<Event>V<m>) | each event version step m → m+1 with an upcastFrom]`. The
  emitted code references the upcaster *by name only* — e.g.
  `upcasters = [(1, upcastTransferReservationCreatedV1)]` — matching the shape of
  `orderCodec` in `jitsurei/src/Jitsurei/OrderStream.hs:124-169`. **`deprecated` events stay
  in `eventTypes` and `decode` but are removed from any emit-side wiring.** This module is
  `Generated`; it contains no keiki symbolic operator, so the firewall invariant holds.
- The upcaster signature goes into a `HoleStub` module (the aggregate's hand-owned holes
  module). Emit, for each version step, a typed hole:

  ```haskell
  -- HOLE upcaster: bring a TransferReservationCreated v1 payload up to v2.
  -- v2 added field 'triageNote :: Text'. Decide its default/derivation here.
  upcastTransferReservationCreatedV1 :: Value -> Either Text Value
  upcastTransferReservationCreatedV1 _ = Left "HOLE: upcaster not implemented"
  ```

  The stub compiles (so the `Generated` codec that references it links) but fails at runtime
  until filled — which the harness catches. Model the filled shape on
  `upcastOrderPlacedV1` (`jitsurei/src/Jitsurei/OrderStream.hs:211-228`).
- `keiro-dsl/src/Keiro/Dsl/Harness.hs`: for each non-initial version, emit a golden
  round-trip test: construct a representative *old-version* wire payload (a JSON `Value` in
  the v`(n-1)` shape), feed it through `decodeRaw codec (n-1) payload` (which runs
  `migrateToCurrent` then `decode` — `keiro-core/src/Keiro/Codec.hs:176-181`), and assert it
  produces a `Right` of the expected current-version domain value. With the upcaster hole
  unfilled the test is red (`Left "HOLE: …"`); once filled to match the v`(n-1)`→v`n`
  mapping it is green. Also emit the existing EP-1 same-version round-trip
  (encode→decode at current version) per event.

Commands and acceptance: see *Validation and Acceptance*, M3 block.


## Concrete Steps

Run everything from the keiro repo root unless stated otherwise:
`/Users/shinzui/Keikaku/bokuno/keiro`. This plan assumes EP-1 has landed (the `keiro-dsl`
package builds and `parse`/`check`/`scaffold` work). Confirm first:

```bash
cabal build keiro-dsl
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/reservation.kdsl   # exit 0, echoes the spec
```

### M1 — author the evolution fixtures, then extend grammar/parser/validator

First create the three fixtures the milestones use. `reservation-v2.kdsl` is the canonical
spec with `TransferReservationCreated` evolved to v2 plus an upcaster hole:

```bash
# Copy the canonical spec, then add a v2 event with an upcaster hole and bump the wire line.
cp keiro-dsl/test/fixtures/reservation.kdsl keiro-dsl/test/fixtures/reservation-v2.kdsl
```

Edit `keiro-dsl/test/fixtures/reservation-v2.kdsl` so the event block reads:

```text
  event TransferReservationCreated v2 { reservationId hospitalId commandId patientAcuity divertStatus lifeCriticalOverride:Bool triageNote:Text }
    upcast from v1 = HOLE
  event TransferReservationConfirmed { reservationId hospitalId commandId }
  …
  wire kind=ctorName fields=camelCase schemaVersion=2
```

`reservation-v2-noupcast.kdsl` is the same but with the `upcast from v1 = HOLE` line deleted
(the validator must reject it). `reservation-fieldadd.kdsl` is the canonical spec with
`triageNote:Text` added to `TransferReservationCreated` but **no** `v2` and **no** upcaster
(the diff must call this BREAKING):

```bash
cp keiro-dsl/test/fixtures/reservation-v2.kdsl keiro-dsl/test/fixtures/reservation-v2-noupcast.kdsl
# then delete the `upcast from v1 = HOLE` line in reservation-v2-noupcast.kdsl
cp keiro-dsl/test/fixtures/reservation.kdsl keiro-dsl/test/fixtures/reservation-fieldadd.kdsl
# then append `triageNote:Text` to the TransferReservationCreated field list (no version bump)
```

Then make the grammar/parser/pretty-printer/validator edits described in *Plan of Work* M1
and build:

```bash
cabal build keiro-dsl
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/reservation-v2.kdsl   # round-trips, exit 0
```

Expected `check` behavior:

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-v2.kdsl
# OK
# (exit 0)

cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-v2-noupcast.kdsl
# error: keiro-dsl/test/fixtures/reservation-v2-noupcast.kdsl:NN: event
#   'TransferReservationCreated' version 2 has no 'upcast from v1' clause
#   [EvtVersionMissingUpcaster]
# (exit != 0)
```

### M2 — the diff engine and `diff --since`

After writing `Keiro.Dsl.Diff` and the `diff` subcommand, the headline acceptance is a
git-backed before/after on the same file. Use a throwaway git checkout to make it
reproducible:

```bash
# Establish a baseline commit of the canonical (v1) spec under a path the tool will diff.
cp keiro-dsl/test/fixtures/reservation.kdsl /tmp/svc.kdsl
git -C /tmp init -q evo-demo && cp /tmp/svc.kdsl /tmp/evo-demo/svc.kdsl
git -C /tmp/evo-demo add svc.kdsl && git -C /tmp/evo-demo commit -qm "baseline v1 spec"

# 1) BREAKING: add a field with no version bump and no upcaster.
cp keiro-dsl/test/fixtures/reservation-fieldadd.kdsl /tmp/evo-demo/svc.kdsl
cabal run keiro-dsl -- diff --since HEAD /tmp/evo-demo/svc.kdsl
# BREAKING: aggregate Reservation event TransferReservationCreated:
#   field 'triageNote' added to version 1 without a version bump or upcaster
#   [EvtFieldAddedWithoutBump]
# (exit != 0)

# 2) ADDITIVE: the same field, but wrapped as a v2 with an upcaster hole.
cp keiro-dsl/test/fixtures/reservation-v2.kdsl /tmp/evo-demo/svc.kdsl
cabal run keiro-dsl -- diff --since HEAD /tmp/evo-demo/svc.kdsl
# ADDITIVE: aggregate Reservation event TransferReservationCreated: new version v2
#   with upcaster from v1
# (exit 0)
```

The `--since HEAD` ref resolves the spec's prior blob with `git show HEAD:svc.kdsl` inside
`/tmp/evo-demo` (the tool runs `git rev-parse --show-toplevel` from the spec's directory to
find the repo). Run `cabal test keiro-dsl` to exercise the in-memory `diffSpecs` unit tests
and the temporary-repo integration test.

### M3 — scaffold the codec/upcaster wiring + harness

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation-v2.kdsl --out /tmp/genv2

# The emitted codec carries schemaVersion = 2 and a hole-backed upcaster:
grep -n 'schemaVersion = 2' /tmp/genv2/Generated/HospitalCapacity/Reservation/EventStream.hs
grep -n 'upcasters = \[(1, upcastTransferReservationCreatedV1)\]' \
  /tmp/genv2/Generated/HospitalCapacity/Reservation/EventStream.hs
# The upcaster signature is a typed hole in the hand-owned holes module:
grep -n 'upcastTransferReservationCreatedV1 :: Value -> Either Text Value' \
  /tmp/genv2/HospitalCapacity/Reservation/Holes.hs

cabal test keiro-dsl
# expect, among others:
#  - firewall invariant: no -- @generated line contains a keiki symbolic operator.
#  - golden round-trip (upcaster unfilled): a v1 wire payload fed through decodeRaw codec 1
#    is RED (Left "HOLE: …").
#  - after filling upcastTransferReservationCreatedV1 to default triageNote, the same test
#    is GREEN.
```

Detailed file-by-file edits (cabal stanzas if any, module contents, fixture diffs) are
recorded here as each file is written, with short transcripts proving each step. (To be
filled during implementation.)


## Validation and Acceptance

Acceptance is behavioral and per-milestone. Each milestone is done only when its block below
passes. All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

### M1 — grammar/parser/validator

```bash
cabal test keiro-dsl
# expect: the round-trip property still passes for specs that include versioned/deprecated
# events; a unit test asserts `parseSpec reservation-v2.kdsl` yields a
# TransferReservationCreated Event with version == 2 and upcastFrom == Just (1, Hole);
# a unit test asserts `validateSpec` of reservation-v2-noupcast.kdsl contains a
# Diagnostic with code EvtVersionMissingUpcaster on the v2 line; and a unit test asserts
# a `deprecated` event that appears in an `emit` yields DeprecatedEventStillEmitted.

cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-v2.kdsl          # OK, exit 0
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-v2-noupcast.kdsl # EvtVersionMissingUpcaster, exit != 0
```

The proof beyond compilation: deleting the `upcast from v1 = HOLE` line flips `check` from
exit 0 to exit non-zero with a specific, line-numbered diagnostic.

### M2 — diff classification + git integration (the headline acceptance)

The behavioral acceptance, stated as the plan's contract: **adding a field to an event
without bumping its version and supplying an upcaster makes `diff --since` report BREAKING
and exit non-zero; supplying the version bump + upcaster hole makes it pass (ADDITIVE, exit
zero).** Verified by the `/tmp/evo-demo` transcript in *Concrete Steps* M2, and by the test
suite:

```bash
cabal test keiro-dsl
# expect:
#  - diffSpecs unit tests: each Change variant (new type → Additive; new version+upcaster →
#    Additive; field-add-no-bump → Breaking; remove-not-deprecated → Breaking;
#    remove-with-deprecated → Additive; gap-in-chain → Breaking) is asserted on a fixture
#    Spec pair.
#  - the temporary-repo integration test: commit reservation.kdsl, replace with
#    reservation-fieldadd.kdsl, run the `diff --since HEAD` code path → Breaking present →
#    non-zero exit; replace with reservation-v2.kdsl → no Breaking → zero exit.
```

A reader can reproduce the end-to-end gate manually with the `/tmp/evo-demo` commands above
and observe the two exit codes (`echo $?` after each `diff` run).

### M3 — scaffold + harness round-trip

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation-v2.kdsl --out /tmp/genv2
cabal test keiro-dsl
# expect:
#  - the emitted Generated EventStream codec has `schemaVersion = 2` and
#    `upcasters = [(1, upcastTransferReservationCreatedV1)]`.
#  - firewall invariant test passes (no symbolic operator in any -- @generated line).
#  - golden round-trip: with the upcaster hole unfilled, the v1→current decode test is RED;
#    after the test harness fills (or the fixture's reference fill supplies)
#    upcastTransferReservationCreatedV1 to default `triageNote`, the test is GREEN. Mutating
#    the fill (e.g. dropping the default so the field is absent) turns that specific test red.
#  - idempotence: running `scaffold` twice leaves a hand-edited Holes.hs (with the filled
#    upcaster) untouched.
```

The proof beyond compilation: a v1-shaped wire payload (lacking `triageNote`) decodes
successfully *only* because the filled upcaster supplies the field — demonstrating the codec
actually migrates old data forward, which is the whole point of the evolution constructs.


## Idempotence and Recovery

Every step in M1–M2 is pure source editing plus read-only analysis, and is safe to repeat.
`check` and `diff --since` are **read-only**: they never write to the working tree or to git.
`diff --since` reads history through `git show <ref>:<path>`, which cannot mutate the
repository; rerunning it any number of times yields the same classification. Creating
fixtures with `cp` and editing them is idempotent (re-copying overwrites the same file).

The `/tmp/evo-demo` throwaway git repo used in the M2 transcript is disposable — delete it
with `rm -rf /tmp/evo-demo` and recreate from the `git init` step to reset. It never touches
the real keiro repo.

The M3 scaffolder inherits EP-1's idempotence contract: `Generated` modules (the `Codec`
with `schemaVersion`/`upcasters`) are **fully overwritten** on each run, and the `HoleStub`
module carrying the upcaster signature is **created only when absent and never overwritten**.
This matters more under evolution because a *filled* upcaster body lives in that holes
module: re-scaffolding after an author writes `upcastTransferReservationCreatedV1` must not
clobber it. Verify with the EP-1 idempotence test pattern (run `scaffold` twice; assert a
hand-edited `Holes.hs` is byte-identical after the second run).

To roll back this plan entirely: revert the edits to `Grammar.hs`, `Parser.hs`,
`PrettyPrint.hs`, `Validate.hs`, `Scaffold.hs`, `Harness.hs`, and `Main.hs`; delete
`keiro-dsl/src/Keiro/Dsl/Diff.hs` and the `reservation-v2*.kdsl`/`reservation-fieldadd.kdsl`
fixtures. The changes are additive to EP-1 (new record fields default to `version = 1`,
`upcastFrom = Nothing`, `deprecated = False`, reproducing pre-EP-2 behavior), so an
unversioned spec behaves exactly as before.


## Interfaces and Dependencies

No new external libraries. EP-2 reuses what EP-1 added to `keiro-dsl.cabal`
(`megaparsec`, `optparse-applicative`, `prettyprinter`, `parser-combinators`, plus `base`,
`text`, `containers`) and the `process` (or `typed-process`) package for invoking `git` from
the `diff` subcommand — add `process` to `keiro-dsl.cabal` if EP-1 did not. The runtime
target it lowers to, `Keiro.Codec`, is in `keiro-core` (already in `cabal.project`); the
emitted `Generated` modules depend on `keiro`/`keiro-core`/`keiki` exactly as EP-1's do. No
existing keiro package gains a dependency.

### The grammar extension EP-3…EP-6 may reuse

The single most important interface this plan publishes is the versioning extension to the
shared `Event` node in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`. It must be on the **shared**
`Event` constructor (defined by EP-1), not an aggregate-local type, so every vertical's
events inherit it:

```haskell
-- In Keiro.Dsl.Grammar (EP-1 owns Event; EP-2 adds these fields).
data Event = Event
  { eventName   :: Name
  , eventFields :: EventFields          -- EP-1: fields(Command) | explicit field list
  , version     :: Int                  -- EP-2: default 1; the schema version of this shape
  , upcastFrom  :: Maybe (Int, Hole)    -- EP-2: source version this migrates from + the hole
  , deprecated  :: Bool                 -- EP-2: removed from write path, still decodable
  , eventLine   :: Int                  -- EP-1: source line for diagnostics
  }

data Hole = Hole | Filled Text          -- EP-2 (reuse EP-1's hole repr if it has one)
```

A vertical (EP-3 process events, EP-4 contract/integration events, EP-6 workflow events)
that declares an event automatically participates in `diffSpecs` classification and in the
codec `schemaVersion`/`upcaster` scaffolding — no per-vertical evolution code needed.

### Signatures that must exist at the end of each milestone

- **M1** — extended `Keiro.Dsl.Grammar.Event` (above); the parser
  `parseSpec :: Text -> Either ParseError Spec` (EP-1) now accepts `vN`/`upcast from`/
  `deprecated`; `renderSpec :: Spec -> Text` (EP-1) renders them; `Keiro.Dsl.Validate`'s
  `validateSpec :: Spec -> [Diagnostic]` gains the new `DiagnosticCode` constructors
  `EvtVersionMissingUpcaster`, `DeprecatedEventStillEmitted`, `WireSchemaVersionMismatch`
  (and registers `EvtFieldAddedWithoutBump`/`EvtRemovedNotDeprecated`, emitted by the diff
  path).
- **M2** — `keiro-dsl/src/Keiro/Dsl/Diff.hs` exposing:

  ```haskell
  diffSpecs :: Spec {- old -} -> Spec {- new -} -> [Change]

  data Change
    = Additive ChangeKind
    | Breaking ChangeKind

  data ChangeKind = ChangeKind
    { node      :: Name          -- e.g. the aggregate name
    , subject   :: Text          -- e.g. event name, enum name
    , code      :: DiagnosticCode -- reuses Validate's registry for breaking kinds
    , detail    :: Text          -- human-readable delta
    }
  ```

  Plus the `diff` subcommand in `keiro-dsl/app/Main.hs` (`--since <git-ref>` + spec path),
  exiting non-zero iff any `Breaking` change is present. A helper
  `specAtRef :: FilePath {- repo -} -> Text {- ref -} -> FilePath {- relpath -} -> IO (Either Text Text)`
  wraps `git show <ref>:<relpath>`.
- **M3** — `Keiro.Dsl.Scaffold.scaffoldAggregate :: Context -> Aggregate -> [ScaffoldModule]`
  (EP-1 signature, unchanged) now emits a `Codec` with `schemaVersion` = max event version
  and `upcasters` referencing per-step hole upcasters, plus a `HoleStub` carrying
  `upcast<Event>V<n> :: Value -> Either Text Value`. `Keiro.Dsl.Harness.harnessFor ::
  Context -> Aggregate -> [ScaffoldModule]` (EP-1 signature, unchanged) now also emits a
  golden per-version round-trip test.

### File:line anchors into the runtime (the lowering contract)

The scaffolded codec and the diff classifier must stay faithful to these exact locations:

- `keiro-core/src/Keiro/Codec.hs:54-59` — `type Upcaster = (Int, Value -> Either Text Value)`
  (the shape every emitted upcaster hole must match).
- `keiro-core/src/Keiro/Codec.hs:77-84` — `data Codec` (`schemaVersion :: !Int`,
  `upcasters :: ![Upcaster]` — the fields the scaffolder fills).
- `keiro-core/src/Keiro/Codec.hs:165-169` — `decodeRecorded` rejects unknown event types
  (why removing an event without `deprecated` is BREAKING).
- `keiro-core/src/Keiro/Codec.hs:192-214` — `migrateToCurrent` / `GapInUpcasterChain` (why
  a non-contiguous version step is BREAKING).
- `keiro-core/src/Keiro/Codec.hs:220-225` — `extractSchemaVersion` defaults a missing stamp
  to `1` (why an unversioned event is v1).
- `jitsurei/src/Jitsurei/OrderStream.hs:124-169` — `orderCodec` with `schemaVersion = 2` and
  `upcasters = [(1, upcastOrderPlacedV1)]` (the exact emitted-codec shape to reproduce).
- `jitsurei/src/Jitsurei/OrderStream.hs:211-228` — `upcastOrderPlacedV1` (the canonical
  filled-upcaster body: defaults a missing `sku`, reads old `qty` as `quantity`).
- `keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/Reservation/EventStream.hs:63,66`
  — `schemaVersion = 1`, `upcasters = []` (the un-evolved baseline the scaffolder emits for
  a v1-only spec).

The bijection contract from EP-1 (every DSL node lowers to a named keiro primitive) is
preserved: the evolution constructs lower precisely to the `Codec.schemaVersion`/`upcasters`
surface and nothing else. Read-model table migrations remain delegated to `codd` and are not
part of this contract.
