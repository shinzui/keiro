---
id: 103
slug: make-keiro-dsl-diff-sound-over-the-full-decode-and-identity-surface
title: "Make keiro-dsl diff sound over the full decode and identity surface"
kind: exec-plan
created_at: 2026-07-13T18:56:58Z
intention: "intention_01kxed7haee7ja78qm70cc6qm5"
master_plan: "docs/masterplans/15-harden-and-extend-the-keiro-dsl-toolchain-surfaced-by-the-2026-07-dsl-audit.md"
---

# Make keiro-dsl diff sound over the full decode and identity surface

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-dsl diff --since <git-ref> <file.keiro>` is the evolution merge gate for `.keiro`
service specifications: it compares the working-tree spec against the version stored at a
git ref, classifies every change, and exits non-zero on anything that would break already
persisted data. CI and the authoring loop rely on that exit code to block unsafe merges.

Today the gate is unsound. It inspects only the events of `aggregate` nodes, and even
there it compares field *names* only. All of the following currently print **nothing and
exit 0** (each one verified against the built CLI on 2026-07-13; transcripts are in
Surprises & Discoveries):

- changing an event field's *type* (`note:Text` to `note:Int`) — every stored payload of
  that event misdecodes;
- removing an enum constructor or changing its wire spelling (`Red=red` to `Red=crimson`)
  — stored payloads carrying the old spelling fail decode;
- changing the `wire` block (`fields=camelCase` to `fields=snake_case`) — every stored
  event of the aggregate re-keys and fails decode;
- removing an event from a cross-service `contract` — other services decode that schema;
- changing a `workqueue` payload wire name or type — queued jobs misdecode on consume;
- renaming a workflow's stable `name` — the journal stream and every deterministic id
  re-derive, orphaning all in-flight workflows;
- changing an `id` declaration's `prefix` — stored ids stop matching newly minted ones.

Worse, a version jump with a dangling upcaster (`v1` to `v3` with only `upcast from v2`)
is positively classified **ADDITIVE**, and two distinct breaking rules (field removal,
version decrease) report the *wrong* machine code (`EvtFieldAddedWithoutBump`), which
tests and tooling match on.

After this plan, the differ covers the full **decode surface** (anything that changes how
persisted bytes are interpreted: aggregate events, enums, wire specs, contract events,
workqueue payloads, process inputs, workflow inputs/outputs) and the full **identity
surface** (anything that re-keys persisted state or deterministic derivations: workflow
stable names, id prefixes, dedupe keys and policies, derived-id prefixes, queue names),
with a three-tier classification — `ADDITIVE` (exit 0), `WARNING` (printed, exit 0), and
`BREAKING` (exit non-zero) — and a *correct, distinct* diagnostic code per rule. The
differ is restructured so that **every** `Node` constructor is either diffed by an
explicit per-node-family differ or explicitly declared out-of-diff-scope with a written
rationale; there is no silent fall-through, and the mechanism is the extension point that
docs/plans/107, docs/plans/108, and docs/plans/109 register their new constructs with.

To see it working after implementation: run `bash keiro-dsl/test/diff-test.sh` from the
repo root (all cases pass, including the new ones), and run the manual repro in Concrete
Steps — a field type change that today exits 0 silently will print a `BREAKING` line
tagged `[EvtFieldTypeChanged]` and exit 1.


## Progress

Milestone 1 (registry restructure, parity):

- [x] (2026-07-13 19:59Z) Add the new `DiagnosticCode` constructors to `keiro-dsl/src/Keiro/Dsl/Validate.hs`.
- [x] (2026-07-13 19:59Z) Add `Advisory` to `Change`, add `ckFacet` to `ChangeKind` in `keiro-dsl/src/Keiro/Dsl/Diff.hs`.
- [x] (2026-07-13 19:59Z) Introduce `DiffEnv`, `NodeFamily`, `familyOf`, `FamilyDiff`, `familyRegistry`, `Paired`, `pairByName`.
- [x] (2026-07-13 19:59Z) Port the existing aggregate event differ onto the registry with unchanged classifications.
- [x] (2026-07-13 19:59Z) Write out-of-scope rationales for `NOperation` and for `specRules` (code comments + registry entries).
- [x] (2026-07-13 19:59Z) Generalize `renderChange` in `keiro-dsl/app/Main.hs` (facet-aware, `WARNING:` tier); exit non-zero only on `Breaking`.
- [x] (2026-07-13 19:59Z) Unit tests: registry completeness over `[minBound .. maxBound]`, non-empty rationales, parity of the two existing diff-classification tests.
- [x] (2026-07-13 19:59Z) `cabal build keiro-dsl`, unit suite, and `bash keiro-dsl/test/diff-test.sh` all green (59 examples, 0 failures; shell cases 1–2 passed).

Milestone 2 (aggregate-family decode soundness — A1, A2, A3, A5, A7):

- [x] (2026-07-13 20:04Z) Field comparison by `(name, type)`; `EvtFieldTypeChanged` breaking rule (direct fields and `fields(Command)` indirection).
- [x] (2026-07-13 20:04Z) Correct codes for removal (`EvtFieldRemovedSameVersion`) and version decrease (`EvtVersionDecreased`).
- [x] (2026-07-13 20:04Z) Version-bump rule anchored to the OLD spec's version (fixes the dangling-upcaster hole).
- [x] (2026-07-13 20:04Z) Spec-level enum differ (`EnumCtorRemoved`, `EnumWireSpellingChanged`, additions additive).
- [x] (2026-07-13 20:04Z) Wire-spec differ with default normalization (`WireSpecChanged`).
- [x] (2026-07-13 20:04Z) Un-deprecation advisory (`EventUndeprecated`).
- [x] (2026-07-13 20:04Z) Red/green fixtures committed under `keiro-dsl/test/fixtures/`; unit tests per code; `diff-test.sh` cases 3–4 added (69 examples, 0 failures; every new fixture also passes `keiro-dsl check`).

Milestone 3 (cross-node decode surface — A4):

- [ ] Contract family differ (event/field/discriminator/topic/schemaVersion rules).
- [ ] Workqueue payload differ (`WqPayloadFieldChanged`, optional-field addition additive).
- [ ] Process input differ (`ProcessInputChanged`).
- [ ] Workflow input/output/id and body differs (`WorkflowShapeChanged`, `WorkflowBodyChanged`, exported `classifyWorkflowBody` hook).
- [ ] Fixtures + unit tests per code; `diff-test.sh` contract case added.

Milestone 4 (identity surface — A6 — plus CLI/doc truth):

- [ ] Identity rules: `WorkflowStableNameChanged`, `IdPrefixChanged`, `DedupeIdentityChanged`, `DerivedIdentityChanged`, `QueueIdentityChanged` (breaking); `TimerWindowChanged`, `EmitMappingChanged`, `DecodePostureChanged`, `ProjectionChanged`, `PublisherPolicyChanged`, `DispatchRetargeted`, `ContractSchemaVersionBumped` (warnings).
- [ ] Fixtures + unit tests per code; `diff-test.sh` identity + warning-tier cases added.
- [ ] Rewrite the `Keiro.Dsl.Diff` module haddock (it currently claims enum deltas are emitted; they are not).
- [ ] Update the `diff` subcommand help text in `keiro-dsl/app/Main.hs` and the one-line diff descriptions in `agents/skills/keiro-dsl-authoring/NOTATION.md` and `agents/skills/keiro-dsl-authoring/SKILL.md` to name the three tiers.
- [ ] Full validation sweep: unit suite from `keiro-dsl/`, `diff-test.sh`, manual before/after repro, conformance suites untouched and green.


## Surprises & Discoveries

Pre-implementation verification (2026-07-13, plan authoring). Every headline finding was
re-confirmed against the built CLI (`cabal list-bin keiro-dsl`) using a throwaway git repo
seeded with the committed fixtures, exactly as `diff-test.sh` does. Field type change,
wire-spec change, enum wire-spelling change, contract event removal, and workflow stable
name change all printed nothing and exited 0. The dangling-upcaster jump printed a
positive misclassification:

```text
--- v1 -> v3 with only 'upcast from v2 = HOLE' (no 1->2 rung exists) ---
ADDITIVE: Reservation event TransferReservationCreated: new version v3 with upcaster from v2
exit=0
```

The two classifications the differ does get right today (field add without bump is
BREAKING exit 1; v2-with-upcaster is ADDITIVE exit 0) were also confirmed, so Milestone 1
has a real parity baseline:

```text
BREAKING: Reservation event TransferReservationCreated: field(s) triageNote added at the same version v1 without a version bump or upcaster [EvtFieldAddedWithoutBump]
exit=1
ADDITIVE: Reservation event TransferReservationCreated: new version v2 with upcaster from v1
exit=0
```

- Milestone 1 validation (2026-07-13 19:59Z) preserved both baseline CLI lines
  byte-for-byte after moving aggregate evolution onto the exhaustive family registry.
  The unit suite increased from 58 to 59 examples and remained green; the new example
  proves every `NodeFamily` appears exactly once and every exclusion has a non-empty
  rationale.
- Milestone 2 validation (2026-07-13 20:04Z) showed the old-spec anchor is sufficient
  to reject the audited v1→v3 false additive without reconstructing unavailable history:
  the CLI now reports `EvtVersionMissingUpcaster` and exits 1. Direct fields and
  `fields(Command)` both report `EvtFieldTypeChanged`; all nine mutation fixtures remain
  valid single specs, separating evolution failures from validator failures.

(Add new entries here as implementation proceeds.)


## Decision Log

- Decision: Three-tier classification; the middle tier's constructor is named `Advisory`,
  rendered as `WARNING:` by the CLI, and does not affect the exit code.
  Rationale: A6 requires distinguishing "blocks the merge" from "must be seen but may
  proceed". The constructor is not named `Warning` because `keiro-dsl/test/Main.hs`
  imports both `Keiro.Dsl.Validate (Severity (..))` (which exports a `Warning`
  constructor, Validate.hs:28-29) and `Keiro.Dsl.Diff (Change (..))` unqualified
  (test/Main.hs:10,19); a second unqualified `Warning` would force qualification churn
  across the suite.
  Date: 2026-07-13.

- Decision: Workflow stable `name` change (`wfStable`, Grammar.hs:757) is BREAKING
  (`WorkflowStableNameChanged`).
  Rationale: the stable name keys the journal stream and seeds every deterministic id
  (step, awakeable, child ids). Renaming it orphans every in-flight workflow: replays
  open a fresh journal and re-execute effects. Unambiguous.
  Date: 2026-07-13.

- Decision: `id` declaration `prefix` change (`idPrefix`, Grammar.hs:134) is BREAKING
  (`IdPrefixChanged`).
  Rationale: ids are persisted with their prefix embedded (typeid-style); stored ids stop
  equaling newly minted ones, so correlation and dedupe keys silently diverge.
  Unambiguous.
  Date: 2026-07-13.

- Decision: Intake dedupe key and dedupe policy changes (`inkDedupeKey`/`inkDedupePolicy`,
  Grammar.hs:619-620) are BREAKING (`DedupeIdentityChanged`), not warnings.
  Rationale (argued, per the case-by-case mandate): the dedupe key IS the identity of
  "this message was already processed". Under at-least-once Kafka redelivery, re-keying
  the dedup store means an already-processed message no longer matches its dedup record
  and its side effects re-execute. There is no online migration expressible in the spec,
  so the gate must force a conscious decision (revert, or accept the breaking
  classification explicitly). The same code covers the pgmq `dispatch` dedup surfaces
  (`pdDedupKey`/`pdDedupQueue`/`pdDedupQueueField`/`pdDedupReadModel`/
  `pdDedupReadModelField`, Grammar.hs:727-731), which key the double-enqueue check.
  Date: 2026-07-13.

- Decision: Timer deadline window change (`faWindow` of `FireAtExpr`, Grammar.hs:464-468,
  reached via `tmFireAt`, Grammar.hs:499) is a WARNING (`TimerWindowChanged`), not
  breaking. A change to the fireAt *source field* is classified the same way.
  Rationale (argued): the deadline is computed at schedule time and persisted with the
  timer request, so already-scheduled timers keep their old deadline; only future
  schedules shift. No stored payload misdecodes and no identity re-keys — it is a
  behavioral timing change the author must see in gate output but that need not block.
  Date: 2026-07-13.

- Decision: Process identity fields are BREAKING under `DerivedIdentityChanged`: the
  define-once process `name` (`procName`, Grammar.hs:515-516), the saga stream prefix
  (`sagaStreamPrefix`, Grammar.hs:401-405), the timer id prefix and fired-event-id prefix
  (`IdExpr.idePrefix`, Grammar.hs:451-455, used at Grammar.hs:498 and Grammar.hs:490),
  the emit `messageId`/`idempotencyKey` derive prefixes (`DeriveSpec.dsPrefix`,
  Grammar.hs:630, fields at Grammar.hs:653-654), the publisher `outboxId stable from`
  field (`pubOutboxField`, Grammar.hs:673-674), and the workflow id derivation
  (`wfIdField`/`wfIdVia`, Grammar.hs:762-764).
  Rationale: each is an input to a deterministic derivation whose outputs are persisted
  and deduped against (dispatch command ids derive from the process name; timer fires
  dedupe on the derived fired-event id; outbox retries coalesce on the derived
  message/outbox id; the workflow id keys the journal). Changing any of them re-keys a
  dedup or persistence identity, so replays and retries stop coalescing — duplicate side
  effects.
  Date: 2026-07-13.

- Decision: Workqueue captured names (`wqLogical`/`wqPhysical`/`wqDlq`/`wqTable`,
  Grammar.hs:705-708) are BREAKING under `QueueIdentityChanged`.
  Rationale: the physical queue and its pgmq table hold in-flight jobs and are one arm of
  the dispatch dedup check; renaming orphans queued messages and re-keys the dedup site.
  Date: 2026-07-13.

- Decision: Emit status-map changes (rows/discriminant/key, Grammar.hs:648-652) are a
  WARNING (`EmitMappingChanged`); intake decode-block changes (Grammar.hs:601-607,621)
  are a WARNING (`DecodePostureChanged`); publisher `ordering` changes (Grammar.hs:670)
  are a WARNING (`PublisherPolicyChanged`); aggregate projection changes
  (table/key/status-map, Grammar.hs:340-347) are a WARNING (`ProjectionChanged`).
  Rationale: each changes forward behavior visibly (what gets published, decode
  strictness, delivery order, read-model shape) but neither misdecodes stored payloads
  nor re-keys a persisted identity. Projection table migrations are owned by codd, and
  docs/plans/107-add-a-first-class-read-model-node-with-registration-schema-and-consistency-to-keiro-dsl.md
  supersedes `ProjectionChanged` with a real read-model family differ. Publisher
  `maxAttempts`/`backoff` and workqueue `retry` tuning stay out-of-diff-scope entirely
  (single-spec validator territory, no persisted identity).
  Date: 2026-07-13.

- Decision: pgmq `dispatch` retargeting (`pdSourceReadModel`/`pdEnqueueTo`,
  Grammar.hs:724,732) is a WARNING (`DispatchRetargeted`), while its dedup-arm changes
  are BREAKING (`DedupeIdentityChanged`, above).
  Rationale: retargeting rewires which read model feeds the fan-out or which queue
  receives jobs — loud forward-behavior change, but no already-queued job misdecodes and
  the dedup identity is covered separately; unresolved targets are `check`'s job
  (`DispatchEnqueueUnresolved`, Validate.hs:185-189).
  Date: 2026-07-13.

- Decision: Contract field addition at the *same* `schemaVersion` is BREAKING
  (`ContractFieldChanged`); the same addition accompanied by a `schemaVersion` increase
  is a WARNING (`ContractSchemaVersionBumped`). Field removal and type change are always
  BREAKING; `schemaVersion` decrease is BREAKING (`ContractSchemaVersionDecreased`).
  Rationale: contract fields have no optionality flag and contracts carry no upcaster
  chain (Grammar.hs:534-561), so an updated consumer strictly decoding an older in-flight
  message fails on a missing field. A version bump signals a coordinated cross-service
  rollout — the gate surfaces it loudly but does not block, because blocking would make
  legitimate contract evolution impossible in this notation.
  Date: 2026-07-13.

- Decision: ANY workflow body change (relabel, reorder, removal, insertion, appending)
  is BREAKING (`WorkflowBodyChanged`) in this plan.
  Rationale: replay matches on the step label (Grammar.hs:739-751), so divergent bodies
  re-execute divergent code against existing journals. The runtime's sanctioned safe
  evolution mechanisms (`patch`, `continueAsNew`) are not expressible in the notation yet;
  docs/plans/109-extend-keiro-dsl-node-coverage-pgmq-ordering-and-provisioning-snapshot-policy-and-workflow-patch-and-continue-as-new.md
  adds them and relaxes this rule for patch-guarded edits via the exported
  `classifyWorkflowBody` hook (see Interfaces and Dependencies). The breaking detail text
  must point authors at that plan's `patch` support.
  Date: 2026-07-13.

- Decision: The no-silent-fall-through guarantee is enforced by (a) a total `familyOf ::
  Node -> NodeFamily` case, so a new `Node` constructor trips `-Wincomplete-patterns`
  (the package builds with `-Wall`, keiro-dsl.cabal:21-22), and (b) a unit test asserting
  the registry covers `[minBound .. maxBound] :: [NodeFamily]` with non-empty rationale
  text on every `OutOfDiffScope` entry — rather than adding `-Werror=incomplete-patterns`
  package-wide.
  Rationale: a package-wide `-Werror` flag could break unrelated modules and is a
  build-policy decision beyond this plan's scope; the pair of guards is mechanical and
  test-enforced.
  Date: 2026-07-13.

- Decision: New diagnostic codes are appended to `DiagnosticCode` in
  `keiro-dsl/src/Keiro/Dsl/Validate.hs` (the enum at Validate.hs:32-73), grouped under a
  comment marking them diff-only, because `Keiro.Dsl.Diff` already imports the type from
  there (Diff.hs:30) and the enum is documented as "the single registry of evolution
  rules" (Validate.hs:41-43). `EvtFieldAddedWithoutBump` keeps its one true meaning
  (field added at same version); removal and decrease get their own codes.
  Date: 2026-07-13.

- Decision: Wire specs are normalized before comparison: an absent `wire` block means the
  defaults `kind=ctorName fields=camelCase`, so adding or removing the block is only
  breaking when the *effective* kind/fields change. `wire schemaVersion=` is not diffed
  (the single-spec `WireSchemaVersionMismatch` rule, Validate.hs:480-491, already ties it
  to the max event version, which the event rules diff).
  Date: 2026-07-13.

- Decision: `NOperation` nodes and top-level `rule` declarations are explicitly
  out-of-diff-scope, with rationale recorded both in code comments and the registry.
  Rationale: an operation owns no persisted decode/identity surface — it references other
  nodes, and those references are `check`'s job (strengthened by
  docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md);
  the signal/await pairing surfaces on the workflow differ. Rules are guard logic:
  changing one changes behavior, not the interpretation of stored bytes or any persisted
  key. The same reasoning excludes transitions, guards, writes, states, intake bind rows,
  and all disposition tables (single-spec validator territory).
  Date: 2026-07-13.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The package and its scope

`keiro-dsl` (directory `keiro-dsl/` of this repo) is the toolchain over `.keiro` typed
service specifications: parser (`keiro-dsl/src/Keiro/Dsl/Parser.hs`), validator
(`Validate.hs`), scaffolder (`Scaffold.hs`), pretty-printer (`PrettyPrint.hs`), grammar
(`Grammar.hs`), and the evolution differ (`Diff.hs`), wired into a CLI at
`keiro-dsl/app/Main.hs` with subcommands `parse`, `check`, `scaffold`, `diff`, `new`.
Tests live under `keiro-dsl/test/` (an hspec unit suite `test/Main.hs`, shell gates
`test/*.sh`, spec fixtures `test/fixtures/*.keiro`, and seventeen conformance suites that
compile scaffold output against the live runtime).

Standing assumption: keiro MasterPlan 14
(docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md)
is implemented before this MasterPlan. This MasterPlan — and therefore this plan —
changes ONLY the `keiro-dsl` package, its tests, the authoring skill under
`agents/skills/keiro-dsl-authoring/`, and docs. It never touches `keiro`, `keiro-core`,
or `keiro-pgmq` runtime code.

Effort framing: medium complexity concentrated in getting the classification table right
and in fixture volume; the registry restructure itself is mechanical and low-risk because
the existing behavior is pinned by tests before it moves.

### The classification axes, stated faithfully to the runtime

**Decode safety.** The runtime decodes a stored event through
`keiro-core/src/Keiro/Codec.hs`: `decodeRecorded` (Codec.hs:235-240) reads the schema
version stamped in event metadata via `extractSchemaVersion` (Codec.hs:295-308),
**defaulting to 1 when the stamp is absent**, then `migrateToCurrent` (Codec.hs:266-289)
replays the upcaster chain — one rung per version, keyed by source version (`Upcaster`,
Codec.hs:65) — up to the codec's current `schemaVersion`, and only then runs the
current-version `decode`. A missing rung fails with `GapInUpcasterChain` or
`IncompleteUpcasterChain` (Codec.hs:112-117), and `mkCodec` (Codec.hs:142-165) rejects a
codec whose chain does not cover every version `1 .. schemaVersion-1`. So a change is
decode-safe exactly when every payload already in the log still decodes under the new
spec: same field names AND types at an unchanged version, or a bumped version with a
contiguous upcaster chain reaching back to every version that may exist on disk. Field
*names and types* both matter because the generated decoder is shape-strict; the wire
spec (`kind=`, `fields=` case convention) matters because it renames every key; enum wire
spellings matter because stored payloads carry the old spelling.

**Identity.** Deterministic derivations and dedupe keys are persisted or re-derived on
replay: workflow journals are keyed by the workflow's stable name and id derivation;
process dispatch ids derive from the process name; timer fires dedupe on a derived
fired-event id; outbox retries coalesce on derived message/outbox ids; intake dedupe
records are keyed by the declared key/policy; pgmq queues live under their physical
names. Changing any of these re-keys persisted state without touching a byte of payload —
the decode axis cannot see it, so the differ needs an explicit identity axis.

### The current differ, verified 2026-07-13

`Keiro.Dsl.Diff` (`keiro-dsl/src/Keiro/Dsl/Diff.hs`) exports `Change` (constructors
`Additive`/`Breaking`, Diff.hs:35-38), `ChangeKind` (node/subject/code/detail,
Diff.hs:40-46), `isBreaking`, and `diffSpecs` (Diff.hs:52-55). `diffSpecs` walks **only**
`NAggregate` nodes (`specAggs`, Diff.hs:57-58) plus removed aggregates
(Diff.hs:118-124). Per aggregate, `eventDiff` (Diff.hs:78-103) classifies:

- version increased (Diff.hs:84-87): additive iff `evUpcastFrom` names `evVersion e - 1`
  — checked only against the NEW spec's own version, never the OLD spec's, so `v1 -> v3`
  with `upcast from v2 = HOLE` is ADDITIVE despite the missing 1→2 rung (finding A3);
- version decreased (Diff.hs:88-89): breaking, but tagged `EvtFieldAddedWithoutBump`
  (finding A7);
- same version (Diff.hs:90-103): compares `eventFieldNames` (Diff.hs:137-141), which
  projects field **names only** — type changes are invisible (finding A1); field removal
  at the same version (Diff.hs:98-99) is breaking but also tagged
  `EvtFieldAddedWithoutBump` (finding A7); deprecation is additive (Diff.hs:101-103), but
  UN-deprecating (deprecated → not) is unreported;
- `enumRemovedFromFields` (Diff.hs:130-131) is a stub returning `[]` under a docstring
  claiming removed constructors classify breaking (finding A2);
- nothing inspects `WireSpec` (finding A5), `NContract`, `NWorkqueue`, `NProcess`
  inputs, or `NWorkflow` (finding A4), nor any identity-bearing field (finding A6).

The grammar surface the differ must cover (all in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`):
`Node` has ten constructors (Grammar.hs:793-804): `NAggregate`, `NProcess`, `NContract`,
`NIntake`, `NEmit`, `NPublisher`, `NWorkqueue`, `NPgmqDispatch`, `NWorkflow`,
`NOperation`. Shared declarations live on `Spec` (Grammar.hs:825-834): `specIds`
(`IdDecl` with `idPrefix`, Grammar.hs:132-137), `specEnums` (`EnumDecl` with per-ctor
wire spellings, Grammar.hs:142-147), `specRules`. Events (`Event`, Grammar.hs:285-300)
carry `evVersion`, `evUpcastFrom :: Maybe (Int, Hole)`, `evDeprecated`, and a body that
is either explicit fields or `fields(Command)` (`EventBody`, Grammar.hs:302-305) — the
indirection means a *command* field type change silently changes an event shape.
`WireSpec` (Grammar.hs:330-335) carries `wireKind`/`wireFields`/`wireSchemaVersion`.
Contracts (Grammar.hs:531-561) carry a discriminator, `(alias, real topic string)`
pairs, and events of typed fields (`typeid "pfx"`/`text`/`int` — no optionality).
Workqueues (Grammar.hs:682-717) carry captured physical/dlq/table names and payload rows
`WqField` (wire name, type, required flag). Processes (Grammar.hs:383-526) carry an
input shape, correlate/saga/derive prefixes, and a timer with `fireAt <field> + <window>`
(Grammar.hs:464-468,496-507). Workflows (Grammar.hs:743-768) carry the stable name
`wfStable`, input fields, output type, id derivation, and a label-matched body.

### The CLI contract and the gate

The `diff` subcommand (parser at app/Main.hs:54-56, `--since` at app/Main.hs:74-75)
resolves the spec to a repo-relative path, fetches the old text with
`git show <ref>:<relpath>` (app/Main.hs:142-158), parses both, prints one line per change
via `renderChange` (app/Main.hs:236-242 — note it hardcodes the word `event` between node
and subject, an aggregate-only assumption that must be generalized), and exits non-zero
iff any change `isBreaking` (app/Main.hs:160-162). Its help text currently reads
"Classify spec changes since a git ref as ADDITIVE/BREAKING; exit non-zero on any
breaking change" — an overclaim while only aggregate events are inspected, and stale once
the WARNING tier exists; both the help text (app/Main.hs:56) and the module haddock of
Diff.hs (Diff.hs:1-17, which falsely claims "Only event and enum deltas are emitted")
must be brought to truth in Milestone 4. The one-line diff descriptions in
`agents/skills/keiro-dsl-authoring/NOTATION.md` (line 206) and
`agents/skills/keiro-dsl-authoring/SKILL.md` (line 69) say "ADDITIVE/BREAKING" and get
the same one-line correction; the full skill refresh is owned by
docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md.

**How the shell gate works.** `keiro-dsl/test/diff-test.sh` (run from the repo root as
`bash keiro-dsl/test/diff-test.sh`) locates the built CLI with `cabal list-bin
keiro-dsl`, creates a throwaway git repo in `mktemp -d`, copies a committed baseline
fixture in as `svc.keiro`, commits it, then overwrites the file with a mutated fixture
and runs `"$EXE" diff --since HEAD "$DEMO/svc.keiro"`, asserting the exit code (non-zero
for red fixtures, zero for green). Each red/green scenario is one numbered case; the
script exits 0 only if every case's classification and exit code are correct. This plan
extends it with new numbered cases in the same pattern.

**Unit-test conventions.** `test/Main.hs` has a `describe "diff (evolution
classification)"` block (test/Main.hs:205-216) whose cases call `diffFixtures old new`
(test/Main.hs:349-356) — parse two committed fixtures, run `diffSpecs`, and match on
`isBreaking`/`ckCode`/`ckSubject`. New classifications follow exactly this pattern.
Fixture naming convention: `<base>-<mutation>.keiro` next to its base (e.g.
`reservation.keiro` / `reservation-fieldadd.keiro` / `reservation-v2.keiro`). Note the
unit suite reads fixtures by relative path (`test/fixtures/...`), so it must be run from
the `keiro-dsl/` package directory: `cd keiro-dsl && cabal run keiro-dsl-test`. Running
it from the repo root produces dozens of phantom file-not-found failures.

### Minimal repro (embedded, self-contained)

Baseline spec (`svc.keiro`), committed to a scratch git repo:

```text
context demo

id  NoteId  prefix=note

enum Color { Red=red Green=green }

aggregate Note
  regs
  states Open
  command AddNote { noteId note:Text color }
  event NoteAdded = fields(AddNote)
  wire kind=ctorName fields=camelCase schemaVersion=1
```

Mutation A1 (field type): change `note:Text` to `note:Int` in `AddNote`. Every stored
`NoteAdded` payload misdecodes (the event's shape comes from the command via
`fields(AddNote)`). Today:

```console
$ keiro-dsl diff --since HEAD svc.keiro ; echo exit=$?
exit=0
```

After this plan (detail prose is implementation-defined; the tier prefix, the
`node facet subject` triple, and the bracketed code are the contract):

```console
$ keiro-dsl diff --since HEAD svc.keiro ; echo exit=$?
BREAKING: Note event-field NoteAdded.note: type changed Text -> Int at the same version v1 [EvtFieldTypeChanged]
exit=1
```

Mutation A2 (enum): `Red=red` to `Red=crimson` — today silent exit 0; after: `BREAKING
... [EnumWireSpellingChanged]`, exit 1. Mutation A5 (wire): `fields=camelCase` to
`fields=snake_case` — today silent exit 0; after: `BREAKING ... [WireSpecChanged]`,
exit 1. Mutation A6 (identity): `prefix=note` to `prefix=nte` — today silent exit 0;
after: `BREAKING ... [IdPrefixChanged]`, exit 1.


## Plan of Work

### Milestone 1 — Restructure into a per-node-family registry, with classification parity

Goal: the differ becomes structurally incapable of silently ignoring a node kind, while
classifying exactly what it classifies today. This is deliberately a pure-refactor
milestone (plus plumbing that later milestones need), so its acceptance is "everything
that passed before still passes, plus the new structural guarantees hold".

Work, in `keiro-dsl/src/Keiro/Dsl/Validate.hs`: append the new `DiagnosticCode`
constructors to the enum at Validate.hs:32-73, in a group headed by a comment marking
them as diff-only (cross-spec) rules — breaking codes `EvtFieldTypeChanged`,
`EvtFieldRemovedSameVersion`, `EvtVersionDecreased`, `EnumCtorRemoved`,
`EnumWireSpellingChanged`, `WireSpecChanged`, `ContractEventRemoved`,
`ContractFieldChanged`, `ContractDiscriminatorChanged`, `ContractTopicChanged`,
`ContractSchemaVersionDecreased`, `WqPayloadFieldChanged`, `ProcessInputChanged`,
`WorkflowShapeChanged`, `WorkflowBodyChanged`, `WorkflowStableNameChanged`,
`IdPrefixChanged`, `DedupeIdentityChanged`, `DerivedIdentityChanged`,
`QueueIdentityChanged`; warning codes `TimerWindowChanged`, `EmitMappingChanged`,
`DecodePostureChanged`, `ProjectionChanged`, `PublisherPolicyChanged`,
`DispatchRetargeted`, `ContractSchemaVersionBumped`, `EventUndeprecated`. (Adding constructors is safe: the
enum has no total case anywhere — `renderDiagnostic` shows codes via `show`.)

Work, in `keiro-dsl/src/Keiro/Dsl/Diff.hs`: add the `Advisory` constructor to `Change`
and an `isAdvisory` helper; add `ckFacet :: !Text` to `ChangeKind` (existing
constructions set facet `"event"`, preserving today's rendered output). Introduce the
registry types and helpers exactly as specified in Interfaces and Dependencies:
`DiffEnv`, `NodeFamily` (deriving `Enum`/`Bounded`), a total `familyOf :: Node ->
NodeFamily`, `FamilyDiff` (`DiffFamily` or `OutOfDiffScope Text`), `familyRegistry`,
`Paired`/`pairByName`. Reimplement `diffSpecs old new` as: shared-declaration changes
(empty in this milestone) followed by a walk of `familyRegistry` applying each
`DiffFamily` to `DiffEnv old new`. Port `aggDiff`/`eventDiff`/`removedEvents`/
`removedAggDiff` verbatim into the `FamAggregate` entry (delete the dead
`enumRemovedFromFields` stub, Diff.hs:130-131 — Milestone 2 replaces it with a real
spec-level enum differ). Register every other family as `OutOfDiffScope` with an honest
interim rationale ("not yet diffed; Milestone N of docs/plans/103 covers this family"),
except `FamOperation`, which gets its permanent rationale now (see Decision Log). Add a
code comment at the registry stating the invariant: every `Node` constructor maps to a
family (`familyOf` is total; `-Wincomplete-patterns` under `-Wall` catches new
constructors) and every family has a registry entry (the unit test catches omissions).

Work, in `keiro-dsl/app/Main.hs`: generalize `renderChange` (app/Main.hs:236-242) to
render `<TIER>: <node> <facet> <subject>: <detail> [Code]` with tiers `ADDITIVE`,
`WARNING` (for `Advisory`), `BREAKING`; keep the exit rule "non-zero iff any
`isBreaking`" (app/Main.hs:162).

Work, in `keiro-dsl/test/Main.hs`: add a registry-completeness case (every `NodeFamily`
in `[minBound .. maxBound]` has exactly one entry; every `OutOfDiffScope` rationale is
non-empty) and keep the three existing diff cases green unchanged.

Result and proof: `cabal build keiro-dsl` clean; `cd keiro-dsl && cabal run
keiro-dsl-test` green; `bash keiro-dsl/test/diff-test.sh` from the repo root passes both
existing cases with byte-identical classifications.

### Milestone 2 — Aggregate-family decode soundness (A1, A2, A3, A5, A7)

Goal: every decode-relevant aggregate change is classified, with the correct code.

Work, in the `FamAggregate` differ: replace `eventFieldNames` with a signature
projection `eventFieldSigs :: Aggregate -> Event -> [(Name, Maybe Name)]` (name paired
with declared type, `Nothing` meaning "reuses the declared type elsewhere",
Grammar.hs:262-269) — resolved through `EventFromCommand` so command field type changes
propagate. At an unchanged version: added names stay `EvtFieldAddedWithoutBump` (true
meaning restored); removed names become `EvtFieldRemovedSameVersion`; a name present on
both sides with a different type becomes `EvtFieldTypeChanged` (facet `event-field`,
subject `<Event>.<field>`). Version decrease becomes `EvtVersionDecreased`. Rewrite the
version-increase arm to anchor on the OLD spec: additive iff `evVersion new == evVersion
old + 1` AND `evUpcastFrom new` names `evVersion old`; any larger jump is breaking
`EvtVersionMissingUpcaster` with a detail naming the missing rung(s) — the notation can
only carry one `upcast from` clause per event (Grammar.hs:290-293), so a multi-version
jump can never carry a complete chain, and the runtime's `mkCodec` would reject the
resulting codec (`CodecUpcasterChainIncomplete`, Codec.hs:142-165). Emit the
un-deprecation advisory (`Advisory`, `EventUndeprecated`) when `evDeprecated old && not
(evDeprecated new)`. Normalize `Maybe WireSpec` to the defaults (`kind=ctorName
fields=camelCase`) on both sides and emit breaking `WireSpecChanged` when effective
`wireKind` or `wireFields` differ.

Work, spec-level: implement the shared-declaration differ over `specEnums` — for an enum
present on both sides, a removed constructor is breaking `EnumCtorRemoved` and a kept
constructor whose wire spelling changed is breaking `EnumWireSpellingChanged` (detail
names event fields and registers whose declared type is the enum, when resolvable); an
added constructor is additive; a removed enum reports `EnumCtorRemoved` for each of its
constructors.

Fixtures (all under `keiro-dsl/test/fixtures/`, mutations of `reservation.keiro` unless
noted; red means BREAKING/exit 1, green means exit 0): `reservation-fieldtype.keiro`
(red, `commandId` gains `:Int` in `TransferReservationConfirmed`),
`reservation-cmdfieldtype.keiro` (red, `lifeCriticalOverride:Bool` becomes `:Int` in the
command that `TransferReservationCreated` takes `fields(...)` from),
`reservation-fieldremove.keiro` (red, drop `hospitalId` from
`TransferReservationConfirmed`), `reservation-v3-dangling.keiro` (red, `v3` with `upcast
from v2 = HOLE` — the A3 flip from today's false ADDITIVE),
`reservation-enumdrop.keiro` (red, `YellowTag` removed from `PatientAcuity` and from the
`lifeCriticalOverride` rule cases so the fixture stays check-clean),
`reservation-enumwire.keiro` (red, `RedTag=red` to `RedTag=crimson`),
`reservation-enumadd.keiro` (green, `BlackTag=black` added plus a rule case),
`reservation-wire.keiro` (red, `fields=snake_case`), `reservation-deprecated.keiro`
(`TransferReservationConfirmed` marked `deprecated event` and its `emit` removed from
the `Held` transition — used forward for the additive-deprecation green case and
*reversed* for the un-deprecation warning). Version decrease needs no new fixture: diff
old=`reservation-v2.keiro`, new=`reservation.keiro`.

Unit tests: one `diffFixtures` case per new code asserting `isBreaking` (or not) and the
exact `ckCode`. Gate: extend `diff-test.sh` with case 3 (field type change breaking) and
case 4 (`reservation-v3-dangling.keiro` breaking — this case FAILS against today's
binary, proving the fix).

### Milestone 3 — Cross-node decode surface (A4)

Goal: contract, workqueue payload, process input, and workflow input/output/body changes
classify. Contract coverage is the highest-priority item in this plan: a contract is a
cross-service Kafka schema that OTHER services decode, so its blast radius exceeds any
single service's log.

Work, `FamContract`: pair contracts by `ctrName`; removed contract event → breaking
`ContractEventRemoved`; per paired event, removed field or changed type → breaking
`ContractFieldChanged`; added field at unchanged `ctrSchemaVersion` → breaking
`ContractFieldChanged`, at increased version → advisory `ContractSchemaVersionBumped`;
`ctrDiscriminator` change → breaking `ContractDiscriminatorChanged`; a topic alias whose
real topic string changed → breaking `ContractTopicChanged`; `ctrSchemaVersion` decrease
→ breaking `ContractSchemaVersionDecreased`; new events/topics additive.

Work, `FamWorkqueue` (decode half): pair by `wqName`; per payload field (matched by
`wqfName`): wire-name change, type change, removal, required flip false→true, or a new
*required* field → breaking `WqPayloadFieldChanged` (queued jobs persisted in the pgmq
table misdecode on consume); a new non-required field or a required→optional flip →
additive. `wqPayloadName` is Haskell-side only (not wire-visible) — noted in a code
comment, not diffed.

Work, `FamProcess` (decode half): pair by `procId`; any input field addition, removal,
or type change → breaking `ProcessInputChanged` (facet `input-field`; the input shape is
the generated decoder for the source events, and the notation has no versioning surface
for it — the detail says to version at the source). `inName` is Haskell-side only.

Work, `FamWorkflow` (decode half): pair by `wfId`; `wfInputFields` add/remove/type
change or `wfOutput` change → breaking `WorkflowShapeChanged` (journaled inputs and
persisted outcomes of in-flight workflows re-decode on replay). Body comparison goes
through the exported `classifyWorkflowBody :: WorkflowNode -> WorkflowNode -> [Change]`:
in this plan, any difference in the `wfBody` item lists (labels, kinds, result types,
order, count) yields breaking `WorkflowBodyChanged`, detail pointing at `patch` support
arriving via docs/plans/109-extend-keiro-dsl-node-coverage-pgmq-ordering-and-provisioning-snapshot-policy-and-workflow-patch-and-continue-as-new.md.

Fixtures: from `contract.keiro` — `contract-eventdrop.keiro` (red),
`contract-fieldtype.keiro` (red, `redCount: int` to `text`), `contract-fieldadd.keiro`
(red, new field at `schemaVersion 1`), `contract-bump-fieldadd.keiro` (WARNING/exit 0,
same field plus `schemaVersion 2`; reversed pair gives the
`ContractSchemaVersionDecreased` red unit case), `contract-topic.keiro` (red, real topic
string changed), `contract-discriminator.keiro` (red), `contract-eventadd.keiro`
(green). From `reservation-work.keiro` — `reservation-work-wirename.keiro` (red,
`"reservation_id"` to `"reservationId"`), `reservation-work-fieldtype.keiro` (red,
`bool` to `text`), `reservation-work-optfield.keiro` (green, adds `note -> "note" text`
without `required`), `reservation-work-reqfield.keiro` (red, adds a `required` field).
From `hospital-surge.keiro` — `hospital-surge-inputtype.keiro` (red,
`availableIcuBeds:Int` to `:Text`). From `workflow.keiro` — `workflow-output.keiro`
(red), `workflow-inputfield.keiro` (red, `hospitalId:Id` to `:Text`),
`workflow-body.keiro` (red, a step relabeled), `workflow-stepadd.keiro` (red, a trailing
`step notify-ops -> OpsNote` appended).

Unit tests per code as in Milestone 2; `diff-test.sh` case 5: contract event removal is
breaking (fails against today's binary).

### Milestone 4 — Identity surface (A6), CLI and doc truth, full gate sweep

Goal: identity-bearing changes classify per the Decision Log; the CLI, module haddock,
and skill one-liners tell the truth; the shell gate exercises all three tiers.

Work, shared declarations: `idPrefix` change on a paired `IdDecl` → breaking
`IdPrefixChanged`.

Work, per family (identity halves): `FamWorkflow` — `wfStable` change → breaking
`WorkflowStableNameChanged`; `wfIdField`/`wfIdVia` change → breaking
`DerivedIdentityChanged`. `FamProcess` — `procName`, `sagaStreamPrefix`, correlate
`via`, timer `idePrefix`, fired-event-id `idePrefix` → breaking
`DerivedIdentityChanged`; `faWindow` or `faField` change → advisory
`TimerWindowChanged`. `FamIntake` — `inkDedupeKey`/`inkDedupePolicy` → breaking
`DedupeIdentityChanged`; `DecodeSpec` change → advisory `DecodePostureChanged`.
`FamEmit` — derive prefix changes → breaking `DerivedIdentityChanged`; map
rows/`emSkip`/`emDiscriminant`/`emKey` changes → advisory `EmitMappingChanged`.
`FamPublisher` — `pubOutboxField` → breaking `DerivedIdentityChanged`; `pubOrdering` →
advisory `PublisherPolicyChanged`; `maxAttempts`/`backoff` remain out of scope (code
comment). `FamWorkqueue` — `wqLogical`/`wqPhysical`/`wqDlq`/`wqTable` change → breaking
`QueueIdentityChanged`; retry tuning and dispositions out of scope (code comment).
`FamPgmqDispatch` — any dedup surface change → breaking `DedupeIdentityChanged`;
retargeting `source readModel` or `enqueue to` → advisory `DispatchRetargeted` (facet
`retarget`; see Decision Log). `FamAggregate` — projection table/key/status-map change
→ advisory `ProjectionChanged` (superseded by docs/plans/107's read-model family
differ).

Work, docs and CLI: rewrite the Diff.hs module haddock to describe the two axes, the
three tiers, and the registry invariant; update the `diff` help text (app/Main.hs:56) to
"Classify spec changes since a git ref as ADDITIVE/WARNING/BREAKING over the decode and
identity surface; exit non-zero on any BREAKING change"; update
`agents/skills/keiro-dsl-authoring/NOTATION.md:206` and
`agents/skills/keiro-dsl-authoring/SKILL.md:69` to say `ADDITIVE/WARNING/BREAKING`.

Fixtures: `workflow-rename.keiro` (red), `workflow-idfield.keiro` (red, `id from
input.reservationId` to `input.hospitalId`), `reservation-idprefix.keiro` (red,
`prefix=rsv` to `prefix=resv`), `intake-dedupepolicy.keiro` (red, policy renamed),
`intake-dedupekey.keiro` (red, `key messageId` to `key idempotencyKey`),
`intake-decode.keiro` (WARNING/exit 0, `body strict` to `body lenient`),
`hospital-surge-procname.keiro` (red), `hospital-surge-timerid.keiro` (red, timer id
prefix changed), `hospital-surge-window.keiro` (WARNING/exit 0, `+ 5m` to `+ 10m`),
`emit-mapchange.keiro` (WARNING/exit 0, `"released"` remapped),
`emit-derive.keiro` (red, `derive "msg"` to `derive "msg2"`),
`emit-outboxfield.keiro` (red, `outboxId stable from messageId` to `from incidentId`),
`emit-ordering.keiro` (WARNING/exit 0, `ordering PerKeyHeadOfLine` to `Unordered`),
`reservation-work-rename.keiro` (red, logical/physical/dlq/table renamed consistently),
`reservation-work-dedupkey.keiro` (red, dispatch `dedup key` changed),
`reservation-work-retarget.keiro` (WARNING/exit 0, `enqueue to` retargeted — the fixture
also renames the target workqueue so the spec stays check-clean),
`reservation-projection.keiro` (WARNING/exit 0, a status-map value changed).

Unit tests per code; `diff-test.sh` gains: case 6 workflow stable-name rename breaking,
case 7 id-prefix change breaking, case 8 timer-window change prints a `WARNING:` line
AND exits 0 (assert both — this pins the tier/exit contract).

Result and proof: full sweep in Validation and Acceptance passes end to end.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless a
`cd` is shown.

Build and locate the CLI:

```bash
cabal build keiro-dsl
EXE="$(cabal list-bin keiro-dsl)"
```

Run the unit suite (MUST be from the package directory — fixture paths are relative):

```bash
cd keiro-dsl && cabal run keiro-dsl-test
```

Expected tail on success:

```text
Finished in ... seconds
NN examples, 0 failures
```

Run the diff gate:

```bash
bash keiro-dsl/test/diff-test.sh
```

Expected final line: `PASS: diff --since gates breaking event changes` (Milestone 1) and
the extended pass message once new cases land (update the script's final echo to
`PASS: diff --since gates the decode and identity surface`).

Manual before/after repro (the same scratch-repo pattern the gate uses):

```bash
D="$(mktemp -d)"; git -C "$D" init -q
cp keiro-dsl/test/fixtures/reservation.keiro "$D/svc.keiro"
git -C "$D" add svc.keiro
git -C "$D" -c user.email=t@t -c user.name=t commit -qm baseline
cp keiro-dsl/test/fixtures/reservation-fieldtype.keiro "$D/svc.keiro"
"$EXE" diff --since HEAD "$D/svc.keiro"; echo "exit=$?"
```

Before this plan the last two lines print nothing and `exit=0`. After Milestone 2:

```text
BREAKING: Reservation event-field TransferReservationConfirmed.commandId: type changed (declared) -> Int at the same version v1 [EvtFieldTypeChanged]
exit=1
```

Warning-tier repro after Milestone 4 (must print and still exit 0):

```bash
cp keiro-dsl/test/fixtures/hospital-surge.keiro "$D/svc.keiro"
git -C "$D" add svc.keiro && git -C "$D" -c user.email=t@t -c user.name=t commit -qm surge
cp keiro-dsl/test/fixtures/hospital-surge-window.keiro "$D/svc.keiro"
"$EXE" diff --since HEAD "$D/svc.keiro"; echo "exit=$?"
```

```text
WARNING: HospitalSurge timer surgeFollowUp: fireAt window changed 5m -> 10m (already-scheduled timers keep their persisted deadline) [TimerWindowChanged]
exit=0
```

At every stopping point: update Progress, commit with a conventional message, e.g.
`feat(dsl-diff): restructure diff into a per-node-family registry` /
`feat(dsl-diff): classify field type, enum, wire-spec, and upcaster-gap changes` /
`test(dsl-diff): red/green fixtures for the identity surface`.


## Validation and Acceptance

Acceptance is behavioral, per tier and per code. A classification is accepted when its
committed red fixture makes the CLI print a line containing its bracketed code and exit
1 (`BREAKING`), or print a `WARNING:` line and exit 0 (advisory), or print
nothing-or-`ADDITIVE` and exit 0 (green) — via the scratch-git flow above, and when the
corresponding `diffFixtures` unit case asserts the exact `ckCode`.

1. Unit suite: `cd keiro-dsl && cabal run keiro-dsl-test` — 0 failures. New cases exist
   in the `describe "diff (evolution classification)"` block for every new
   `DiagnosticCode` listed in Milestone 1, each pinned to a committed fixture pair.
   The registry test fails if any `NodeFamily` lacks an entry or any `OutOfDiffScope`
   rationale is empty — verify it is red-capable by commenting out one entry locally and
   watching it fail before restoring.
2. Shell gate: `bash keiro-dsl/test/diff-test.sh` from the repo root — exits 0 with all
   numbered cases OK. Cases 4 (dangling upcaster) and 5 (contract event removal) MUST
   fail when pointed at a pre-plan binary; note that check in Surprises & Discoveries
   when performed.
3. Exit-code contract: case 8 proves a WARNING prints while exiting 0; existing cases 1
   and 2 prove the breaking/additive exits are unchanged.
4. CLI help: `"$EXE" diff --help` mentions ADDITIVE/WARNING/BREAKING and both surfaces.
5. Scope guard: `git status` shows changes only under `keiro-dsl/`,
   `agents/skills/keiro-dsl-authoring/`, and `docs/` — never `keiro/`, `keiro-core/`,
   `keiro-pgmq/`.
6. No regression elsewhere: the parse/pretty round-trip property and all pre-existing
   unit cases still pass; the conformance suites are untouched by this plan (the differ
   has no scaffold output) — spot-run one, e.g. `cabal test keiro-dsl-conformance`, to
   confirm nothing in the shared library broke compilation.


## Idempotence and Recovery

Every step is safe to repeat. The differ is a pure function of two parsed specs; there
are no migrations, no generated files, and no on-disk state — re-running builds, tests,
and the shell gate is always non-destructive (the gate creates and removes its own
`mktemp -d` scratch repo; on abnormal exit the `trap ... EXIT` cleans up, and a leaked
temp dir is harmless). Fixture files are additive; re-copying them changes nothing.

The one ordering hazard: Milestone 1 changes `ChangeKind` (new `ckFacet` field) and
`Change` (new constructor), which `keiro-dsl/app/Main.hs` and `keiro-dsl/test/Main.hs`
both consume — do the library, app, and test edits in the same commit so the package
never fails to build at a commit boundary. If a milestone must be abandoned midway,
`git revert` of its commits restores a working gate, because every milestone ends with
the full suite green; never leave `familyRegistry` with a placeholder `DiffFamily` that
returns `[]` for a family documented as covered — use `OutOfDiffScope` with an interim
rationale instead, so the registry never lies.


## Interfaces and Dependencies

No new package dependencies: `keiro-dsl`'s library depends on `base`, `containers`,
`megaparsec`, `parser-combinators`, `prettyprinter`, `text` (keiro-dsl.cabal:42-48) and
this plan stays within them. All work is in `Keiro.Dsl.Diff`, `Keiro.Dsl.Validate` (enum
extension only), `keiro-dsl/app/Main.hs`, `keiro-dsl/test/Main.hs`, fixtures, and
`keiro-dsl/test/diff-test.sh`.

At the end of Milestone 1, `Keiro.Dsl.Diff` exports (and keeps exporting — this is the
extension surface later plans build on):

```haskell
module Keiro.Dsl.Diff (
    Change (..),        -- Additive | Advisory | Breaking, each carrying ChangeKind
    ChangeKind (..),    -- ckNode, ckFacet, ckSubject, ckCode :: Maybe DiagnosticCode, ckDetail
    isBreaking,
    isAdvisory,
    diffSpecs,          -- :: Spec -> Spec -> [Change]  (old, then new)
    -- The per-node-family registry (the docs/plans/107/108/109 extension point)
    DiffEnv (..),       -- DiffEnv { deOld :: !Spec, deNew :: !Spec }
    NodeFamily (..),    -- FamAggregate | FamProcess | FamContract | FamIntake | FamEmit
                        -- | FamPublisher | FamWorkqueue | FamPgmqDispatch
                        -- | FamWorkflow | FamOperation
                        --   deriving stock (Eq, Ord, Show, Enum, Bounded)
    familyOf,           -- :: Node -> NodeFamily      (total case, no wildcard)
    FamilyDiff (..),    -- DiffFamily (DiffEnv -> [Change]) | OutOfDiffScope Text
    familyRegistry,     -- :: [(NodeFamily, FamilyDiff)]  (exactly one entry per family)
    Paired (..),        -- Paired { prMatched :: [(n, n)], prAdded :: [n], prRemoved :: [n] }
    pairByName,         -- :: (Node -> Maybe n) -> (n -> Name) -> DiffEnv -> Paired n
    classifyWorkflowBody, -- :: WorkflowNode -> WorkflowNode -> [Change]
) where
```

Semantics each milestone must preserve: `diffSpecs old new` equals the shared-declaration
changes (over `specIds`/`specEnums`; `specRules` excluded with written rationale) plus
the concatenation, in `NodeFamily` order, of every `DiffFamily` applied to
`DiffEnv old new`. `familyOf` has one arm per `Node` constructor and no wildcard, so a
constructor added by a later plan is an `-Wincomplete-patterns` warning under the
package's `-Wall` (keiro-dsl.cabal:21-22) until classified; the unit suite fails until
`familyRegistry` gains the matching entry.

Extension contract for sibling plans (integration statements only):

- docs/plans/107-add-a-first-class-read-model-node-with-registration-schema-and-consistency-to-keiro-dsl.md
  and docs/plans/108-add-a-router-node-and-rejection-and-poison-policy-surfaces-to-keiro-dsl.md
  each add a `Node` constructor; they extend `familyOf` with a new `NodeFamily` value
  and register a `DiffFamily` covering their construct's decode surface (read-model
  version/shape-hash; router source input shape) and identity surface (read-model
  name/table/subscription; router stable name and key derivation), reusing the codes
  introduced here (`DerivedIdentityChanged`, `DedupeIdentityChanged`,
  `QueueIdentityChanged`) where the semantics match, or adding codes to the
  `DiagnosticCode` enum in `Keiro.Dsl.Validate` in the same diff-only group. Plan 107
  also retires this plan's interim `ProjectionChanged` advisory in favor of its
  read-model family differ.
- docs/plans/109-extend-keiro-dsl-node-coverage-pgmq-ordering-and-provisioning-snapshot-policy-and-workflow-patch-and-continue-as-new.md
  extends the `FamWorkqueue` differ with the pgmq ordering/provisioning surfaces and the
  `FamAggregate` differ with the snapshot-policy surface, and replaces the body of
  `classifyWorkflowBody` so that body edits guarded by its new `patch` construct (and
  `continueAsNew` rotations) classify as safe instead of `WorkflowBodyChanged` — which
  is why that function is exported as a named seam rather than inlined.
- docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md
  owns everything this plan declares out-of-diff-scope (single-spec reference and
  disposition rules); the boundary is: `check` validates one spec, `diff` compares two.
- docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md
  owns the full authoring-skill refresh; this plan only corrects the two
  `ADDITIVE/BREAKING` one-liners that its own tier change falsifies.

Runtime modules referenced for semantics only (never modified):
`keiro-core/src/Keiro/Codec.hs` (decode/migration semantics the decode axis mirrors).
