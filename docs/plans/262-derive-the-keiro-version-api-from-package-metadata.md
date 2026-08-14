---
id: 262
slug: derive-the-keiro-version-api-from-package-metadata
title: "Derive the Keiro version API from package metadata"
kind: exec-plan
created_at: 2026-08-14T13:33:20Z
intention: "intention_01m0075g1kecjb2959gy704yhc"
master_plan: "docs/masterplans/42-fix-the-final-keiro-release-blockers-and-publish-stable-language-5.md"
---

# Derive the Keiro version API from package metadata

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, `Keiro.version` always reports the version Cabal assigned to the `keiro`
package. Telemetry, diagnostics, and user displays can trust it without a second literal being
updated during every release. At the current tree it must report 0.11.0.0; when EP-5 changes
`keiro/keiro.cabal` to the confirmed release version, the public value and focused test change
automatically.

The proof is a focused `Keiro` test that compares the public `Text` with Cabal's generated
`Paths_keiro.version`, plus EP-5's version-bump run demonstrating that no Haskell source edit is
needed.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: register Cabal's generated `Paths_keiro` module in the library and test components
- [ ] M1: render `Keiro.version` from `Paths_keiro.version` and remove the stale literal
- [ ] M2: make the focused test compare the public value with authoritative package metadata
- [ ] M2: add a regression guard against reintroducing a hand-maintained version literal
- [ ] M3: update the unreleased Keiro changelog and pass focused, package, and full repository gates


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `keiro/keiro.cabal` reports 0.11.0.0, while `Keiro.version` and its test both report
  0.4.0.0. The test is green because it repeats the defect instead of consulting metadata.
- The repository already has the correct local pattern: `keiro-dsl` imports
  `Paths_keiro_dsl` and renders `Package.version` with `Data.Version.showVersion` for generated
  banners. This plan reuses that pattern and adds no dependency.


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep the public `version :: Text` API and derive its value from
  `Paths_keiro.version`.
  Rationale: Consumers retain source compatibility while Cabal becomes the sole package-version
  authority. A second exposed `Version` value is unnecessary for the release blocker.
  Date: 2026-08-14
- Decision: Test metadata equality and source ownership, not a numeric release literal.
  Rationale: A literal comparison only catches drift after someone remembers to update one side;
  the test must remain valid across every future version bump.
  Date: 2026-08-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`keiro/src/Keiro.hs` is the umbrella module. It exports `version :: Text` for display and
telemetry and currently defines it as the literal `"0.4.0.0"`. Its Haddock says to keep that
literal in lockstep with `keiro/keiro.cabal`. The package manifest currently says 0.11.0.0.
`keiro/test/Main.hs`, under `describe "Keiro"`, expects the same stale literal, so the focused
test passes while public package identity is wrong. [REV-5](../reviews/keiro-version-api.md)
records this release blocker.

Cabal generates a module named `Paths_<package>` for each component. Its `version` value has
type `Data.Version.Version` and reflects the package's `version:` field. The local precedent is
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, which imports `Paths_keiro_dsl qualified as Package` and
uses `Data.Version.showVersion Package.version`. `keiro-dsl/keiro-dsl.cabal` lists that generated
module in `autogen-modules` for the library and test suite.

No local ADR governs package-version rendering, and this change does not establish an
architecture boundary that needs one. It is a direct removal of duplicate metadata. No
cross-repository ADR or dependency API is involved.


## Plan of Work

Milestone 1 makes Cabal authoritative. In the library stanza of `keiro/keiro.cabal`, register
`Paths_keiro` under `autogen-modules`, following the `keiro-dsl` pattern. In
`keiro/src/Keiro.hs`, import `Data.Text` qualified, `Data.Version.showVersion`, and
`Paths_keiro` qualified as `Package`; define `version` by packing `showVersion Package.version`.
Rewrite the Haddock to say the value comes from package metadata and delete the lockstep-edit
instruction. This milestone is complete when a build reports 0.11.0.0 without a numeric version
literal in `Keiro.hs`.

Milestone 2 repairs the test. Register `Paths_keiro` for the `keiro-test` stanza as required by
Cabal, import it qualified, and compare `KeiroRoot.version` with the rendered generated value.
Add a small source-ownership assertion using the repository's existing source-reading test
pattern, or an equivalently robust policy check, that confirms `Keiro.hs` refers to
`Package.version` and contains no four-component numeric assignment to `version`. The policy
test is not the value authority; it prevents someone from replacing the derivation with the
currently matching literal and leaving a temporarily green metadata-equality test.

Milestone 3 adds a `Bug Fixes` entry under `Unreleased` in `keiro/CHANGELOG.md`, then runs the
focused test, all Keiro tests, the workspace build, and `just verify`. Record the current
0.11.0.0 proof in this plan. EP-5 later records the second proof after changing only package
metadata to 0.12.0.0.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Preserve the defective baseline:

```bash
rg -n '^version:' keiro/keiro.cabal
rg -n 'version =|exposes the scaffold version' keiro/src/Keiro.hs keiro/test/Main.hs
cabal test keiro-test --test-options='--match "exposes the scaffold version"'
```

The first two commands show 0.11.0.0 in metadata and 0.4.0.0 in both Haskell files, while the
test passes.

After Milestones 1 and 2, run:

```bash
cabal build keiro:lib:keiro keiro:test:keiro-test
cabal test keiro-test --test-options='--match "Keiro"'
```

The focused result must prove:

```text
Keiro
  exposes the package metadata version
```

Confirm there is one numeric authority:

```bash
rg -n '0\.4\.0\.0|version[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' keiro/src keiro/test
rg -n '^version:' keiro/keiro.cabal
```

The first command returns no live literal assignment; the second returns the authoritative Cabal
field. Finish with:

```bash
cabal test keiro-test
just verify
```


## Validation and Acceptance

At the end of this plan, `Keiro.version` equals `Text.pack (showVersion
Paths_keiro.version)` and therefore prints 0.11.0.0 in the current working tree. The umbrella
module contains no hard-coded PVP version and its Haddock names Cabal metadata as the authority.
The focused test imports the generated module rather than expecting a number.

Changing only a temporary copy of `keiro/keiro.cabal`'s version and rebuilding must change
`Keiro.version`; do not commit that temporary probe. EP-5 supplies the durable 0.12.0.0 version
of the same proof. `cabal test keiro-test` and `just verify` pass, with no user-visible API type
change.


## Idempotence and Recovery

All edits are ordinary and repeatable. Cabal regenerates `Paths_keiro` during each build; never
create or commit that module by hand. If a stale `dist-newstyle` artifact appears to mask the
metadata change, rerun the named component build or use Cabal's normal rebuild behavior; do not
edit generated files.

Any temporary metadata probe must restore the exact original Cabal line before continuing. The
real version change belongs exclusively to EP-5.


## Interfaces and Dependencies

The public interface remains:

```haskell
module Keiro (version, ...) where

version :: Text
version = Text.pack (showVersion Package.version)
```

`Package.version` is `Paths_keiro.version :: Data.Version.Version`. Use only `base`'s
`Data.Version` and the already-declared `text` dependency. Add `Paths_keiro` to the relevant
`autogen-modules`/component inventory exactly as Cabal requires; do not expose the generated
module as a Keiro API.

EP-5 owns the subsequent `version:` edit and must verify that this implementation follows it
without touching `keiro/src/Keiro.hs` or replacing the metadata-based test.
