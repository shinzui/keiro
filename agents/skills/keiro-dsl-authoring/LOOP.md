# The authoring loop

Run everything from the repo root (`/Users/shinzui/Keikaku/bokuno/keiro`).

### 1. Write the spec

Author `service.keiro` in the notation (`NOTATION.md`). Start from `context <name>` and add
exactly the nodes the feature needs. Prefer the smallest spec that captures the decisions;
the deterministic boilerplate is derived, so don't hand-write it.

### 2. Parse (sanity)

```bash
cabal run keiro-dsl -- parse service.keiro
```

It echoes the spec pretty-printed. A parse error is line-numbered; fix the notation.

### 3. Check (the gate — before any Haskell)

```bash
cabal run keiro-dsl -- check service.keiro ; echo "exit=$?"
# add --emit to pretty-print the parsed spec on success (folds parse + check)
```

`OK` / exit 0 means every required decision is present and no dangerous inversion is stated
the wrong way. Any `error[Code]` (exit non-zero) names the rule and line — fix the spec, not
the generated code. Warnings (e.g. benign-inversion notices) are informational and pass.
Common diagnostics you must resolve in the spec (the warning-only codes are called out):

- Syntax and generated names: positioned parse errors reject raw newlines in strings and
  duplicate `wire`, `projection`, or transition `goto` clauses. `IdentHaskellKeyword`,
  `IdentNotConstructorSafe`, `VertexCtorCollision`, `DuplicateNodeName`,
  `DuplicateEnumCtor`, `DuplicateEnumWire`, `DuplicateIdPrefix`, `DuplicateCommandName`,
  and `DuplicateEventName` reject names that would collide or generate illegal Haskell.
- Aggregate, rule, and evolution: `StatusMapNotTotal`, `StatusMapDanglingKey`,
  `StatusMapDuplicateKey`, `WriteTargetNotRegister`, `RegisterInitialOutOfScope`,
  `UndeclaredCommand`, `UndeclaredEvent`, `UndeclaredState`, `UnreachableState`,
  `TerminalHasOutgoing`, `RuleDomainUnresolved`, `RuleNotTotal`, `RuleCaseUnknownCtor`,
  `ClockSampled`, `GuardAtomOutOfScope`, `EvtVersionMissingUpcaster`,
  `DeprecatedEventStillEmitted`, `SnapshotIntervalInvalid`, and
  `SnapshotCodecFixtureInvalid`. `WireSchemaVersionMismatch` is a warning.
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
component(s), and the manifest. It also rewrites
`keiro-dsl-scaffold-record.<context>.txt`. A later run may print an exit-0 `stale:` section
for recorded paths it no longer emits. Nothing is deleted: a `generated` line is a
safe-to-delete candidate after review; a `hole` line is hand-owned and must be inspected
before any deletion. A note about a different previous spec path means two specs share the
same context and `--out` (and therefore the same manifest/record); separate their output
directories unless that sharing is intentional. The manual firewall `grep` is no longer
needed.

To place the generated layer next to your domain code instead of a parallel `Generated.*`
tree, pass `--module-root <Prefix>` and/or `--collocate` (or set `module <Prefix>` / `layout
collocated` in the spec): with both, modules land at `<Prefix>.<Ctx>.<Node>.Generated.*`. The
emitted `keiro-dsl-manifest.<context>.txt` carries paste-ready `other-modules:`/`build-depends:`
blocks for the consuming Cabal stanza. Re-scaffold after every spec change and resolve the
stale report before adding the generated tree to a component.

### 5. Fill the holes

Open the hole modules. Each hole is a typed signature with a `-- HOLE …` annotation carrying
the spec decision to encode (e.g. `-- HOLE guard: divertStatus != TotalDivert || …`). Fill
the body against the **generated** names (the TH-produced `inCtor…`/`wire…`/`…TermFields`,
the `Keiro.Codec`, the `ProcessManager` wiring). Use the corpus
(`docs/corpus/keiro-dsl-corpus.md`) to see how a real spec's holes were filled. **Never edit
a `-- @generated` module** — change the `.keiro` and re-scaffold instead.

For any hand-written duplicate path, follow the generated hole note and call
`confirmBenignDuplicate :: StreamName -> EventId -> CommandError -> Eff es Bool` with the
target stream and attempted event id. Fold `True` into the duplicate outcome and preserve
`False` as the original failure. Pattern-matching `DuplicateEvent` alone is unsafe because
event ids are globally unique across streams.

### 6. Run the harness (pin behaviour)

The scaffolder emits a harness (`Harness.hs` for aggregates; a facts harness for processes)
plus golden round-trips. Compile and run it (via the relevant `cabal test` component). It
asserts `validateTransducer == []`, codec round-trips, the disposition/time-injection/id
decisions, and a behavioural accept. A wrong fill turns a **specific** named test red. Green
harness = your fill matches the spec.

If validation is red or startup reports `is not replay-safe`, open `TAXONOMY.md`. It explains
all eight warning families, including why a `state-changing-epsilon` transition must emit an
event or stop changing durable state. Do not silence the gate with
`mkEventStreamUnchecked`.

### 7. Diff (gate evolution over time)

When you later change the spec, gate the change against history:

```bash
cabal run keiro-dsl -- diff --since <git-ref> service.keiro ; echo "exit=$?"
```

`BREAKING` (exit non-zero) means an on-disk event payload could now fail to decode — add a
versioned event + `upcast from v(N-1) = HOLE`, or a `deprecated event`, until it reports
`ADDITIVE` (exit 0).
