# The authoring loop

Run everything from the repo root (`/Users/shinzui/Keikaku/bokuno/keiro`).

### 1. Write the spec

Author `service.keiro` in the notation (`NOTATION.md`). Start with `language keiro-dsl 4`, then
write `context <name>` and exactly the nodes the feature needs. Language 4 includes the released
consumer-owned nominal syntax, generated TypeID admission, typed contract TypeID fields, and the
strict service surface. Prefer the smallest spec that captures the decisions;
the deterministic boilerplate is derived, so don't hand-write it.

### 2. Parse (sanity)

```bash
cabal run keiro-dsl -- parse service.keiro
```

It echoes the spec pretty-printed. A parse error is line-numbered; fix the notation.
For a multi-file service, parse the `.keiro-workspace` manifest to inspect its canonical
member order.

To audit source-language provenance rather than normalized notation, inspect the source or
workspace:

```bash
cabal run keiro-dsl -- inspect service.keiro --format=json
```

Declared version 4 is reported as `stable`. Versions 1 through 3 are reported as
`compatibility-only`; an unversioned source is reported as `legacy-unversioned` with effective
version 1. Inspection and parse/pretty preserve all of those source forms without silently
rewriting them. An unsupported future version is rejected before its body is parsed.

`check`, `scaffold`, and the working-tree side of `diff` print a one-line stderr notice
naming the effective contract whenever a source is compatibility-only. It is a notice, not a
diagnostic: it has no code, does not affect the exit status, and is not something to silence.
Treat it as the prompt to declare `language keiro-dsl 4` and fix whatever that surfaces.

### 3. Check (the gate — before any Haskell)

```bash
cabal run keiro-dsl -- check service.keiro ; echo "exit=$?"
# add --emit to pretty-print the parsed spec on success (folds parse + check)
```

`OK` / exit 0 means every required decision is present and no dangerous inversion is stated
the wrong way. Any `error[Code]` (exit non-zero) names the rule and line — fix the spec, not
the generated code. Warnings (e.g. benign-inversion notices) are informational and pass.
For a multi-file service, pass the manifest path to the same command. `check` composes all
members first, resolves cross-file references once, and cites each owning file and line.

The canonical CI invocation is:

```bash
cabal run keiro-dsl -- check service.keiro \
  --min-language 4 \
  --deny-warnings \
  --report-out build/keiro-check-report.json
```

`--min-language 4` requires the stable released contract, so a spec cannot quietly sit on
compatibility-only semantics. `--deny-warnings` turns every warning this invocation emits
into exit 1 without changing its severity; `--deny CODE[,CODE...]` (repeatable, comma-separated)
does the same for named codes only. A code `check` cannot emit is rejected outright rather
than accepted as a no-op, so a denial in CI is either effective or an immediate error: a
cross-revision code belongs to `diff`, and a structural-coverage code needs
`--coverage-report FILE` in the same invocation. `--report-out` writes the append-only
`keiro-dsl/check-report/1` JSON on success or failure, creating parent directories, and
covers coverage findings when coverage runs.

Many surfaces warn on released languages 1–3 and error from language 4 on. Both severities
print the same sentence, so an author reads one explanation either way — and a language-4
spec cannot state something the runtime does not do. Write the spelling that describes what
runs: `body strict`, `on-appended AckOk`, `not-mine Retry`, a `bind … from header` naming a
canonical keiro envelope header, a timer `decode unknown-status` from
`Scheduled`/`Firing`/`Fired`/`Cancelled`/`Dead`, and a non-blank timer `dead-letter` reason.

Common diagnostics you must resolve in the spec (the warning-only codes are called out):

- Syntax and generated names: positioned parse errors reject raw newlines in strings and
  duplicate `wire`, `projection`, or transition `goto` clauses. Source selection separately
  reports `InvalidLanguageVersion`, `UnsupportedLanguageVersion`,
  `DuplicateLanguagePreamble`, or `MisplacedLanguagePreamble`. `IdentUnsafeNormalization`,
  `GeneratedOccurrenceReserved`,
  `GeneratedOccurrenceCollision`, `VertexCtorCollision`, `DuplicateNodeName`,
  `DuplicateEnumCtor`, `DuplicateEnumWire`, `DuplicateIdPrefix`, `DuplicateCommandName`,
  and `DuplicateEventName` reject names that would collide or generate illegal Haskell.
- Aggregate, rule, and evolution: `StatusMapNotTotal`, `StatusMapDanglingKey`,
  `StatusMapDuplicateKey`, `WriteTargetNotRegister`, `RegisterInitialOutOfScope`,
  `UndeclaredCommand`, `UndeclaredEvent`, `UndeclaredState`, `UnreachableState`,
  `TerminalHasOutgoing`, `RuleDomainUnresolved`, `RuleNotTotal`, `RuleCaseUnknownCtor`,
  `ClockSampled`, `GuardAtomOutOfScope`, `EvtVersionMissingUpcaster`,
  `DeprecatedEventStillEmitted`, `SnapshotIntervalInvalid`, and
  `SnapshotCodecFixtureInvalid`. `WireSchemaVersionMismatch` is a warning.
- Consumer-owned nominal types: `NominalMissingIngredient`,
  `NominalInvalidHaskellSource`, `NominalInvalidQualifiedName`,
  `NominalInvalidIdentity`, `NominalInvalidIdPrefix`,
  `NominalUnsupportedRepresentation`, `NominalEmptyEnumRepresentation`,
  `NominalMissingInitialValue`, and `NominalNameCollision`. Historical version-1 sources still
  reject nominal syntax at the language boundary as `LanguageFeatureRequiresVersion`.
- Process, router, and worker policy: `SagaCategoryIllegal`, `ProcessFireAtNotInjected`,
  `ProcessDispatchIdSupplied`, `ProcessUnresolvedRef`, `ProcessFieldBindingUnresolved`,
  `ProcessTimerCeilingInvalid`, `RouterUnresolvedRef`, `RouterKeyFieldUnknown`,
  `RouterBindingUnscoped`, `RouterCommandUnknown`, `RouterReadModelUnverified`,
  `PolicyContradiction`, and `AmbiguousMarkedBenign`. `ProcessBenignInversion`,
  `PolicyDeadLetterUnused`, and `AmbiguousFollowsRejectedPolicy` are explanatory warnings.
- Integration: `DispositionIncomplete`, `DispositionDuplicateOutcome`,
  `DispositionDuplicateRetry`, `DispositionPreviouslyFailedRetry`,
  `DispositionDecodeUnboundedRetry`, `TopicAffinityMismatch`, `EmitSkipMissing`,
  `EmitUnresolvedContract`, `PublisherUnresolvedEmit`, and `IntakeUnresolvedContract`.
- Workqueue and dispatch: `WqPhysicalDivergence`, `WqDlqDivergence`,
  `WqTableDivergence`, `WqDispositionIncomplete`, `WqStoreFailureNotRetry`,
  `WqDecodeFailureNotDeadLetter`, `WqDlqWithoutCeiling`, `WqGroupKeyMissing`,
  `WqGroupKeyWithoutFifo`, `WqGroupKeyUnresolved`, `WqPartitionSpecEmpty`,
  `DispatchEnqueueUnresolved`, `DispatchDedupQueueUnresolved`, and
  `DispatchDedupFieldUnresolved`. `WqUnloggedDurability` is a warning.
- Read models: `RmShapeHashDrift`, `RmStrongInlineOnly`, `RmScopeWithoutStrong`,
  `RmUnknownColumnType`, `RmInlineFeedUnreferenced`, `RmConsistencyConflict`,
  `QueryUnresolvedReadModel`, `QueryConsistencyInvalid`, `DispatchReadModelUnresolved`, and
  `DispatchReadModelFieldUnknown`; `RmProjectionWithoutNode` is a warning.
- Workflow and operations: `WorkflowDuplicateLabel`, `WorkflowSleepDelayUnresolved`,
  `WorkflowIdFieldUnresolved`, `AwaitSignalMismatch`, `AwaitSignalValueMismatch`,
  `RunWorkflowUnresolved`, `OperationUnresolvedRef`, `WorkflowPatchDuplicate`,
  `WorkflowPatchIdInvalid`, and `WorkflowContinueAsNewNotTerminal`.

### 4. Scaffold (emit generated layer + holes)

```bash
cabal run keiro-dsl -- scaffold service.keiro --out gen/
```

You get `-- @generated` modules (overwritten every run) and create-if-absent hole modules
(`Holes.hs`, `ProcessHoles.hs`). **Re-scaffolding never clobbers a filled hole module.**

Before writing, `scaffold` refuses module-path collisions (including case-folded collisions),
unfaithful type/policy lowering, a firewall breach, or an existing Generated target without
the `-- @generated` banner. Each refusal exits 1 and writes nothing. Fix collision/lowering
problems in the spec; a firewall breach is a scaffolder bug. For a banner refusal, move or
rename hand-owned code. Only when replacing that file is deliberate, re-run with
`--force-generated-overwrite`; the flag bypasses no other gate.

On success the stderr report names every module and disposition
(`overwritten`/`created`/`skipped: already present`), the firewall verdict
(`firewall: OK (N generated modules scanned, 0 forbidden operators)`), the harness
component(s), and the generated Cabal fragment
(`keiro-dsl-cabal-fragment.context.<context>.<ext>`, the authoritative build inventory). It
also rewrites the scaffold ledger `keiro-dsl-ledger.context.<context>.txt`.
A later run may print an exit-0 `stale:` section
for recorded paths it no longer emits. Nothing is deleted: a `generated` line is a
safe-to-delete candidate after review; a `hole` line is hand-owned and must be inspected
before any deletion. A note about a different previous spec path means two specs share the
same context and `--out` (and therefore the same Cabal fragment and ledger); separate their output
directories unless that sharing is intentional. The manual firewall `grep` is no longer
needed.

Two kinds of migration refuse before writing and are applied by the same explicit flag.

An output tree still holding pre-0.11 sidecar names needs a rename. The current names are the
scaffold ledger `keiro-dsl-ledger.context.<context>.txt` (workspace form
`keiro-dsl-ledger.workspace.<service>.txt`), the conformance ledger
`keiro-dsl-conformance-ledger.txt`, and the build inventory
`keiro-dsl-cabal-fragment.context.<context>.<ext>` (workspace form
`keiro-dsl-cabal-fragment.workspace.<service>.<ext>`). Scaffold refuses with
`sidecar migration required` and lists every rename; nothing is written.

A ledger created by the legacy generated-Haskell naming edition may instead require exact source
moves such as `Service_oncall` → `ServiceOncall`. The first run refuses before writing and prints
the complete move/backup plan. Review either plan, then opt in explicitly:

```bash
cabal run keiro-dsl -- scaffold service.keiro --out gen/ --apply-name-migrations
```

Keiro rewrites exact module references in Haskell code, not comments or string/character
literals; moves every original generated and create-once source under
`.keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1/`; and installs prepared files by
same-filesystem rename. It journals source/transformed digests so an exact interrupted state can
resume and a conflicting state refuses with recovery evidence. Backups are never deleted. This is
the sole explicit exception to ordinary stale handling: unrelated module-root/layout changes and
ordinary stale hole paths remain preserve-and-review operations.

Sidecar renames are applied before the later scaffold gates run. If one of those gates then
refuses, the refusal says so explicitly: the renames are already on disk, they are idempotent
and carry no spec content, and re-running after fixing the refusal is correct. Nothing needs
to be undone.

To place the generated layer next to your domain code instead of a parallel `Generated.*`
tree, pass `--module-root <Prefix>` and/or `--collocate` (or set `module <Prefix>` / `layout
collocated` in the spec): with both, modules land at `<Prefix>.<Ctx>.<Node>.Generated.*`. The
emitted `keiro-dsl-cabal-fragment.context.<context>.txt` carries paste-ready `other-modules:`/`build-depends:`
blocks for the consuming Cabal stanza. Re-scaffold after every spec change and resolve the
stale report before adding the generated tree to a component.

For a multi-file service, pass the manifest path instead of one member. The planner sees
the complete member set before writing, emits context-level modules once, and stores
workspace-keyed history with per-module ownership. Never scaffold workspace members
independently into the same output tree after adoption.

For a runnable whole-service conformance target, declare the Cabal library that
owns the generated runtime in the workspace manifest:

```text
service my-service
runtime-package my-service-runtime
spec domain/a.keiro
spec domain/b.keiro
```

For a standalone source, pass `--runtime-package my-service-runtime`. The run
generates one `keiro-dsl-conformance.workspace.<service>` package (or the
standalone context-keyed equivalent), exposes one service facade in the runtime
manifest, and prints `conformance-target: cabal test
keiro-<service>-conformance`. Add a stable optional-package glob for these Cabal
files to the root project once; do not add a hand-written stanza per node.

### 5. Fill the holes

Open the hole modules. Language 4 generates ordinary transition guards, writes, emits, and
targets. Each remaining hole is an explicitly hand-owned boundary with a typed signature and a
`-- HOLE …` annotation—for example an `implementation hole`, projection apply, upcaster,
consumer binding, or effectful resolver. Fill the body against the **generated** names (the
TH-produced `inCtor…`/`wire…`/`…TermFields`, the `Keiro.Codec`, the `ProcessManager` wiring). Use the corpus
(`docs/corpus/keiro-dsl-corpus.md`) to see how a real spec's holes were filled. **Never edit
a `-- @generated` module** — change the `.keiro` and re-scaffold instead.

For any hand-written duplicate path, follow the generated hole note and call
`confirmBenignDuplicate :: StreamName -> EventId -> CommandError -> Eff es Bool` with the
target stream and attempted event id. Fold `True` into the duplicate outcome and preserve
`False` as the original failure. Pattern-matching `DuplicateEvent` alone is unsafe because
event ids are globally unique across streams.

Consumer-owned nominal declarations also create typed, create-once binding skeletons. Implement
both total directions and the declared fixture corpus. Do not return `Either`, hide validation in
the inverse, or move JSON policy into the binding. A refined consumer type belongs behind
`mapped opaque`.

### 6. Run the service conformance package (pin behaviour)

The scaffolder emits per-node harnesses plus one service facade. With
`runtime-package` configured, run the generated target printed by the scaffold
report, for example `cabal test keiro-my-service-conformance`. It asserts
`validateTransducer == []`, codec round-trips, read-model derivations,
disposition/time-injection/id decisions, and behavioural acceptance across the
complete service. A wrong source lowering or hole fill turns a **specific**
qualified test red.

Process, router, and workflow values are pinned in the create-once
`KeiroConformance.Expectations` module. Re-scaffolding never overwrites it. When
an intentional fact changes, inspect the focused expected/actual failure and
edit that one hand-owned baseline; do not copy the generated actual value
without review. Missing and unexpected keys fail too, so deleting or adding a
node cannot silently reduce coverage.

The runtime `keiro-dsl-cabal-fragment.*` still needs reconciliation when generated
modules or dependencies change. The runnable package removes the manual driver
and test stanza, not the runtime library's ownership of generated code.

If validation is red or startup reports `is not replay-safe`, open `TAXONOMY.md`. It explains
all eight warning families, including why a `state-changing-epsilon` transition must emit an
event or stop changing durable state. Do not silence the gate with
`mkEventStreamUnchecked`.

### 7. Diff (gate evolution over time)

When you later change the spec, gate the change against history:

```bash
cabal run keiro-dsl -- diff --since <git-ref> service.keiro ; echo "exit=$?"
```

Use the workspace manifest path here too when the service has multiple members; the old
manifest and member set are reconstructed from Git and classified as one service.

`BREAKING` (exit non-zero) means an on-disk event payload could now fail to decode — add a
versioned event + `upcast from v(N-1) = HOLE`, or a `deprecated event`, until it reports
`ADDITIVE` (exit 0).
