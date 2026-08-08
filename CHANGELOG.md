# Changelog

All notable changes to the Keiro package set are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/), and the published
packages follow the [Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Unreleased

### Breaking Changes

- **keiro-dsl**: candidate language 5 extends the exported semantic graph with
  projection target, rebuild group, and projection owner nodes and adds catalog
  bindings to `ReadModelNode`. `DiagnosticCode` gains the corresponding
  validation and evolution codes, including distinct target-dependency and
  handler-order changes; exhaustive consumers must be extended. Languages 1–4
  retain their published parse and runtime meaning.

### New Features

- **keiro**: add `Keiro.Projection.Catalog`, a pure typed projection inventory
  that separates query models, physical targets, atomic rebuild groups, and
  ordered projection owners. Validation accumulates stable multi-site
  diagnostics and produces typed inline views, heterogeneous registration and
  replay metadata, deterministic inventory rendering, and SHA-256
  fingerprints. Reset policy is independent from replay policy, prior-inventory
  removal comparison remains a separate gate, and legacy read-model/projection
  values have explicit unmanaged compatibility wrappers.
- **keiro**: make catalog rebuild groups the durable lifecycle and writer-fence
  unit. Catalog registration persists group fingerprints and query bindings;
  `beginGroupRebuild` atomically fences the group, clears all declared
  clear-before-replay tables with one foreign-key-compatible `TRUNCATE`,
  preserves reconcile targets, and derives async dedup/checkpoint resets from
  the catalog. `runCommandWithCatalogProjections` and
  `applyAsyncProjectionFromCatalog` use the same sorted group locks and return
  typed fenced outcomes without committing append, dedup, or target writes.
  Existing single-read-model rebuild functions remain as an unmanaged bridge.
- **keiro**: add the catalog history runner and native migration 0023. Rebuilds
  capture an immutable Kiroku head, k-way merge category history in global
  order, commit target writes with per-source and per-adapter progress, resume
  only an exact `keiro/projection-replay/v1` contract, persist structured
  failure/verification evidence, and atomically promote only after complete
  source exhaustion, adapter participation, and catalog verification. New
  rebuild metrics cover starts, resumes, committed pages/events, failures,
  promotions, and page duration.
- **keiro-dsl**: register unreleased candidate language 5 with checked physical
  targets, atomic rebuild groups, projection ownership/order, typed aggregate
  or category sources, independent reset/replay policies, and query-model
  bindings. Scaffolding emits one validated context catalog with typed live
  views, catalog-derived registration and rebuild functions, aggregate-codec
  replay adapters, and create-once live/replay/category/idempotency holes.
  Diff, replay-impact JSON, scaffold ledgers, and workspace records carry the
  same catalog identities. A dedicated compiled conformance service exercises
  inline multi-target, async, clear, and preserve paths. Language 5 is amended
  in place until publication; no language 6 contract is allocated.

## [0.11.0.0] - 2026-08-05

### Breaking Changes

- **keiro-dsl**: scaffold sidecars now use role-bearing names:
  `keiro-dsl-scaffold-record.<context>.txt` becomes
  `keiro-dsl-ledger.context.<context>.txt`, the workspace form becomes
  `keiro-dsl-ledger.workspace.<service>.txt`, the conformance record becomes
  `keiro-dsl-conformance-ledger.txt`, and both generated `keiro-dsl-manifest.*`
  files become explicit `keiro-dsl-cabal-fragment.context.*` or
  `.workspace.*` files. An existing old-name tree now refuses without writing;
  review the listed moves and rerun `scaffold --apply-name-migrations` to rename
  them losslessly or preserve duplicate old files under
  `.keiro-dsl-name-migrations/sidecar-v1/`.
- **keiro-dsl**: `Refusal` gains `SidecarMigrationRequired` and
  `SidecarMigrationRefusal`, while `ScaffoldReport` and
  `WorkspaceScaffoldReport` gain their applied-sidecar-move fields; exhaustive
  consumers must be extended. The renamed conformance ledger also moves from
  whitespace rows to the versioned `keiro-dsl conformance ledger v1` format
  with typed JSON file rows. Its parser now ignores unknown row kinds and JSON
  keys while retaining service-key, malformed-record, unsafe-path, and
  case-folded duplicate-path refusals; legacy conformance records are converted
  only by the explicit name-migration apply path.
- **keiro-core**, **keiro**, and **keiro-dsl** now require
  `keiki >=0.9 && <0.10`; **keiro** also requires
  `keiki-codec-json >=0.9 && <0.10`. Keiki 0.9 seals `InCtor` and `WireCtor`
  construction behind read-only patterns: manual constructors must use
  `unavailableInCtor` / `unavailableWireCtor`, while constructors that need
  trusted structural evidence must use Keiki's Generic or Template Haskell
  producers. Keiro's generated aggregates already use the trusted TH path.
- Keiki 0.9 classifies replay head identity structurally and can suppress a
  default inversion-ambiguity warning when exact integral register/literal
  constraints prove the candidates disjoint. Consequently,
  `validateEventStream`, `mkEventStream`, generated validation harnesses, and
  consumers that inspect Keiki warnings may report a different conservative
  warning set after recompilation. Runtime event execution and the
  `keiki-codec-json` wire format are unchanged.
- **keiro-dsl**: generated Haskell now uses one checked UpperCamelCase/lowerCamelCase
  naming edition. Compound module and create-once paths move (for example,
  `Service_oncall` → `ServiceOncall`), and public diagnostic, refusal, report, and
  additive scaffold-history surfaces expose normalization, collision, and migration
  evidence.
- **keiro-dsl**: `DiagnosticCode` gains `FieldWireKeyCollision`,
  `FieldWireKeyInvalid`, and `EvtFieldWireKeyChanged`; exhaustive matches must be
  extended.
- **keiro-dsl**: `DiagnosticCode` appends `LanguageVersionBelowMinimum` and now
  derives `Ord`, `Enum`, and `Bounded`; exhaustive matches must be extended. `check`,
  `scaffold`, and the working-tree side of `diff` now add a stderr language-contract
  notice for compatibility-only sources, which changes exact-stderr consumers.
- **keiro-dsl**: `DiagnosticCode` appends `AggregateEmpty`, `ContractEmpty`,
  `GeneratedPathCollision`, `GeneratedImportCycle`, `BehaviorDerivationInvalid`,
  `ConformanceFactKeyCollision`, and `GeneratedPlanningInvariantViolation`;
  exhaustive matches must be extended. Specs that scaffold already could not lower
  now fail earlier during `check`.
- **keiro-dsl**: `DiagnosticCode` appends thirteen accepted-surface warning and
  language-4 error codes, including process/router resolution, bounded windows,
  queue payload types, derived IDs, projection/outbox fields, and the distinct
  `RouterBenignInversion`; exhaustive matches must be extended. The never-emitted
  `DuplicateUpcasterSource`, `IdentHaskellKeyword`, `IdentNotConstructorSafe`, and
  `MappedGuardUnsupported` constructors are removed.
- **keiro-dsl**: `IdExpr` gains the parsed `ideField`, and `ScaffoldReport` gains
  `reportInertNodes`; callers constructing or exhaustively matching these exported
  records must be updated.

### New Features

- **keiro-dsl**: `scaffold --apply-name-migrations` performs an explicit,
  backup-backed and digest-journaled source move with token-aware Haskell module
  rewriting and crash recovery. Generated-only renames are consumer-build advisories;
  external and replay identities remain unchanged.
- **keiro-dsl**: language 4 direct aggregate and integration-contract fields may
  declare independent `haskell <selector>` and `as "<wire-key>"` aliases. Records
  use selectors, codecs and goldens use wire keys, and `fields(Command)` copies the
  resolved three-namespace identity.
- **keiro-dsl**: `check --min-language N` enforces a released language floor, while
  `--deny-warnings` and repeatable/comma-separated `--deny CODE` make warnings
  CI-failing without changing their severity. `check --report-out` writes the
  append-only `keiro-dsl/check-report/1` source/workspace schema through the new
  `Keiro.Dsl.CheckReport` module.
- **keiro-dsl**: language 4 now resolves every internally decidable process,
  router, projection, publisher, queue, pgmq source-key, read-model identity, and
  timer-ID surface, and rejects duration values that cannot fit the runtime `Int`
  seconds representation. Released languages 1–3 keep their prior acceptance.

### Other Changes

- **keiro-dsl**: generated behavior contracts and harnesses now carry complete
  signatures, annotated behavior cells, named sample constants, runtime-backed
  read-model facts, evidence-rich failures, and usage-conditional imports. The
  `keiro/behavior-conformance/1` JSON failure object adds the append-only
  `subject` field. The conformance corpus was regenerated under `-Wall` and now
  has a clean-tree regeneration policy gate; consumers should re-scaffold and
  recompile. Behavior keys, wire data, shape hashes, fold identity, and replay
  semantics are unchanged.
- **keiro-dsl**: adds record-derived conformance-corpus regeneration and golden
  acceptance tooling. The driver replays the public CLI without forced overwrites,
  preserves create-once files, checks record/disk and Cabal/disk consistency, and
  reports every resulting Git diff for review.
- The development project pins `mori://shinzui/keiki/repos/keiki` at the commit
  behind `v0.9.0.0` for both `keiki` and `keiki-codec-json` until the coordinated
  0.9 packages are published to Hackage.
- **keiro-dsl**: language 4 now selects syntax profile 3 for field aliases. The
  generated occurrence reserved set narrows to the 23 words GHC actually rejects;
  previously refused contextual identifiers such as `family`, `via`, and
  `qualified` now check and compile.
- **keiro-dsl**: generated aggregate conformance now uses one source-wide transition
  layout. Replay-only initial edges remain available to detailed replay witnesses but
  no longer emit live acceptance helpers; predicate verification, behavior attribution,
  and Keiki runtime edges share the same cumulative outgoing index. Residual duplicate
  generated declarations are refused before any scaffold write.
- **keiro-dsl**: source and workspace checking and both scaffold planners now share
  one pure gate order: fold surface, lowering, module construction, conformance-package
  planning, then module-plan refusals. Workspace planning therefore reports a lowering
  refusal before a simultaneous facade-key refusal. Valid generated output is unchanged.
- **keiro-dsl**: accepted but inert intake flags, emit derivations, optional queue
  markers, and inline subscriptions now warn; scaffold reports list emit, pgmq
  dispatch, and operation nodes that contribute no modules. Timer dead-letter text,
  pgmq fanout functions, and pgmq top-level dedupe keys are explicitly
  descriptive-only. Existing valid generated output remains byte-identical.

## 0.10.0.0 — 2026-08-03

All published packages move to 0.10.0.0 together. The cycle is entirely
`keiro-dsl` work: generated Haskell gains an explicit, checked compilation
contract, consumer-owned types are imported idiomatically instead of being
flattened into module-qualified text, and a configured service now scaffolds a
runnable conformance package behind one runtime-owned facade.
`keiro-core`, `keiro`, `keiro-pgmq`, and `keiro-migrations` have no source
changes; they move only to keep the set on one version.

### Breaking Changes

- **keiro-dsl**: `Keiro.Dsl.AggregateType` replaced `aggregateHaskellType` and
  `aggregateImports` with the typed `AggregateHaskellSource` surface
  (`aggregateConsumerHaskellSource`, `aggregateSourceReferences`,
  `aggregateSourceStaticImports`, `renderAggregateHaskellSource`).
- **keiro-dsl**: `Refusal` gained `DuplicateConformanceFactKeys` and
  `ConformancePackageRefusal`; `ScaffoldReport` gained
  `reportConformancePackage`; `WorkspaceManifest` gained `wmfRuntimePackage`
  and `wmfRuntimePackageLoc`.
- **keiro-dsl**: the generated build manifest now emits the complete Cabal
  fragment, including `default-language`, `default-extensions`, and an
  `exposed-modules` block for the conformance facade. Consumers must repaste
  the fragment.

### New Features

- **keiro-dsl**: a configured service generates at most one local conformance
  package, whose runner imports a single generated
  `<Generated prefix>.Conformance` facade compiled in the consumer's runtime
  package (ADR 20).
- **keiro-dsl**: the runtime Cabal package is explicit build metadata — an
  optional `runtime-package <cabal-name>` workspace clause and a
  `scaffold --runtime-package PACKAGE` override, validated against Cabal's
  package-name grammar and never inferred. New modules
  `Keiro.Dsl.RuntimePackage`, `Keiro.Dsl.ServiceHarness`, and
  `Keiro.Dsl.ConformancePackage`.
- **keiro-dsl**: generated Haskell has an explicit language contract — the
  manifest owns the `GHC2024` + `OverloadedStrings` baseline while
  overwriteable modules declare specialized pragmas locally, only when needed,
  from a closed checked set (ADR 19).

### Other Changes

- **keiro-dsl**: generated event codecs derive one named event-type allow-list
  per aggregate and render unknown-event diagnostics from that same value, so
  the diagnostic text cannot drift from the accepted set.
- **keiro-dsl**: generated structural record fields and union payloads now use
  minimal precedence-correct parentheses without changing schema or wire
  semantics.
- **keiro-dsl**: generated Haskell plans consumer-owned imports once per
  module. Unique type names use explicit unqualified imports; collisions,
  external values, constructors, generated shapes, and binding APIs use
  deterministic short qualified aliases. Imports are merged, deduplicated,
  and sorted without changing semantic identities or create-once ownership.

## 0.9.0.0 — 2026-08-02

All published packages move to 0.9.0.0 together. The cycle designates
`language keiro-dsl 4` as the sole stable authoring contract, closes the
accepted-but-unenforced spec surfaces behind check-time diagnostics, and
tightens the generated runtime API. The whole set also moves to the Keiki 0.8
line.

### Breaking Changes

- **keiro-core**, **keiro**, **keiro-dsl**: require `keiki >=0.8 && <0.9` (and
  `keiki-codec-json >=0.8 && <0.9` in `keiro`), replacing the `>=0.7 && <0.8`
  bounds. Consumers must solve for the same Keiki major; verification results
  and rendering may differ from the 0.7 line.
- **keiro-dsl**: aggregate fold fingerprints widen from 16-hex-digit
  FNV-1a-64 to 32-lowercase-hex-digit FNV-1a-128, intentionally invalidating
  snapshots created with the earlier discriminator. Generated transducers must
  be refreshed; unrelated read-model, mapped-wire, and behavior-key 64-bit
  identities do not move.
- **keiro-dsl**: aggregate fold, diff, replay-impact, and workspace-diff
  service APIs now return `Either FoldSurfaceError`; scaffold planning refuses
  the same error before module generation. The misleading `Spec`-only
  `aggregateFoldFingerprint`, `aggregateFoldSurface`, `diffSpecs`,
  `replayImpact`, `nominalEqualityContract`, `nominalEqualityIdentity`, and
  `nominalEqualityIdentities` legacy/version-1 wrappers are removed. Callers
  must retain and pass a `CheckedService` (or explicitly construct one with
  `legacyCheckedService`).
- **keiro-dsl**: `DiagnosticCode` gains append-only constructors for contract
  TypeID admission and for closed policy, numeric, duplicate, identity,
  external-name, intake-coupling, topic-alias, and wire-clause validation;
  `RolloutConstraint` gains `RolloutProducerFirst`. Exhaustive matches must be
  extended.
- **keiro-dsl**: removes the unreachable exported grammar types `Derivation`,
  `DerivStrategy`, `Disposition`, `DispAction`, `EnvelopeBinding`, and
  `EnvelopeLayer`, which no parser, renderer, validator, or generator ever
  constructed.
- **keiro-dsl**: generated runtime surfaces close over `Text`. Workqueue
  `jobOutcomeFor` takes a queue-named closed outcome sum; inbox generation
  exposes closed outcome and detailed disposition sums; aggregate stream
  categories are fixed to their generated event-stream phantom (`PMCommand`
  and router consumers use the new `<aggregate>CommandCategory`); and
  `workflowFacts` becomes the generated `WorkflowFacts` record.
- **keiro-dsl**: structural projection witnesses are renamed from hex-mangled
  identifiers to deterministic owner-and-JSON-pointer names. Re-scaffold and
  update hand-owned imports; witness values and semantics are unchanged.

### New Features

- **keiro-dsl**: adds `language keiro-dsl 4` (syntax profile 2,
  `keiro-dsl/runtime-semantics/3`) and designates it the sole stable authoring
  contract. `inspect` reports language 4 as `stable` and 1–3 as
  `compatibility-only`; every `new <kind>` skeleton starts at language 4.
  Historical and unversioned sources keep their released semantics and are
  never silently upgraded.
- **keiro-dsl**: closes accepted-but-unenforced service surfaces. Values that
  cannot lower to working generated code are rejected under every language
  version; language 4 additionally enforces numeric floors, duplicate and
  shadowing rules, stable runtime identity uniqueness, Kafka and PostgreSQL
  naming, intake envelope and schema coupling, contract topic aliases, and the
  aggregate wire convention.
- **keiro-dsl**: language-4 public contract fields declared `typeid "inc"`
  scaffold as `KindID "inc"`, with field-path-aware decoders enforcing Keiro's
  frozen TypeID-v7 admission policy. Diffing an unchanged such field from
  language 3 to 4 emits `ContractTypeIdDomainChanged` with producer-first and
  drain-required rollout.
- **keiro-dsl**: runtime semantics is selected by private monotone capability
  profiles rather than consumer-maintained identifier lists. Fold identity and
  replay transition comparison use a total frozen canonical encoder
  independent of presentation pretty-printing, and replay pairing of
  guard-disambiguated sibling transitions is declaration-order invariant.
- **keiro-dsl**: adds service-aware `scaffoldContractForService`,
  `manifestDependenciesForService`, and `renderManifestForService`; exports
  generated contract topic constants; reports the rejected value, complete
  expected set, and Aeson field path from generated decoders; and stamps
  package version, effective language version, and node origin into the
  generated provenance banner.
- **keiro-core**: adds `parseKindIdV7Text` and `parseKindIdV7Value` to
  `Keiro.Codec.IdDomain`, constructing a prefix-indexed `KindID` only after the
  frozen TypeID-v7 policy succeeds and preserving the owning JSON field path on
  failure.
- **keiro**: `Keiro.Inbox.Types` re-exports `RetryDelay` from
  `Shibuya.Core.Ack`, so generated inbox dispositions carrying retry delays
  need only the `keiro` import.

### Other Changes

- **keiro-dsl**: moves the primary conformance baseline to language 4 — 226
  stable fixtures and 30 stable-primary compiled suites enforced against 14
  named source exceptions, two compatibility suites, and one version-independent
  suite. `keiro-dsl-conformance-contract` owns the typed TypeID contract proof,
  the permissive target is renamed `keiro-dsl-conformance-contract-v1-compat`,
  and the redundant `keiro-dsl-conformance-contract-typeid` target is removed.
- **keiro-pgmq**, **keiro-migrations**: no user-facing changes beyond the
  lockstep version and `keiro-core ^>=0.9.0.0` bound.

## 0.8.0.0 — 2026-08-01

All published packages move to 0.8.0.0 together. The cycle is entirely `keiro-dsl`: the `.keiro`
grammar is split into internal concern modules behind the stable `Keiro.Dsl.Parser` facade, a new
located surface frontend is published as an advanced API, and the released-language registry now
selects syntax profiles and runtime-semantics identities explicitly rather than inheriting them from
numeric version ordering. `keiro-core`, `keiro`, `keiro-pgmq`, and `keiro-migrations` are unchanged
and move with the set.

### Breaking Changes

- **keiro-dsl**: `LanguageDefinition` gains `definitionSyntaxProfile` and
  `definitionRuntimeSemantics`. It is exported as `LanguageDefinition (..)`, so positional
  construction and non-wildcard record patterns no longer compile. `definitionBodyParser` remains as
  a compatibility projection but no longer drives parser dispatch.

### New Features

- **keiro-dsl**: publishes `Keiro.Dsl.Source`, `Keiro.Dsl.Syntax`, and `Keiro.Dsl.Frontend`.
  Source-aware tooling can parse an ordered, located `SurfaceSource`, inspect exact half-open spans,
  and lower explicitly to the existing `ParsedSource`/`Spec` semantic boundary.
- **keiro-dsl**: structured frontend failures carry source-selection, body-parsing, and lowering
  phases; stable codes; exact primary spans; messages; expected items; and supported-version
  metadata. Megaparsec types remain internal.
- **keiro-dsl**: adds `syntaxProfileIdentifier`, `syntaxProfileSupportsFeature`,
  `languageVersionsSupportingFeature`, and `sourceLanguageDiagnosticMessage` to
  `Keiro.Dsl.LanguageVersion`.

### Other Changes

- **keiro-dsl**: organizes the `.keiro` grammar into internal concern modules behind the stable
  `Keiro.Dsl.Parser` compatibility facade. CLI and workspace members still parse once through that
  facade; semantic checking, scaffolding, diffing, fingerprints, and replay consume only lowered
  semantic values.
- **keiro-dsl**: every released registry entry now selects an immutable syntax profile and
  runtime-semantics identity. Version 3 deliberately reuses version 2's syntax profile; adding a
  future version no longer inherits syntax or runtime behavior from numeric ordering.
- **keiro-dsl**: `parseSource`, `parseSpec`, `parseSpecText`, their rendered diagnostics, the
  complete 0.7 acceptance matrix, and generated Haskell bytes are unchanged. Canonical pretty
  printing remains non-lossless: the located surface layer does not retain comments or whitespace.
- **keiro-core**, **keiro**, **keiro-pgmq**, **keiro-migrations**: no changes; version moves with
  the set. Internal `keiro-core` bounds bumped to `^>=0.8.0.0` in lockstep.

## 0.7.0.0 — 2026-08-01

All published packages move to 0.7.0.0 together. The cycle is again dominated by
`keiro-dsl`, which lands language version 3 and an enforced TypeID-v7 identifier
domain, one deterministic owner for every generated service-level nominal, a
retained semantic-contract boundary, and complete finite behavior conformance.
`keiro-core` gains the published identifier-domain contract those generators
target; `keiro`, `keiro-pgmq`, and `keiro-migrations` move with the set.

### Breaking Changes

- **keiro-dsl**: language version 3 makes each generated prefix-bearing ID
  abstract. Import `parseX`, `mkX`, and `xText` from
  `Generated.<Context>.Nominals`; the raw constructor and
  `unsafeXFromLegacyText` live only in the generated internal replay module.
  Version 1, version 2, and legacy-unversioned generated output retain their
  released constructor and decoder behavior.

- **keiro-dsl**: generated service-level IDs and enums now live in one
  context-level `Generated.<Context>.Nominals` module instead of being
  redeclared in every aggregate `Domain`. Hand-owned modules that construct
  these values must import the constructors from `Nominals` explicitly.
  Re-scaffolding overwrites only generated files; event wire bytes and canonical
  nominal identities are unchanged.

- **keiro-dsl**: `DiagnosticCode` gains the append-only
  `IdDomainContractChanged` constructor alongside those listed below.
  Exhaustive matches must classify the new command/public-codec, replay,
  snapshot, persisted-identity, and consumer-build vector.

- **keiro-core**, **keiro**, **keiro-dsl**: require Keiki 0.7
  (`keiki >=0.7 && <0.8`, and `keiki-codec-json >=0.7 && <0.8` where used).
  Keiki now classifies a predicate that crosses a one-way generated projection
  conservatively: symbolic verification may return `UnverifiedOpaque` where an
  earlier release reported a verified result. Runtime command execution and
  replay behavior are unchanged. Consumers that require a proof-strength
  `Verified*` result must provide an exact projection with its reverse witness;
  conformance tooling must preserve the unverified classification instead of
  relabelling it as source-proved.

- **keiro-dsl**: `DiagnosticCode` gains the append-only
  `EventOutputCommandMismatch` and `AggregateEventlessStateChange`
  constructors. Exhaustive matches must be extended. Version-2 transitions
  that change vertex or registers without emitting an event are now rejected;
  an empty accepted edge is legal only as a true no-op.

- **keiro-dsl**: requires `keiro-core ^>=0.7.0.0`. The 0.6.0.0 library
  dependency on `keiro-core` carried no version constraint; the bound is now
  explicit and moves in lockstep with the set.

### New Features

- **keiro-core**: adds the public `Keiro.Codec.IdDomain` module — the frozen
  `keiro-dsl/id-domain/typeid-v7/1` runtime contract for prefix-bearing
  identifiers. Admission requires canonical lowercase TypeID-v7 text, the
  declared prefix and one underscore, a 26-character Crockford suffix, and
  UUIDv7 version/variant bits; `idDomainTextPattern` yields the matching exact
  Keiki projection domain. **keiro** re-exports the module, so generated
  version-3 bindings keep a single direct `keiro` dependency.
- **keiro-dsl**: adds `language keiro-dsl 3`, selecting
  `keiro-dsl/runtime-semantics/2`, with prefix-bearing IDs on the enforced
  `keiro-dsl/id-domain/typeid-v7/1` contract. Generated and consumer-bound v3
  IDs validate before binding conversion, current JSON decoding, literals, and
  scaffold samples. Historical generated-event decoding retains an explicitly
  named internal legacy constructor, while the same malformed text is rejected
  at current command/public decoding with its JSON field path. Domain adoption
  emits `IdDomainContractChanged`: old history remains readable, old snapshots
  miss, public consumers break, consumer builds are advisory, and rollout is
  producer-last.
- **keiro-dsl**: plans one deterministic Haskell owner for every generated
  service-level ID and enum across single-file and multi-file services.
  Aggregate rings import only their resolved uses, unused declarations are not
  imported into unrelated domains, and member reordering or ownership moves
  leave generated nominal type identity unchanged.
- **keiro-dsl**: adds the public `CheckedService`/`EffectiveLanguageContract`
  semantic boundary. Single-source and workspace CLI routes retain the selected
  contract through validation, scaffold and harness planning, generated fold
  fingerprints, diff, replay-impact analysis, inspection JSON, and additive
  scaffold-record rows. `Spec`-only APIs remain explicit legacy/version-1
  compatibility wrappers, and grammar-only v1/v2 differences preserve generated
  and fold bytes.
- **keiro-dsl**: supports type-safe same-declaration ID and enum equality in
  generated aggregate guards. Consumer `KindID` IDs and finite enums use exact
  Keiki 0.7 projection domains with reconstructible models; legacy generated
  `Text`-backed IDs execute concretely but remain conservatively unverified
  until their construction domain is enforced. Cross-declaration,
  nominal-to-`Text`, and unqualified enum comparisons fail during checking.
- **keiro-dsl**: generates version-2 `fields(Command)` event values directly
  from a checked total identity mapping. Direct, aliased-wire, optional,
  nominal, `Time`, `Natural`, and structural fields no longer pass through a
  create-once identity-copy output hook. Explicit event fields remain
  hand-owned, while obsolete generated-identity functions are reported and
  cannot affect runtime execution.
- **keiro-dsl**: adds complete finite aggregate behavior accounting.
  `behavior-obligations FILE --format=text|json` inventories every live
  transition from a live-reachable state, every reachable rejection cell, and
  every replay-only transition for single specs and workspaces. Additive
  scaffold records retain stable semantic keys and owning members without
  claiming consumer fill status.
- **keiro-dsl**: generates a typed `BehaviorContract` and create-once
  `BehaviorHoles` witness list per version-2 aggregate. The compiled
  `keiro/behavior-conformance/1` report reconciles required, filled, pending,
  missing, duplicate, stale, failed, verified, and unverified keys; exact
  Keiki 0.7 edge attribution, codec-crossing replay, event values, final vertex,
  and every register are checked. Completeness fails by default, while honest
  Hole/unknown proof surfaces are separately gateable with
  `--fail-on-unverified`.

### Bug Fixes

- **keiro-dsl**: parses the optional `language keiro-dsl N` preamble only after
  leading trivia and before `context`. Nested `language` fields and declarations
  no longer look like misplaced or duplicate preambles, and version-2 feature
  gates now arise from their grammar productions instead of raw source
  substrings. Comments, strings, wire keys, and legal identifiers containing
  `using`, `Integer`, `implementation hole`, `reg.`, or `cmd.` remain inert.

## 0.6.0.0 — 2026-07-31

All published packages move to 0.6.0.0 together. The cycle is dominated by
`keiro-dsl`, which gains an explicit source-language contract, nominal consumer
bindings, and authoritative scalar aggregate expressions. `keiro-core` and
`keiro` gain the nominal codec surface and move to Keiki 0.6; `keiro-pgmq` and
`keiro-migrations` are released with the set.

### Breaking Changes

- **keiro-core**, **keiro**: require the exact-`Integer` / total-`Natural`
  Keiki releases (`keiki >=0.6 && <0.7`, `keiki-codec-json >=0.6 && <0.7`),
  replacing the previous `>=0.4 && <0.5` bounds.
- **keiro**, **keiro-pgmq**: the internal `keiro-core` bound moves to
  `^>=0.6.0.0`.
- **keiro-dsl**: `DiagnosticCode` gains the aggregate-type codes
  (`AggregateTypeUnknown`, `AggregateTypeUnsupportedAtUse`,
  `AggregateRegisterInitialInvalid`, `AggregateGuardTypeMismatch`,
  `AggregateGuardCapabilityUnsupported`), the source-language codes
  (`WorkspaceLanguageVersionMismatch`, `SourceLanguageDeclarationChanged`), the
  nominal check and diff codes, and the scalar-expression codes. The additions
  are append-only, but exhaustive matches must be extended.
- **keiro-dsl**: the public expression AST gains located arithmetic, scalar
  literals, explicit roots/paths, and transition implementation ownership;
  aggregate command/event fields use the located `AggregateField` type and
  aggregate register types use `TypeExpr` instead of a raw `Name`. Exhaustive
  matches over `Expr`, `TypeExpr`, or transition implementation must be
  extended.

### New Features

- **keiro-core**: adds the public total `Keiro.Codec.Nominal` binding and
  fixture API that generated nominal consumer codecs are checked against;
  **keiro** re-exports it so generated consumers keep a single direct
  dependency.
- **keiro-dsl**: adds an explicit source-language contract. A
  first-significant-clause `language keiro-dsl 1` preamble selects the frozen
  released v1 parser before body parsing; unsupported future versions fail at
  that boundary, and unversioned input remains readable as
  `legacy-unversioned` and is never silently rewritten. Adds
  `Keiro.Dsl.LanguageVersion`, `keiro-dsl inspect FILE --format=json`, and
  source-language rows in scaffold and workspace records.
- **keiro-dsl**: adds language version 2 syntax and the public total
  `Keiro.Codec.Nominal`-backed binding path for consumer-owned aggregate IDs,
  enums, and nominal scalar wrappers, with a checked nominal registry,
  prefix-safe `KindID` codecs, closed private enum representations, and
  diff-visible nominal provenance.
- **keiro-dsl**: adds `Keiro.Dsl.AggregateType`, the single resolution and
  capability policy shared by validation, lowering, imports, packages, samples,
  fold fingerprints, diffs, replay impact, and scaffold refusals. Direct
  aggregate `Time` and `Natural` fields and registers now check, scaffold,
  compile, encode, snapshot, and replay.
- **keiro-dsl**: adds authoritative version-2 scalar aggregate expressions —
  typed `reg.`/`cmd.` roots, required structural scalar paths, all scalar
  literal families, exact `Integer` `+`/`-`/`*` and total `Natural`
  `+`/monus/`*` — plus generated per-aggregate `Expressions` and `Transducer`
  modules. Every version-2 transition is exclusively generated-owned or
  explicitly `implementation hole`. Version-1 generated output remains frozen.

### Other Changes

- Language extensions are centralized in the shared cabal stanzas and the tree
  is reformatted onto the latest Fourmolu template. No behaviour change.

## 0.5.0.0 — 2026-07-31

All published packages move to 0.5.0.0 together. The entire cycle is
`keiro-dsl`; `keiro-core`, `keiro`, `keiro-pgmq`, and `keiro-migrations` have no
changes and are released with the set.

### Breaking Changes

- **keiro-dsl**: `DiagnosticCode` gains nine append-only constructors
  (`WorkspaceMemberUnreadable`, `WorkspaceMemberParseFailed`,
  `WorkspaceContextMismatch`, `WorkspaceAuthorityConflict`,
  `WorkspaceDuplicateDeclaration`, `WorkspaceDuplicateNodeName`,
  `WorkspacePathCollision`, `OwnershipMoved`, `WorkspaceAuthorityChanged`),
  `ScaffoldRun.Refusal` gains `GoldenRootDivergence`,
  `ScaffoldRun.WriteDisposition` gains `Unchanged`, and `DiffReport.Remedy`
  gains `RemedyRescaffoldWorkspace`. Exhaustive matches over these types must be
  extended; no existing behaviour changed.

### New Features

- **keiro-dsl**: adds **service workspaces**. A `.keiro-workspace` manifest names
  a service and lists its member `.keiro` files, and the whole toolchain now
  operates on the composed service:

  - `check <manifest>` validates the members as one contract — shared ids,
    enums, rules, and mapped structural types resolve once across all members,
    so an aggregate in one file may use a declaration owned by another or feed a
    read model declared in a third. Composition refuses on context disagreement,
    manifest-authority conflicts, duplicate declarations or nodes, and
    case-folded generated-path collisions, citing every relevant file.
  - `scaffold <manifest> --out DIR` emits the complete module set for every
    member in one atomic invocation, with workspace-keyed history, per-module
    member ownership (so a node moved between files is an ownership move, not a
    stale/new pair), observable idempotence, and evidence-based adoption of
    pre-existing per-context output.
  - `diff <manifest> --since <rev>` composes the historical workspace from git
    and diffs it as one service, annotating findings with owning file and line
    and adding non-blocking `OwnershipMoved` / `WorkspaceAuthorityChanged`
    consumer-build advisories.

  A single `.keiro` file is unchanged and behaves as a one-member workspace; the
  `keiro-dsl/diff-report/1` JSON schema and all single-file report bytes are
  preserved. Recorded as ADR-14 and ADR-15, with ADR-4 amended.

## 0.4.0.1 — 2026-07-28

### Other Changes

- Adds PVP upper bounds to every dependency that previously carried a lower
  bound only, so `cabal check` reports no packaging warnings. No API or
  behaviour change from 0.4.0.0, which was tagged but never published.


## 0.4.0.0 — 2026-07-28

### Breaking Changes

- `Keiro.Timer.scheduleTimerOnceTx` now returns `Bool`: `True` when the
  first-arm-wins insert created the timer row, and `False` when an existing row
  won. Callers that discarded its former `()` result can continue to use
  `void`.
- `Keiro.Workflow.Child.Schema.ChildRow` gains `failureReason`, and
  `markChildFailedTx` now requires the failure reason as its third argument.
  Migration `0020-keiro-workflow-children-failure-reason.sql` adds the nullable
  `failure_reason` column used by the new field.
- `StateCodec` gains a `stateShapeHash` compatibility field, and aggregate
  snapshot lookup now requires codec version, register-layout hash, and
  control-state/fold hash to match. Migration
  `0019-keiro-snapshots-state-shape-hash.sql` adds the corresponding
  `state_shape_hash` column; existing rows receive the empty sentinel and are
  invalidated once on their next hydration. `keiro-core`, `keiro`, and
  snapshot-enabled generated code now require `keiki >=0.4 && <0.5`.
- Validated event-stream construction now rejects an event codec whose schema
  version, event tags, or upcaster chain fail `mkCodec`. Restore missing rungs
  or deduplicate conflicting sources before deployment; for emergency
  forensics only, `mkEventStreamUnchecked` remains the explicit bypass.
- The package set now requires Keiki 0.4 (and keiki-codec-json 0.4 where used).
  Exhaustive term and validation handling must account for typed structural
  field projections and their guard-only/direct-base restrictions.

### New Features

- Structural consumer mappings gain create-once binding skeletons, granular
  newly-required-hole reporting, exact opt-in `GHC.Generics` bindings, and
  `keiro-dsl check --explain-bindings`; wire policy remains exclusively in the
  checked declaration and generated codec.
- `keiro-dsl` gains a historical-codec comparison engine
  (`Keiro.Dsl.CodecCompare`) plus `scaffold --codec-comparison`/`--comparison-out`,
  proving a migration by classifying RFC 8785 canonical-JSON parity between the
  declared codec and a historical one and reporting branch-coverage gaps. The
  generated comparison module and runner are non-production evidence, never a
  wire authority.
- `keiro-dsl` gains reporting-only structural and opaque coverage
  (`Keiro.Dsl.Coverage`) via `check --coverage-report` and
  `diff --coverage-report`, with opt-in `check --fail-on-opaque` and
  `diff --fail-on-opaque-increase` gates for private persisted roots.
- `keiro-dsl` now accepts checked structural and opaque consumer-type declarations with nested
  records, enums, tagged unions, collections, optional/default policies, canonical identities,
  binding or codec provenance, and register initials. Its resolved type graph drives stable
  validation diagnostics, root-aware compatibility vectors, replay impact, and deterministic
  `--emit-goldens` weak stand-ins without treating consumer JSON instances as wire authority.
- `keiro-core` publishes `Keiro.Codec.Structural`, and `keiro` re-exports it,
  providing total structural bindings, deterministic labelled fixture corpora,
  both round-trip law helpers, and one-way generated JSON delegation.
- Durable workflows can be returned from terminal failure with
  `Keiro.Workflow.Instance.resurrectFailedWorkflow`. The transactional API
  resets retry/lease state, removes only the derived current-generation failure
  marker, revives failed child links, and preserves append-only failure history.
- `WorkflowRunOptions` gains the additive `leaseHeartbeat` option plus the
  `LeaseHeartbeat` and `WorkflowLeaseLost` contracts. Resume workers populate it
  automatically and classify mid-run lease loss as `leaseSkipped` without
  consuming a crash attempt.
- `keiro-dsl` now lowers same-version event upcasters into one
  `EventType`-dispatching rung, so unrelated event kinds pass through
  unchanged, and supports `diff --emit-goldens DIR` plus
  `scaffold --goldens DIR` to capture and embed genuine old payload shapes in
  generated conformance harnesses.
- Scaffolded workqueues now include a `QueueCodec` module with a versioned
  `keiroJobCodec` envelope from schema version 1. Fresh queues need no migration;
  drain a queue before replacing an existing bare-payload codec (or use a
  transitional codec) so in-flight messages are not dead-lettered.
- `keiro-dsl check` now rejects duplicate and incomplete aggregate upcaster
  chains, supports a mutually exclusive `retiring event` marker, and warns
  when deprecated events lack the replay-only transition required to hydrate
  old payloads.
- `keiro-dsl diff` now reports vanished upcaster rungs as breaking and
  distinguishes hazardous event deprecation from the replay-safe
  deprecated-plus-replay-only cutover. Versioned old-payload JSON goldens now
  exercise `decodeRaw` in the v2 conformance suite.
- `defaultStateCodec` derives a control-state discriminator through Keiki's
  `CanonicalStateShape`; `withFoldFingerprint` composes an explicit fold token
  as `<state-hash>;fold=<fingerprint>`.
- `keiro-dsl` derives a deterministic fingerprint from aggregate states,
  register initials, transitions, and referenced rules, lowers it into
  generated snapshot codecs, and emits the non-breaking
  `AggFoldSurfaceChanged` advisory when that replay surface evolves.
- `keiro`: `Keiro.version` now reports the current package version. It had
  been left at `"0.1.0.0"` since the initial scaffold while the package
  shipped 0.2.0.0 and 0.3.0.0; keep it in lockstep with `keiro/keiro.cabal`
  when cutting a release.

### Bug Fixes

- Active workflow patch sets are now recorded atomically with the seed when
  `continueAsNew` opens a generation, so an asynchronous wake append before the
  first run cannot silently force every patch decision to the old branch.
- Resume-worker leases renew before fresh step actions and unresolved await
  arms. A healthy multi-step advance no longer loses ownership merely because
  its original claim aged past `leaseTtl`; operators should size the TTL above
  the longest individual action or arm.
- Workflow sleep timer fires are pinned to the generation that armed them,
  including legacy timer payloads recovered from deterministic timer ids. A
  stale re-fire after `continueAsNew` can no longer resolve a same-named sleep
  on the next generation.
- Workflow sleep re-arms no longer postpone `wake_after`, and firing clears the
  hint atomically with the journal append, so an already-fired sleeper is
  rediscovered promptly.
- Workflow GC now deletes scheduled sleep timers as well as terminal timer
  rows, and sleep firing cancels itself against a surviving terminal instance.
  A timer can no longer resurrect and re-execute a cancelled workflow after
  its journal and instance data were collected.
- Workflows using journal snapshots no longer suspend forever when a child,
  awakeable, or sleep completion was journaled while a run was mid-flight but
  omitted from that run's snapshot. The `awaitStep` miss path now falls back to
  the authoritative workflow-step index before arming and suspending.
- Failed children now preserve their terminal reason on the child link, and
  `awaitChild` raises `WorkflowChildFailed` from that row even after the parent
  rotates past the generation containing the original failure sentinel.
- Awakeable rows are now registered before their ids can escape a journaled
  allocation step, so an immediate external signal is no longer mistaken for
  an unknown id.
- `signalAwakeable` now re-reads status inside its transaction when a guarded
  completion loses a race. If cancellation won, it returns `False` without
  appending a result, preventing both compensation and completion from firing.

## 0.3.0.0 — 2026-07-14

A dependency-realignment release across the package set. `keiro-migrations` and
`keiro-pgmq` now sit on one `pg-migrate` 1.1 family together with Kiroku, so a
single ledger owns the kiroku, keiro, and pgmq migration components. `keiro-core`,
`keiro`, and `keiro-dsl` have no source changes and are released at 0.3.0.0 to
stay in lockstep with the set.

With this release every dependency in the default build plan resolves from
Hackage: `codd` and `codd-extras` remain the only non-Hackage packages, and they
are reachable only through the manual `legacy-codd-tools` flag, which is off by
default.

### Breaking Changes

- `keiro-migrate check` now takes the manifest as `--manifest PATH` instead of a
  positional argument, following the `pg-migrate-cli` 1.1.0.0 parser.
- `Keiro.Test.Postgres.withMigratedSuiteWith` now takes `[MigrationComponent]` —
  extra `pg-migrate` components appended to the framework plan — instead of a
  `Text -> IO ()` hook that ran its own migration against the template database.
  A `pg-migrate` ledger is shared by every component in it, so a second plan that
  omitted Kiroku's and Keiro's components failed strict verification with
  `UnknownStoredMigration`. Suites that installed extra schema (such as PGMQ) now
  pass the component itself: `withMigratedSuiteWith [pgmqMigrations]`.

### Changed

- Upgraded `kiroku-store` to 0.3.0.1, `kiroku-store-migrations` to 0.3.0.0, and the
  `pg-migrate` package family to 1.1.0.0 in `keiro-migrations` and
  `keiro-test-support`. This realigns Keiro's pg-migrate version with the one
  Kiroku's migration component requires — the previous `^>=1.0.0.0` bounds excluded
  pg-migrate 1.1 and so could not resolve alongside `kiroku-store-migrations` 0.3.
  From `kiroku-store` 0.3.0.1, a failure raised inside an opaque `runTransaction`
  body now preserves its SQLSTATE and server message instead of surfacing as
  `StreamNotFound (StreamName "<transaction>")`.
- Upgraded `keiro-pgmq` to `shibuya-pgmq-adapter` 0.12.0.0 and the `pgmq-*` 0.4
  package family, which is what aligns the PGMQ path with pg-migrate 1.1. The
  adapter's own API is unchanged; the notable fix is that idle streams now observe
  shutdown, so a processor with nothing to consume finishes on request instead of
  polling until it is forcibly cancelled. `shibuya-core` stays at 0.8.0.1 (already
  the latest).
- Dropped the `hasql-migration` `source-repository-package` pin from
  `cabal.project`. It existed only because `pgmq-migration` 0.3 depended on
  `hasql-migration`, whose Hackage release does not build against hasql 1.10;
  `pgmq-migration` 0.4 is a native `pg-migrate` component and nothing in the build
  plan depends on it now.

## 0.2.0.0 — 2026-07-13

A major release across the package set. The headline changes are the relocation
of Keiro's framework tables into a dedicated `keiro` PostgreSQL schema, stricter
replay-contract validation on the Keiki 0.2 core, durable dead letters for
rejected dispatches, and a substantially expanded `keiro-dsl` spec surface
(read models, routers, snapshots, queue ordering, and workflow evolution).

### Breaking Changes

- **Keiro's framework tables moved out of the `kiroku` schema into a new,
  dedicated `keiro` PostgreSQL schema that Keiro creates and owns.** Every
  runtime query is now schema-qualified (`keiro.keiro_snapshots`,
  `keiro.keiro_timers`, `keiro.keiro_outbox`, …) and no longer depends on
  `search_path`. `keiro-core` exports the new `Keiro.Schema.keiroSchema` as the
  single source of truth for the name. Existing databases must run the
  `keiro-migrations` bootstrap, which creates the schema and relocates the
  tables; application SQL that read bare `keiro_*` relations must be re-qualified.
- `runCommandWithSql`, `runCommandWithSqlEvents`,
  `runCommandWithProjections`, and the process-manager/router runners now
  require `KirokuStoreResource` so transactional appends can apply Kiroku's
  configured `enrichEvent` hook. Acquire the store with `withKirokuStore` and
  interpret `Store` with `runStoreResource`; plain `runCommand` is unchanged.
- Read-model queries no longer auto-register missing registry rows. Applications
  must call `registerReadModel` at projection startup; unknown models now return
  `ReadModelUnregistered` without mutating the registry.
- `ReadModel` now requires a `strongScope :: StrongScope` field. Use
  `EntireLog` for all-stream subscriptions or `CategoryHead category` for a
  category subscription so unrelated traffic cannot hold `Strong` reads behind.
- `ReadModel` now also requires a `schema :: Text` field naming the PostgreSQL
  schema its data table lives in. Keiro does not rewrite `query`; qualify the
  application's SQL with `qualifiedTableName` or `Keiro.Connection.qualifyTable`.
  The field is Haskell-level wiring only and is deliberately not persisted in the
  `keiro.keiro_read_models` registry.
- `AsyncProjection` now requires `readModelName`, naming the registry row that
  fences writes during a rebuild.
- `PMCommandResult.PMCommandFailed` now carries the target `StreamName` alongside
  its `CommandError`, so worker policy can identify the failing target.
- `WorkerOptions` gains a `rejectedCommandPolicy :: RejectedCommandPolicy` field,
  and `ShardedWorkerOptions` gains `handlerRetryDelay :: RetryDelay` and
  `retryPolicy :: RetryPolicy`. Record construction must supply them; the
  `defaultWorkerOptions` and `defaultShardedWorkerOptions` defaults are unchanged
  in behavior.
- `applyAsyncProjection` now returns `AsyncApplyOutcome` (`AsyncApplied`,
  `AsyncDuplicate`, or `AsyncFenced`) and live workers must not checkpoint a
  fenced event. Rebuild replayers use `applyAsyncProjectionUnfenced` between the
  new atomic `startRebuild` and guarded `finishRebuild` helpers.
- `keiro-migrations` now exports a native `pg-migrate` component and composes
  Kiroku through an explicit component dependency instead of a combined Codd
  migration-set API.
- Router deterministic command ids are now derived from the resolved target
  stream name and same-stream occurrence rather than the target's list position.
  A transition point-probe recognizes legacy positional ids for stable resolver
  output and may be removed in a later release. If both the deployment version
  and resolver output change between attempts, a target command may be
  dispatched at most one extra time across that one-time upgrade window.
- `runWorkflow`, `runWorkflowWith`, and the child-workflow runtime now require
  `Error StoreError` in their effect rows so post-commit workflow snapshot
  failures can be caught without leaving the typed error channel.
- `mkEventStream` now rejects snapshot codecs that cannot encode their initial
  state and register file. Snapshot-enabled streams built from
  `emptyRegFile` must initialize every slot before validation.
- Keiro now requires post-MP-16 Keiki 0.2. Stream validation runs the new
  head-recoverability, inversion-ambiguity, unguarded-input-read, and
  state-changing-silent-edge checks; any warning makes `mkEventStream` reject
  the stream at startup.
- `HydrationReplayFailed` now carries a typed `HydrationReplayReason` alongside
  the failing stream version. The reasons distinguish no inverting edge,
  ambiguous inversion, queue mismatch, and a truncated multi-event chain.
  `CommandError` also gains `CommandAmbiguous`, carrying matched edge indices.
- A command matching multiple transitions is now reported as
  `CommandAmbiguous` instead of `CommandRejected`. Process managers and routers
  halt on this aggregate-definition bug, while generated timer dispositions
  route it through their on-error arm rather than benign on-reject handling.
- The `hydration_replay_failed` telemetry class is replaced by four
  reason-specific `error.type` values, and `command_ambiguous` is new.
  Dashboards keyed on the old hydration class must be updated.
- `validateEventStreamWith` and `mkEventStreamWith` now force-enable Keiki's
  head-recoverability and state-changing-epsilon checks. Caller-supplied
  options may only strengthen validation at Keiro's durable boundary; use the
  explicitly unsafe `mkEventStreamUnchecked` only for tests and emergency
  forensics, never production streams.
- `keiro-dsl`: the process `saga` clause is now
  `saga <Aggregate> category "<camelCase>"`, replacing
  `saga <Aggregate> stream="<prefix>-" <> correlationId`; `process` nodes must
  declare node-level `rejected` and `poison` policies; every timer `fire`
  disposition must carry an `on-ambiguous` arm; identifiers are restricted to
  ASCII and checked for Haskell hygiene; and numeric literals exceeding
  `maxBound :: Int` are rejected instead of silently wrapping. Validation is
  substantially stricter overall, so specs that checked under 0.1.0.0 may now be
  rejected. See `keiro-dsl/CHANGELOG.md` for the full list.
- `keiro-dsl`: `scaffold` now plans the whole module set before writing any byte
  and refuses to overwrite a `Generated` path lacking the `@generated` banner
  (override with `--force-generated-overwrite`). `diff` gained a `WARNING:` tier
  and reformatted its change lines; only `BREAKING:` changes exit non-zero.

### New Features

- Durable dispatch dead letters. New `Keiro.DeadLetter`,
  `Keiro.DeadLetter.Schema`, and `Keiro.DeadLetter.Replay` modules let
  process-manager and router workers park a rejected dispatch instead of halting.
  `RejectedCommandPolicy` selects `RejectedHalt` (the default),
  `RejectedDeadLetter` (persist to the new `keiro.keiro_dead_letters` table and
  acknowledge), or `RejectedSkip`. `replaySubscriptionDeadLetters` re-runs a
  caller-supplied handler over the rows Kiroku parked in `kiroku.dead_letters`
  without deleting or mutating those Kiroku-owned rows.
- New `Keiro.Connection` module for application read-model and projection tables:
  `qualifyTable`, `quoteIdentifier`, `withProjectionSchema`,
  `keiroConnectionSettings`, and the opt-in `ensureProjectionSchema`. The store
  connection's `schema` stays `kiroku` because it drives the `LISTEN`/`NOTIFY`
  channel; a projection schema is reached by qualification and/or
  `extraSearchPath`.
- Acknowledgement-aware sharded subscriptions: `runShardedSubscriptionGroupAck`
  with `ShardAck`, `ShardDelivery`, and `ShardEventHandler`, plus per-event retry
  and dead-letter dispositions. `runShardedSubscriptionGroup` remains as the
  compatibility wrapper.
- New telemetry: `keiro.dispatch.deadlettered`, `keiro.subscription.deadlettered`,
  `keiro.snapshot.encode.failures`, `keiro.snapshot.decode.failures`,
  `keiro.snapshot.read.hits`, `keiro.snapshot.read.misses`, and
  `keiro.snapshot.apply.divergence`. `Keiro.Telemetry.kirokuEventBridge` installs
  on Kiroku's `eventHandler` to observe the terminal retry-exhaustion signal.
- `keiro-dsl` gained a first-class `readmodel` node (typed columns, shape-hash
  drift detection, consistency/scope/feed validation) and a `router` node for
  stateless content-based routing, both with generated runtime modules and typed
  holes. Query operations and PGMQ dispatch dedup references now genuinely resolve
  against declared read models — they were deferred no-ops in 0.1.0.0.
- `keiro-dsl` gained aggregate `snapshot` policies with a captured state-codec
  fixture, workqueue `ordering` and provisioning (FIFO, group keys, unlogged,
  partitioned), intake `persist` posture, and durable-workflow evolution via
  guarded `patch` blocks and terminal `continueAsNew`. `diff` was rebuilt on an
  exhaustive node-family registry, so a new node kind can no longer be silently
  classified as safe.
- `keiro-migrations` appended `0018`, creating `keiro.keiro_dead_letters`.

### Bug Fixes

- Sharded subscription readers now acknowledge each event only after its handler
  returns. A shed or rebalanced bucket's checkpoint can no longer cover an
  unprocessed event.
- `keiro-dsl` string literals now decode and re-render the closed DSL escape set,
  so topics, emit maps, and quoted field bindings survive a parse/pretty-print
  round trip. The scaffolder also escapes payload literal splices, closing a
  template-injection path where a quoted spec literal could break out of the
  generated Haskell string.

### Other Changes

- Command hydration now detects stream-version gaps caused by Kiroku
  per-stream truncation and returns `HydrationGapDetected` unless a snapshot
  covers the hidden prefix.
- Transactional command runners now apply Kiroku's configured `enrichEvent`
  hook before event preparation, so persisted events and the
  `runCommandWithSqlEvents` callback observe the same enriched metadata as
  plain `runCommand`.
- The shared PostgreSQL test fixture now provisions templates through the
  native Kiroku/Keiro migration plan. Codd transition and remediation tests are
  retained behind the manual `legacy-codd-tools` flag.
- Router and process-manager duplicate-event rejections are now confirmed
  against the intended target stream before being treated as benign.
  Unconfirmed cross-stream or id-less collisions surface as command failures,
  causing workers to halt instead of silently dropping a dispatch.
- Aggregate snapshot encoding is forced before the store write. An `ErrorCall`
  from a partial state encoder or uninitialized register is swallowed after the
  event append and counted instead of escaping a successful command.
- Workflow snapshot writes after steps, completion, and continue-as-new
  rotation are advisory: store failures are swallowed and counted after the
  journal append commits.
- Added `keiro.snapshot.encode.failures`,
  `keiro.snapshot.decode.failures`, `keiro.snapshot.read.hits`, and
  `keiro.snapshot.read.misses`; snapshot lookup APIs now retain miss and decode
  reasons while compatibility wrappers preserve the previous `Maybe` surface.
- Corrected snapshot documentation: version non-regression applies within one
  codec version and shape hash, while an incompatible codec can replace a newer
  row to permit rollback. Upgrade notes cover the full-replay miss caused by
  Keiki EP-78's stable shape hash.
- Kiroku 0.3/0.2, Keiki 0.2, and pg-migrate 1.0 now resolve from Hackage; their
  obsolete Git package overrides and local Cabal overlay are no longer needed.
- `RunCommandOptions.verifyReplayOnAppend` defaults on. Both command append
  paths replay each just-committed batch from the pre-command state, count an
  unreplayable batch through `keiro.snapshot.apply.divergence`, and attach a
  bounded typed reason to `keiro.replay.divergence` without turning an already
  committed command into a reported failure.
- No-op commands now report `CommandResult.globalPosition = Nothing` instead
  of exposing Kiroku's per-stream-read sentinel `GlobalPosition 0`. Appended
  commands continue to report the real store-assigned position.
- Exported additional runtime helpers so custom workers can reuse the framework's
  classification logic: `commandErrorClass`, `isRejectionClass`,
  `decideForFailures`, `DispatchFailure`, `confirmBenignDuplicate`,
  `deterministicRouterCommandId`, `ReadModel.categoryHeadPosition`,
  `ReadModel.qualifiedTableName`, `StrongScope`, and `RebuildError`.
- Documented previously implicit runtime contracts: the inbox deduplication window
  closes when `garbageCollectCompleted` removes a completed row; outbox
  `created_at` is transaction-start time, so `PerKeyHeadOfLine` and
  `PerSourceStream` ordering is best-effort unless the caller serializes same-key
  enqueues; the default timer worker has no attempt ceiling and requeues claims
  left `Firing` for five minutes; and process-manager `correlate` joins across
  streams must be order-insensitive.
- Added upper bounds alongside the move to Hackage: `keiki >=0.2 && <0.3`,
  `keiki-codec-json >=0.2 && <0.3`, and `kiroku-store >=0.3 && <0.4`.
- `keiro-dsl` added conformance suites that round-trip every node family, compile
  every `keiro-dsl new <kind>` starter, and cold-start the new read-model, router,
  snapshot, queue-ordering, and workflow-rotation surfaces against the live
  runtime.

## 0.1.0.0 — 2026-07-05

Initial Hackage release of the Keiro package set.

### Breaking Changes

- Established `ValidatedEventStream` as the command-boundary contract for the
  runtime packages. Existing pre-release git users should construct validated
  streams with `mkEventStream`, `mkEventStreamWith`, or `mkEventStreamOrThrow`.
- Finalized the `keiro-core` stream, codec, and event-stream contracts for the
  first public package set.
- Renamed the typed-spec file extension from `.kdsl` to `.keiro` before the first
  public `keiro-dsl` release.

### New Features

- `keiro-core`: shared typed contracts for streams, codecs, event streams,
  replay-safety validation, integration events, and snapshot policies.
- `keiro`: command runners, projections, read models, snapshots, process
  managers, routers, timers, outbox/inbox integrations, subscription workers,
  telemetry, and durable workflows.
- `keiro-pgmq`: typed PGMQ jobs, codecs, runtime workers, retry and DLQ
  policies, FIFO/message-group support, queue provisioning, metrics, and trace
  propagation.
- `keiro-migrations`: embedded codd migrations and the `keiro-migrate`
  executable for installing and upgrading Keiro database schema.
- `keiro-dsl`: parser, checker, diff engine, scaffold generator, harness emitter,
  configurable module placement, starter skeletons, and conformance suites for
  `.keiro` specifications.

### Bug Fixes

- Hardened runtime behavior across command retries, snapshots, projections,
  process-manager/router dispatch, timers, subscriptions, workflows, and
  inbox/outbox recovery.
- Fixed PGMQ job decode handling, retry tuning validation, queue-name
  disambiguation, and direct job draining without the shibuya runner.

### Other Changes

- Added release metadata, documentation, Haddocks, user guides, migration guides,
  operational references, and guide-backed examples across the package set.
