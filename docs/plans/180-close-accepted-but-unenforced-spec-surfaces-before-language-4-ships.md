---
id: 180
slug: close-accepted-but-unenforced-spec-surfaces-before-language-4-ships
title: "Close accepted-but-unenforced spec surfaces before language 4 ships"
kind: exec-plan
created_at: 2026-08-02T04:56:03Z
intention: "intention_01kz0d7wh0e5d896gjc15379pf"
---

# Close accepted-but-unenforced spec surfaces before language 4 ships

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl check` is the admission gate for a `.keiro` service specification, and
[ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
freezes the meaning of every released language version.  That freeze cuts both
ways: every spec `check` accepts today becomes permanently accepted behavior once
the language that admitted it ships.  A 2026-08-01 audit of the frontend found a
family of surfaces the parser accepts and stores that no validator or generator
enforces — the same defect class ExecPlan 178 just fixed for contract
`typeid` prefixes.  Some of these specs generate Haskell that does not compile;
some produce a service that rejects every command at runtime; some silently
ignore a policy the author declared.

Language version 4 is registered (commit `3e1217c`) but unreleased: `0.8.0.0`
shipped versions 1 through 3, and version 4 first reaches users in the planned
`0.9.0.0` release.  This is the one window in which these holes can be closed
without minting a language version 5 and without migrating any consumer.  After
this change, a spec that names an unknown publisher ordering, declares two
identical live transitions, binds an intake field that does not exist, or reuses
a workflow's stable name fails `keiro-dsl check` with a named diagnostic and a
source location — instead of failing later at GHC, failing forever at runtime,
or never failing at all.

The observable outcome: for each closed hole there is a fixture spec that passed
`check` before this plan and now fails with a specific stable diagnostic code,
while every existing conformance fixture and released-language regression
continues to pass unchanged.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: enforcement-tier framework, closed policy vocabularies, and
  numeric floors.
- [ ] Milestone 2: duplicate and collision detection across declarations.
- [ ] Milestone 3: stable-identity and external-name constraints.
- [ ] Milestone 4: language-4 semantic couplings for the intake envelope,
  contract topology, and wire clause.
- [ ] Milestone 5: dead-grammar removal, negative-test coverage for previously
  untested diagnostics, documentation, and ADR amendments.
- [x] (2026-08-02 06:42Z) Revalidated the plan against the post-ExecPlan-178
  tree, the released-package registry and tags, the current runtime policy
  constructors, validator helpers, generated-code paths, and relevant ADRs;
  corrected tier assignments, filled the transition-code gap, and narrowed
  dead-grammar cleanup to every companion type and workspace instance.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (from the pre-plan audit, to be re-verified during Milestone 1):
  publisher `ordering` and intake `dedupe ... policy` words are spliced verbatim
  into generated Haskell.  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits
  `"publisherOrdering = " <> pubOrdering pb` and
  `"inboxDedupePolicy = " <> inkDedupePolicy i`, so
  `ordering banana` type-checks the spec and produces a module GHC rejects.
  Backoff kinds are checked only at scaffold time (`publisherRefusals`,
  `BackoffUnknownKind`) and an unknown kind reaching emission becomes
  `error "keiro-dsl: unlowerable backoff kind"`.
- Discovery: `keiro-dsl/src/Keiro/Dsl/Validate.hs` contains no reference to
  `pubOrdering`, `inkDedupePolicy`, `wfStable`, `procName`, or `rtName`
  (verified by repository search on 2026-08-01), confirming that publisher
  ordering, intake dedupe policy, and the three stable runtime identities are
  entirely unvalidated at `check` time.
- Discovery (validation pass): the published release claim is current.  Hackage
  `keiro-dsl/preferred.json` lists `0.8.0.0` as the newest normal version and
  upstream tags stop at `keiro-dsl-0.8.0.0`; there is no `0.9.0.0` tag.  The
  local `LanguageVersion.hs` registry contains version 4, so the unreleased-v4
  window described by this plan is real.
- Discovery (validation pass): `resolveAggForService` retains the declared
  `WireSpec` in `aWire`, but no emitter reads `aWire`; `defaultWire` is only the
  fallback when the clause is absent.  The defect is therefore ignored wire
  words, not replacement of every supplied clause by `defaultWire`.
- Discovery (validation pass): duplicate aggregate state names are Tier A, not
  Tier B.  `emitVertex` renders every entry from `aStates` into one Haskell
  declaration, so `states { Draft Draft! }` emits the same constructor twice
  and cannot compile.  Conversely, a contract field that shadows the
  discriminator can round-trip for a specially chosen field value and is not
  universally non-working, so that rule belongs behind the version-4 gate.
- Discovery (validation pass): the legacy duplicate helper already has the
  incompatible shape `duplicatesBy :: Eq key => (a -> key) -> [a] -> [a]` and
  intentionally returns only occurrences after the first.  New pair/group
  diagnostics need a separate `duplicateGroupsBy` helper rather than silently
  changing the semantics of existing diagnostics.
- Discovery (validation pass): deleting the dead grammar declarations also
  requires deleting their exported companion types (`DispAction` and
  `EnvelopeLayer`) and their no-op `HasLocs` instances in
  `keiro-dsl/src/Keiro/Dsl/Workspace.hs`; the original plan named only the
  headline declarations.
- Discovery (validation pass): the exact unreferenced single-spec diagnostic
  inventory to pin in Milestone 5 is `UndeclaredEvent`, `UndeclaredState`,
  `TerminalHasOutgoing`, `DeprecatedEventStillEmitted`,
  `WireSchemaVersionMismatch`, `ProcessBenignInversion`,
  `DispositionDecodeUnboundedRetry`, `PublisherUnresolvedEmit`,
  `IntakeUnresolvedContract`, `WqDlqWithoutCeiling`,
  `DispatchEnqueueUnresolved`, `RunWorkflowUnresolved`, and
  `RouterReadModelUnverified`.  Diff-only and consumer-binding codes absent
  from `keiro-dsl/test/` are outside this single-spec closure plan.


## Decision Log

Record every decision made while working on the plan.

- Decision: Split every new rule into two enforcement tiers.  Tier A rules
  reject specs whose generated output provably cannot work under any released
  meaning — the generated Haskell fails to compile, or the generated service
  fails every request at runtime.  Tier A diagnostics apply to all language
  versions, including released 1 through 3.  Tier B rules reject specs that
  today produce a compiling, running, but unintended or under-specified
  service; Tier B diagnostics are gated on the effective language contract of
  the unreleased version 4, following the gating pattern ExecPlan 178
  established in `validateContract`.
  Rationale: ADR 0016 freezes released meanings, but a meaning that was never a
  working service has no consumer to break; moving its failure from GHC or
  runtime to `check` is the earliest-sound-boundary rule of
  [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md),
  not a semantic change.  Tier B changes real acceptance, so it rides the
  unreleased version 4 and ships in the first release that carries version 4.
  Date: 2026-08-01
- Decision: Close these holes by widening version 4 before it ships rather than
  registering a language version 5.
  Rationale: version 4 exists in the registry but has never been released;
  `0.8.0.0` shipped versions 1-3.  Nothing outside this repository consumes
  version 4 yet (confirmed by the operator: no serious project depends on Keiro
  today), so tightening it now is free, while deferring any single rule past
  the `0.9.0.0` release converts it into a future version-5 migration.
  Date: 2026-08-01
- Decision: An implementer may reassign an individual rule from Tier A to
  Tier B during implementation if evidence shows the accepted spec actually
  produces a working service, but never the reverse direction, and every
  reassignment must be recorded here with the evidence.
  Rationale: the tier assignments below are grounded in the audit's generated
  fixtures, but Tier A's justification is exactly "cannot work"; if that claim
  fails for a case, the honest response is to gate it on version 4, not to
  widen an ungated rejection of released-language specs.
  Date: 2026-08-01
- Decision: Reassign duplicate aggregate states to Tier A and discriminator-
  shadowing contract fields to Tier B before implementation.
  Rationale: current scaffold source provides direct evidence that duplicate
  state constructors cannot compile, while discriminator shadowing has a
  working subset and therefore changes real acceptance rather than merely
  moving an inevitable failure earlier.
  Date: 2026-08-02
- Decision: Add `TransitionUnguardedSibling` for a version-4 live-transition
  group that shares source and command and mixes guarded and unguarded members;
  retain `TransitionDuplicateUnguarded` for two or more unguarded members under
  every version.
  Rationale: the original plan required both checks but named only the Tier A
  code.  Giving the Tier B case its own stable code keeps the enforcement tier
  machine-visible and avoids describing a guarded edge as a duplicate
  unguarded edge.
  Date: 2026-08-02
- Decision: Treat the canonical intake envelope field vocabulary as
  `messageId`, `source`, `destination`, `key`, `eventType`, `schemaVersion`,
  `contentType`, `schemaReference`, `sourceEventId`,
  `sourceGlobalPosition`, `payloadBytes`, `occurredAt`, `causationId`,
  `correlationId`, `traceContext`, `attributes`, and the existing DSL envelope
  extension `idempotencyKey`.  Version-4 bind and dedupe resolution uses the
  union of this vocabulary and fields of the intake's accepted contract events.
  Rationale: this list is the current `IntegrationEvent` authority plus the
  envelope extension already used by every intake fixture; making it explicit
  prevents an invented field set and keeps valid existing spellings explainable.
  Date: 2026-08-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

A `.keiro` file declares an event-sourced service: aggregates (state machines
with commands, events, guarded transitions, and registers), integration
contracts (public Kafka message schemas), intakes (Kafka consumers that admit
external messages), publishers (outbox emitters), workqueues, read models
(projected SQL tables), workflows, processes, and routers.  The parser in
`keiro-dsl/src/Keiro/Dsl/Parser/` builds the AST in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs`; `validateSpec` and `validateCheckedSpec`
in `keiro-dsl/src/Keiro/Dsl/Validate.hs` produce `Diagnostic` values with
stable `DiagnosticCode` constructors; `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`
emits generated Haskell.  A rule that lives only in Scaffold runs after `check`
has already said yes, and a value the parser stores but nobody reads is a
"semantic dead letter": authors believe they declared behavior, and nothing
enforces it.

The language registry in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` currently
holds versions 1-4; versions 2-4 share syntax profile 2, and version 4 selects
`keiro-dsl/runtime-semantics/3`.  `CheckedService` in
`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` pairs the normalized graph with
the effective language contract; ExecPlan 178
(`docs/plans/178-enforce-typed-typeids-in-integration-contracts.md`) threaded
that contract into `validateContract` and gated `ContractInvalidTypeIdPrefix`
on it.  That is the exact mechanism Tier B rules reuse.

The audited holes, grouped as this plan's milestones treat them:

Verbatim policy splices.  `pubOrdering` (publisher `ordering` word) and
`inkDedupePolicy` (intake `dedupe ... policy` word) are stored as free `Text`
and emitted verbatim into generated modules (`Scaffold.hs`, the
`emitPublisherGen` and inbox emission paths).  Backoff kinds get a
scaffold-time refusal (`publisherRefusals`) instead of a `check` diagnostic.
Numeric fields accept zero where zero is meaningless: publisher
`maxAttempts 0`, `contract { schemaVersion 0 }`, read-model `version = 0`,
intake `decode schemaVersion == 0` (existing floors cover only timer
max-attempts, snapshot interval/codec version, and the DLQ-on retry ceiling).

Missing duplicate detection.  Duplicate states inside `states { ... }` collapse
through `Set.fromList` during validation, while generation emits the same
Haskell vertex constructor twice.
Duplicate registers, and duplicate fields within one command, event, or
contract event, pass `check` and fail later at GHC (duplicate record fields) or
produce a JSON object with a duplicated key (a contract field named like the
event discriminator).  Two same-category declarations (`enum Foo` twice) pass
because `NominalDeclarationCollision` in
`keiro-dsl/src/Keiro/Dsl/NominalType.hs` fires only across categories, and the
resolver's `Map.fromList` keeps the last.  Two live transitions with the same
source state and command and no guards pass `check` and produce a runtime in
which every such command fails with `CommandAmbiguous`.  Duplicate `emit map`
discriminant rows (`"done" => A` and `"done" => B`) pass.

Unconstrained stable identities.  Workflow `name`, process `name`, and router
`name` are stable runtime identities — the workflow name keys the journal
stream family — yet have no non-empty, charset, or spec-wide uniqueness rule;
two workflows may share `name "transfer"`.  Kafka topic strings in contracts
are arbitrary string literals (empty, spaces, over 249 characters, or illegal
charset all pass), and read-model `schema`/`table`/column names are not held to
PostgreSQL unquoted-identifier form; column names come from a token class that
admits `-`.

The intake envelope surface is a dead letter.  `bind` rows (`brField`,
`brSource`, `brRequired`, `brCrossCheck`), the `decode` clause (`decEnvelope`,
`decBodyStrict`, `decBodySchemaVersion`), and `dedupe key` are consumed only by
the parser, pretty-printer, and (for whole-record equality) `Diff.hs`.
`bind nonsenseField from header "x"`, a free-text envelope policy, a `dedupe`
key naming no field, and `decode schemaVersion == 99` against a
`schemaVersion 1` contract all pass.  Similarly, a contract
`event <Name> on <alias>` never checks that the alias names a declared topic,
and the aggregate `wire kind=... fields=...` words are parsed and ignored —
`resolveAggForService` retains the supplied clause as `aWire`, but no emitter
reads `aWire`; an absent clause alone selects `defaultWire`.  Only
`wireSchemaVersion` is validated.  The `emit` block's `source "..."` is fully
dead, and `emKey` /
`emDiscriminant` reach only diff identity.

Dead grammar.  `EnvelopeBinding`/`envCrossChecked`, `Derivation`/
`DerivStrategy`, and the hole-kind `Disposition` exist in `Grammar.hs` but no
parser constructs them and nothing consumes them; they misrepresent the frozen
surface.

Untested diagnostics.  Roughly a dozen existing `DiagnosticCode` constructors
(among them `UndeclaredState`, `UndeclaredEvent`, `TerminalHasOutgoing`,
`WireSchemaVersionMismatch`, `IntakeUnresolvedContract`,
`PublisherUnresolvedEmit`) have no test reference, so their accidental loss
would silently widen acceptance.

Relevant ADRs: ADR 0004 (each hazard is checked at the earliest boundary with
enough evidence — this plan moves scaffold-time and GHC-time failures to
`check`), ADR 0016 (released-language freeze — the tier framework exists to
honor it), and ADR 0012
(`../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md`,
whose one-schema-authority principle motivates resolving intake `bind` rows
against the contract's field set).  No ADR currently documents check-time
policy-vocabulary or identity rules; the distillation pass at the end of this
plan must add that context to ADR 0004's gate inventory.


## Plan of Work

Milestone 1 establishes the tier framework and closes the holes that produce
non-compiling or crashing output.  In `Validate.hs`, extend the contract-aware
validation path (the one ExecPlan 178 built, where `validateCheckedSpec` has
the `EffectiveLanguageContract`) so any rule can declare itself
version-gated; Tier A rules simply do not consult the gate.  Add closed
vocabularies: publisher `ordering` must be one of the words the emitter can
lower (enumerate them from the current `pubOrdering` splice sites and the
generated `publisherOrdering` consumer in keiro-core; the audit fixture set
suggests the working vocabulary is what existing conformance fixtures use),
publisher backoff kinds must be the set `publisherRefusals` already checks —
move that check (including the exponential-backoff completeness rule) from
scaffold time into `validateSpec` and leave a defensive scaffold assertion
behind — and intake `dedupe ... policy` must match the closed set the inbox
emitter can lower.  New Tier A codes: `PublisherOrderingUnknown`,
`PublisherBackoffInvalid`, `IntakeDedupePolicyUnknown`.  Add numeric floors as
Tier B (a zero today yields a compiling if useless service):
`PublisherMaxAttemptsBelowMinimum`, `ContractSchemaVersionBelowMinimum`,
`ReadModelVersionBelowMinimum`, `IntakeDecodeSchemaVersionBelowMinimum`, each
requiring the value be at least 1.  Every new code is appended to
`DiagnosticCode` without reordering existing constructors.

Milestone 2 adds duplicate and collision detection.  Tier A (the output cannot
work): duplicate field names within one command, one event, or one contract
event (`AggregateDuplicateFieldName`, `ContractDuplicateFieldName`); two live
unguarded transitions sharing source state and command
(`TransitionDuplicateUnguarded` — the generated runtime answers every such
command with `CommandAmbiguous`); duplicate contract event names and duplicate
topic aliases within one contract (`ContractDuplicateEvent`,
`ContractDuplicateTopicAlias`); and duplicate state names in the `states`
block (`AggregateDuplicateState`), because generation emits the same vertex
constructor twice.  Tier B (the output can run but is not what the author
wrote): a contract field whose JSON key equals the event discriminator key
(`ContractFieldShadowsDiscriminator`), duplicate register names
(`AggregateDuplicateRegister`), duplicate same-category nominal, id, and rule
declarations (`NominalDuplicateDeclaration` — extend the existing
cross-category collision logic in `NominalType.hs` so same-category duplicates
are also fatal under version 4), duplicate `emit map` discriminant rows
(`EmitMapDuplicateCase`), and guarded transition pairs that share source and
command with at least one unguarded sibling (`TransitionUnguardedSibling`,
reporting every member of the ambiguous group).  Retain the existing
first-shadow `duplicatesBy` behavior for old diagnostics and add
`duplicateGroupsBy` for rules that need every member and pair, anchoring at the
most specific `Loc` the current AST retains.

Milestone 3 constrains stable identities and external names, all Tier B under
version 4.  Workflow `name`, process `name`, and router `name` must be
non-empty, match the same legality rule the saga-category check already applies
(reuse its charset), and be unique spec-wide across the union of the three
kinds (`RuntimeIdentityInvalid`, `RuntimeIdentityDuplicate`).  Kafka topic
strings in contracts must match the broker's grammar — one to 249 characters
from `[a-zA-Z0-9._-]`, not `.` or `..` (`ContractTopicNameInvalid`); an empty
topic is Tier A because no broker accepts it.  Read-model `schema`, `table`,
and column names must match PostgreSQL unquoted-identifier form
(`[a-z_][a-z0-9_]{0,62}`), and duplicate column names are rejected
(`ReadModelIdentifierInvalid`, `ReadModelDuplicateColumn`).

Milestone 4 constrains the declared-but-ignored surfaces to statements that are
internally meaningful under version 4.  Resolve every intake `bind` row against
the explicit canonical-envelope vocabulary recorded in the Decision Log plus
the union of fields on its accepted contract events, and resolve `dedupe key`
against the same set
(`IntakeBindUnresolved`, `IntakeDedupeKeyUnresolved`).  Give the `decode`
envelope policy a closed vocabulary (`IntakeEnvelopePolicyUnknown`) and require
`decBodySchemaVersion` to equal the resolved contract's `ctrSchemaVersion`
(`IntakeDecodeSchemaVersionMismatch`).  Require a contract `event ... on alias`
to name a declared topic alias (`ContractTopicAliasUnresolved`).  For the
aggregate `wire` clause, validate `kind` and `fields` against the closed
vocabulary the emitter actually honors; because the emitter today ignores
`aWire`, the honest version-4 rule is: accept exactly `kind=ctorName` and
`fields=camelCase`, the spellings that describe current emitted bytes, and
reject everything else
(`WireClauseUnsupported`), so the surface stops lying without changing wire
bytes.  For the `emit` block, `source "..."` text remains accepted (it is
descriptive), but this milestone must either wire `emKey`/`emDiscriminant`
into validation against the read-model/contract field sets or explicitly
document them as descriptive-only in the language reference; record the choice
in the Decision Log.  Versions 1-3 continue to accept all of these specs
unchanged; every rule in this milestone consults the effective contract and
fires only for version 4.

Milestone 5 cleans up and locks down.  Delete the unreachable
`EnvelopeBinding`/`EnvelopeLayer`, `Derivation`/`DerivStrategy`, and
`Disposition`/`DispAction` declarations and exports from `Grammar.hs`, plus
their no-op `HasLocs` instances from `Workspace.hs` (no parser constructs them;
deleting them is invisible to every spec).  Add at least one negative test for
each of the thirteen exact single-spec diagnostic codes listed in Surprises &
Discoveries, so each
existing rejection is pinned against regression.  Add one positive and one
negative fixture per new code from Milestones 1-4.  Update the language
reference documentation for every newly enforced surface, amend ADR 0004's
gate inventory with the new check-time gates, append one `okf log add` entry,
and update `keiro-dsl/CHANGELOG.md` describing the version-4 tightening and
the Tier A corrections.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`.

Before editing, capture the defect evidence: stream a scratch spec per hole
(publisher `ordering banana`, duplicate unguarded transitions, `bind` to a
nonexistent field, two workflows with the same stable name, a `schemaVersion 0`
contract) to the CLI through `/dev/stdin` and confirm each passes today:

```bash
cabal run keiro-dsl:exe:keiro-dsl -- check /dev/stdin
```

The exact entry point was confirmed with
`cabal run keiro-dsl:exe:keiro-dsl -- --help`.  All five pre-change cases exited
zero.  The concise transcript was:

```text
publisher ordering banana: OK
duplicate Held -- ConfirmReservation transition: warning[RmProjectionWithoutNode], then OK
bind ghost from header "keiro-source": OK
contract schemaVersion 0: OK
two workflows named "hospital-transfer-reservation": OK
```

After each milestone, run the focused validator suite and the full DSL suite:

```bash
cabal test keiro-dsl-test --test-show-details=direct
```

After Milestone 4, prove released-language stability by running every
conformance suite unchanged:

```bash
cabal test all --test-show-details=direct
```

Expected: all suites pass; no committed fixture under `keiro-dsl/test/` needed
regeneration except fixtures this plan adds.  Any regenerated legacy fixture is
evidence a Tier A rule was wrongly scoped — stop and re-tier it.

Close with repository-wide gates and ADR validation:

```bash
cabal build all
nix flake check
okf log add docs/adr --kind Update -m "Record check-time policy, duplicate, identity, and envelope gates (plan 180)."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
```


## Validation and Acceptance

Acceptance is behavioral.  For every new diagnostic code there is a checked-in
fixture spec that fails `check` with exactly that code and a source line, and a
minimal edit of that fixture that passes.  Specifically:

- `publisher P { emit E ordering banana ... }` fails with
  `PublisherOrderingUnknown` under every language version; the same spec with a
  vocabulary word passes and scaffolds a compiling module.
- A spec with two identical unguarded `Held -- Confirm -->` transitions fails
  with `TransitionDuplicateUnguarded` under every version.
- `command C { x x: Int }` fails with `AggregateDuplicateFieldName` under every
  version.
- Under `language keiro-dsl 4`: two workflows sharing `name "transfer"` fail
  with `RuntimeIdentityDuplicate`; `bind ghost from header "x"` fails with
  `IntakeBindUnresolved`; `decode { schemaVersion == 99 }` against a
  `schemaVersion 1` contract fails with `IntakeDecodeSchemaVersionMismatch`;
  `states { Draft Draft! }` fails with `AggregateDuplicateState`.  The workflow,
  bind, and decode specs under `language keiro-dsl 3` still pass `check`, proving
  the Tier B gate; duplicate states fail under every version because their
  generated Haskell cannot compile.
- Every pre-existing fixture and conformance suite passes byte-unchanged, and
  `cabal build all` plus `nix flake check` succeed.

The work is accepted only when all new codes are pinned by tests, the
previously untested legacy codes are pinned, released versions 1-3 accept
exactly what they accepted before except the Tier A cases whose output never
worked, and strict ADR validation passes.


## Idempotence and Recovery

All edits are deterministic source changes; validators and tests can be rerun
freely.  New `DiagnosticCode` constructors are append-only — never reorder or
rename released constructors to make a fixture pass.  If a Tier A rule turns
out to reject a spec that actually worked, do not weaken the rule in place:
move it behind the version-4 gate (recording the decision) and re-run the full
conformance sweep.  The temporary defect-evidence specs live outside the
repository and can be recreated from the transcripts recorded in this plan.
Grammar deletions in Milestone 5 are safe because no parser constructs the
deleted nodes; if any hidden consumer surfaces during compilation, restore the
node, record the discovery, and leave its removal to a follow-up.


## Interfaces and Dependencies

All work is inside `keiro-dsl` (canonical URI
`mori://shinzui/keiro/packages/keiro-dsl`); no new external dependency is
expected.  `keiro-dsl/src/Keiro/Dsl/Validate.hs` appends the new
`DiagnosticCode` constructors named in the milestones and gains, for Tier B,
rules that receive the `EffectiveLanguageContract` the same way
`validateContract` does today.  The new group helper has the effective shape:

```haskell
duplicateGroupsBy :: Ord k => (a -> k) -> [a] -> [[a]]
```

returning every group of two or more declarations with the same key so each
member's location can be reported.  The existing `duplicatesBy` helper retains
its first-shadow semantics.  Milestone 1 moves the backoff rules so
`publisherRefusals` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` becomes a
defensive re-check of what `check` already guaranteed.  Milestone 4's
resolution rules consult the same resolved-contract lookup `intakeCoupling`
uses today; they introduce no second resolution authority.  Versions 1-3
behavior, all generated bytes, all fold fingerprints, and all wire formats are
unchanged by this plan; it adds admission rules only.


Revision note (2026-08-02): Revalidated the plan immediately before
implementation.  Corrected the wire-path description, re-tiered duplicate
states and discriminator shadowing from direct generator evidence, added the
missing guarded/unguarded transition diagnostic, specified the intake field
authority, enumerated the exact legacy diagnostic tests, preserved the existing
duplicate-helper contract, and expanded dead-grammar cleanup to companion types
and workspace instances.  Release status was confirmed against both Hackage and
upstream tags, and the five representative accepted-hole cases were reproduced
through the real CLI.
