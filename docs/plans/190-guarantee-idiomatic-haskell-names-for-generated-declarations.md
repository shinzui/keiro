---
id: 190
slug: guarantee-idiomatic-haskell-names-for-generated-declarations
title: "Guarantee idiomatic Haskell names for generated declarations"
kind: exec-plan
created_at: 2026-08-04T04:34:58Z
intention: "intention_01kz5gbdh9e1nr20r3djzh0pe3"
---

# Guarantee idiomatic Haskell names for generated declarations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro accepts logical DSL names such as `service_oncall`, but its Haskell generator currently
uses several unrelated approximations when those names become source identifiers. A read-model
module uppercases one character and becomes `Service_oncall`, while a nearby value splits on
underscores and becomes `serviceOncall`. The result compiles in some cases, but it is not an
idiomatic or coherent generated API, and two distinct DSL names can converge only after files
have already been planned.

After this work, every name that Keiro generates from a logical DSL declaration passes through
one checked naming plan. Module segments, types, and constructors are UpperCamelCase; values and
record selectors are lowerCamelCase. Thus `readmodel reaction_history` produces a
`ReactionHistory` module segment and `reactionHistoryProjection`, while the table string
`"reaction_history"`, SQL schema, registry identity, subscription, event tag, queue name, and
other external spellings remain unchanged. `keiro-dsl check` rejects unsafe normalization and
collisions before scaffolding writes anything.

The change also gives existing users a safe upgrade path. A scaffold based on an older record
first reports the exact generated and create-once Haskell source moves it needs. With an explicit
apply flag, Keiro moves the old files into a recoverable backup, rewrites only exact Haskell
module references in hand-owned source, emits the new tree, and writes a manifest and scaffold
record containing only the new module names. A user can see the result by scaffolding
`keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro`: the output contains
`Generated.IncidentPaging.ServiceOncall.ReadModel`, never `Service_oncall`, while its generated
metadata still names the SQL table `service_oncall` and the existing subscription
`incident-paging-service-oncall-sub`.


## Progress

- [x] (2026-08-04 13:47Z) Add the central ASCII generated-Haskell name model, shared keyword
  policy, checked name wrappers, naming edition, and private Hspec/QuickCheck component. The five
  pinned casing pairs and 20 focused examples pass.
- [x] (2026-08-04 13:47Z) Add append-only unsafe-normalization, reserved-occurrence, and normalized
  collision diagnostics with primary and related source locations; focused ordinary validation
  examples pass.
- [x] (2026-08-04 13:47Z) Route scaffold, aggregate-type, binding-explanation, and import casing
  through the central derivation, remove the literal `_renderEventTypes`, update workqueue skeleton
  logical names, and prove a fresh incident-paging scaffold uses `ServiceOncall`/`serviceOncall`
  while retaining its snake_case SQL and subscription strings.
- [ ] Complete the typed occurrence inventory across every emitter and replace the current
  module-declaration/top-level-underscore defense with the complete planned-occurrence source
  audit and its mutation test.
- [x] (2026-08-04 13:47Z) Extend single-file and workspace records additively with naming-edition
  and stable module-role history; missing rows parse as legacy naming.
- [x] (2026-08-04 13:47Z) Add explicit `--apply-name-migrations` refusal/apply behavior for both
  scaffold paths, token-aware code-only module rewriting, deterministic backups, current-only
  records/manifests, idempotent reruns, and a four-example single/two-member regression. Normal
  workspace preflights complete before any source move.
- [ ] Add content digests, same-filesystem prepared temporary files, and complete crash-state
  recovery/conflict evidence to the source-move executor.
- [ ] Classify source edits that change only generated Haskell as consumer-build advisories while
  preserving replay, wire, SQL, and runtime identity classifications.
- [ ] Regenerate and compile the conformance corpus, update authoring and upgrade documentation,
  amend the relevant ADRs, and run the complete repository gates.


## Surprises & Discoveries

- Observation: The clean baseline ordinary suite passed with 539 examples and zero failures in
  148.1563 seconds; a baseline incident-paging scaffold reproduced the active
  `Service_oncall` generated and create-once paths.
  Evidence: `cabal test keiro-dsl-test` and the disposable scaffold commands in Concrete Steps.

- Observation: Most renderer inconsistency was reachable through the three exported casing
  helpers in `Scaffold`, so centralizing those immediately corrected modules and helpers in
  downstream harness and facade emitters without touching external spelling expressions.
  Evidence: the disposable incident-paging scaffold emitted `ServiceOncall` paths and
  lowerCamelCase helpers while retaining `tableName = "service_oncall"`, schema
  `incident_paging`, and subscription `incident-paging-service-oncall-sub`.

- Observation: A workspace migration wrapper that applied prepared moves before invoking the
  existing workspace preflights would violate the established detection-before-write contract.
  The prepared moves therefore have to cross the seam and execute only after golden, generated
  banner, and conformance-package preflights all succeed.
  Evidence: `executeWorkspaceScaffoldBase` now receives prepared moves and applies them only in
  its refusal-free branch; the focused workspace regression passes.


## Decision Log

- Decision: Treat generated Haskell naming as a versioned presentation contract, not as a Keiro
  source-language, wire, replay, SQL, or runtime-identity contract.
  Rationale: The requested correction changes source paths and occurrences for an unchanged
  semantic graph. Coupling it to `language keiro-dsl 4` would contradict the released-language
  boundary in ADR 0016 and would incorrectly contaminate fold and persisted identities. The
  generated naming edition belongs in manifests and scaffold history so a generator upgrade is
  observable and migratable.
  Date: 2026-08-03

- Decision: Derive both cases from one ASCII word segmentation. Underscores and hyphens separate
  words where that source category admits them; lower-to-upper and acronym-to-word boundaries are
  recognized inside a segment; acronym spelling is preserved in UpperCamelCase and lowered as a
  unit at the start of lowerCamelCase. Leading, trailing, or repeated underscores are errors.
  Rationale: This makes `foo_bar` and `fooBar` converge deliberately to `FooBar`/`fooBar`, turns
  `HTTP_server2` into `HTTPServer2`/`httpServer2`, preserves already-idiomatic `ThingID` as
  `ThingID`/`thingID`, and refuses empty segments instead of silently erasing information.
  Date: 2026-08-03

- Decision: Preserve explicit consumer-owned Haskell package, module, type, constructor, and
  qualified-value references byte-for-byte after validating them with the same name types; only
  logical Keiro names are normalized.
  Rationale: A `mapped` or nominal `haskell` clause identifies source owned outside the generator.
  Re-casing it would point at a different API and violate ADR 0012. SQL columns, wire keys, event
  tags, queue names, registry names, schema names, table names, and provenance text are likewise
  external or semantic data, not Haskell occurrences.
  Date: 2026-08-03

- Decision: Make the complete checked occurrence plan the only source from which renderers obtain
  generated identifiers, and retain a final lexical audit as defense in depth.
  Rationale: Merely sharing `pascal` and `lowerFirst` would leave suffix construction, module-path
  assembly, helper names, and namespace collisions distributed across renderers. A complete plan
  catches collisions during `check`; the audit detects a literal template name or raw interpolation
  that accidentally bypasses the typed boundary.
  Date: 2026-08-03

- Decision: Require an explicit `--apply-name-migrations` scaffold flag when a prior record proves
  that normalization moves source files. Preserve old bytes in a deterministic backup and rewrite
  hand-owned source with a token-aware exact-module-reference transform.
  Rationale: Create-once modules may contain application logic, so silently creating a second stub
  or doing an unrestricted text replacement is unsafe. A dry refusal makes the move reviewable;
  a recoverable apply path can update module declarations, imports, and qualified references while
  leaving comments and string/character literals untouched.
  Date: 2026-08-03

- Decision: Add no package dependency for casing or source migration.
  Rationale: The parser already restricts logical identifiers to ASCII, and the repository already
  depends on `base`, `text`, `containers`, `directory`, and `filepath`. A small total segmenter and
  lexer over the generator's constrained Haskell output are easier to freeze and test than an
  extra library whose acronym or Unicode behavior may change.
  Date: 2026-08-03

- Decision: Expose a stable `moduleRole` projection derived from the existing module origin and
  artifact family instead of adding fields to the widely constructed public `ScaffoldModule`
  record. Persist that role in additive scaffold/workspace record rows.
  Rationale: Role pairing needs a stable semantic key, but changing the public record constructor
  would impose unrelated source churn on callers and fixtures. The projected role is independent
  of the cased path and has focused migration-pairing coverage.
  Date: 2026-08-04

- Decision: Keep record headers at v1, render `naming-edition idiomatic-v1` and role rows for every
  new run, and interpret their absence as `legacy-v1`.
  Rationale: Naming presentation history is additive and older readers already ignore unknown
  rows. This preserves the established forward-compatible persistence contract while giving the
  migration planner exact current evidence.
  Date: 2026-08-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The source request is
`docs/improvement-requests/guarantee-idiomatic-haskell-names-for-generated-declarations.md`
(`IR-16`). It records the concrete failure: `readmodel service_oncall` currently yields the
module component `Service_oncall`, even though some values from the same declaration become
`serviceOncall`. It also records the downstream occurrence in
`mori://shinzui/mori/plans/175-rewrite-the-reaction-aggregate-as-a-functional-execution-lifecycle`.
That URI is intentionally retained even if a local Mori registry snapshot cannot yet resolve
the artifact.

A *logical name* is an identifier stored in the Keiro semantic graph, such as `rmName` for a
read model or `aggName` for an aggregate. An *external spelling* is text persisted or exchanged
outside generated Haskell: examples include an event discriminator, a JSON key, a queue name, a
PostgreSQL schema/table/column, a read-model registry/subscription name, a canonical mapping
identity, or a source-language fingerprint segment. A *generated occurrence* is a Haskell module
segment, type, data constructor, value, or record selector emitted from a logical name. An
*occurrence space* is the scope in which two generated names conflict: a full case-folded module
path; a type, constructor, or top-level value namespace within one module; or a record field set
within one generated record where `DuplicateRecordFields` deliberately permits the same selector
on different records.

`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs` accepts identifiers made from ASCII letters, digits, and
underscores, including leading underscores. Its comment explicitly describes the grammar as
CamelCase or snake_case. `keiro-dsl/src/Keiro/Dsl/Validate.hs` then applies the older legality
model: type-like aggregate, ID, enum, and event names must already be uppercase, fields may retain
underscores, and node families that call `pascal` are rejected only when they start with an
underscore. The three diagnostic codes `IdentHaskellKeyword`, `IdentNotConstructorSafe`, and
`VertexCtorCollision` therefore prevent some invalid Haskell but do not describe normalization or
collisions after normalization. `Diagnostic` currently carries one line only, while
`WorkspaceDiagnostic` in `keiro-dsl/src/Keiro/Dsl/Workspace.hs` can render a primary location plus
secondary notes from other members.

The duplication is concentrated but not confined to
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`. Its exported `pascal` uppercases only one character,
`lowerFirst` lowercases only one character, and queue/read-model helpers separately split on
underscores. `genPrefixFor`, `holePrefixFor`, `ctxPascalOf`, aggregate resolution, nominal and
structural modules, contracts, inboxes, publishers, workqueues, read models, routers, processes,
and generated helper declarations all interpolate raw `Text`. The same raw-name flow continues in
`keiro-dsl/src/Keiro/Dsl/Harness.hs` and `keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs` for node
harnesses and the service facade. `keiro-dsl/src/Keiro/Dsl/ExplainBindings.hs` and
`keiro-dsl/src/Keiro/Dsl/AggregateType.hs` contain additional local capitalization helpers.

`keiro-dsl/src/Keiro/Dsl/HaskellImport.hs` is the existing typed presentation boundary for
consumer imports. It validates raw module and occurrence text and allocates deterministic aliases,
but it owns a second Haskell-keyword list and accepts `Text`, so it cannot prove that an occurrence
came from the checked generator naming plan. This work should reuse its namespace distinction and
alias algorithm while replacing its duplicated lexical checks with the new name types. It must
continue to preserve complete consumer-owned module names and types, as required by
[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md).

`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` assembles all modules, runs pure pre-write refusals, checks
case-folded paths and generated banners, writes overwriteable `Generated` modules, skips existing
`HoleStub` modules, and records prior paths. Its `staleAgainst` function reports but never removes
old files. `keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` stores file kind/path rows in a forward-
compatible v1 text format; unknown rows are ignored. Whole-service equivalents live in
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs`. Workspace rows already retain member ownership, but
neither record format stores a generated-Haskell naming edition or a stable module-role key.
[ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
requires detection before writes, generated provenance checks, non-destructive stale handling, and
create-once ownership. The explicit source-move workflow in this plan must amend that decision; it
must not weaken its ordinary stale or adoption rules.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` and `keiro-dsl/src/Keiro/Dsl/WorkspaceDiff.hs` classify semantic
changes over compatibility-vector axes. The existing `ConsumerBuild` axis is exactly where a
generated-only name change belongs. `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` separately compares
fold and replay surfaces; Haskell presentation must remain absent from that surface. The mapped
differ in `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs` already pairs some renamed record fields by their
stable wire key, but currently emits no build finding when only the Haskell selector changes.
Workqueue diffing explicitly comments that `wqPayloadName` is generated Haskell, then ignores a
change to it. These are concrete seams for the new source/build-only finding.

`keiro-dsl/src/Keiro/Dsl/Skeleton.hs` currently teaches snake_case logical names in the workqueue
skeleton. Many checked-in paths under `keiro-dsl/test/conformance-*` consequently contain module
segments such as `Reservation_work`, `Transfer_decisions`, `Accepted_transfer_needs`,
`Service_oncall`, `Hospital_load`, `Alpha_view`, and `Beta_view`. Several matching create-once
`ReadModelHoles.hs` files contain filled or hand-edited source and import the old generated module
paths. They are migration fixtures, not disposable generated output. Test components and module
inventories are declared throughout `keiro-dsl/keiro-dsl.cabal`; `cabal test keiro-dsl` runs the
ordinary test suite and every `keiro-dsl-conformance-*` suite.

The local ADR scan found five relevant decisions. [ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
keeps consumer Haskell references distinct from semantic and wire identity and requires one import
plan per module. [ADR 0014](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
makes module ownership deterministic and rejects case-folded workspace path collisions.
[ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
defines history, create-once preservation, and detection-before-write behavior.
[ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
keeps source provenance and presentation outside the semantic graph and freezes released language
contracts. [ADR 0019](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
makes the generated manifest the explicit Haskell compilation contract and excludes create-once
source from automatic normalization. ADRs 0012, 0015, and 0019 need amendments during
implementation; the plan remains self-contained rather than requiring an implementer to infer the
design from them.


## Plan of Work

### Milestone 1: Freeze and check one naming model

Add the private module `keiro-dsl/src/Keiro/Dsl/HaskellName.hs` and list it in the library's
`other-modules` in `keiro-dsl/keiro-dsl.cabal`. It owns the single Haskell keyword set, checked
UpperCamelCase and lowerCamelCase occurrence types, checked module segments and full module names,
the deterministic ASCII word segmenter, stable name-site keys, occurrence-space keys, diagnostics,
and `HaskellNamePlan`. Do not add a casing dependency.

The segmenter first rejects a leading, trailing, or repeated `_`. It splits `_` and, only for
wire-word sources such as context, `-`; it also recognizes a lower/digit-to-upper boundary and an
acronym boundary before the last uppercase letter followed by lowercase text. It never drops an
input character. For UpperCamelCase, capitalize each word's first letter and preserve the rest;
for lowerCamelCase, lowercase the first word's initial, or its complete leading acronym run, then
append the upper words. Pin at least these pairs in tests:

```text
foo_bar        -> FooBar        / fooBar
fooBar         -> FooBar        / fooBar
ThingID        -> ThingID       / thingID
HTTP_server2   -> HTTPServer2   / httpServer2
version2_event -> Version2Event / version2Event
```

The plan must enumerate every dynamic Haskell occurrence before rendering. Include context and
node module segments; generated and create-once module names; ID, enum, nominal, mapped shape,
aggregate, command, event, state/vertex, contract, queue, read-model, process, router, workflow,
and service-facade types and constructors; record fields; helper values formed with prefixes or
suffixes; structural projection tags/witnesses; and import aliases. Include fixed template
declarations in the final source audit so a literal such as the current `_renderEventTypes` cannot
bypass the policy. Keep record-field collision scope compatible with the deliberate
`DuplicateRecordFields` use: identical selectors on different generated records may coexist, but
two source fields in the same record, or a selector colliding with another top-level value where
GHC would reject or make it ambiguous, must fail.

Extend `DiagnosticCode` in `keiro-dsl/src/Keiro/Dsl/Validate.hs` with append-only naming codes for
unsafe normalization, reserved generated occurrences, and normalized collisions. Replace
`validateNames`' renderer-shaped uppercase/lowercase approximations with conversion of
`HaskellNameError` values from the central plan. A collision retains both `NameSite` values and
renders the later declaration as primary plus the earlier declaration as a note; extend the
ordinary diagnostic representation minimally so `checkWorkspace` can map both locations back to
their member files. Both messages name the raw declarations, the normalized occurrence, target
module/namespace, and stable code.

Add `keiro-dsl/test/haskell-name/Main.hs` and a private
`keiro-dsl-haskell-name-test` component in `keiro-dsl/keiro-dsl.cabal`, following the existing
private `Keiro.Dsl.HaskellImport` test pattern. Unit and QuickCheck properties cover leading,
trailing, and repeated underscores; empty/all-underscore input; acronyms; digits; already
idiomatic camel case; keywords; case-folded module paths; deterministic source-order independence;
and collisions for every `NameSiteKind`. Add integration examples to `keiro-dsl/test/Main.hs`
which prove `foo_bar` and `fooBar` fail at `check`, before scaffold planning.

At the end of this milestone, the new private tests and ordinary validator tests pass. No emitted
module needs to change yet, but every spelling and collision decision is frozen in executable
tests.

### Milestone 2: Make all Haskell emitters consume the checked plan

Thread `HaskellNamePlan` through the service and compatibility scaffold entry points in
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`. The public convenience functions may construct the plan
internally, but no emitter may call a local case helper or concatenate a raw logical name into a
Haskell occurrence. The CLI path has already run `validateService`; a direct API caller that
supplies an invalid graph receives a `HaskellNamePlanningRefusal` from plan functions rather than
an `error` or partial rendering.

In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, replace `pascal`, `pascalFromKebab`, `lowerFirst`,
`readModelStem`, queue stem construction, and every raw name interpolation at a Haskell occurrence
site with a typed lookup. Carry raw logical names alongside planned occurrences where generated
strings, JSON keys, event types, registry/subscription names, SQL, origins, fingerprints, or
diagnostics need the source spelling. In particular, `rmTable`, `rmSchema`, `rmcName`,
`wqPhysical`, `wqDlq`, `wqTable`, `wqfWire`, contract discriminator/field strings, enum wire
spellings, event tags, and the output of `registryNameFor` and `subscriptionNameFor` must not pass
through Haskell normalization.

Apply the same conversion to `keiro-dsl/src/Keiro/Dsl/Harness.hs`,
`keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs`,
`keiro-dsl/src/Keiro/Dsl/ExplainBindings.hs`, and
`keiro-dsl/src/Keiro/Dsl/AggregateType.hs`. Update
`keiro-dsl/src/Keiro/Dsl/HaskellImport.hs` so `HaskellReference` and
`ImportEnvironment` carry the checked module/occurrence wrappers. Explicit consumer references are
parsed without re-casing and rejected if invalid; generated references come directly from the
plan. Alias allocation remains deterministic and semantically unchanged.

Give each `ScaffoldModule` a stable `ModuleRole` derived from raw semantic ownership and module
family, distinct from `modulePath`, `origin`, and member ownership. This compile-visible field
forces every module emitter to identify its artifact and later lets migration pair a legacy path
with its idiomatic path without guessing from human prose. Add a final generated-source naming
audit to `pureRefusals`. The audit tokenizes the constrained generated module text, verifies its
declared module path and top-level type/constructor/value/selector declarations against the
planned occurrence inventory, and reports `GeneratedNameInvariantViolation` as an internal
pre-write refusal. It scans both overwriteable modules and a newly created hole stub; it never
audits or rewrites an already hand-owned hole during an ordinary scaffold.

Update `keiro-dsl/src/Keiro/Dsl/Skeleton.hs` so logical compound identifiers use idiomatic source
camel case: for example, `reservationWork`, `acceptedTransferNeeds`, `transferDecisions`, and
`reservationWorkDispatch`. Keep their queue, table, SQL column, and other external strings in
snake_case. Add fresh-scaffold assertions using the existing incident-paging fixture. At the end
of this milestone, a disposable scaffold contains `ServiceOncall` paths and `serviceOncall...`
values, contains the original external strings, passes the final name audit, and is byte-idempotent
on a second fresh generation.

### Milestone 3: Plan and apply recoverable source moves

Add a `GeneratedHaskellNamingEdition` value and current edition identifier to
`keiro-dsl/src/Keiro/Dsl/HaskellName.hs`. Keep a `LegacyGeneratedHaskellNames` policy only in the
migration layer, where it exactly reproduces the pre-change `pascal`/`lowerFirst`/underscore split
behavior. It must never be selectable for new output. Add forward-compatible naming-edition and
module-role rows to `ScaffoldRecord` and `WorkspaceRecord`; absence means the historical legacy
edition. Preserve the v1 headers and unknown-row behavior so older readers keep parsing the parts
they understand.

Add `keiro-dsl/src/Keiro/Dsl/HaskellSourceMove.hs`. Its pure planner pairs legacy and idiomatic
artifacts by `ModuleRole`, reads only prior-record paths, and returns a sorted list of `SourceMove`
values. A move records kind, old/new module names and relative paths, expected provenance, content
digest, and backup path. The token-aware transform recognizes nested block comments, line comments,
escaped string and character literals, pragmas, module declarations, imports, and qualified
constructor-token paths. It replaces exact old module-name token sequences longest-first only in
Haskell code, leaving comments and literals byte-identical. It refuses malformed lexical input,
an unexpected declared module, ambiguous old/new maps, a missing recorded source, a target that
already contains different bytes, a bannerless generated source, or any unrecorded path.

Extend the `Scaffold` CLI constructor and both execution paths in
`keiro-dsl/app/Main.hs` with `--apply-name-migrations`. Without the flag, any required move returns
a `NameMigrationRequired` refusal before the output directory, manifest, record, conformance
package, or module tree changes; `renderRefusals` prints the complete ordered plan and the rerun
command. With the flag, complete every content transformation and conflict check in memory first.
Write transformed hole bytes to same-filesystem temporary files, move every old generated and hole
source into a deterministic backup directory such as
`.keiro-dsl-name-migrations/<old>-to-<new>/`, then rename the prepared files into their new paths
and generate overwriteable modules. Never unlink old content. Only after the moves and module
writes succeed should the current manifest and scaffold record be written.

Extend `ScaffoldReport` and `WorkspaceScaffoldReport` with planned/applied move and backup data.
Current manifests and records contain only idiomatic paths; migrated old paths are not also
reported as stale, while unrelated prior paths retain the ordinary preserve-and-review stale
behavior. A rerun after success finds the current edition and no moves, reports every generated
module unchanged or overwritten according to the existing single/workspace convention, and never
touches the backup. A rerun after a crash recognizes prepared temp/backup/new states by digest and
either resumes safely or refuses with exact recovery instructions.

Add a migration fixture under `keiro-dsl/test/fixtures/haskell-name-migration/` representing an
existing `Generated/.../Service_oncall` tree, its prior record, and a filled
`Service_oncall/ReadModelHoles.hs`. Put the old module path in a comment and string literal as well
as the module declaration, import, and a qualified code reference. Tests first prove ordinary
scaffold refuses with a complete move plan and zero mutations. Applying the flag must preserve the
filled function body, change only code-token module references, retain the comment/string bytes,
store the original files under the backup root, remove the active old tree, and write no old module
to the current manifest or record. Run the same scenario through a two-member workspace to prove
member ownership and context-level artifacts remain attributable.

### Milestone 4: Classify Haskell-only evolution and regenerate evidence

Add the append-only `GeneratedHaskellNameChanged` code to
`keiro-dsl/src/Keiro/Dsl/Validate.hs` and classify it in
`keiro-dsl/src/Keiro/Dsl/Diff.hs` as `VAdvisory` only on `ConsumerBuild`, with no rollout
constraint. Teach ordinary and workspace diffing to compare planned Haskell occurrence surfaces
for declarations already paired by stable semantic or external identity. Do not invent a pairing
when external identity is ambiguous. Concrete coverage must include a workqueue payload type rename
(which is explicitly generated-only today), a mapped record selector rename paired by unchanged
wire key, a module-segment rename whose runtime facts are explicit and unchanged, and an unchanged
normalized spelling that produces no finding.

`keiro-dsl/src/Keiro/Dsl/DiffReport.hs` should recommend rescaffolding, recompiling consumers, and
running conformance for this code. `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` must remain unchanged
except for tests proving those cases render replay-neutral and produce no aggregate fingerprint
change. Scaffold naming-edition drift is reported by scaffold history, not fabricated as a source
semantic diff when the old and new `.keiro` text are identical.

Regenerate every checked-in generated conformance module from its owning fixture under the new
policy. Use the migration path for create-once modules rather than deleting or overwriting their
contents. Update module declarations, imports, Cabal `other-modules`, package source paths, service
facades, generated manifests, scaffold/workspace records, and conformance-package inventories.
Add `scripts/check-generated-name-policy.sh` and a `generated-name-policy` recipe in `justfile`.
The script checks tracked generated and initial hole-stub module paths/declarations for underscore
components and invokes the final occurrence audit over fresh scaffold plans; it must not mistake
snake_case SQL, wire strings, comments, or hand-owned value bodies for Haskell declarations.

At the end of this milestone, all focused diff/replay tests and all affected compiled conformance
components pass. A repository search finds no underscore-bearing Haskell module component under a
tracked generated tree, while fixture source and generated metadata still contain intentional
snake_case external spellings.

### Milestone 5: Publish the contract and run release gates

Update `agents/skills/keiro-dsl-authoring/NOTATION.md` and
`docs/user/typed-spec-toolchain.md`. Define logical versus external versus generated names, show
the normalization examples, explain collision diagnostics, change skeleton examples to camel case,
and document the review/apply/backup/recovery workflow for an existing scaffold. Update
`agents/skills/keiro-dsl-authoring/LOOP.md` where it currently says stale hole paths always require
manual preservation. Add breaking-change and feature entries to `keiro-dsl/CHANGELOG.md` and the
root `CHANGELOG.md`, including the public `ScaffoldModule`, diagnostic, refusal, report, and record
surface changes.

Amend ADR 0012 so the import plan consumes checked generated occurrences while preserving explicit
consumer references. Amend ADR 0015 with the explicit, backup-backed source-move exception to
ordinary no-rename stale handling and its detection-before-write rules. Amend ADR 0019 with the
generated naming edition, UpperCamelCase/lowerCamelCase contract, and the continued exclusion of
ordinary hand-owned rewriting. Advance each `timestamp`, add bundle log entries with `okf log add`,
and run strict validation. Do not allocate a new ADR unless implementation discovers a distinct
durable decision not covered by those records.

Finish by running the private naming tests, ordinary DSL tests, the complete `keiro-dsl` package
test target, all-package build, generated-name and extension policies, strict ADR validation, and
`git diff --check`. Record exact results and any fixture count in Progress and Outcomes &
Retrospective. Every implementation commit must use Conventional Commits and include both active
trailers:

```text
ExecPlan: docs/plans/190-guarantee-idiomatic-haskell-names-for-generated-declarations.md
Intention: intention_01kz5gbdh9e1nr20r3djzh0pe3
```


## Concrete Steps

Run every command in this section from the repository root,
`/Users/shinzui/Keikaku/bokuno/keiro`, unless a command explicitly changes directory. Begin by
capturing the clean baseline and the current defect:

```bash
git status --short
cabal test keiro-dsl-test
name_probe_dir="$(mktemp -d)"
cabal run -v0 keiro-dsl -- scaffold \
  keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro \
  --out "$name_probe_dir"
rg --files "$name_probe_dir" | sort | rg 'Service_oncall|service_oncall'
```

Before implementation, the test suite should pass and the final command should show old active
paths resembling:

```text
.../Generated/IncidentPaging/Service_oncall/ReadModel.hs
.../IncidentPaging/Service_oncall/ReadModelHoles.hs
```

After Milestone 1, run the central model and validation tests:

```bash
cabal test keiro-dsl-haskell-name-test
cabal test keiro-dsl-test --test-options='--match Haskell.name'
```

Expected summary:

```text
Test suite keiro-dsl-haskell-name-test: PASS
Test suite keiro-dsl-test: PASS
```

After Milestone 2, prove fresh generation and external-name preservation in a disposable tree:

```bash
fresh_name_dir="$(mktemp -d)"
cabal run -v0 keiro-dsl -- scaffold \
  keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro \
  --out "$fresh_name_dir"
test -f "$fresh_name_dir/Generated/IncidentPaging/ServiceOncall/ReadModel.hs"
test -f "$fresh_name_dir/IncidentPaging/ServiceOncall/ReadModelHoles.hs"
test ! -e "$fresh_name_dir/Generated/IncidentPaging/Service_oncall"
rg -n 'serviceOncall(ReadModel|QualifiedTable|Query|AsyncProjection)' \
  "$fresh_name_dir/Generated/IncidentPaging/ServiceOncall" \
  "$fresh_name_dir/IncidentPaging/ServiceOncall"
rg -n 'tableName = "service_oncall"|schema = "incident_paging"|incident-paging-service-oncall-sub' \
  "$fresh_name_dir/Generated/IncidentPaging/ServiceOncall"
```

The `test` commands must exit zero. The first `rg` shows lowerCamelCase Haskell values; the second
shows unchanged SQL and subscription strings.

Exercise the migration regression after Milestone 3. The test fixture's helper script or Hspec
example should create its own temporary copy, so this command does not mutate checked-in files:

```bash
cabal test keiro-dsl-test --test-options='--match Haskell.name-migration'
```

Expected evidence in the captured test transcript is equivalent to:

```text
name migration required: legacy-v1 -> idiomatic-v1; nothing was written
hole IncidentPaging.Service_oncall.ReadModelHoles -> IncidentPaging.ServiceOncall.ReadModelHoles
backup: .keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1/...
name migration: applied
```

After Milestone 4, run the focused source/build and replay tests, then the affected conformance
families:

```bash
cabal test keiro-dsl-test --test-options='--match Haskell.name-diff'
cabal test keiro-dsl-conformance-queue
cabal test keiro-dsl-conformance-readmodel-runtime
cabal test keiro-dsl-conformance-dispatch-full
cabal test keiro-dsl-conformance-router-full
cabal test keiro-dsl-conformance-newsurface
cabal test keiro-dsl-conformance-skeletons
cabal build keiro-dsl-conformance-service-runtime
cabal test keiro-workspace-proof-conformance:conformance
just generated-name-policy
```

The diff assertion should render a finding like this, with every other vector entry compatible:

```text
ADVISORY GeneratedHaskellNameChanged consumer-build=advisory
replay-impact: neutral
```

If regeneration intentionally changes either service-package name, inspect the generated `.cabal`
files, update these two commands in this plan, and record the reason in Surprises & Discoveries
rather than silently skipping that proof.

For the ADR amendments, preserve the existing `docId` values and update their timestamps. Add the
bundle log entries and validate:

```bash
okf log add docs/adr ADR-12 --kind Update \
  -m "Route generated Haskell references through the checked naming plan while preserving consumer identities (plan 190)."
okf log add docs/adr ADR-15 --kind Update \
  -m "Record explicit backup-backed source moves for generated-name migrations (plan 190)."
okf log add docs/adr ADR-19 --kind Update \
  -m "Define the generated Haskell naming edition and idiomatic occurrence policy (plan 190)."
just adr-validate
```

The validation must end with an `OK` result for the full ADR bundle and no stale-log diagnostic.

Run the final gates:

```bash
cabal build all
cabal test keiro-dsl
just generated-name-policy
just extension-policy
just adr-validate
git diff --check
git status --short
```

Expected terminal summaries include:

```text
Test suite keiro-dsl-test: PASS
generated Haskell name policy: OK
extension policy: OK
OK: 20 concepts
```

The ADR concept count may increase if implementation creates a justified new record; record the
actual count in this plan. Inspect `git status --short` rather than assuming that regenerated
files are limited to one conformance tree. Every changed create-once file must correspond to a
recorded source move, not a fresh stub overwrite.


## Validation and Acceptance

Acceptance is behavioral and requires all of the following observations.

1. Checking and scaffolding a source containing `readmodel reaction_history` succeeds. The
   generated and create-once module segments are `ReactionHistory`; generated values include
   `reactionHistoryProjection` or the applicable read-model helper suffix. No module declaration,
   path, type, constructor, value, or selector derived from that logical name contains
   `reaction_history` or `Reaction_history`.

2. The same output still contains `tableName = "reaction_history"`, uses the exact declared SQL
   schema and qualified table, and preserves explicit registry/subscription strings. Golden tests
   similarly pin enum wire values, event tags, JSON keys, queue physical/DLQ/table values, mapped
   canonical identities, and scaffold provenance to their raw or explicitly declared spelling.

3. The checked naming property suite proves the exact acronym/digit examples in Milestone 1 and
   proves that every generated occurrence returned by the complete plan satisfies its typed
   UpperCamelCase or lowerCamelCase invariant. The final generated-source audit finds the same
   occurrence inventory in emitted text and has a mutation test in which a raw or underscore
   template interpolation makes scaffolding refuse before writes.

4. Two declarations such as `foo_bar` and `fooBar` that target the same occurrence space fail
   `keiro-dsl check` with the stable normalized-collision code. A single-file diagnostic names
   both raw declarations and both lines. A workspace collision cites both member paths and lines.
   Reversing member or declaration order does not change the normalized key or ordered evidence.

5. Leading, trailing, repeated, or all-only underscores fail with the unsafe-normalization code;
   keywords that arise only after lower-casing fail with the reserved-occurrence code. Acronyms,
   digits after the first character, and already-idiomatic camel case succeed with byte-pinned
   results. Explicit consumer Haskell references are not normalized and retain their established
   validity diagnostics.

6. `keiro-dsl new workqueue` emits `reservationWork`, `acceptedTransferNeeds`, and
   `transferDecisions` logical identifiers, while its queue, table, and column strings remain
   snake_case. Every skeleton parses and checks, and every freshly scaffolded checked-in fixture
   has no underscore-bearing module component.

7. Given a legacy record plus `Generated/.../Service_oncall` and a filled
   `Service_oncall/ReadModelHoles.hs`, ordinary scaffold reports the exact migration and writes
   nothing. Re-running with `--apply-name-migrations` produces the `ServiceOncall` tree, preserves
   the filled body, rewrites code-token module references only, backs up every old file, and leaves
   no `Service_oncall` module in the active tree, manifest, or current record. Running the command
   again performs no move and leaves backup bytes unchanged. The equivalent workspace test retains
   member ownership.

8. A source edit that changes only a generated Haskell occurrence emits
   `GeneratedHaskellNameChanged` with consumer-build advisory and recompilation/conformance
   remedies. Its compatibility vector reports compatible private-history, new-event reading,
   snapshot, public-consumer, and persisted-identity axes; replay impact is neutral. A real SQL,
   wire, queue, registry, subscription, or runtime identity change continues to emit its existing
   independent finding and is never hidden by the name finding.

9. The refreshed conformance modules named in Concrete Steps compile and run under their existing
   generated-Haskell language contract. `cabal test keiro-dsl`, `cabal build all`, the generated
   name policy, extension policy, and strict ADR validation all pass. A tracked-file audit reports
   no underscore module segments in generated or initial hole-stub declarations, while intentional
   snake_case remains visible in SQL/wire fixtures.


## Idempotence and Recovery

Name planning, collision checking, diffing, source auditing, and migration planning are pure and
deterministically sorted. Repeating them with the same `Context`, `CheckedService`, prior record,
and filesystem evidence returns the same names, diagnostics, module bytes, and move plan. Fresh
scaffolding retains the existing generated overwrite and hole create-once behavior.

The migration apply path is deliberately opt-in. Before moving anything it must validate the
complete plan, every old content digest, every generated banner, every destination, every
transformed module declaration, and every conformance-package preflight. If any check fails, it
returns a refusal and changes no active file. Do not use `--force-generated-overwrite` to bypass a
name-migration conflict; that flag proves authority only at an already-current Generated path and
does not authorize moving hand-owned code.

Backups make the applied operation recoverable. An old source is renamed under
`.keiro-dsl-name-migrations/<old>-to-<new>/` before its prepared replacement is installed. Backups
are never included in Cabal manifests or current scaffold records and are never deleted by Keiro.
If execution stops after backup but before installation, a rerun compares the recorded digest,
the backup, temporary file, and destination. It resumes only when the state matches one unique
planned operation; otherwise it prints exact paths and asks the user to restore the backup or
resolve the conflict manually. Restoring means moving the backed-up tree to its original relative
paths and restoring the prior manifest/record from version control; no destructive reset is
required.

Regeneration of checked-in conformance output should happen through disposable fresh scaffolds and
the tested migration path. Never delete all conformance directories and recreate hole modules:
that would lose filled application evidence. If a generated diff includes an external string,
fingerprint, record identity, or unrelated module, stop, add a focused test, and determine which
raw semantic value was accidentally routed through the Haskell-name plan before continuing.


## Interfaces and Dependencies

`keiro-dsl/src/Keiro/Dsl/HaskellName.hs` is private implementation policy. Exact constructor
visibility may be narrower, but it must provide interfaces equivalent to:

```haskell
newtype UpperCamelName = UpperCamelName { unUpperCamelName :: Text }
newtype LowerCamelName = LowerCamelName { unLowerCamelName :: Text }
newtype HaskellModuleSegment = HaskellModuleSegment { unHaskellModuleSegment :: Text }
newtype HaskellModuleName = HaskellModuleName { unHaskellModuleName :: Text }

data DerivedHaskellName = DerivedHaskellName
  { upperCamel :: !UpperCamelName
  , lowerCamel :: !LowerCamelName
  }

data NameSourceKind = LogicalIdentifier | LogicalWireWord | ExplicitHaskellName
data NameSiteKind
  = ContextModuleSite
  | NodeModuleSite
  | GeneratedTypeSite
  | GeneratedConstructorSite
  | GeneratedValueSite
  | GeneratedFieldSite
  | GeneratedHelperSite
  | ImportAliasSite
data HaskellOccurrenceSpace = ModuleSpace | TypeSpace | ConstructorSpace | ValueSpace | FieldSpace

data NameSite = NameSite
  { siteKind :: !NameSiteKind
  , siteLogicalName :: !Text
  , siteOwner :: !Text
  , siteLoc :: !Loc
  }

data HaskellNameError
  = EmptyNameSegment !NameSite
  | ReservedGeneratedOccurrence !NameSite !Text
  | NormalizedNameCollision !HaskellOccurrenceKey !(NonEmpty NameSite)
  | InvalidExplicitHaskellName !NameSite !Text

data GeneratedHaskellNamingEdition = LegacyNamingV1 | IdiomaticNamingV1

deriveHaskellName :: NameSourceKind -> NameSite -> Either HaskellNameError DerivedHaskellName
planHaskellNames :: Spec -> Either (NonEmpty HaskellNameError) HaskellNamePlan
lookupUpperName :: HaskellNamePlan -> HaskellNameKey -> UpperCamelName
lookupLowerName :: HaskellNamePlan -> HaskellNameKey -> LowerCamelName
auditGeneratedHaskell
  :: HaskellNamePlan
  -> HaskellModuleName
  -> [PlannedOccurrence]
  -> Text
  -> [HaskellNameError]
```

Do not export unchecked constructors to renderers. Smart constructors validate explicit Haskell
module/type/value references without changing their text. Rendering functions are the only way to
recover `Text` at a source-emission boundary. The audit takes module identity, planned
occurrences, and rendered text separately so `HaskellName` does not import `Scaffold` and create an
import cycle.

`ScaffoldModule` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` gains a stable role and occurrence
inventory equivalent to:

```haskell
data ModuleRole = ModuleRole
  { roleOwnerKind :: !Text
  , roleOwnerName :: !Text
  , roleFamily :: !Text
  }

data ScaffoldModule = ScaffoldModule
  { modulePath :: !FilePath
  , moduleText :: !Text
  , kind :: !ModuleKind
  , origin :: !Text
  , moduleRole :: !ModuleRole
  , moduleOccurrences :: ![PlannedOccurrence]
  }
```

If implementation can keep `moduleOccurrences` inside a private wrapper without reintroducing
parallel module registries, it may do so and record that refinement in the Decision Log. The
observable requirements are stable role pairing and a source audit against the complete planned
inventory.

`keiro-dsl/src/Keiro/Dsl/HaskellSourceMove.hs` provides pure plan/transform functions and an IO
preflight seam equivalent to:

```haskell
data SourceMove = SourceMove
  { moveRole :: !ModuleRole
  , moveKind :: !ModuleKind
  , moveOldModule :: !HaskellModuleName
  , moveNewModule :: !HaskellModuleName
  , moveOldPath :: !FilePath
  , moveNewPath :: !FilePath
  , moveBackupPath :: !FilePath
  , moveExpectedDigest :: !Text
  }

planSourceMoves
  :: GeneratedHaskellNamingEdition
  -> HaskellNamePlan
  -> PreviousScaffoldModules
  -> Either (NonEmpty SourceMoveError) [SourceMove]

rewriteHaskellModuleReferences
  :: Map HaskellModuleName HaskellModuleName
  -> Text
  -> Either SourceMoveError Text
```

The IO executor stays in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`, where existing detection-before-write and report
contracts live. Record extensions stay additive under the existing v1 headers. Missing naming
edition means `LegacyNamingV1`; every newly rendered record explicitly names `IdiomaticNamingV1`
and includes stable module-role rows.

`HaskellReference` in `keiro-dsl/src/Keiro/Dsl/HaskellImport.hs` changes from raw `Text` module and
occurrence fields to `HaskellModuleName` plus the namespace-appropriate checked occurrence type.
The qualification preference and shortest-unique-suffix algorithm remain unchanged. Complete
external module paths continue into imports, manifests, scaffold history, mapping provenance, and
diagnostics exactly as declared.

No external service or new package is required. Use the repository's existing `base`, `text`,
`containers`, `directory`, and `filepath` bounds. The implementation uses Cabal/GHC for compiled
proof, Hspec/QuickCheck already present in the test suite for examples and properties, `okf` for
the profiled ADR bundle, and Mori only for canonical cross-repository references. Do not inspect
`/nix/store`; dependency source lookup, if an unexpected API question arises, must go through the
Mori registry first.
