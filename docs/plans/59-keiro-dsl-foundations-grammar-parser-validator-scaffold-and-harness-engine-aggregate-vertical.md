---
id: 59
slug: keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical
title: "keiro-dsl foundations: grammar, parser, validator, scaffold and harness engine, aggregate vertical"
kind: exec-plan
created_at: 2026-06-10T01:05:27Z
intention: "intention_01ktqdn85xe2btqzr2zghxgrpr"
master_plan: "docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md"
---

# keiro-dsl foundations: grammar, parser, validator, scaffold and harness engine, aggregate vertical

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, building a new **keiro service** — a bounded context that uses event sourcing,
process managers, durable timers, durable workflows, and Kafka/PGMQ integration — means
hand-writing a large amount of highly regular Haskell. An empirical audit of two real
keiro services found that roughly two-thirds to nine-tenths of the code per feature is a
deterministic template, and the non-derivable remainder collapses into a small, closed
set of **eight "hole-kinds"** (defined in *Context and Orientation* below). This plan
builds the foundation of **`keiro-dsl`**: a toolchain over a **typed specification** of a
keiro service. That specification is a plain-text file with the extension `.kdsl` written
in a terse, readable notation; it is the permanent, machine-checkable source of truth for
what a service is.

After this plan, a developer (or a coding agent planning a feature) can do three concrete
things from a single binary called `keiro-dsl`:

1. Run `keiro-dsl parse service.kdsl` and get the spec parsed into a typed in-memory model
   and pretty-printed back out — proving the notation is a real, parseable language rather
   than freeform text.
2. Run `keiro-dsl check service.kdsl` and have the tool **reject the spec** with a precise,
   line-numbered diagnostic if any required decision is left unspecified or any structural
   rule is violated — *before any Haskell is written*.
3. Run `keiro-dsl scaffold service.kdsl --out <dir>` and get two kinds of Haskell modules:
   `-- @generated` modules holding the **symbol-free deterministic layer** (domain data
   types, id newtypes, codec, event-stream and projection wiring, the register type-list,
   and the Template-Haskell splice), plus **typed hole** modules (created only if absent)
   holding the parts a human or coding agent must fill — chiefly the transducer body and
   the eight hole-kinds. A spec-derived **harness** (emitted test modules) then pins the
   filled behavior.

The user-visible proof at the end of this plan: take a real, hand-written keiro aggregate
captured from the external corpus (`HospitalCapacity/Reservation`, which uses registers, a
guard, register writes, and a status-map projection), check it, scaffold it, hand-fill the
holes to match the captured reference, and show (a) the `-- @generated` modules compile,
(b) a tested **firewall invariant** holds — *no `-- @generated` line ever contains a keiki
symbolic operator* — and (c) the emitted harness goes **green**, while mutating a filled
guard or a status-map entry turns a **specific** harness test **red**.

The single most important scope boundary, repeated because everything depends on it:
**keiro-dsl does not emit the symbolic transducer logic.** The transducer body — the part
that lowers guards and register writes into keiki's symbolic operator surface (`./=`,
`.==`, `.||`, `lit`, `B.slot @"…" =:`, `B.requireGuard`) — is the most brittle,
most framework-coupled piece and exactly the code a coding agent writes well from a spec
plus examples. It is left as a typed hole and pinned by the harness. The scaffolder emits
only the deterministic boilerplate plus hole signatures; a tested firewall invariant
guarantees it never emits a keiki symbolic operator.

This plan is **EP-1 (Foundations)** of the MasterPlan
`docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md`. It is the hard
prerequisite for every other child plan (EP-2 through EP-7), because it defines the shared
engine types those plans extend additively: `Keiro.Dsl.Grammar` (the abstract syntax),
`Keiro.Dsl.Parser`, `Keiro.Dsl.PrettyPrint`, `Keiro.Dsl.Validate` (the `Diagnostic`
framework and cross-cutting rules), `Keiro.Dsl.Scaffold` (the `ScaffoldModule`/`ModuleKind`
engine and the firewall invariant), `Keiro.Dsl.Harness`, and the CLI dispatcher. It also
proves the whole engine end-to-end on the **aggregate** vertical — the one node type every
keiro service has.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — package, grammar, parser, pretty-printer, round-trip, `parse` CLI: **DONE 2026-06-10**

- [x] Create the `keiro-dsl/` package directory tree and `keiro-dsl.cabal` (library + executable + test). (2026-06-10)
- [x] Add `keiro-dsl` to `cabal.project`'s `packages:` list. (2026-06-10)
- [x] Write `Keiro.Dsl.Grammar` — ADTs for shared declarations (`IdDecl`, `EnumDecl`, `RuleDecl`, the hole types `Derivation`/`Disposition`/`Mapping`/`EnvelopeBinding`), the `Expr` sublanguage, the `Aggregate` node, and the top-level `Spec`. (2026-06-10)
- [x] Write `Keiro.Dsl.Parser` exposing `parseSpec :: FilePath -> Text -> Either ParseError Spec` (megaparsec; FilePath form per MasterPlan reconciliation) plus `parseSpecText`. (2026-06-10)
- [x] Write `Keiro.Dsl.PrettyPrint` exposing `renderSpec :: Spec -> Text`. (2026-06-10)
- [x] Write the round-trip property test `parse . pretty == id` (100 generated specs pass) and the canonical-spec unit test. (2026-06-10)
- [x] Write `keiro-dsl/app/Main.hs` with the optparse-applicative command tree and the `parse` subcommand. (2026-06-10)
- [x] Capture the canonical `reservation.kdsl` fixture; confirm `keiro-dsl parse` round-trips it. (2026-06-10)

Milestone 2 — validator + `check` CLI: **DONE 2026-06-10**

- [x] Write `Keiro.Dsl.Validate` exposing the `Diagnostic` type and `validateSpec :: Spec -> [Diagnostic]`. (2026-06-10)
- [x] Implement the cross-cutting checks (declared-reference, reachability, terminal-no-outgoing, guard `Expr` scope-check, status-map totality, clock-free). (2026-06-10)
- [x] Add the `check` subcommand; wire diagnostics to a non-zero exit. (2026-06-10)
- [x] Add validator unit tests (good spec passes; each broken-spec fixture yields the expected diagnostic) + captured `reservation-no-statusmap/-bad-command/-clock` fixtures. (2026-06-10)

Milestone 3 — scaffold engine + firewall invariant + `scaffold` CLI: **DONE 2026-06-10**

- [x] Write `Keiro.Dsl.Scaffold` exposing `ScaffoldModule`/`ModuleKind`/`Context` and `scaffoldAggregate :: Context -> Spec -> Aggregate -> [ScaffoldModule]` (Spec threaded for shared id/enum decls). (2026-06-10)
- [x] Emit the symbol-free deterministic layer into `Generated` modules (Domain ADTs incl. id newtypes + accessors + enum text fns + vertex enum, `…Regs`, `initial…Regs`, the two TH splices; Codec encode/decode; EventStream wiring; Projection wiring + pure status mapping). (2026-06-10)
- [x] Emit the typed hole module (`Holes.hs`) with the transducer signature, the `buildTransducer` skeleton reproducing the `B.from`/`B.onCmd`/`B.goto` structure, and per-`guard`/`write`/`emit` annotation holes carrying the exact spec `Expr`. (2026-06-10)
- [x] Add the `scaffold <file> --out <dir>` subcommand with `Generated`=overwrite / `HoleStub`=create-if-absent file-writing discipline. (2026-06-10)
- [x] Write the firewall-invariant test (no `Generated` module text contains a keiki symbolic operator). (2026-06-10)
- [x] Write the idempotence test (determinism + HoleStub kind); plus the live CLI sentinel sequence (hand-edited `Holes.hs` survives, Generated byte-identical). (2026-06-10)
- [x] Capture the `HospitalCapacity/Reservation` Generated modules under `keiro-dsl/test/conformance/`; the `keiro-dsl-conformance` suite compiles them + a hand-filled `Holes.hs` against keiki/keiro and a scaffold-conformance test pins live output to them. (2026-06-10)
- [x] Scaffold the register-free smoke target (`OrderStream`); show it scaffolds without error and respects the firewall. (2026-06-10)

Milestone 4 — harness engine + aggregate conformance:

- [ ] Write `Keiro.Dsl.Harness` exposing `harnessFor :: Context -> Aggregate -> [ScaffoldModule]`.
- [ ] Emit `validateTransducer defaultValidationOptions` calls, golden wire fixtures (encode/decode round-trip per event), and a clock-free static assertion.
- [ ] Hand-fill the captured Reservation `Holes.hs` to match the reference; show the aggregate compiles and the emitted harness is green.
- [ ] Add the mutation test: flipping a filled guard or a status-map entry turns a specific harness test red.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **M1: the `states` line greedily swallowed a transition source.** The round-trip
  property test (QuickCheck) immediately surfaced an ambiguity the canonical fixture
  could not: when a transition directly follows the `states` line with no `command`/
  `event` between them (which the fixture happens to avoid), `some pStateDecl` parsed the
  transition's *source* state name as a fourth state, then failed at the `--` arrow:

  ```text
  64 |   St5 -- Ev9 -->
     |       ^
  unexpected '-'
  expecting "aggregate", "command", … '!', '_', end of input, or letter
  ```

  Fix: a state decl now carries a `notFollowedBy (symbol "--")` lookahead (wrapped in
  `try`) so the identifier is left for `pTransition`. This is the kind of grammar bug a
  hand-written fixture never exercises but a generator finds on the sixth case — strong
  evidence the round-trip property is doing real work.

- **M3: bare command/event field types resolve via registers, then a Pascal-case
  fallback.** The `.kdsl` writes bare fields like `reservationId hospitalId commandId`,
  and the scaffolder must recover each Haskell type. `reservationId` Pascal-cases to
  `ReservationId`, which is *not* a declared id (`TransferReservationId` is) — so a
  name→type-by-capitalization rule alone fails. Resolution that works for the corpus: (1)
  reuse a same-named register's type (`reservationId`/`hospitalId`/`patientAcuity` are
  registers), else (2) Pascal-case and match a declared id/enum/vertex (`commandId` →
  `CommandId`, `divertStatus` → `DivertStatus`), else (3) fall back to `Text`. The
  conformance compile proves this lines up with real types.

- **M3: the Generated layer needs `DuplicateRecordFields` + `OverloadedRecordDot`.** Every
  command/event record repeats `reservationId`/`hospitalId`/`commandId`, so GHC rejects
  the Domain module without `DuplicateRecordFields` (the corpus enables it globally; the
  self-contained Generated module must declare it per-file). Field reads in the Codec and
  the filled transducer use `payload.field`/`d.field` (`OverloadedRecordDot`), which
  resolves the duplicates by type. Evidence: `keiro-dsl-conformance` compiles and prints
  `validateTransducer == [] OK` + `codec round-trip OK`.

- **M3 scope: codec decode is strict and the projection `apply` is a hole.** The reference
  codec uses service-specific optional defaults (`divertStatus`→`Open`,
  `lifeCriticalOverride`→`False`) — those are EP-4's lenient/optional-decode territory, so
  the EP-1 scaffolder emits a *strict* decode (every field required). The reference
  projection `apply` is raw hasql SQL with hand-written column names — not derivable, and
  read-model migrations are delegated to `codd` per the MasterPlan — so the Generated
  Projection module emits only the deterministic `InlineProjection` wiring plus the pure
  event→status mapping (`…StatusFor`), leaving the SQL `apply` a typed hole in `Holes.hs`.

- **M2: write right-hand sides and guards range over state names too.** The guard
  scope-check initially resolved atoms against registers ∪ command-fields ∪ enum-ctors ∪
  rules, and the canonical spec immediately failed with two `GuardAtomOutOfScope` on
  `write reservationState := Held` / `:= Confirmed`. `Held`/`Confirmed` are *state* names,
  i.e. constructors of the implicit vertex enum (`ReservationVertex`) the scaffolder will
  generate, and a register of that type is legitimately assigned one. Fix: add the
  aggregate's state names to the in-scope set. Evidence: the four `check` invocations now
  yield `OK`/exit 0 for the canonical spec and exactly one precise diagnostic each for the
  three broken fixtures.

- **M2: `status-map` made optional in the grammar.** The plan wants *deleting the
  status-map line* to be a validation error (`StatusMapNotTotal`), not a parse error, so
  `ProjectionSpec.projStatusMap` became `Maybe Mapping` (parser uses `optional`,
  pretty-printer omits it when absent, generator wraps it in `genMaybe`). Totality matches
  a status-map key to an event when the key is a (non-empty) suffix of the event name
  (`Created` ⊑ `TransferReservationCreated`), mirroring how the corpus's TH wire deriver
  produces short constructor names.

- **M1: source locations vs. structural equality.** The AST carries a line number on
  every declaration (for M2 diagnostics), but the pretty-printer cannot reproduce exact
  line numbers, so a naive derived `Eq` would break `parse . pretty == id`. Resolved by a
  `newtype Loc` whose `Eq` instance ignores its value (`_ == _ = True`); the derived
  structural `Eq` on the whole tree then ignores positions automatically, with no
  tree-walking normalizer needed.


## Decision Log

Record every decision made while working on the plan. These initial entries are inherited
from the MasterPlan (`docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md`) and
its predecessor research plan (`docs/plans/58-build-the-keiro-dsl-service-dsl-toolchain.md`);
they are repeated here so this plan is self-contained.

- Decision: keiro-dsl is a **typed spec** with `check` + `scaffold` + `harness` (+ `diff`,
  added by EP-2), **not** a full transducer generator. The scaffolder emits only the
  symbol-free deterministic layer plus typed hole signatures; it never emits a keiki
  symbolic operator (the firewall invariant).
  Rationale: emitting the symbolic transducer is the largest, most brittle,
  keiki-lockstep-coupled piece, and exactly the code a coding agent writes well from a spec
  plus examples. The determinism guarantee the project actually needs is *behavioral*
  ("two agents produce behaviorally-identical code") and is delivered by the harness
  (`validateTransducer` + golden wire fixtures + clock-free check), regardless of who wrote
  the transducer body. This is the load-bearing scope decision.
  Date: 2026-06-10

- Decision: The canonical authoring surface is a **bespoke terse notation** (parsed with
  megaparsec), not KDL, Dhall, or a Haskell embedded DSL; the CLI uses
  optparse-applicative; the pretty-printer uses prettyprinter.
  Rationale: the hard requirement is readability by both humans and coding agents. The
  terse notation read fluently in the audit; Dhall is verbose, KDL is bracket-heavy, and a
  Haskell eDSL cannot typecheck before the domain types it describes exist. We accept
  writing our own parser in exchange for the cleanest surface and recover typechecking via
  the dedicated validator (M2). None of these three libraries is yet a dependency anywhere
  in keiro (confirmed by grep over all `.cabal` files), so they are added fresh to the new
  package only, touching nothing existing.
  Date: 2026-06-10

- Decision: Generated code and hand-filled holes live in **separate modules**. `Generated`
  modules carry a `-- @generated` marker and are fully overwritten on every scaffold; hole
  modules (`Holes.hs`) are created only when absent and never overwritten.
  Rationale: the `.kdsl` file is a permanent source of truth, regenerated on every change.
  If regeneration overwrote hand-written logic the tool would be unusable past the first
  edit. The generated/hole split makes the Nth scaffold as safe as the first. This matters
  *more* under the scaffold+verify decision, because the transducer body lives in
  `Holes.hs`.
  Date: 2026-06-10

- Decision: The primary conformance corpus is the **external** `keiro-runtime-jitsurei`
  repository, captured as **read-only fixtures** under `keiro-dsl/test/fixtures/`. The
  in-repo `jitsurei` context (e.g. `OrderStream`) is a secondary, register-free **smoke
  target** only.
  Rationale: every in-repo `jitsurei` aggregate is register/guard/projection-free, so it
  cannot exercise the features the DSL exists for (registers, guards, status-map
  projections). The rich examples live only in the external repo. Capturing slices as
  fixtures keeps the test suite hermetic — it does not require the sibling repo to be
  checked out.
  Date: 2026-06-10

- Decision (this plan): **Pick `deriveAggregateCtorsAll ''Command ''Regs` (the 2-argument
  `Keiki.Generics.TH` deriver used by the external hospital-capacity corpus) as the single
  TH deriver the aggregate scaffolder emits.**
  Rationale: the corpus contains two derivers — in-repo jitsurei uses
  `deriveAggregate ''C ''R ''E` (3 args) and external hospital-capacity uses
  `deriveAggregateCtorsAll ''C ''R` (2 args). The conformance target that exercises the
  full feature set (`HospitalCapacity/Reservation`) uses the 2-argument form, and the
  separate `deriveWireCtorsAll ''Event` splice it pairs with provides the `wireX`/
  `XTermFields` names the transducer hole references. Standardizing on the form the rich
  fixture already uses removes a divergence between the scaffold and the reference we
  conform against. The register-free smoke target (`OrderStream`) currently uses the
  3-argument form, so the smoke scaffold uses the 2-argument deriver plus the wire splice
  too; this is a deliberate, documented divergence from that file (it changes only which
  TH splice produces the witnesses, not behavior) and is acceptable for a smoke target.
  Date: 2026-06-10

- Decision (this plan, M1): **`Expr` atoms are kept syntactically neutral (`AName Name |
  ABool Bool`), not pre-classified into register/field/enum-ctor/rule kinds.**
  Rationale: at parse time an identifier is lexically indistinguishable between a register,
  a command field, an enum constructor, and a rule; classifying requires scope, which is
  exactly the validator's job (M2's guard scope-check resolves each `AName` against
  registers ∪ command fields ∪ enum constructors ∪ rules). Keeping atoms neutral makes the
  parser honest and the round-trip exact, and loses nothing — the validator and scaffolder
  both have the declared sets available. Booleans (`true`/`false`) are keywords, so they
  parse to `ABool` directly. Date: 2026-06-10

- Decision (this plan, M1): **adopt `parseSpec :: FilePath -> Text -> Either ParseError
  Spec`** (the source-name form) and expose `parseSpecText :: Text -> …` as a convenience
  wrapper, per the MasterPlan's cross-plan reconciliation note. The `FilePath` is used only
  as the source name in megaparsec's line/column diagnostics. Date: 2026-06-10

- Decision (this plan, M1): **the notation is parsed keyword-driven with newlines and
  `#`-comments treated as insignificant whitespace**, rather than with a strict
  indentation lexer. Structure comes from keywords (`aggregate`/`regs`/`states`/`command`/
  `event`/`wire`/`projection`) and the `Src -- Cmd -->` arrow; clauses may be stacked or
  `;`-separated interchangeably. Rationale: the grammar is unambiguous via keywords (with
  one lookahead fix for the states/transition boundary — see Surprises), and a
  whitespace-insignificant parser is simpler, more robust, and frees the pretty-printer
  from reproducing exact layout. Date: 2026-06-10

- Decision (this plan, M3): **`scaffoldAggregate` takes the `Spec` as well** —
  `scaffoldAggregate :: Context -> Spec -> Aggregate -> [ScaffoldModule]`, a refinement of
  the `Context -> Aggregate -> …` signature sketched in *Interfaces and Dependencies*.
  Rationale: the id and enum declarations are shared at the `Spec` level (not per
  aggregate), and the scaffolder needs them to emit the id newtypes, enum types, enum
  wire-text/parse functions, and to resolve bare field types. Threading the `Spec` is the
  minimal additive change; later verticals keep this shape. Date: 2026-06-10

- Decision (this plan, M3): **compilation of the Generated layer is proven by a committed
  `keiro-dsl-conformance` cabal test-suite**, not by invoking GHC from within a test. The
  suite's `hs-source-dirs` is `test/conformance/`, holding the scaffolded
  `Generated.HospitalCapacity.Reservation.*` modules (byte-identical to `keiro-dsl
  scaffold` output, pinned by a whitespace-normalized scaffold-conformance test in
  `keiro-dsl-test`) plus a hand-filled `Holes.hs`. `cabal build keiro-dsl-conformance`
  therefore *is* the compile proof, and its `Main` asserts
  `validateTransducer defaultValidationOptions reservationTransducer == []` and a codec
  round-trip. Rationale: hermetic, fast, and it keeps the live scaffolder honest against
  known-compiling output without a GHC-in-test dependency. Date: 2026-06-10

- Decision (this plan): **`Context` is a thin wrapper carrying the spec's `context` name and
  the chosen output module-namespace root**, threaded into `scaffoldAggregate` and
  `harnessFor` as the first argument. It is part of the EP-1 integration contract and is
  extended additively (never re-shaped) by later verticals.
  Rationale: the scaffolder must compute module names like
  `<Root>.Generated.<Context>.<Aggregate>.Transducer` and file paths under `--out`, and the
  harness must reference the same names. Centralizing that in one `Context` value keeps the
  signatures stable for EP-2…EP-6, which is the integration requirement the MasterPlan
  imposes.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this section fully before touching code. It assumes you know nothing about keiro, the
DSL, or this repository.

### What keiro is, in one paragraph

keiro is an **event-sourcing framework** written in Haskell. A **service** (a bounded
context) is built from a small set of **primitives**. An **aggregate** is a consistency
boundary whose state is rebuilt by replaying its **events**; it accepts **commands** and,
per a state machine called a **transducer**, emits events and moves between named
**states**. The primitives live in this repository: the event-sourcing core is in the
`keiro/` and `keiro-core/` packages, and the transducer builder is in a separate package
`keiki` (referenced from `cabal.project` as a `source-repository-package`, and present on
disk at `/Users/shinzui/Keikaku/bokuno/keiki`). The other node types — router, process
manager, durable timer, workflow, operation, integration adapters — are out of scope for
EP-1 and handled by sibling plans `docs/plans/60`…`docs/plans/65`.

### Key terms used throughout this plan

- **`.kdsl` file** — a plain-text service specification in the terse notation shown below.
  It is indentation-structured; `#` begins a line comment; a `!` immediately after a state
  name marks that state **terminal** (no outgoing transitions allowed); the literal word
  `HOLE` names an unfilled hole.
- **transducer** — the aggregate's state machine. In keiki it is a value built with
  `Keiki.Builder.buildTransducer`, whose body is a sequence of `B.from <state>` blocks,
  each containing `B.onCmd <inCtor> $ \d -> …` handlers that may call `B.requireGuard`,
  `B.slot @"…" =:` (register write), `B.emit`, and `B.goto`.
- **register** — a named, typed slot of aggregate state that survives between commands
  (e.g. `reservationState`). The set of registers is a **type-level list** `…Regs` and an
  initial value `initial…Regs`. An aggregate with no registers declares `type …Regs = '[]`.
- **symbolic operator surface** — the keiki operators a transducer body uses: `lit`
  (a literal term), `./=`/`.==` (inequality/equality predicates), `.||`/`.&&` (predicate
  or/and), `B.requireGuard` (assert a predicate), and `B.slot @"name" =:` (write a
  register). The **firewall invariant** of this plan is that **no `-- @generated` line ever
  contains any of these**; they appear only in hand-owned, harness-checked modules.
- **hole** — a piece of code the scaffolder deliberately does *not* write, leaving a typed
  signature (and a spec annotation) for a human or coding agent to fill. The transducer
  body is the largest hole; the **eight hole-kinds** (below) are the rest.
- **scaffold** — to emit Haskell source modules from a spec: `Generated` modules (the
  symbol-free deterministic layer, overwritten each run) and `HoleStub` modules
  (`Holes.hs`, created only if absent).
- **harness** — emitted **test** modules (not product code) that pin the filled holes'
  behavior: `validateTransducer` calls, golden wire fixtures, and a clock-free assertion.

### The eight hole-kinds (the only non-derivable surface)

Everything the scaffolder cannot emit deterministically is one of these. A node's type
*requires* the relevant holes to be present, which the validator (M2) enforces. EP-1
defines the grammar types for all eight (so later verticals reuse them) but only exercises
hole-kinds 1–3 against the aggregate vertical; the rest are exercised by EP-3…EP-6.

1. **derivation** — a deterministic id/string derivation, tagged with a `strategy`
   (`uuidv5` | `suffix-splice`). Opaque ones (e.g. a per-status string scramble) must carry
   a captured **fixture**, not a prose rule, because two agents cannot re-derive them
   identically.
2. **disposition** — a failure→action table whose actions are `AckOk` | `Retry n` |
   `DeadLetter r`. It carries the dangerous inversions (a *duplicate* or *rejected replay*
   is treated as success; a *previously-failed* message is dead-lettered, not retried).
3. **mapping** — an explicit value→value table that is not an identity echo (e.g. an event
   name → projection status, where `Created` maps to `held`).
4. **field-source / envelope-binding** — which layer (Kafka header vs JSON body) carries
   each envelope field, and whether the two are cross-checked.
5. **cross-node coupling** — a value defined once and referenced elsewhere (an id scheme, a
   queue's derived physical table name). The grammar's "define once, reference" discipline
   removes the duplication; the validator flags divergence.
6. **decode strictness** — lenient decode (optional-with-default) vs strict
   (`schemaVersion` hard pin), stated separately from encode.
7. **optionality** — explicit `Maybe`/`[]` where a naive reader assumes presence.
8. **runtime config (delegated)** — knobs the node set does not determine (consumer group,
   poll batch size, pool size). Declared, but the scheduling loop itself is delegated to
   deployment, not emitted.

A cross-cutting rule the validator must enforce: **time is injected, never sampled.** A
deadline is computed from an input timestamp carried as data (e.g. `observedAt`), never
from a wall-clock read inside a transducer or handler — sampling the clock breaks
deterministic replay. EP-1 enforces this for the aggregate vertex (no clock atom may appear
in a guard or write `Expr`); later verticals extend it to timer deadlines.

### The canonical surface (the M1 parser target)

This is the exact notation M1 must parse and round-trip. It describes one aggregate and is
reproduced verbatim from the predecessor plan
`docs/plans/58-build-the-keiro-dsl-service-dsl-toolchain.md`. It is a faithful transcription
of the real external aggregate
`keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/Reservation/Transducer.hs`.
Save it as `keiro-dsl/test/fixtures/reservation.kdsl`.

```text
context hospital-capacity

id  TransferReservationId  prefix=rsv
id  HospitalId             prefix=hosp
id  CommandId              prefix=cmd

enum PatientAcuity { RedTag=red YellowTag=yellow GreenTag=green }
enum BedType       { Icu=icu MedicalSurgical=medical-surgical }
enum DivertStatus  { Open=open PartialDivert=partial-divert TotalDivert=total-divert }

rule lifeCriticalOverride : PatientAcuity -> Bool
  ex RedTag => true ; YellowTag => false ; GreenTag => false

aggregate Reservation
  regs
    reservationId    TransferReservationId = placeholder
    hospitalId       HospitalId            = placeholder
    patientAcuity    PatientAcuity         = GreenTag
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

Notes on the notation, line by line, so the parser author knows exactly what to accept:

- `context <name>` — the service/bounded-context name, one per file.
- `id <TypeName> prefix=<tag>` — declares an id newtype over `Text` and its prefix tag.
- `enum <Name> { Ctor=wire-name … }` — a closed enumeration; each constructor has a wire
  spelling (`RedTag=red`).
- `rule <name> : <Enum> -> Bool` followed by an `ex` line of `Ctor => bool ; …` — a total
  function from an enum to a value (here a `Bool`), used as a derived atom in guards.
- `aggregate <Name>` opens a node; its body is indentation-nested.
- `regs` lists named registers with `name Type = initial`.
- `states <s1> <s2> … <sN>!` — the state set; a trailing `!` marks a terminal state.
- `command <Name> { field … field:Type }` — a command constructor; a bare field name reuses
  the field's declared type (an id type, an enum, or — for ids — the id newtype), and
  `name:Type` gives an explicit primitive type (e.g. `lifeCriticalOverride:Bool`).
- `event <Name> { … }` or `event <Name> = fields(<Command>)` — an event constructor, either
  with its own fields or copying a command's field list.
- A transition is `Src -- Command --> <clauses>` where clauses are `guard <Expr>`,
  `write <reg> := <Expr>`, `emit <Event>`, `goto <State>`. Clauses may be written
  indentation-stacked (the first transition) or `;`-separated on one line (the second).
- `wire kind=ctorName fields=camelCase schemaVersion=<n>` — how events serialize.
- `projection <table> consistency=<Strong|Eventual> key=<field>` with a nested
  `status-map { EventName=>status … }` — the read-model projection and its event→status
  mapping (hole-kind 3, *mapping*).

The **`Expr` sublanguage** (used by `guard` and the right-hand side of `write`) is an infix
expression over **atoms**: register names (`reservationState`), command-field names
(`divertStatus`), enum constructors (`TotalDivert`, `Held`), `rule` names
(`lifeCriticalOverride`), and the booleans `true`/`false`. The operators, lowest precedence
first, are `||` then `&&` then the relational `==`/`!=`/`<`/`<=`/`>`/`>=`. Guards are parsed
as a **typed `Expr`**, never an opaque string, because M2 scope-checks the atoms, M4 drives
the guard both true and false, and the scaffolder reproduces the `Expr` as an annotation on
the transducer hole.

### What the aggregate scaffolder emits (grounded in the real reference)

The hand-written reference
`…/HospitalCapacity/Reservation/Transducer.hs` (read during research) shows exactly what
the `Generated` layer must produce so it lines up with what the TH deriver and
`buildTransducer` expect:

- The state enum `data ReservationVertex = ReservationUnrequested | ReservationHeld | …`
  `deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)`.
- Per-command payload records `data RequestTransferReservationData = …` and the command sum
  `data ReservationCommand = RequestTransferReservation !RequestTransferReservationData | …`.
- Per-event payload records `data TransferReservationCreatedData = …` and the event sum
  `data ReservationEvent = TransferReservationCreated !TransferReservationCreatedData | …`,
  all `deriving stock (Generic, Eq, Show)`.
- The register type-list `type ReservationRegs = '[ '("reservationState", ReservationVertex), … ]`.
- `initialReservationRegs :: RegFile ReservationRegs` built as an
  `RCons (Proxy @"…") <initial> $ … RNil` chain (note: `RCons` is keiki's, imported from
  `Keiki.Core`; `Proxy` from `base`).
- The TH splices `$(deriveAggregateCtorsAll ''ReservationCommand ''ReservationRegs)` and
  `$(deriveWireCtorsAll ''ReservationEvent)` — these synthesize the `inCtor…` matchers, the
  `wire…` constructors, and the `…TermFields` records the transducer body references.
- Id newtypes + text accessors. The reference uses a shared `idText` accessor over an
  `Id` class on `TransferReservationId`/`HospitalId`/`CommandId`; for the smoke target,
  jitsurei's `Jitsurei.Domain` instead uses `newtype OrderId = OrderId Text` with a
  standalone `orderIdText`. EP-1's scaffolder emits the simpler per-type form
  (`newtype TransferReservationId = TransferReservationId Text` + `transferReservationIdText`)
  to stay self-contained; it does not depend on the corpus's `Id` class.
- The `Keiro.Codec` value (event-type list, `eventType`, `schemaVersion`, `encode`,
  `decode`), the `Keiro.EventStream` value, and the `Keiro.Projection.InlineProjection`
  wiring (`InlineProjection { name, apply }`), all modeled on the captured
  `EventStream.hs`/`Projection.hs` siblings.

The transducer **body** — the `reservationTransducer = B.buildTransducer … do …` block with
`B.requireGuard (d.divertStatus ./= lit TotalDivert .|| d.lifeCriticalOverride .== lit True)`
and `B.slot @"reservationState" =: lit ReservationHeld` — is **not** emitted. It is the hole
in `Holes.hs`, annotated with the spec `Expr` to encode.

### The validator target (keiki)

The harness (M4) calls `Keiki.Core.validateTransducer`, whose real signature (read from
`/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs`) is:

```haskell
validateTransducer ::
  (Bounded s, Enum s, Ord s, Show s) =>
  ValidationOptions ->
  SymTransducer (HsPred rs ci) rs s ci co ->
  [TransducerValidationWarning s]
```

An empty result list means the transducer passed all enabled checks.
`defaultValidationOptions` enables the hidden-input, determinism, and reachability checks
(opaque-guard audit off). The harness asserts
`validateTransducer defaultValidationOptions reservationTransducer == []`.

### Where new code goes

A new package `keiro-dsl` at `/Users/shinzui/Keikaku/bokuno/keiro/keiro-dsl/`, added to
`/Users/shinzui/Keikaku/bokuno/keiro/cabal.project` (whose `packages:` list currently holds
`keiro`, `keiro-core`, `keiro-migrations`, `keiro-pgmq`, `keiro-test-support`, `jitsurei` —
the addition is purely additive and touches nothing existing). Module namespace
`Keiro.Dsl.*`. The repo targets GHC ≥ 9.12 with the `GHC2024` language edition (confirmed in
`keiro/keiro.cabal`: `default-language: GHC2024`, `tested-with: GHC >=9.12 && <9.13`); match
that. Use `-Wall`.

The **conformance corpus** is the external sibling repo
`/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei`; its rich worked examples live under
`services/hospital-capacity/` and `services/incident-command/`. EP-1 captures one slice —
the `HospitalCapacity/Reservation` aggregate — as **read-only fixtures** under
`keiro-dsl/test/fixtures/` (the `.kdsl` plus copies of the hand-written reference modules)
so the test suite is hermetic and does not require the sibling repo to be checked out. The
in-repo `jitsurei` context's `OrderStream` (at
`/Users/shinzui/Keikaku/bokuno/keiro/jitsurei/src/Jitsurei/OrderStream.hs`) is a secondary,
register-free smoke target only.


## Plan of Work

The work proceeds in four milestones, each ending in a runnable, verifiable artifact. M1
stands up the package and the parseable language; M2 adds the validator; M3 adds the
scaffold engine and the firewall invariant; M4 adds the harness engine and proves the whole
vertical end-to-end on the captured Reservation fixture. The shared engine types defined
here are the integration contract that EP-2…EP-6 extend additively — keep their signatures
exactly as written in *Interfaces and Dependencies*.

### Milestone 1 — package, grammar AST (incl. `Expr`), parser, pretty-printer, round-trip, `parse` CLI

Scope: stand up the `keiro-dsl` package and make the canonical Reservation spec (in
*Context and Orientation*) parse into a typed AST and pretty-print back to equivalent text.
At the end the grammar exists as Haskell types and the terse notation is a real, parseable
language.

Work, file by file:

- Create the package tree: `keiro-dsl/src/Keiro/Dsl/`, `keiro-dsl/app/`,
  `keiro-dsl/test/`, `keiro-dsl/test/fixtures/`.
- Write `keiro-dsl/keiro-dsl.cabal` with three stanzas — a `library` exposing the
  `Keiro.Dsl.*` modules, an `executable keiro-dsl` whose `main-is: Main.hs` lives in `app/`,
  and a `test-suite keiro-dsl-test` whose `main-is` lives in `test/`. Set
  `default-language: GHC2024`, `ghc-options: -Wall`, and `build-depends: base, text,
  containers, megaparsec, optparse-applicative, prettyprinter` (the library does not need
  all of these; put megaparsec/prettyprinter in the library, optparse-applicative in the
  executable). Add a test dependency on a property/unit framework already in the repo
  ecosystem (`hspec` plus `QuickCheck`; both already build for this toolchain).
- Add `keiro-dsl` to the `packages:` list in
  `/Users/shinzui/Keikaku/bokuno/keiro/cabal.project`.
- Write `keiro-dsl/src/Keiro/Dsl/Grammar.hs`. Define the shared declaration ADTs `IdDecl`,
  `EnumDecl`, `RuleDecl`, and the hole types `Derivation`, `Disposition`, `Mapping`,
  `EnvelopeBinding`. Define the `Expr` sublanguage (a recursive ADT with `EOr`/`EAnd`/`ECmp`
  over atoms `ARegister Name | AField Name | AEnumCtor Name | ARule Name | ABool Bool`, where
  `ECmp` carries one of `==`/`!=`/`<`/`<=`/`>`/`>=`). Define the `Aggregate` node — `RegDecl`,
  `Command`, `Event`, `Transition { guard :: Maybe Expr, writes :: [(Name, Expr)], emits ::
  [Name], goto :: Name }`, `WireSpec`, `ProjectionSpec` (carrying the `status-map` as a
  `Mapping`). Define the top-level `Spec` aggregating the context name, the id/enum/rule
  declarations, and the list of nodes (only `Aggregate` for now; the constructor list will
  grow in later plans). Every node and declaration carries a source `SourcePos`/line number
  field so diagnostics can be line-numbered.
- Write `keiro-dsl/src/Keiro/Dsl/Parser.hs` exposing
  `parseSpec :: Text -> Either ParseError Spec` over megaparsec. Implement a small
  whitespace/indentation lexer, then parsers for each declaration. Parse `Expr` with
  `Control.Monad.Combinators.Expr.makeExprParser` (from `parser-combinators`, a megaparsec
  companion) using the precedence table above. Re-export a `ParseError` type alias (a
  rendered `String`/`Text` is acceptable — diagnostics need only display it).
- Write `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` exposing `renderSpec :: Spec -> Text` using
  prettyprinter. Match the canonical layout closely enough that `parse . pretty == id`.
- Write `keiro-dsl/app/Main.hs` with an optparse-applicative command tree. The `parse`
  subcommand reads a file (or stdin), runs `parseSpec`, prints `renderSpec` on success
  (exit 0), and prints the line-numbered parse error to stderr on failure (exit non-zero).
- Write `keiro-dsl/test/Main.hs` (the test driver) with: a unit test asserting that parsing
  `reservation.kdsl` yields an `Aggregate` named `Reservation` with 6 states, 2 commands,
  2 events, and 2 transitions; and a QuickCheck property that for a generated `Spec`,
  `parseSpec (renderSpec s)` returns `Right s`. (Write a small `Arbitrary Spec` generator
  restricted to the aggregate subset; keep field names valid Haskell identifiers.)

Result: `keiro-dsl parse keiro-dsl/test/fixtures/reservation.kdsl` round-trips, and the test
suite passes. Acceptance: see *Validation and Acceptance*, M1.

### Milestone 2 — validator + `check` CLI

Scope: a parsed spec is *valid* only if it passes the cross-cutting structural and
hole-kind rules. Catch the dangerous-by-omission cases before any scaffolding.

Work:

- Write `keiro-dsl/src/Keiro/Dsl/Validate.hs`. Define `Diagnostic` as a structured,
  line-numbered record: `Diagnostic { line :: Int, severity :: Severity, code ::
  DiagnosticCode, message :: Text }` with `Severity = Error | Warning` and a `DiagnosticCode`
  enum naming each rule (so tests match on the code, not the prose). Expose
  `validateSpec :: Spec -> [Diagnostic]` (empty list = valid).
- Implement the cross-cutting checks (each emits a `Diagnostic` with a precise line):
  1. **declared-reference** — every transition's command and every `emit` references a
     declared command/event; every `goto` and the initial state is a declared state.
  2. **reachability** — every non-terminal state is reachable from the initial state by
     following transitions.
  3. **terminal-no-outgoing** — a state marked terminal (`!`) has no outgoing transition.
  4. **guard scope-check** — every atom in a guard `Expr` resolves to a declared register,
     a field of the transition's command, an enum constructor of a declared enum, a declared
     `rule`, or a bool. (This is the "guards range over registers ∪ command fields" rule.)
  5. **status-map totality** — the projection's `status-map` is total over the event set, or
     explicitly marked partial. Deleting the `status-map` line, or omitting an event from it,
     is an error naming the uncovered events.
  6. **clock-free** — no guard or write `Expr` references a wall-clock atom (a reserved set
     of names like `now`/`currentTime`/`wallClock`); deadlines must come from an injected
     timestamp field. (TIME IS INJECTED NOT SAMPLED.)
  Also stub the eight hole-kind **presence** checks: for the aggregate vertical the only
  required hole-kinds are *mapping* (the status-map, rule 5) and — when an `id` carries an
  opaque derivation — *derivation* (a fixture must be present); the dangerous-inversion
  checks for *disposition* are defined here as reusable helpers but not triggered by the
  aggregate node (they fire for EP-3/EP-4 nodes).
- Add the `check` subcommand to `app/Main.hs`: parse, then `validateSpec`; print `OK` and
  exit 0 if the diagnostic list is empty, else print each diagnostic
  (`<file>:<line>: error[<code>]: <message>`) to stderr and exit non-zero.
- Add validator unit tests: the canonical spec passes; per-rule "bad" fixtures each yield the
  expected `DiagnosticCode`.

Result/Acceptance: `check` passes the canonical spec; a status-map-missing fixture and an
undeclared-command fixture each produce a precise, line-numbered diagnostic and a non-zero
exit. See *Validation*, M2.

### Milestone 3 — scaffold engine: symbol-free deterministic layer + typed holes + firewall invariant

Scope: emit, from an `aggregate` node, the symbol-free deterministic layer into `Generated`
modules and typed hole signatures into a hand-owned `Holes.hs`. The scaffolder is a faithful
boilerplate emitter, **not** a symbolic-transducer compiler.

Work:

- Write `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`. Define
  `data ScaffoldModule = ScaffoldModule { modulePath :: FilePath, moduleText :: Text, kind ::
  ModuleKind }` and `data ModuleKind = Generated | HoleStub`. Define `data Context = Context
  { contextName :: Text, moduleRoot :: Text }`. Expose
  `scaffoldAggregate :: Context -> Aggregate -> [ScaffoldModule]`.
- Emit, as `Generated` modules (each beginning with a `-- @generated` line), the layer
  enumerated in *Context and Orientation*: the state enum; per-command/per-event payload
  records and the command/event sums; the id newtypes + `…Text` accessors; the `…Regs`
  type-list and `initial…Regs` `RCons` chain; the `Keiro.Codec`/`Keiro.EventStream`/
  `Keiro.Projection.InlineProjection` wiring; and the two TH splices
  `$(deriveAggregateCtorsAll ''<Cmd> ''<Regs>)` and `$(deriveWireCtorsAll ''<Event>)`. Render
  Haskell as `Text` (string templating is sufficient; no need to depend on a Haskell
  pretty-printing AST library).
- Emit a single `HoleStub` module `Holes.hs` containing: the transducer's full type
  signature (`reservationTransducer :: SymTransducer (HsPred …) … `), a `buildTransducer`
  skeleton whose `B.from`/`B.onCmd`/`B.goto` **structure** is reproduced from the spec's
  transitions, and each `guard`/`write`/`emit` body left as a clearly-marked hole annotated
  with the exact spec `Expr` to encode — for example
  `-- HOLE guard: divertStatus != TotalDivert || lifeCriticalOverride`. Also emit a typed
  hole per relevant hole-kind for this node (a derivation hole when an id needs one). The
  `Holes.hs` module must reference only the `Generated` names; it is where the human/agent
  writes the symbolic operators.
- Add the `scaffold <file> --out <dir>` subcommand to `app/Main.hs`. For each
  `ScaffoldModule`: compute its on-disk path under `--out` from `modulePath`; if `kind ==
  Generated`, overwrite unconditionally; if `kind == HoleStub`, write only if the file does
  not already exist (never overwrite). Create intermediate directories as needed.
- Write the **firewall-invariant test**: scaffold the canonical spec, take every
  `Generated` module's `moduleText`, and assert that **none** contains any of the literal
  keiki symbolic operators `./=`, `.==`, `.||`, `lit `, `B.slot`, `B.requireGuard`. (Match
  on substrings; the surrounding source is generated, so exact-token matching is unnecessary
  and substring matching is stricter.)
- Write the **idempotence test**: run `scaffold` to a temp dir, hand-edit the emitted
  `Holes.hs` (append a sentinel comment), run `scaffold` again to the same dir, and assert
  the sentinel survives (HoleStub create-if-absent) while a `Generated` module's content is
  byte-identical to the first run (Generated overwrite is deterministic).
- Capture the reference fixtures: copy the four hand-written
  `HospitalCapacity/Reservation` modules (`Transducer.hs`, `EventStream.hs`, `Projection.hs`,
  and the shared `Domain/Types.hs` slice they need) into `keiro-dsl/test/fixtures/reference/`
  as read-only text, plus the `reservation.kdsl`. A conformance test scaffolds the spec and
  diffs the `Generated` domain/codec/wiring against the captured reference (modulo whitespace
  and module-name prefix) to confirm the scaffold lines up with real, compiling code.
- Add the smoke target: capture `jitsurei`'s `OrderStream.hs` plus its `Jitsurei.Domain`
  slice as a second fixture pair, write its `.kdsl`, and assert it scaffolds without error.

Result: scaffolding `reservation.kdsl` yields `Generated` modules that compile against
keiro/keiki, plus a `Holes.hs` whose signatures typecheck once filled. Acceptance: see
*Validation*, M3.

### Milestone 4 — harness engine + aggregate conformance (the determinism guarantee)

Scope: the same spec emits the tests that pin the filled holes' behavior. This is where
"deterministic enough" is actually closed, since the tool no longer guarantees the
transducer by construction.

Work:

- Write `keiro-dsl/src/Keiro/Dsl/Harness.hs` exposing
  `harnessFor :: Context -> Aggregate -> [ScaffoldModule]`. Emit a test module that:
  1. asserts `validateTransducer defaultValidationOptions <aggregate>Transducer == []`;
  2. holds **golden wire fixtures** — for each event, an `encode`-then-`decode` round-trip
     assertion plus a pinned wire shape — modeled on the corpus's `test/IdentitySpec.hs`;
  3. holds a **clock-free static assertion** (a test that fails to compile or fails at
     runtime if any guard/write references a clock atom — concretely, a generated check that
     the spec passed the M2 clock-free rule, surfaced as a test).
  Model the emitted module's style on the captured
  `keiro-runtime-jitsurei/.../test/SymbolicSpec.hs` and `IdentitySpec.hs` (read during
  research): a `main :: IO ()` that runs labeled assertions and `exitFailure`s on any miss.
- Hand-fill the captured Reservation `Holes.hs` to match the reference transducer body
  (`B.requireGuard (d.divertStatus ./= lit TotalDivert .|| d.lifeCriticalOverride .== lit
  True)`, the register writes, the emits, the gotos). Show the aggregate compiles and the
  emitted harness is green.
- Add the **mutation test**: programmatically flip a filled guard (`./=` → `.==`) or a
  status-map entry (`held` → `confirmed`) in a copy of the filled module, rebuild, and assert
  a **specific** named harness test goes red — proving the harness, not the scaffold, is what
  pins behavior.

Result: the spec-derived harness for the filled Reservation aggregate is green; a mutation
turns a specific test red. Acceptance: see *Validation*, M4. With M4 complete, EP-1 has
proven the full engine (grammar → parse → validate → scaffold → harness) end-to-end on the
aggregate vertical, and the shared types are frozen as the contract for EP-2…EP-6.


## Concrete Steps

Run everything from the keiro repo root unless stated otherwise:
`/Users/shinzui/Keikaku/bokuno/keiro`. This section shows exact commands with short expected
transcripts; update it with real output as each milestone lands.

### M1 — package skeleton, parse, round-trip

```bash
# 1. Create the package directory and source tree.
mkdir -p keiro-dsl/src/Keiro/Dsl keiro-dsl/app keiro-dsl/test/fixtures

# 2. After writing keiro-dsl.cabal and adding `keiro-dsl` to cabal.project:
cabal build keiro-dsl
# expect: it compiles; the first run resolves megaparsec / parser-combinators /
# optparse-applicative / prettyprinter from Hackage.

# 3. Save the canonical spec (from Context and Orientation) to the fixture, then parse it:
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/reservation.kdsl
```

Expected (the pretty-printed spec echoed back, exit code 0):

```text
context hospital-capacity

id  TransferReservationId  prefix=rsv
...
  projection transfer_decisions consistency=Strong key=reservationId
    status-map { Created=>held Confirmed=>confirmed }
```

```bash
# 4. A non-spec input fails with a line-numbered error and a non-zero exit:
echo "not a spec" | cabal run keiro-dsl -- parse /dev/stdin ; echo "exit=$?"
# expect: a megaparsec error like "1:1: unexpected 'n', expecting \"context\"" on stderr,
#         and: exit=1
```

### M2 — validation

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation.kdsl ; echo "exit=$?"
# expect: "OK" then "exit=0"

# Remove the status-map line, save as reservation-no-statusmap.kdsl:
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-no-statusmap.kdsl ; echo "exit=$?"
```

Expected:

```text
keiro-dsl/test/fixtures/reservation-no-statusmap.kdsl:27: error[StatusMapNotTotal]: projection 'transfer_decisions' status-map is not total over events {TransferReservationCreated, TransferReservationConfirmed}
exit=1
```

```bash
# Referencing an undeclared command in a transition (reservation-bad-command.kdsl):
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-bad-command.kdsl ; echo "exit=$?"
# expect a line-numbered error[UndeclaredCommand] and exit=1
```

### M3 — scaffold + firewall invariant + idempotence

```bash
# Scaffold the rich aggregate (registers + guard + write + status-map).
rm -rf /tmp/gen && cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation.kdsl --out /tmp/gen
find /tmp/gen -name '*.hs' | sort
```

Expected (Generated modules plus the create-if-absent Holes module):

```text
/tmp/gen/Generated/HospitalCapacity/Reservation/Codec.hs
/tmp/gen/Generated/HospitalCapacity/Reservation/Domain.hs
/tmp/gen/Generated/HospitalCapacity/Reservation/EventStream.hs
/tmp/gen/Generated/HospitalCapacity/Reservation/Projection.hs
/tmp/gen/HospitalCapacity/Reservation/Holes.hs
```

```bash
# Confirm the firewall: no Generated module mentions a keiki symbolic operator.
grep -RnE './=|\.==|\.\|\||(^| )lit |B\.slot|B\.requireGuard' /tmp/gen/Generated && echo "FIREWALL BREACH" || echo "firewall OK"
# expect: "firewall OK"

# Confirm the same operators DO appear (as annotations/holes) in the hand-owned module:
grep -n 'HOLE guard' /tmp/gen/HospitalCapacity/Reservation/Holes.hs
# expect: a line like "-- HOLE guard: divertStatus != TotalDivert || lifeCriticalOverride"

# Idempotence: hand-edit Holes.hs, re-scaffold, confirm the edit survives.
echo '-- SENTINEL hand edit' >> /tmp/gen/HospitalCapacity/Reservation/Holes.hs
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation.kdsl --out /tmp/gen
grep -c 'SENTINEL' /tmp/gen/HospitalCapacity/Reservation/Holes.hs
# expect: 1  (the HoleStub was NOT overwritten)
```

```bash
# Run the full test suite (firewall, idempotence, scaffold conformance, smoke target):
cabal test keiro-dsl
```

### M4 — harness (the determinism guarantee)

```bash
cabal test keiro-dsl
# expect: the spec-derived harness for the filled Reservation aggregate is green
#         (validateTransducer == [], golden round-trips pass, clock-free assertion holds).
# Then the mutation test flips a filled guard (./= -> .==) or a status-map entry and asserts
# a SPECIFIC test goes red — proving the harness, not the scaffold, pins behavior.
```

Detailed file-by-file edits (cabal stanzas, module contents, real transcripts) are recorded
here as each file is written. (To be filled during implementation.)


## Validation and Acceptance

Acceptance is behavioral and per-milestone. Each milestone is done only when its block below
passes. All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

**M1 — parsing and round-trip.** The `keiro-dsl` package builds, and:

```bash
cabal test keiro-dsl
# expect a test suite that includes:
#  - a property "parse . pretty round-trips" that passes for generated Specs;
#  - a unit test asserting `parseSpec reservation.kdsl` yields an Aggregate node named
#    "Reservation" with 6 states, 2 commands, 2 events, and 2 transitions.
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/reservation.kdsl   # exit 0, echoes spec
echo "not a spec" | cabal run keiro-dsl -- parse /dev/stdin             # exit != 0, line-numbered error
```

Behavioral proof beyond compilation: the canonical spec written by a human round-trips
through parse → pretty → parse unchanged, and malformed input is rejected with a position.

**M2 — validation.** `check` accepts the canonical spec and rejects each dangerous-omission
fixture with a precise, line-numbered diagnostic:

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation.kdsl            # "OK", exit 0
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-no-statusmap.kdsl   # error[StatusMapNotTotal], exit != 0
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-bad-command.kdsl    # error[UndeclaredCommand], exit != 0
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-clock.kdsl          # error[ClockSampled], exit != 0
cabal test keiro-dsl   # the validator unit tests assert each fixture yields the expected DiagnosticCode
```

Behavioral proof: deleting a required decision (the status-map) or writing a structurally
invalid spec (undeclared command, unreachable state, terminal-with-outgoing, an out-of-scope
guard atom, a clock sample) is caught *before any Haskell is written*.

**M3 — scaffold + firewall + idempotence + conformance.**

```bash
rm -rf /tmp/gen && cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation.kdsl --out /tmp/gen
# The Generated modules compile against keiro/keiki. Verify by building the captured-fixture
# conformance test, which depends on the scaffold output shape:
cabal test keiro-dsl
# expect, among others:
#  - firewall invariant: a test takes every Generated module's text and asserts NONE contains
#    a keiki symbolic operator (./=, .==, .||, lit, B.slot, B.requireGuard);
#  - idempotence: running scaffold twice leaves a hand-edited Holes.hs untouched while the
#    Generated modules are byte-identical across runs;
#  - scaffold conformance: the Generated domain/codec/wiring matches the captured
#    HospitalCapacity/Reservation reference (modulo whitespace + module-name prefix);
#  - smoke target: the register-free OrderStream spec scaffolds without error.
```

Behavioral proof: the generated boilerplate is real, compiling Haskell that lines up with a
hand-written reference, and the firewall guarantees the brittle symbolic surface is never
emitted — re-scaffolding is therefore safe at the Nth edit.

**M4 — harness (the determinism guarantee).**

```bash
cabal test keiro-dsl
# expect: with the captured Reservation Holes.hs hand-filled to match the reference, the
# emitted harness is green — validateTransducer defaultValidationOptions == [], every event's
# encode/decode round-trips, and the clock-free assertion holds.
# Then the mutation test flips the filled guard (./= -> .==) or a status-map entry and asserts
# a SPECIFIC named test goes red.
```

Behavioral proof: the harness — not the scaffold — is what pins behavior. Two agents who fill
the holes differently but correctly both pass; a single wrong guard or mapping fails a named
test. This is the project's actual determinism guarantee, delivered behaviorally.


## Idempotence and Recovery

All M1–M2 steps are pure file creation and compilation; rerunning them is safe. `mkdir -p`
and re-writing source files are idempotent. Adding `keiro-dsl` to `cabal.project` is additive
and touches no existing package.

The scaffolder (M3) is explicitly idempotent for the deterministic layer and non-destructive
for holes — this is the load-bearing safety property, and it matters *more* under
scaffold+verify because the transducer body lives in `Holes.hs`:

- `Generated` modules are **fully overwritten** on every run. Overwriting is deterministic:
  the same spec produces byte-identical output, so re-scaffolding after a spec edit simply
  refreshes the boilerplate.
- `HoleStub` modules (`Holes.hs`) are **created only when absent and never overwritten**. A
  hand-filled transducer body therefore survives every subsequent scaffold. This is verified
  by the idempotence test described in M3 (hand-edit `Holes.hs`, re-scaffold, assert the edit
  survives while a `Generated` module is byte-identical to the prior run).

Recovery paths:

- To re-derive scaffold output from scratch, delete the `--out` directory and re-run
  `scaffold`; only the hand-filled `Holes.hs` is unrecoverable, so back it up before deleting
  if it has been filled.
- To roll back EP-1 entirely, remove the `keiro-dsl/` directory and its line in
  `cabal.project`. Because the change is additive, this leaves every existing keiro package
  exactly as it was.
- If a `cabal build keiro-dsl` fails on a fresh dependency, the cause is almost always a
  Hackage resolution issue for one of the new libraries; re-running after `cabal update` and
  confirming the constraint solver picks GHC-9.12-compatible versions resolves it. None of
  the new deps is used elsewhere in the repo, so they cannot conflict with existing pins.


## Interfaces and Dependencies

New libraries (added only to `keiro-dsl/keiro-dsl.cabal`): `megaparsec` and its companion
`parser-combinators` (parser + the `Expr` precedence table), `optparse-applicative` (CLI),
`prettyprinter` (pretty-printer), plus `base`, `text`, `containers`. The test suite adds
`hspec` + `QuickCheck`. None of `megaparsec`/`optparse-applicative`/`prettyprinter` is yet a
dependency anywhere in keiro (confirmed by `grep -rln` over all `.cabal` files — zero
matches), so they are added fresh to the new package only. No existing keiro package gains a
dependency.

The harness emitter (M4) targets `Keiki.Core.validateTransducer` /
`defaultValidationOptions` / `ValidationOptions` (in the `keiki` package, already a
`cabal.project` `source-repository-package`). The scaffolded wiring targets `Keiro.Codec`,
`Keiro.EventStream`, and `Keiro.Projection.InlineProjection` (in this repo's `keiro`/
`keiro-core` packages). The aggregate scaffolder emits the TH splices
`deriveAggregateCtorsAll` and `deriveWireCtorsAll` from `Keiki.Generics.TH`.

**These module signatures are the integration contract.** EP-2…EP-6 extend them *additively*
— a later vertical adds a `Grammar` constructor, `Validate` rules, and `Scaffold` cases, but
must not re-shape these types. Keep the signatures exactly as written.

Module surface that must exist by the end of each milestone (full paths under
`keiro-dsl/src/`):

- **M1:**
  - `Keiro.Dsl.Grammar` — the AST: `IdDecl`, `EnumDecl`, `RuleDecl`; hole types `Derivation`,
    `Disposition`, `Mapping`, `EnvelopeBinding`; the `Expr` sublanguage; the `Aggregate` node
    (`RegDecl`, `Command`, `Event`, `Transition` with guard/write/emit/goto, `WireSpec`,
    `ProjectionSpec`); and the top-level `Spec` that aggregates all node types (only
    `Aggregate` for now; the node constructor list grows in EP-3…EP-6).
  - `Keiro.Dsl.Parser` exposing `parseSpec :: Text -> Either ParseError Spec`.
  - `Keiro.Dsl.PrettyPrint` exposing `renderSpec :: Spec -> Text`.
  - `keiro-dsl` executable with subcommand `parse`.
- **M2:**
  - `Keiro.Dsl.Validate` exposing the `Diagnostic` type (line-numbered, structured:
    `Diagnostic { line, severity, code, message }` with a `DiagnosticCode` enum) and
    `validateSpec :: Spec -> [Diagnostic]` (empty list = valid). It implements the
    cross-cutting checks: reachability, terminal-no-outgoing, guard `Expr` scope-check over
    registers ∪ command fields, status-map totality, and clock-free.
  - subcommand `check`.
- **M3:**
  - `Keiro.Dsl.Scaffold` exposing
    `scaffoldAggregate :: Context -> Aggregate -> [ScaffoldModule]` where
    `ScaffoldModule = ScaffoldModule { modulePath :: FilePath, moduleText :: Text, kind ::
    ModuleKind }` and `ModuleKind = Generated {- @generated, overwrite -} | HoleStub
    {- create-if-absent -}`, plus the `Context` type. The `Generated` modules must satisfy
    the firewall invariant (no keiki symbolic operator), enforced by a test.
  - subcommand `scaffold <file> --out <dir>`.
- **M4:**
  - `Keiro.Dsl.Harness` exposing `harnessFor :: Context -> Aggregate -> [ScaffoldModule]`
    (test modules: `validateTransducer defaultValidationOptions` + golden wire fixtures +
    clock-free static assertion). Folded into the `scaffold` output or exposed via a
    `harness` subcommand.

How the scope decision narrows the coupling: the scaffolder still emits the chosen
`$(deriveAggregateCtorsAll …)`/`$(deriveWireCtorsAll …)` splices and the wiring that
references TH-produced names, so the deriver choice (recorded in the Decision Log) is part of
the contract. But it does **not** emit the symbolic operator surface (`./=`, `.||`, `lit`,
`B.slot @"…" =:`, `B.requireGuard`), which is the most brittle, fastest-moving coupling. That
surface lives only in hand-owned, harness-checked `Holes.hs`, so a change to keiki's symbolic
operators breaks a *test* (loudly, locally) rather than the *emitter*. The co-location of
keiro-dsl in the keiro repo keeps a deriver/wiring change and the scaffolder change in one
commit.

The captured-fixture corpus convention established here
(`keiro-dsl/test/fixtures/` holding a `.kdsl` plus read-only copies of the hand-written
reference modules from `keiro-runtime-jitsurei`) is reused by every later vertical, which
captures its own slice. EP-7 registers the corpus for agent use.
