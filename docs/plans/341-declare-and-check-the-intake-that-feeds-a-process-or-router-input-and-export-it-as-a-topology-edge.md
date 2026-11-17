---
id: 341
slug: declare-and-check-the-intake-that-feeds-a-process-or-router-input-and-export-it-as-a-topology-edge
title: "Declare and check the intake that feeds a process or router input and export it as a topology edge"
kind: exec-plan
created_at: 2026-11-17T14:55:55Z
intention: "intention_01m7n03hbfem79q2brf07rneyq"
master_plan: "docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-17T14:55:55Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-17T15:26:59Z
      mode: "update"
      note: "Correct schema handoffs, compatibility checks and fixture acceptance after repository review"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-17T15:26:59Z
      verdict: "comments"
      note: "Reviewed and corrected local coordination and acceptance; Mori outage prevents external API and ADR verification"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-17T15:42:49Z
      verdict: "approved"
      note: "Follow-up: Mori works with corrected Codex environment; keiki APIs, sibling fixtures and ADR verified; local findings corrected"
---

# Declare and check the intake that feeds a process or router input and export it as a topology edge

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl` is the command-line tool in this repository that reads `.keiro` service
specifications, checks them, and generates Haskell. In a specification, an "intake" declares
an inbox: a consumer of integration events that another service publishes on a topic of a
shared "contract". A "process" (a process manager) and a "router" each declare a typed
`input` that they react to. Nothing in the specification says that a given input is built
from a given intake's events. That link exists only in hand-written Haskell that converts an
accepted inbox message into the input value. As a result, every tool that reads the
specification sees the inbox and the component that reacts to it as unrelated, and
`keiro-dsl check` cannot notice when an intake stops accepting the event a router depends on.

After this plan, an author can write

```text
router CapacityChangeRouter
  name "incident-command-capacity-change"
  input AcceptedHospitalCapacitySnapshot from intake hospitalInbox event HospitalCapacitySnapshotPublished { messageId hospitalId snapshotId region divertStatus availableIcuBeds:Int }
```

and three things follow. `keiro-dsl check` rejects the specification if `hospitalInbox` is
not an intake of the service, or if the intake's `accept` list does not contain
`HospitalCapacitySnapshotPublished`. `keiro-dsl topology` shows an edge with relation `feeds`
from the intake to the router, in a document whose schema id is
`keiro-dsl/service-topology/2`. And nothing else changes: generated code, identity
fingerprints and the scaffold ledger are byte-for-byte what they were without the clause, so
declaring a source is documentation that is checked, not a runtime migration. A specification
that declares no source means exactly what it means today.

This implements the improvement request
`docs/improvement-requests/declare-which-intake-feeds-a-process-or-router-input.md` (IR-63),
filed by the Mori project. This plan is child EP-4 of
`docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md`.


## Progress

- [ ] Milestone 1: Language 6 parses and pretty-prints an input source on process and router
      inputs; earlier languages reject it; a specification without one is unchanged.
- [ ] Milestone 2: `check` reports a named error for an unknown intake and for an event the
      intake does not accept, and scaffolding a sourced specification produces generated
      code, fingerprints and a ledger identical to the unsourced one.
- [ ] Milestone 3: `topology` emits a `feeds` edge and schema id
      `keiro-dsl/service-topology/2` for a sourced specification and keeps `/1`, byte for
      byte, for every unsourced one; documentation, the `/2` JSON Schema and the IR-63 record
      are updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The syntax is `from intake <Intake> event <Event>+`, placed after the input's
  name and before its `{ fields }` body or its `: Type` annotation. At least one event is
  required.
  Rationale: The conversion from inbox message to input is hand-written, so the checker
  cannot infer which contract events an input is built from. Requiring the author to name
  them makes the second check precise: each named event must be in the intake's `accept`
  list. IR-63 leaves the syntax to keiro.
  Date: 2026-11-17

- Decision: The form is a Language 6 feature. Languages 1 to 5 reject it.
  Rationale: `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
  forbids widening a published language and tells contributors to correct an unfinalized
  candidate in place. Language 5 is published and stable; Language 6 is the registered
  candidate.
  Date: 2026-11-17

- Decision: `from`, `intake` and `event` are recognized only in this position. They are not
  reserved words.
  Rationale: ADR-16 requires new keywords to be contextual so that existing identifiers keep
  parsing. `intake` already begins a top-level declaration and must keep doing so.
  Date: 2026-11-17

- Decision: A declared source has no effect on generated code, fold fingerprints,
  process-reaction fingerprints, router-selection fingerprints, the scaffold ledger, or the
  compatibility verdicts of `keiro-dsl diff`.
  Rationale: IR-63 requires that declaring a source not change runtime behavior or the
  hand-written binding. Excluding it from every identity is what makes adopting it free for
  an existing service.
  Date: 2026-11-17

- Decision: The topology relation is `feeds`, from the intake node to the process or router
  node, with attributes `input` and `events`. A document that contains at least one `feeds`
  edge is emitted as `keiro-dsl/service-topology/2`; every other document stays `/1`.
  Rationale: The topology contract requires a new schema id for a new relation, so that a
  `/1` consumer fails closed instead of silently dropping the edge. Emitting the lowest
  schema id able to represent the document keeps every service that declares no source
  readable by `/1` consumers.
  Date: 2026-11-17

- Decision: The acceptance in IR-63 that the keiro-runtime-jitsurei incident-command suite
  passes unchanged is replaced here by a byte-identity proof inside this repository.
  Rationale: That service lives in `mori://shinzui/keiro-runtime-jitsurei`, pins an older
  keiro, and its specification is a legacy-unversioned (Language 1) source that cannot use a
  Language 6 form until it migrates. Byte-identical generated output is a stronger statement
  of the same guarantee and can be measured here.
  Date: 2026-11-17


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root. Run every build and test inside the Nix
development shell from the repository root, as `AGENTS.md` requires. The Z3 solver must be
present for some `keiro-dsl` suites; confirm with `nix develop -c z3 --version`.

The grammar's data types are in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`. An input is

```haskell
data InputDecl = InputDecl
  { name :: Name, fields :: [Field], valueType :: Maybe TypeExpr, loc :: Loc }
```

A router (`RouterNode`) has exactly one, in its `input` field. A process (`ProcessNode`) has
a `body` that is either `LegacyProcessBody` with one `InputDecl`, or `ReactionProcessBody`
whose `ReactionBody` has `inputs :: NonEmpty InputDecl`. An intake is `IntakeNode`, with
`name`, `contract`, `topic` and `accept :: [Name]`, the contract events it accepts.

Parsing is in `keiro-dsl/src/Keiro/Dsl/Parser/Coordination.hs`. `pInputDecl` parses a process
input, `input Name { fields }`. `pRouterInputDecl` parses a router input, either
`input Name { fields }` or `input Name : Type`. `InputDecl` values are constructed in three
places in that file and in the QuickCheck generators `genProcess` and `genRouter` in
`keiro-dsl/test/Main.hs`; adding a field means updating each.

Language versions are in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`. A `.keiro` file may
begin with `language keiro-dsl N`. Each registered version selects a "syntax profile", a set
of `LanguageFeature` constructors. Language 5 is the published stable version. Language 6 is
the candidate; its profile is the value `profileV5`, identified as
`keiro-dsl/syntax-profile/5`, built as a chain of `Set.insert` calls. A parser position is
gated with `requireLanguageFeatureAt` or, for an optional clause,
`optionalLanguageFeature :: FrontendContext -> LanguageFeature -> Text -> P a -> P (Maybe a)`
in `keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`. The intake's `idempotence` clause in
`keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs` is a worked example of an optional gated
clause; copy its shape. Before starting, read the `languageRegistry` value and confirm that
Language 6 is still `Candidate` with maturity `CandidateLanguage`. If it has been published
in the meantime, ADR-16 requires registering a successor version for this feature instead;
stop and record that in the Decision Log.

Pretty-printing is in `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`; `docInput` renders an input.
A property test in `keiro-dsl/test/Main.hs` asserts that parsing the pretty-printed form of a
specification gives the same specification.

Checking is in `keiro-dsl/src/Keiro/Dsl/Validate.hs`. `data DiagnosticCode` is a large
enumeration; a code's text is the `show` of its constructor. `mkErr line code message` builds
an error. `validateRouter` and `validateLegacyProcess` check routers and processes, and
reaction-process inputs are also checked in `keiro-dsl/src/Keiro/Dsl/ProcessReaction.hs`. An
existing check of the same family, which resolves a name to another declaration, is the one
that emits `IntakeUnresolvedContract` in `intakeCoupling`. In a workspace, declarations from
all member files are merged before these checks, so "an intake of the same service" means any
intake in the merged specification.

Identity and comparison code that must ignore the new field: fold fingerprints (in
`keiro-dsl/src/Keiro/Dsl/CanonicalEncoding.hs` and `FoldEvidence.hs`), the process-reaction
fingerprint (`processReactionFingerprintFrom` in `ProcessReaction.hs`, a SHA-256 of a
canonical text that includes inputs), the router-selection fingerprint
(`keiro-dsl/src/Keiro/Dsl/RouterSelection.hs`), the scaffold ledger
(`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs`), code generation
(`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`), and `keiro-dsl diff`
(`keiro-dsl/src/Keiro/Dsl/Diff.hs`, where `processInputs` and `legacyProcessPairDiff` report
`ProcessInputChanged` when input fields change). Some of these may derive their encodings
generically from the whole `InputDecl` value, which would let a new field leak in; Milestone
2 tests for exactly that.

The topology export is provided by the plan
`docs/plans/338-emit-a-versioned-service-topology-document-from-keiro-dsl-topology.md`. It is
needed only for Milestone 3. It supplies `keiro-dsl/src/Keiro/Dsl/Topology.hs` with a closed
`Relation` sum type, `buildServiceTopology`, `encodeServiceTopology`, and
`topologySchemaId :: ServiceTopology -> Text`, which until this plan always returns
`keiro-dsl/service-topology/1`; fixtures `hospital-capacity.keiro` and
`incident-command.keiro` under `keiro-dsl/test/fixtures/topology/` with golden documents
beside them; and golden tests in `keiro-dsl/test/Main.hs` that rewrite goldens when
`KEIRO_DSL_UPDATE_GOLDENS=1`. Confirm it is complete before Milestone 3 by running
`nix develop -c cabal run -v0 keiro-dsl -- topology keiro-dsl/test/fixtures/topology/incident-command.keiro`.
Milestones 1 and 2 do not need it.

The documentation page `docs/user/keiro-dsl-service-topology.md`, the schema
`docs/user/schemas/keiro-dsl-service-topology-1.schema.json` and the `Justfile` recipe
`topology-schema-validate` are created by
`docs/plans/339-keep-committed-topology-exports-fresh-and-publish-the-service-topology-contract.md`
and may or may not exist yet; Milestone 3 handles both cases. Other user documentation this
plan edits always exists: `docs/user/keiro-dsl-processes-and-routers.md`,
`docs/user/keiro-dsl-reference.md` (which has a table of Language 6 additions), and the
notation reference `agents/skills/keiro-dsl-authoring/NOTATION.md`. `docs/user/` is an OKF
bundle (Markdown with YAML frontmatter, validated by `just user-documentation-validate`);
when a page changes, advance its `timestamp` and add an entry with `okf log add`, following
recent entries in `docs/user/log.md`.

Relevant ADRs. `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
is binding as summarized in the Decision Log, and also requires fixtures proving that
predecessor languages reject the new form. `docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md`
requires positive fixtures to select Language 6.
`docs/adr/0043-delegated-inbox-intake-uses-a-downstream-event-receipt.md` describes intake
idempotence modes, which this plan does not change.
`docs/adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md`
describes reaction processes and why their fingerprint is identity.


## Plan of Work

### Milestone 1: grammar, parser and printer

Add to `Grammar.hs`:

```haskell
data InputSource = InputFromIntake { intake :: !Name, events :: !(NonEmpty Name), loc :: !Loc }
```

and a field `source :: !(Maybe InputSource)` on `InputDecl`. Update every construction site
to pass `Nothing`, and the generators in `keiro-dsl/test/Main.hs` to generate both cases for
Language 6.

Add a constructor `InputSourceSyntax` to `data LanguageFeature` and insert it into
`profileV5`. Write a parser `pInputSource` for `from intake <ident> event <ident>+` and call
it through `optionalLanguageFeature` in `pInputDecl` and `pRouterInputDecl`, immediately
after the input's name. Thread `FrontendContext` through `pInputDecl`,
`pLegacyProcessBody`, their reaction-body callers and `pRouterInputDecl`; the existing input
parsers do not receive this context. The event list ends at the `{` or `:` that starts the body. Under
Languages 1 to 5 the token `from` in that position must produce the standard
"requires language version" failure, not a generic parse error. Because `from` is contextual,
an input whose name is followed directly by `{` or `:` parses exactly as before.

Update `docInput` to print the clause when present, in the same position. Update whatever
else the compiler reports as non-exhaustive or positionally matched on `InputDecl`.

Tests, in the router and process `describe` blocks of `keiro-dsl/test/Main.hs`: a Language 6
router with a braces input, a Language 6 router with a typed (`: Type`) input, a legacy
process and a reaction process with two inputs of which one declares a source, each parsing
to the expected `InputSource`; the parse-and-pretty round trip for each; each predecessor language (1 through 5), using a compatible legacy-process or router
fixture with the clause, failing with the version-requirement message; and an existing fixture
without a source producing an identical parsed value before and after, apart from the new
`Nothing`.

### Milestone 2: checker and non-interference

Add two constructors to `DiagnosticCode`, `InputSourceUnresolvedIntake` and
`InputSourceEventNotAccepted`, classified like their neighbours in `diagnosticOrigin`. Write
one function that checks an `InputDecl` against the service's intakes and call it for the
router input, the legacy process input and every reaction-process input:

```text
spec.keiro:12: error[InputSourceUnresolvedIntake]: input 'AcceptedHospitalCapacitySnapshot' of router 'CapacityChangeRouter' names intake 'hospitalInbx', which is not declared in this service
spec.keiro:12: error[InputSourceEventNotAccepted]: input 'AcceptedHospitalCapacitySnapshot' of router 'CapacityChangeRouter' is fed by intake 'hospitalInbox' event 'HospitalCapacitySnapshotPublished', which the intake does not accept
```

One error is reported per unaccepted event. A repeated event name in the clause is reported
with the second diagnostic code's sibling wording or simply deduplicated; choose
deduplication unless an existing convention for duplicate list entries in `Validate.hs` says
otherwise, and note the choice in the Decision Log.

Create two fixtures under `keiro-dsl/test/fixtures/input-source/`: `sourced.keiro`, a small
Language 6 service with a contract, an intake, an aggregate, a read model, a router whose
input declares a source, and a reaction process one of whose inputs declares a source; and
`unsourced.keiro`, the same file with the two clauses removed and nothing else changed.

Tests: each diagnostic, by code and line; a workspace in which the intake and the router are
in different member files checks clean; and the non-interference proof. For that proof,
copy `sourced.keiro` and `unsourced.keiro` into separate temporary input directories under
the same basename, and scaffold into separate output directories with the same
arguments and assert that the sets of written files are equal and that every file, including
the ledger and the Cabal fragment, is byte-identical. Also directly compare fold fingerprints, `processReactionFingerprint` and the checked
router-selection fingerprint between the two specifications. Do not assume the scaffold
ledger contains every fingerprint. Include a declarative-selection router so that its
fingerprint assertion is non-vacuous, and assert that every compared identity is present. If the ledger or a
generated banner records a digest of the specification file itself, the two will differ
there for a reason unrelated to semantics; in that case compare everything else exactly,
assert that those specific lines are the only difference, and record it in Surprises &
Discoveries. Also assert that `keiro-dsl diff`'s comparison of the two specifications
reports no breaking or replay-affecting change: use the library entry point the existing
diff tests in `keiro-dsl/test/Main.hs` use to compare two parsed specifications. If any
fingerprint or the diff does change, fix the encoder or comparison that let the field in by
excluding `source` there, rather than accepting the new value.

### Milestone 3: the `feeds` edge and schema id `/2`

This milestone needs the topology export described in Context and Orientation.

In `keiro-dsl/src/Keiro/Dsl/Topology.hs`, add `Feeds` to `Relation`. For every input that
declares a source, emit one edge from the intake node to the process or router node with
relation `feeds` and attributes `input` (the input's name) and `events` (the named events, in
declared order). Change `topologySchemaId` to return `keiro-dsl/service-topology/2` when the
document contains at least one `feeds` edge and `keiro-dsl/service-topology/1` otherwise. A
`/2` document is otherwise identical in shape to `/1`.

Create `keiro-dsl/test/fixtures/topology/incident-command-sourced.keiro` as a copy of
`incident-command.keiro` in which the input of `CapacityChangeRouter` declares
`from intake hospitalInbox event HospitalCapacitySnapshotPublished`. Do not edit
`incident-command.keiro`. Add a golden test for the new fixture with golden file
`incident-command-sourced.topology.golden.json`. For the semantic comparison, copy the two
inputs to separate temporary directories under the same basename `incident-command.keiro`,
then export and decode them. They must differ only in `schema`, the one added edge, and the
member digest and line numbers that follow from the edited line. Comparing the checked-in
filenames directly would also change `service`, `source.path`, member paths and node ownership.
Retain every `machine` field unchanged if the machine-export plan has already landed. Run the existing golden tests without regenerating them:
they must pass unchanged, which proves that unsourced services still produce `/1` bytes.

Update documentation. In `docs/user/keiro-dsl-processes-and-routers.md` describe the clause,
what `check` verifies, and that it has no runtime effect. Add a row to the Language 6
additions table in `docs/user/keiro-dsl-reference.md` and the form to
`agents/skills/keiro-dsl-authoring/NOTATION.md`. If
`docs/user/keiro-dsl-service-topology.md` exists, add a section for schema id `/2` covering
the `feeds` relation and the rule that a document is emitted under the lowest schema id able
to represent it, create `docs/user/schemas/keiro-dsl-service-topology-2.schema.json` as the
`/1` schema with the `schema` constant changed and `feeds` added to the relation
enumeration, and extend the `topology-schema-validate` recipe so each golden document is
validated against the schema its own `schema` field names. If that page does not exist yet,
record in this plan's Progress section and in the Progress section of
`docs/plans/339-keep-committed-topology-exports-fresh-and-publish-the-service-topology-contract.md`
that documentation and a schema for `/2` are owed.

Update `docs/improvement-requests/declare-which-intake-feeds-a-process-or-router-input.md`:
set `status` (the values in use in that directory are `proposed`, `accepted`, `in-progress`,
`completed`), advance `timestamp`, and add a section "Keiro's response" stating the syntax,
the two diagnostics, the `feeds` relation and `/2` schema id, and that adoption in
keiro-runtime-jitsurei requires that service to move to Language 6 first. Add the matching
entry to `docs/improvement-requests/log.md`. Add a `keiro-dsl/CHANGELOG.md` entry under
`## [Unreleased]`.


## Concrete Steps

Work from the repository root.

```bash
nix develop -c z3 --version
nix develop -c cabal build keiro-dsl
nix develop -c cabal test keiro-dsl:keiro-dsl-test --test-show-details=direct --test-options='--match "input source"'
```

Name the new `describe` blocks so that they contain the words `input source`, which makes the
command above select them.

See the checker by hand:

```bash
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/input-source/sourced.keiro; echo "exit $?"
```

prints `OK` and `exit 0`. After changing the intake name in the clause to a name that does
not exist, the same command prints an `error[InputSourceUnresolvedIntake]` line and exits
non-zero. Restore the file afterwards.

See the edge (Milestone 3):

```bash
nix develop -c cabal run -v0 keiro-dsl -- topology keiro-dsl/test/fixtures/topology/incident-command-sourced.keiro | grep -o '"schema":"[^"]*"'
```

prints:

```text
"schema":"keiro-dsl/service-topology/2"
```

Commit at each milestone with a Conventional Commits message and these trailers:

```text
feat(keiro-dsl): declare and check the intake that feeds an input

MasterPlan: docs/masterplans/48-export-a-keiki-verified-service-topology-from-keiro-dsl-and-declare-intake-sources.md
ExecPlan: docs/plans/341-declare-and-check-the-intake-that-feeds-a-process-or-router-input-and-export-it-as-a-topology-edge.md
Intention: intention_01m7n03hbfem79q2brf07rneyq
```


## Validation and Acceptance

A Language 6 specification whose router input, or process input, names an intake and events
parses, pretty-prints back to the same text, and checks clean; the same specification
declared as Language 5 fails with the version-requirement message; and a specification
without a source parses to the same value as before (IR-63 AC-1).

`keiro-dsl check` exits non-zero with `InputSourceUnresolvedIntake` for an unknown intake and
with `InputSourceEventNotAccepted` for an event missing from the intake's `accept` list
(AC-2).

`keiro-dsl topology` on `incident-command-sourced.keiro` prints a document with schema id
`keiro-dsl/service-topology/2` containing one `feeds` edge from intake `hospitalInbox` to
router `CapacityChangeRouter`, and every pre-existing topology golden test passes without
regeneration (AC-3).

Guarantees that must not weaken, with the check that measures each (AC-4). Generated code,
the scaffold ledger and the Cabal fragment are byte-identical with and without a source,
measured by the Milestone 2 scaffold comparison. Fold, process-reaction and router-selection
fingerprints are identical, measured by direct identity comparisons as well as the scaffold
comparison. `diff`
reports no compatibility change, measured by the Milestone 2 diff test. Languages 1 to 5
parse exactly what they parsed before, measured by the existing language-version and
frontend-compatibility tests passing and by
`nix develop -c bash scripts/check-conformance-corpus.sh` reporting no drift in any committed
corpus. No runtime package (`keiro`, `keiro-core`, `keiro-pgmq`) is edited, so the command
path and its benchmarks are not affected.

Finally:

```bash
nix develop -c just verify
```


## Idempotence and Recovery

All steps are additive. Adding the `source` field breaks compilation at each `InputDecl`
construction site until it is updated; the compiler lists them, and there is no partial state
to recover from. Golden regeneration is needed only for the one new golden file; if any
pre-existing golden changes, restore it with
`git checkout -- keiro-dsl/test/fixtures/topology` and fix the code instead. Milestones 1 and
2 can be completed and committed while the topology export does not exist yet; Milestone 3
then waits for it.


## Interfaces and Dependencies

No new package.

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`: `InputSource` as shown under Milestone 1, exported,
and `InputDecl.source :: Maybe InputSource`.

In `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`: `InputSourceSyntax :: LanguageFeature`, a
member of the Language 6 profile only.

In `keiro-dsl/src/Keiro/Dsl/Validate.hs`: `InputSourceUnresolvedIntake` and
`InputSourceEventNotAccepted :: DiagnosticCode`.

In `keiro-dsl/src/Keiro/Dsl/Topology.hs`: `Feeds :: Relation`, and `topologySchemaId`
returning `/2` exactly when a `feeds` edge is present.


Review update, 2026-11-17: reconciled schema handoffs, optional-field compatibility and
acceptance comparisons without changing the four work streams. Repository APIs and local
ADR references were inspected. Follow-up Mori lookup resolved the sibling fixtures,
keiki source and `mori://shinzui/mori/okf/adrs/concepts/ADR-33`; the earlier failures came
from Codex inheriting a stale development database address, not a Mori outage. The earlier
review entry is retained as history and corrected by the follow-up review. Keiki's
`edgesOut`, `initial`, `isFinal`, `target`, `mode`, `edgeInputName` and `OPack`/`wcName`
interfaces support the planned comparison; its builder preserves declaration order within
each source state, including repeated source blocks. The two sibling specifications exist
and are legacy-unversioned, as the fixture-migration instructions expect.
