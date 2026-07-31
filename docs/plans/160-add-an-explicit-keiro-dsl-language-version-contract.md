---
id: 160
slug: add-an-explicit-keiro-dsl-language-version-contract
title: "Add an explicit Keiro DSL language version contract"
kind: exec-plan
created_at: 2026-07-31T14:46:35Z
---

# Add an explicit Keiro DSL language version contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, every Keiro DSL source can state which released language contract it was
written for:

```keiro
language keiro-dsl 1
context hospital-capacity
```

The tool selects that contract before parsing the source body, rejects future versions before
current syntax can be misinterpreted, and preserves both the declared version and the effective
version selected by the tool. `keiro-dsl parse` retains an explicit declaration, a new
`keiro-dsl inspect --format=json` path reports source-language provenance, and workspaces report
the provenance of every member. Existing unversioned sources remain readable as an explicitly
identified legacy form whose effective version is 1.

This plan deliberately does not implement `keiro-dsl upgrade` or rewrite other repositories. It
creates the stable parser-dispatch and provenance boundary required by the already-filed
[IR-5](../improvement-requests/add-version-aware-keiro-dsl-upgrade-and-fleet-rewrite-tooling.md).


## Progress

- [ ] Milestone 1: add the source-language model, version registry, provenance-preserving parse
  entry point, and early preamble diagnostics while retaining the existing semantic `Spec` API.
- [ ] Milestone 2: route CLI and workspace loading through the new entry point; add inspection,
  record provenance, and provenance-only diff reporting without changing fold/replay semantics.
- [ ] Milestone 3: declare version 1 in Keiro-owned fixtures, skeletons, and documentation; add
  legacy/future/malformed coverage; update the ADR and changelog; and complete validation.


## Surprises & Discoveries

- 2026-07-31: `keiro-dsl/app/Main.hs` currently exposes only `parse`, `check`, `scaffold`, `diff`,
  and `new`. There is no `pretty` command and no JSON `inspect` command; `parse` is the existing
  pretty-printing path. This plan must add `inspect` explicitly rather than referring to an
  existing inspection path.
- 2026-07-31: `Keiro.Dsl.Grammar.Spec` is the semantic value merged into
  `WorkspaceSpec.wsMergedSpec`. Putting one source-language field on `Spec` would misrepresent a
  workspace containing both legacy and explicitly versioned members. Source provenance therefore
  needs a wrapper around `Spec` plus one value per `WorkspaceMember`.
- 2026-07-31: `ScaffoldRecord` and `WorkspaceRecord` are histories used for stale-path, ownership,
  mapping, and obligation drift. They are not parser-result caches. Language rows belong there for
  provenance and drift reporting, not to claim cache invalidation behavior that does not exist.
- 2026-07-31: The checked-in fixture corpus contains 211 `.keiro` files, all currently beginning
  with `context`. Migrating them shifts source lines, so located diagnostic expectations and
  golden transcripts must be updated deliberately rather than assuming a header-only edit is
  invisible to tests.
- 2026-07-31: IR-5 already exists at
  `docs/improvement-requests/add-version-aware-keiro-dsl-upgrade-and-fleet-rewrite-tooling.md`.
  This plan must not attempt to file it again.
- 2026-07-31: `ParseError` is currently rendered `Text`, while the append-only
  `DiagnosticCode` registry belongs to parsed single-spec and diff findings. Early version
  failures need their own structured source-selection error codes plus a compatibility renderer;
  they must not be forced through `validateSpec`, which never receives an unsupported source.
  Workspace member parse failures currently retain the outer `WorkspaceMemberParseFailed` code,
  so their rendered/structured cause must preserve the underlying source-selection code rather
  than pretending the outer attribution wrapper does not exist.
- 2026-07-31: Mori identifies `mori://shinzui/keiro/packages/keiro-dsl` and reports multiple
  registered Keiro dependents, but the local project has no curated Mori docs for this package.
  Fleet inspection and rewriting remain IR-5 work; no dependent checkout is edited by this plan.


## Decision Log

- Decision: Use a first-significant-clause preamble, `language keiro-dsl <positive-decimal>`,
  before `context`; continue to parse a missing preamble as `LegacyUnversioned`.
  Rationale: The tool can select a parser before reading version-sensitive body syntax, while
  existing fleets remain usable until explicit upgrade tooling exists. Comments and whitespace
  may precede the preamble, but no other clause may.
  Date: 2026-07-31

- Decision: Version 1 denotes the complete language accepted when this plan lands. Unversioned
  input has effective version 1 but never acquires a declared version unless an explicit rewrite
  changes the source.
  Rationale: Ordinary parse/pretty must not masquerade as a migration or erase the distinction
  between intentional versioning and compatibility fallback.
  Date: 2026-07-31

- Decision: Keep source-language provenance in a `ParsedSource`-style wrapper around the existing
  semantic `Spec`, and retain additive compatibility functions that return only `Spec`.
  Rationale: `Spec` is also the merged workspace graph and the input to semantic validators,
  fingerprints, and replay analysis. A wrapper preserves truthful per-document provenance without
  inventing one declaration for a synthetic merged graph or forcing unrelated semantic consumers
  to carry it.
  Date: 2026-07-31

- Decision: Maintain one parser registry containing each released version, its predecessor, and
  its body-parser configuration. Released-version parser configurations and rejection fixtures
  are append-only.
  Rationale: A version number is useful only if it selects a stable grammar/semantics contract.
  Later syntax plans must add a successor entry and must prove that the released v1 entry still
  rejects their new syntax.
  Date: 2026-07-31

- Decision: Reject zero and malformed version tokens as invalid preambles, and reject an unknown
  positive version as `UnsupportedLanguageVersion`, reporting the declared value and the exact
  supported set.
  Rationale: Versions are positive identifiers; zero is not a version. Separating invalid syntax
  from a well-formed future version gives tools a stable, actionable failure before body parsing.
  Date: 2026-07-31

- Decision: Give source-selection failures a small parse-boundary code type and retain the public
  rendered-`Text` parser as a compatibility wrapper.
  Rationale: All CLI paths need one stable version failure, but adding constructors to
  `Validate.DiagnosticCode` would assign a pre-parse fact to a validator that can never observe
  it and would contradict the repository's existing malformed-source boundary.
  Date: 2026-07-31

- Decision: A workspace may mix legacy-unversioned and declared-v1 members because their effective
  version is the same; different effective versions are refused before semantic graph merge.
  Rationale: Member provenance remains visible, while one composed graph never silently combines
  two language contracts. This also preserves the all-or-nothing workspace upgrade requirement
  deferred to IR-5.
  Date: 2026-07-31

- Decision: Report a legacy-to-declared-v1 rewrite as a provenance-only diff with an all-compatible
  vector, and keep `FoldFingerprint` and `ReplayImpact` functions version-unaware.
  Rationale: If both parsers produce the same semantic `Spec`, the header rewrite changes neither
  stored bytes nor replay behavior. Feeding the header into fold identity would create needless
  snapshot invalidation and conflict with the semantic/source separation.
  Date: 2026-07-31

- Decision: Extend scaffold record v1 files with ignore-unknown source-language rows; decode a
  missing row as legacy-unversioned and report language drift on later runs.
  Rationale: Existing record parsers deliberately ignore unknown row kinds, so an additive row is
  backward readable. Bumping or replacing the record schema would discard usable stale/ownership
  history without a semantic need.
  Date: 2026-07-31

- Decision: Keep this audit follow-on as a standalone ExecPlan rather than reopening the completed
  structural-consumer-type MasterPlan.
  Rationale: The source-language contract is an independent prerequisite for later syntax work and
  should expose its own implementation state.
  Date: 2026-07-31


## Outcomes & Retrospective

(To be filled during and after implementation. At completion, compare the delivered CLI,
workspace, provenance, and compatibility behavior with the purpose above, record remaining gaps,
and distill any additional durable decisions into `docs/adr/`.)


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Parser.hs` currently runs one Megaparsec parser,
`sc *> pSpec <* eof`, and `pSpec` immediately requires `context`. `ParseError` is a type alias for
rendered `Text`. `keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines `Spec`, which contains context,
module/layout choices, declarations, and nodes but no source-document metadata.
`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` renders a semantic `Spec` beginning at `context`.

Keep `Spec` semantic. Add a focused `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` module for the
opaque positive `LanguageVersion`, `SourceLanguage`, source-selection failures, and JSON
provenance. Add a provenance-preserving parser entry point in `Parser.hs` that returns a source
wrapper containing `SourceLanguage` and `Spec`; preserve `parseSpec` and `parseSpecText` as
documented wrappers that discard provenance only after version dispatch succeeds. Add a matching
source renderer in `PrettyPrint.hs`; leave `renderSpec` as the semantic/legacy renderer used by
existing generators and tests.

`keiro-dsl/src/Keiro/Dsl/Workspace.hs` parses every member separately, stores the parsed `Spec` in
`WorkspaceMember.wmSpec`, relocates semantic `Loc` values into `wsMergedSpec`, and validates that
merged graph. Extend each member with its original `SourceLanguage`. Do not relocate the preamble
location into the merged `Spec`; it remains a member-source location used by inspection and any
version-compatibility refusal. Compare effective versions after member parsing and before
declaration/node merge. The manifest grammar itself remains unversioned and unchanged.

`keiro-dsl/app/Main.hs` owns the complete command tree. For a `.keiro` input, `parse` is the
canonical pretty path and `check --emit` also renders that source. `parse` on a
`.keiro-workspace` remains the existing manifest-only canonicalizer; it does not load members.
Add an `Inspect` command whose `--format=json` output uses schema
`keiro-dsl/source-inspection/1`. A single-source report carries `path`, `sourceForm`, nullable
`declaredLanguageVersion`, and non-null `effectiveLanguageVersion`. A workspace report adds service
identity and a canonically ordered `members` array with those fields per member. Single-file
parse/check/scaffold/diff/inspect and member-loading workspace check/scaffold/diff/inspect must all
use the same source parser. A single-file future version renders `UnsupportedLanguageVersion`
directly; a workspace member keeps the existing `WorkspaceMemberParseFailed` attribution while
preserving `UnsupportedLanguageVersion` as its structured/rendered cause.

`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs` are line-oriented v1 histories whose parsers ignore
unknown row kinds. Add one canonical JSON source-language row to a single-file record and one row
per member to a workspace record without changing either header. Update
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` to write the rows and report provenance drift; a
missing row in an older record means legacy-unversioned, never declared v1. The single-file
scaffold planner and generated module functions continue to accept semantic `Spec`. Add a
source-aware execution entry point that receives `SourceLanguage` for the record, route the CLI
through it, and retain the existing `executeScaffold` as a compatibility wrapper that records
legacy provenance when a library caller has deliberately supplied only `Spec`.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceDiff.hs` currently compare semantic specs. Preserve
`diffSpecs`. Append the diff-only `SourceLanguageDeclarationChanged` constructor to
`Keiro.Dsl.Validate.DiagnosticCode`, then add source-aware entry points that prepend a finding with
an all-compatible vector when only the declaration form changes and annotate a workspace member's
provenance finding with that member path. Extend `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` with an
explicit no-action/provenance remedy so this compatible finding does not misleadingly recommend a
version bump, consumer rebuild, or conformance run. Pass only the wrapped semantic specs to
`keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs` and
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`; add regression tests proving a header-only rewrite keeps
the same fold surface/fingerprint and returns `ReplayNeutral`.

[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires
future-version rejection at the first boundary with enough evidence. [ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
requires one semantic workspace composition authority. [ADR 15](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
defines the history format that receives per-member provenance. [ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) records the source-wrapper,
version-dispatch, and provenance-only compatibility decisions established by this validation.

“Declared version” is the positive number written in a source preamble. “Effective version” is the
registered body grammar selected by the tool. “Legacy-unversioned” means no preamble was written;
for this compatibility window it selects effective version 1. A “semantic `Spec`” is the normalized
declaration/node graph after parser selection, without source-document provenance.


## Plan of Work

Milestone 1 establishes the source boundary without changing semantic consumers. Create
`LanguageVersion.hs`, expose an opaque positive version type and explicit legacy/declared source
forms, and define the one supported-version registry with version 1 and no predecessor. Refactor
`Parser.hs` so it first parses only the optional preamble, selects a registered body-parser
configuration, and then parses `context` plus the existing v1 body. Introduce a structured
source-level parse result and error renderer while keeping `parseSpec`/`parseSpecText` source
compatible. Add parser tests for comments/whitespace before the preamble, declared v1, legacy,
zero, non-decimal/negative tokens, unsupported v2, duplicate preambles, a preamble after `context`,
and proof that an unsupported version produces no secondary body-grammar failure. This milestone
is complete when both legacy and v1 sources produce equal semantic `Spec` values but different
`SourceLanguage` values.

Milestone 2 makes provenance observable end to end. Switch the single-file CLI branches and
workspace member loader to the source-preserving parser, while leaving workspace-manifest `parse`
as the manifest-only canonicalizer. Render declared single sources with their preamble and legacy
sources without one; do not add a normalization flag, because changing a legacy declaration
belongs to IR-5. Store language metadata per workspace member, enforce equal effective versions
before merge, and keep `wsMergedSpec` semantic. Add `inspect --format=json` for single files and
workspaces. Extend both scaffold record formats with additive canonical JSON rows, decode old
records as legacy, and report language drift without changing generated module bytes. Add
source-aware single/workspace diff entry points and the compatible provenance finding. Prove with
tests that a header-only legacy-to-v1 rewrite leaves `diffSpecs`, generated modules, fold
fingerprints, and replay impact unchanged. Add the append-only diff code and an explicit
no-semantic-action remedy to `Validate.hs` and `DiffReport.hs`, including their registry and JSON
rendering tests.

Milestone 3 makes version 1 the normal Keiro-owned source form while preserving focused legacy
coverage. Add named `language-v1.keiro`, `language-legacy.keiro`, `language-future.keiro`, and
malformed/misplaced fixtures. Prepend `language keiro-dsl 1` to the 211 existing on-disk `.keiro`
fixtures except the explicit source-version negative/legacy allowlist, then update line-sensitive
diagnostic tests and goldens. Make every `new <kind>` skeleton declare v1. Update
`agents/skills/keiro-dsl-authoring/SKILL.md`, `NOTATION.md`, `WALKTHROUGH.md`, and `LOOP.md`, plus
`docs/user/typed-spec-toolchain.md`, `docs/corpus/keiro-dsl-corpus.md`, the root `README.md`, and
`keiro-dsl/CHANGELOG.md`. Add the preamble to complete `.keiro` examples; grammar fragments that
do not represent a whole source remain fragments. Keep IR-5 linked and aligned; do not create
another request or edit a dependent repository. Finish by updating ADR 16 from Proposed to
Accepted only if the implemented behavior and tests match it, recording the ADR log update, and
running the repository checks below.

This version registry is a hard prerequisite for
[plan 158](158-bind-direct-aggregate-ids-enums-and-nominal-scalars-to-consumer-owned-haskell-types.md)
and [plan 161](161-extend-aggregate-expressions-with-typed-literals-arithmetic-membership-and-quantification.md).
Each later plan must register its syntax under a successor language definition (or a deliberately
shared unreleased successor), add a predecessor relation, and add a fixture proving released v1
still rejects the new form. Neither plan needs to implement the general upgrade command, but each
must document the manual rewrite until IR-5 lands.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro` after each milestone. During implementation, replace
the test filter with the final exact Hspec group name if it differs:

```bash
cabal test keiro-dsl-test --test-options='--match=source language version'
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/language-v1.keiro
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/language-future.keiro
cabal run -v0 keiro-dsl -- inspect keiro-dsl/test/fixtures/language-legacy.keiro --format=json
cabal run -v0 keiro-dsl -- inspect keiro-dsl/test/fixtures/workspace/service.keiro-workspace --format=json
rg --files-without-match '^language keiro-dsl 1$' keiro-dsl/test/fixtures -g '*.keiro'
cabal test keiro-dsl-test
cabal build all
nix flake check
just adr-validate
```

The v1 check prints `OK` and exits 0. The future-version check exits non-zero with one primary
`UnsupportedLanguageVersion` failure naming declared version 2 and supported version 1; it does not
continue into v1 grammar errors. The legacy inspection result is structurally equivalent to:

```json
{
  "schema": "keiro-dsl/source-inspection/1",
  "kind": "source",
  "path": "keiro-dsl/test/fixtures/language-legacy.keiro",
  "sourceForm": "legacy-unversioned",
  "declaredLanguageVersion": null,
  "effectiveLanguageVersion": 1
}
```

The workspace result lists members in the same canonical path order as `wsMembers`, with each
member's declaration and effective version. The `rg --files-without-match` output must contain only
the named source-version legacy, future, malformed, zero, duplicate, and misplaced fixtures; record
that final allowlist in the test next to the assertion so later fixtures cannot become unversioned
accidentally. During implementation, update this transcript to the final stable error rendering and
JSON envelope rather than leaving an approximate contract.


## Validation and Acceptance

1. `language keiro-dsl 1` is accepted as the first significant clause before `context`, survives
   single-file `parse` and `check --emit`, and is reported by single-file and workspace inspection.
2. A well-formed unsupported positive version fails before v1 body parsing with one stable
   `UnsupportedLanguageVersion` source-selection code and the exact supported set. Zero,
   malformed/negative tokens, duplicate preambles, and misplaced preambles fail with their own
   source-selection classifications and source locations. Workspace member failures retain the
   outer `WorkspaceMemberParseFailed` attribution and preserve the exact source-selection code as
   their cause.
3. Unversioned input remains readable, is explicitly reported as legacy, and has effective version
   1. No parsed source, record, report, or JSON response falsely claims that it declared v1, and
   ordinary pretty printing does not add a preamble.
4. `Spec`, `validateSpec`, and `wsMergedSpec` remain semantic. Workspaces retain per-member source
   language, accept legacy plus v1, and compare effective versions before graph merge. Source
   locations in version refusals remain member-local and are not run through semantic line
   relocation.
5. The single-file and workspace scaffold records round-trip canonical source-language rows,
   interpret an absent row in an old v1 record as legacy, reject duplicate/malformed known rows,
   and remain readable by the pre-change ignore-unknown behavior. Header-only provenance drift is
   reported without changing generated module bytes or stale ownership.
6. A legacy-to-declared-v1 header-only rewrite emits one compatible provenance finding. Semantic
   `diffSpecs` is empty, aggregate fold surfaces/fingerprints are equal, replay impact is
   `ReplayNeutral`, the finding's remedy says no semantic action is required, and no persisted or
   public compatibility surface is promoted to advisory or breaking.
7. Every ordinary on-disk Keiro fixture, `new <kind>` skeleton, and complete user-facing `.keiro`
   source example declares v1. Grammar fragments remain fragments. Only a checked allowlist of
   source-version compatibility/negative fixtures remains unversioned or declares another token.
   No dependent repository migration is part of this plan.
8. The parser has one released-version registry and an explicit version-specific body-parser
   configuration. The documentation and tests require each later syntax feature to add a successor
   entry and a predecessor rejection fixture; released v1 is never widened as a shortcut.
9. `cabal test keiro-dsl-test`, `cabal build all`, `nix flake check`, and strict ADR validation pass.
   The implementation records actual test counts/output and any environment-qualified Nix result
   in Progress and Surprises & Discoveries.


## Idempotence and Recovery

Parser selection, source rendering, inspection, semantic diffing, and record generation are
deterministic and safe to repeat. Re-running the fixture migration must not add a second preamble;
keep the source-version exception list explicit and have a test reject both missing required
preambles and duplicate ones.

Old scaffold records remain useful: the new reader maps a missing source-language row to
legacy-unversioned while preserving file/module/mapping history, and older readers ignore the new
row. If a malformed known row is encountered, refuse that record rather than guessing declared v1.
No generated or hand-owned file is deleted by this work.

If a successor syntax feature lands concurrently, rebase it onto the registry and assign it a
successor version before merging. Do not recover by adding the new parser branch to v1. If the
fixture rewrite exposes large line-number churn, update expectations from the parser's reported
locations and keep at least one legacy fixture at the old layout; do not weaken location assertions
globally.


## Interfaces and Dependencies

`Keiro.Dsl.LanguageVersion` and the source-level parser/renderer must expose equivalents of the
following; exact constructor names may vary, but the positive-version invariant and semantic/source
separation may not:

```haskell
newtype LanguageVersion = LanguageVersion Natural
-- The constructor is not exported; zero is rejected by the smart constructor/parser.

data SourceLanguage
  = LegacyUnversioned
  | DeclaredLanguage
      { declaredLanguageVersion :: LanguageVersion
      , languageVersionLoc :: Loc
      }

data ParsedSource = ParsedSource
  { parsedSourceLanguage :: SourceLanguage
  , parsedSpec :: Spec
  }

data SourceLanguageErrorCode
  = InvalidLanguageVersion
  | UnsupportedLanguageVersion
  | DuplicateLanguagePreamble
  | MisplacedLanguagePreamble

data ParseFailure
  = SourceLanguageFailure SourceLanguageDiagnostic
  | BodyGrammarFailure Text

effectiveLanguageVersion :: SourceLanguage -> LanguageVersion
supportedLanguageVersions :: NonEmpty LanguageVersion
parseSource :: FilePath -> Text -> Either ParseFailure ParsedSource
parseSpec :: FilePath -> Text -> Either Text Spec
renderSource :: ParsedSource -> Text
renderSpec :: Spec -> Text
```

Internally, one non-empty registry maps each released `LanguageVersion` to its predecessor and
body-parser configuration; `supportedLanguageVersions` is derived from that registry rather than
maintained separately. Version 1 maps to the existing grammar and has no predecessor. The CLI and
workspace loader use `parseSource`; `parseSpec` and `parseSpecText` remain compatibility wrappers
for semantic callers and existing property generators.

Inspection and record JSON use the already-declared `aeson` dependency. `LanguageVersion` uses
`Natural`, and the supported registry uses `NonEmpty`; both are available from existing base
packages. No dependency bounds, pins, or compatibility workarounds change, so this plan requires
no external release selection. Mori was used to confirm the local package identity and dependency
corpus before making that determination.

The source-aware single-file scaffold execution function may be named differently, but it must
take `SourceLanguage` (or `ParsedSource`) in addition to the existing semantic planning inputs.
The current `executeScaffold` signature remains available as a wrapper using
`LegacyUnversioned`; callers that discarded provenance through `parseSpec` cannot later claim an
explicit declaration. Workspace scaffolding needs no compatibility wrapper because
`WorkspaceSpec.wsMembers` retains every member's source language.

This plan provides parser dispatch and provenance only. Sequential source transformations,
workspace-atomic writes, and Mori-aware fleet rewriting remain deferred to IR-5.


Revision note: Detached this plan from the completed structural-consumer-type MasterPlan so it is
an independent implementation unit, 2026-07-31.

Revision note: Validated the plan against the current parser, command tree, workspace composition,
diff/replay surfaces, scaffold records, 211-file fixture corpus, ADRs, and Mori registry on
2026-07-31. Reworked the design around a source wrapper instead of a `Spec` field; made `inspect`
and parse-boundary diagnostics explicit; corrected record, replay, IR-5, documentation, and
fixture-migration claims; and recorded the durable boundary in ADR 16.
