---
id: 284
slug: gate-ordering-fifo-heads-to-language-6
title: "Gate ordering fifo-heads to Language 6"
kind: exec-plan
created_at: 2026-09-16T18:25:28Z
intention: "intention_01m2nqd9hre9gbhw37aagtf066"
master_plan: "docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T18:25:28Z
---

# Gate ordering fifo-heads to Language 6

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A `.keiro` specification declares which version of the keiro-dsl language it is written in
with a first line such as `language keiro-dsl 5`. Languages 1 through 5 are published: they
are frozen contracts that consumers on Hackage rely on, and the parser for a published
language must never start accepting syntax that it rejected when the language was released.
Language 6 is the unpublished candidate where this release cycle's new syntax lives.

The 0.17 cycle added a fourth workqueue ordering, `ordering fifo-heads`, and wired it into
the parser without a language gate. Today a specification that declares `language keiro-dsl 4`
or `language keiro-dsl 5` and says `ordering fifo-heads` passes `keiro-dsl check` and
scaffolds, although keiro-dsl 0.16.0.0 rejected that spelling. The other two constructs
added in this cycle (`idempotence delegated` on intakes and `reactions` process bodies) are
correctly refused below Language 6 with a located `LanguageFeatureRequiresVersion`
diagnostic. This plan gives `fifo-heads` the same treatment before 0.17.0.0 is tagged, because
once the package is on Hackage any Language 4 or 5 specification using the token becomes a
published fact that can never be gated without breaking it.

After this plan, running `keiro-dsl check` on a Language 4 or Language 5 specification that
contains `ordering fifo-heads` fails at the `fifo-heads` token with the diagnostic
`selected syntax requires keiro-dsl language version 6`, exactly as the reaction fixture
does today; the same specification declared as `language keiro-dsl 6` checks, scaffolds to
`jobOrdering = FifoHeads`, and diffs as before. The frozen conformance corpora do not change,
the changelogs state that the token belongs to the Language 6 candidate, and the user
reference says so where it lists the ordering vocabulary.


## Progress

- [ ] M1: `WorkqueueFifoHeadsSyntax` registered in `Keiro.Dsl.LanguageVersion` and added to the Language 6 candidate syntax profile.
- [ ] M1: `pOrdering` in `Keiro.Dsl.Parser.Queue` refuses `fifo-heads` below Language 6 at the token span.
- [ ] M1: `test/fixtures/workqueue-fifo-heads.keiro` declares `language keiro-dsl 6`; new tests prove Languages 4 and 5 refuse the token at its span and Language 6 still round-trips, scaffolds, and diffs.
- [ ] M1: `FrontendProfiles` expectations extended (minimum version table, `featureBody`, `featureCases`) and the unversioned QuickCheck workqueue generator no longer emits `WqFifoHeads`.
- [ ] M1: `cabal test keiro-dsl-test` passes.
- [ ] M2: `just corpus-regen` produces no diff; record migration manifests regenerated; `just conformance-corpus-policy`, `just record-migration-policy`, `just dsl-api-boundaries`, `just generated-name-policy` pass.
- [ ] M3: `keiro-dsl/CHANGELOG.md` and root `CHANGELOG.md` say the token is a Language 6 candidate feature; `docs/user/typed-spec-toolchain.md`, `docs/user/work-queues.md`, and `docs/corpus/keiro-dsl-corpus.md` updated; `docs/user/log.md` entry added; `just user-documentation-validate` passes.
- [ ] Commits made with the `MasterPlan:`, `ExecPlan:`, and `Intention:` trailers.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Gate the token to Language 6 rather than document an exception that lets
  published languages accept it.
  Rationale: `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
  states that once a language version is released, new syntax must be registered under a
  successor version and existing version parsers are not widened. The two sibling
  constructs of this cycle already follow that rule, and the review that created this plan
  (REV-17, `docs/reviews/keiro-0-17-release-readiness.md`) found only the fifo-heads
  alternative missing its gate. The rejected alternative, documenting `fifo-heads` as a
  deliberate widening of Languages 4 and 5, would have made the language-stability record
  false for two published versions to save one small parser change.
  Date: 2026-09-16
- Decision: Gate on the `fifo-heads` token, not on the `ordering` keyword.
  Rationale: `ordering unordered`, `ordering fifo-throughput`, and `ordering fifo-roundrobin`
  are published Language 1 syntax and must keep parsing. Placing the check on the new
  spelling makes the diagnostic span point at the exact text a user must change and leaves
  the three legacy alternatives untouched.
  Date: 2026-09-16
- Decision: Move the existing fixture to `language keiro-dsl 6` instead of adding a second
  fixture, and derive the negative Language 4 and Language 5 cases in the test by rewriting
  the preamble line.
  Rationale: The fixture's only reason to exist is the new token, so it should live at the
  language that owns it. The diff test that compares it with the Language 4 base fixture
  filters to breaking changes, and a language declaration change is classified as an
  additive `SourceLanguageDeclarationChanged` on the source-provenance vector, so that test
  keeps passing. Rewriting the preamble in the test mirrors the pattern already used for the
  projection-catalog gate at `keiro-dsl/test/Main.hs:2447`.
  Date: 2026-09-16
- Decision: Remove `WqFifoHeads` from the QuickCheck generator that feeds the unversioned
  parse-then-pretty round-trip property rather than teaching that property about languages.
  Rationale: The property renders with `renderSpec`, which emits no `language` preamble, so
  every generated spec is parsed as Language 1. The generator already restricts itself to
  Language 1 syntax elsewhere (`genWqField` produces only `LegacyQueueScalar` payload types
  for the same reason). Language 6 round-tripping of the token is covered by the dedicated
  fixture test.
  Date: 2026-09-16


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The keiro-dsl package (`keiro-dsl/`) is the typed specification toolchain. A `.keiro` file
is parsed into a surface document, lowered into a `Spec`, checked, and scaffolded into
Haskell. The parts of it this plan touches are:

- `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` is the language registry. The type
  `LanguageFeature` (around line 375) enumerates every piece of grammar introduced after
  Language 1, for example `DelegatedInboxSyntax` and `ProcessReactionSyntax`. Each registered
  language carries a `SyntaxProfile`, a named set of features; `profileV4` is Language 5's
  profile and `profileV5` (around line 299) is the Language 6 candidate's profile, built by
  inserting the two Language 6 features into `profileV4`. `languageFeatureMinimumVersion`
  (around line 392) answers "which version first supports this feature" by scanning the
  registry, and `languageSupportsFeature` answers "does this version support it". There is
  no separate numeric table: adding a feature to a profile is what makes it available.
  The registry row for Language 6 is marked `Candidate CandidateLanguage`, which per ADR-16
  means it may be amended in place until it is published.
- `keiro-dsl/src/Keiro/Dsl/Parser/Core.hs` holds the parser primitives. Two matter here:
  `requireLanguageFeatureAt :: FrontendContext -> LanguageFeature -> SourceSpan -> P ()`
  (line 121) succeeds when the selected language supports the feature and otherwise raises a
  `ContextualParseFailure` with code `LanguageFeatureRequiresVersion` at the given span, and
  `withOwnedSpan :: P a -> P (Located a)` (line 302) runs a parser and records the span of
  the text it owns, trimming trailing whitespace and comments. `spanOf` (line 327) extracts
  the span from a `Located` value. The `FrontendContext` passed around the parser carries the
  selected language definition; `frontendSupportsFeature` in
  `keiro-dsl/src/Keiro/Dsl/Frontend/Internal.hs` is what `requireLanguageFeatureAt` consults.
- `keiro-dsl/src/Keiro/Dsl/Parser/Queue.hs` parses `workqueue` nodes. `pWorkqueue context`
  (line 15) reads the header, then `ordering <- option WqUnordered pOrdering`. `pOrdering`
  lives in the `where` clause (line 66) and is a `choice` over four alternatives; the fourth,
  `WqFifoHeads <$ symbol "fifo-heads"` (line 72), is the ungated one. The same `where`
  clause already contains a correctly gated construct to copy: `pTypedPayload` (line 105)
  does `marker <- withOwnedSpan (symbol ":")` and then
  `requireLanguageFeatureAt context MappedConsumerSurfaceSyntax (spanOf marker)`. The module
  imports `LanguageFeature (MappedConsumerSurfaceSyntax)` from `Keiro.Dsl.LanguageVersion`
  (line 10) and the whole of `Keiro.Dsl.Parser.Core`.
- `keiro-dsl/src/Keiro/Dsl/Grammar.hs:1240` defines
  `data WqOrdering = WqUnordered | WqFifoThroughput | WqFifoRoundRobin | WqFifoHeads`. The
  pretty printer (`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs:371`), the diff renderer
  (`keiro-dsl/src/Keiro/Dsl/Diff.hs:2911`), and the scaffolder
  (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:4044`, which emits `jobOrdering = FifoHeads`) all
  pattern-match on the constructor. None of them needs a language check: once the parser
  refuses the token, no `WqFifoHeads` value can exist for a Language 4 or 5 source.
- `keiro-dsl/test/fixtures/workqueue-fifo-heads.keiro` is the fixture that proves the
  feature. It currently begins `language keiro-dsl 4`. Its `ordering fifo-heads` line is
  line 9, and the token starts at column 12.
- `keiro-dsl/test/Main.hs` holds the package test-suite `keiro-dsl-test`. The fifo-heads
  tests are "round-trips fifo-heads and lowers it to the grouped-head runtime strategy"
  (line 7217) and the diff assertion inside "classifies workqueue ordering changes as
  breaking delivery-contract changes" (line 8555), which diffs
  `test/fixtures/workqueue-policy-base.keiro` (a Language 4 file) against the fifo-heads
  fixture. The `parse . pretty round-trip` property (line 4333) renders arbitrary specs with
  `renderSpec` and re-parses them with `parseSpec`; because `renderSpec` never emits a
  `language` preamble (only `renderSource` does, `PrettyPrint.hs:39`), every generated spec is
  parsed as Language 1. The workqueue generator `genWorkqueue` (line 14818) picks the
  ordering from `elements [WqUnordered, WqFifoThroughput, WqFifoRoundRobin, WqFifoHeads]`.
  The projection-catalog gate test at line 2447 shows the pattern for deriving a
  predecessor-language source from a fixture with `T.replace` and asserting on
  `renderParseFailure`.
- `keiro-dsl/test/Keiro/Dsl/FrontendProfiles.hs` pins the language registry. The test
  "pins each released syntax profile, predecessor, and runtime contract explicitly"
  contains a `case feature of` table (lines 72 to 82) that states each feature's minimum
  version, with a `_ -> version 2` default; every `LanguageFeature` constructor must be
  listed there or fall into the default. `featureBody :: LanguageFeature -> Text` (line 150
  onward) is an exhaustive `\case` that produces a minimal source exercising each feature,
  and `featureCases :: [FeatureCase]` (around line 130) lists, for each feature, the exact
  marker text the refusal span must cover and a body. The test "checks every real feature
  marker against the exact selected profile" parses each body under Languages 1 through 6
  and asserts that unsupported versions refuse it at the marker.
- `keiro-dsl/record-field-migration-0.15.md` and
  `keiro-dsl/generated-haskell-edition-idiomatic-v2.md` are generated inventories that embed
  source line numbers. `just record-migration-policy` regenerates them in check mode and fails
  if they differ, so any edit that adds lines above an inventoried record in
  `LanguageVersion.hs` requires regenerating them with
  `python3 scripts/generate-record-migration-manifests.py` and committing the result.
- `just corpus-regen` re-scaffolds every conformance corpus under `keiro-dsl/test/` and
  `just conformance-corpus-policy` fails if the committed corpus differs from the generator's
  output. `grep -rln fifo-heads keiro-dsl/test` returns only `Main.hs` and the fixture, so no
  corpus uses the token and regeneration is expected to be a no-op.
- User documentation is an OKF bundle validated by `just user-documentation-validate`. Every
  change to a file under `docs/user/` must be accompanied by a dated `## YYYY-MM-DD` entry
  in `docs/user/log.md` with an `* **Update**:` bullet, following the existing entries.

Two ADRs govern this work. `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
(ADR-16) freezes released language versions: new syntax is registered under a successor
version with its predecessor relation, existing version parsers are not widened, and a
registered candidate becomes immutable only when a package containing it is published.
`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (ADR-4)
places each evolution check at the earliest boundary with enough evidence and makes
machine-readable diagnostic codes, not prose, the tooling contract; the parser is the
earliest boundary for a syntax gate and `LanguageFeatureRequiresVersion` is the code.

Two sibling plans under the same MasterPlan touch adjacent files. `docs/plans/283-reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces.md`
owns the structure of every changelog and of the user reference; this plan edits only the
sentences that describe `fifo-heads`. `docs/plans/285-harden-the-language-6-reaction-candidate-before-it-is-published.md`
also reads `profileV5`; it adds no feature, so the two compose without conflict.
`docs/plans/282-write-the-0-16-0-0-to-0-17-0-0-upgrade-edge-and-reconcile-release-metadata.md`
reads this plan's outcome to state in the consumer upgrade edge that `fifo-heads` requires
Language 6. `docs/plans/281-restore-a-green-verify-gate-for-the-0-17-0-0-candidate.md`
also regenerates the record migration manifests; regeneration is idempotent, so whichever
plan lands second simply regenerates again.


## Plan of Work

### Milestone 1: register the feature and gate the parser

At the end of this milestone the parser refuses `fifo-heads` below Language 6 with the
standard located diagnostic, the fixture and tests describe the new contract, and
`cabal test keiro-dsl-test` passes.

In `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, add a constructor
`WorkqueueFifoHeadsSyntax` to `data LanguageFeature`, after `ProcessReactionSyntax`, with
the same derived instances. Extend `profileV5` so the Language 6 candidate profile contains
it: the current body is
`Set.insert ProcessReactionSyntax (Set.insert DelegatedInboxSyntax ((.features) profileV4))`;
wrap it in one more `Set.insert WorkqueueFifoHeadsSyntax`. Do not touch `profileV4` or any
earlier profile, and do not change the profile identifier string
`"keiro-dsl/syntax-profile/5"`; the frontend profile test pins that string and ADR-16 allows a
candidate profile to be amended in place. Because `languageFeatureMinimumVersion` scans the
registry, the new feature now resolves to version 6 with no further code.

In `keiro-dsl/src/Keiro/Dsl/Parser/Queue.hs`, widen the import on line 10 to
`LanguageFeature (MappedConsumerSurfaceSyntax, WorkqueueFifoHeadsSyntax)`, and replace the
fourth alternative of `pOrdering` with a gated one:

```haskell
    pOrdering = do
      _ <- symbol "ordering"
      choice
        [ WqUnordered <$ symbol "unordered",
          WqFifoThroughput <$ symbol "fifo-throughput",
          WqFifoRoundRobin <$ symbol "fifo-roundrobin",
          do
            marker <- withOwnedSpan (symbol "fifo-heads")
            requireLanguageFeatureAt context WorkqueueFifoHeadsSyntax (spanOf marker)
            pure WqFifoHeads
        ]
```

`context` is the `FrontendContext` parameter of `pWorkqueue` and is already in scope in the
`where` clause. `withOwnedSpan` records the span of the literal token; `requireLanguageFeatureAt`
raises the fancy `ContextualParseFailure` after the token has been consumed, so megaparsec
reports it at that span rather than backtracking to a generic "expected ordering" error,
which is the same behavior the mapped-payload gate relies on.

Change the first line of `keiro-dsl/test/fixtures/workqueue-fifo-heads.keiro` from
`language keiro-dsl 4` to `language keiro-dsl 6`. Nothing else in the fixture changes.

In `keiro-dsl/test/Main.hs`, add a test next to the existing fifo-heads round-trip test
(line 7217) that proves the gate for both published versions:

```haskell
    it "gates ordering fifo-heads at the token before Language 6" $ do
      source <- readTestText "test/fixtures/workqueue-fifo-heads.keiro"
      forM_ [4 :: Int, 5] $ \predecessor -> do
        let downgraded = T.replace "language keiro-dsl 6" ("language keiro-dsl " <> T.pack (show predecessor)) source
        case parseSurfaceSource "workqueue-fifo-heads-predecessor.keiro" downgraded of
          Left FrontendFailure {code = SourceLanguageError LanguageFeatureRequiresVersion, span = SourceSpan {start = SourcePoint {offset = startOffset}, end = SourcePoint {offset = endOffset}}} ->
            T.take (endOffset - startOffset) (T.drop startOffset downgraded) `shouldBe` "fifo-heads"
          Left failure -> expectationFailure (show failure)
          Right _ -> expectationFailure ("Language " <> show predecessor <> " unexpectedly accepted ordering fifo-heads")
```

`parseSurfaceSource`, `FrontendFailure`, `FrontendErrorCode`, `SourceSpan`, and
`SourcePoint` are already imported at the top of the file (line 49 imports the frontend
names; the reaction gate test at line 6580 uses this exact match). Also assert the
compatibility rendering, as the projection-catalog test does, so the CLI text is pinned:
`renderParseFailure failure` must contain `"LanguageFeatureRequiresVersion"` and
`"requires keiro-dsl language version 6"` when the same downgraded source goes through
`parseSource`. Leave the existing round-trip, scaffold, and diff assertions unchanged;
the round-trip test reads the fixture and now exercises Language 6, and the diff test's
`Breaking`-only filter ignores the additive `SourceLanguageDeclarationChanged` that the
language move introduces.

In `genWorkqueue` (line 14818), change the ordering generator to
`elements [WqUnordered, WqFifoThroughput, WqFifoRoundRobin]`. Add a one-line comment above
it explaining that the round-trip property renders without a language preamble and is
therefore parsed as Language 1, so gated syntax is excluded here exactly as `genWqField`
excludes typed payloads.

In `keiro-dsl/test/Keiro/Dsl/FrontendProfiles.hs`, make three additions. In the minimum
version table (lines 72 to 82) add `WorkqueueFifoHeadsSyntax -> version 6` beside the two
other Language 6 rows. In `featureBody`, add a case for `WorkqueueFifoHeadsSyntax` whose
body is the fixture's `context` line and a minimal `workqueue` node that uses
`ordering fifo-heads` and the `group key` line (copy the fixture body after its `language`
line; the `retry` and `disposition` blocks are required by the grammar, so keep them). In
`featureCases`, add `FeatureCase WorkqueueFifoHeadsSyntax "fifo-heads" (featureBody WorkqueueFifoHeadsSyntax)`.
The marker test will then parse that body under every version and require that Languages 1
through 5 refuse it with the span covering exactly `fifo-heads`, and that Language 6
accepts it. If the marker test reports a span mismatch, the culprit is almost always a
trailing comment or whitespace inside the owned span; `withOwnedSpan` already trims those,
so inspect the fixture body rather than the parser.

Run the package suite. Acceptance: `cabal test keiro-dsl-test` reports 0 failures, and the
focused patterns in Concrete Steps pass.

### Milestone 2: prove the corpora and policies are untouched

At the end of this milestone every repository policy that reads generated output or source
inventories passes against the committed tree.

Run `just corpus-regen` and confirm `git status --short` shows no change under
`keiro-dsl/test/`; no conformance corpus uses the token. Run
`python3 scripts/generate-record-migration-manifests.py` and inspect the diff of
`keiro-dsl/record-field-migration-0.15.md` and
`keiro-dsl/generated-haskell-edition-idiomatic-v2.md`; the only expected changes are line
numbers of records declared below the new constructor in `LanguageVersion.hs`. Commit those
regenerated files with the code. Then run `just conformance-corpus-policy`,
`just record-migration-policy`, `just dsl-api-boundaries`, and `just generated-name-policy`;
all four must exit 0.

### Milestone 3: say so in the changelogs and the user reference

At the end of this milestone every published sentence about `fifo-heads` states that it is
Language 6 candidate syntax, and the user documentation bundle validates.

In `keiro-dsl/CHANGELOG.md`, rewrite the bullet at lines 11 to 13 so it begins "Candidate
Language 6 adds `ordering fifo-heads` to workqueues" and keeps the rest of its content
(round trips preserve the spelling, scaffolding emits `FifoHeads` and FIFO-index
provisioning, ordering diffs remain breaking). Move it to sit with the other two
"Candidate Language 6 adds ..." bullets so the section reads as one candidate. In the root
`CHANGELOG.md`, rewrite the bullet at lines 35 to 36 the same way. Do not restructure either
file; `docs/plans/283-reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces.md`
owns that.

In `docs/user/typed-spec-toolchain.md`, the workqueue syntax reference at lines 1427 to
1431 lists the ordering vocabulary; add one sentence after the `fifo-heads` description
stating that `fifo-heads` is Language 6 candidate syntax and is refused below Language 6
with `LanguageFeatureRequiresVersion`, while the three other orderings remain available in
every published language. Check the example block that starts around line 1368: if its
enclosing example declares a published language, either change the example's declared
language to 6 or replace `ordering fifo-heads` with `ordering fifo-throughput` in that
example so the reference never shows a spec that would fail `check`. In
`docs/user/work-queues.md` lines 538 to 540, add the same one-sentence qualification. In
`docs/corpus/keiro-dsl-corpus.md` line 199, note "(Language 6)" in the fixture's description.
Add a `## 2026-MM-DD` section (today's date) at the top of `docs/user/log.md` with an
`* **Update**:` bullet such as "Document that `ordering fifo-heads` is Language 6 candidate
syntax refused by published languages." Run `just user-documentation-validate`; it must print
`OK` for both `docs/user` and `docs/guides`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless
stated otherwise. Confirm the starting state before editing:

```bash
grep -n 'fifo-heads' keiro-dsl/src/Keiro/Dsl/Parser/Queue.hs
head -1 keiro-dsl/test/fixtures/workqueue-fifo-heads.keiro
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workqueue-fifo-heads.keiro; echo "exit=$?"
```

Expected before the change: the grep shows `WqFifoHeads <$ symbol "fifo-heads"` with no
`requireLanguageFeatureAt` nearby, the fixture declares `language keiro-dsl 4`, and check
prints a compatibility-only language note followed by `OK` with `exit=0`, which is the
defect.

Make the Milestone 1 edits, then build and run the focused tests:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test --test-show-details=direct --test-options='--match "fifo-heads"'
cabal test keiro-dsl-test --test-show-details=direct --test-options='--match "FrontendProfiles"'
cabal test keiro-dsl-test --test-show-details=direct --test-options='--match "round-trip"'
cabal test keiro-dsl-test --test-show-details=direct --test-options='--match "workqueue ordering"'
```

Each invocation must end with a line of the form `N examples, 0 failures`. Then prove the
gate from the command line with throwaway copies of the fixture:

```bash
S=$(mktemp -d)
sed 's/language keiro-dsl 6/language keiro-dsl 4/' keiro-dsl/test/fixtures/workqueue-fifo-heads.keiro > "$S/l4.keiro"
sed 's/language keiro-dsl 6/language keiro-dsl 5/' keiro-dsl/test/fixtures/workqueue-fifo-heads.keiro > "$S/l5.keiro"
cabal run -v0 keiro-dsl -- check "$S/l4.keiro"; echo "exit=$?"
cabal run -v0 keiro-dsl -- check "$S/l5.keiro"; echo "exit=$?"
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workqueue-fifo-heads.keiro; echo "exit=$?"
```

Expected output for the two downgraded copies, where the position is the start of the
`fifo-heads` token on the `ordering` line of the fixture:

```text
/tmp/.../l4.keiro:9:12: error [LanguageFeatureRequiresVersion]: selected syntax requires keiro-dsl language version 6; selected version 4
exit=1
```

and the Language 6 fixture prints `OK` with `exit=1` replaced by `exit=0`. The wording and
shape match what the existing reaction gate prints today for
`keiro-dsl/test/fixtures/process-reactions-language5.keiro` (`6:1: error
[LanguageFeatureRequiresVersion]: selected syntax requires keiro-dsl language version 6;
selected version 5`).

Run the whole package suite once:

```bash
cabal test keiro-dsl-test
```

Expected: `Test suite keiro-dsl-test: PASS`. Commit Milestone 1:

```text
feat(dsl)!: gate ordering fifo-heads to Language 6

Register WorkqueueFifoHeadsSyntax in the Language 6 candidate profile and
refuse the token below Language 6 at its span, matching the delegated
intake and reaction gates. Move the fixture to Language 6 and keep the
unversioned round-trip generator on published syntax.

MasterPlan: docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md
ExecPlan: docs/plans/284-gate-ordering-fifo-heads-to-language-6.md
Intention: intention_01m2nqd9hre9gbhw37aagtf066
```

Milestone 2:

```bash
just corpus-regen
git status --short -- keiro-dsl/test
python3 scripts/generate-record-migration-manifests.py
git diff --stat -- keiro-dsl/record-field-migration-0.15.md keiro-dsl/generated-haskell-edition-idiomatic-v2.md
just conformance-corpus-policy
just record-migration-policy
just dsl-api-boundaries
just generated-name-policy
```

Expected: the first `git status` prints nothing; the manifest diff, if any, shows only
line-number columns moving; the four policies print their `ok`/`OK` lines and exit 0
(`conformance corpus: ok`, `keiro-dsl API boundary policy: OK`,
`generated Haskell name policy: OK`). Commit the regenerated manifests if they changed:

```text
chore(dsl): regenerate record migration manifests after the fifo-heads gate

MasterPlan: docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md
ExecPlan: docs/plans/284-gate-ordering-fifo-heads-to-language-6.md
Intention: intention_01m2nqd9hre9gbhw37aagtf066
```

Milestone 3:

```bash
grep -n 'fifo-heads' CHANGELOG.md keiro-dsl/CHANGELOG.md docs/user/typed-spec-toolchain.md docs/user/work-queues.md docs/corpus/keiro-dsl-corpus.md
just user-documentation-validate
```

Expected after editing: every hit either says Language 6 or is inside a sentence that does;
the validator prints `OK: 25 concepts` for `docs/user` and `OK: 27 concepts` for
`docs/guides` (counts may be higher if sibling plans landed first). Commit:

```text
docs(dsl): describe ordering fifo-heads as Language 6 candidate syntax

MasterPlan: docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md
ExecPlan: docs/plans/284-gate-ordering-fifo-heads-to-language-6.md
Intention: intention_01m2nqd9hre9gbhw37aagtf066
```

Update the Progress section of this plan at each commit.


## Validation and Acceptance

The change is accepted when all of the following hold on a clean tree at the final commit.

A specification declaring `language keiro-dsl 4` or `language keiro-dsl 5` that contains
`ordering fifo-heads` fails `cabal run -v0 keiro-dsl -- check <file>` with exit status 1
and a single diagnostic whose code is `LanguageFeatureRequiresVersion`, whose message says
`requires keiro-dsl language version 6`, and whose reported line and column are the start of
the `fifo-heads` token. The same file with `language keiro-dsl 6` prints `OK` and exits 0,
and `cabal run -v0 keiro-dsl -- scaffold <file> --out <dir>` produces a `QueuePolicy.hs`
containing `jobOrdering = FifoHeads`. The three published orderings keep parsing under every
language from 1 to 6; the frontend profile marker test proves this because every other
`FeatureCase` body still parses in Languages 1 through 5.

`cabal test keiro-dsl-test` passes with 0 failures, including the new gate test, the
existing fifo-heads round-trip and diff tests, the `FrontendProfiles` suite, and the
`parse . pretty round-trip` property. `just corpus-regen` leaves the tree unchanged.
`just conformance-corpus-policy`, `just record-migration-policy`, `just dsl-api-boundaries`,
`just generated-name-policy`, and `just user-documentation-validate` exit 0. The two
changelogs and the three documentation files describe the token as Language 6 candidate
syntax. Finally, `just verify` passes once
`docs/plans/281-restore-a-green-verify-gate-for-the-0-17-0-0-candidate.md` has repaired the
unrelated gate failures it describes; until then, the focused commands above are the
acceptance evidence.


## Idempotence and Recovery

Every step is safe to repeat. The code edits are plain source changes; rerunning the tests
and policies has no side effects. `just corpus-regen` rewrites files under `keiro-dsl/test/`
only when the generator's output differs, and `git checkout -- keiro-dsl/test` restores the
committed corpus if a regeneration ever surprises you. The manifest generator overwrites the
two manifest files deterministically. If the marker test in `FrontendProfiles` fails after
the fixture body is added, the parser change is still correct; fix the body until its only
gated spelling is `fifo-heads`. If the round-trip property fails with a
`LanguageFeatureRequiresVersion` message, the generator still emits `WqFifoHeads`; remove it.
No database, migration, or published artifact is involved, and the whole plan can be
reverted with `git revert` of its commits.


## Interfaces and Dependencies

Modules and functions that must exist at the end of Milestone 1:

- `Keiro.Dsl.LanguageVersion.LanguageFeature` gains the constructor
  `WorkqueueFifoHeadsSyntax`; `profileV5 :: SyntaxProfile` contains it;
  `languageFeatureMinimumVersion WorkqueueFifoHeadsSyntax == version6`; and
  `languageSupportsFeature v WorkqueueFifoHeadsSyntax` is `True` only for `v == version6`.
- `Keiro.Dsl.Parser.Queue.pWorkqueue :: FrontendContext -> P WorkqueueNode` is unchanged in
  type; its internal `pOrdering` uses `withOwnedSpan`, `spanOf`, and
  `requireLanguageFeatureAt` from `Keiro.Dsl.Parser.Core`.
- `Keiro.Dsl.Grammar.WqOrdering` is unchanged; downstream consumers in `PrettyPrint`,
  `Diff`, and `Scaffold` are unchanged.

Libraries: megaparsec (already the parser library; `choice`, `symbol`, and `customFailure`
semantics are relied on as described above), hspec and QuickCheck (already the test
libraries). No dependency bound changes. This plan has no hard dependency on any other plan.
It has soft dependencies on `docs/plans/283-reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces.md`
(shared changelog and user-reference files; rebase whichever lands second) and on
`docs/plans/281-restore-a-green-verify-gate-for-the-0-17-0-0-candidate.md` (shared record
migration manifests; regenerate again if both land). `docs/plans/282-write-the-0-16-0-0-to-0-17-0-0-upgrade-edge-and-reconcile-release-metadata.md`
consumes this plan's outcome.
