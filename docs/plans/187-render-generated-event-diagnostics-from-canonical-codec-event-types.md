---
id: 187
slug: render-generated-event-diagnostics-from-canonical-codec-event-types
title: "Render generated event diagnostics from canonical codec event types"
kind: exec-plan
created_at: 2026-08-03T17:20:45Z
intention: "intention_01kz4a8jz2egz9wfydqbnmr1gk"
---

# Render generated event diagnostics from canonical codec event types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Generated event decoders currently print the accepted event tags as one long
string literal. That literal duplicates the `Codec.eventTypes` allow-list in
the same generated module and makes a long diagnostic difficult to review. At
the end of this plan, each generated aggregate codec has one named
`NonEmpty EventType` value, uses it as the runtime allow-list, and formats the
unknown-event diagnostic from that same value. `NonEmpty` means a list with at
least one item; it matches the existing `Codec` contract that an aggregate owns
at least one event tag.

The observable result is readable generated Haskell such as
`projectEventTypes = EventType "ProjectImported" :| [...]`, followed by
`eventTypes = projectEventTypes` and an unknown-tag branch that renders
`projectEventTypes`. Existing JSON bytes, schema versions, accepted and
rejected values, and diagnostic text remain unchanged. The generator unit
suite demonstrates the single source of truth, an aggregate named `Render`
demonstrates that the new names cannot collide, and the complete Cabal test
corpus compiles and runs every tracked generated codec family.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-08-03 10:08 PDT: audited `Keiro.Codec`, the codec emitter, generated
  fixtures, and the relevant Keiki generic metadata; selected the existing
  wire-tag allow-list instead of constructor reflection or `Enum`/`Bounded`.
- [x] 2026-08-03 10:13 PDT: emitted a named `<aggregate>EventTypes` value,
  reused it in `Codec.eventTypes` and the diagnostic, added focused generator
  assertions, and refreshed 28 tracked generated codecs.
- [x] 2026-08-03 10:20 PDT: ran the 519-example generator suite, representative
  single-event and multi-event conformance suites, and `cabal test all`; all
  passed and the existing event-byte and decoder-acceptance pins stayed true.
- [x] 2026-08-03 10:21 PDT: performed the requested retrospective plan and ADR
  audit, which found that an accepted aggregate named `Render` collides with
  the first implementation's local `renderEventTypes` formatter.
- [x] 2026-08-03 10:24 PDT: renamed the formatter to
  `_renderEventTypes`, added an aggregate-`Render` regression, and passed the
  focused generator test proving the event-list binding and formatter are
  disjoint.
- [x] 2026-08-03 10:32 PDT: refreshed the 28 generated codecs with the
  collision-proof helper, passed the focused regression, the 520-example
  generator suite, representative conformance suites, and `cabal test all`,
  then completed ADR distillation with no ADR change required.
- [x] 2026-08-03 10:42 PDT: diagnosed the failed commit hook as a stale
  nix-direnv development-shell cache: direct `nix fmt` uses the current
  GHC2024-aware wrapper and passes, while the installed hook points to an older
  wrapper without `GHC2024`, `ImportQualifiedPost`, or conformance exclusions.
- [x] 2026-08-03 10:49 PDT: restored the intended postpositive qualified
  import and the two fixtures reformatted by the stale hook, added local
  nix-direnv watches for all imported development-shell modules, refreshed the
  installed hook, and passed both hook checks plus the focused regression.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: event constructors carry payload records, so the generated event
  sum cannot derive `Enum`; `[minBound .. maxBound]` is unavailable even if
  `Bounded` were also requested. `GHC.Generics` can reflect constructor names,
  but those Haskell names are not the codec's durable wire-tag authority.

- Discovery: `Keiro.Codec.Codec.eventTypes` already carries the complete
  non-empty wire-tag set used by `encodeForAppendWithMetadata`,
  `decodeRecorded`, and `decodeRaw`. Reusing that set makes the diagnostic
  follow the runtime contract without runtime type reflection.

- Discovery: a full passing repository test run did not prove collision safety
  for every accepted aggregate identifier. For aggregate `Render`,
  `eventTypesName` produces `renderEventTypes`, which duplicated the first
  implementation's fixed formatter binding. This would be a generated-code
  compile failure, not wire corruption, and must be covered directly.

- Discovery: the first broad fixture-refresh loop encountered the opt-in
  structural codec-comparison module, which ordinary scaffolding does not
  emit. Refreshing only tracked paths ending in `/Codec.hs` is the correct
  idempotent scope for this event-codec-only change.

- Discovery: the failed pre-commit run did not use the formatter declared by
  the current flake. The installed `.pre-commit-config.yaml` points to the
  `igi3f55...-treefmt` wrapper and excludes nothing, while fresh flake
  evaluation produces the distinct `z0r9rl...-treefmt` wrapper. The stale
  invocation reported only `BangPatterns`, `PatternSynonyms`, and
  `TypeApplications`; `nix fmt keiro-dsl/test/Main.hs` with the current wrapper
  accepts postpositive qualified imports with zero changes.

- Discovery: nix-direnv automatically watches `.envrc`, `flake.nix`, and
  `flake.lock`, but not the imported `nix/treefmt.nix` or
  `nix/pre-commit.nix` files. This checkout's cached shell hook still expects
  the old `0i60ajj...-pre-commit-config.json`; fresh `nix print-dev-env`
  expects `m4i03qp...-pre-commit-config.json`. The formatter and hook changes
  committed on 2026-08-02 therefore did not invalidate the cached shell.


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat the generated `NonEmpty EventType` value as the canonical
  source for both `Codec.eventTypes` and the expected-tag diagnostic.
  Rationale: wire tags are protocol data and may eventually differ from
  Haskell constructor names; the `Codec` allow-list already owns this runtime
  contract. This also avoids impossible `Enum` derivation for payload-bearing
  constructors and unnecessary generic reflection.
  Date: 2026-08-03.

- Decision: Keep the formatter private to each generated codec as
  `_renderEventTypes`, rather than add a public helper to `keiro-core`.
  Rationale: underscore-leading aggregate names are rejected by identifier
  validation, while aggregate-derived value names always start from an
  accepted PascalCase aggregate name. The leading underscore therefore gives
  the helper a disjoint generator-private namespace. Imported record selectors
  may be shadowed safely, and the helper is not a new public API.
  Date: 2026-08-03.

- Decision: Preserve the exact diagnostic text and tag order.
  Rationale: diagnostics are not persisted wire format, but byte stability
  avoids needless consumer-test churn and makes this a readability-only
  refactor. `NonEmpty.toList` preserves declaration order and
  `T.intercalate ", "` reproduces the old comma-separated suffix.
  Date: 2026-08-03.

- Decision: Do not create or amend an ADR for the private helper name.
  Rationale: this plan follows the existing generated-language and evidence
  boundaries; it does not change a shared interface, wire contract, or durable
  architectural constraint. The relevant durable decisions already live in
  ADR 0004 and ADR 0019.
  Date: 2026-08-03.

- Decision: Preserve postpositive qualified imports and treat the failure as
  development-environment cache invalidation, not generated-Haskell syntax.
  Rationale: postpositive qualified is the repository standard, the current
  treefmt configuration explicitly enables `GHC2024` and
  `ImportQualifiedPost`, and the current wrapper formats the touched source
  successfully. Changing generated source to accommodate an obsolete installed
  hook would violate the intended language and formatting contract.
  Date: 2026-08-03.

- Decision: Make this checkout's ignored `.envrc` watch `nix/haskell.nix`,
  `nix/treefmt.nix`, and `nix/pre-commit.nix` before `use flake`.
  Rationale: nix-direnv otherwise watches only the flake entry points and can
  retain an obsolete hook after an imported module changes. Keeping the repair
  local preserves the repository's existing decision to ignore `.envrc` while
  preventing recurrence in this checkout.
  Date: 2026-08-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The completed implementation gives every generated aggregate codec one
canonical event-tag list, reuses it for runtime validation and the unknown-tag
diagnostic, and preserves the exact error text and declaration order. The
`Render`-aggregate regression proves the `_renderEventTypes` private helper
cannot collide with the aggregate-derived list name. All 28 tracked aggregate
codecs were refreshed; the 520-example generator suite, representative
single-event and multi-event conformance suites, extension-policy check, and
complete Cabal test corpus passed. The canonical reservation evidence still
reported `event bytes pinned: True` and `event decoder acceptance/rejection
pinned: True`.

ADR distillation reviewed every decision and discovery against ADR 0004 and
ADR 0019. No ADR was created or amended because this is a task-local generated
binding convention, not a new public interface, wire contract, or durable
architectural constraint. The important lesson is that compiling the committed
generated corpus is necessary but not sufficient for a code generator:
accepted source identifiers that are absent from fixtures need direct hygiene
tests when new generated bindings are introduced.

The obsolete installed hook was repaired without changing the repository's
postpositive qualified convention. The local `.envrc` now watches every
imported development-shell module, `nix-direnv-reload` installed the exact
pre-commit configuration produced by fresh flake evaluation, and the failed
hook's two fixture rewrites were removed. The refreshed hook passed both the
global extension policy and treefmt; the focused `Render` regression passed
again with one example and zero failures. The repair is local because `.envrc`
is intentionally ignored, while the generated-code and ExecPlan changes remain
the only tracked work in this commit. ADR distillation found no new
architectural decision: ADR 0019 already owns the postpositive generated
Haskell contract, and nix-direnv cache invalidation is checkout-local
operational configuration.


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` converts a checked `.keiro` aggregate
into generated Haskell. Its `emitCodec` function assembles a codec module,
`emitCodecValue` creates the `Codec` record, and `emitDecode` emits the
event-tag case expression. An `Agg` is the emitter's resolved aggregate
description; each resolved event in `aEvents` carries the constructor and wire
tag name through `rcName`.

`keiro-core/src/Keiro/Codec.hs` defines `Codec e`. Its `eventTypes` field is a
`NonEmpty EventType`, and runtime append and decode functions reject tags not
in that field. `EventType` is imported from Kiroku and wraps `Text`. The
generated decoder is also public, so it retains its own unknown-tag branch for
callers that invoke `parse<Aggregate>Event` directly rather than `decodeRaw`.

`keiro-dsl/test/Main.hs` is the generator's Hspec suite. The aggregate-scalar
group already builds generated modules in memory and is the focused location
for assertions about the named event set. It must also generate an aggregate
named `Render`, because `lowerFirst "Render" <> "EventTypes"` is exactly
`renderEventTypes`, the collision missed by ordinary fixtures.

Tracked examples live below `keiro-dsl/test/conformance*/Generated/`. These
files are overwriteable evidence, not hand-owned source. The authoritative
source-to-output mapping is
`keiro-dsl/test/conformance-baseline.json`; built-in skeleton outputs live in
`keiro-dsl/test/conformance-skeletons/`. Only aggregate files whose path ends
in `/Codec.hs` change under this plan.

This work is a small follow-up to the diagnostic milestone in
[ExecPlan 182](182-ship-closed-named-and-diagnosable-generated-runtime-apis-in-keiro-0-9.md),
which established that unknown decoder failures name the rejected value and
complete expected set while preserving accepted and rejected outcomes.
[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires codec changes to be proved at the earliest available boundary and
then defended by runtime/conformance tests; it also states that tools depend on
machine codes rather than human diagnostic prose. [ADR
0019](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
requires the complete generated corpus to compile under GHC2024 plus
`OverloadedStrings` and a closed local-extension set. This plan adds no
extension and does not change those durable decisions. Mori was used to
inspect the registered Keiki and Mina sources; no cross-repository ADR is
needed.


## Plan of Work

Milestone 1 establishes one event-tag authority in generated code. In
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, emit a private
`<lowerFirst aggregateName>EventTypes :: NonEmpty EventType` binding before the
codec record. Assign that binding to the record's `eventTypes` field. Change
only the event decoder's fallback to render the expected suffix from the named
binding. Leave enum, nominal, union, and message-type diagnostics alone because
they do not have a `Codec.eventTypes` authority. The milestone is observable
when generated output contains the named binding once and no longer contains a
literal event-name suffix in the unknown-event branch.

Milestone 2 makes the new generated namespace total. Name the formatter
`_renderEventTypes :: NonEmpty EventType -> String` and have it convert the
`NonEmpty` value to a list, unwrap each `EventType`, join names with comma-space,
and unpack the resulting `Text`. The leading underscore is essential: the
validator rejects underscore-leading aggregate names, so an accepted aggregate
cannot generate the same top-level name. In `keiro-dsl/test/Main.hs`, mutate
the stable aggregate-scalar fixture's aggregate name to `Render`, generate its
codec, and assert that `renderEventTypes :: NonEmpty EventType` is the list
binding while `_renderEventTypes` is the formatter and is used by the error
branch. This milestone passes when the focused Hspec example proves both
bindings occur exactly once.

Milestone 3 refreshes evidence and closes validation. Regenerate only tracked
aggregate `/Codec.hs` files from every source-backed component in
`keiro-dsl/test/conformance-baseline.json`, then regenerate the built-in
skeleton aggregate/process/router codecs. Run formatter checks, the focused
generator test, the full generator suite, representative diagnostic
conformance, and `cabal test all`. Acceptance requires no hard-coded event-name
suffix, no changed wire bytes or acceptance outcomes, zero failures, and no
diff outside the generator, generator test, plan, and tracked Generated codec
files.

Milestone 4 closes the development-environment gap exposed by the commit hook.
Restore the postpositive `import Data.List.NonEmpty qualified as NonEmpty`
emission and regenerate or restore only the two fixture files changed by the
obsolete hook. Refresh nix-direnv from the current flake so the installed
pre-commit configuration contains the current treefmt wrapper, the
`extension-policy` hook, and the conformance exclusion. Run the hook against
the staged paths and repeat the final source checks before committing. A
durable follow-up may add explicit `watch_file` entries for the imported Nix
modules so future changes invalidate nix-direnv automatically. Because
`.envrc` is ignored, this is a checkout-local repair separate from the tracked
generated-code behavior in this plan.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/keiro`.

Inspect the generator and runtime authority:

```bash
rg -n 'emitCodecValue|emitDecode|eventTypes' \
  keiro-dsl/src/Keiro/Dsl/Scaffold.hs \
  keiro-core/src/Keiro/Codec.hs
```

Run the focused generator proof after editing:

```bash
cabal test keiro-dsl-test --test-show-details=direct \
  --test-option=--match \
  --test-option='keeps the event-list binding disjoint'
```

Expected focused output is:

```text
aggregate type capabilities
  keeps the event-list binding disjoint from the private formatter [✔]

1 example, 0 failures
```

Refresh source-backed codec evidence through a temporary directory. Use the
same baseline loop already documented in this repository, but select only
tracked paths matching `/Generated/.*/Codec.hs`; do not copy structural
`CodecCompare` modules or hand-owned files. Repeat the built-in skeleton loop
for only the same `/Codec.hs` suffix. Re-running either loop is safe because
the generator is deterministic and overwriteable Generated files are its owned
output.

Format and validate:

```bash
nix fmt keiro-dsl/src/Keiro/Dsl/Scaffold.hs keiro-dsl/test/Main.hs \
  docs/plans/187-render-generated-event-diagnostics-from-canonical-codec-event-types.md
just extension-policy
cabal test keiro-dsl-test --test-show-details=direct
cabal test keiro-dsl-conformance-aggregate-scalars \
  keiro-dsl-conformance-behavior-complete --test-show-details=direct
cabal test all --test-show-details=direct
git diff --check
```

The pre-collision-fix audit already produced `519 examples, 0 failures` for the
generator suite, passed both representative conformance suites, and exited zero
from `cabal test all`. Repeat those commands after the fix because the helper
name appears in every regenerated aggregate codec.

Before the final commit, compare the installed environment with fresh flake
evaluation:

```bash
direnv allow .
nix-direnv-reload
readlink .pre-commit-config.yaml
nix print-dev-env .#default | rg 'pre-commit-config.json'
nix fmt keiro-dsl/test/Main.hs
```

The first two commands must name the same generated configuration after the
development shell is refreshed. The formatter command must finish with
`formatted 0 files (0 changed)` while `Main.hs` retains postpositive qualified
imports.


## Validation and Acceptance

Acceptance has five observable parts. First, a generated multi-event codec has
one named `NonEmpty EventType` value, the `Codec` record refers to it, and the
unknown-event branch calls `_renderEventTypes` on it. Second, an aggregate
named `Render` generates both `renderEventTypes` (the list) and
`_renderEventTypes` (the formatter) without duplicate declarations. Third,
passing an unknown tag still reports exactly `unknown event type "<tag>";
expected one of: <declaration-order tags>`. Fourth, the canonical reservation
conformance still prints `event bytes pinned: True` and `event decoder
acceptance/rejection pinned: True`. Fifth, `cabal test all` exits zero while
compiling all regenerated codecs under ADR 0019's advertised language contract.

The focused source checks are:

```bash
rg -n 'unknown event type.*expected one of: [A-Z]' \
  keiro-dsl/test --glob '**/Generated/**/Codec.hs'
rg -n '_renderEventTypes .*EventTypes' \
  keiro-dsl/test --glob '**/Generated/**/Codec.hs'
```

The first command must print nothing. The second must name every tracked
aggregate codec refreshed by this plan.


## Idempotence and Recovery

Generator and test edits are ordinary additive Haskell changes and can be
reapplied safely with `apply_patch`. Fixture refreshes write first to a unique
`mktemp -d` directory and copy only paths already tracked by Git; a failed
scaffold therefore cannot partially replace the committed tree. If a refresh
fails, retain the temporary directory for diagnosis, correct the generator, and
rerun the complete loop. Do not delete or restore the entire dirty tree: use
`git diff -- <specific path>` to inspect unexpected changes and regenerate the
specific owned codec again. No database, network service, persisted event, or
schema migration is touched.


## Interfaces and Dependencies

No new package dependency or public runtime interface is introduced.
`keiro-core/src/Keiro/Codec.hs` continues to expose the existing field:

```haskell
eventTypes :: NonEmpty EventType
```

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` gains generator-internal helpers with
these effective interfaces:

```haskell
emitEventTypes :: Agg -> Text
eventTypesName :: Agg -> Text
renderUnknownEventTypeFailure :: Agg -> Text -> Text
```

Each generated aggregate codec contains private declarations shaped as:

```haskell
projectEventTypes :: NonEmpty EventType

_renderEventTypes :: NonEmpty EventType -> String
```

`Data.List.NonEmpty.toList` preserves tag order. `Data.Text.intercalate` and
`Data.Text.unpack` reproduce the existing `String` expected by Aeson's
`Parser.fail`. `EventType (..)` remains the only required event-tag interface;
no constructor-reflection API from Keiki or `GHC.Generics` participates.


## Revision Note

2026-08-03: Completed the implementation and safety audit. The revision records
the formatter-name collision found after the initial passing test run, the
collision-proof `_renderEventTypes` design, the direct `Render` regression,
the refreshed 28-codec evidence, the final validation results, and the outcome
of ADR distillation.

2026-08-03: Reopened final validation after the commit hook failed. Investigation
proved that nix-direnv had retained a pre-2026-08-02 hook configuration because
the imported Nix modules were not watched. The plan now preserves postpositive
qualified syntax, distinguishes current `nix fmt` success from the stale hook,
and records hook refresh and cleanup as the remaining work.

2026-08-03: Completed the checkout-local repair. The ignored `.envrc` now
watches all imported development-shell modules, the installed pre-commit
configuration matches fresh flake evaluation, accidental hook rewrites were
removed, and both refreshed hook checks and the focused generator regression
pass.
