---
id: 310
slug: derive-generated-declaration-stems-from-whole-logical-names-to-fix-bug-11
title: "Derive generated declaration stems from whole logical names to fix BUG-11"
kind: exec-plan
created_at: 2026-10-13T14:19:34Z
intention: "intention_01m4tsyezzeg487dsvychmr0xg"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-13T14:19:34Z
---

# Derive generated declaration stems from whole logical names to fix BUG-11

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


`keiro-dsl` compiles a `.keiro` specification into Haskell modules that a consuming
service builds. Today a read model whose snake_case name contains a Haskell keyword as
one underscore-separated segment, such as `validate_custom_type`, passes `keiro-dsl check`
and scaffolds without complaint, but the generated tree does not compile. The generated
definition module exports `validateCustomtypeReadModel`, the generated harness module
imports `validateCustomTypeReadModel`, and GHC stops with error GHC-61689. The same naming
helper also names workqueue declarations, so a workqueue called `job_type` scaffolds
`jobtypeJobCodec`, `jobtypePayloadCodec`, and `data JobtypeOutcome` beside its own module
segment `JobType` and payload type `JobTypePayload`. Bug report
[BUG-11](../bug-reports/11-read-model-harness-imports-inconsistent-keyword-segment-name.md)
records the read-model failure; the owning repository reproduced it on master after the
0.20.0.0 release.

After this plan, every generated identifier that belongs to one declaration is spelled
from one derivation of the whole logical name. `validate_custom_type` yields
`validateCustomTypeReadModel`, `validateCustomTypeQuery`, `ValidateCustomTypeQueryInput`,
`validateCustomTypeQualifiedTable`, and a harness that imports exactly the exported
spelling; `job_type` yields `jobTypeJobCodec`, `jobTypePayloadCodec`, and
`JobTypeOutcome`. A new compiled conformance suite built from a Language 6 fixture that
declares both names fails to compile before the repair and passes after it. The scaffolder
additionally refuses to write any generated tree in which one generated module's explicit
import of a sibling generated module names something that sibling does not export, so this
class of mismatch cannot reach a consumer again. Whole-name keywords such as
`readmodel type` continue to be rejected by `check` with `GeneratedOccurrenceReserved`.


## Progress


- [x] (2026-10-13) Milestone 0: validate BUG-11 from source on master, reproduce it with the public CLI and GHC 9.12.4, merge GitHub PR #6 as BUG-11, set the report `confirmed`, retain the transcript under `docs/bug-reports/evidence/`, create this plan with its intention, link it from the report body, index, and log, and prove that the Language 6 fixture in this plan checks and scaffolds.
- [ ] Milestone 1: add `keiro-dsl/test/fixtures/keyword-segments.keiro` and the focused generator tests in `keiro-dsl/test/Main.hs` (harness import resolves against the definition's exports, no glued-keyword spellings, every reserved word as a middle and as a trailing segment, whole-name keyword still rejected); run them and record the failures in Surprises & Discoveries.
- [ ] Milestone 1: scaffold the fixture into `keiro-dsl/test/conformance-keyword-segments/` with the public CLI, add `Main.hs` and the `keiro-dsl-conformance-keyword-segments` stanza, track the ledger and fragment, run the suite before the repair and record GHC-61689; set BUG-11 `status: in-progress`, advance `generated`, and log it.
- [ ] Milestone 2: add `deriveUpperCamelName` to `Keiro.Dsl.HaskellName` with unit tests in `keiro-dsl/test/haskell-name/Main.hs`; route the upper branch of `generatedCase` in `Keiro.Dsl.Scaffold` and `pascal` in `Keiro.Dsl.AggregateType` through it.
- [ ] Milestone 2: replace the per-segment stems in `readModelStem`, `emitQueueCodec`, and `emitQueuePolicy` with whole-name derivations; export `readModelStem` and use it in `emitReadModelHarness`; run the focused tests, the keyword-segment suite, and `scripts/check-generated-name-policy.sh`.
- [ ] Milestone 2: delete the two hole stubs of the keyword-segment suite, regenerate the corpus with `just corpus-regen`, confirm only that suite changed, and run `scripts/check-conformance-corpus.sh` and `cabal test keiro-dsl:tests --keep-going`.
- [ ] Milestone 3: add `generatedImportResolutionViolations` to `Keiro.Dsl.ScaffoldRun`, refuse before writes beside `generatedNameInvariantViolations`, add the mutated-module unit test, and prove the whole corpus produces no violation.
- [ ] Milestone 4: update `docs/user/keiro-dsl-reference.md`, add Unreleased entries to `keiro-dsl/CHANGELOG.md` and `CHANGELOG.md`, write ADR-51 and validate the ADR bundle.
- [ ] Milestone 4: run `nix develop -c just verify` and read the exit marker inside the log; set BUG-11 `fixed` with `fixedVersion: unreleased` and a `resolution`, update the index row and log; write Outcomes & Retrospective and perform the ADR distillation pass.


## Surprises & Discoveries


- (2026-10-13) The compile failure is confined to one cross-module reference. In the scaffold of
  the report's specification, `ReadModel.hs`, `ReadModelTable.hs`, the hole stub, and (under
  Language 6) `QueryContract.hs` and `ProjectionCatalog.hs` all use the per-segment spelling
  `validateCustomtype…` consistently, and the aggregate projection module uses whole-name
  spellings for its own helpers (`validateCustomTypeStatusFor`, `validateCustomTypeProjection`)
  while importing the table as `validateCustomtypeQualifiedTable`. Only `ReadModelHarness.hs`
  imports the whole-name spelling, so GHC fails exactly once:

```text
Generated/NamingRepro/ValidateCustomType/ReadModelHarness.hs:4:60: error: [GHC-61689]
    Module ‘Generated.NamingRepro.ValidateCustomType.ReadModel’ does not export ‘validateCustomTypeReadModel’.
    Suggested fix: Perhaps use ‘validateCustomtypeReadModel’
```

- (2026-10-13) Workqueues share the defect without a compile failure. `job_type` scaffolds
  `Generated.<Context>.JobType.QueueCodec` exporting `jobtypePayloadCodec` and
  `jobtypeJobCodec`, and `QueuePolicy` declaring `data JobtypeOutcome`, while the payload type
  is `JobTypePayload` and the module segment is `JobType`. No generated module imports those
  three names, so the tree compiles, but every consumer must write the glued spelling.
- (2026-10-13) `cabal exec -- ghc` inside the Nix shell exposes a store build of
  `keiro-0.20.0.0` whose `hasql-transaction` and `effectful` instances differ from the
  in-project build, so type-checking a generated `ReadModel.hs` that way reports unrelated
  type errors in both the keyword and the control trees. `-fdefer-type-errors` isolates the
  renamer error above. The conformance suite in Milestone 1 compiles through Cabal and does
  not have this problem.


## Decision Log


- Decision: fix the generator, not the validator. `validate_custom_type` is a legitimate name
  whose whole-name derivation `validateCustomType` is a valid, non-reserved identifier;
  rejecting keyword segments would contradict completed IR-16 and break accepted
  specifications. Whole-name keywords such as `readmodel type` stay rejected.
  Rationale: the reserved-word check is only meaningful for a complete lowerCamel
  occurrence; applying it to one segment of a compound name is the defect.
  Date: 2026-10-13
- Decision: repair in two layers. Every stem derives once from the whole logical name through
  the existing `lowerFirst`/`pascal` helpers and the harness reuses `readModelStem` instead of
  re-deriving it; and the upper-case helper `pascal` stops consulting the lowerCamel keyword
  check by using a new `deriveUpperCamelName`, so a remaining per-piece caller (projection
  alias parts built from JSON-pointer segments) cases `type` as `Type`.
  Rationale: the first layer is the single-derivation policy the report asks for; the second
  removes the silent fallback that produced lowercase segments.
  Date: 2026-10-13
- Decision: add a generated-to-generated explicit-import audit to the pre-write refusal path
  rather than only a targeted test.
  Rationale: BUG-11's shape is "a planned import names an occurrence the sibling does not
  export"; `Keiro.Dsl.ScaffoldRun` already parses every planned module before writing, and
  IR-16 promised that planned and emitted occurrences agree.
  Date: 2026-10-13
- Decision: the fixture and conformance suite use Language 6 (a catalog read model with a
  `projection-owner`), matching ADR-49 and the reporting consumer, instead of the report's
  Language 4 form. The focused unit tests still cover the Language 4 inline form through the
  report's own specification text.
  Rationale: Language 6 is the sole pre-1.0 coverage baseline; Language 4 remains accepted and
  covered by the existing corpus.
  Date: 2026-10-13
- Decision: no new generated-Haskell naming edition. The repair changes generated spellings
  only for declarations whose snake_case name contains a reserved segment; read models of that
  shape cannot compile today and workqueues of that shape receive an idiomatic rename recorded
  as a breaking changelog entry.
  Rationale: an edition exists to migrate every consumer; this change touches a shape that is
  either broken or rare, and `scaffold` already reports every overwritten module.
  Date: 2026-10-13
- Decision: BUG-11 moves from `confirmed` to `in-progress` when the compiled suite fails in
  Milestone 1 and to `fixed` with `fixedVersion: unreleased` at the end of Milestone 4.
  Rationale: the bundle's lifecycle rules; `confirmed` already records the owner reproduction.
  Date: 2026-10-13


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


### Vocabulary used in this plan


`keiro-dsl` is the package under `keiro-dsl/`. Its executable reads a `.keiro` file: `keiro-dsl
check FILE` validates it and `keiro-dsl scaffold FILE --out DIR` writes Haskell into `DIR`.
Inside this repository both run as `cabal run -v0 keiro-dsl:exe:keiro-dsl -- check FILE`
from the repository root, inside `nix develop`.

A *specification* declares named things: aggregates, read models, workqueues, projection
owners, and more. A *logical name* is the name as written in the specification. Read models,
workqueues, targets, and rebuild groups use snake_case logical names such as
`validate_custom_type`; aggregates and commands use PascalCase.

The scaffold writes two kinds of module. A *generated module* lives under `Generated/…` and is
overwritten on every scaffold. A *hole module* lives under `<Context>/…Holes.hs`, is created
once with `error "HOLE: …"` bodies, and is then owned by the consumer. A hole module compiles
as created; a consumer fills it later.

A *read model* declares a queryable table. Scaffolding one produces `ReadModelTable.hs` (the
qualified table name), `ReadModel.hs` (the runtime `ReadModel` value and, under Language 5
and later, rebuild helpers), `QueryContract.hs` (Language 5 and later: the query input and
result type aliases), `ReadModelHarness.hs` (a generated self-check that imports the
`ReadModel` value and compares facts about it with the specification), and the hole module
`ReadModelHoles.hs` (the query implementation).

A *workqueue* declares a pgmq-backed job queue. Scaffolding one produces `Queue.hs` (the
payload record), `QueueCodec.hs` (the payload and job codecs), and `QueuePolicy.hs` (the
retry policy and the outcome type).

A *stem* is the lowerCamel prefix shared by one declaration's generated names, for example
`validateCustomType` in `validateCustomTypeReadModel`. An *occurrence* is one Haskell
identifier emitted into generated code: lowerCamel occurrences are values and record fields,
UpperCamel occurrences are types, constructors, and module segments. A *derivation* turns a
logical name into checked occurrences; the only derivation is `deriveHaskellName` in
`keiro-dsl/src/Keiro/Dsl/HaskellName.hs` (module `Keiro.Dsl.HaskellName`).

A *reserved word* is one of the twenty-three words GHC rejects as a term-level identifier
under the generated manifest contract: `case`, `class`, `data`, `default`, `deriving`, `do`,
`else`, `foreign`, `forall`, `if`, `import`, `in`, `infix`, `infixl`, `infixr`, `instance`,
`let`, `module`, `newtype`, `of`, `then`, `type`, and `where`. They are the set
`haskellKeywords` in `Keiro.Dsl.HaskellName`. A *keyword segment* is one of those words used
as a whole underscore-separated segment of a longer logical name.

A *conformance suite* is a Cabal `test-suite` under `keiro-dsl/test/conformance-*` that holds a
scaffold output tree plus a hand-written `Main.hs`, so the generated code is compiled by GHC
and exercised against the live runtime. Each scaffold writes a *ledger*
(`keiro-dsl-ledger.context.<context>.txt`) and a *fragment*
(`keiro-dsl-cabal-fragment.context.<context>.txt`) beside the tree; the corpus regeneration
tool under `keiro-dsl/tools/corpus-regen` finds every suite through its tracked ledger and
re-runs the recorded scaffold invocation, and `scripts/check-conformance-corpus.sh` fails when
the tracked tree drifts from a fresh scaffold.

`docs/bug-reports/` is an OKF bundle validated by `just bug-reports-validate`. Its reports have
no plan field; a report links its plan in the body, and its `status` moves through `reported`,
`confirmed`, `in-progress`, and `fixed` (which needs `fixedVersion` and `resolution`).


### Where the defect lives


Line numbers below are as of commit `0f81c1bb`; search by function name if they drift.

`Keiro.Dsl.HaskellName` derives both cases from one word list and checks both:

```haskell
-- keiro-dsl/src/Keiro/Dsl/HaskellName.hs:166
deriveHaskellName :: NameSourceKind -> NameSite -> Either HaskellNameError DerivedHaskellName
deriveHaskellName source site
  | source == ExplicitHaskellName = Left (InvalidExplicitHaskellName site ((.logicalName) site))
  | otherwise = do
      words' <- segmentLogicalName (source == LogicalWireWord) site
      case words' of
        [] -> Left (EmptyNameSegment site)
        firstWord : restWords -> do
          let upper = T.concat (map upperWord words')
              lower = lowerFirstWord firstWord <> T.concat (map upperWord restWords)
          upperName <- checkedUpperOccurrence site upper
          lowerName <- checkedLowerOccurrence site lower
          pure DerivedHaskellName {upperCamel = upperName, lowerCamel = lowerName}
```

`checkedLowerOccurrence` (same file, about line 204) returns `Left (ReservedGeneratedOccurrence
site candidate)` when the lowerCamel candidate is in `haskellKeywords`. `segmentLogicalName`
splits on single underscores (and hyphens for wire words) and on camel boundaries, so the
whole name `validate_custom_type` becomes the words `validate`, `custom`, `type`, whose upper
form `ValidateCustomType` and lower form `validateCustomType` both pass.

`Keiro.Dsl.Scaffold` (file `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`) wraps that derivation in a
helper that silently returns the input on failure:

```haskell
-- keiro-dsl/src/Keiro/Dsl/Scaffold.hs:10447
lowerFirst :: Text -> Text
lowerFirst = generatedCase HaskellName.LogicalIdentifier False

-- keiro-dsl/src/Keiro/Dsl/Scaffold.hs:10457
pascal :: Text -> Text
pascal = generatedCase HaskellName.LogicalIdentifier True

-- keiro-dsl/src/Keiro/Dsl/Scaffold.hs:10463
generatedCase :: HaskellName.NameSourceKind -> Bool -> Text -> Text
generatedCase source upper name =
  case HaskellName.deriveHaskellName source site of
    Right derived
      | upper -> HaskellName.renderUpperCamelName ((.upperCamel) derived)
      | otherwise -> HaskellName.renderLowerCamelName ((.lowerCamel) derived)
    Left _ -> name
  where
    site = HaskellName.NameSite {kind = HaskellName.GeneratedHelperSite, logicalName = name, owner = "scaffold-renderer", line = 0}
```

Both `pascal` and `lowerFirst` are exported from `Keiro.Dsl.Scaffold` (export list lines 97
and 98), so tests can call them directly. `pascal "type"` derives the words `type`, the upper
form `Type` (valid) and the lower form `type` (reserved), fails, and falls back to `"type"`.

The read-model stem splits the name first and cases each piece on its own:

```haskell
-- keiro-dsl/src/Keiro/Dsl/Scaffold.hs:5554
readModelStem :: ReadModelNode -> Text
readModelStem = lowerFirst . T.concat . map pascal . T.splitOn "_" . (.name)
```

For `validate_custom_type` the pieces case to `Validate`, `Custom`, and the fallback `type`;
concatenated they are `ValidateCustomtype`, and `lowerFirst` turns that into
`validateCustomtype`. `readModelStem` names everything the read-model modules declare: the
`ReadModel` value and its rebuild helpers (`scaffoldReadModel…` where-blocks at lines 4829 and
4870 bind `stem = readModelStem readModel` beside `nodeSegment = pascal ((.name) readModel)`,
which derives the module segment `ValidateCustomType` from the whole name), the query hole and
the query input and result types (lines 6119 to 6124: `readModelStemValue = readModelStem
readModel`, `queryInputType = pascal readModelStemValue <> "QueryInput"`, `readModelValue =
readModelStemValue <> "ReadModel"`), and the qualified-table value (lines 5269, 9885, 10150,
10172, 10178 all append `"QualifiedTable"` to `readModelStem readModel`).

The harness derives the same stem from the whole name instead:

```haskell
-- keiro-dsl/src/Keiro/Dsl/Harness.hs:283 (module Keiro.Dsl.Harness)
emitReadModelHarness :: Text -> Context -> Spec -> ProjectionSupplyAnalysis -> ReadModelNode -> Text
emitReadModelHarness genPrefix ctx spec supplyAnalysis readModel =
  nl $
    ...
      <> [ "import " <> genPrefix <> ".ReadModel (" <> T.intercalate ", " readModelImports <> ")", ... ]
  where
    stem = lowerFirst (pascal ((.name) readModel))      -- line 320
    readModelName = stem <> "ReadModel"                   -- line 321
```

`pascal "validate_custom_type"` is `ValidateCustomType` and `lowerFirst` of that is
`validateCustomType`, so the harness imports `validateCustomTypeReadModel` from a module that
exports `validateCustomtypeReadModel`. `Keiro.Dsl.Harness` imports `Keiro.Dsl.Scaffold`
unqualified (line 66), so exporting `readModelStem` from `Keiro.Dsl.Scaffold` makes it
available there without further import changes.

Two workqueue emitters use the same per-segment pattern:

```haskell
-- keiro-dsl/src/Keiro/Dsl/Scaffold.hs:4688 emitQueueCodec, where-block line 4723
    stem = lowerFirst (T.concat (map pascal (T.splitOn "_" ((.name) w))))
-- keiro-dsl/src/Keiro/Dsl/Scaffold.hs:4729 emitQueuePolicy, where-block line 4771
    outcomeType = T.concat (map pascal (T.splitOn "_" ((.name) w))) <> "Outcome"
```

while the workqueue module segment at lines 4254 and 4293 is `genPrefixFor ctx (pascal
((.name) w))`, a whole-name derivation. The inbox emitter near line 4141 already uses
`stem = pascal ((.name) i)`; the router emitters near lines 5992 and 6114 use `lowerFirst
((.id) router)`; the aggregate projection module near lines 9822 to 9839 uses `lowerFirst
((.table) p)` for `…Projection` and `…StatusFor`. Those whole-name sites are correct and
unchanged.

One more per-piece caller exists for a different reason. `normaliseAliasPart` (line 8681)
builds a projection alias from the segments of a JSON pointer, splitting on every
non-alphanumeric character and applying `pascal` to each piece; the pieces can begin with a
digit, so joining them and deriving once would fail the identifier check. Those aliases are
used only inside the generated module that defines them (`projectionAliasFor`, lines 8688 to
8838), so they compile today, but a pointer segment `type` is spelled `type` inside the alias.
Making `pascal` case a lone reserved word as `Type` fixes this site without changing its
structure.

`Keiro.Dsl.AggregateType` (file `keiro-dsl/src/Keiro/Dsl/AggregateType.hs`, line 482) has its
own `pascal` with the same fallback; it must follow the same upper-only derivation so the two
helpers never disagree.

`Keiro.Dsl.Validate` (file `keiro-dsl/src/Keiro/Dsl/Validate.hs`) already proves at `check`
time that every node's whole logical name derives: `checkedLogicalName` (line 1956) maps a
failed derivation to `IdentUnsafeNormalization` or `GeneratedOccurrenceReserved` through
`nameErrorDiagnostic` (line 1971), and `nodeNameAndLoc` (line 2203) lists `readmodel` and
`workqueue` among the node kinds. That is why `readmodel type` is rejected while
`validate_custom_type` is accepted, and why no accepted specification can reach the
`Left _ -> name` fallback through a whole-name derivation. The collision inventory in the same
file (`nodeModuleOccurrences`, line 2006, and the following helpers) registers module
segments, shared types, aggregate fields, aggregate harness helpers, and workflow awaits; it
does not register read-model or workqueue values, so nothing there needs to change.

`Keiro.Dsl.ScaffoldRun` (file `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`) audits every planned
module before writing: `generatedNameInvariantViolations modules` (line 605, used at line 603
as `namingViolations`) applies `auditGeneratedHaskell` (line 612), which masks comments and
string literals with `maskNonCode`, checks the declared module name against the path, rejects
underscore-bearing declarations, repeated signatures, and reserved occurrences. Milestone 3
adds a sibling audit beside it.


### Which names trigger it


Any read model or workqueue whose snake_case name contains one of the twenty-three reserved
words as a whole segment, in any position except alone (alone it is rejected by `check`).
Names such as `validate_custom_type`, `validate_recipient_type`, `order_data`, `audit_class`,
`job_default`, `if_then`, and `type_registry` all qualify. The reporting consumer hit
`validate_custom_type` and `validate_recipient_type`. The rename workaround recorded in the
report (`validate_customtype`) avoids the segment and must keep working, because
`validate_customtype` derives identically under both paths.


### The reporter's evidence, verified


GitHub PR #6 (merged on 2026-10-13 as commit `0f81c1bb`, renumbered from BUG-8 to BUG-11
because BUG-8 was already allocated) reproduced the failure on released 0.18.0.0 and traced
both paths in release source. The owning repository verified the trace against master (the
excerpts above), reproduced the failure with the report's Language 4 specification using the
in-tree CLI and GHC 9.12.4, and retained the transcript in
`docs/bug-reports/evidence/BUG-11-master-keyword-segment-ghc-61689.txt`. The report is
`confirmed`.


### Reproduction in this repository (2026-10-13)


From the repository root inside `nix develop`, with the report's `keyword.keiro` saved under a
scratch directory `$R`:

```bash
cabal run -v0 keiro-dsl:exe:keiro-dsl -- check "$R/keyword.keiro"
cabal run -v0 keiro-dsl:exe:keiro-dsl -- scaffold "$R/keyword.keiro" --out "$R/out-keyword"
sed -n 20,21p "$R/out-keyword/Generated/NamingRepro/ValidateCustomType/ReadModel.hs"
sed -n 4p "$R/out-keyword/Generated/NamingRepro/ValidateCustomType/ReadModelHarness.hs"
```

prints `OK` for the check, writes the tree, and shows the two spellings:

```text
validateCustomtypeReadModel :: ReadModel ValidateCustomtypeQueryInput ValidateCustomtypeQueryResult
validateCustomtypeReadModel =
import Generated.NamingRepro.ValidateCustomType.ReadModel (validateCustomTypeReadModel)
```

The Language 6 fixture given in Milestone 1 was also checked and scaffolded on master. Its
tree spells `validateCustomtypeReadModel`, `validateCustomtypeQualifiedTable`,
`validateCustomtypeQuery`, `ValidateCustomtypeQueryInput`, `ValidateCustomtypeQueryResult`,
and `validateCustomtypeReadModelBlueprint` in the definition, hole, contract, and catalog
modules, imports `validateCustomTypeReadModel` in the harness, and names the workqueue
declarations `jobtypePayloadCodec`, `jobtypeJobCodec`, and `JobtypeOutcome` beside
`JobTypePayload`. A control specification that renames the read model to
`validate_customtype` scaffolds one consistent spelling and its harness type-checks.


### Relevant architecture decisions


[ADR-19](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
fixes the generated manifest contract (GHC2024 plus `DuplicateRecordFields`,
`NoFieldSelectors`, `OverloadedRecordDot`, `OverloadedStrings`) against which the reserved
word set is defined; this plan keeps that set and the `idiomatic-v2` edition unchanged.
[ADR-22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
governs the ledger and fragment sidecar names the conformance suite tracks; it does not speak
to declaration stems. [ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md)
makes Language 6 the sole pre-1.0 coverage baseline, which is why the new fixture is Language
6. No ADR states that every generated name of one declaration must come from one derivation
of the whole logical name; Milestone 4 writes that decision as ADR-51 (confirm the handle
with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` before writing). The
completed improvement request
[IR-16](../improvement-requests/guarantee-idiomatic-haskell-names-for-generated-declarations.md)
and its [plan 190](190-guarantee-idiomatic-haskell-names-for-generated-declarations.md)
introduced `Keiro.Dsl.HaskellName`; this plan completes their promise for compound names.


### Test infrastructure you will touch


`keiro-dsl/test/Main.hs` is the `keiro-dsl-test` suite (Hspec). The block `describe
"Haskell.name-audit"` near line 5954 shows the pattern this plan extends: `specOf
"test/fixtures/…"` parses a fixture, `legacyCheckedService spec` and `defaultContext
(spec.context)` prepare a scaffold, `scaffoldServiceModules ctx service` returns every planned
`ScaffoldModule` (fields `path`, `text`, `kind`, `origin`), and `generatedTextEndingIn
"…/ReadModelHarness.hs" modules` (line 13303) picks one generated module's text. The block
near line 2140 shows how to parse specification text that is not on disk: `parseSource
"name.keiro" sourceText` returns `Right parsed`, `parsed.spec` is the `Spec`, and
`checkedSource parsed` is the checked service. `scripts/check-generated-name-policy.sh` runs
`cabal test keiro-dsl-test --test-options='--match Haskell.name-audit'`, so tests placed in
that block run in the `generated-name-policy` gate.

`keiro-dsl/test/haskell-name/Main.hs` is the `keiro-dsl-haskell-name-test` suite for
`Keiro.Dsl.HaskellName` alone; it has helpers `logicalSite`, `derivePair`, `shouldReject`, and
a pinned-example table.

`keiro-dsl/test/conformance-readmodel-runtime/` and the stanza
`keiro-dsl-conformance-readmodel-runtime` in `keiro-dsl/keiro-dsl.cabal` are the template for
a read-model conformance suite: `import: warnings, generated-output`, `type:
exitcode-stdio-1.0`, one `hs-source-dirs`, `main-is: Main.hs`, `other-modules` listing every
generated and hole module, and `build-depends` copied from the fragment. The Language 6
query-only tree under `keiro-dsl/test/conformance-nominal-query-only/` (compiled by the
`keiro-dsl-conformance-structural-nominals` stanza, lines 578 onward) shows the module set a
catalog read model produces. `keiro-dsl/test/conformance-corpus-manifest.txt` lists only
suites that need extra facts; a plain suite is discovered from its tracked ledger. `just
corpus-regen` regenerates every suite and `scripts/check-conformance-corpus.sh` checks for
drift.


## Plan of Work


### Milestone 1: proofs that fail before the repair


This milestone adds the fixture, the focused generator tests, and the compiled conformance
suite, and runs all of them against the unrepaired generator so the failures are recorded
before any generator line changes. At the end, `keyword-segments.keiro` exists,
`keiro-dsl-test` has four new failing examples, and `keiro-dsl-conformance-keyword-segments`
fails to compile with GHC-61689.

Create `keiro-dsl/test/fixtures/keyword-segments.keiro` with exactly this content; it was
checked and scaffolded on master during Milestone 0:

```keiro
language keiro-dsl 6
context keyword-segments

id SubscriptionId prefix=subscription

target validate_custom_type_table {
  schema = "billing"
  table = "validate_custom_type"
  reset = clear
}

rebuild-group validate_custom_type_rebuild {
  targets = [ validate_custom_type_table ]
  order = [ validate_custom_type_table ]
}

projection-owner validate_custom_type_writer {
  source = all
  delivery = subscription
  group = validate_custom_type_rebuild
  targets = [ validate_custom_type_table ]
  order = 10
  subscription = "validate-custom-type-writer"
  dedup = "validate-custom-type-writer-v1"
  checkpoint-on-missing = from-beginning
  replay = explicit
}

readmodel validate_custom_type {
  columns {}
  query input = SubscriptionId
  query result = List SubscriptionId
  version = 1
  shape = "fnv1a:3c07a19c552c3547"
  freshness = wait-for-head entire-log
  group = validate_custom_type_rebuild
  targets = [ validate_custom_type_table ]
}

workqueue job_type {
  queue logical = "billing.job_type"
  derive physical = "billing_job_type"
         dlq = "billing_job_type_dlq"
         table = "pgmq.q_billing_job_type"
  payload JobTypePayload {
    subscriptionId -> "subscription_id" : SubscriptionId
  }
  retry maxRetries = 3 delay = 1s dlq = on
  disposition {
    storeFailure -> retry 1s
    commandRejected -> deadLetter
    decodeFailure -> deadLetter
    onCodecReject -> deadLetter
  }
}
```

Add a new `describe "Haskell.keyword-segments"` block directly after the
`describe "Haskell.name-audit"` block in `keiro-dsl/test/Main.hs` (so the name-policy gate's
`--match Haskell.` prefix also selects it only if you widen that match; otherwise it runs with
the full suite, which is sufficient). It holds four examples.

The first example scaffolds the fixture with `scaffoldServiceModules` and checks that the
harness import resolves. Take the text of the module whose path ends in
`ValidateCustomType/ReadModelHarness.hs`, find the line that starts with `import
Generated.KeywordSegments.ValidateCustomType.ReadModel (`, split the parenthesised list on
commas, trim each name, and assert each one occurs as a top-level signature `name ::` in the
text of the module whose path ends in `ValidateCustomType/ReadModel.hs`. Before the repair
this fails because `validateCustomTypeReadModel` is imported and `validateCustomtypeReadModel`
is declared.

The second example asserts the generated spellings. Concatenate the text of every module
returned for the fixture and assert that none of `Customtype`, `customtype`, `Jobtype`, or
`jobtype` occurs, that `validateCustomTypeReadModel ::`, `ValidateCustomTypeQueryInput`,
`validateCustomTypeQualifiedTable ::`, `jobTypeJobCodec ::`, `jobTypePayloadCodec ::`, and
`data JobTypeOutcome` do occur, and that `concatMap auditGeneratedHaskell modules` is empty.

The third example covers every reserved word. For each word `k` in
`Set.toList haskellKeywords`, assert `pascal k == upperFirstOf k` where `upperFirstOf` upper-cases
the first character (write this small helper inline), assert
`pascal ("check_" <> k <> "_name") == "Check" <> upperFirstOf k <> "Name"`, and assert
`lowerFirst ("check_" <> k <> "_name") == "check" <> upperFirstOf k <> "Name"` and
`lowerFirst ("check_" <> k) == "check" <> upperFirstOf k`. Then build the report's Language 4
specification text inline (the `keyword.keiro` text quoted in the bug report, whose two
occurrences of `validate_custom_type` become `check_<k>_name`), parse it with `parseSource`,
scaffold it with `scaffoldServiceModules (defaultContext parsed.spec.context) (checkedSource
parsed)`, and assert the harness import resolves exactly as in the first example. Before the
repair, `pascal "type"` is `"type"` and the stems are glued, so this fails for every word.

The fourth example proves the rejection that must survive. Build the Language 4 text with the
read model named `type` and the projection line `projection type key=subscriptionId`, parse
it, run the same validation the CLI runs (the `check` path used elsewhere in `test/Main.hs`,
for example through `errorCodesOf` near line 2289 if it accepts text, or by writing the text
to a temporary fixture and calling the file-based helper), and assert the diagnostic codes
include `GeneratedOccurrenceReserved`. This passes before and after the repair; it exists so
the repair cannot accidentally widen acceptance.

Run the suite before touching the generator and record the four failures:

```bash
nix develop -c cabal test keiro-dsl-test --test-show-details=direct --test-options='--match Haskell.keyword-segments'
```

Now create the conformance suite. From the repository root inside `nix develop`:

```bash
cabal run -v0 keiro-dsl:exe:keiro-dsl -- scaffold keiro-dsl/test/fixtures/keyword-segments.keiro --out keiro-dsl/test/conformance-keyword-segments
git add keiro-dsl/test/conformance-keyword-segments
git status --short keiro-dsl/test/conformance-keyword-segments
```

The tree must contain `keiro-dsl-ledger.context.keyword-segments.txt` and
`keiro-dsl-cabal-fragment.context.keyword-segments.txt` as tracked files (use `git add -f` if
an ignore rule hides them); the corpus tool regenerates the suite from that ledger. Leave the
two hole modules (`KeywordSegments/ValidateCustomType/ReadModelHoles.hs` and
`KeywordSegments/ProjectionCatalog/ProjectionCatalogHoles.hs`) exactly as created; their
`error "HOLE: …"` bodies compile.

Write `keiro-dsl/test/conformance-keyword-segments/Main.hs`:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Control.Monad (unless)
import Generated.KeywordSegments.JobType.Queue (JobTypePayload)
import Generated.KeywordSegments.JobType.QueueCodec (jobTypeJobCodec, jobTypePayloadCodec)
import Generated.KeywordSegments.JobType.QueuePolicy (JobTypeOutcome (..), jobOutcomeFor)
import Generated.KeywordSegments.ValidateCustomType.ReadModel (validateCustomTypeReadModel)
import Generated.KeywordSegments.ValidateCustomType.ReadModelHarness (readModelFacts, runReadModelFacts)
import Keiro.Codec (Codec)
import Keiro.PGMQ.Codec (JobCodec)
import Keiro.PGMQ.Job (JobOutcome (..), RetryDelay (..))
import Keiro.ReadModel (ReadModel (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
  factsOk <- runReadModelFacts
  let recordOk =
        validateCustomTypeReadModel.name == "keyword-segments-validate-custom-type"
          && validateCustomTypeReadModel.tableName == "validate_custom_type"
          && validateCustomTypeReadModel.schema == "billing"
      policyOk = jobOutcomeFor StoreFailure == Retry (RetryDelay 1)
      allOk = factsOk && all (\(_, expected, actual) -> expected == actual) readModelFacts && recordOk && policyOk
  putStrLn ("read-model facts: " <> show factsOk)
  putStrLn ("runtime record: " <> show recordOk)
  putStrLn ("queue policy: " <> show policyOk)
  unless allOk exitFailure

_usesPayloadCodec :: Codec JobTypePayload
_usesPayloadCodec = jobTypePayloadCodec

_usesJobCodec :: JobCodec JobTypePayload
_usesJobCodec = jobTypeJobCodec
```

The import lines for `JobCodec`, `Codec`, `JobOutcome`, and `RetryDelay` mirror the headers of
the generated `QueueCodec.hs` and `QueuePolicy.hs`; if `JobOutcome` lacks an `Eq` instance,
replace `policyOk` with a `case` that matches `Retry (RetryDelay 1) -> True`. The read-model
field values come from the generated blueprint: the registry name is the context and
read-model name joined with hyphens, and the table and schema come from the target.

Add the stanza to `keiro-dsl/keiro-dsl.cabal` after `keiro-dsl-conformance-readmodel-runtime`,
listing every module the fragment names:

```cabal
-- Plan 310 / BUG-11: a read model and a workqueue whose snake_case names carry the
-- reserved segment `type` must scaffold one consistent idiomatic spelling and compile.
test-suite keiro-dsl-conformance-keyword-segments
  import: warnings, generated-output
  type: exitcode-stdio-1.0
  hs-source-dirs: test/conformance-keyword-segments
  main-is: Main.hs
  other-modules:
    Generated.KeywordSegments.JobType.Queue
    Generated.KeywordSegments.JobType.QueueCodec
    Generated.KeywordSegments.JobType.QueuePolicy
    Generated.KeywordSegments.Nominals
    Generated.KeywordSegments.Nominals.Internal
    Generated.KeywordSegments.ProjectionCatalog
    Generated.KeywordSegments.Structural.NominalLeaves
    Generated.KeywordSegments.StructuralConformance
    Generated.KeywordSegments.ValidateCustomType.QueryContract
    Generated.KeywordSegments.ValidateCustomType.ReadModel
    Generated.KeywordSegments.ValidateCustomType.ReadModelHarness
    Generated.KeywordSegments.ValidateCustomType.ReadModelTable
    KeywordSegments.ProjectionCatalog.ProjectionCatalogHoles
    KeywordSegments.ValidateCustomType.ReadModelHoles

  build-depends:
    aeson,
    base >=4.21 && <5,
    effectful-core,
    hasql-transaction,
    keiro,
    keiro-core,
    keiro-pgmq,
    kiroku-store,
    text >=2.1 && <2.2,
```

Run it before the repair:

```bash
nix develop -c cabal build keiro-dsl:test:keiro-dsl-conformance-keyword-segments
```

The build must fail, and the first error must be GHC-61689 on
`Generated/KeywordSegments/ValidateCustomType/ReadModelHarness.hs` naming
`validateCustomTypeReadModel`; `Main.hs` itself also fails on the not-yet-existing
`jobTypeJobCodec`, `jobTypePayloadCodec`, and `JobTypeOutcome` imports. Copy the first error
into Surprises & Discoveries. Then edit the bug report: `status: in-progress`, advance
`generated.at` to the current UTC time, append one sentence to the owner-confirmation section
saying the compiled suite in this plan fails as predicted, run `okf log add docs/bug-reports
--kind Update -m "…"`, update the BUG-11 row in `docs/bug-reports/index.md`, and run `just
bug-reports-validate`. Commit with the `ExecPlan:` and `Intention:` trailers; the repository
stays buildable except for the deliberately failing new suite, so run the commit with the rest
of the tests green.


### Milestone 2: the generator repair


This milestone makes every stem a whole-name derivation and removes the silent lowercase
fallback for lone reserved words in upper positions. At the end, the four examples and the
conformance suite pass, the existing corpus is byte-identical, and the generated-name policy
gate passes.

In `keiro-dsl/src/Keiro/Dsl/HaskellName.hs`, add an upper-only derivation directly after
`deriveHaskellName` and export it from the module header:

```haskell
-- | Derive only the UpperCamel occurrence of a logical name. Use it where the
-- same words are never emitted as a lowerCamel occurrence: type names,
-- constructors, module segments, and words embedded inside a larger generated
-- name. The reserved term-level words only concern lowerCamel occurrences, so a
-- name such as @type@ cases to @Type@ here while 'deriveHaskellName' still
-- rejects it.
deriveUpperCamelName :: NameSourceKind -> NameSite -> Either HaskellNameError UpperCamelName
deriveUpperCamelName source site
  | source == ExplicitHaskellName = Left (InvalidExplicitHaskellName site ((.logicalName) site))
  | otherwise = do
      words' <- segmentLogicalName (source == LogicalWireWord) site
      case words' of
        [] -> Left (EmptyNameSegment site)
        _ -> checkedUpperOccurrence site (T.concat (map upperWord words'))
```

Add three examples to `keiro-dsl/test/haskell-name/Main.hs` beside "rejects keywords created
by normalization": `deriveUpperCamelName LogicalIdentifier (logicalSite "type")` renders
`"Type"` while `deriveHaskellName` on the same site is `Left (ReservedGeneratedOccurrence …
"type")`; `deriveUpperCamelName LogicalIdentifier (logicalSite "validate_custom_type")`
renders `"ValidateCustomType"`, equal to the upper half of `deriveHaskellName`; and
`deriveUpperCamelName` rejects `"foo__bar"`, `"_foo"`, and a hyphenated `LogicalIdentifier`
exactly as `deriveHaskellName` does (reuse `shouldReject` with a wrapper).

In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, change `generatedCase` so its upper branch uses the
new derivation and its lower branch is unchanged:

```haskell
generatedCase :: HaskellName.NameSourceKind -> Bool -> Text -> Text
generatedCase source upper name
  | upper = case HaskellName.deriveUpperCamelName source site of
      Right derived -> HaskellName.renderUpperCamelName derived
      Left _ -> name
  | otherwise = case HaskellName.deriveHaskellName source site of
      Right derived -> HaskellName.renderLowerCamelName ((.lowerCamel) derived)
      Left _ -> name
  where
    site =
      HaskellName.NameSite
        { HaskellName.kind = HaskellName.GeneratedHelperSite,
          HaskellName.logicalName = name,
          HaskellName.owner = "scaffold-renderer",
          HaskellName.line = 0
        }
```

Make the same change to `pascal` in `keiro-dsl/src/Keiro/Dsl/AggregateType.hs` (line 482),
which keeps its `GeneratedTypeSite` site and `"aggregate-type"` owner. Keep `Keiro.Dsl.Validate`
on `deriveHaskellName` everywhere: the validator's job is to reject whole names whose
lowerCamel occurrence is reserved, and the fourth example of Milestone 1 pins that.

Replace the three per-segment stems in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`:

```haskell
-- | The lowerCamel stem shared by every generated declaration of a read model,
-- including the harness import of the ReadModel value. Derived exactly once from
-- the whole logical name: casing underscore segments separately applies the
-- reserved-word check to one word of a compound name and glued the spellings
-- that BUG-11 reports.
readModelStem :: ReadModelNode -> Text
readModelStem = lowerFirst . (.name)
```

In `emitQueueCodec` change the where-binding to `stem = lowerFirst ((.name) w)`, and in
`emitQueuePolicy` change it to `outcomeType = pascal ((.name) w) <> "Outcome"`. Add
`readModelStem` to the export list of `Keiro.Dsl.Scaffold` next to `scaffoldReadModel`. In
`keiro-dsl/src/Keiro/Dsl/Harness.hs` replace line 320 with `stem = readModelStem readModel`.
Search the file for any other `T.splitOn "_"` combined with `map pascal` and confirm none
remains except `normaliseAliasPart`, whose per-piece structure stays because pieces may begin
with digits; it now cases `type` as `Type` through the repaired `pascal`. If
`scripts/check-keiro-dsl-api-boundaries.py` (the `dsl-api-boundaries` gate) objects to the
new export, keep `readModelStem` internal and instead export a `readModelHarnessStem` wrapper
with the same body under whichever module the script allows, but do not re-derive the stem in
`Keiro.Dsl.Harness`.

Run the focused tests and the compiled suite:

```bash
nix develop -c cabal test keiro-dsl-haskell-name-test --test-show-details=direct
nix develop -c cabal test keiro-dsl-test --test-show-details=direct --test-options='--match Haskell.keyword-segments'
nix develop -c cabal test keiro-dsl:test:keiro-dsl-conformance-keyword-segments --test-show-details=direct
```

The third command still fails at this point because the tracked tree was scaffolded before the
repair. Delete the two hole stubs, regenerate the corpus, and inspect what changed:

```bash
rm keiro-dsl/test/conformance-keyword-segments/KeywordSegments/ValidateCustomType/ReadModelHoles.hs
rm keiro-dsl/test/conformance-keyword-segments/KeywordSegments/ProjectionCatalog/ProjectionCatalogHoles.hs
nix develop -c just corpus-regen
git status --short keiro-dsl/test
```

Only files under `keiro-dsl/test/conformance-keyword-segments/` may change; every other suite
is byte-identical because no existing fixture uses a reserved segment. If any other file
changes, the repair altered a spelling it must not have: stop, diff it, and record the finding
before continuing. Then run the suite again and expect it to pass, printing `read-model facts:
True`, `runtime record: True`, and `queue policy: True`. Finish the milestone with the
policy gate and the corpus check:

```bash
nix develop -c scripts/check-generated-name-policy.sh
nix develop -c scripts/check-conformance-corpus.sh
nix develop -c cabal test keiro-dsl:tests --keep-going
```

Commit with the trailers.


### Milestone 3: the import-resolution audit


This milestone adds the guard that would have caught BUG-11 before any file was written: when
one planned generated module imports a sibling planned generated module with an explicit
import list, every listed name must be exported by that sibling. At the end, the scaffolder
refuses a mutated pair of modules with a named diagnostic and accepts the entire corpus.

In `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`, beside `generatedNameInvariantViolations`, add:

```haskell
-- | Every explicit import of a sibling planned module must name something that
-- sibling exports. A planned occurrence that the sibling never emits is exactly
-- the BUG-11 shape (the read-model harness imported a spelling the definition
-- did not declare), so it is refused before any write.
generatedImportResolutionViolations :: [ScaffoldModule] -> [Text]
```

Implement it as follows. Build a map from module name (via `moduleNameOf . (.path)`) to the
set of names the module exports: parse the `module M (…) where` header after `maskNonCode`;
when the header has an export list, the set is its entries with any `(..)` or `(A, B)` suffix
removed, dropping entries that start with `module ` (re-exported modules) and operator
sections in parentheses; when the header has no export list, the set is every top-level
signature name (`name ::` at column one) plus every `data`, `newtype`, `type`, and `class`
head. Then, for every planned module whose `kind` is `Generated` or `HoleStub`, scan its masked
text for lines beginning `import` that name a module present in the map and carry a
parenthesised import list without `hiding`; qualified imports with a list are included. For
each listed name (same suffix stripping; skip operators), report
`<path>:<line>: imports '<name>' from <Module>, which exports no such name` when the name is
absent from the sibling's set. Modules not in the map (runtime libraries, consumer modules)
are skipped. Re-exports are honoured because the export list is consulted first.

Wire it where `namingViolations` is computed (line 603): compute `importViolations =
generatedImportResolutionViolations modules` and append it to the same refusal so the
scaffolder returns the existing generated-name refusal with the new lines included. Read the
refusal rendering (`renderRefusals`) to keep the output shape.

Add two examples to a new `describe "Haskell.import-resolution"` block in
`keiro-dsl/test/Main.hs`. The first builds two `ScaffoldModule` values by hand, a definition at
`Generated/Demo/Foo/ReadModel.hs` exporting `fooReadModel` and a harness at
`Generated/Demo/Foo/ReadModelHarness.hs` importing `fooReadmodel`, and asserts the violation
list has one entry mentioning `ReadModelHarness.hs`, `fooReadmodel`, and
`Generated.Demo.Foo.ReadModel`; it also asserts that a sibling pair with a re-export (a module
whose export list names `Bar` imported from a third module) and an import of a runtime module
produce no violation. The second scaffolds `test/fixtures/keyword-segments.keiro` and
`test/fixtures/incident-paging/incident-paging.keiro` and asserts the violation list is empty.
Finally prove the corpus:

```bash
nix develop -c scripts/check-conformance-corpus.sh
```

The corpus check re-runs every recorded scaffold invocation through the same refusal path, so a
false positive anywhere in the corpus fails here. Commit with the trailers.


### Milestone 4: documentation, changelog, ADR, gate, and lifecycle


This milestone records the behaviour for users and maintainers and closes the bug report. At
the end, the reference explains segment versus whole-name reserved words, both changelogs carry
Unreleased entries, ADR-51 exists and validates, `just verify` passes, and BUG-11 is `fixed`.

In `docs/user/keiro-dsl-reference.md`, add a row `| validate_custom_type | ValidateCustomType
| validateCustomType |` to the naming table near line 168 and, after the sentence ending
"normalization to a Haskell keyword is rejected before scaffolding." near line 174, add: "The
check applies to the whole generated occurrence, never to one underscore segment: `type` alone
is rejected, while `validate_custom_type` is accepted and every generated declaration,
import, and harness spells it `validateCustomType…`." In the identifier bullet near line 230
that lists the keywords, add the same clarification in one sentence after "Use a field's
`haskell` alias when its DSL name must remain a hard keyword."

In `keiro-dsl/CHANGELOG.md` under `## [Unreleased]`, add a `### Breaking Changes` entry: a
workqueue whose snake_case name contains a reserved segment now scaffolds idiomatic names
(`job_type` gives `jobTypeJobCodec`, `jobTypePayloadCodec`, and `JobTypeOutcome` instead of
`jobtypeJobCodec`, `jobtypePayloadCodec`, and `JobtypeOutcome`); consumers of such names
rename their references after re-scaffolding. Add a `### Fixed` entry for BUG-11: read models
with a reserved segment now compile because the definition, query contract, hole, and harness
share one whole-name stem, and `scaffold` refuses a generated tree whose generated-to-generated
explicit imports do not resolve. In the root `CHANGELOG.md` under `## [Unreleased]`, add one
`keiro-dsl` bullet summarising both, pointing at
`docs/bug-reports/11-read-model-harness-imports-inconsistent-keyword-segment-name.md`.

Write ADR-51 in `docs/adr/` following `docs/adr/profile.dhall` and the frontmatter of
`docs/adr/0050-…md` (fields `type`, `title`, `description`, `timestamp`, `docId`, `status`,
`date`). Allocate the handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`
and name the file `0051-generated-declaration-names-derive-once-from-the-whole-logical-name.md`.
Its decision: every generated occurrence that belongs to one declaration is derived from one
derivation of that declaration's whole logical name; the reserved term-level word set applies
to complete lowerCamel occurrences only, so an upper-position derivation never consults it;
generators must not case underscore segments independently; and a planned explicit import
between generated modules is audited against the sibling's exports before any write. Record
the rejected alternative (reject keyword segments at `check`) and the consequence (consumers
with reserved segments in workqueue names see an idiomatic rename). Append the ADR to
`docs/adr/log.md` with `okf log add docs/adr --kind Addition -m "…"` and run:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Run the full gate and read the exit marker inside the log rather than trusting the terminal:

```bash
nix develop -c just verify > /tmp/keiro-verify-310.log 2>&1; echo "exit: $?" >> /tmp/keiro-verify-310.log
tail -5 /tmp/keiro-verify-310.log
```

`just verify` stops at its first failing recipe, so if it fails, fix that recipe and run it
again until the log ends with `exit: 0`.

Close the report: set `status: fixed`, add `fixedVersion: unreleased` and a one-sentence
`resolution`, advance `generated.at`, append a short "Resolution" paragraph to the body naming
this plan and the new conformance suite, update the BUG-11 row in `docs/bug-reports/index.md`
to `fixed` with the plan link and "Implemented; keyword-segment conformance suite compiles",
run `okf log add docs/bug-reports --kind Update -m "…"`, and run `just
bug-reports-validate`. Write the Outcomes & Retrospective section of this plan, then perform
the ADR distillation pass: re-read the Decision Log and Surprises & Discoveries and confirm
ADR-51 carries everything durable (the per-segment pattern, the upper-only derivation, and the
import audit) while the `cabal exec` environment note stays here. Commit with the trailers.


## Concrete Steps


All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` inside the
Nix shell (`nix develop -c <command>` or after `nix develop`). Every commit carries the
trailers `ExecPlan:
docs/plans/310-derive-generated-declaration-stems-from-whole-logical-names-to-fix-bug-11.md`
and `Intention: intention_01m4tsyezzeg487dsvychmr0xg`.

Milestone 1, in order: write `keiro-dsl/test/fixtures/keyword-segments.keiro`; run
`cabal run -v0 keiro-dsl:exe:keiro-dsl -- check keiro-dsl/test/fixtures/keyword-segments.keiro`
and expect `OK`; add the four examples to `keiro-dsl/test/Main.hs`; run
`cabal test keiro-dsl-test --test-show-details=direct --test-options='--match Haskell.keyword-segments'`
and expect three failures and one pass (the rejection example); scaffold the suite tree,
write `Main.hs`, add the stanza; run
`cabal build keiro-dsl:test:keiro-dsl-conformance-keyword-segments` and expect GHC-61689;
update the bug report, index, and log; run `just bug-reports-validate`; commit.

Milestone 2, in order: edit `HaskellName.hs`, its test, `Scaffold.hs`, `AggregateType.hs`,
`Harness.hs`; run the haskell-name suite and the focused examples and expect all green; delete
the two hole stubs; run `just corpus-regen`; confirm with `git status --short keiro-dsl/test`
that only `keiro-dsl/test/conformance-keyword-segments/` changed; run the conformance suite
and expect `read-model facts: True`, `runtime record: True`, `queue policy: True`; run
`scripts/check-generated-name-policy.sh`, `scripts/check-conformance-corpus.sh`, and
`cabal test keiro-dsl:tests --keep-going`; commit.

Milestone 3, in order: add `generatedImportResolutionViolations` and wire it; add the two
examples; run `cabal test keiro-dsl-test --test-options='--match Haskell.import-resolution'`;
run `scripts/check-conformance-corpus.sh`; commit.

Milestone 4, in order: edit the reference, both changelogs, write ADR-51 and log it; validate
the ADR bundle; run `just verify` into a log and read its exit marker; close BUG-11; write
Outcomes & Retrospective; commit.


## Validation and Acceptance


The change is accepted when all of the following hold on the final commit.

Scaffolding `keiro-dsl/test/fixtures/keyword-segments.keiro` into a scratch directory prints
no refusal, and `grep -rn "Customtype\|customtype\|Jobtype\|jobtype"` over the output finds
nothing, while `grep -rn "validateCustomTypeReadModel ::" ` finds the definition and the
harness's import line names the same identifier.

`cabal test keiro-dsl:test:keiro-dsl-conformance-keyword-segments --test-show-details=direct`
passes and prints the three `True` lines; `git stash`-ing the Milestone 2 generator change and
re-running `just corpus-regen` followed by the same test reproduces GHC-61689, proving the
suite guards the repair (do this once, then `git stash pop` and regenerate again).

`cabal test keiro-dsl-test --test-options='--match Haskell.keyword-segments'` and
`--match Haskell.import-resolution` pass; `cabal test keiro-dsl-haskell-name-test` passes;
`cabal run -v0 keiro-dsl:exe:keiro-dsl -- check` on a specification declaring `readmodel
type` still prints `error[GeneratedOccurrenceReserved]`.

Hand-mutating one generated module's import list and feeding the pair to
`generatedImportResolutionViolations` yields a diagnostic naming the importing path, the
missing name, and the sibling module; `scripts/check-conformance-corpus.sh` passes, proving
the audit accepts every tracked suite.

`just verify` ends with `exit: 0` in its log; `okf validate docs/adr …` and `just
bug-reports-validate` pass; BUG-11 is `fixed` with `fixedVersion: unreleased`.


## Idempotence and Recovery


Scaffolding into `keiro-dsl/test/conformance-keyword-segments/` is repeatable: generated
modules are overwritten and hole modules are left alone, so deleting the two hole stubs before
`just corpus-regen` is the only way to pick up their corrected spellings after Milestone 2.
`just corpus-regen` is safe to run at any time; if it changes a suite other than the new one,
revert that suite with `git checkout -- <dir>` and investigate the generator change before
proceeding.

If the conformance suite fails to compile for a reason other than GHC-61689 in Milestone 1 (for
example a runtime import name in `Main.hs` that does not exist), compare `Main.hs` against the
generated headers and against `keiro-dsl/test/conformance-readmodel-runtime/Main.hs`, fix the
import, and re-run; do not alter generated files by hand.

If `just verify` fails in a recipe unrelated to this plan, record the failing recipe and its
output in Surprises & Discoveries, fix it in a separate commit if it is a latent defect, and
re-run; the gate aborts at the first failure, so repeat until the log ends with `exit: 0`.

Bug-report edits are plain Markdown and can be redone; `okf log add` appends, so run it once
per lifecycle change and remove a duplicate line by hand if a command is repeated.


## Interfaces and Dependencies


`Keiro.Dsl.HaskellName` (`keiro-dsl/src/Keiro/Dsl/HaskellName.hs`) gains and exports:

```haskell
deriveUpperCamelName :: NameSourceKind -> NameSite -> Either HaskellNameError UpperCamelName
```

with the same segmentation and separator rules as `deriveHaskellName` and no reserved-word
check. `deriveHaskellName`, `checkedLowerOccurrence`, and `haskellKeywords` are unchanged.

`Keiro.Dsl.Scaffold` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`) keeps the exported helpers
`pascal :: Text -> Text` and `lowerFirst :: Text -> Text`; `pascal` now renders a lone reserved
word in UpperCamel (`pascal "type" == "Type"`), and both remain identity on input that cannot
be derived. It exports `readModelStem :: ReadModelNode -> Text`, now `lowerFirst . (.name)`.
`emitQueueCodec` and `emitQueuePolicy` derive from the whole workqueue name. The generated
module and value names for a read model `n` are, with `s = lowerFirst n` and `S = pascal n`:
module segment `S`, values `sReadModel`, `sQualifiedTable`, `sQuery`, rebuild helpers
`startSRebuild`/`finishSRebuild`/`abandonSRebuild` where emitted, and types `SQueryInput` and
`SQueryResult`. For a workqueue `n`: module segment `S`, values `sPayloadCodec` and
`sJobCodec`, and type `SOutcome`.

`Keiro.Dsl.AggregateType` (`keiro-dsl/src/Keiro/Dsl/AggregateType.hs`) keeps `pascal` with the
upper-only derivation.

`Keiro.Dsl.Harness` (`keiro-dsl/src/Keiro/Dsl/Harness.hs`) binds the read-model harness stem
to `readModelStem readModel`; its generated output is unchanged for every name without a
reserved segment.

`Keiro.Dsl.ScaffoldRun` (`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`) gains and exports:

```haskell
generatedImportResolutionViolations :: [ScaffoldModule] -> [Text]
```

evaluated beside `generatedNameInvariantViolations` on every planned module set before
writes, with diagnostics of the form
`<path>:<line>: imports '<name>' from <Module>, which exports no such name`.

New test artefacts: `keiro-dsl/test/fixtures/keyword-segments.keiro`;
`keiro-dsl/test/conformance-keyword-segments/` (generated tree, two hole stubs, `Main.hs`,
ledger, fragment); the `keiro-dsl-conformance-keyword-segments` stanza in
`keiro-dsl/keiro-dsl.cabal` depending on `aeson`, `base`, `effectful-core`,
`hasql-transaction`, `keiro`, `keiro-core`, `keiro-pgmq`, `kiroku-store`, and `text`; the
`Haskell.keyword-segments` and `Haskell.import-resolution` blocks in
`keiro-dsl/test/Main.hs`; three examples in `keiro-dsl/test/haskell-name/Main.hs`.

Documents: `docs/user/keiro-dsl-reference.md`, `keiro-dsl/CHANGELOG.md`, `CHANGELOG.md`,
`docs/adr/0051-…md` plus `docs/adr/log.md`, and
`docs/bug-reports/11-read-model-harness-imports-inconsistent-keyword-segment-name.md` with
`docs/bug-reports/index.md` and `docs/bug-reports/log.md`. External tools: `okf` for bundle
validation, logging, and ID allocation; `just` recipes `corpus-regen`, `bug-reports-validate`,
`generated-name-policy`, `conformance-corpus-policy`, and `verify`.
