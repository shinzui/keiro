---
id: 106
slug: harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering
title: "Harden the keiro-dsl scaffolder: template injection, firewall completeness, collision and stale-module detection, and faithful policy lowering"
kind: exec-plan
created_at: 2026-07-13T18:56:58Z
intention: "intention_01kxed7haee7ja78qm70cc6qm5"
master_plan: "docs/masterplans/15-harden-and-extend-the-keiro-dsl-toolchain-surfaced-by-the-2026-07-dsl-audit.md"
---

# Harden the keiro-dsl scaffolder: template injection, firewall completeness, collision and stale-module detection, and faithful policy lowering

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-dsl scaffold` turns a validated `.keiro` specification into Haskell modules: a
deterministic "generated layer" (files stamped with a `-- @generated` banner, overwritten on
every run) plus hand-owned "hole" modules (created once, never overwritten). Today that
scaffolder can silently betray a spec author in nine distinct ways: spec text can flip quote
parity inside a generated module (template injection); the "firewall" that is supposed to
keep keiki's symbolic operators out of generated modules scans only 6 of keiki's roughly 30
operator exports and diverges from its own unit test; two spec nodes whose module paths
collide silently clobber each other (confirmed: two aggregates named `Thing` pass `check`,
the second one's generated modules win while the first one's hole stub is kept — an
inconsistent scaffold); renamed nodes leave stale generated files on disk forever; every
`keiro-dsl new process` skeleton passes `check` yet scaffolds Haskell that does not parse
(`data SurgeCommand = ()`); `backoff exponential 2s` is silently lowered to a *constant*
backoff; `delay = 5m` is silently lowered to *5 seconds* (a 60x error); an `Int` event field
scaffolds a harness that throws at runtime; a `Text` register's declared initial is silently
replaced with `""`; and the projection status-map is lowered by first-match *suffix*
comparison, so `ReservationUnHeld` can lower to the status meant for `ReservationHeld`.

After this plan, `keiro-dsl scaffold` is all-or-nothing (it refuses — writing *nothing* —
on path collisions, firewall breaches, missing `-- @generated` banners, and un-lowerable
policies), every splice of spec text into generated Haskell is escaped through one shared
contract, every retry/backoff window means what the spec says (`5m` is 300 seconds,
`exponential` is `ExponentialBackoff`), every `new <kind>` skeleton scaffolds code that a
committed conformance suite actually compiles, the conformance pin covers import lines, and
re-scaffolding reports (never deletes) files a previous run produced that the current spec
no longer does. You can see it working by running the exact CLI transcripts and test
commands in "Validation and Acceptance".


## Progress

- [x] (2026-07-13 21:50Z) M1: `Keiro.Dsl.ScaffoldRun` gated pipeline — all-or-nothing writes, provenance on
      `ScaffoldModule`, collision gate, generated-banner gate, firewall verdict moved
      before any write, `--force-generated-overwrite` flag.
- [x] (2026-07-13 21:50Z) M2: canonical firewall surface derived from keiki 0.2's real exports; token-aware
      scanner (string-literal/comment-skipping, maximal-munch symbols, qualified-name
      awareness); import guard; one list shared by CLI and test.
- [x] (2026-07-13 22:00Z) M3: D1 template-injection fix in `payloadExpr` + D8 `Text` register initials
      (quoted-initial grammar, escaped splice, refusal for unsupported register types).
- [x] (2026-07-13 22:00Z) M4: D5 faithful policy lowering — strict `s|m|h` window grammar, shared
      `windowSeconds`, `constant`/`exponential` backoff lowered to the live
      `BackoffSchedule`, refusal of unknown kinds.
- [x] (2026-07-13 22:00Z) M5: D9 exact status-map lowering (fixtures were already updated by EP-104) and D6 harness
      `sampleValue` completeness (Int, vertex; refusal for non-representable types).
- [x] (2026-07-13 22:06Z) M6: D4 skeletons scaffold compiling code — fixed `process` skeleton, new
      `keiro-dsl-conformance-skeletons` suite compiling every skeleton's scaffold, unit
      pin that fresh skeleton scaffolds match the committed suite.
- [x] (2026-07-13 22:06Z) M7: D7 conformance pin includes import lines (sorted-set comparison); committed
      conformance modules regenerated if drift is exposed.
- [x] (2026-07-13 22:16Z) M8: D3 versioned scaffold-run record sidecar + non-deleting
      stale-module report across node renames and layout/module-root flips, with generated
      versus hand-owned guidance and shared-context/spec-path warning.
- [ ] M9: authoring-docs refresh (NOTATION.md/SKILL.md/LOOP.md for every surface changed
      here) + full sweep: unit suite green from `keiro-dsl/`, all conformance suites green.


## Surprises & Discoveries

Pre-implementation research findings that shaped the plan (evidence embedded in Context and
Plan of Work):

- The repository's canonical fixtures themselves rely on the suffix status-map bug:
  `keiro-dsl/test/fixtures/reservation.keiro` line 37 writes
  `status-map { Created=>held Confirmed=>confirmed }` against events named
  `TransferReservationCreated`/`TransferReservationConfirmed`. Moving to exact matching
  (M5) therefore also rewrites fixture keys in `reservation*.keiro`, `subscription.keiro`,
  and `surge-service.keiro`. The *generated arm text* is unchanged (the suffix keys
  happened to resolve to the same statuses), so committed conformance Projection modules
  do not change.
- The firewall verdict is computable before any write: `firewallBreaches` is a pure
  function over in-memory `ScaffoldModule` values, yet `keiro-dsl/app/Main.hs:131-137`
  writes every module *and* the manifest first and only then scans. The fix is a
  reordering, not new machinery.
- Implementation found three legitimate `Keiki.Core` imports omitted from the authored
  firewall allowlist: generated harness modules import `defaultValidationOptions`, `step`,
  and `validateTransducer` to check filled holes. The canonical restricted-import
  allowlist now includes those names alongside `RegFile` and `HsPred`; all other
  `Keiki.Core` names still breach. Evidence: the strengthened unit suite passed 140
  examples with real aggregate and process scaffolds firewall-clean.
- EP-104 had already converted every canonical status-map fixture to exact constructor
  names before EP-106 began. M5 therefore required only the scaffold-side lookup change;
  no fixture or committed Projection output changed. The exact `ReservationHeld` versus
  `ReservationUnHeld` regression and the aggregate conformance suite are green.
- Strengthening the import pin immediately exposed the formatter-only distinction between
  `import qualified Data.Text as T` and GHC2024's postpositive
  `import Data.Text qualified as T`. Import normalization now canonicalizes those two
  spellings while still comparing the imported module and explicit import list. The new
  skeleton suite compiled 31 modules and ran the aggregate harness and workflow-facts
  checks; the unit suite passed 148 examples.
- The stale-path record is an input to filesystem lookups on the next run, so its parser
  now rejects absolute paths and `..` path components in addition to rejecting unknown
  major versions. This keeps a corrupted or hand-edited sidecar from making the stale scan
  inspect paths outside `--out`; forward-compatible unknown header lines remain ignored.

(To be extended during implementation.)


## Decision Log

- Decision: the scaffold CLI becomes all-or-nothing — every refusal gate (collision,
  banner, firewall, un-lowerable policy) runs before the first byte is written.
  Rationale: `firewallBreaches` is pure and the banner/collision checks are read-only, so
  there is no reason to leave poisoned or half-written trees on disk; the audit confirmed
  today's order writes everything (manifest included) before the verdict.
  Date: 2026-07-13.
- Decision: aeson's `(.=)` stays allowed in generated modules; keiki's `Keiki.Builder.(.=)`
  is excluded by an *import guard* (generated modules may never import `Keiki.Builder`,
  `Keiki.Operators`, or `Keiki.Symbolic`, and may import `Keiki.Core` only with an explicit
  list drawn from an allowlist) rather than by token. Rationale: the two operators are
  textually identical; every generated Codec/Contract legitimately uses aeson `(.=)`; the
  only way keiki's version can be *used* is via an import the guard forbids.
  Date: 2026-07-13.
- Decision: `exponential` backoff requires explicit `max=` and `multiplier=` clauses in the
  notation; the scaffolder never invents `ExponentialBackoffOptions` defaults. Rationale:
  the live `Keiro.Outbox.Types.ExponentialBackoffOptions` (keiro/src/Keiro/Outbox/Types.hs:100-105)
  has three load-bearing fields with runtime validation
  (`validateBackoff`, same file :248-258); a made-up `maxDelay`/`multiplier` would be
  silent policy invention — exactly the class of bug this plan removes.
  Date: 2026-07-13.
- Decision: unsupported lowering inputs (unknown backoff kind, exponential without
  `max=`/`multiplier=`, `Text` register with a bare-identifier initial, register/field
  types outside the representable set) are refused by a scaffold-side pre-write gate
  (`scaffoldRefusals`) *and* named as validator rules whose preferred owner is
  docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md.
  Rationale: the two plans must be landable in either order; the scaffold gate keeps this
  plan self-protecting before 104 lands and remains as cheap defense-in-depth after.
  Date: 2026-07-13.
- Decision: stale-file handling reports and never deletes. Rationale: hole modules contain
  hand-written code; generated files may have been adopted (which the banner gate now
  surfaces); a report with explicit per-file guidance is strictly safer and is what the
  audit asked for.
  Date: 2026-07-13.
- Decision: skeleton compile-proof uses the existing conformance-suite architecture (a new
  committed `test/conformance-skeletons` tree compiled by a cabal test stanza, pinned
  byte-wise from the unit suite) rather than invoking GHC from the unit test at runtime.
  Rationale: GHC has no supported stop-after-parse mode; resolving generated imports
  requires the package environment a cabal stanza already provides; this repo already
  proves 17 suites this way.
  Date: 2026-07-13.
- Decision: permit the five `Keiki.Core` names already emitted by generated aggregate and
  harness modules: `RegFile`, `HsPred`, `defaultValidationOptions`, `step`, and
  `validateTransducer`.
  Rationale: the authored plan listed only Domain and EventStream imports, but the existing
  generated Harness is also part of the deterministic layer and legitimately validates and
  steps hand-filled transducers. Restricting it would make every real aggregate scaffold a
  firewall breach; allowing only the observed explicit names preserves the firewall.
  Date: 2026-07-13.
- Decision: model register initials as `RegInitBare Text | RegInitText Text`, where the
  bare form also accepts signed decimal text.
  Rationale: the authored `RegInitIdent` sketch could not represent an `Int` register's
  initial value even though `Int` is explicitly in the supported register set. Keeping one
  bare source token variant covers enum/state/Bool/id placeholders and integer literals;
  the quoted variant preserves the semantic distinction needed to escape `Text` safely.
  Date: 2026-07-13.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What keiro-dsl is and where everything lives

`keiro-dsl` is a Haskell package (directory `keiro-dsl/` at the repo root
`/Users/shinzui/Keikaku/bokuno/keiro`) providing a CLI with subcommands `parse`, `check`,
`scaffold`, `diff`, and `new`. A `.keiro` file is a typed specification of a keiro service
(aggregates, process managers, Kafka contracts/intakes/publishers, pgmq workqueues, durable
workflows). `scaffold` emits Haskell modules of two kinds (`Keiro.Dsl.Scaffold.ModuleKind`):

- **Generated** — deterministic, overwritten every run, first content line after pragmas is
  the banner `-- @generated by keiro-dsl; do not edit. Regenerated from the .keiro spec.`
  (`generatedBanner`, keiro-dsl/src/Keiro/Dsl/Scaffold.hs:1310-1311).
- **HoleStub** — hand-owned modules (e.g. `Holes.hs`) created only when absent.

Key files (all paths repo-relative):

- `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (1382 lines) — every emitter; the firewall
  (`forbiddenOperators` :131-132, `firewallBreaches`/`breachesLine` :140-158).
- `keiro-dsl/src/Keiro/Dsl/Harness.hs` — generated test-harness emitters (`sampleValue`
  :322-329).
- `keiro-dsl/src/Keiro/Dsl/Skeleton.hs` — the `new <kind>` starter specs.
- `keiro-dsl/src/Keiro/Dsl/Manifest.hs` — the Cabal-pasteable build manifest written next
  to the scaffold output.
- `keiro-dsl/src/Keiro/Dsl/Parser.hs`, `Grammar.hs`, `PrettyPrint.hs` — notation.
- `keiro-dsl/app/Main.hs` — the CLI; the scaffold run is `run (Scaffold …)` :106-137 and
  `writeModule` :172-184.
- `keiro-dsl/test/Main.hs` — the unit suite (hspec + QuickCheck). It must be run with
  working directory `keiro-dsl/` (fixture paths are relative).
- `keiro-dsl/test/conformance*/` — 17 committed suites that compile scaffolder output
  against the live keiki/keiro/keiro-pgmq runtime. Example stanza:
  `keiro-dsl-conformance` (keiro-dsl/keiro-dsl.cabal:82-101) compiles
  `test/conformance/Generated/HospitalCapacity/Reservation/*.hs` plus a hand-filled
  `HospitalCapacity/Reservation/Holes.hs`.
- `agents/skills/keiro-dsl-authoring/{SKILL,NOTATION,LOOP,WALKTHROUGH}.md` — the authoring
  skill documentation this plan must keep truthful for every surface it changes.

The **firewall** is the invariant that no Generated module contains a keiki symbolic
operator — those belong only in hand-filled hole modules, so that generated code stays
symbol-free and deterministic. keiki is the pure transducer-core library; its sources live
at `/Users/shinzui/Keikaku/bokuno/keiki` (version 0.2.0.0; keiro-dsl's conformance stanzas
depend on `keiki >=0.2 && <0.3`). Locate it with `mori registry show keiki --full` if the
path differs on another machine.

### Standing assumption

keiro MasterPlan 14
(docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md)
is implemented first; the runtime types referenced here (`Keiro.Outbox.Types`,
`Keiro.PGMQ.Job`, `Keiro.Inbox.Types`) are the post-MP-14 surface. This plan changes ONLY
the `keiro-dsl` package, its tests, and `agents/skills/keiro-dsl-authoring/` docs — never
`keiro`, `keiro-core`, or `keiro-pgmq` runtime code.

### Sibling-plan boundaries

- docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md
  owns **validator** rules, including duplicate-*name* detection (two nodes spelled the
  same in one spec) and the validator side of exact status-map matching. This plan owns
  everything **filesystem-facing**: module-*path* collisions after name sanitization
  (including case-variant clashes), banner protection, stale files, and the scaffold-side
  lowering itself.
- docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md
  owns notation-level string escaping (`stringLit`/`dquoted`) and the `mapPartial`
  concrete syntax. This plan states the same escape contract (below) so either plan can
  land first.

### The shared escape contract (stated identically in docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md)

Any spec-sourced `Text` value spliced into generated Haskell source is rendered exactly as
`T.pack (show t)` renders it — GHC `show @String` escaping (`\"` for a double quote, `\\`
for a backslash, escape codes for control characters), with the surrounding double quotes
added by the renderer, never carried in the stored value. In `Keiro.Dsl.Scaffold` this
renderer is the existing `tshow` (Scaffold.hs:1378-1379). Quote-and-escape happens exactly
once, at the splice site.

### The nine confirmed defects this plan fixes

**D1 — template injection in `payloadExpr`.** `payloadExpr`
(keiro-dsl/src/Keiro/Dsl/Scaffold.hs:732-738) splices a timer payload literal *verbatim*
into the generated Process module: `kv b = tshow (fbName b) <> " .= (" <> maybe "\"\"" id
(fbValue b) <> " :: Value)"`. The parser stores quoted binding values quote-*wrapped*
(`pBindingValue`, keiro-dsl/src/Keiro/Dsl/Parser.hs:1067-1072, returns `"\"" <> s <>
"\""`), and `stringLit` (Parser.hs:1084-1089) accepts any character except `"` — including
a trailing backslash. So `payload { kind="follow-up\" }` splices `("follow-up\" :: Value)`
into Haskell: `\"` escapes the closing quote, quote parity flips, and the rest of the spec
text lands in code position. Every *other* splice site correctly uses `tshow`; this is the
one exception.

**D2 — firewall incompleteness and divergence.** `forbiddenOperators` (Scaffold.hs:131-132)
is `["./=", ".==", ".||", "lit", "B.slot", "B.requireGuard"]`. The unit test checks a
*different* list — `symbolicOperators` (keiro-dsl/test/Main.hs:359-360) adds `.&&` and
spells `lit ` with a trailing space. keiki 0.2 actually exports (verified against
`/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/{Core,Operators,Builder}.hs`): relational
`.< .<= .> .>= .== ./=`, logical `.&& .|| pnot`, arithmetic `.+ .- .*` plus `tadd tsub
tmul`, term builders `lit proj inpCtor matchInCtor pack`, and the whole `Keiki.Builder`
edge-authoring surface (`slot`, `(.=)`, `(=:)`, `reg`, `emit`, `emitWith`, `noEmit`,
`(*:)`, `oNil`, `requireEq`, `requireGuard`, `requireCmp`, `requireLt/Le/Gt/Ge`, `goto`,
`onCmd`, `onEpsilon`, `from`, `buildTransducer`). None of `=:`, the relationals, the
arithmetic operators, or the `B.require*`/`B.reg`/`B.emitWith` surface is scanned. Also,
`breachesLine` word-matches `lit` by splitting on non-alphanumerics (Scaffold.hs:153-158),
so a generated *string literal* like the enum wire spelling `"lit"` (emitted by
`emitEnumParser`, Scaffold.hs:950-957) is a false BREACH. Finally, the CLI writes all
modules and the manifest *before* scanning (app/Main.hs:131-137), so a breach leaves
poisoned files on disk.

**D3 — collisions and staleness.** No path-collision check exists: `scaffoldAggregate`
derives module paths from the node name via `genPrefixFor`/`holePrefixFor`
(Scaffold.hs:104-117) and `writeModule` (app/Main.hs:172-184) just writes in order.
Confirmed repro: a spec with two `aggregate Thing` nodes passes `check` (duplicate-NAME
detection is docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md's gap) and the scaffold silently clobbers — the second
aggregate's Generated modules win while the first's `Holes.hs` stub is kept (HoleStub is
skip-if-present), yielding a scaffold whose generated layer and hole layer describe
*different* aggregates. Case-variant names (`Thing` vs `THING`, or lowercase `thing` —
`ident` admits it) produce distinct paths that collide on case-insensitive filesystems
such as this machine's APFS. Separately: nothing records what a scaffold run produced, so
renaming/removing a node or flipping `layout`/`--module-root` leaves old `-- @generated`
modules and old `Holes.hs` on disk; and a Generated-path overwrite never checks that the
target actually carries the `@generated` banner, so a user who adopted a generated file as
hand code loses edits silently.

**D4 — certified-valid specs that scaffold broken code.** The `new process` skeleton
(keiro-dsl/src/Keiro/Dsl/Skeleton.hs:111-118) ends with two aggregates that have no
commands, events, or transitions. It passes `check` (pinned green by
test/Main.hs:273-275). But `emitSum` (Scaffold.hs:852-864) renders an empty constructor
list as `data SurgeCommand = ()` (Scaffold.hs:860) — not valid Haskell — and
`emitCodecValue` (Scaffold.hs:959-978) renders `eventType = \case` with zero arms plus
`eventTypes = error "no events"` (Scaffold.hs:976-978). The scaffold succeeds; GHC rejects
the output. Eventless contracts have the same problem in `messageTypeOf`
(Scaffold.hs:340-343).

**D5 — silent policy corruption.** The publisher's `backoffExpr` (Scaffold.hs:521-523)
lowers every non-`"constant"` kind to `ConstantBackoff` — the parser accepts any
identifier as the kind (Parser.hs:655-659: `bk <- ident`), so `backoff exponential 2s`
emits a constant policy even though the live `Keiro.Outbox.Types.BackoffSchedule`
(keiro/src/Keiro/Outbox/Types.hs:112-115) has
`ConstantBackoff !NominalDiffTime | ExponentialBackoff !ExponentialBackoffOptions` with
`ExponentialBackoffOptions { initial, maxDelay, multiplier }` (same file :100-105). And
`secondsOf` (duplicated at Scaffold.hs:520 and :635) keeps only leading digits — `delay =
5m` lowers to `RetryDelay 5`, i.e. 5 *seconds* (the pgmq `RetryDelay` is seconds:
`retryDelaySeconds`, keiro-pgmq/src/Keiro/PGMQ/Job.hs:206-209, re-exported from
shibuya-core at Job.hs:146), a 60x error. `pWindow` (Parser.hs:1033-1037) accepts *any*
letters as the unit.

**D6 — harness samples throw for `Int`.** `sampleValue` (Harness.hs:322-329) handles id,
enum, `Bool`, `Text` and otherwise emits `(error "sample: unsupported type Int")` into
`sampleEvent<Ctor>` — a landmine that detonates when the generated harness runs. The full
representable field-type set, per `resolveFieldType` (Scaffold.hs:243-254), is: an
explicit type annotation verbatim, a same-named register's type, a declared id, a declared
enum, the vertex type, else `Text`.

**D7 — conformance pin strips imports.** `assertMatchesCommitted`'s `normalize`
(test/Main.hs:412-434) drops every `import` line before comparing fresh scaffolder output
to the committed `test/conformance/` copies. A module-rename drift in emitted imports
passes the pin; committed copies keep compiling with old imports; the drift only surfaces
on a user's fresh scaffold.

**D8 — `Text` register initials silently replaced.** `regInitialValue`
(Scaffold.hs:900-908) emits `""` for any `Text` register (line 905), discarding the
declared initial; and `pRegDecl` (Parser.hs:322-329) only accepts a bare identifier as the
initial, so there is no way to declare a real `Text` initial at all. Register types outside
{declared id, declared enum, vertex, `Bool`/`Int`-style literal-initial types} splice
`regInitial` raw as an unbound name (the `otherwise` arm) and fail only at GHC.

**D9 — status-map suffix lowering.** `statusFor` (Scaffold.hs:1149) picks the *first* map
pair whose key is a `T.isSuffixOf` the event name. With events `ReservationHeld` and
`ReservationUnHeld` and `status-map { Held => held, UnHeld => available }`,
`ReservationUnHeld` lowers to `"held"`. The validator has the same suffix logic
(docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md owns that side); the two must move to exact matching in lockstep.

### Agreed exact status-map semantics (stated identically in docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md)

A status-map key matches an event if and only if it is `Text`-equal (case-sensitive) to the
event's declared constructor name. Each event maps via at most the single row whose key
equals its name; a key equal to no declared event name is a check-time error (diagnostic
code `StatusMapDanglingKey`, owner docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md); totality means every declared event
appears as a key, unless the map is declared partial (`mapPartial` — concrete syntax owned
by docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md). Whichever of this plan and docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md lands second must
verify its change against the other's already-committed fixtures.


## Plan of Work

Work happens in nine milestones, each independently verifiable. All commands run from
`/Users/shinzui/Keikaku/bokuno/keiro/keiro-dsl` unless stated otherwise.

### Milestone 1 — a gated, all-or-nothing scaffold pipeline

Scope: restructure the scaffold run so every refusal is decided before the first write,
and give modules provenance so refusals can name the offending spec nodes. At the end, the
CLI writes either everything (modules, manifest) or nothing, and refuses on path
collisions and banner violations with diagnostics naming both sides.

Add an `origin :: !Text` field to `ScaffoldModule` (Scaffold.hs:64-69) describing the
producing node, e.g. `aggregate Thing (spec.keiro:15)` — built from the node kind, its
name, and its `Loc` where the grammar node carries one (`aggLoc` etc.; fall back to the
name alone). Update every construction site: `genModule`/`holeModule` (Scaffold.hs:274-288),
`scaffoldProcess`/`scaffoldContract`/`scaffoldIntake`/`scaffoldPublisher`/
`scaffoldWorkqueue`, the three `Harness.hs` emit sites, and the literal `ScaffoldModule`
values in test/Main.hs:281-296 (use `origin = "test"`).

Create `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` (add to `exposed-modules`; add `directory`
and `filepath` to the library's `build-depends`) with a pure planning half and an IO
execution half (signatures in "Interfaces and Dependencies"). The pure half computes, from
the full `[ScaffoldModule]`:

1. **Collision gate.** Group modules by `T.toLower . T.pack . modulePath` (case-folded, so
   APFS-style case-insensitive clashes are caught even when developing on a
   case-sensitive filesystem). Any group of two or more is a refusal that lists the path
   once and each colliding module's `origin`. This also catches a Generated path colliding
   with a HoleStub path.
2. **Firewall gate.** The (M2) scanner over Generated modules — pure, so it now runs
   before any write. On breach the CLI prints the existing `firewall: BREACH` report shape
   and writes nothing.
3. **Lowering-refusal gate.** `scaffoldRefusals :: Spec -> [Text]` (new, in
   `Keiro.Dsl.Scaffold`) — the D5/D8/D6 spec conditions the emitters cannot lower
   faithfully (enumerated in M3-M5). These duplicate validator rules whose preferred owner
   is docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md; keep them so this plan is self-protecting regardless of landing
   order.

The IO half then runs the **banner gate**: for every Generated module whose target file
already exists, read it; if no line begins with `-- @generated`, refuse (naming each file)
unless the new `--force-generated-overwrite` switch was passed. Only after all four gates
pass does it write modules (same `Generated`-overwrite / `HoleStub`-skip discipline as
today's `writeModule`), then the manifest, then the M8 record, then print the report.
Rewire `run (Scaffold …)` in app/Main.hs:106-137 onto this pipeline; the success report
format is unchanged except for the new `stale:` section (M8).

Tests (test/Main.hs, new `describe "scaffold gates"`): the duplicate-`Thing` spec plans to
a collision refusal naming both origins; a case-variant pair (`Thing`/`THING`) refuses; a
firewall-breaching synthetic module refuses with nothing in the plan's write set; banner
gate covered by an hspec temp-dir test (add `directory`/`filepath` to the test stanza's
`build-depends`) — pre-create the Generated target without the banner, assert refusal and
that the file is untouched; with the banner, assert overwrite proceeds.

Acceptance: the "collision refusal" and "banner refusal" transcripts under Validation
reproduce exactly; `cabal test keiro-dsl-test` green.

### Milestone 2 — the canonical firewall surface and token-aware scanner

Scope: one canonical description of keiki's forbidden surface, exported from
`Keiro.Dsl.Scaffold`, consumed by both the CLI scan and the unit test; a scanner that
cannot be fooled by string literals or fail on substrings.

Replace `forbiddenOperators`/`breachesLine` with a `FirewallSurface` value (shape in
"Interfaces and Dependencies") whose contents — derived from keiki 0.2's actual exports
enumerated in Context — are:

- `forbiddenSymbolic` (matched as complete, maximal-munch symbol tokens):
  `.==`, `./=`, `.<`, `.<=`, `.>`, `.>=`, `.&&`, `.||`, `.+`, `.-`, `.*`, `=:`, `*:`.
  Maximal munch means `x .<= y` yields the single token `.<=` (no false `.<` hit) and
  aeson's `.:`, `<$>`, `<*>`, `::`, `->`, `!` never match. `.=` is deliberately absent
  (aeson's `.=` is legitimate in every generated codec); keiki's `Builder.(.=)` is closed
  off by the import guard below.
- `forbiddenIdents` (complete unqualified identifier tokens): `lit`, `pnot`, `tadd`,
  `tsub`, `tmul`. (`pack`, `proj`, `inpCtor`, `matchInCtor` are excluded: they are
  common-vocabulary or appear qualified as `T.pack` in generated code; the import guard
  covers their keiki versions.)
- `forbiddenQualifiers`: any token qualified as `B.<anything>` — this subsumes `B.slot`,
  `B.requireGuard`, `B.requireEq/Cmp/Lt/Le/Gt/Ge`, `B.reg`, `B.emit`, `B.emitWith`,
  `B.noEmit`, `B.goto`, `B.onCmd`, `B.onEpsilon`, `B.from`, `B.buildTransducer`. Generated
  modules never alias any import as `B`.
- `forbiddenImports`: `Keiki.Builder`, `Keiki.Operators`, `Keiki.Symbolic` — any import of
  these in a Generated module is a breach.
- `restrictedImports`: `Keiki.Core` may be imported only with an explicit import list
  whose names are within `{RegFile, HsPred, defaultValidationOptions, step,
  validateTransducer}`. Domain and EventStream use the first two; the generated Harness
  uses the final three to validate and step hand-filled transducers. `Keiki.Generics.TH`
  stays freely importable (the Domain module's TH derives).

The scanner (`firewallBreaches`, same name and result shape `[(FilePath, Text, Int)]` so
the CLI report code is unchanged) tokenizes each line: a `"` opens a string literal
consumed to the matching unescaped `"` honoring `\\` and `\"` (sound because after M3
every splice is `tshow`-escaped); a symbol run beginning `--` (dashes only, per the
Haskell line-comment rule) skips the rest of the line; identifier tokens are maximal runs
of alphanumeric/`_`/`'` glued across `.` to their qualifier when the segment before the
dot starts uppercase (so `T.pack` is one token, distinct from `pack`); symbol tokens are
maximal runs of Haskell symbol characters. Membership against the surface above yields
breaches; import-guard violations are reported with the pseudo-operator name
`import:<module>`.

Delete `symbolicOperators` from test/Main.hs:358-360; the test imports the canonical
surface instead. Keep and extend the pins at test/Main.hs:281-296: `"lit"` *inside a
string literal* is clean (the D2 false positive: an enum with wire spelling `lit`
scaffolds with `firewall: OK`); `x =: y`, `a .< b`, `import Keiki.Builder`, and
`import Keiki.Core (lit)` in a synthetic Generated module each breach; the real
aggregate + process fixture scaffolds stay breach-free (test/Main.hs:293-296).

Acceptance: `cabal test keiro-dsl-test` green; scaffolding
`test/fixtures/reservation.keiro` still reports `firewall: OK`.

### Milestone 3 — escape the last unescaped splice (D1) and real `Text` register initials (D8)

Scope: after this milestone no spec text reaches generated Haskell unescaped, and a `Text`
register's declared initial survives into the generated `RegFile`.

`payloadExpr` (Scaffold.hs:732-738): a literal binding (currently detected by the stored
value's leading quote) is spliced as `tshow (stripWrappingQuotes v)` — quote-and-escape
exactly once at the splice site, per the shared escape contract. A payload literal ending
in a backslash now renders as `"follow-up\\"` and the module parses. If
docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md lands first and changes `FieldBinding` storage to unquoted-with-marker,
the same splice-site `tshow` call is the contract; only the strip step drops out.

`pRegDecl` (Parser.hs:322-329): accept `initial <- (RegInitBare <$> (ident <|>
signedDecimalText)) <|> (RegInitText <$> stringLit)` — extend `RegDecl`
(Grammar.hs:244-248) so a quoted initial
is distinguishable from a bare identifier (store the *inner* text; `PrettyPrint` re-quotes
via its `dquoted`, which docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md makes escaping-aware — coordinate but do not
duplicate). `regInitialValue` (Scaffold.hs:900-908): the `Text` arm emits
`tshow initialText` when the initial is quoted. Round-trip: the QuickCheck `genReg`
(test/Main.hs:483) gains a quoted-initial case only if docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md's escaping has
landed; otherwise pin round-trip with a unit example using escape-free text.

`scaffoldRefusals` entries (mirrored as validator-rule candidates for
docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md, codes in parentheses): a `Text` register with a bare-identifier
initial (`RegTextInitialNotQuoted`); a register whose type is not a declared id, declared
enum, the vertex type, `Text`, `Int`, or `Bool` (`RegTypeUnsupported`); an enum-typed
register whose initial is not one of that enum's constructors (`RegInitialNotEnumCtor`).
Record in the plan docs that an id-typed register's initial is a conventional placeholder:
`regInitialValue` emits `(TheId "")` regardless (Scaffold.hs:903), and the skeletons write
`= placeholder` for exactly this reason — unchanged here, now documented in NOTATION.md.

Tests: unit pins that (a) a process spec with `payload { kind="x\" }` scaffolds a Process
module whose text contains `"x\\"` and has balanced quotes (assert the emitted line equals
the expected escaped form), (b) `note Text = "hello world"` emits
`RCons (Proxy @"note") "hello world"`, (c) each refusal fires.

Acceptance: the D1 before/after transcript under Validation; `cabal test keiro-dsl-test`
green; conformance suites untouched (no fixture uses these shapes yet).

### Milestone 4 — faithful policy lowering: windows and backoff (D5)

Scope: `5m` means 300 seconds everywhere a window is lowered, and every spelled backoff
kind lowers to the matching live constructor or is refused.

`pWindow` (Parser.hs:1033-1037): restrict the unit to exactly `s`, `m`, or `h`
(megaparsec `choice` + `notFollowedBy letterChar`), failing otherwise with
`expecting time unit: s, m, or h`. This turns previously silently-corrupted inputs
(`5xyz`, `5min`) into parse errors — intended.

Add `windowSeconds :: Text -> Either Text Int` to `Keiro.Dsl.Scaffold` (exported; spec in
"Interfaces and Dependencies") and use it at every lowering site, replacing both
`secondsOf` copies: publisher backoff (Scaffold.hs:520-523), workqueue
`defaultRetryDelay` (:623), the disposition fallback (:633), and per-row `IRetry` windows
(:637). Intake disposition windows are currently *not* lowered into generated code
(`emitIntakeGen`'s `ackFor`, Scaffold.hs:465-476, drops them) — note this in the module
haddock; the strict `pWindow` grammar still protects those rows for any future lowering.

Backoff: extend `BackoffSpec` (Grammar.hs:660-663) with `boMax :: Maybe Text` and
`boMultiplier :: Maybe Text`; parse optional `max=<window>` and `multiplier=<decimal>`
after the window in the publisher block (Parser.hs:655-659); render them in
PrettyPrint.hs:188 when present (the QuickCheck round-trip property generates only
aggregate nodes, test/Main.hs:554-563, so no generator change is forced; add a unit
round-trip example). Lower in `backoffExpr`:

- `constant` → `ConstantBackoff <windowSeconds boWindow>` (a `NominalDiffTime` numeric
  literal — `ConstantBackoff 120` for `2m`).
- `exponential` → `ExponentialBackoff ExponentialBackoffOptions { initial = <windowSeconds
  boWindow>, maxDelay = <windowSeconds boMax>, multiplier = <boMultiplier> }`, and add
  `ExponentialBackoffOptions (..)` to the generated import at Scaffold.hs:508.
- anything else → unreachable at emit time because `scaffoldRefusals` refuses first.

`scaffoldRefusals` entries (validator-rule candidates for docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md):
`BackoffUnknownKind` (kind not `constant`/`exponential`), `BackoffExponentialIncomplete`
(`exponential` missing `max=` or `multiplier=`), `BackoffInvalidExponential` (multiplier
does not parse as a decimal `>= 1`, or `max` window `<` initial window — mirroring the
runtime's `validateBackoff`, keiro/src/Keiro/Outbox/Types.hs:248-258).

Tests: unit pins that `backoff constant 2m` emits `ConstantBackoff 120`; that
`backoff exponential 2s max=60s multiplier=2.0` emits the exact `ExponentialBackoff`
record text; that `delay = 5m` in a workqueue emits `RetryDelay 300`; that
`backoff exponential 2s` (no `max=`) is refused; that `5x` fails to parse naming the unit
set. Existing fixtures all use `s` windows at the lowered sites (e.g.
`test/fixtures/reservation-work.keiro`, `emit.keiro`), so committed conformance modules
(`test/conformance-queue`, `-publisher-runtime`) are byte-stable — assert by running those
suites.

Acceptance: the D5 before/after transcript under Validation; `cabal test keiro-dsl-test
keiro-dsl-conformance-queue keiro-dsl-conformance-publisher-runtime` green.

### Milestone 5 — exact status-map lowering (D9) and total harness samples (D6)

Scope: status lowering keys on exact event names, and every representable field type gets
a valid generated sample.

`statusFor` (Scaffold.hs:1141-1154): replace the suffix scan at :1149 with
`lookup (rcName e) pairs`. Semantics exactly as stated in Context ("Agreed exact
status-map semantics") — in lockstep with docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md's validator change; whichever
plan lands second verifies against the other's committed fixtures. Update every fixture
that uses suffix keys to full event names: `test/fixtures/reservation.keiro:37` (and its
`reservation-*.keiro` siblings) become
`status-map { TransferReservationCreated=>held TransferReservationConfirmed=>confirmed }`;
`test/fixtures/subscription.keiro:29` and `test/fixtures/surge-service.keiro:46,60`
likewise. The generated Projection arm text is unchanged (the suffix keys resolved to the
same statuses), so `test/conformance/Generated/HospitalCapacity/Reservation/Projection.hs`
does not change — assert with the committed-pin test. Add a regression pin: an aggregate
with events `ReservationHeld`/`ReservationUnHeld` and map
`{ ReservationHeld=>held ReservationUnHeld=>available }` lowers `ReservationUnHeld {} ->
Just "available"` (this exact spec, under today's code, produces `Just "held"` — the bug).

`sampleValue` (Harness.hs:322-329): add `Int` → `0` and vertex → `initialVertex a` (the
type mapping in `resolveFieldType`, Scaffold.hs:243-254, admits exactly: explicit
annotations, register types, ids, enums, the vertex type, `Text` fallback). Any other
explicit annotation on an aggregate command/event field is a `scaffoldRefusals` entry
(`FieldTypeUnrepresentable`; validator-rule candidate for docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md) — today such
a field already fails at GHC with no import for its type, so refusing at scaffold is
strictly earlier, not stricter.

Tests: unit pin that an aggregate with `event CountBumped { count:Int }` emits
`sampleEventCountBumped = (CountBumped (CountBumpedData 0))` and that the emitted harness
text contains no `sample: unsupported`; compile-level coverage comes from M6 (the
skeleton conformance aggregate carries an `Int` field).

Acceptance: `cabal test keiro-dsl-test keiro-dsl-conformance` green (the committed
Projection pin proving no drift).

### Milestone 6 — skeletons that scaffold compiling code (D4)

Scope: every `keiro-dsl new <kind>` output passes `check` AND scaffolds modules that a
committed conformance suite compiles.

Fix `processSkeleton` (Skeleton.hs:77-118): replace the two empty stub aggregates
(:111-118) with minimal *complete* aggregates that also declare the commands the process
references (so the skeleton stays valid after docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md's cross-reference rules
land): `Surge` declares `command NoteSurgeThreshold { hospitalId availableIcuBeds:Int
redDemand:Int timerId }`, `command MarkSurgeTimerFired { hospitalId timerId }`, matching
events via `= fields(...)`, states `Watching Fired!`, and transitions
`Watching -- NoteSurgeThreshold --> … goto Watching` and `Watching -- MarkSurgeTimerFired
--> … goto Fired`; `Hospital` declares `command ActivateSurge { hospitalId }`, one event,
states `Operational Surging!`, one transition. Verify the exact text with
`cabal run keiro-dsl -- check` while implementing — the acceptance is behavioral (checks
clean, scaffolds to compiling code), not this precise wording. Give the `aggregate`
skeleton's `Thing` an `Int` field (e.g. `command DoThing { thingId attempt:Int }`) so M5's
Int sample is compile-covered. Keep `emitSum`'s empty arm (Scaffold.hs:860) but make it
emit a compilable placeholder (`data X = XUnused deriving …` is NOT wanted — instead leave
it, because after this milestone it is unreachable from valid specs: state as an
invariant, and name the validator rules that guarantee it — `AggregateEmpty` (an aggregate
must declare at least one command, one event, and one transition) and `ContractEmpty` (a
contract must declare at least one event) — preferred owner docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md, mirrored
in `scaffoldRefusals` here so the guarantee holds in either landing order).

Create `test/conformance-skeletons/` + cabal stanza `keiro-dsl-conformance-skeletons`
(`build-depends`: aeson, base, keiki, keiro, keiro-pgmq, text, time, uuid — the union of
what the seven distinct skeletons' generated modules import). Populate it by scaffolding
each *distinct* skeleton text (aggregate, process, contract, intake, emit/publisher,
workqueue/dispatch, workflow/operation — the pairs share text, Skeleton.hs:38-48) with a
per-kind `--module-root` (`SkelAggregate`, `SkelProcess`, `SkelContract`, `SkelIntake`,
`SkelEmit`, `SkelQueue`, `SkelWorkflow`) so the two `myContract` declarations (contract vs
intake skeletons) cannot collide. Hand-fill the three aggregate `Holes.hs` (Thing, Surge,
Hospital — trivial transducers against the generated signatures). `Main.hs` runs Thing's
`harnessAssertions` and asserts the workflow facts list is non-empty. Then add the unit
pin in test/Main.hs: for every skeleton kind, scaffold in-process with the matching
`Context` and byte-compare each Generated module against the committed copy using M7's
normalize — this makes "every skeleton scaffolds to compiling code" a standing regression,
because the committed copies are exactly what the new suite compiles.

Acceptance: the D4 before/after transcript under Validation;
`cabal test keiro-dsl-conformance-skeletons` green; `cabal test keiro-dsl-test` green
(skeleton-validity pin at test/Main.hs:273-279 still green, plus the new byte pin).

### Milestone 7 — the conformance pin covers imports (D7)

Scope: import drift between the scaffolder and the committed conformance modules turns the
unit suite red.

Rework `normalize` (test/Main.hs:424-434): partition lines into imports and body; compare
the body exactly as today (comma-spacing + word normalization); compare imports as a
*sorted list* of whitespace-normalized lines (sorting preserves the original rationale —
fourmolu may reorder imports in committed copies — while a renamed/added/removed import
now fails). Run `cabal test keiro-dsl-test`; if the strengthened pin exposes drift,
regenerate the committed copies with the CLI (command below; `Holes.hs` is skip-if-present
so hand-filled holes are safe) and re-run the conformance suites to prove the regenerated
copies compile. Apply the same normalize to the M6 skeleton pin.

Acceptance: a deliberate one-line import edit in
`test/conformance/Generated/HospitalCapacity/Reservation/Codec.hs` makes
`cabal test keiro-dsl-test` fail naming that module (revert after observing);
`cabal test keiro-dsl-conformance` green.

### Milestone 8 — scaffold-run record and stale-module report (D3 staleness)

Scope: a re-scaffold tells you which files a previous run produced that this run no longer
does — including across `layout`/`--module-root` flips — and never deletes anything.

Add `Keiro.Dsl.ScaffoldRecord` (exposed; plain-text format because the keiro-dsl library
deliberately has no aeson dependency — format in "Interfaces and Dependencies"). The
record file `keiro-dsl-scaffold-record.<context>.txt` sits next to the manifest in
`--out` (the manifest path today: app/Main.hs:133). `ScaffoldRun`'s execution half reads
any existing record before writing; **stale** = a recorded relative path that is absent
from the current emission set and still exists on disk under `--out`. Because staleness is
a pure set difference on recorded paths, a `layout` or `--module-root` flip (which changes
every path) is automatically covered. After a successful write pass, the record is
rewritten wholesale for the current run. The report is a `stale:` stderr section —
generated files annotated "safe to delete", holes "hand-owned, review before deleting" —
and does not change the exit code. If the record's `spec:` line differs from the current
spec path, prepend a note: two specs sharing one context in one `--out` now ping-pong loud
stale reports (and their shared manifest is called out) instead of silently clobbering.

Tests: hspec temp-dir scenarios — scaffold, rename the aggregate in the spec, re-scaffold,
assert the report names the old `Domain.hs`/`Holes.hs` paths and that the files still
exist; flip `--module-root`, assert the entire old tree is reported; assert a fresh `--out`
produces no `stale:` section and a well-formed record.

Acceptance: the stale-report transcript under Validation reproduces; `cabal test
keiro-dsl-test` green.

### Milestone 9 — authoring-docs refresh and full sweep

Scope: the skill documentation stops overclaiming and covers every surface this plan
changed; the whole package is green.

Update `agents/skills/keiro-dsl-authoring/NOTATION.md`: window grammar is `digits + s|m|h`
with meaning in seconds/minutes/hours; `backoff exponential <initial> max=<window>
multiplier=<decimal>`; status-map keys are exact event constructor names (with the
dangling-key/totality rules and their owner); quoted `Text` register initials and the
id-register placeholder convention; the representable field-type set. Update `SKILL.md`
and `LOOP.md`: the scaffold's refusal modes (collision, banner, firewall, lowering) with
their exit-1 semantics, `--force-generated-overwrite`, and the stale report (what to do
with each annotation). `WALKTHROUGH.md`: only if its transcripts show changed output.
Do not restructure the skill — docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md
owns the full refresh; this milestone only keeps the surfaces this plan touched truthful.

Final sweep: from `keiro-dsl/`, run the unit suite and all conformance suites (list under
Validation) and paste the passing summary into Outcomes & Retrospective.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro/keiro-dsl` (the unit suite
requires this cwd — fixture paths are relative).

Build and baseline before touching anything (all 17 conformance suites plus the unit
suite pass at baseline):

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test --test-show-details=direct
```

Reproduce the headline defects to know what "before" looks like (transcripts under
Validation):

```bash
mkdir -p /tmp/keiro-dsl-demo
printf 'context my-service\n\nid ThingId prefix=thing\n\naggregate Thing\n  regs\n    thingId ThingId = placeholder\n    state ThingVertex = Pending\n  states Pending Done!\n\n  command DoThing { thingId }\n  event ThingDone { thingId }\n\n  Pending -- DoThing -->\n    write state := Done\n    emit ThingDone\n    goto Done\n\naggregate Thing\n  regs\n    thingId ThingId = placeholder\n    state ThingVertex = Pending\n  states Pending Stuck!\n\n  command DoThing { thingId }\n  event ThingStuck { thingId }\n\n  Pending -- DoThing -->\n    emit ThingStuck\n    goto Stuck\n' > /tmp/keiro-dsl-demo/dup.keiro
cabal run keiro-dsl -- check /tmp/keiro-dsl-demo/dup.keiro          # prints OK today (B9)
cabal run keiro-dsl -- scaffold /tmp/keiro-dsl-demo/dup.keiro --out /tmp/keiro-dsl-demo/out
cabal run keiro-dsl -- new process > /tmp/keiro-dsl-demo/p.keiro
cabal run keiro-dsl -- check /tmp/keiro-dsl-demo/p.keiro            # OK
cabal run keiro-dsl -- scaffold /tmp/keiro-dsl-demo/p.keiro --out /tmp/keiro-dsl-demo/skel
grep -n 'data SurgeCommand' /tmp/keiro-dsl-demo/skel/Generated/MyService/Surge/Domain.hs
```

Expected today (the bugs): the dup scaffold succeeds, `Generated/MyService/Thing/*.hs`
holds the *second* aggregate's code while `MyService/Thing/Holes.hs` is the *first*'s
stub; the grep prints `data SurgeCommand = ()`.

Then implement milestone by milestone, running after each:

```bash
cabal build keiro-dsl && cabal test keiro-dsl-test --test-show-details=direct
```

Regenerating committed conformance copies when M7 (or a deliberate emitter change)
requires it — `Holes.hs` is create-if-absent so hand-filled holes survive:

```bash
cabal run keiro-dsl -- scaffold test/fixtures/reservation.keiro --out test/conformance
cabal test keiro-dsl-conformance
```

Populating the M6 skeleton suite (repeat per distinct kind with its module root):

```bash
cabal run keiro-dsl -- new aggregate > /tmp/keiro-dsl-demo/skel-aggregate.keiro
cabal run keiro-dsl -- scaffold /tmp/keiro-dsl-demo/skel-aggregate.keiro \
  --out test/conformance-skeletons --module-root SkelAggregate
```

Final sweep:

```bash
cabal test keiro-dsl-test keiro-dsl-conformance keiro-dsl-conformance-coldstart \
  keiro-dsl-conformance-contract keiro-dsl-conformance-queue \
  keiro-dsl-conformance-queue-runtime keiro-dsl-conformance-publisher-runtime \
  keiro-dsl-conformance-process keiro-dsl-conformance-process-runtime \
  keiro-dsl-conformance-workflow keiro-dsl-conformance-skeletons
# then the remaining -full/-runtime suites (intake-runtime, intake-full, dispatch-full,
# workflow-runtime, workflow-full, process-full, v2) — all must pass.
```


## Validation and Acceptance

Every acceptance below is a behavior with exact inputs and observable outputs. Regressions
are pinned in `keiro-dsl/test/Main.hs` and the conformance suites as described per
milestone.

**Collision refusal (M1).** With `/tmp/keiro-dsl-demo/dup.keiro` from Concrete Steps:

```text
$ cabal run keiro-dsl -- scaffold /tmp/keiro-dsl-demo/dup.keiro --out /tmp/keiro-dsl-demo/out2
error: module path collision — refusing to scaffold; nothing was written
  Generated/MyService/Thing/Domain.hs
    from aggregate Thing (/tmp/keiro-dsl-demo/dup.keiro:5)
    from aggregate Thing (/tmp/keiro-dsl-demo/dup.keiro:18)
  … (one block per colliding path: Codec, EventStream, Projection, Harness, Holes)
$ echo $?
1
$ ls /tmp/keiro-dsl-demo/out2
ls: /tmp/keiro-dsl-demo/out2: No such file or directory
```

(Exact line numbers depend on the heredoc; the requirement is that both origins are named
and the out directory receives nothing — not even the manifest.) Case-variant collisions
(`Thing` vs `THING`) refuse identically.

**Banner refusal (M1).** Pre-create a bannerless file at a Generated path, re-scaffold:

```text
error: refusing to overwrite 1 file at a Generated path that lacks the '-- @generated' banner
  Generated/MyService/Thing/Domain.hs
  (adopted as hand code? move it, or re-run with --force-generated-overwrite)
nothing was written
```

Exit 1; the file's bytes are untouched. With `--force-generated-overwrite` the run
proceeds and reports normally.

**Firewall (M2).** Scaffolding `test/fixtures/reservation.keiro` still ends with
`firewall: OK (5 generated modules scanned, 0 forbidden operators)`. The unit suite pins:
an enum wire spelling `"lit"` scaffolds clean (today's scanner false-positives on it); a
synthetic Generated module containing `x =: y` or `import Keiki.Builder` breaches; on any
breach the pipeline refuses before writing (asserted at the `planScaffold` level: the plan
is `Left`, so no write set exists).

**Template injection (M1+M3).** Before, with `payload { kind="follow-up\" hospitalId }`
in a process spec, the generated Process module contains
`payload = object [ "kind" .= ("follow-up\" :: Value) ]` — unbalanced quotes, spec text in
code position, `firewall: OK`, exit 0. After: the same spec scaffolds
`"kind" .= ("follow-up\\" :: Value)` — balanced, meaning-preserving. Pinned by unit test.

**Faithful lowering (M4).** Before/after generated text for
`backoff exponential 2s` (with `max=60s multiplier=2.0` added after — the old spelling
without them is refused):

```diff
-publisherBackoff :: BackoffSchedule
-publisherBackoff = ConstantBackoff 2
+publisherBackoff :: BackoffSchedule
+publisherBackoff = ExponentialBackoff ExponentialBackoffOptions { initial = 2, maxDelay = 60, multiplier = 2.0 }
```

and for a workqueue `retry maxRetries = 3 delay = 5m dlq = on`:

```diff
-    , defaultRetryDelay = RetryDelay 5
+    , defaultRetryDelay = RetryDelay 300
```

`backoff sideways 2s` and `backoff exponential 2s` (incomplete) exit 1 naming
`BackoffUnknownKind` / `BackoffExponentialIncomplete`; `delay = 5x` is a parse error
naming the `s|m|h` unit set. All pinned by unit tests.

**Exact status-map (M5).** The `ReservationHeld`/`ReservationUnHeld` pin: under the old
code `ReservationUnHeld {} -> Just "held"`; after, `-> Just "available"`. The committed
`test/conformance/Generated/HospitalCapacity/Reservation/Projection.hs` is byte-stable
across the change (suffix keys in the fixture are rewritten to full names; same statuses).

**Skeletons compile (M6).** Before:

```text
$ cabal run keiro-dsl -- new process > p.keiro && cabal run keiro-dsl -- check p.keiro
OK
$ cabal run keiro-dsl -- scaffold p.keiro --out skel && grep 'data SurgeCommand' skel/Generated/MyService/Surge/Domain.hs
data SurgeCommand = ()
```

(GHC rejects `()` as a data constructor.) After: the grep finds
`data SurgeCommand = NoteSurgeThreshold !NoteSurgeThresholdData` (or equivalent), and
`cabal test keiro-dsl-conformance-skeletons` compiles every skeleton's committed scaffold
and passes; the unit pin proves fresh scaffolds match those committed modules.

**Import pin (M7).** Editing one import line in a committed conformance module makes
`cabal test keiro-dsl-test` fail on the `matches the committed compiling Generated
conformance modules` example, naming the module; reverting restores green.

**Stale report (M8).** Scaffold, rename `aggregate Thing` to `aggregate Widget` in the
spec, re-scaffold into the same `--out`:

```text
stale: 6 file(s) from a previous scaffold of context my-service are no longer produced by this spec:
  generated Generated/MyService/Thing/Domain.hs   (safe to delete; still on disk)
  generated Generated/MyService/Thing/Codec.hs    (safe to delete; still on disk)
  … (EventStream, Projection, Harness)
  hole      MyService/Thing/Holes.hs              (hand-owned — review before deleting)
note: keiro-dsl never deletes files.
```

Exit 0; every listed file still exists; the record now lists only the Widget paths.

**Full sweep (M9).** All suites listed in Concrete Steps pass from `keiro-dsl/`; the unit
suite output ends `0 failures`.


## Idempotence and Recovery

Every milestone is additive and re-runnable. Scaffold demos write only under
`/tmp/keiro-dsl-demo`; delete the directory to reset. The scaffold pipeline itself becomes
idempotent-by-construction: gates run before writes, Generated files are deterministic
overwrites, holes are skip-if-present, and the record/manifest are wholesale rewrites — so
re-running a successful scaffold is a no-op-equivalent, and re-running a refused scaffold
changes nothing on disk. Regenerating committed conformance copies is safe to repeat (the
scaffolder is deterministic — pinned by the existing `is deterministic` unit tests,
test/Main.hs:315-318); if a regeneration goes wrong, `git checkout -- keiro-dsl/test/`
restores the committed state. Fixture edits (M5 status-map keys) are guarded by the unit
suite: a wrong key spelling turns `accepts the canonical reservation.keiro` red. If a
milestone must be abandoned mid-way, the package still builds because each edit set keeps
`cabal build keiro-dsl` green before its tests are extended; commit at each milestone
boundary (conventional commits, e.g. `fix(keiro-dsl): escape payload literal splice`).


## Interfaces and Dependencies

Dependencies: no new Hackage packages beyond adding `directory` and `filepath` to the
keiro-dsl *library* and *test* stanzas (both already in the executable's dependencies,
keiro-dsl/keiro-dsl.cabal:53-63). The new conformance suite depends only on packages other
suites already use (aeson, keiki, keiro, keiro-pgmq, text, time, uuid). The keiro-dsl
library deliberately gains no aeson/JSON dependency — the scaffold record is plain text.

At the end of the milestones these interfaces exist (full module paths; signatures are the
contract, minor naming latitude allowed if kept consistent):

In `Keiro.Dsl.Scaffold`:

```haskell
data ScaffoldModule = ScaffoldModule
    { modulePath :: !FilePath
    , moduleText :: !Text
    , kind :: !ModuleKind
    , origin :: !Text          -- e.g. "aggregate Thing (spec.keiro:15)"
    }

data FirewallSurface = FirewallSurface
    { forbiddenSymbolic   :: [Text]           -- ".==", "./=", ".<", ".<=", ".>", ".>=",
                                              -- ".&&", ".||", ".+", ".-", ".*", "=:", "*:"
    , forbiddenIdents     :: [Text]           -- "lit", "pnot", "tadd", "tsub", "tmul"
    , forbiddenQualifiers :: [Text]           -- ["B"]
    , forbiddenImports    :: [Text]           -- Keiki.Builder, Keiki.Operators, Keiki.Symbolic
    , restrictedImports   :: [(Text, [Text])] -- Keiki.Core: RegFile, HsPred, harness validation names
    }

firewallSurface  :: FirewallSurface
firewallBreaches :: [ScaffoldModule] -> [(FilePath, Text, Int)]  -- token-aware; Generated only
scaffoldRefusals :: Spec -> [Text]   -- unlowerable-policy refusals (D5/D8/D6 conditions)
windowSeconds    :: Text -> Either Text Int  -- "90s"->90, "5m"->300, "2h"->7200, else Left
```

In `Keiro.Dsl.ScaffoldRun` (new):

```haskell
data Refusal = PathCollision FilePath [Text] | FirewallBreach [(FilePath, Text, Int)]
             | LoweringRefusal [Text] | MissingGeneratedBanner [FilePath]

planScaffold :: Context -> Spec -> Either [Refusal] [ScaffoldModule]  -- pure gates 1-3
executeScaffold
    :: FilePath          -- --out
    -> Bool              -- --force-generated-overwrite
    -> FilePath          -- spec path (for the record + report)
    -> Spec
    -> [ScaffoldModule]
    -> IO (Either [Refusal] ScaffoldReport)  -- banner gate, writes, record, stale report
```

In `Keiro.Dsl.ScaffoldRecord` (new) — the record file format, version-headed plain text,
unknown header lines ignored for forward compatibility:

```text
keiro-dsl scaffold record v1
spec: test/fixtures/reservation.keiro
module-root: (none)
layout: prefixed
generated Generated/HospitalCapacity/Reservation/Domain.hs
generated Generated/HospitalCapacity/Reservation/Codec.hs
hole HospitalCapacity/Reservation/Holes.hs
```

```haskell
data ScaffoldRecord = ScaffoldRecord
    { recSpecPath :: !Text, recModuleRoot :: !Text, recLayout :: !Text
    , recFiles :: ![(ModuleKind, FilePath)] }
renderRecord :: ScaffoldRecord -> Text
parseRecord  :: Text -> Maybe ScaffoldRecord   -- Nothing on unknown major version
recordFileName :: Text -> FilePath             -- context -> "keiro-dsl-scaffold-record.<ctx>.txt"
```

Grammar/Parser extensions: `BackoffSpec` gains `boMax :: !(Maybe Text)` and
`boMultiplier :: !(Maybe Text)`; `RegDecl`'s initial distinguishes a bare source token
(`RegInitBare`, including signed integer literals) from quoted text (`RegInitText`);
`pWindow` accepts only `s|m|h`. Runtime types consumed (read-only, never
edited): `Keiro.Outbox.Types.BackoffSchedule`/`ExponentialBackoffOptions`
(keiro/src/Keiro/Outbox/Types.hs:100-115), `Keiro.PGMQ.Job.RetryPolicy`/`RetryDelay`
(keiro-pgmq/src/Keiro/PGMQ/Job.hs:190-214; delay unit is seconds). keiki 0.2's operator
surface as enumerated in Context (sources at `/Users/shinzui/Keikaku/bokuno/keiki`).

---

Revision note (2026-07-13): initial authoring. Scope: audit findings D1-D9 plus the
scaffold half of B9 (path-level collisions), per MasterPlan 15; validator-rule ownership
delegated to docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md and escape/`mapPartial` notation semantics to
docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md, with the shared contracts stated verbatim here so landing order is
free.
