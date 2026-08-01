---
id: 171
slug: enforce-versioned-id-prefix-domains-across-construction-decode-replay-and-evolution
title: "Enforce versioned ID prefix domains across construction decode replay and evolution"
kind: exec-plan
created_at: 2026-08-01T00:15:25Z
intention: "intention_01kyxarnbbet3ajn0995gt65w9"
master_plan: "docs/masterplans/27-repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions.md"
---

# Enforce versioned ID prefix domains across construction decode replay and evolution

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a prefix-bearing generated ID in the successor Keiro language is a real runtime
domain. Public construction and new-command decoding reject wrong prefixes, empty suffixes,
malformed separators, normalization violations, and overlong values with field-located errors.
Generated constructors cannot create an invalid current ID.

Historical version-1/version-2 events keep their documented readability. Replay uses an explicit
legacy decoder/upcast path, while the same malformed bytes are rejected at the new-command
boundary. Diff and upgrade reports explain whether a prefix change affects command admission,
events, snapshots, replay, or public codecs instead of silently tightening an old decoder.
Keiki `0.7.0.0` supplies the exact full-string textual projection-domain algebra used to prove the
same contract symbolically; Keiro remains the authority for runtime admission and replay policy.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: freeze the successor ID-domain contract from authoritative TypeID APIs, verify
  its Keiki 0.7 exact textual projection, and register the new language semantic through Plan
  169's checked service contract.
- [ ] Milestone 2: generate hidden-representation IDs, safe constructors, and boundary-specific
  public/current versus legacy replay codecs for generated and consumer-bound ownership.
- [ ] Milestone 3: integrate legacy upcast/replay, snapshots, literals, fixtures, fingerprints,
  diffs, upgrade reports, and scaffold adoption.
- [ ] Milestone 4: add property, migration, mutation, workspace, documentation, ADR, and full
  release validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-01: `Keiro.Dsl.Scaffold.emitId` currently emits `newtype X = X Text` with a public
  constructor and derives generic snapshot `FromJSON`. Generated event decoding constructs the
  wrapper with `X <$> o .: field`, so the declared prefix is not enforced. Consumer-bound IDs take
  a different path through `Data.KindID.parseText` and do enforce it.
- 2026-08-01: prefix changes already participate in declaration validation, ID literals,
  fingerprints, and `IdPrefixChanged` diff findings. Tightening the generated decoder without a new
  effective language contract would therefore change replay behavior behind metadata that already
  appeared authoritative.
- 2026-08-01: Keiki public `master` exposes validated full-string `TextPattern` domains plus exact
  projection/reconstruction evidence. Hackage now publishes those APIs as `0.7.0.0`, and
  `v0.7.0.0` resolves to release commit `7c5d433ef4455e9e626347f89cb3a416bad62e72`.
  That is the authoritative symbolic domain surface required here and by Plan 170.


## Decision Log

Record every decision made while working on the plan.

- Decision: Enforce generated ID domains only under a new effective language contract; version 1
  and version 2 retain their released unchecked generated decoder semantics.
  Rationale: persisted events may contain text accepted by those releases. A patch-level decoder
  tightening would turn a source-compatible upgrade into an undeclared replay break.
  Date: 2026-08-01

- Decision: Expose smart constructors and boundary-specific codec functions, not a public raw
  constructor or one general `FromJSON` instance used everywhere.
  Rationale: command admission and historical replay have different policies. A context-free
  instance cannot know whether accepting legacy bytes is allowed and would leak the unsafe path to
  application code.
  Date: 2026-08-01

- Decision: Permit legacy invalid text only through an explicitly named generated internal replay
  constructor/upcaster; keep it out of public/domain module exports.
  Rationale: IR-14 requires old logs to remain readable and allows an explicitly unsafe internal
  API. Naming and isolating that seam prevents new commands from manufacturing historical debt
  while preserving deterministic replay.
  Date: 2026-08-01

- Decision: Derive generated and consumer-bound validation from one checked `IdDomainContract` and
  include its version in all evolution surfaces.
  Rationale: binding mode must not change the meaning of the same declaration, and dependency
  library behavior must not drift invisibly across releases.
  Date: 2026-08-01

- Decision: Map the checked `IdDomainContract` to Keiki 0.7's exact `TextPattern` projection domain,
  but keep construction, decode, and legacy replay policy in Keiro.
  Rationale: Keiki now provides the exact solver image and reconstructible witnesses needed for
  nominal equality, while only Keiro's effective language contract knows whether a concrete value
  is new admission or historical replay. Hackage and `v0.7.0.0` now publish that API
  authoritatively, so this plan adopts `>=0.7 && <0.8` once Plans 168 and 169 satisfy its local hard
  dependencies.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(Implementation not started. The Keiki `0.7.0.0` symbolic-domain prerequisite is authoritatively
released; Plans 168 and 169 remain the local hard dependencies.)


## Context and Orientation

The owning request is
[IR-14](../improvement-requests/make-id-prefix-declarations-enforceable-and-evolution-safe.md).
Plan 169 is a hard dependency: without its `CheckedService` effective contract, generated code
cannot distinguish legacy/v2 semantics from the successor. Plan 168 owns the single shared module
where generated IDs and their constructors live. Plan 170 consumes the ID domain as an exact
symbolic equality domain but does not define validation policy.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` stores `idPrefix`. `NominalType.hs` resolves it into
`IdRepresentation`. `Validate.hs` detects duplicate/invalid binding prefixes, and `Expression.hs`
checks ID literals. `Scaffold.hs` emits raw generated newtypes, event codecs, snapshots, literals,
and harness samples. `FoldFingerprint.hs`, `Diff.hs`, `ReplayImpact.hs`, scaffold records, and
workspace reports already carry parts of prefix provenance and must be unified around the new
domain version.

Consumer-bound IDs use the `mmzk-typeid` package through `Data.KindID`. Before implementation, use
Mori to locate its source and independently verify its current Hackage version and upstream tag.
Read `checkPrefix`, `parseText`, `toText`, separator/suffix rules, and size behavior directly; do not
copy assumptions from memory. If its public contract is insufficiently explicit, Keiro must freeze
and test its own `IdDomainContract` rather than inherit undocumented behavior.

The symbolic dependency is `mori://shinzui/keiki/packages/keiki`. Public `master` implements the
exact domain/reconstruction capability from
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-4`. Keiro-side modeling may begin against
released `0.7.0.0`; after Plans 168 and 169, reverify Hackage and `v0.7.0.0`, then adopt
`>=0.7 && <0.8`.

[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) is amended by
Plan 169 so runtime semantics can depend on the effective contract. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
governs admission/replay/diff boundaries. [ADR 3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md)
requires changed fold/codec semantics to invalidate rebuildable snapshots. ADR 12 requires one
schema/binding authority.


## Plan of Work

Milestone 1 freezes `IdDomainContract`. Record separator spelling, prefix grammar, non-empty suffix,
allowed characters, case/normalization, maximum encoded length, JSON representation, and stable
contract version. Express the same accepted textual set through Keiki 0.7's full-string
`TextPattern` domain and add concrete agreement/reconstruction probes. Add the successor version to
`LanguageVersion.hs` and make the Plan 169 semantic planner choose enforced versus legacy ID
policy. The source syntax may remain `id X prefix=p`; the same syntax receives different runtime
semantics only because the document explicitly selects the new version. Verify Hackage and the
matching upstream tag, then change Keiro's dependency bound to `>=0.7 && <0.8`.

Milestone 2 changes generated ownership. In the Plan 168 shared nominal module, emit a hidden raw
representation, `parseX`, `mkX` or equivalent safe constructors, `xText`, and public JSON helpers
that validate. Do not export the raw constructor. Generate a separately named internal legacy
constructor/decoder used only by event replay/upcast and legacy snapshot paths. Consumer-bound IDs
must pass the same conformance contract: their total `NominalBinding` representation and fixtures
must agree with prefix validation, and the harness must reject a binding that accepts a wrong
prefix or normalizes two inputs to one identity.

Milestone 3 threads boundary policy. New commands, public decoders, literals, Dhall/scaffold
samples, and current event encoders use the safe contract. Historical v1/v2 event decoders and
explicit upcasters may construct a legacy internal value so replay remains deterministic. Define
whether snapshots containing legacy values decode or are invalidated and rebuilt; follow ADR 3 and
record the chosen surface. Extend fold fingerprints, scaffold records, diffs, replay impact, and
upgrade output to classify contract adoption/removal/change separately for commands, events,
snapshots, replay, and public codecs.

Milestone 4 proves both directions with properties and a migration fixture. Generate valid IDs and
malformed/wrong-prefix/empty/overlong/non-normalized text. Assert no safe constructor or public
decoder admits an invalid value. Seed a legacy v2 event containing an invalid current ID, upgrade
the source, replay it successfully through the documented legacy path, then submit the identical
text as a new command and observe a field-located rejection. Add generated/consumer parity,
workspace single-owner, equality-domain, mutation, and codec golden tests. Update language,
migration, replay, authoring, changelog, and ADR documentation.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
mori registry search mmzk-typeid
mori registry show MMZK1526/mmzk-typeid --full
curl -fsSL https://hackage.haskell.org/package/mmzk-typeid/preferred.json
git ls-remote --tags https://github.com/MMZK1526/mmzk-typeid.git
mori registry show shinzui/keiki --full
curl -fsSL https://hackage.haskell.org/package/keiki/preferred.json
git ls-remote --tags https://github.com/shinzui/keiki.git
cabal test keiro-dsl-test --test-option=--match --test-option='ID domain'
cabal test keiro-dsl-conformance-id-domain-migration
cabal test keiro-dsl-test
cabal build all
nix flake check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Record the authoritative dependency version/tag and the frozen domain vector in Progress. The
migration conformance target must show successful legacy replay and rejected new admission for the
same malformed text.


## Validation and Acceptance

Acceptance requires current public construction and command decoding to reject every invalid domain
case at the owning field. Generated constructors cannot bypass validation. Generated and
consumer-bound IDs behave identically. Version-1/version-2 fixtures retain their old decode policy.
A successor migration fixture replays an invalid legacy value but rejects it as new input. Prefix
contract evolution is visible across every affected compatibility surface, and differently
declared IDs remain type-distinct even when suffixes match.


## Idempotence and Recovery

Do not mutate existing event fixtures in place; add versioned migration fixtures and preserve their
bytes. Generate into temporary output until safe/public and legacy/internal imports are proven.
All upcasts and reports must be deterministic. If legacy replay cannot be represented without
exporting an unsafe constructor, stop and revise the boundary rather than weakening the public
type.


## Interfaces and Dependencies

The checked contract should be equivalent to:

```haskell
data IdDomainContract = IdDomainContract
  { idDomainVersion :: Text
  , idDomainPrefix :: Text
  , idDomainSeparator :: Char
  , idDomainMaxLength :: Int
  , idDomainNormalization :: IdNormalization
  }

data IdBoundary = NewAdmission | PublicDecode | HistoricalReplay
```

Generated modules expose safe parsing/rendering and keep any
`unsafeXFromLegacyText :: Text -> X` function internal to generated codec/upcast modules. Plan 170
maps `IdDomainContract` to Keiki 0.7's exact textual projection domain. No ordinary `FromJSON X`
instance may silently choose between public and historical policy.


Revision note: Added released Keiki `0.7.0.0` as the exact textual-domain integration baseline,
verified through Hackage and the matching `v0.7.0.0` tag. After Plans 168 and 169, this plan can
adopt `>=0.7 && <0.8`; no external Keiki blocker remains, 2026-08-01.
