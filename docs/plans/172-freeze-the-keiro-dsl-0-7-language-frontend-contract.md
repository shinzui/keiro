---
id: 172
slug: freeze-the-keiro-dsl-0-7-language-frontend-contract
title: "Freeze the Keiro DSL 0.7 language frontend contract"
kind: exec-plan
created_at: 2026-08-01T19:49:09Z
intention: "intention_01kyzdr07ge299bk2axrgwssht"
master_plan: "docs/masterplans/28-build-a-modular-source-aware-keiro-dsl-language-frontend.md"
---

# Freeze the Keiro DSL 0.7 language frontend contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Before the language frontend is restructured, this plan turns the released `keiro-dsl` 0.7.0.0
behavior into an executable compatibility oracle. A contributor can run one focused test group and
prove that the complete Keiro-owned source corpus still accepts and rejects the same files, that
curated failures still point to the same place with the same code, that canonical rendering and
semantic parsing agree, and that the public parsing functions still compile with their released
types.

This plan begins only after the `keiro-dsl-0.7.0.0` tag exists and Hackage publishes the matching
package. It changes tests and test data, not production parsing behavior. The later child plans in
the parent MasterPlan use this oracle as a non-negotiable gate; they may add cases, but they may not
refresh a failing expectation merely because a refactor changed the language. EP-177 separately
records and intentionally replaces the 0.7 record-selector surface for the next PVP-breaking
release; the parser function signatures and every non-selector observation remain pinned here.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: verify and record the released 0.7.0.0 source, package, and language-contract baseline.
- [ ] Milestone 2: inventory every single-source and workspace frontend path and build the checked compatibility manifest.
- [ ] Milestone 3: add the corpus parity, curated diagnostic, canonical-render, and public-API tests.
- [ ] Milestone 4: run the focused oracle and complete package validation without production behavior changes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: Only the original DSL has downstream users; released language versions 2 and 3 have
  no adopters yet.
  Evidence: Maintainer report on 2026-08-01.
  Impact: The oracle must still freeze all three released contracts, but no v2/v3 downstream fleet
  or source migration needs to be discovered by this baseline plan.


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat the tagged and published 0.7.0.0 package as the sole compatibility authority for
  this refactor.
  Rationale: Comparing a new parser only with its own expectations can conceal drift. A released
  artifact plus checked-in fixtures gives later plans a fixed external reference.
  Date: 2026-08-01

- Decision: Pin every Keiro-owned `.keiro` and `.keiro-workspace` fixture by outcome, but pin exact
  rendered diagnostics only for a curated boundary corpus.
  Rationale: Full outcome coverage catches accidental acceptance/rejection changes without creating
  thousands of brittle error-text snapshots. Exact goldens remain valuable for preambles, feature
  gates, strings, expressions, duplicate clauses, and workspace attribution.
  Date: 2026-08-01

- Decision: Keep production modules unchanged except for any test-only export that can be avoided
  by exercising the existing public API.
  Rationale: The purpose is to measure 0.7, not begin the frontend refactor early.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`keiro-dsl/keiro-dsl.cabal` publishes the library and executable. At the 0.7 baseline the library
depends on Megaparsec and exposes `Keiro.Dsl.Parser`, `Keiro.Dsl.Grammar`,
`Keiro.Dsl.LanguageVersion`, `Keiro.Dsl.PrettyPrint`, `Keiro.Dsl.Validate`, and workspace/tooling
modules. `keiro-dsl/src/Keiro/Dsl/Parser.hs` exposes `parseSource`, `parseSpec`, and
`parseSpecText`. `parseSource` preserves `SourceLanguage` in `ParsedSource`; the two compatibility
wrappers return only `Spec`. `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` exposes `renderSource` and
`renderSpec`.

The main Hspec suite is `keiro-dsl/test/Main.hs`, currently a large test driver covering parsing,
validation, CLI behavior, workspaces, scaffold records, generated-byte freshness, diff, and replay.
Positive, negative, and evolution fixtures live below `keiro-dsl/test/fixtures/`; compiled generated
trees live in directories named `keiro-dsl/test/conformance*`. A “compatibility oracle” in this
plan means checked-in data plus tests that describe the released behavior independently of the
implementation that will replace it.

The inventory must cover distinct entry points, not only file extensions. A `.keiro` file can be
read through library parsing, `keiro-dsl parse`, `check`, `scaffold`, `diff`, `inspect`, and as a
member loaded from a `.keiro-workspace`. A workspace manifest has its own parser, while every member
uses `parseSource`. The oracle records single-source and workspace-member outcomes separately so a
later facade change cannot leave one path behind.

[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires stable
machine codes at the earliest sound gate. [ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
requires deterministic separately parsed workspace members. [ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
freezes released language parsers and keeps source provenance outside `Spec`. These records make
acceptance, source selection, workspace attribution, and semantic equality part of the baseline.
No cross-repository ADR is required. Megaparsec source is registered as
`mori://mrkkrp/megaparsec/packages/megaparsec`, but this plan neither changes nor tests that
dependency directly.


## Plan of Work

Milestone 1 verifies that planning has crossed the release boundary. Confirm the local
`keiro-dsl-0.7.0.0` tag, record its commit in this plan's Surprises & Discoveries section, and fetch
the authoritative Hackage Cabal file to prove its version and dependency metadata match the tag.
Do not start while the tag is missing, while the release worktree contains uncommitted production
changes, or while Hackage still serves no 0.7.0.0 artifact. This milestone changes no files except
the living plan.

Milestone 2 creates `keiro-dsl/test/frontend-0.7/manifest.json` with schema
`keiro-dsl/frontend-compatibility/1`. It records release `0.7.0.0` and every Keiro-owned source or
workspace fixture that is intentionally fed to a frontend entry point. A source row names the
repository-relative path, source form (`legacy-unversioned`, declared 1, 2, or 3), expected result
(`accept` or `reject`), and, for a rejection, its stable source-language or semantic diagnostic code
when one exists. A workspace row names the manifest, expected composition result, and expected
member-attribution code when rejected. Generate an initial sorted inventory with a small test helper,
review it against existing Hspec examples, and check it in; do not leave an auto-update mode in the
ordinary test path.

Add `keiro-dsl/test/Keiro/Dsl/FrontendCompatibility.hs` and list it under `other-modules` in the
`keiro-dsl-test` stanza. The helper decodes the manifest, asserts that no referenced file is missing,
and asserts that every `.keiro`/`.keiro-workspace` fixture used by existing frontend tests appears in
the manifest or in a documented non-source-data allowlist. It invokes existing public library and
workspace functions rather than copying parser logic.

Milestone 3 adds a `frontend 0.7 compatibility` group to `keiro-dsl/test/Main.hs`. For every accept
row, parsing must succeed, canonical rendering must reparse to a `Spec` equal modulo existing `Loc`
semantics, and the declared/effective source contract must match the manifest. For every reject row,
the correct entry point must fail and expose the expected stable code or rendered parse class. The
test also invokes the existing single-member workspace helper for representative accepted versions
and proves it yields the same semantic graph as direct parsing.

Create `keiro-dsl/test/frontend-0.7/diagnostics/` containing exact text goldens for representative
invalid/misplaced/duplicate preambles, one feature gate for each `LanguageFeature`, an escaped-string
failure, numeric overflow, duplicate clause, expression error, and workspace-member parse failure.
The golden names identify the language version and scenario. The focused test compares bytes,
including source name, line, column or historical lack of column, diagnostic code, caret, and
message. Add a compile-time probe module that assigns the 0.7 public functions to explicit type
signatures; this catches an accidental signature change even when call sites infer the new type.
Also capture representative exported 0.7 record selectors as input to EP-177's exhaustive migration
manifest. Those selector probes document the break; they are not required to compile unchanged
after EP-177.

Milestone 4 runs the focused group, the whole Hspec suite, all package builds, and the existing
native repository check. Confirm with `git diff` that no production module under
`keiro-dsl/src/` or `keiro-dsl/app/` changed. Record final test counts and the release tag commit in
the living sections.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro` after the release is complete:

```bash
git show --no-patch --format='%H %s' keiro-dsl-0.7.0.0
curl -fsSL https://hackage.haskell.org/package/keiro-dsl-0.7.0.0/keiro-dsl.cabal
```

The first command prints the immutable tag commit. The second begins with metadata containing:

```text
name:            keiro-dsl
version:         0.7.0.0
```

After authoring the manifest and tests, run:

```bash
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='frontend 0.7 compatibility'
cabal test keiro-dsl-test --test-show-details=direct
cabal build all
nix flake check
git diff -- keiro-dsl/src keiro-dsl/app
```

The focused and full suites exit zero, the build and native flake checks pass, and the final diff is
empty. Update this section with exact observed counts when implemented.


## Validation and Acceptance

Acceptance requires all of the following observable results. The local tag and Hackage artifact
identify the same 0.7.0.0 package. Every checked-in frontend fixture is classified by the manifest,
and every manifest path exists. All accepted sources preserve declared/effective version and
semantic round trip. All rejected sources still reject through their relevant library, CLI, or
workspace path. The curated diagnostic files compare byte-for-byte. The public API type probe
compiles. Existing generated-byte and conformance tests remain green. Production parser and CLI
files have no diff.

The oracle is not accepted if it classifies only filename conventions, silently skips a fixture
whose behavior is hard to run, updates an expected diagnostic without an explanation, or reads
Megaparsec internals. It must exercise the same public boundaries later plans promise to preserve.


## Idempotence and Recovery

All checks and manifest reads are repeatable. The one-time inventory generator may write to a
temporary file or print JSON to stdout for review; it must never overwrite the checked manifest in
the default test command. If inventory review exposes an existing untested or ambiguously named
fixture, add an explicit row or allowlist explanation rather than renaming the fixture in this plan.
If the release tag or Hackage artifact does not exist, stop without editing the baseline and resume
after the release completes.


## Interfaces and Dependencies

No production interface is added. The compile probe must pin these released signatures:

```haskell
parseSource :: FilePath -> Text -> Either ParseFailure ParsedSource
parseSpec :: FilePath -> Text -> Either ParseError Spec
parseSpecText :: Text -> Either ParseError Spec
renderSource :: ParsedSource -> Text
renderSpec :: Spec -> Text
```

Use `aeson` already available to the test suite for the compatibility manifest, Hspec for
assertions, and existing workspace/content-source helpers for manifests. Do not add a package
dependency. The only external verification is the authoritative Hackage artifact; source and API
understanding come from the registered local Megaparsec project
`mori://mrkkrp/megaparsec/packages/megaparsec` and the Keiro source tree.
