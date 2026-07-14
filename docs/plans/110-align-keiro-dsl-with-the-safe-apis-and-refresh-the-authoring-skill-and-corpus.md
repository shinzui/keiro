---
id: 110
slug: align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus
title: "Align keiro-dsl with the safe APIs and refresh the authoring skill and corpus"
kind: exec-plan
created_at: 2026-07-13T18:56:58Z
intention: "intention_01kxed7haee7ja78qm70cc6qm5"
master_plan: "docs/masterplans/15-harden-and-extend-the-keiro-dsl-toolchain-surfaced-by-the-2026-07-dsl-audit.md"
---

# Align keiro-dsl with the safe APIs and refresh the authoring skill and corpus

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro-dsl is a typed-spec toolchain: a `.keiro` file is the machine-checkable source of
truth for a keiro service, and the `keiro-dsl` CLI validates it (`check`), emits a
`-- @generated` deterministic layer plus typed holes (`scaffold`), and gates evolution
(`diff`). A coding agent drives this loop through the **authoring skill** at
`agents/skills/keiro-dsl-authoring/` and learns from the **conformance corpus** indexed at
`docs/corpus/keiro-dsl-corpus.md`. That is the whole point of the toolchain: an agent that
knows nothing but the skill can deliver a working service.

The 2026-07 audit found that the toolchain **teaches the unsafe idioms the runtime already
replaced**. The notation's own `saga … stream="hospital-surge-" <> correlationId` clause and
the committed reference hole fill (`stream ("surge-" <> cid)`) encode raw stream-name
concatenation, which keiro's validated category API (`Keiro.Stream.category` /
`entityStream`) exists to prevent. The runtime's per-target duplicate confirmation
(`Keiro.ProcessManager.confirmBenignDuplicate`) — the function that makes the notation's
`on-duplicate AckOk` disposition *correct* rather than merely optimistic — appears nowhere
in keiro-dsl or the skill. The skill has zero guidance for two failure classes an agent will
actually hit (`StateChangingEpsilon` rejections from `mkEventStreamOrThrow`, and
`CommandAmbiguous` in disposition thinking). `NOTATION.md` claims validator checks that do
not exist. And the sibling plans of this MasterPlan add a large new authoring surface
(read-model, router, policies, pgmq ordering/provisioning, snapshots, workflow
patch/continueAsNew, string escaping) that the skill and corpus do not yet cover.

After this plan, the notation constructs saga streams through a validated category clause
whose legality check mirrors the runtime's; the reference fills demonstrate `entityStream`
and `confirmBenignDuplicate` instead of the raw idioms; the skill explains every
`mkEventStreamOrThrow` rejection and the command-failure taxonomy; every "Checked:" claim in
`NOTATION.md` is true of the delivered validator; the skill and corpus cover the full
post-MasterPlan-15 surface; and — the MasterPlan's end-to-end acceptance — a **fresh
cold-start agent given only the skill** authors a spec exercising the NEW surface (read
model + router + policies), checks it, scaffolds it, fills the holes, and lands a green
harness, committed as a permanent conformance component. This is the delivery tail of
MasterPlan 15, modeled on MasterPlan 8's delivery plan
`docs/plans/65-keiro-dsl-authoring-skill-and-corpus-registration.md`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

**M1 — category-based saga stream construction**

- [x] (2026-07-14 03:15Z) Replace `SagaRef.sagaStreamPrefix` with `sagaCategory` in
      `keiro-dsl/src/Keiro/Dsl/Grammar.hs` and update the docstring.
- [x] (2026-07-14 03:15Z) Rewrite `pSaga` in `keiro-dsl/src/Keiro/Dsl/Parser.hs` to parse
      `saga <Agg> category "<name>"` (hard break on the old clause — see Decision Log).
- [x] (2026-07-14 03:15Z) Rewrite `docSaga` in `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` to print the new clause;
      round-trip property still passes.
- [x] (2026-07-14 03:15Z) Add the `SagaCategoryIllegal` check-time diagnostic in
      `keiro-dsl/src/Keiro/Dsl/Validate.hs`, mirroring `Keiro.Stream.category` legality
      (non-empty, no `-`, not `$all`, no whitespace/control characters).
- [x] (2026-07-14 03:15Z) Update the `new process` skeleton template (`keiro-dsl/src/Keiro/Dsl/Skeleton.hs:89`)
      to the new clause with a legal category.
- [x] (2026-07-14 03:15Z) Emit the saga category constant (`<proc>Category` via `categoryUnsafe`) from
      `emitProcessGen` and a per-aggregate `<agg>Category` constant from `emitEventStream`
      in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`; update the `ProcessHoles` stub comments to
      reference them.
- [x] (2026-07-14 03:15Z) Migrate every current saga fixture (`hospital-surge.keiro`,
      `hospital-surge-{clock,dispatchid,badref}.keiro`, `surge-service.keiro`) and any
      skill/corpus snippets to the new clause.
- [x] (2026-07-14 03:15Z) Rewrite `keiro-dsl/test/conformance-process-full/SurgeDemo/SurgeFlow/Manager.hs`
      (lines 49 and 57) to `entityStream` against the emitted category constants; sweep for
      other raw `stream ("…" <> …)` fills (grep evidence recorded below).
- [x] (2026-07-14 03:15Z) Regenerate and re-commit the pinned byte-stable `Generated/` trees affected by the new
      emissions; all conformance suites and the unit suite green.
- [x] (2026-07-14 03:15Z) Add unit coverage: illegal category rejected by `check`, legal one accepted, skeleton
      still certified valid.

**M2 — confirmBenignDuplicate in fills, holes, and the skill**

- [x] (2026-07-14 03:15Z) Add a `confirmBenignDuplicate` reference to the generated `Process` module comment
      block (next to the `FireOutcome` disposition) and to the `emitProcessHoles` stub in
      `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`.
- [x] (2026-07-14 03:15Z) Extend the process reference material (using the documented
      `Manager.hs` fill commentary) with a worked duplicate-dispatch demonstration that
      names `confirmBenignDuplicate` as the mechanism behind `on-duplicate AckOk`.
- [x] (2026-07-14 03:15Z) Write the hole-filling-contract paragraph into
      `agents/skills/keiro-dsl-authoring/SKILL.md` (rule 4) and `LOOP.md` step 5, with the
      quoted signature.

**M3 — failure-taxonomy guidance (StateChangingEpsilon, CommandAmbiguous)**

- [x] (2026-07-14 03:19Z) Write the `mkEventStreamOrThrow` rejection playbook into the skill (new section in
      `NOTATION.md` or a referenced page): all eight warning families, deep guidance on
      `state-changing-epsilon` with the canonical fixes.
- [x] (2026-07-14 03:19Z) Write the `CommandAmbiguous` explanation (definition bug, rejection-class, never
      transient) into the skill's disposition guidance, using the vocabulary
      `docs/plans/108-add-a-router-node-and-rejection-and-poison-policy-surfaces-to-keiro-dsl.md`
      decided (read its Decision Log at execution time).
- [x] (2026-07-14 03:19Z) Cross-link from `WALKTHROUGH.md` (the harness's `validateTransducer` step) to the
      playbook.

**M4 — NOTATION truthfulness re-audit (after EP-103…EP-106 land)**

- [ ] Enumerate every "Checked:" / "validator …" claim in
      `agents/skills/keiro-dsl-authoring/NOTATION.md` and `SKILL.md`/`LOOP.md`.
- [ ] Verify each against the delivered diagnostics (grep the shipped
      `keiro-dsl/src/Keiro/Dsl/Validate.hs` code list and the `check` output of the negative
      fixtures); fix the two known overclaims (workqueue trio at `NOTATION.md:145`, child-id
      at `NOTATION.md:180`) in whichever direction the delivered validator dictates.
- [ ] Record the audit table (claim → verdict → action) in Surprises & Discoveries.

**M5 — holistic skill + corpus refresh for the new surface (after EP-107…EP-109 land)**

- [ ] Extend `NOTATION.md` with the delivered `readmodel`, `router`, and policy clauses
      (EP-107/EP-108) and the pgmq ordering/provisioning, snapshot, and workflow
      `patch`/`continueAsNew` clauses (EP-109), sourced from those plans' shipped grammar —
      never invented.
- [ ] Document the string-escaping rules EP-105 delivers and the category-stream rules from
      M1.
- [ ] Refresh `LOOP.md`/`SKILL.md`/`WALKTHROUGH.md` for any changed CLI output (scaffold
      report, new diagnostics) and the new hole kinds.
- [ ] Rewrite `docs/corpus/keiro-dsl-corpus.md`: add rows for every fixture and conformance
      component added by EP-103…EP-109 and this plan, and backfill the components the index
      already omits (it lists 3 of the 16 conformance suites in
      `keiro-dsl/keiro-dsl.cabal`).
- [ ] `mori validate` passes with the refreshed description/paths in `mori.dhall`.

**M6 — cold-start proof on the new surface (the MasterPlan's end-to-end acceptance)**

- [ ] Fix the one-line feature description and the scratch protocol (below); confirm the
      skill is the only context handed to the fresh agent.
- [ ] Run the cold-start: fresh agent → `.keiro` with at least `readmodel` + `router` +
      rejection/poison policies → `check` exit 0 → `scaffold` → fill holes only → green
      harness; capture the transcript.
- [ ] Commit the result as a permanent conformance component
      (`keiro-dsl/test/conformance-newsurface/` + a `keiro-dsl-conformance-newsurface`
      test-suite stanza), pinned like the existing `conformance-coldstart` suite.
- [ ] Verify no `-- @generated` module was hand-edited (diff discipline below); record the
      outcome in Outcomes & Retrospective and roll it up to the MasterPlan Progress.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Pre-work discovery (2026-07-13, plan authoring): the `saga … stream=` prefix is
  **load-bearing nowhere in the scaffolder**. `grep -n sagaStreamPrefix keiro-dsl/src` hits
  only Grammar, Parser, PrettyPrint, and the Validate cross-ref on `sagaAgg`; `Scaffold.hs`
  and `Harness.hs` never read it. Consequently the committed reference fill drifted without
  anything noticing: `keiro-dsl/test/fixtures/hospital-surge.keiro:10` declares
  `stream="hospital-surge-"` while the fill
  `keiro-dsl/test/conformance-process-full/SurgeDemo/SurgeFlow/Manager.hs:49` writes
  `stream ("surge-" <> cid)`. M1 makes the clause load-bearing (an emitted, define-once
  category constant) precisely so this class of drift becomes impossible.

- Implementation discovery (2026-07-14): the pre-work inventory's five saga fixtures had
  grown to eleven after EP-109, and EP-108's router fill introduced two additional raw
  `stream ("…" <> …)` targets. M1 migrated every current grammar occurrence and both process
  and router fills; `rg -n 'stream \("' keiro-dsl/test -g '!**/Generated/**'` now has no
  matches.
- Implementation discovery (2026-07-14): `hospital-surge.keiro` is a validator fixture with
  command-only aggregates and the delivered EP-106 scaffold refusal correctly reports
  `AggregateEmpty`; it cannot be used to regenerate its historical conformance tree through
  the CLI. The three affected category-bearing files in `conformance-process` and
  `conformance-process-runtime` were updated surgically, while every scaffoldable tree was
  regenerated normally. The focused matrix passed all twelve requested components, including
  200 unit/property examples and the compile-all-skeletons suite.
- Implementation discovery (2026-07-14): EP-108 had already added router-side
  `confirmBenignDuplicate` comments and a short NOTATION mention. M2 retained that delivered
  guidance, added the missing process generated/stub signature and hand-written-path rules,
  and aligned SKILL/LOOP plus the process reference fill.
- Implementation discovery (2026-07-14): keiki's `OpaqueGuard` audit is the only one of
  the eight rendered warning families disabled by `defaultValidationOptions`; it is
  advisory because the pure symbolic analyses under-verify opaque function applications.
  `TAXONOMY.md` labels it opt-in rather than implying that every generated harness runs it.

(Nothing further yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: **Hard break** on the old `saga <Agg> stream="<prefix>" <> correlationId`
  clause. The parser stops accepting it; there is no deprecation-diagnostic compatibility
  path.
  Rationale: the spec format has no external users. Verified 2026-07-13:
  `find . -name '*.keiro' -not -path './dist-newstyle/*'` returns exactly 28 files, all
  under `keiro-dsl/test/fixtures/`; the only other occurrences of the clause are notation
  snippets inside `agents/skills/keiro-dsl-authoring/` and the `Skeleton.hs` template — all
  owned by this repo and migrated by M1. Keeping a legacy parse path would keep the
  raw-concatenation idiom printable, round-trippable, and teachable, which is the exact
  failure this plan removes. If external `.keiro` users appear before this plan executes,
  revisit (add a parse-time error with a fix-it message rather than silent acceptance).
  Date: 2026-07-13
- Decision: category legality is enforced at `check` time by a **mirrored rule** in
  `Keiro.Dsl.Validate` (not by calling `Keiro.Stream.category` directly), and the scaffold
  then emits the constant via `categoryUnsafe`.
  Rationale: keiro-dsl deliberately depends on the runtime only in its conformance suites,
  not in the toolchain library; mirroring the four `CategoryError` cases keeps that
  boundary. Emitting `categoryUnsafe` in generated code is safe because `check` has already
  proven legality — the same "partial constructor for generated code … that ha[s] a sibling
  validation proof" pattern the runtime documents on `mkEventStreamOrThrow`
  (`keiro-core/src/Keiro/EventStream/Validate.hs`). A conformance test pins the mirror
  against the real `Keiro.Stream.category` so the two rules cannot drift.
  Date: 2026-07-13
- Decision: unlike its model EP-7 (`docs/plans/65-…`, which wrote no Haskell), this plan
  **does** change keiro-dsl source — but only the `keiro-dsl` package and its tests, the
  skill directory, and `docs/corpus/`; **never** the runtime packages (`keiro`,
  `keiro-core`, `keiro-pgmq`, …).
  Rationale: F1/F2 are notation, scaffold, and reference-fill changes; every runtime API
  they align to (`Keiro.Stream` category API, `confirmBenignDuplicate`,
  `mkEventStreamOrThrow`, `CommandAmbiguous`) already exists under the MasterPlan-14
  standing assumption. If executing this plan appears to require a runtime edit, stop — that
  is a sibling plan's scope or a new finding for the MasterPlan.
  Date: 2026-07-13
- Decision: the cold-start artifact is committed as a permanent conformance component
  (`keiro-dsl-conformance-newsurface`) rather than left as a transcript in `/tmp`.
  Rationale: EP-7's cold-start (the `conformance-coldstart` suite,
  `keiro-dsl/test/conformance-coldstart/Billing/…`) proved that committing the artifact
  turns a one-off acceptance into a standing regression: the new-surface scaffold output
  keeps compiling against live keiro forever. The MasterPlan's acceptance deserves the same
  durability.
  Date: 2026-07-13
- Decision: the migrated saga fixtures adopt camelCase categories (`hospitalSurge`,
  `surge`), changing the stream family the SurgeDemo specs name
  (`hospitalSurge-<cid>` instead of `hospital-surge-<cid>`).
  Rationale: the runtime forbids `-` inside a category (it is kiroku's category/id
  boundary; `Keiro.Stream.category` rejects it with `CategoryContainsSeparator`) and its
  docstring prescribes camelCase compound categories. The fixtures are hermetic test data —
  no deployed streams exist under the old names — so no data migration arises.
  Date: 2026-07-13

- Decision: use M2's documented-assertion fallback in the pure process conformance component
  rather than introduce a PostgreSQL store fixture solely to re-test
  `confirmBenignDuplicate` internals.
  Rationale: the runtime process and router workers already exercise the function on their
  dispatch paths, while the DSL obligation is to expose the exact target-stream contract at
  every hand-written decision point. The generated output is pinned to the signature, the
  process reference fill explains the global-id collision hazard, and the green full-process
  component records that the worker owns the confirmation behind `on-duplicate AckOk`.
  Date: 2026-07-14

- Decision: put the replay-safety and command-failure playbook in a new sibling
  `agents/skills/keiro-dsl-authoring/TAXONOMY.md` and cross-link it from the three existing
  entry points.
  Rationale: the eight-warning table, the full state-changing-epsilon repair order, and the
  process/router/timer ambiguity split are a troubleshooting workflow longer than one screen;
  keeping them together gives a red harness one direct destination without burying notation.
  Date: 2026-07-14

(Add entries as implementation decisions are made.)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

M1 replaced raw saga prefixes with validated categories, made category literals load-bearing
through generated `StreamCategory` constants, migrated process and router fills to
`entityStream`, and pinned the mirrored runtime rule plus the stricter workflow-colon
reservation. M2 made the target-stream duplicate confirmation contract visible in generated
process output, hole stubs, the reference fill, and the authoring loop. The focused unit and
conformance matrix passed. M3 added the source-verified eight-warning replay playbook and the
EP-108-aligned `CommandAmbiguous` disposition rules. M4–M6 remain.

(The M6 entry must state whether the cold-start agent succeeded without touching a generated
module — that entry is the MasterPlan's end-to-end acceptance record.)


## Context and Orientation

Read this section fully before touching anything. It embeds every piece of external context
this plan relies on; you need no other document except the checked-in sibling plans it names
by path.

### Standing assumption

keiro MasterPlan 14
(`docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`)
is implemented **before** this MasterPlan runs. That is what guarantees the runtime surfaces
quoted below (the category API, `confirmBenignDuplicate`, the rejection/poison policies, the
snapshot subsystem, the failure taxonomy) exist exactly as quoted. If a quoted signature
does not match the working tree, re-read the runtime source first and update this plan —
do not improvise.

### Scope boundary

This plan edits only: the `keiro-dsl` package (`keiro-dsl/src/`, `keiro-dsl/test/`,
`keiro-dsl/keiro-dsl.cabal`), the authoring skill (`agents/skills/keiro-dsl-authoring/`,
which is symlinked from `.claude/skills/keiro-dsl-authoring`), the corpus index
(`docs/corpus/keiro-dsl-corpus.md`), and — for registration verification only —
`mori.dhall`. It **never** edits the runtime packages (`keiro/`, `keiro-core/`,
`keiro-pgmq/`) or their tests.

### Position in MasterPlan 15

This is the delivery tail of
`docs/masterplans/15-harden-and-extend-the-keiro-dsl-toolchain-surfaced-by-the-2026-07-dsl-audit.md`.
It **hard-depends** on the three surface-extension siblings, because M5 documents and M6
exercises the nodes they deliver:

- `docs/plans/107-add-a-first-class-read-model-node-with-registration-schema-and-consistency-to-keiro-dsl.md`
  (the `readmodel` node),
- `docs/plans/108-add-a-router-node-and-rejection-and-poison-policy-surfaces-to-keiro-dsl.md`
  (the `router` node and `rejected =>` / `poison =>` policy clauses — also the owner of the
  disposition-vocabulary decision M3 aligns with),
- `docs/plans/109-extend-keiro-dsl-node-coverage-pgmq-ordering-and-provisioning-snapshot-policy-and-workflow-patch-and-continue-as-new.md`
  (pgmq ordering/provisioning, `snapshot`, workflow `patch`/`continueAsNew`).

It **soft-depends** on the four hardening siblings
(`docs/plans/103-make-keiro-dsl-diff-sound-over-the-full-decode-and-identity-surface.md`,
`docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md`,
`docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md`,
`docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md`):
M4's truthfulness audit is only meaningful against the validator/differ/parser/scaffolder
those plans ship, and M5 documents EP-105's escaping rules. Milestones M1–M2 have no
dependency on any sibling and can start immediately; M3 needs only EP-108's vocabulary
decision (its Decision Log), not its code.

Its model is MasterPlan 8's delivery plan,
`docs/plans/65-keiro-dsl-authoring-skill-and-corpus-registration.md` (checked in): the same
skill layout, corpus-index shape, mori-registration approach, and — above all — the same
cold-start acceptance discipline. Where EP-7 proved the loop closes for the *original*
surface, M6 proves it closes for the surface MasterPlan 15 adds.

### The toolchain, skill, and corpus in one paragraph each

A `.keiro` spec is checked by `cabal run keiro-dsl -- check <file>`, scaffolded by
`cabal run keiro-dsl -- scaffold <file> --out DIR` into `-- @generated` modules
(overwritten every run; symbol-free — the "firewall": no keiki symbolic operator such as
`./=`, `.==`, `.||`, `lit`, `B.slot`, `B.requireGuard` ever appears in them) plus
create-if-absent hole modules (`Holes.hs`, `ProcessHoles.hs`) that a human or agent fills
against the generated signatures, and gated over time by
`cabal run keiro-dsl -- diff --since <ref> <file>`. The toolchain sources live under
`keiro-dsl/src/Keiro/Dsl/` (`Grammar.hs`, `Parser.hs`, `PrettyPrint.hs`, `Validate.hs`,
`Scaffold.hs`, `Harness.hs`, `Skeleton.hs`, `Diff.hs`).

The **authoring skill** is four files under `agents/skills/keiro-dsl-authoring/`:
`SKILL.md` (frontmatter + the five load-bearing rules), `NOTATION.md` (218 lines: the
per-node notation with "Checked:" claims), `LOOP.md` (the seven-step
write → parse → check → scaffold → fill → harness → diff loop), and `WALKTHROUGH.md` (a
worked Reservation-aggregate pass). A symlink `.claude/skills/keiro-dsl-authoring` makes it
harness-discoverable. Verified 2026-07-13: none of the four files mentions
`CommandAmbiguous`, `StateChangingEpsilon`, `confirmBenignDuplicate`, `entityStream`, or
`categoryUnsafe` (a grep across the skill and `docs/corpus/` returns nothing).

The **corpus index** `docs/corpus/keiro-dsl-corpus.md` (51 lines) tables the fixture specs
under `keiro-dsl/test/fixtures/` and three compiled conformance components. It is already
stale: `keiro-dsl/keiro-dsl.cabal` declares sixteen `test-suite` conformance components
(`conformance`, `conformance-coldstart`, `conformance-contract`,
`conformance-intake-runtime`, `conformance-intake-full`, `conformance-publisher-runtime`,
`conformance-queue`, `conformance-queue-runtime`, `conformance-dispatch-full`,
`conformance-workflow`, `conformance-workflow-runtime`, `conformance-process-full`,
`conformance-workflow-full`, `conformance-process-runtime`, `conformance-process`,
`conformance-v2`) while the index lists only `conformance`, `conformance-v2`, and
`conformance-process`. The **mori registration** is a mention inside the keiro-dsl package
description in `mori.dhall` (line 46: "…Authoring skill: agents/skills/keiro-dsl-authoring;
corpus index: docs/corpus/keiro-dsl-corpus.md") — after edits, `mori validate` must still
pass.

### Runtime surface 1 — the safe category API (what M1 aligns the notation to)

`keiro-core/src/Keiro/Stream.hs` provides validated, category-based stream construction.
The exact current surface (quoted from source):

```haskell
newtype StreamCategory a = StreamCategory {categoryTextOf :: Text}

data CategoryError
    = CategoryEmpty
    | CategoryContainsSeparator !Text
    | CategoryReserved !Text
    | CategoryContainsIllegalChar !Char !Text

category :: Text -> Either CategoryError (StreamCategory a)

categoryUnsafe :: (HasCallStack) => Text -> StreamCategory a

entityStream :: (HasCallStack) => StreamCategory a -> Text -> Stream a

entityStreamId :: (HasCallStack, StreamIdSegment i) => StreamCategory a -> i -> Stream a
```

`category` rejects the empty string, any text containing `-` (kiroku defines a stream's
category as the substring before the first `-`, so a `-` inside the category makes
`categoryName` ambiguous), the reserved `$all`, and whitespace/control characters. The
module docstring prescribes writing compound categories in camelCase (its example is
literally `"hospitalSurge" for a saga over hospital surges`) and reserves `:` for the
workflow stream family (`wf:<name>`). `categoryUnsafe` is documented as a "Partial
constructor for static, known-good category literals at definition sites" — intended for
top-level constants. `entityStream` renders `<category>-<id>` by delegating to kiroku's
`streamNameInCategory` (the naming rule is single-sourced in the store) and rejects a blank
id segment. `entityStreamId` is the typed-id variant. The raw `stream :: Text -> Stream a`
constructor still exists, but hand-concatenating `prefix <> id` through it is exactly the
idiom the category API replaced.

What the DSL does today instead — the misalignment, with evidence:

- Grammar (`keiro-dsl/src/Keiro/Dsl/Grammar.hs:401-405`):

  ```haskell
  data SagaRef = SagaRef
      { sagaAgg :: !Name
      , sagaStreamPrefix :: !Text
      }
  ```

  with the docstring `@saga Surge stream=\"hospital-surge-\" <> correlationId@ — the saga's
  own aggregate plus the @streamFor@ suffix-splice prefix.`

- Parser (`keiro-dsl/src/Keiro/Dsl/Parser.hs:929-938`, `pSaga`): parses
  `saga <ident> stream = "<prefix>" <> correlationId` (the trailing identifier is fixed and
  discarded).
- Printer (`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs:287-288`, `docSaga`): renders the same
  shape back.
- Skeleton (`keiro-dsl/src/Keiro/Dsl/Skeleton.hs:89`): the `new process` starter contains
  `saga Surge stream="hospital-surge-" <> correlationId`.
- Validator: only `sagaAgg` is checked (it must name a declared aggregate,
  `Validate.hs:311-312`); the prefix text is never validated.
- Scaffolder/harness: the prefix is **never lowered** — nothing generated or pinned carries
  it (see Surprises & Discoveries for the drift this already caused).
- Reference fill (`keiro-dsl/test/conformance-process-full/SurgeDemo/SurgeFlow/Manager.hs`),
  the corpus's canonical "what a filled process hole looks like":

  ```haskell
  , streamFor = \cid -> stream ("surge-" <> cid)          -- line 49
  ...
  { target = stream ("hospital-" <> hospitalId i)          -- line 57
  ```

  Verified 2026-07-13 by `grep -rn 'stream ("' keiro-dsl/test/`: these two lines are the
  only raw-concatenation fills in the committed suites (the other suites' stream handles
  come from generated `EventStream` values or workflow machinery).
- Fixtures carrying the clause (all of them, verified by grep): `hospital-surge.keiro:10`,
  `hospital-surge-clock.keiro:10`, `hospital-surge-dispatchid.keiro:10`,
  `hospital-surge-badref.keiro:10` (all `stream="hospital-surge-"`), and
  `surge-service.keiro:9` (`stream="surge-"`).

### Runtime surface 2 — confirmBenignDuplicate (what M2 weaves in)

`keiro/src/Keiro/ProcessManager.hs` exports it under `-- * Idempotency primitives` (export
list line 129); `keiro/src/Keiro/Router.hs` re-exports it (line 70) and both workers call it
on their dispatch paths (`ProcessManager.hs:478,524`; `Router.hs:282`). Quoted from source
(`ProcessManager.hs:717-727`):

```haskell
-- | Decide whether a failed append is a benign duplicate of the write just
-- attempted: whether @ourId@ is genuinely present in @streamName@.
--
-- Kiroku's @DuplicateEvent@ carries 'Just' the colliding id only when
-- PostgreSQL's detail string parses ('Nothing' otherwise), and because the
-- store's event-id uniqueness is global, even a matching id does not prove the
-- event landed in our stream. A mismatched id is never ours; a matching or
-- missing id is confirmed against the target stream with a point lookup.
confirmBenignDuplicate ::
    (Store :> es) =>
    StoreTypes.StreamName ->
    EventId ->
    CommandError ->
    Eff es Bool
```

Why it matters to the DSL: the notation's dispatch disposition row `on-duplicate AckOk`
(Grammar's `DispatchDisposition { onAppended, onDuplicate, onFailed }`,
`Grammar.hs:415-419`; the validator even warns when `onDuplicate` is *not* `DAckOk`,
`Validate.hs:330`) is only correct because the runtime confirms the duplicate against the
**target stream** before acking — a globally-unique event-id collision from another stream
is *not* benign. Today neither the generated modules, nor the hole stubs, nor the skill
mention this function, so an agent hand-rolling any duplicate handling (a custom
fire-outcome, an operation that appends with a deterministic id) has no way to learn the
correct discipline. Note also that the generated timer-fire disposition
(`emitProcessGen`, `Scaffold.hs:707-714`) lowers `Left CommandRejected ->` to the benign
`on-reject` arm and everything else (`Left{}` — including a `StoreFailed (DuplicateEvent …)`)
to `on-error`: a duplicate append surfaces on the *error* arm unless code confirms it
benign, which is exactly the situation `confirmBenignDuplicate` exists for.

### Runtime surface 3 — the replay-safety gate and the failure taxonomy (what M3 teaches)

Every generated aggregate `EventStream` module ends with (emitted by `emitEventStream`,
`Scaffold.hs:1099-1101`):

```haskell
reservationEventStream = mkEventStreamOrThrow "Reservation" reservationEventStreamDef
```

`mkEventStreamOrThrow` (`keiro-core/src/Keiro/EventStream/Validate.hs:156`) throws at
startup unless the transducer passes validation, with the message
`"…: <label> is not replay-safe: <warnings>"`. Validation **force-enables** the
replay-contract checks regardless of caller options (`forceReplayContract`,
`Validate.hs:116-121`, sets `checkStateChangingEpsilon = True` and
`checkHeadRecoverability = True`). The rendered warning families (`renderWarning`,
`Validate.hs:187-207`) are: `hidden-input`, `head-unrecoverable`, `inversion-ambiguity`,
`unguarded-input-read`, `state-changing-epsilon`, `nondeterministic`, `possibly-dead`, and
`opaque-guard`, each tagged with the source vertex and a detail string.

**StateChangingEpsilon** is the one an agent filling a transducer is likeliest to trip and
the one with zero current guidance: an *epsilon edge* — a transition that emits **no
event** — that nonetheless changes state (a `goto` to a different vertex or a register
write). Replay reconstructs state purely from stored events, so a state change with no
event is silently lost on rehydration; the check is therefore non-negotiable at keiro's
durable boundary. The canonical fixes, in preference order: (1) emit an event on that edge
(if the state change matters, it is history and deserves a record); (2) reshape the edge so
the state change happens on an adjacent event-emitting edge (fold the epsilon into the
transition that triggered it); (3) if the change genuinely need not survive a restart, it
does not belong in a register — move it out of the transducer. Never "fix" it with
`mkEventStreamUnchecked` (its docstring: "Tests and emergency forensics only; never use it
for production streams").

**CommandAmbiguous** (`keiro/src/Keiro/Command.hs:164`, quoted docstring: "Two or more
transducer edges matched the command in the hydrated state. This is a deterministic
aggregate-definition bug rather than a business rejection; the list contains the zero-based
matched edge indices…"). The worker taxonomy (`ProcessManager.hs:309-326`) classifies it
non-transient and — together with `CommandRejected` — as the *rejection class* covered by
the per-worker `RejectedCommandPolicy`. For disposition thinking the distinction matters:
`CommandRejected` can be a benign race (the timer-fire `on-reject Fired` inversion), but
`CommandAmbiguous` is always a bug in the transducer definition — acking it as benign hides
a defect. The DSL's generated fire-disposition currently lumps it into the `on-error` arm
(`Left CommandRejected ->` matches only rejection; `Left{} ->` catches ambiguity —
`Scaffold.hs:710-713`), which is defensible but undocumented. EP-108 owns the
disposition-vocabulary decision (whether ambiguity gets its own arm, stays lumped, or maps
to the rejected-policy); M3 adopts whatever its Decision Log records and documents the
lowering truthfully.

### The two known NOTATION overclaims (what M4 starts from)

Verified 2026-07-13 against `agents/skills/keiro-dsl-authoring/NOTATION.md`:

- Line 145 (workqueue): `derive physical = … # captured fixture; validator re-derives +
  checks drift` — implies the whole trio; the current validator re-derives only `physical`
  (`Validate.hs:162`); `dlq` and `table` are unchecked. EP-104 may close this; the claim
  must match whatever ships.
- Line 180 (workflow): `child ship-order id input via shipChildId -> Text # child id MUST
  differ from parent's` — no such check exists anywhere (`validateNode _ (NWorkflow _) = []`,
  `Validate.hs:123`, is the current workflow validation in its entirety).

M4 is not limited to these two: every "Checked:" sentence in the skill is re-audited against
the post-EP-103…EP-106 validator, in both directions (delete or weaken claims the validator
does not honor; add claims for new diagnostics agents will encounter).

### The conformance-suite architecture (where M1/M2/M6 artifacts land)

Each conformance component under `keiro-dsl/test/conformance-*` commits raw scaffold output
(`Generated/…`, byte-stable, pinned by the scaffold-conformance test in
`keiro-dsl/test/Main.hs`) plus hand-filled hole modules, compiled against live keiki/keiro
by a `test-suite` stanza in `keiro-dsl/keiro-dsl.cabal`. The process exemplar is
`test/conformance-process-full/` (spec `surge-service.keiro` → `Generated/SurgeDemo/…` +
hand-owned `SurgeDemo/{Hospital,Surge}/Holes.hs`, `SurgeDemo/SurgeFlow/Manager.hs`,
`SurgeDemo/SurgeFlow/ProcessHoles.hs`, driven by `Main.hs`). The cold-start exemplar is
`test/conformance-coldstart/` (`Billing/Subscription/Holes.hs` + `Generated/Billing/…`),
committed by EP-7 exactly as M6 will commit the new-surface cold-start. Because M1 changes
what `emitProcessGen`/`emitEventStream` emit, the pinned `Generated/` trees must be
regenerated and re-committed in the same change (the unit suite runs from `keiro-dsl/`,
i.e. `cabal test keiro-dsl-test` with cwd `keiro-dsl/` — fixture paths are relative).


## Plan of Work

Six milestones. M1 and M2 are code + fixtures + skill text and can start immediately. M3 is
skill text gated only on EP-108's vocabulary decision. M4 runs after EP-103…EP-106 land.
M5 runs after EP-107…EP-109 land. M6 is last: it is the MasterPlan's end-to-end acceptance
and needs everything else in place. Within each milestone, work is committed incrementally
with green suites (conventional commits, e.g. `feat(dsl): …`, `docs(skill): …`).

### Milestone 1 — Category-based saga stream construction (F1)

**Scope.** Replace the raw-concatenation saga clause with a validated category clause, make
it load-bearing (the scaffold emits the category constant), and purge the raw idiom from
the reference fills. At the end, the notation *cannot express* an illegal category, the
generated layer carries the define-once `StreamCategory` constants, and the corpus teaches
`entityStream`.

**Work.**

First the grammar and syntax. In `keiro-dsl/src/Keiro/Dsl/Grammar.hs` change `SagaRef` to
carry `sagaCategory :: !Text` (docstring: the validated stream category of the saga's own
stream family; the saga stream for correlation id *c* is `<category>-<c>` via
`Keiro.Stream.entityStream`). In `keiro-dsl/src/Keiro/Dsl/Parser.hs` rewrite `pSaga` to
parse `saga <Agg> category "<text>"` (keyword `category`, then a string literal; the old
`stream = "…" <> correlationId` shape is simply no longer grammar — a spec using it now
fails at parse with the standard unexpected-token error pointing at `stream`). In
`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` rewrite `docSaga` to print
`"saga" <+> pretty (sagaAgg s) <+> "category" <+> dquoted (sagaCategory s)`. Round-trip
holds by construction (the property in `keiro-dsl/test/Main.hs` only generates aggregates,
but the fixture round-trip tests cover the process shape).

Then the legality check. In `keiro-dsl/src/Keiro/Dsl/Validate.hs` add a `SagaCategoryIllegal`
diagnostic code and a rule on process nodes that mirrors `Keiro.Stream.category` exactly:
reject an empty category, a category containing `-`, the literal `$all`, and any category
containing whitespace or a control character (implement with `Data.Char.isSpace` /
`isControl` over `Data.Text.find`, same predicate as the runtime). The message must name the
offending text, the reason, and the fix (e.g. `saga category "hospital-surge" contains '-'
(kiroku's category/id boundary); write compound categories in camelCase, e.g.
"hospitalSurge"`). Also reject a category containing `:` (reserved for the `wf:<name>`
workflow family per the `StreamCategory` docstring) — this is one rule stricter than the
runtime's `category`, deliberately, and must be called out in the diagnostic text. Add a
conformance pin (in the `keiro-dsl-conformance-process-runtime` suite or a small new test in
an existing runtime-linked suite) asserting that for a sample of legal and illegal inputs
the mirror agrees with the real `Keiro.Stream.category` — this is what stops the two rules
drifting.

Then make the clause load-bearing. In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`:

- `emitProcessGen` additionally emits a define-once category constant into the generated
  `Process` module:

  ```haskell
  -- The saga stream category (hole-kind 5: referenced, never retyped).
  -- Saga streams are '<category>-<correlationId>' via Keiro.Stream.entityStream.
  surgeFlowCategory :: Stream.StreamCategory a
  surgeFlowCategory = Stream.categoryUnsafe "hospitalSurge"
  ```

  (name = `lowerFirst (procId p) <> "Category"`; add
  `import qualified Keiro.Stream as Stream` to the module's import block; `categoryUnsafe`
  is safe here because `check` proved legality — record the sibling-proof rationale in a
  generated comment). `categoryUnsafe` is not a firewall token
  (`forbiddenOperators`, `Scaffold.hs:132`, lists only keiki symbolic operators), so the
  firewall self-check stays green.
- `emitEventStream` additionally emits a per-aggregate category constant
  (`hospitalCategory :: Stream.StreamCategory a`;
  `hospitalCategory = Stream.categoryUnsafe "hospital"`, text = `lowerFirst (aName a)`) so
  dispatch-target fills can write `entityStream hospitalCategory (hospitalId i)`. Aggregate
  names are PascalCase identifiers, so `lowerFirst` of one can never contain `-`, `:` or
  whitespace; still, route the derived text through the same mirrored legality predicate at
  scaffold time as a belt-and-braces assertion.
- `emitProcessHoles` stub comments gain a line telling the filler to build `streamFor` with
  `entityStream <proc>Category` and dispatch targets with `entityStream <agg>Category …` —
  never raw `stream (prefix <> id)`.

Then migrate the repository. Update `Skeleton.hs:89` to
`saga Surge category "hospitalSurge"` (the skeleton must stay certified-valid: the pinned
`new process`-passes-`check` test keeps this honest). Rewrite the five fixtures
(`hospital-surge.keiro` and its three negative variants to `category "hospitalSurge"`;
`surge-service.keiro` to `category "surge"`). Rewrite
`test/conformance-process-full/SurgeDemo/SurgeFlow/Manager.hs`: line 49 becomes
`streamFor = entityStream surgeCategory` (the constant emitted from `surge-service.keiro`'s
process node — import it from `Generated.SurgeDemo.SurgeFlow.Process`) and line 57 becomes
`target = entityStreamId hospitalCategory …` / `entityStream hospitalCategory (hospitalId i)`
(imported from `Generated.SurgeDemo.Hospital.EventStream`); drop the now-unused
`Keiro.Stream (stream)` import in favor of `Keiro.Stream (entityStream)`. Regenerate every
pinned `Generated/` tree the emission change touches (all suites with an `EventStream.hs` or
`Process.hs` under `Generated/` — regenerate with `keiro-dsl scaffold` against each suite's
source spec and re-commit; the scaffold-conformance byte-pin in `keiro-dsl/test/Main.hs`
will confirm). Finally update the notation snippets in
`agents/skills/keiro-dsl-authoring/NOTATION.md` (the `saga` line in the process block) and
any corpus prose, and add a short NOTATION paragraph on category streams: what a category
is, the legality rules, camelCase for compounds, and that fills use
`entityStream`/`entityStreamId` against the emitted constants.

**Acceptance.** `cabal run keiro-dsl -- check` rejects
`saga Surge category "hospital-surge"` with `SagaCategoryIllegal` naming the `-`; accepts
`category "hospitalSurge"`; the old `stream="…"` clause is a parse error. `keiro-dsl new
process | keiro-dsl check /dev/stdin` passes. All sixteen conformance suites plus
`keiro-dsl-test` (from `keiro-dsl/`) are green, and
`grep -rn 'stream ("' keiro-dsl/test/` (excluding `Generated/`) returns nothing.

### Milestone 2 — confirmBenignDuplicate in fills, holes, and the skill (F2)

**Scope.** Make the per-target duplicate confirmation visible everywhere an agent decides a
duplicate's fate. No runtime change — the function exists and the workers already call it;
this milestone is generated comments, reference material, and skill text.

**Work.** In `Scaffold.hs`: extend the generated `Process` module's disposition comment
block (next to the emitted `<proc>FireOutcome`) with two sentences: the `Left
CommandRejected ->` arm is the benign `on-reject` inversion, and a duplicate append
(`StoreFailed (DuplicateEvent …)`) lands on the `on-error` arm — treating it as benign
requires confirming it against the target stream with
`Keiro.ProcessManager.confirmBenignDuplicate` (paste the signature into the comment), which
is exactly what the runtime workers do on the dispatch path. Extend the `emitProcessHoles`
stub with a matching `-- HOLE` note: any hand-rolled duplicate handling in the `handle`
fill or an operation must call `confirmBenignDuplicate streamName ourEventId err` and fold
`True` into the duplicate result, `False` back into the failure — never pattern-match
`DuplicateEvent` as success on its own (the store's event-id uniqueness is global, so a
collision does not prove the event landed in *our* stream).

In the reference material: add a worked demonstration to the process runtime suite
(`keiro-dsl/test/conformance-process-runtime/`) that dispatches the same command twice with
the same deterministic id and asserts the second attempt acks as a benign duplicate —
with a comment naming `confirmBenignDuplicate` as the mechanism (if the suite's existing
store fixture makes this awkward, the fallback is a documented assertion in the
`conformance-process-full` `Main.hs` facts plus prose in the Manager fill's header comment;
record which path was taken in the Decision Log). Reference the demonstration from
`docs/corpus/keiro-dsl-corpus.md`.

In the skill: `SKILL.md` load-bearing rule 4 (the dangerous-decisions rule) gains the
sentence explaining *why* `duplicate => ackOk` / `on-duplicate AckOk` is safe (the runtime
confirms the duplicate against the target stream via `confirmBenignDuplicate` before
acking) and the corresponding obligation when the agent writes duplicate handling by hand.
`LOOP.md` step 5 (fill the holes) points at the new hole-stub note.

**Acceptance.** Scaffolding any process spec produces the new comments (assert via the
byte-stable pin); the runtime demonstration is green; grepping the skill for
`confirmBenignDuplicate` hits SKILL.md and LOOP.md with the quoted signature.

### Milestone 3 — Failure-taxonomy guidance in the skill (F3 + F4)

**Scope.** Give the agent the playbook for the two failure classes the toolchain currently
tells it nothing about, aligned with EP-108's vocabulary. Pure skill text.

**Work.** Add a "When the runtime rejects your fill" section (in `NOTATION.md`, or a new
`TAXONOMY.md` referenced from `SKILL.md` if it exceeds a screen — decide at execution time
and record it). Content, sourced from the runtime quotes embedded in Context and
Orientation:

- What `mkEventStreamOrThrow` is (the generated `EventStream` module's startup gate), what
  its error looks like (`"<label> is not replay-safe: […]"`), and that the replay-contract
  checks cannot be disabled (`forceReplayContract` force-enables `checkStateChangingEpsilon`
  and `checkHeadRecoverability`). One line per warning family (`hidden-input`,
  `head-unrecoverable`, `inversion-ambiguity`, `unguarded-input-read`,
  `state-changing-epsilon`, `nondeterministic`, `possibly-dead`, `opaque-guard`): what it
  means and the first thing to try.
- A full subsection on **state-changing-epsilon**: definition (a state-changing edge that
  emits no event), why replay loses it, the three canonical fixes in preference order (emit
  an event on the edge; fold the state change into an adjacent event-emitting edge; if it
  need not survive restart it does not belong in a register), and the explicit prohibition
  on `mkEventStreamUnchecked`. Note that the harness's `validateTransducer …== []` assertion
  (LOOP step 6) catches this *before* startup would — a red harness here is the same finding
  as the startup throw.
- A subsection on **CommandAmbiguous**: quoted definition (two or more edges matched — a
  deterministic aggregate-definition bug, not a business rejection), that it is
  non-transient and rejection-class in the worker taxonomy, and what that means for
  disposition tables: never write an arm that treats ambiguity as benign; the fix is always
  in the transducer (make the guards mutually exclusive), and the spec-side symptom is
  usually two transitions from one state on the same command with overlapping guards. State
  truthfully how the generated timer-fire disposition lowers it **using the vocabulary
  EP-108 decided** (read the Decision Log of
  `docs/plans/108-add-a-router-node-and-rejection-and-poison-policy-surfaces-to-keiro-dsl.md`
  at execution time: if EP-108 gave ambiguity its own arm or routed it to the
  rejected-policy, document that; if it stayed lumped in `on-error`, document *that*,
  including that `Left CommandRejected ->` matches only rejection). This is the plan's one
  integration point with EP-108's text.

Cross-link `WALKTHROUGH.md`'s harness step to the new section.

**Acceptance.** `grep -rn 'StateChangingEpsilon\|state-changing-epsilon\|CommandAmbiguous'
agents/skills/keiro-dsl-authoring/` hits the guidance; a reader can answer, from the skill
alone: "my scaffold's startup throws `not replay-safe: state-changing-epsilon @Held` — what
do I change?" and "can `duplicate => ackOk` ever ack a CommandAmbiguous?" (no — different
error, different arm, always a bug).

### Milestone 4 — NOTATION truthfulness re-audit (F5; after EP-103…EP-106)

**Scope.** Make every checker claim in the skill true of the delivered validator. Pure
skill text, but strictly gated on the hardening siblings having landed (auditing against
the pre-fix validator would enshrine the audit findings as documentation).

**Work.** Build the claim inventory: every sentence in `NOTATION.md` (the "Checked:" lines
per node section plus inline `# …` comments making checker claims, e.g. lines 93-94,
137-138, 145, 180, 192-194) and the diagnostic list in `LOOP.md` step 3. For each claim,
verify against the shipped code: the diagnostic-code sum in
`keiro-dsl/src/Keiro/Dsl/Validate.hs`, the negative fixtures' actual `check` output, and —
for diff claims — `Keiro.Dsl.Diff`. Record a claim → verdict (true / overclaim /
underclaim) → action table in Surprises & Discoveries. Fix the text: the two known
overclaims (`NOTATION.md:145` workqueue trio — if EP-104 shipped `dlq`/`table` re-derivation
the claim becomes true and stays, otherwise scope it to `physical`; `NOTATION.md:180`
child-id — same logic against EP-104's delivered workflow validation), plus anything else
the inventory surfaces, plus *underclaims*: new diagnostics agents will now hit (EP-104's
workflow/rule/cross-ref/disposition rules, EP-105's escaping and duplicate-clause errors,
EP-106's scaffolder collision/stale detection, M1's `SagaCategoryIllegal`) belong in
`LOOP.md`'s "common rejections" list.

**Acceptance.** The audit table is recorded; for every "Checked:" claim in the skill there
is a named diagnostic (or validator code path) that enforces it, demonstrable by running
`check` on a fixture that violates it.

### Milestone 5 — Holistic skill + corpus refresh for the new surface (F6, part 1; after EP-107…EP-109)

**Scope.** The skill and corpus cover everything MasterPlan 15 added, sourced from the
shipped grammar of the siblings, never invented. At the end, an agent reading only the
skill can author every node/clause the toolchain now parses.

**Work.** Extend `NOTATION.md` with one section (notation block + "maps to" + hole-kinds +
"Checked:" list, matching the existing per-node format) per delivered surface: the
`readmodel` node (EP-107: name, table, db schema, subscription, version + shape-hash
fixture, default consistency including the inline-model rule, rebuild declaration, and how
`query` operations now resolve against it); the `router` node and the per-process/router
`rejected =>` / `poison =>` policy clauses (EP-108: stable name, key derivation,
resolve-via, target bindings, dispositions, policy consistency rules); pgmq
`ordering`/provisioning clauses, the `snapshot` clause (with the codec version/shape-hash
fixture and the note that the generated `EventStream` no longer hardcodes
`snapshotPolicy = Never` when declared), and workflow `patch`/`continueAsNew` (EP-109 —
including why they exist: they are the runtime's sanctioned safe-evolution mechanism, and
`diff` treats them accordingly). Fold in the cross-cutting rules from M1 (category streams)
and EP-105 (string escaping: how to write a literal `"` and what the printer escapes).
Update `LOOP.md`/`SKILL.md` for changed CLI behavior (EP-106's scaffold report changes,
stale-module handling, any new flags) and `WALKTHROUGH.md` where its transcripts drifted.

Rewrite `docs/corpus/keiro-dsl-corpus.md`: add fixture rows for every `.keiro` the siblings
added (enumerate `keiro-dsl/test/fixtures/` fresh — do not trust this plan's list by then),
add component rows for every conformance suite in `keiro-dsl/keiro-dsl.cabal` (including
the thirteen currently missing, listed in Context and Orientation, and M6's new suite), and
refresh the mutation/gate-script table. Then verify registration: `mori validate` passes,
and the `mori.dhall` keiro-dsl package description (line 46) still names the skill and
corpus paths accurately (update the sentence if the surface description drifted).

**Acceptance.** Reading only the skill, one can enumerate every node type the parser
accepts (cross-check against the `new <kind>` list and the Grammar node sum); every fixture
and every cabal conformance component appears in the corpus index with a resolving path;
`mori validate` exits 0.

### Milestone 6 — Cold-start proof on the new surface (F6, part 2; the MasterPlan's end-to-end acceptance)

**Scope.** Re-run EP-7's cold-start discipline against the surface this MasterPlan added.
A fresh coding agent — no context except the `keiro-dsl-authoring` skill and a one-line
feature description — authors a `.keiro` exercising at minimum a `readmodel`, a `router`,
and rejection/poison policies; checks it; scaffolds it; fills the holes; and lands a green
harness. The artifact is committed as a permanent conformance component. This milestone is
the MasterPlan's end-to-end acceptance: it proves the *entire* initiative (hardened
toolchain + extended surface + refreshed teaching material) closes the loop for the agent
the toolchain exists to serve.

**Procedure, fully specified.**

1. **The feature description** (fixed here so the run is reproducible): *"Route each
   accepted hospital-transfer need to a target hospital's aggregate, resolving the target
   through a hospital-load read model; dead-letter rejected commands instead of halting."*
   This is deliberately shaped so a correct spec needs an aggregate (the target), a
   `readmodel` node (hospital load), a `router` node (source input → key → resolve-via the
   read model → target command), and an explicit `rejected => deadLetter` policy — the
   minimum new surface — without naming any node type in the description (the agent must
   choose them from the skill).
2. **The handoff.** Spawn a fresh agent whose entire context is: the four skill files
   (via the `/keiro-dsl-authoring` skill), the feature description, a scratch spec path
   (e.g. `keiro-dsl/test/fixtures-scratch/transfer-routing.keiro` — outside the committed
   fixtures until accepted), and a scratch `--out` directory. The agent is *not* shown the
   corpus answers for router/readmodel beyond what the skill itself links, is not shown
   this plan, and is never told the expected node set.
3. **The loop.** The agent runs `check` until exit 0, `scaffold` into the scratch dir,
   fills only the created hole modules against the generated signatures, and runs the
   emitted harness until green. Course corrections are allowed only as diagnostics-driven
   iteration by the agent itself; the supervisor answers no design questions.
4. **The audit.** After the run: `check` exits 0 on the agent's spec; the scaffold report's
   firewall verdict is OK; a directory diff of the scratch `--out` against a fresh
   re-scaffold of the agent's spec shows the generated trees byte-identical (proving no
   `-- @generated` file was hand-edited — only hole modules differ from their stubs);
   the harness (and any runtime-facing assertions the scaffold emitted) is green.
5. **The commit.** Promote the artifact: move the spec into `keiro-dsl/test/fixtures/`,
   the generated + filled modules into `keiro-dsl/test/conformance-newsurface/`, add a
   `test-suite keiro-dsl-conformance-newsurface` stanza to `keiro-dsl/keiro-dsl.cabal`
   (mirror the `keiro-dsl-conformance-coldstart` stanza's shape: `hs-source-dirs`,
   `other-modules` for the generated + hole modules, `build-depends` on keiki/keiro and
   whatever the router/readmodel wiring needs), pin the generated tree in the
   scaffold-conformance list in `keiro-dsl/test/Main.hs` alongside the existing pins, and
   add the corpus-index row (M5's file). Record the transcript summary (spec size, number
   of check iterations, which diagnostics the agent hit, harness output) in Outcomes &
   Retrospective, and mark the corresponding MasterPlan Progress entry.

**Acceptance.** `cabal test keiro-dsl-conformance-newsurface` is green in CI from a clean
checkout; the byte-identical re-scaffold audit passed; the cold-start agent hit zero
supervisor interventions. If the agent *fails* — cannot produce a passing spec, or the
skill sent it somewhere wrong — that is a finding against M3–M5 (or a sibling), not against
the agent: fix the skill (or file the toolchain bug), record it in Surprises & Discoveries,
and re-run with a fresh agent. The milestone is done only when a fresh run succeeds.


## Concrete Steps

Run everything from the repo root `/Users/shinzui/Keikaku/bokuno/keiro` unless a step says
otherwise. The unit suite must be run from the package directory (`keiro-dsl/`) because its
fixture paths are relative.

**Orientation (before M1).**

```bash
# The misalignment, verbatim:
grep -n 'sagaStreamPrefix\|sagaAgg' keiro-dsl/src/Keiro/Dsl/*.hs
grep -rn 'stream ("' keiro-dsl/test/ | grep -v Generated
grep -n 'saga' keiro-dsl/test/fixtures/*.keiro
grep -rn 'confirmBenignDuplicate\|StateChangingEpsilon\|CommandAmbiguous\|entityStream' \
  agents/skills/keiro-dsl-authoring/ docs/corpus/        # expect: no hits (that's the gap)
# The runtime surfaces (read, do not edit):
sed -n '55,152p'  keiro-core/src/Keiro/Stream.hs
sed -n '700,730p' keiro/src/Keiro/ProcessManager.hs
sed -n '100,210p' keiro-core/src/Keiro/EventStream/Validate.hs
```

**M1.**

```bash
# after the Grammar/Parser/PrettyPrint/Validate/Skeleton/Scaffold edits and fixture migration:
cabal run -v0 keiro-dsl -- new process | cabal run -v0 keiro-dsl -- check /dev/stdin
# expect: OK (the skeleton stays certified-valid with the new clause)

printf 'saga X category "hospital-surge"' >/dev/null  # illustrative; real test is a fixture:
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/hospital-surge.keiro
# expect: OK, and the file now reads: saga Surge category "hospitalSurge"

# regenerate the pinned trees for every suite whose Generated/ output changed, e.g.:
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/surge-service.keiro \
  --out keiro-dsl/test/conformance-process-full
git -C . diff --stat keiro-dsl/test/conformance-process-full/Generated/

(cd keiro-dsl && cabal test keiro-dsl-test)     # unit suite, from the package dir
cabal test keiro-dsl-conformance-process-full   # Manager.hs now uses entityStream
# then the full sweep:
for t in $(grep -o 'keiro-dsl-conformance[a-z0-9-]*' keiro-dsl/keiro-dsl.cabal | sort -u); do
  cabal test "$t" || break
done
grep -rn 'stream ("' keiro-dsl/test/ | grep -v Generated   # expect: no output
```

**M2.**

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/hospital-surge.keiro --out /tmp/m2gen
grep -n 'confirmBenignDuplicate' /tmp/m2gen -r
# expect: hits in the generated Process module comment and the ProcessHoles stub
cabal test keiro-dsl-conformance-process-runtime   # includes the duplicate-dispatch demo
grep -n 'confirmBenignDuplicate' agents/skills/keiro-dsl-authoring/SKILL.md \
  agents/skills/keiro-dsl-authoring/LOOP.md
```

**M3.**

```bash
grep -rn 'state-changing-epsilon\|CommandAmbiguous' agents/skills/keiro-dsl-authoring/
# expect: the playbook section + the disposition guidance; then read
# docs/plans/108-…'s Decision Log and confirm the vocabulary matches.
```

**M4** (after EP-103…EP-106 are Complete in the MasterPlan registry).

```bash
grep -n 'Checked:\|validator' agents/skills/keiro-dsl-authoring/NOTATION.md
# for each claim, find the enforcing diagnostic:
grep -n 'data Diag\|Diagnostic' keiro-dsl/src/Keiro/Dsl/Validate.hs
# and demonstrate it, e.g.:
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/<violating-fixture>.keiro ; echo "exit=$?"
```

**M5** (after EP-107…EP-109 are Complete).

```bash
ls keiro-dsl/test/fixtures/                      # enumerate fresh; index every spec
grep -c 'test-suite' keiro-dsl/keiro-dsl.cabal    # every component gets a corpus row
mori validate                                     # registration still typechecks
```

**M6.**

```bash
# hand the fresh agent ONLY the skill + the fixed feature description, then audit:
cabal run keiro-dsl -- check keiro-dsl/test/fixtures-scratch/transfer-routing.keiro ; echo "exit=$?"
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures-scratch/transfer-routing.keiro --out /tmp/coldstart2
# byte-identical re-scaffold audit (no @generated file was hand-edited):
diff -r /tmp/coldstart2-fresh /tmp/coldstart2 --exclude '*Holes*' --exclude '*Manager*'
# promote, then from a clean checkout:
cabal test keiro-dsl-conformance-newsurface
```

Expected transcripts are recorded inline as each milestone executes (this section must be
updated with the real output).


## Validation and Acceptance

The plan is accepted when all of the following hold, each phrased as observable behavior:

1. **The notation cannot express an illegal category.** `keiro-dsl check` on a spec with
   `saga X category "hospital-surge"` exits non-zero with `SagaCategoryIllegal` naming the
   `-`; `category "hospitalSurge"` passes; the pre-plan `stream="…" <> correlationId`
   clause is a parse error. A conformance test proves the mirrored legality rule agrees
   with `Keiro.Stream.category` on a sample of legal and illegal inputs.
2. **The corpus teaches the safe idioms.**
   `grep -rn 'stream ("' keiro-dsl/test/ | grep -v Generated` is empty; the process
   reference fill imports and uses `entityStream` against generated `StreamCategory`
   constants; the generated Process/ProcessHoles output names `confirmBenignDuplicate` at
   the duplicate-handling decision points; a runtime conformance test demonstrates the
   benign-duplicate ack.
3. **The skill covers the failure taxonomy.** From the skill alone a reader can diagnose
   and fix a `state-changing-epsilon` startup throw and can state why `CommandAmbiguous`
   must never be acked as benign, in EP-108's vocabulary.
4. **Every checker claim in the skill is true.** The M4 audit table exists in Surprises &
   Discoveries with a verdict per claim; the two named overclaims are resolved in the
   direction the delivered validator dictates; every claim maps to a demonstrable
   diagnostic.
5. **The skill and corpus cover the full post-MP-15 surface.** Every node kind the parser
   accepts has a NOTATION section; every fixture and every cabal conformance component has
   a corpus-index row with a resolving path; `mori validate` exits 0.
6. **The cold-start closes (MasterPlan acceptance).** A fresh agent, given only the skill
   and the fixed one-line description, produced a spec with at least `readmodel` +
   `router` + a rejection/poison policy that passes `check`, scaffolded it, filled only
   hole modules (byte-identical re-scaffold audit), and reached a green harness; the
   artifact is committed as `keiro-dsl-conformance-newsurface` and passes in CI from a
   clean checkout.

Throughout: all sixteen pre-existing conformance suites plus the unit suite (run from
`keiro-dsl/`) stay green, and no file under `keiro/`, `keiro-core/`, or `keiro-pgmq/` is
modified (verify with `git diff --stat` before each commit).


## Idempotence and Recovery

All steps are re-runnable. `scaffold` is idempotent by design (overwrites `-- @generated`,
never touches an existing hole module), so regenerating pinned trees can be repeated until
the byte-pin passes. Skill and corpus edits are plain-file rewrites. `mori validate` is
read-only.

The one coordinated change is M1: grammar, parser, printer, skeleton, validator, scaffolder,
fixtures, reference fill, and pinned `Generated/` trees must move together or the suites go
red. Do it as one commit series on a green base, in this order: (1) grammar + parser +
printer + fixtures (parse/round-trip green), (2) validator rule + its tests, (3) skeleton,
(4) scaffolder emissions + regenerate pins + rewrite `Manager.hs` (conformance green),
(5) skill text. If a step goes red, `git revert` the series — nothing outside `keiro-dsl/`,
the skill, and the corpus is touched, and no migration or persistent state is involved
(the renamed saga stream family exists only in hermetic test fixtures).

M6 is repeatable by construction: each attempt uses a fresh agent, a fresh scratch spec
path, and a fresh `--out`; nothing is committed until the audit passes. A failed cold-start
leaves only scratch files to delete. If a cold-start failure implicates a sibling plan's
artifact (a validator bug, a scaffolder bug on the new nodes), file it against that plan in
the MasterPlan's Surprises & Discoveries and re-run after the fix — do not patch runtime or
sibling-owned code from this plan.


## Interfaces and Dependencies

**Runtime interfaces consumed (read-only; must exist per the MasterPlan-14 assumption —
re-verify signatures against the working tree before relying on them):**

- `Keiro.Stream` (`keiro-core/src/Keiro/Stream.hs`): `StreamCategory a`, `CategoryError
  (CategoryEmpty | CategoryContainsSeparator | CategoryReserved |
  CategoryContainsIllegalChar)`, `category :: Text -> Either CategoryError (StreamCategory
  a)`, `categoryUnsafe :: HasCallStack => Text -> StreamCategory a`, `entityStream ::
  HasCallStack => StreamCategory a -> Text -> Stream a`, `entityStreamId`. Consumed by:
  the M1 mirrored validator rule (semantics only), the generated modules (emitted imports),
  the reference fills, and the mirror-agreement conformance test (real import, test-only).
- `Keiro.ProcessManager` (`keiro/src/Keiro/ProcessManager.hs`): `confirmBenignDuplicate ::
  (Store :> es) => StreamName -> EventId -> CommandError -> Eff es Bool` (also re-exported
  by `Keiro.Router`). Consumed by generated comments, the M2 runtime demonstration, and
  skill text.
- `Keiro.EventStream.Validate` (`keiro-core/src/Keiro/EventStream/Validate.hs`):
  `mkEventStreamOrThrow`, `forceReplayContract` (force-enabled `checkStateChangingEpsilon`
  / `checkHeadRecoverability`), `renderWarning`'s eight warning families. Consumed by M3
  skill text only.
- `Keiro.Command` (`keiro/src/Keiro/Command.hs`): the `CommandError` constructors, in
  particular `CommandRejected` and `CommandAmbiguous ![Int]`, and the worker taxonomy
  (`isTransientCommandError`, `isRejectionClass`). Consumed by M3 skill text only.

**keiro-dsl interfaces changed (all within `keiro-dsl/`):**

- `Keiro.Dsl.Grammar`: `SagaRef { sagaAgg :: !Name, sagaCategory :: !Text }` (field rename;
  `sagaStreamPrefix` is deleted).
- `Keiro.Dsl.Parser`: `pSaga` parses `saga <Agg> category "<text>"`.
- `Keiro.Dsl.PrettyPrint`: `docSaga` prints the same clause.
- `Keiro.Dsl.Validate`: new diagnostic `SagaCategoryIllegal` with the mirrored legality
  rule (plus the `:` reservation).
- `Keiro.Dsl.Skeleton`: the `new process` template carries the new clause.
- `Keiro.Dsl.Scaffold`: `emitProcessGen` emits `<proc>Category :: Stream.StreamCategory a`;
  `emitEventStream` emits `<agg>Category :: Stream.StreamCategory a`; `emitProcessHoles`
  and the Process-module comments gain the `entityStream`/`confirmBenignDuplicate`
  guidance. By the end of each milestone the affected suites' pinned `Generated/` trees
  reflect the new emissions byte-for-byte.

**Sibling-plan dependencies (restated):** hard on
`docs/plans/107-add-a-first-class-read-model-node-with-registration-schema-and-consistency-to-keiro-dsl.md`,
`docs/plans/108-add-a-router-node-and-rejection-and-poison-policy-surfaces-to-keiro-dsl.md`
(also the disposition-vocabulary owner M3 aligns with), and
`docs/plans/109-extend-keiro-dsl-node-coverage-pgmq-ordering-and-provisioning-snapshot-policy-and-workflow-patch-and-continue-as-new.md`
— M5 documents and M6 exercises their surfaces. Soft on `docs/plans/103-…`,
`docs/plans/104-…`, `docs/plans/105-…`, `docs/plans/106-…` — M4's audit and M5's
escaping/CLI documentation are written against what they ship. M1–M2 depend on none of
them. Model plan (checked in, consulted for shape only):
`docs/plans/65-keiro-dsl-authoring-skill-and-corpus-registration.md`.

**Tools:** the `keiro-dsl` CLI (`parse`/`check`/`scaffold`/`diff`/`new`), `cabal test` for
the suites (unit suite from `keiro-dsl/`), `mori validate` for registration, and a fresh
coding agent for M6.
