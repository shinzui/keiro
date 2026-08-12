---
id: 233
slug: gate-the-outcome-reserved-words-on-the-language-5-syntax-profile
title: "Gate the outcome reserved words on the language-5 syntax profile"
kind: exec-plan
created_at: 2026-08-11T23:37:31Z
intention: "intention_01kzsjznhgeyvbcpfk1znzmbnr"
master_plan: "docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md"
---

# Gate the outcome reserved words on the language-5 syntax profile

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

At release 0.11.0.0 a `.keiro` specification could name a register, command field, state, or
enum constructor `outcome`. The current development branch broke that promise: while adding
the typed domain-outcome syntax for candidate language 5, the words `outcome` and
`domain-outcomes` were added to the parser's global reserved-word list, which applies to every
language version unconditionally. A deployed service whose spec declares `language keiro-dsl 4`
(or 1, 2, or 3, or no declaration at all) and legally uses `outcome` as an identifier no longer
parses: `keiro-dsl check` fails, `keiro-dsl scaffold` cannot regenerate the service, and
`keiro-dsl diff` cannot even load its own old baseline, so evolution gating for that service is
hard-blocked. This is one of the four confirmed defects from the 2026-08-11 pre-release review
tracked by the parent MasterPlan, and it must be fixed while language 5 is still an amendable
candidate — after publication the fix itself would be a breaking language change.

After this plan, published languages 1–4 accept `outcome` as an ordinary identifier exactly as
0.11.0.0 did, and candidate language 5 parses the outcome keywords contextually — only in the
one grammatical position where the typed outcome clause occurs — so even language-5 sources may
freely name things `outcome`. Nothing is reserved globally. You can see it working by running
`cabal run -v0 keiro-dsl -- check` over the regression fixtures added by this plan: every
published-language variant that fails today prints `OK` afterwards, while the existing
language-5 typed-outcome fixture and its compiled conformance corpus stay green.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-12T00:21:30Z) M1: add `keiro-dsl/test/fixtures/outcome-identifier-legacy.keiro` (legacy grammar, no preamble).
- [x] (2026-08-12T00:21:30Z) M1: add `keiro-dsl/test/fixtures/outcome-identifier.keiro` (language-4 body, typed expressions).
- [x] (2026-08-12T00:21:30Z) M1: add `keiro-dsl/test/fixtures/outcome-identifier-positions.keiro` (language 4: enum constructor, state, transition source named `outcome`).
- [x] (2026-08-12T00:21:30Z) M1: add `keiro-dsl/test/fixtures/outcome-identifier-v5.keiro` (language 5: outcome clauses coexisting with `outcome` identifiers, including the clause-boundary hazard).
- [x] (2026-08-12T00:21:30Z) M1: add the `outcome identifier compatibility` describe block to `keiro-dsl/test/Main.hs` covering legacy, declared 1, 2, 3, 4, the position fixture, the renderer round-trip, and the language-5 coexistence fixture.
- [x] (2026-08-12T00:21:30Z) M1: run the targeted suite and record the red result (new examples fail at HEAD; all pre-existing examples still pass).
- [x] (2026-08-12T00:27:20Z) M2: remove `"domain-outcomes"` and `"outcome"` from `reservedWords` in `keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`.
- [x] (2026-08-12T00:27:20Z) M2: make the `outcome` clause marker in `pClause` (`keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs`) contextual with `try` + `lookAhead` of the three selector keywords.
- [x] (2026-08-12T00:27:20Z) M2: targeted suite green, including the untouched "gates the syntax to candidate language 5" example.
- [x] (2026-08-12T00:27:20Z) M2: `cabal test -v0 keiro-dsl:keiro-dsl-conformance-domain-outcomes --test-show-details=direct` green (language-5 outcome corpus still compiles and its runtime facts hold).
- [x] (2026-08-12T00:27:20Z) M2: before/after CLI transcripts captured for the language-4 fixture (failing exit 1 before, `OK` exit 0 after).
- [ ] M3: changelog entry under `Unreleased` in `keiro-dsl/CHANGELOG.md`.
- [ ] M3: `just conformance-corpus-policy` passes with zero corpus drift (coordinate with plan 234 per the MasterPlan if it landed first).
- [ ] M3: `cabal test keiro-dsl:tests` green; `just verify` green.
- [ ] M3: ADR distillation — record the contextual-keyword principle in `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`.
- [ ] M3: update the MasterPlan registry row (EP-1 status) and its two EP-1 progress checkboxes in `docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Milestone 1 (2026-08-12): the focused red run produced exactly the intended five failures
  and no passing compatibility example. Four failures stopped on the reserved register name
  (`unexpected "outcom"`, expecting `states`); the positions fixture stopped on the reserved
  enum constructor (`unexpected 'o'`, expecting `}`). Cabal reported `5 examples, 5 failures`,
  confirming the fixtures isolate the global reservation before the parser changes.
- Milestone 2 (2026-08-12): the contextual marker restored all five compatibility examples
  while the untouched typed-domain-outcome block also reported `5 examples, 0 failures`,
  including the candidate-language feature-gate assertion. The compiled outcome conformance
  suite exited 0, the language-4 CLI check printed `OK`, and diffing the committed fixture
  against `HEAD` succeeded with `replay-neutral: stored-data replay is unchanged by this diff`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix the defect with contextual keyword parsing (design option b) rather than
  profile-gated reservation (option a). No word is reserved at all; the `outcome` clause is
  recognized only when `outcome` is immediately followed by one of its three selector keywords.
  Rationale: (1) Option a requires threading `FrontendContext` into `ident`
  (`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`), which is deliberately context-free and called from
  all thirteen parser modules — a wide mechanical change for a worse result. (2) The grammar
  makes the contextual parse unambiguous: the expression grammar
  (`keiro-dsl/src/Keiro/Dsl/Parser/Expression.hs`) has no identifier juxtaposition, so inside a
  transition's clause list the only legal continuation that begins with a bare identifier is the
  next transition's head, whose second token is always `--` — never `accepted`, `rejected`, or
  `no-op`. A one-token lookahead therefore separates the clause from every identifier use, in
  language 5 included. (3) Plan 232 already made exactly this call for `accepted`, `rejected`,
  and `rejection` after 84 fixture failures ("Outcome values must be contextual transition
  keywords rather than globally reserved identifiers",
  `docs/plans/232-add-typed-domain-outcomes-to-the-dsl.md`); this plan completes that decision
  for the two words it left reserved. (4) Contextual parsing is the least-breaking contract to
  freeze into language 5: once published, un-reserving a word would be a new language version,
  while never reserving it costs nothing.
  Date: 2026-08-11
- Decision: Remove `"domain-outcomes"` from `reservedWords` as well, even though the entry is
  provably inert — `ident` only matches dash-free words, so it can never produce
  `domain-outcomes`, and `wireWord` (which does admit dashes) never consults the list.
  Rationale: Restores the 0.11.0.0 list byte-for-byte (verified against tag commit `e796227c`)
  and keeps the exported `reservedWords :: [Text]` value honest about what the parser actually
  refuses. `keyword "domain-outcomes"` in `pDomainOutcomeTypes` needs no lookahead guard: no
  legal 1–4 program can place that dashed word where the marker is attempted, so the existing
  `requireLanguageFeatureAt` diagnostic is reachable only by genuine language-5 syntax.
  Date: 2026-08-11
- Decision: Keep `requireLanguageFeatureAt context DomainCommandOutcomeSyntax` immediately after
  the contextual marker in both `pClause` and `pDomainOutcomeTypes`.
  Rationale: A language-1–4 source that genuinely writes `outcome accepted` (or a
  `domain-outcomes` declaration) still gets the targeted
  `LanguageFeatureRequiresVersion` diagnostic pointing at the marker span, instead of a generic
  parse error. This narrows the targeted diagnostic to real attempts at the new syntax — `outcome`
  followed by anything else now falls through to the published grammar, which is exactly the
  restoration this plan exists to make.
  Date: 2026-08-11
- Decision: Do not run `just corpus-regen`; run only the drift check
  (`just conformance-corpus-policy`).
  Rationale: The fix changes what the parser accepts, not what the scaffolder emits for any
  existing corpus spec, so regeneration must be a byte-for-byte no-op. Proving zero drift is
  stronger evidence than regenerating. Per the MasterPlan's integration note, plan 234 also
  regenerates the corpus; whichever plan lands second runs its corpus check on top of the
  first's committed state.
  Date: 2026-08-11
- Decision: Scope is parser-only. No changes to `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`
  (registry, profiles, features), no changes to validation, lowering, scaffolding, fold
  fingerprints, or the pretty-printer, and no registry flip to `Stable` (that is release
  mechanics outside the MasterPlan).
  Rationale: The defect is entirely in `reservedWords` and one clause marker; everything else
  already behaves correctly, and replay identity must not move.
  Date: 2026-08-11
- Decision: In the new regression tests, assert `validateService … == []` only for the
  language-4 and language-5 fixtures, and assert parse success (plus renderer round-trip) for
  legacy/1/2/3.
  Rationale: Mirrors the existing `typed-domain-outcomes` test pattern at
  `keiro-dsl/test/Main.hs:1835`. All five neutral-named variants were verified clean through
  `keiro-dsl check` during planning, but pinning full-diagnostic emptiness across
  compatibility-only languages adds fragility without adding evidence about this defect.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a Haskell multi-package Cabal project rooted at the repository top level
(the directory containing `cabal.project` and the `Justfile`). All commands in this plan run
from that repository root unless stated otherwise. The package that matters here is
`keiro-dsl`: it implements a small typed specification language (files with the `.keiro`
extension) and a CLI (`cabal run -v0 keiro-dsl -- <subcommand>`) whose subcommands include
`check` (parse and validate one file), `scaffold` (emit generated Haskell), and `diff`
(classify spec changes since a git ref and block breaking evolution).

A "language version" is a numbered, registered contract for what `.keiro` syntax means. The
registry lives in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` (`languageRegistry`, lines
240–247): languages 1–4 are `PublishedLanguage` and immutable, language 4 is the current
`Stable`, and language 5 is the amendable `Candidate` that the upcoming 0.12.0.0 release will
publish as the next stable contract. A source selects its language with a first-line preamble
(`language keiro-dsl 4`); a file without a preamble is "legacy-unversioned" and means language 1.
Each language owns a `SyntaxProfile`, an immutable set of `LanguageFeature` values; grammar
productions query it through `frontendSupportsFeature` and refuse feature syntax under older
languages with the targeted `LanguageFeatureRequiresVersion` diagnostic (raised by
`requireLanguageFeatureAt` in `keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`, lines 121–130). The
feature relevant here is `DomainCommandOutcomeSyntax`, owned by `profileV4` (the language-5
profile) in `LanguageVersion.hs`. Parsing dispatch flows from
`keiro-dsl/src/Keiro/Dsl/Parser.hs` (public facade) through
`keiro-dsl/src/Keiro/Dsl/Parser/Document.hs` (`parseSurfaceSource` selects the language via
`keiro-dsl/src/Keiro/Dsl/Parser/Preamble.hs`, then runs one shared modular grammar with the
selected `FrontendContext`).

The typed domain-outcome syntax (candidate language 5, added by
`docs/plans/232-add-typed-domain-outcomes-to-the-dsl.md`) has exactly two spellings:

- `domain-outcomes rejection=<Type> no-op=<Type>` directly after the aggregate header
  (`pDomainOutcomeTypes`, `keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs` lines 92–106), and
- an `outcome accepted` / `outcome rejected <expr>` / `outcome no-op <expr>` clause inside a
  transition's clause list (`pClause`, same file, lines 359–376).

The defect: commit `2bcec017` (plan 232) added five words to `reservedWords` in
`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs` — the list of words the identifier parser `ident`
(lines 272–279) refuses unconditionally, before any feature gate. A follow-up in the same plan
(commit `924bcb80`, "preserve identifiers around typed outcomes") removed `accepted`,
`rejected`, and `rejection` after existing fixtures broke, but left `"domain-outcomes"` (line
212) and `"outcome"` (line 213) in the list. At the 0.11.0.0 tag (`e796227c`,
`keiro-dsl-0.11.0.0`) neither word was reserved, so any published-language source naming
something `outcome` was legal then and fails to parse now. Because `ident` is wrapped in
`lexeme . try`, its internal "unexpected reserved word" failure backtracks, and the user sees a
misleading downstream structural error. Verified reproduction at HEAD — this language-4 spec
(legal at 0.11.0.0; the same body with `result` in place of `outcome` checks `OK` at HEAD
today, for every published language):

```text
language keiro-dsl 4
context outcome-ident

aggregate Account
  regs
    outcome Text = "none"
  states Open Done!

  command Close { outcome:Text }

  event AccountClosed = fields(Close)

  Open -- Close -->
    write outcome := cmd.outcome
    emit AccountClosed
    goto Done
```

```console
$ cabal run -v0 keiro-dsl -- check /tmp/outcome-ident-v4.keiro
/tmp/outcome-ident-v4.keiro:6:5:
  |
6 |     outcome Text = "none"
  |     ^^^^^^
unexpected "outcom"
expecting "states"
$ echo $?
1
```

The same failure reproduces for the legacy-unversioned form and declared languages 1, 2, and 3,
and in every `ident` position: enum constructors (`enum Decision { outcome=outcome-wire … }`
fails with `unexpected 'o' expecting '}'`), states, transition sources, command/event names, and
fields. Positions parsed by `wireWord` (context names, enum wire spellings such as
`outcome-wire`, status-map values) were never affected, because `wireWord` does not consult
`reservedWords`. `keiro-dsl diff` parses both the working-tree file and the `--since <ref>`
baseline with the same parser, so a deployed service's diff gate cannot even load its committed
baseline — regeneration and evolution gating are hard-blocked, which is why this fix gates the
language-5 publication flip.

Two facts make the contextual fix safe, and both were verified during planning:

1. `reservedWords` has exactly one consumer: `ident` in the same module. (It is also exported
   from the public module `Keiro.Dsl.Parser.Core`; a repo-wide search found no other consumer —
   the `reservedWords` in `keiro-dsl/test/haskell-name/Main.hs` is an unrelated local list of
   Haskell keywords.) Removing the two entries restores the exact 0.11.0.0 list.
2. The only grammar sites that consume `outcome` as a keyword are the gated clause in `pClause`,
   and `pRunOp` in `keiro-dsl/src/Keiro/Dsl/Parser/Workflow.hs` (line 125, `run … input …
   outcome -> …`), which shipped in 0.11.0.0 while `outcome` was unreserved — that is, it has
   always been a contextual keyword there. The repository has further precedent for contextual
   recognition over global reservation: language preambles are recognized contextually
   (`docs/plans/167-parse-keiro-language-preambles-and-feature-gates-from-grammar-context.md`,
   IR-11), and plan 232 made the three selector words contextual.

Why the one-token lookahead is unambiguous, including for language 5: `pClause` alternatives are
all introduced by keywords (`guard`, `write`, `emit`, `goto`, `implementation hole`, and the
outcome clause). A clause list (`many pClause` inside `pTransition`) ends when no alternative
matches, and the enclosing aggregate-body grammar (`pBodyItem`) then accepts commands, events,
wire/projection/snapshot blocks (all keyword-led), or another transition — the only production
that begins with a bare identifier, and its second token is always `--`. The expression grammar
is built with `makeExprParser` over single-path terms (no juxtaposition), so an expression can
never absorb a following `outcome` word. Therefore `outcome` followed by `accepted`, `rejected`,
or `no-op` occurs in a valid program only as the language-5 clause, and `outcome` followed by
anything else (most importantly `--`) is an ordinary identifier.

Relevant ADRs, both local (no relevant cross-repository ADR was found):

- `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md` — a source
  selects a registered language contract before body parsing; published versions are immutable
  and "existing version parsers and their rejection fixtures are not widened". The reservation
  violates exactly this: it narrowed published languages 1–4 after release. This plan restores
  them, and the MasterPlan directs that the resulting principle (contextual keywords, never
  global reservation, for syntax introduced by a later language) be recorded in this ADR.
- `docs/adr/0029-typed-domain-decisions-are-successful-additive-command-outcomes.md` — the
  semantics behind `DomainCommandOutcomeSyntax`: typed accepted/rejected/no-op decisions are
  successful additive command outcomes classified on Keiki's exact selected edge. This plan does
  not touch those semantics; it only changes how the surface keywords are recognized.

The parent MasterPlan is
`docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md`
(this plan is its EP-1). Its integration constraint: the compiled conformance corpus — the
committed `keiro-dsl/test/conformance-*` directories of real `keiro-dsl scaffold` output,
checked bit-for-bit by `scripts/check-conformance-corpus.sh` via the
`keiro-dsl-corpus-regen` tool (`keiro-dsl/tools/corpus-regen/src/Main.hs`) — is also touched by
plan 234 (`docs/plans/234-bind-catalog-read-models-to-one-explicit-physical-target.md`).
Whichever plan lands second runs its corpus verification on top of the first's committed state.
The language-5 outcome corpus specifically lives in
`keiro-dsl/test/conformance-domain-outcomes/` (test suite
`keiro-dsl-conformance-domain-outcomes`), generated from
`keiro-dsl/test/fixtures/domain-command-outcomes.keiro`, with mutation evidence in
`keiro-dsl/test/domain-command-outcome-mutation-test.sh`.


## Plan of Work

The work is three milestones: make the regression observable as failing tests, make the
two-site parser change that turns them green without disturbing language 5, then prove the
corpus and the whole repository gate are clean and distill the durable decision into the ADR.

Milestone 1 — regression fixtures and red tests. Four small `.keiro` fixtures go into
`keiro-dsl/test/fixtures/`, exercising `outcome` as an identifier in every affected position
and under every published language, plus a language-5 fixture proving coexistence with the real
outcome clauses. One new hspec describe block in `keiro-dsl/test/Main.hs` parses them all. At
the end of this milestone the new examples fail against HEAD (proving they capture the defect)
while every pre-existing example still passes. The fixture bodies below were validated during
planning by running `keiro-dsl check` on identical specs with the neutral identifier `result`
in place of `outcome`: legacy, declared 1, 2, 3, 4, the positions body, and the language-5 body
all print `OK` at HEAD, so the only thing the new tests can be red about is the reservation
itself.

Milestone 2 — the fix. Two edits. First, delete the `"domain-outcomes"` and `"outcome"` entries
from `reservedWords` in `keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`, restoring the exact 0.11.0.0
list. Second, in `keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs`, make the `outcome` clause
marker in `pClause` contextual: recognize the word only when the next token is one of
`accepted`, `rejected`, or `no-op`, backtracking otherwise so the published grammar sees the
identifier. The feature gate stays where it is, so pre-5 sources attempting real outcome syntax
keep their targeted diagnostic (the existing test "gates the syntax to candidate language 5" at
`keiro-dsl/test/Main.hs:1856` pins this and must stay green untouched). At the end of this
milestone the new tests are green, the whole `keiro-dsl-test` suite is green, the
`keiro-dsl-conformance-domain-outcomes` suite is green, and the before/after CLI transcripts
are captured.

Milestone 3 — corpus proof, full gate, documentation. Add the changelog entry, prove the
committed conformance corpus has zero drift (`just conformance-corpus-policy`), run the full
test set (`cabal test keiro-dsl:tests`) and the repository gate (`just verify`), update ADR
0016 with the contextual-keyword principle, and update the MasterPlan's EP-1 row and progress
checkboxes. Commit at each stable point with conventional-commit messages (for example
`test(dsl): capture outcome identifier regression across published languages` after M1 and
`fix(dsl): parse outcome keywords contextually instead of reserving them` after M2).


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`, inside the
development environment (prefix commands with `nix develop -c` if `cabal`/`just` are not
already on PATH in your shell).

Step 1 — write the fixtures. Create these four files exactly as shown.

`keiro-dsl/test/fixtures/outcome-identifier-legacy.keiro` (no preamble — legacy-unversioned,
effective language 1; uses the legacy expression grammar, where a write right-hand side is a
bare name and fields are untyped):

```text
context outcome-ident

aggregate Account
  regs
    outcome Text = "none"
  states Open Done!

  command Close { outcome }

  event AccountClosed = fields(Close)

  Open -- Close -->
    write outcome := outcome
    emit AccountClosed
    goto Done
```

`keiro-dsl/test/fixtures/outcome-identifier.keiro` (language 4; typed expressions — the test
rewrites the preamble to exercise languages 2 and 3 with the same body):

```text
language keiro-dsl 4
context outcome-ident

aggregate Account
  regs
    outcome Text = "none"
  states Open Done!

  command Close { outcome:Text }

  event AccountClosed = fields(Close)

  Open -- Close -->
    write outcome := cmd.outcome
    emit AccountClosed
    goto Done
```

`keiro-dsl/test/fixtures/outcome-identifier-positions.keiro` (language 4; `outcome` as an enum
constructor, a state name, and a transition source — lowercase states and constructors are
legal at language 4, verified during planning with the neutral name):

```text
language keiro-dsl 4
context outcome-state

enum Decision { outcome=outcome-wire Other=other-wire }

aggregate Review
  regs
    d Decision = Other
  states outcome Done!

  command Finish { note:Text }

  event Finished = fields(Finish)

  outcome -- Finish -->
    emit Finished
    goto Done
```

`keiro-dsl/test/fixtures/outcome-identifier-v5.keiro` (language 5; typed outcome clauses
coexisting with `outcome` as a register, field, state, and transition source. The transition
order is deliberate: the first transition's clause list is followed immediately by a transition
whose source state is `outcome`, so the tokens after `goto Done` are `outcome --` — the exact
sequence that the contextual lookahead must refuse to claim):

```text
language keiro-dsl 5
context outcome-five

enum ReviewRejection { AlreadyDone=already-done }
enum ReviewNoOp { Duplicate=duplicate }

aggregate Review
  domain-outcomes rejection=ReviewRejection no-op=ReviewNoOp
  regs
    outcome Text = "none"
  states outcome Done

  command Finish { outcome:Text }

  event Finished = fields(Finish)

  Done -- Finish -->
    outcome no-op ReviewNoOp.Duplicate
    goto Done

  outcome -- Finish -->
    write outcome := cmd.outcome
    outcome accepted
    emit Finished
    goto Done
```

Step 2 — add the tests. In `keiro-dsl/test/Main.hs`, directly after the existing
`describe "typed-domain-outcomes"` block (which starts at line 1835), add a new block. Use the
same helpers the neighboring tests use: `readTestText` (resolves fixture paths from either the
package directory or the repo root), `parseSource` and `renderParseFailure` from
`Keiro.Dsl.Parser`, `renderSource`, and `validateService`/`checkedSource`. The shape:

```haskell
  describe "outcome identifier compatibility" $ do
    it "parses outcome as an ordinary identifier under legacy and declared language 1" $ do
      source <- readTestText "test/fixtures/outcome-identifier-legacy.keiro"
      case parseSource "outcome-identifier-legacy.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right _ -> pure ()
      case parseSource "outcome-identifier-v1.keiro" ("language keiro-dsl 1\n" <> source) of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right _ -> pure ()

    it "parses outcome as an ordinary identifier under languages 2, 3, and 4" $ do
      source <- readTestText "test/fixtures/outcome-identifier.keiro"
      forM_ ["2", "3", "4"] $ \version ->
        case parseSource
          ("outcome-identifier-v" <> T.unpack version <> ".keiro")
          (T.replace "language keiro-dsl 4" ("language keiro-dsl " <> version) source) of
          Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
          Right parsed
            | version == "4" -> validateService (checkedSource parsed) `shouldBe` []
            | otherwise -> pure ()

    it "parses outcome as an enum constructor, state, and transition source" $ do
      source <- readTestText "test/fixtures/outcome-identifier-positions.keiro"
      case parseSource "outcome-identifier-positions.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right parsed -> validateService (checkedSource parsed) `shouldBe` []

    it "round-trips outcome identifiers through the canonical renderer" $ do
      source <- readTestText "test/fixtures/outcome-identifier.keiro"
      parsed <- case parseSource "outcome-identifier.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "unreachable"
        Right value -> pure value
      parseSource "outcome-identifier-rendered.keiro" (renderSource parsed) `shouldBe` Right parsed

    it "keeps outcome usable as an identifier alongside language-5 outcome clauses" $ do
      source <- readTestText "test/fixtures/outcome-identifier-v5.keiro"
      case parseSource "outcome-identifier-v5.keiro" source of
        Left failure -> expectationFailure (T.unpack (renderParseFailure failure))
        Right parsed -> validateService (checkedSource parsed) `shouldBe` []
```

If `forM_` is not already imported in `Main.hs`, use `mapM_` with the same lambda. Do not
change the existing "gates the syntax to candidate language 5" example (line 1856): it rewrites
the preamble of `domain-command-outcomes.keiro` to language 4 and expects
`LanguageFeatureRequiresVersion`; it must pass unmodified before and after the fix, because the
fixture's `outcome accepted` clause is a genuine language-5 syntax attempt (the lookahead sees
`accepted`) and still reaches the feature gate.

Step 3 — observe red. Run the targeted suite and confirm the five new examples fail at HEAD
while nothing else does:

```bash
cabal test keiro-dsl-test --test-options='--match "outcome identifier compatibility"' --test-show-details=direct
```

Expect five failures whose messages are parse errors of the shape shown in Context and
Orientation (for example `unexpected "outcom" / expecting "states"`). Commit the red corpus
(`test(dsl): …`).

Step 4 — edit `keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`. In `reservedWords` (list starts at line
192), delete exactly two lines so the neighborhood reads as it did at 0.11.0.0:

```diff
     "projection",
     "snapshot",
-    "domain-outcomes",
-    "outcome",
     "category",
```

Also update the module's header comment block (lines 1–9) if you add one line noting that
language-5 outcome words are contextual, and leave everything else — `ident`, `keyword`,
`wireWord` — untouched.

Step 5 — edit `keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs`. In `pClause` (line 359), replace
the outcome branch's marker so the word is claimed only when a selector follows. Before:

```haskell
    [ do
        loc <- getLoc
        marker <- withOwnedSpan (keyword "outcome")
        requireLanguageFeatureAt context DomainCommandOutcomeSyntax (spanOf marker)
```

After (with a comment; `try`, `lookAhead`, and `<|>` are already in scope from
`Text.Megaparsec`):

```haskell
    [ do
        loc <- getLoc
        -- @outcome@ is a contextual keyword, never reserved (plan 233, completing
        -- plan 232's decision for accepted/rejected/no-op): claim it only when one
        -- of the three selectors follows, so @outcome@ stays a legal identifier in
        -- every language — including a transition source named @outcome@, whose
        -- next token is @--@.
        marker <-
          withOwnedSpan
            ( try
                ( keyword "outcome"
                    <* lookAhead (keyword "accepted" <|> keyword "rejected" <|> keyword "no-op")
                )
            )
        requireLanguageFeatureAt context DomainCommandOutcomeSyntax (spanOf marker)
```

The inner `choice` over the three selectors, and everything after it, stays exactly as it is —
the lookahead consumes nothing, so the selector keyword is still consumed by the existing
branches. `pDomainOutcomeTypes` (line 92) needs no change: `domain-outcomes` contains a dash,
`ident` can never match it, and no legal pre-5 program can place it at the marker position, so
its `requireLanguageFeatureAt` diagnostic remains correct as is.

Step 6 — observe green, then widen. In order:

```bash
cabal test keiro-dsl-test --test-options='--match "outcome identifier compatibility"' --test-show-details=direct
cabal test keiro-dsl-test --test-options='--match "typed-domain-outcomes"' --test-show-details=direct
cabal test -v0 keiro-dsl:keiro-dsl-conformance-domain-outcomes --test-show-details=direct
```

All must pass. Capture the after-transcript for the same spec that failed in the reproduction
(write `keiro-dsl/test/fixtures/outcome-identifier.keiro`'s content to a scratch path or use the
fixture directly):

```console
$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/outcome-identifier.keiro
OK
$ echo $?
0
```

(Language-4 sources print only `OK`; pre-4 languages print an informational "language contract:
effective keiro-dsl N …" line before `OK` — that line is expected and not an error.) Commit
(`fix(dsl): …`).

Step 7 — changelog. In `keiro-dsl/CHANGELOG.md` under `## Unreleased`, add a `### Fixed`
entry (or extend it if plan 234 created one first) in this spirit: published languages 1–4
again accept `outcome` (and the dashed `domain-outcomes`) as ordinary identifiers, restoring
the 0.11.0.0 grammar that the candidate language-5 outcome syntax had accidentally narrowed;
the outcome words are now contextual keywords in every language, so language-5 sources may also
use `outcome` as an identifier.

Step 8 — corpus and full gate:

```bash
just conformance-corpus-policy
cabal test keiro-dsl:tests
just verify
```

`just conformance-corpus-policy` replays every recorded scaffold invocation from a clean corpus
and fails if regeneration changes a byte; expect it to pass with no diff, proving the fix is
parser-only. `cabal test keiro-dsl:tests` runs all keiro-dsl suites (the bare package name would
silently run only one — the Justfile documents this). `just verify` is the full repository gate
(build, all package tests, ADR/research/capabilities validation, extension and naming policies,
corpus policy); it requires the repository's Postgres dev environment (`process-compose`) for
the database-backed suites — if your environment lacks it, run the keiro-dsl-scoped commands
above and state so in Progress.

Step 9 — ADR distillation and MasterPlan bookkeeping. Append to the Consequences (or Decision)
section of `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md` a
short paragraph recording the durable rule: syntax introduced by a later language version must
be recognized through contextual keywords (claimed only in its owning grammatical position,
behind its feature gate) and must never add entries to the global reserved-word list, because
reservation retroactively narrows published, immutable languages; cite plans 232 and 233 as the
precedent. Update
`docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md`:
set EP-1's registry row status and check its two EP-1 progress entries. Update this plan's own living sections, then commit
(`docs(adr): …` or fold into the fix commit per your commit granularity).


## Validation and Acceptance

Acceptance is behavioral. The change is complete when all of the following hold, in each case
run from `/Users/shinzui/Keikaku/bokuno/keiro`:

1. Restoration, demonstrated before/after. Before the fix,
   `cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/outcome-identifier.keiro` exits 1
   with the caret diagnostic at the `outcome Text = "none"` register line (transcript in Context
   and Orientation). After the fix the same command prints `OK` and exits 0. The same holds for
   the legacy fixture and for the language 1/2/3 preamble variants (pre-4 variants additionally
   print the informational language-contract line), and for
   `outcome-identifier-positions.keiro`.

2. Regression tests for every published language.
   `cabal test keiro-dsl-test --test-options='--match "outcome identifier compatibility"'
   --test-show-details=direct` reports 5 examples, 0 failures — and reported exactly these
   examples failing before the fix (red-to-green is part of the evidence; keep the red transcript
   in Progress or Surprises).

3. Language 5 is intact and less restricted, not changed. The untouched example "gates the
   syntax to candidate language 5" still passes (a language-4 source containing `outcome
   accepted` still fails with `LanguageFeatureRequiresVersion`), the whole `typed-domain-outcomes`
   block passes, and the new language-5 coexistence example passes, proving a language-5 source
   may both declare typed outcomes and name registers/fields/states `outcome` — including a
   transition source named `outcome` immediately after another transition's clause list.

4. The compiled language-5 outcome corpus still compiles and its runtime facts hold:
   `cabal test -v0 keiro-dsl:keiro-dsl-conformance-domain-outcomes --test-show-details=direct`
   passes.

5. The committed corpus has zero drift: `just conformance-corpus-policy` passes without
   regenerating anything (it fails loudly if any corpus byte changes or any corpus path is
   dirty — see Idempotence and Recovery if it refuses to start).

6. The full suites are green: `cabal test keiro-dsl:tests`, then `just verify`.

7. Evolution gating works again over an outcome-using spec: with the fixtures committed,
   `cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/outcome-identifier.keiro --since HEAD`
   exits 0 (no changes, nothing breaking). Before this plan the equivalent invocation could not
   even load the baseline, failing with the parse error from item 1. (Exact success wording may
   differ; the acceptance is the exit code and the absence of a parse failure.)

Interpretation of failures: a red example in the new describe block after M2 means the
contextual lookahead is wrong — check first that the lookahead covers exactly `accepted`,
`rejected`, `no-op`, and that `try` wraps the whole marker including the lookahead. A failure in
`typed-domain-outcomes` or the conformance suite means language-5 recognition regressed — the
most likely cause is a lookahead that consumes input or a dropped feature gate.


## Idempotence and Recovery

Every step is safe to repeat. The fixtures are plain new files; rewriting them is idempotent.
The two source edits are exact-match replacements; re-applying them is a no-op once applied.
All test commands are read-only with respect to the working tree. `just
conformance-corpus-policy` refuses to run if any `keiro-dsl/test/conformance-*` path is dirty —
that refusal protects uncommitted work; commit or `git restore` those paths and re-run. Do not
run `just corpus-regen` for this plan; if it was run by accident, discard the resulting
working-tree changes with `git restore keiro-dsl/test` (the corpus is fully committed, so a
clean checkout is always recoverable). If a `cabal` invocation fails with a missing-package
error (Cabal-7136), you are not at the repository root — every command in this plan assumes
`/Users/shinzui/Keikaku/bokuno/keiro` as the working directory. Commit after each milestone so
any misstep is recoverable by `git revert`/`git restore` of one small commit.


## Interfaces and Dependencies

No new libraries, packages, or modules. The change uses `try`, `lookAhead`, and `(<|>)` from
`Text.Megaparsec` (already imported by `Keiro.Dsl.Parser.Aggregate`) and the existing helpers
`keyword`, `withOwnedSpan`, `spanOf`, and `requireLanguageFeatureAt` from
`Keiro.Dsl.Parser.Core`.

Signatures that must hold at the end (all unchanged):

- `reservedWords :: [Text]` in `Keiro.Dsl.Parser.Core` — same type, same export, list contents
  shrunk by exactly `"domain-outcomes"` and `"outcome"` (matching the 0.11.0.0 contents; this is
  a value change in an exposed module, acceptable inside the 0.12.0.0 major release).
- `ident :: P Name` in `Keiro.Dsl.Parser.Core` — untouched.
- `pClause :: FrontendContext -> P (Clause, [Located SurfaceElement])` and
  `pDomainOutcomeTypes :: FrontendContext -> P DomainOutcomeTypes` in
  `Keiro.Dsl.Parser.Aggregate` — same signatures; only `pClause`'s outcome marker changes.
- `Keiro.Dsl.LanguageVersion` — entirely untouched: `languageRegistry`, `SyntaxProfile`
  contents, `LanguageFeature` constructors, and every runtime-semantics profile and fold
  segment stay byte-identical, so no replay identity, fingerprint, or serialized record moves.

Test-side dependencies (already present in `keiro-dsl/test/Main.hs`): `readTestText`,
`parseSource`, `renderParseFailure`, `renderSource`, `validateService`, `checkedSource`,
hspec's `describe`/`it`/`shouldBe`/`expectationFailure`, and `Data.Text` as `T`. Tooling:
`cabal`, `just`, and for `just verify` the repository's full dev environment (Postgres via
`process-compose`, `okf`, shell scripts under `scripts/`).


Plan revision note (2026-08-12): Milestone 1 fixtures and red regression evidence were added
to the living sections after the focused suite failed in all five intended examples.

Plan revision note (2026-08-12): Milestone 2 parser changes and focused green evidence were
recorded after compatibility, feature-gating, compiled conformance, CLI, and diff checks passed.
