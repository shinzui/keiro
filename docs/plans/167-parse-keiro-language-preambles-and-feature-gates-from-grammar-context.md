---
id: 167
slug: parse-keiro-language-preambles-and-feature-gates-from-grammar-context
title: "Parse Keiro language preambles and feature gates from grammar context"
kind: exec-plan
created_at: 2026-08-01T00:15:25Z
intention: "intention_01kyxarnbbet3ajn0995gt65w9"
master_plan: "docs/masterplans/27-repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions.md"
---

# Parse Keiro language preambles and feature gates from grammar context

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, `language` is recognized as a Keiro language preamble only at the beginning of
a source document. A mapped field such as `language as "language" : Text required`, a direct field,
a comment, or a string containing `using`, `Integer`, `implementation hole`, `reg.`, or `cmd.` can
no longer select a language or trip a version gate. Existing version-1 and version-2 documents keep
their released meaning.

The result is visible by running `keiro-dsl check` and `scaffold` over the adversarial fixtures in
this plan: both the unversioned and `language keiro-dsl 2` variants containing a nested `language`
field succeed, while a real second or misplaced preamble fails at its own source location.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-01 09:10 PDT) Milestone 1: added an adversarial lexical corpus that reproduces
  IR-11 through the library, single-file CLI, and workspace loader.
- [x] (2026-08-01 09:21 PDT) Milestone 2: replaced the file-wide preamble scan with
  grammar-positioned preamble dispatch while preserving the public `ParsedSource` and
  `SourceLanguage` contracts.
- [x] (2026-08-01 09:21 PDT) Milestone 3: replaced raw body-feature substring scans with
  grammar-owned feature evidence and exact source locations.
- [ ] Milestone 4: run compatibility, scaffold, workspace, documentation, and release validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-01: `Keiro.Dsl.Parser.selectSourceLanguage` filters every significant line with
  `isLanguageLine`, where any line whose first whitespace-delimited word is `language` counts as a
  preamble. `ensureBodyFeatures` independently searches raw line words and substrings. Existing
  tests cover true preambles and true successor syntax but not collisions in nested identifiers,
  quoted wire keys, comments, or strings.
- 2026-08-01: the focused source-language suite reproduced the collision at the exact mapped field
  line before implementation: `language-identifier-v1.keiro:16:1` was misclassified as
  `MisplacedLanguagePreamble`, and both library and CLI assertions failed while all prior
  source-language assertions remained green.
- 2026-08-01: Megaparsec custom error components preserve the existing structured
  `SourceLanguageFailure` boundary while allowing duplicate, misplaced, and successor-feature
  failures to originate after the owning grammar has consumed a real syntax marker. The focused
  suite now passes 16 examples, including exact-line assertions for nominal bindings, `Integer`,
  typed paths, and explicit Hole ownership.
- 2026-08-01: the first full-suite run passed 426 of 427 examples and exposed one compatibility
  boundary: version-1 bare-name arithmetic such as `revision + amount` historically reports the
  operator-specific body-grammar error because `+` was never a source-language feature marker.
  Restoring that diagnostic made both the four-example scalar diagnostic group and the
  16-example source-language group pass.


## Decision Log

Record every decision made while working on the plan.

- Decision: Parse at most one optional preamble after leading trivia and before `context`; diagnose
  later real preamble clauses through parser context rather than a global first-word scan.
  Rationale: `language` is contextual syntax, while domain identifiers are intentionally reusable
  in nested grammar positions. Only the parser knows which position it is reading.
  Date: 2026-08-01

- Decision: Derive successor-feature evidence from parsed tokens or checked AST nodes, never from
  raw `Text` substring searches.
  Rationale: a lexical search cannot distinguish syntax from comments, quoted keys, or legal names
  and therefore cannot preserve a frozen predecessor language.
  Date: 2026-08-01

- Decision: Ship this as a compatibility repair for released version 1 and version 2, not as a new
  source language version.
  Rationale: the current behavior violates the already-declared grammar contract; correcting a
  false collision restores rather than changes the language.
  Date: 2026-08-01

- Decision: Keep the feature-to-minimum-version policy in `Keiro.Dsl.LanguageVersion` and use a
  private Megaparsec custom error component to return the existing public diagnostic shape.
  Rationale: the registry remains the one authority for released feature ownership, while parser
  internals can attach precise source locations without exposing Megaparsec types or changing
  `ParsedSource`, `SourceLanguage`, or `ParseFailure`.
  Date: 2026-08-01

- Decision: Move only the released gate markers from `requiresSuccessorSyntax` into grammar
  productions; do not broaden `LanguageFeatureRequiresVersion` to every token accepted by the
  version-2 expression parser.
  Rationale: EP-167 is a compatibility repair. Existing version-1 operator diagnostics are part of
  the released negative corpus, while `using`, `Integer`, `implementation hole`, `reg.`, `cmd.`,
  and `mapped nominal` are the markers that already selected the structured language diagnostic.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(Implementation not started.)


## Context and Orientation

The owning request is
[IR-11](../improvement-requests/parse-language-preambles-contextually-without-colliding-with-domain-identifiers.md).
`keiro-dsl/src/Keiro/Dsl/Parser.hs` exposes `parseSource` and `parseSpec`. `parseSource` currently
calls `selectSourceLanguage`, then `ensureBodyFeatures`, then the selected body parser.
`selectSourceLanguage` builds `significantLines`, strips comments with a character-level rule, and
searches the complete file with `isLanguageLine`. `ensureBodyFeatures` searches those same raw
lines for version-2 spellings.

`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` owns `SourceLanguage`, supported versions, effective
version selection, and source-language diagnostics. `keiro-dsl/src/Keiro/Dsl/Workspace.hs` parses
each member with provenance and refuses mixed effective versions. The public result should remain
`ParsedSource`, so this repair does not force semantic consumers to understand parser internals.

`keiro-dsl/test/Main.hs` contains source-language unit, CLI, and workspace tests. Add dedicated
fixtures under `keiro-dsl/test/fixtures/` for mapped fields, direct fields, declarations, comments,
and strings. At least one fixture must reproduce the unchanged Mori field from IR-11.

[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) is the
relevant durable decision. It requires selection before body parsing, freezes released versions,
and keeps provenance outside `Spec`; this plan corrects the selection implementation without
changing that boundary. ADR 4 requires the malformed real preamble to fail at the earliest parser
boundary with its own location.


## Plan of Work

Milestone 1 pins the failure before implementation. Add positive fixtures with a nested field named
`language`, both without a preamble and after one legal version-2 preamble. Add strings, wire keys,
and comments containing every spelling recognized by `requiresSuccessorSyntax`. Add negative
fixtures for a second genuine preamble and a genuine preamble after `context`. Assert diagnostic
kind and line, not only exit status.

Milestone 2 moves preamble parsing into the document grammar. In
`keiro-dsl/src/Keiro/Dsl/Parser.hs`, parse leading whitespace/comments, then an optional complete
`language keiro-dsl N` clause, then require `context`. Dispatch the remaining body through the
selected parser. Preserve unsupported-version and malformed-preamble diagnostics. A later
top-level `language keiro-dsl N` clause should receive `MisplacedLanguagePreamble`, but nested
grammar positions that accept a name must continue treating `language` as a name.

Milestone 3 removes `ensureBodyFeatures` raw scans. The selected grammar may reject successor-only
constructs structurally, or a parsed intermediate form may carry located feature tags checked
against the effective version. Keep one central feature/version registry in
`LanguageVersion.hs`; do not maintain a second list of textual substrings. Comments and quoted
content never create feature tags.

Milestone 4 runs the complete compatibility surface. Prove `parseSpec` wrappers, CLI `check` and
`scaffold`, one-member and multi-member workspaces, pretty-print round trips, all released positive
and negative language fixtures, and unchanged generated bytes for semantically unchanged input.
Update `docs/user/typed-spec-toolchain.md`, the notation reference used by the authoring skill, and
`keiro-dsl/CHANGELOG.md`. Amend ADR 16 only if the implementation changes its durable dispatch
description; a pure implementation correction needs only a plan decision and regression tests.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-dsl-test --test-option=--match --test-option='source language'
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/language-identifier-v1.keiro
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/language-identifier-v2.keiro
cabal test keiro-dsl-test
cabal build all
nix flake check
```

The two explicit checks exit zero. Focused negative tests report the real duplicate or misplaced
preamble line; the full suite and build exit zero.


## Validation and Acceptance

Acceptance requires the unchanged mapped field `language as "language" : Text required` to check
and scaffold in both released language modes. Every version-feature spelling must be inert inside
comments, strings, wire aliases, and nested identifiers. Exactly one leading real preamble selects
the parser; a second and a post-declaration preamble fail at their own lines. All prior v1/v2
fixtures retain their intended result, and reversing workspace member order does not change
diagnostics or generated bytes.


## Idempotence and Recovery

Parser and test edits are deterministic and contain no migration. Scaffold checks must use a
temporary output directory until the regression corpus is green. If a parser rewrite changes an
unrelated diagnostic, keep the red fixture and narrow the grammar change rather than regenerating
goldens indiscriminately.


## Interfaces and Dependencies

Keep `Keiro.Dsl.LanguageVersion.SourceLanguage`, `ParsedSource`, `parseSource`, and `parseSpec`
source-compatible. The implementation may introduce an internal located preamble type, but no raw
line classifier should remain authoritative. `Keiro.Dsl.Workspace` continues comparing
`effectiveLanguageVersion` from each parsed member. No dependency changes are required.
