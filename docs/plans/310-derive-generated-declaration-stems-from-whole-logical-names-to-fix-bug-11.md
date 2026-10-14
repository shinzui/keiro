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
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-13T14:43:45Z
      mode: "update"
      note: "Stem formula corrected to lowerFirst . pascal for byte-identity; stability example and fail-open re-export rule added"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:09:00Z
      mode: "update"
      note: "Corrected import-audit soundness, corpus sequencing, runtime assertion, Language 6 coverage, naming scope and migration guidance"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:09:38Z
      verdict: "approved"
      note: "Approved after corrections: verified source, ADRs and three Nix-shell scaffolds; bounded audit and repaired validation workflow and compatibility coverage"
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
additionally refuses a planned generated-to-generated import of a plain value name when an
explicit sibling export list proves that name absent. This bounded audit catches BUG-11;
GHC remains the authority for import forms and export sets the audit cannot resolve. Whole-name keywords such as
`readmodel type` continue to be rejected by `check` with `GeneratedOccurrenceReserved`.


## Progress


- [x] (2026-10-13) Correctness review: verified the Language 6 scaffold and source claims; corrected audit scope, compatibility coverage, sample code, and corpus sequencing. Implementation remains pending.
- [x] (2026-10-13) Milestone 0: validate BUG-11 from source on master, reproduce it with the public CLI and GHC 9.12.4, merge GitHub PR #6 as BUG-11, set the report `confirmed`, retain the transcript under `docs/bug-reports/evidence/`, create this plan with its intention, link it from the report body, index, and log, and prove that the Language 6 fixture in this plan checks and scaffolds.
- [ ] Milestone 1: add `keiro-dsl/test/fixtures/keyword-segments.keiro` and the focused generator tests in `keiro-dsl/test/Main.hs` (harness import resolves against the definition's exports, no glued-keyword spellings, every reserved word in leading, middle, and trailing positions in both declaration kinds, whole-name keyword still rejected); run them and record the failures in Surprises & Discoveries.
- [ ] Milestone 1: scaffold the fixture into `keiro-dsl/test/conformance-keyword-segments/` with the public CLI, add `Main.hs` and the `keiro-dsl-conformance-keyword-segments` stanza, track the ledger and fragment, run the suite before the repair and record GHC-61689; set BUG-11 `status: in-progress`, advance `generated`, and log it.
- [ ] Milestone 2: add `deriveUpperCamelName` to `Keiro.Dsl.HaskellName` with unit tests in `keiro-dsl/test/haskell-name/Main.hs`; route the upper branch of `generatedCase` in `Keiro.Dsl.Scaffold` and `pascal` in `Keiro.Dsl.AggregateType` through it.
- [ ] Milestone 2: replace the per-segment stems in `readModelStem`, `emitQueueCodec`, and `emitQueuePolicy` with whole-name derivations; export `readModelStem` and use it in `emitReadModelHarness`; add the structural projection regression and run the focused tests; run the compiled suite and policy gate after regeneration.
- [ ] Milestone 2: refresh only the two untouched test hole stubs, regenerate with the explicit local `--allow-dirty` option, review all corpus changes, run the tests, commit the green change, and then run `scripts/check-conformance-corpus.sh` on clean corpus paths.
- [ ] Milestone 3: add `generatedImportResolutionViolations` to `Keiro.Dsl.ScaffoldRun`, refuse before writes beside `generatedNameInvariantViolations`, add mutation and conservative-resolution tests, and prove the clean corpus produces no violation.
- [ ] Milestone 4: update `docs/user/keiro-dsl-reference.md`, add Unreleased entries to `keiro-dsl/CHANGELOG.md` and `CHANGELOG.md`, allocate the naming ADR handle and validate the ADR bundle.
- [ ] Milestone 4: run `nix develop -c just verify` and read the exit marker inside the log; set BUG-11 `fixed` with `fixedVersion: unreleased` and a `resolution`, update the index row and log; write Outcomes & Retrospective and perform the ADR distillation pass.


## Surprises & Discoveries


- (2026-10-13 review) The public CLI successfully scaffolded the exact Language 6 fixture in
  a scratch directory through `nix develop -c cabal run -v0 keiro-dsl:exe:keiro-dsl`. Its
  fragment confirms all fourteen proposed module entries and the dependency inventory.
  Source inspection confirms `JobOutcome` derives `Show` only, corpus regeneration rejects
  dirty paths by default, and corpus check requires a committed clean tree. Two additional
  Nix-shell scaffolds confirmed `a_b_test` yields `AbTestQueryInput`, and a `type` wire key
  in the Language 6 mapped fixture exports `templateStatetypeWitness`, `templateStatetypeGet`,
  and `templateStatetypeRawGet`, confirming the public projection rename scope.
- (2026-10-13 review) `normaliseAliasPart` feeds exported structural witness/getter names as
  well as local aliases. An import audit that strips `T(..)` to `T` cannot prove a separately
  imported constructor absent; implicit exports also include unsigned bindings. The revised
  audit refuses only cases with a complete known export set and leaves unknown cases to GHC.

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


- Decision: keep pre-fix failures as recorded working-tree evidence until the repair is green;
  use the corpus driver's documented dirty override only for reviewed local regeneration,
  and commit corpus changes before drift checks. Do not undo committed work with `git stash`.
  Rationale: the actual corpus tool enforces clean paths for both ordinary regeneration and
  every check, and intermediate committed failures conflict with the ExecPlan commit contract.
  Date: 2026-10-13
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
- Decision: the fixture, conformance suite, and new inline positive examples use Language 6
  (a catalog read model with a `projection-owner`), matching ADR-49. The Language 4 report
  remains historical reproduction evidence.
  Rationale: ADR-49 requires new positive DSL coverage, including embedded source, to use 6.
  Date: 2026-10-13
- Decision: no new generated-Haskell naming edition. The repair changes generated spellings
  for affected read-model and workqueue names and for structural projection names derived
  from keyword wire-path pieces. Record all those public renames and the required edits to
  existing consumer hole modules as breaking changelog guidance.
  Rationale: retain the plan's targeted bug-fix scope within `idiomatic-v2`, but explicitly
  advertise the affected source API changes and require consumer recompilation. Do not infer
  that all affected code was previously unbuildable or that regeneration updates hand-owned code.
  Date: 2026-10-13
- Decision: the whole-name stem is `lowerFirst . pascal`, never `lowerFirst` alone, and the
  plan pins `a_b_test` and `x_y_coords` as regression guards.
  Rationale: `lowerFirst (pascal n)` equals the old per-segment concatenation for every name
  whose segments all derive, so only reserved segments change spelling; `lowerFirst n` would
  also rename names made of single-letter or all-caps segments (`aBTest…` instead of
  `abTest…`), a consumer-visible change the bug does not justify. Verified on master on
  2026-10-13 by scaffolding `a_b_test`.
  Date: 2026-10-13
- Decision: the import audit checks plain value imports against complete explicit sibling
  export lists only. Unsupported syntax, wildcard children, module re-exports, and implicit
  export lists make absence unknown; they never justify a refusal. Only `Generated` modules
  are import targets for this audit, because planned hole templates do not describe existing
  hand-owned files.
  Rationale: a pre-write gate must never treat an incomplete export inventory as complete.
  Date: 2026-10-13
- Decision: BUG-11 moves from `confirmed` to `in-progress` when the compiled suite fails in
  Milestone 1 and to `fixed` with `fixedVersion: unreleased` at the end of Milestone 4.
  Rationale: the bundle's lifecycle rules; `confirmed` already records the owner reproduction.
  Date: 2026-10-13


## Outcomes & Retrospective


Correctness review on 2026-10-13 verified the Language 6 fixture with the public CLI in
the Nix shell and corrected the implementation and validation instructions below. No
generator implementation or passing post-fix conformance result is claimed yet.


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
digit, so joining them and deriving once would fail the identifier check. Some aliases are local, but `normaliseAliasPart` also feeds `projectionNameStem` near
line 2668, and `emitStructuralProjections` exports the resulting witness/getter functions.
A root `Thing` with wire key `type` currently yields `thingtypeWitness` and `thingtypeGet`;
the upper-only repair yields `thingTypeWitness` and `thingTypeGet`. This is public API churn
outside read-model/workqueue logical names and needs a focused regression and migration note.
The wire key and JSON pointer retain their original bytes.

`Keiro.Dsl.AggregateType` (file `keiro-dsl/src/Keiro/Dsl/AggregateType.hs`, line 482) has its
own `pascal` with the same fallback; it must follow the same upper-only derivation so the two
helpers never disagree.

`Keiro.Dsl.Validate` (file `keiro-dsl/src/Keiro/Dsl/Validate.hs`) already proves at `check`
time that every node's whole logical name derives: `checkedLogicalName` (line 1956) maps a
failed derivation to `IdentUnsafeNormalization` or `GeneratedOccurrenceReserved` through
`nameErrorDiagnostic` (line 1971), and `nodeNameAndLoc` (line 2203) lists `readmodel` and
`workqueue` among the node kinds. That is why `readmodel type` is rejected while
`validate_custom_type` is accepted, and why direct derivation of an accepted declaration
name succeeds. This does not validate arbitrary renderer fragments, such as digit-leading
wire-path pieces, which remain outside that guarantee. The collision inventory in the same
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
of the whole logical name; Milestone 4 writes a naming ADR (allocate its handle
with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` at implementation time). The
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
`keiro-dsl-test` has five examples, three failing before the repair and two passing, and `keiro-dsl-conformance-keyword-segments`
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
`describe "Haskell.name-audit"` block in `keiro-dsl/test/Main.hs`. The existing name-policy
gate selects only `Haskell.name-audit`; run this new block explicitly using the command below
and in the full DSL suite. It initially holds five examples.

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
`Set.toList haskellKeywords`, assert `pascal k == upperFirstOf k`, where the small test helper
`upperFirstOf` upper-cases the first character. For each of `<k>_registry`, `check_<k>_name`,
and `check_<k>`, derive the expected upper spelling by upper-casing each underscore-delimited
piece and concatenating, and the expected lower spelling by lower-casing its first character.
Assert the casing helpers agree. Then load the Language 6 fixture text and, separately for
read models and workqueues, replace only the declaration line (`readmodel validate_custom_type {`
or `workqueue job_type {`) with that variant. Leave catalog identities, SQL/wire names, and
payload type unchanged. Parse each variant with `parseSource`, obtain `checkedSource parsed`,
assert `validateService` has no Error diagnostics, and scaffold it. For read models compare
harness imports with actual exports and assert the expected value/type spellings; for workqueues
assert both codec names and the outcome type. This catches all three positions in both emitter
families, rather than testing only the already-correct whole-name helper.

The fourth example proves the rejection that must survive. Replace only the fixture's read-model
declaration line with `readmodel type {`, parse it with `parseSource`, and inspect
`validateService (checkedSource parsed)`: select `.code` from diagnostics whose `.severity`
is `Error` and assert it includes `GeneratedOccurrenceReserved`. `errorCodesOf` accepts a file
path, not source text. Do not scaffold this invalid service. This example passes before and
after the repair.

The fifth example pins names the repair must not change. Make Language 6 variants by replacing
only the fixture's read-model declaration line with `readmodel a_b_test {` and
`readmodel x_y_coords {`. Assert `ReadModel.hs` declares `abTestReadModel ::` and
`xyCoordsReadModel ::`, and each harness imports the same name. Also pin the contract types
`AbTestQueryInput` and `XyCoordsQueryInput`: query type names derive from the lower stem,
whereas the module segments remain `ABTest` and `XYCoords`. These are passing controls, not
an exhaustive proof over all possible logical names.

Run the suite before touching the generator and record the three failures and two passing controls:

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
      policyOk = case jobOutcomeFor StoreFailure of
        Retry (RetryDelay 1) -> True
        _ -> False
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
the generated `QueueCodec.hs` and `QueuePolicy.hs`; `JobOutcome` derives only `Show`, so the case match above is required. The read-model
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

The build must fail with GHC-61689 on
`Generated/KeywordSegments/ValidateCustomType/ReadModelHarness.hs` naming
`validateCustomTypeReadModel`; `Main.hs` itself also fails on the not-yet-existing
`jobTypeJobCodec`, `jobTypePayloadCodec`, and `JobTypeOutcome` imports. Copy the first error
into Surprises & Discoveries. Then edit the bug report: `status: in-progress`, advance
`generated.at` to the current UTC time, append one sentence to the owner-confirmation section
saying the compiled suite in this plan fails as predicted, run `okf log add docs/bug-reports
--kind Update -m "…"`, update the BUG-11 row in `docs/bug-reports/index.md`, and run `just
bug-reports-validate`. Keep the failing proof uncommitted until Milestone 2 repairs it; record its output here now.
Commit the tests and repair together when they are green, using the `ExecPlan:` and
`Intention:` trailers. Staging files for corpus discovery does not require a failing commit.


### Milestone 2: the generator repair


This milestone makes every stem a whole-name derivation and removes the silent lowercase
fallback for lone reserved words in upper positions. At the end, all six focused examples (including the projection regression added below) and
the conformance suite pass, all corpus diffs are accounted for, and the generated-name policy
gate passes. Review any structural projection rename as well as declaration stems.

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
exactly as `deriveHaskellName` does (assert `isLeft` directly; the existing `shouldReject`
helper is specialized to `deriveHaskellName`).

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
readModelStem = lowerFirst . pascal . (.name)
```

The formula is `lowerFirst . pascal`, not `lowerFirst` alone, and this matters. `pascal` of the
whole name concatenates the UpperCamel words of every segment, which is exactly what the
per-segment concatenation produced for every segment that derived successfully, and
`lowerFirst` of that UpperCamel text re-splits it on camel boundaries exactly as the old
`readModelStem` and today's harness do. So the new stem is byte-identical to the old one for
every name without a reserved segment, including names made of single-letter or all-caps
segments: `a_b_test` stays `abTestReadModel` (verified on master on 2026-10-13: definition and
harness both spell it that way, under module segment `ABTest`). `lowerFirst` applied directly
to `a_b_test` would instead derive `aBTest…`, a silent rename for such names, because the
whole-name lower derivation lower-cases only the first word. In `emitQueueCodec` change the
where-binding to `stem = lowerFirst (pascal ((.name) w))` for the same reason, and in
`emitQueuePolicy` change it to `outcomeType = pascal ((.name) w) <> "Outcome"`. Add
`readModelStem` to the export list of `Keiro.Dsl.Scaffold` next to `scaffoldReadModel`. In
`keiro-dsl/src/Keiro/Dsl/Harness.hs` replace line 320 with `stem = readModelStem readModel`.
Search the file for any other `T.splitOn "_"` combined with `map pascal` and confirm none
remains except `normaliseAliasPart`, whose per-piece structure stays because pieces may begin
with digits; it now cases `type` as `Type` through the repaired `pascal`. The export is not among the protected constructors or accessors in
`scripts/check-keiro-dsl-api-boundaries.py`; retain the shared `readModelStem` export and run
that gate during full verification.

Add one additional regression under `Haskell.keyword-segments` during this milestone: adapt
the Language 6 source in `keiro-dsl/test/fixtures/mapped-nominal-leaf.keiro` so the `templateId`
field's wire key is `type`, then scaffold and assert the structural projection module exports
`templateStateTypeWitness` and `templateStateTypeGet` (and its raw getter where emitted).
Keep the logical field name `templateId` and its nominal type unchanged. Assert the emitted
pointer remains `/type`. This sixth example covers the shared helper's public impact. Inspect
all `normaliseAliasPart` uses; do not describe their output as private-only.

Run the focused tests first:

```bash
nix develop -c cabal test keiro-dsl-haskell-name-test --test-show-details=direct
nix develop -c cabal test keiro-dsl-test --test-show-details=direct --test-options='--match Haskell.keyword-segments'
```

Before refreshing holes, assert that the two new test hole files still contain only the
untouched scaffold stubs from Milestone 1. Delete just those disposable stubs; never use this
procedure for consumer files containing application code. The deletion and staged new suite
make the corpus dirty. `just corpus-regen` refuses dirty paths, so use the driver's explicit
local-iteration override after reviewing `git status --short keiro-dsl/test`:

```bash
rm keiro-dsl/test/conformance-keyword-segments/KeywordSegments/ValidateCustomType/ReadModelHoles.hs
rm keiro-dsl/test/conformance-keyword-segments/KeywordSegments/ProjectionCatalog/ProjectionCatalogHoles.hs
nix develop -c cabal run -v0 keiro-dsl-corpus-regen -- regenerate --allow-dirty
git diff -- keiro-dsl/test
nix develop -c cabal test keiro-dsl:test:keiro-dsl-conformance-keyword-segments --test-show-details=direct
nix develop -c scripts/check-generated-name-policy.sh
nix develop -c z3 --version
nix develop -c cabal test keiro-dsl:tests --keep-going
```

Expect the compiled suite to print `read-model facts: True`, `runtime record: True`, and
`queue policy: True`. Existing corpora are expected to remain byte-identical unless they
exercise an affected keyword wire-path piece; inspect and explain any such diff, and retain
all unrelated local edits. Do not infer compatibility solely from absence of corpus changes.
Stage and commit the green implementation, tests, generated tree, and bug-report progress
with both trailers. Only then run the drift check, which requires clean corpus paths and
rejects even staged changes:

```bash
nix develop -c scripts/check-conformance-corpus.sh
```

Expect `conformance corpus: ok` and no corpus diff. Record the result in this plan.


### Milestone 3: the import-resolution audit


This milestone adds a conservative guard for the exact BUG-11 failure: a plain value imported
from a planned generated sibling whose explicit export list proves it absent. At the end,
a mutated read-model/harness pair is refused before writes, supported valid pairs pass, and
the clean corpus passes the guard. It is not a complete Haskell name resolver.

In `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`, beside `generatedNameInvariantViolations`, add
and export:

```haskell
-- | Refuse a plain value import only when a planned generated sibling's explicit
-- export list proves it absent. Unknown export sets remain GHC's responsibility.
generatedImportResolutionViolations :: [ScaffoldModule] -> [Text]
```

Use `moduleNameOf . (.path)` to index only modules whose `kind` is `Generated`. Both generated
modules and planned `HoleStub` templates may be importers, but never use a hole template as
an authoritative export set: an existing hand-owned file may differ and is not overwritten.
Mask comments and literals with `maskNonCode`. Read balanced module-header and import-list
parentheses across lines, splitting commas at depth zero; `T(A, B)` must remain one item.
Recognize ordinary, pre-qualified and post-qualified imports, optional aliases, and explicit
lists; skip `hiding` imports. Unsupported syntax yields unknown, not a guessed empty set.

For this guard, check only plain lower-case value identifiers in import lists. Skip type,
constructor, operator, `pattern`, and explicit `type` import items. For a sibling's explicit
export list, collect standalone plain names and named children of `T(A, field)`. An export
`T(..)` has unknown children, a `module M` re-export has an unknown imported scope, and an
implicit export list requires more Haskell analysis than this guard supplies. Treat all of
those export sets as unknown for absence checks, including alias re-exports and cycles;
do not recursively union another module's entire export list. Also treat unsupported export
syntax as unknown. A known set may legitimately contain re-exported named values: do not
require every exported name to have a local signature (the fixture's qualified-table value
is such a re-export).

For a supported plain value import missing from a known explicit export set, report
`<path>:<line>: imports '<name>' from <Module>, which exports no such name`. Preserve source
line numbers while masking and joining multiline syntax. Runtime modules, external consumer
modules, and hole targets are outside this map. `fooReadmodel` imported from a generated
module explicitly exporting only `fooReadModel` must fail; importing a constructor from
`T(..)` must not produce a false refusal.

Append `generatedImportResolutionViolations modules` to `namingViolations` in
`pureRefusalsForService`, so the existing `GeneratedNameInvariantViolation` rendering and
pre-write path handle it for single-file and workspace planning. Do not add an IO-only check
that one of those entry points bypasses.

Add a `describe "Haskell.import-resolution"` block in `keiro-dsl/test/Main.hs`. Cover the
mismatched pair, corrected pair, multiline lists, named value re-exports, qualified imports,
and `hiding`. Include conservative controls for `T(..)` with separate constructor/field
imports, nested named children, implicit exports (including an unsigned binding), module
re-exports through aliases/restricted imports/cycles, external runtime targets, and hole
targets. Unknown cases must terminate and produce no refusal. Assert the shared
`pureRefusalsForService` path returns `GeneratedNameInvariantViolation` for the mutated
pair, not just that the helper returns text. Scaffold the Language 6 keyword fixture and
`test/fixtures/incident-paging/incident-paging.keiro` and assert no violations.

Run the focused suite, commit the green change with both trailers, and check the corpus from
clean corpus paths:

```bash
nix develop -c cabal test keiro-dsl-test --test-show-details=direct --test-options='--match Haskell.import-resolution'
nix develop -c scripts/check-conformance-corpus.sh
```

The corpus check re-runs recorded scaffold invocations through the refusal path. It tests the
planned module sets; compilation separately checks actual retained consumer hole files.


### Milestone 4: documentation, changelog, ADR, gate, and lifecycle


This milestone records the behaviour for users and maintainers and closes the bug report. At
the end, the reference explains segment versus whole-name reserved words, both changelogs carry
Unreleased entries, the naming ADR exists and validates, `just verify` passes, and BUG-11 is `fixed`.

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
rename their references after re-scaffolding. Also document keyword wire-path projection
renames (`thingtypeWitness`/`thingtypeGet` become `thingTypeWitness`/`thingTypeGet`). Existing
read-model holes are create-once: consumers must rename affected query bindings, local type
aliases, exports, and contract imports by hand, preserving application bodies. Re-scaffolding
alone does not repair those files. Add this migration procedure to the user reference as well. Add a `### Fixed` entry for BUG-11: read models
with a reserved segment now compile because the definition, query contract, hole, and harness
share one whole-name stem, and `scaffold` refuses provably missing plain-value imports between generated modules with
known explicit export lists; unresolved Haskell forms remain compiler checks. In the root `CHANGELOG.md` under `## [Unreleased]`, add one
`keiro-dsl` bullet summarising both, pointing at
`docs/bug-reports/11-read-model-harness-imports-inconsistent-keyword-segment-name.md`.

Write the naming ADR in `docs/adr/` following `docs/adr/profile.dhall` and the frontmatter of
`docs/adr/0050-shard-resize-composes-public-checkpoints-with-stopped-lease-rows.md` (fields `type`, `title`, `description`, `timestamp`, `docId`, `status`,
`date`). Allocate the handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`
and use the returned stable `ADR-N`, with its corresponding padded filename prefix.
Do not reserve or assume `ADR-51` merely because it was next when this plan was written.
Its decision: every generated occurrence that belongs to one declaration is derived from one
derivation of that declaration's whole logical name; the reserved term-level word set applies
to complete lowerCamel occurrences only, so an upper-position derivation never consults it;
generators must not case underscore segments independently; and supported plain-value imports
between generated modules are checked against known explicit exports before any write, with
unknown cases left to GHC. Record
the rejected alternative (reject keyword segments at `check`) and the consequence (consumers
with affected workqueue names, structural projection paths, or retained read-model holes need
source edits). Append the ADR to
`docs/adr/log.md` with `okf log add docs/adr --kind Addition -m "…"` and run:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Run the full gate and read the exit marker inside the log rather than trusting the terminal:

```bash
nix develop -c z3 --version
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
the naming ADR carries everything durable (the per-segment pattern, the upper-only derivation, and the
import audit) while the `cabal exec` environment note stays here. Commit with the trailers.


## Concrete Steps


All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` inside the
Nix shell (`nix develop -c <command>` or after `nix develop`). Every commit carries the
trailers `ExecPlan:
docs/plans/310-derive-generated-declaration-stems-from-whole-logical-names-to-fix-bug-11.md`
and `Intention: intention_01m4tsyezzeg487dsvychmr0xg`.

Milestone 1 writes the fixture and five examples, observes three failures and two passing
controls, stages the generated suite for corpus discovery, records GHC-61689, and updates the
bug report to `in-progress`. Keep the deliberately failing proof uncommitted.

Milestone 2 repairs the generator, adds the structural projection regression (six focused
examples in total), refreshes only untouched test holes, and uses the explicit
`regenerate --allow-dirty` command above for the reviewed local iteration. Run the focused
and compiled tests, verify Z3 before the full DSL suite, commit the green change, then run the
clean-corpus drift check. Record outcomes before moving on.

Milestone 3 adds the bounded audit and its conservative controls, tests the shared refusal
path, commits the green change, and runs the clean-corpus check.

Milestone 4 updates migration documentation and changelogs, allocates and validates the new
naming ADR, runs `just verify`, and closes BUG-11. Commit any corpus changes before that gate;
its corpus check refuses dirty paths. Run bug-report validation again after the lifecycle edit.


## Validation and Acceptance


The change is accepted when all of the following hold on the final commit.

Scaffolding `keiro-dsl/test/fixtures/keyword-segments.keiro` into a scratch directory prints
no refusal, and `grep -rn "Customtype\|customtype\|Jobtype\|jobtype"` over the output finds
nothing, while `grep -rn "validateCustomTypeReadModel ::" ` finds the definition and the
harness's import line names the same identifier.

`cabal test keiro-dsl:test:keiro-dsl-conformance-keyword-segments --test-show-details=direct`
passes and prints the three `True` lines. The recorded Milestone 1 pre-repair build failure
and Milestone 2 post-repair success establish the regression. Do not use `git stash` to undo
committed generator changes: it cannot do that, and reverting only the stem fix after adding
the audit makes scaffolding refuse rather than reproduce the original GHC failure.

`cabal test keiro-dsl-test --test-options='--match Haskell.keyword-segments'` and
`--match Haskell.import-resolution` pass; `cabal test keiro-dsl-haskell-name-test` passes;
`cabal run -v0 keiro-dsl:exe:keiro-dsl -- check` on a specification declaring `readmodel
type` still prints `error[GeneratedOccurrenceReserved]`; scaffolding the Language 6 variant with
`a_b_test` still declares and imports `abTestReadModel`.

Hand-mutating one generated module's import list and feeding the pair to
`generatedImportResolutionViolations` yields a diagnostic naming the importing path, the
missing name, and the sibling module; `scripts/check-conformance-corpus.sh` passes, proving
the bounded audit accepts every regenerated tracked suite. Its conservative-resolution tests
produce no false refusals, and consumer hole migration is explicitly documented.

`just verify` ends with `exit: 0` in its log; `okf validate docs/adr …` and `just
bug-reports-validate` pass; BUG-11 is `fixed` with `fixedVersion: unreleased`.


## Idempotence and Recovery


Scaffolding into `keiro-dsl/test/conformance-keyword-segments/` is repeatable: generated
modules are overwritten and hole modules are left alone. Refresh only the new suite's
untouched disposable stubs after the repair. Consumer holes require manual renaming while
preserving their bodies. Review corpus status before using `regenerate --allow-dirty` for local
iteration; ordinary regeneration and check mode both require clean corpus paths. Commit
reviewed generated changes before check mode. If another suite changes unexpectedly, inspect
and explain the diff; do not discard existing edits with a blanket checkout or restore.

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
be derived. It exports `readModelStem :: ReadModelNode -> Text`, now `lowerFirst . pascal . (.name)`, byte-identical to the old per-segment result for every name without a reserved segment.
`emitQueueCodec` and `emitQueuePolicy` derive from the whole workqueue name. The generated
module and value names for a read model `n` are, with `S = pascal n` and `s = lowerFirst S`:
module segment `S`, values `sReadModel`, `sQualifiedTable`, `sQuery`, rebuild helpers
with prefixes `start`/`finish`/`abandon` and suffix `pascal(s) <> "Rebuild"` where emitted, and types `pascal(s) <> "QueryInput"` and
`pascal(s) <> "QueryResult"`. Rebuild helpers likewise use `pascal(s)`, not necessarily `S`: for
`a_b_test`, `S = ABTest`, `s = abTest`, and `pascal(s) = AbTest`. For a workqueue `n`: module segment `S`, values `sPayloadCodec` and
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
the allocated naming ADR file plus `docs/adr/log.md`, and
`docs/bug-reports/11-read-model-harness-imports-inconsistent-keyword-segment-name.md` with
`docs/bug-reports/index.md` and `docs/bug-reports/log.md`. External tools: `okf` for bundle
validation, logging, and ID allocation; `just` recipes `corpus-regen`, `bug-reports-validate`,
`generated-name-policy`, `conformance-corpus-policy`, and `verify`.


## Revision notes


- 2026-10-13: corrected the stem formula from `lowerFirst . (.name)` to
  `lowerFirst . pascal . (.name)` (and the workqueue codec stem likewise) after verifying on
  master that `a_b_test` scaffolds `abTestReadModel`; the direct form would have renamed names
  made of single-letter or all-caps segments. Added the fifth stability example, the matching
  Decision Log entries, a fail-open rule for `module M` re-exports in the import audit, and the
  stability check in Validation and Acceptance. Reason: a reviewer asked whether the fix is
  safe, and the byte-identity claim in Milestone 2 was only true for the composed formula.

- 2026-10-13: correctness review against the source and a fresh Language 6 scaffold corrected
  dirty-corpus sequencing, the non-Eq runtime assertion, positive-test language and counts,
  query type casing, and ADR allocation. Bounded the import audit to provable plain-value
  failures, added unknown-syntax controls, and documented structural projection and retained
  hole migration. These changes prevent false refusals, unbuildable sample tests, and an
  implementation workflow that would stop before regeneration or falsely promise compatibility.
