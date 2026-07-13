---
id: 107
slug: add-a-first-class-read-model-node-with-registration-schema-and-consistency-to-keiro-dsl
title: "Add a first-class read-model node with registration, schema, and consistency to keiro-dsl"
kind: exec-plan
created_at: 2026-07-13T18:56:58Z
intention: "intention_01kxed7haee7ja78qm70cc6qm5"
master_plan: "docs/masterplans/15-harden-and-extend-the-keiro-dsl-toolchain-surfaced-by-the-2026-07-dsl-audit.md"
---

# Add a first-class read-model node with registration, schema, and consistency to keiro-dsl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The keiro runtime treats a read model — a named, versioned SQL projection table plus the
query that reads it — as a first-class, registered entity. `Keiro.ReadModel.runQuery`
refuses to serve a model that was never registered (`ReadModelUnregistered`), whose schema
identity (version + shape hash) has drifted (`ReadModelStaleSchema`), or that is mid-rebuild
(`ReadModelNotLive`). The keiro-dsl notation, however, has no read-model node at all. The
only read-side surface it offers is the aggregate-level
`projection <table> consistency=… key=… status-map { … }` clause, which lowers to an
`InlineProjection` value and nothing else: no registration call, no version, no shape hash,
no PostgreSQL schema, no rebuild wiring. A service scaffolded today from a valid spec fails
its very first `runQuery` with `ReadModelUnregistered`, the `consistency=Strong` the
notation happily accepts has broken semantics for an inline-only model (it waits on a
subscription cursor that never advances until the wait times out), and the
`operation … query <ReadModel> …` and pgmq `dispatch … source readModel = …` clauses
reference read models by name with nothing in the spec to resolve against.

After this plan, an author declares a `readmodel` node in the `.keiro` spec: registry name,
table, PostgreSQL schema, declared columns, version plus a captured shape-hash fixture
(re-derived and drift-checked by the validator, exactly like the workqueue physical-name
fixture), the default consistency mode, the strong-wait scope, how the model is fed (inline
by an aggregate's projection, or asynchronously by a subscription worker), and — derived
from the feed — the rebuild helpers. `keiro-dsl check` rejects `Strong` on an inline-only
model, rejects shape-hash drift, and resolves every `query`/`dispatch` read-model reference.
`keiro-dsl scaffold` emits a `-- @generated` module containing the live
`Keiro.ReadModel.ReadModel` record value, a `register<Model>` startup helper, rebuild
helpers with the correct feeding-projection names baked in, an `AsyncProjection` value for
subscription-fed models, and a qualified-table constant — plus a hand-owned hole module
carrying the typed query hole whose comments name the fully qualified
`"schema"."table"` so agent-written SQL never silently depends on `search_path`. A new
conformance suite compiles the generated module against the live `Keiro.ReadModel` API.

You can see it working by running, from `keiro-dsl/`,
`cabal run keiro-dsl -- check test/fixtures/readmodel-strong-inline.keiro` and observing a
non-zero exit with a precise `RmStrongInlineOnly` diagnostic; then
`cabal run keiro-dsl -- scaffold test/fixtures/readmodel.keiro --out /tmp/rm-demo` and
reading the emitted `ReadModel` record value; then `cabal test keiro-dsl-conformance-readmodel-runtime`
to see that value compile and its fields assert green against the live runtime.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Grammar, parser, pretty-printer, round-trip:

- [x] (2026-07-13 22:30Z) `ReadModelNode` (+ `RmColumn`, `RmFeed`, `RmScope`) and the `NReadModel` constructor
      added to `keiro-dsl/src/Keiro/Dsl/Grammar.hs`; `ProjectionSpec.projConsistency`
      loosened to `Maybe Consistency`.
- [x] (2026-07-13 22:30Z) `pReadModel` block parser wired into `pTopItem` in `keiro-dsl/src/Keiro/Dsl/Parser.hs`;
      new reserved words added; `consistency=` on the aggregate projection clause made
      optional.
- [x] (2026-07-13 22:30Z) Pretty-printer arm in `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`; parse→print→parse
      round-trips.
- [x] (2026-07-13 22:30Z) `genReadModel` arm added to the round-trip property generator in
      `keiro-dsl/test/Main.hs`; unit tests parse `test/fixtures/readmodel.keiro` into the
      expected AST.

Milestone 2 — Shape-hash derivation, validator rules, reference resolution:

- [x] (2026-07-13 22:39Z) `Keiro.Dsl.ReadModelShape` module: canonical shape string + FNV-1a-64 derivation,
      with unit tests pinning example digests.
- [x] (2026-07-13 22:39Z) Eleven new `DiagnosticCode` constructors appended (no existing code renamed); node
      rules implemented in `keiro-dsl/src/Keiro/Dsl/Validate.hs`.
- [x] (2026-07-13 22:39Z) `QueryOp` read-model + consistency resolution and `PgmqDispatch`
      source/dedup read-model + column resolution implemented (the arms
      `docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md`
      stubs pending this node).
- [x] (2026-07-13 22:39Z) Negative fixtures added and asserted by code (not prose) in `keiro-dsl/test/Main.hs`;
      positive fixture passes clean.

Milestone 3 — Scaffold emitters:

- [ ] `scaffoldReadModel` emits the `Generated.<Ctx>.<Node>.ReadModel` module (ReadModel
      value, `register<Model>`, rebuild helpers, qualified-table constant, AsyncProjection
      for subscription-fed) and the create-if-absent `<Ctx>.<Node>.ReadModelHoles` module
      with the typed query hole.
- [ ] E5 threading: aggregate projection hole stub comments name the qualified table +
      columns when the projection references a node; legacy standalone stubs warn about
      `search_path`.
- [ ] app/Main wiring + firewall clean on all new `Generated` modules; manifest lists the
      new modules.

Milestone 4 — Harness + conformance suite:

- [ ] `harnessReadModel` emits the facts-harness module.
- [ ] `keiro-dsl-conformance-readmodel-runtime` suite compiles the generated module + a
      filled reference hole against the live `Keiro.ReadModel` and asserts the record
      fields; committed copies pinned byte-identical by the scaffold-conformance test.
- [ ] Existing fixtures updated (`reservation-work.keiro`, `subscription.keiro`, and any
      other fixture with a `Strong` inline projection); pinned scaffold outputs regenerated.

Milestone 5 — Differ registration + docs:

- [ ] `readModelDiff` registered with the generalized differ of
      `docs/plans/103-make-keiro-dsl-diff-sound-over-the-full-decode-and-identity-surface.md`
      (or carried as a standalone arm if 103 has not landed; reconciled at implementation
      time), covering removal, version decrease, shape-change-without-bump, identity
      renames, feed flips, and consistency weakening.
- [ ] `agents/skills/keiro-dsl-authoring/NOTATION.md` gains the minimal `readmodel`
      section; the `query`/`dispatch` lines gain "resolved against readmodel nodes" notes.
- [ ] Outcomes & Retrospective written; MasterPlan 15 registry row updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The aggregate projection clause's `consistency=` is parsed and pretty-printed but **never
  lowered by the scaffolder** — `emitProjection` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:1108-1139`)
  reads only `projTable` and the status map. The clause's `Strong` is pure decoration
  today, which is why ownership of consistency can move to the `readmodel` node without
  changing any generated byte for existing specs. (Discovered while drafting this plan;
  verified by reading the emitter.)

- Validator rollout found three distinct fixture migrations: aggregate-only fixtures can
  drop the previously decorative `consistency=Strong` and intentionally receive the new
  `RmProjectionWithoutNode` warning; workflow fixtures need a real node because their
  `QueryOp` references are now resolved; dispatch fixtures and the workqueue starter need
  two real nodes because both source and dedup references are checked. Evidence: the unit
  suite passed 162 examples after the migration, and the positive `readmodel.keiro`
  fixture produced no diagnostics.


## Decision Log

Record every decision made while working on the plan.

- Decision: The aggregate `projection` clause is kept as **inline-feeding sugar that
  references a `readmodel` node by name**; a standalone clause (no matching node) remains
  legal but earns a `Warning` (`RmProjectionWithoutNode`). An explicit node is required
  only when anything else needs to see the model (a `query` operation, a pgmq `dispatch`,
  registration, `Strong` reads, a rebuild).
  Rationale: hard-requiring a node for every projection would break every existing spec and
  fixture for services that only ever query their table by hand; but leaving the clause
  fully standalone would preserve the audit's core defect (no registration, no identity).
  The reference-by-name design keeps old specs parsing, makes the upgrade a one-block
  addition, and gives the validator a join point for every rule below. Date: 2026-07-13

- Decision: `consistency=Strong` on an inline-only model is a hard **Error**
  (`RmStrongInlineOnly`), fired both for a standalone `projection … consistency=Strong`
  clause and for a `readmodel` node with `feed = inline` and `consistency = Strong`.
  Rationale: an inline projection applies in the same transaction as the command; no
  subscription worker ever advances the cursor `Strong` waits on
  (`keiro/src/Keiro/ReadModel.hs:113-121` says exactly this), so every `Strong` query on a
  non-empty log times out after five seconds. This is not a style preference — it is
  behaviorally broken — so a warning is too weak. Date: 2026-07-13

- Decision: The node-level `consistency` accepts only `Strong | Eventual`.
  `PositionWait` is representable only on the `operation … query` clause, where it changes
  the *documented call shape* (the caller supplies the target `GlobalPosition` per call via
  `runQueryWith`).
  Rationale: `defaultConsistency = PositionWait opts` with `target = Nothing` skips waiting
  entirely (`keiro/src/Keiro/ReadModel.hs:309-312`), and a baked-in target is meaningless
  as a standing default — the runtime designed `PositionWait` as a per-call read-your-writes
  mode. Offering it as a node default would be another wrong-semantics trap of the exact
  kind this plan removes. Date: 2026-07-13

- Decision: `version` + `shape` form a **captured fixture** with validator re-derivation,
  the same discipline as the workqueue `derive physical/dlq/table` trio: the node declares
  its columns, the spec captures `shape = "fnv1a:<16 hex>"`, and the validator recomputes
  the digest from the canonical shape string and errors on divergence
  (`RmShapeHashDrift`, message includes the recomputed value).
  Rationale: the runtime's `ReadModelStaleSchema` guard is only as good as the shape hash's
  honesty — a hand-maintained opaque string that nobody updates never fires. Deriving the
  hash from declared columns makes "I changed the table shape" impossible to hide: the
  validator forces the fixture update, and the differ (Milestone 5) forces the version bump.
  FNV-1a-64 (a ~10-line pure function) is chosen over a cryptographic hash because this is
  drift detection among cooperating specs, not security, and it avoids a new package
  dependency. Date: 2026-07-13

- Decision: Registry `name` and default `subscription` are **derived, not captured**:
  `registryName = <context> <> "-" <> replace "_" "-" <node-name>` (the context name is
  already kebab-case) and default `subscriptionName = registryName <> "-sub"` (matching the
  keiro test convention, e.g. `counter-read-model-sub` in `keiro/test/Main.hs:10103`).
  `subscription = "…"` overrides the default for brown-field cursors.
  Rationale: unlike the table shape, these have a single obvious derivation and no external
  system (codd DDL) to drift against; a fixture would be ceremony. Renames remain visible
  to the differ because the node name and the override are both in the AST. Date: 2026-07-13

- Decision: The feed is declared explicitly (`feed = inline | subscription`) rather than
  inferred from whether an aggregate projection points at the node.
  Rationale: the feed decides three generated artifacts (whether an `AsyncProjection` value
  is emitted, whether the rebuild helpers pass the feeding projection names or `[]`, and
  whether `Strong` is legal), so it must be stable under unrelated edits elsewhere in the
  spec. Explicit declaration also lets the validator check the *converse*: a `feed = inline`
  node with no aggregate projection referencing it is registered-but-never-written, an
  error the runtime cannot catch (`RmInlineFeedUnreferenced`). Date: 2026-07-13

- Decision: Rebuild support is **derived, not notated**: the scaffold emits
  `start<Model>Rebuild` / `finish<Model>Rebuild` / `abandon<Model>Rebuild` helpers that
  wrap `Keiro.ReadModel.Rebuild` with the model value and the correct feeding-projection
  name list baked in (`["<registryName>-async"]` for subscription-fed, `[]` for
  inline-only).
  Rationale: the error-prone part of the rebuild lifecycle is supplying the right
  projection names — `startRebuild` clears exactly the named dedup keys, and a wrong or
  missing name yields the live/replay interleaving and all-deduplicated-rebuild hazards
  that keiro MasterPlan 14 EP-101 just fixed. There is no authoring decision here to
  notate; the spec already knows the names. Date: 2026-07-13

- Decision: The generated module embeds `strongScope` from an optional
  `scope = entire-log | category "<cat>"` clause (default `entire-log`), legal only with
  `consistency = Strong` (`RmScopeWithoutStrong` otherwise).
  Rationale: MP-14/EP-101 added `StrongScope` so a category-scoped subscription is not held
  hostage by unrelated categories (`keiro/src/Keiro/ReadModel.hs:129-145`); the node must be
  able to express it or `Strong` on category subscriptions ships with the wrong scope.
  Restricting the clause to `Strong` keeps `Eventual` nodes free of dead knobs.
  Date: 2026-07-13

- Decision: This plan validates `pdDedupReadModelField` (`field = …` under
  `seenIn readModel`) against the referenced node's declared columns, but leaves
  `pdSourceKey` and `pdDedupQueueField` untouched.
  Rationale: the dedup read-model field is a literal SQL column name against the table this
  plan now describes — checkable for free. The source key names a fan-out-input concept
  (hole-side), and the queue-side field belongs to the workqueue payload, whose resolution
  `docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md`
  owns. Date: 2026-07-13

- Decision: Existing aggregate-only fixtures drop the unused projection-level
  `consistency=Strong` clause and remain legacy standalone projections with a warning;
  fixtures that exercise `query` or pgmq dispatch references declare first-class nodes.
  Rationale: this preserves byte-identical aggregate scaffold output and keeps old
  evolution fixtures focused on their original concern, while every reference-bearing
  fixture exercises the new resolution gate instead of carrying unrelated errors.
  Date: 2026-07-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Milestone 1 is complete. The grammar, parser, printer, all-family generator, and canonical
fixture now carry first-class read-model nodes, while aggregate projection consistency is
optional. `cabal test keiro-dsl-test` passed 154 examples, including 100 generated
round-trips with 14% read-model coverage.

Milestone 2 is complete. Shape fixtures are derived from the ordered SQL surface with a
UTF-8 FNV-1a-64 implementation, all eleven read-model diagnostics are active, and query
plus dispatch references resolve against declared nodes and columns. The unit suite passed
162 examples; the positive fixture checked clean, while the CLI returned exit 1 with
`RmStrongInlineOnly` for the inline-Strong fixture.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### Standing assumption: keiro MasterPlan 14 lands first

This repository (`keiro`) contains the keiro runtime packages (`keiro`, `keiro-core`,
`keiro-pgmq`, …) and the `keiro-dsl` toolchain package. **This plan changes only the
`keiro-dsl` package, its tests, and the authoring docs under
`agents/skills/keiro-dsl-authoring/` — never a runtime package.**

The standing assumption is that keiro MasterPlan 14
(`docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`)
is implemented before this plan — in particular its EP-101
(`docs/plans/101-read-model-rebuild-correctness-dedup-reset-writer-fencing-and-strong-cursor-semantics.md`),
which hardened read-model rebuild correctness and gave `Strong` its cursor-scope semantics.
EP-101 is finishing in the working tree as this plan is drafted; the runtime surface
embedded below was read from that tree (`keiro/src/Keiro/ReadModel.hs`,
`keiro/src/Keiro/ReadModel/Schema.hs`, `keiro/src/Keiro/ReadModel/Rebuild.hs`) and **the
final MP-14/EP-101 surface is the target**. If a signature below differs from the tree when
you implement, re-read those three files and update this plan's embedded surface first
(note it in Surprises & Discoveries).

### The runtime surface this node targets (embedded)

A *read model* is a SQL table populated by a *projection* (a fold of domain events into
rows) and read back by application queries. The runtime record, from
`keiro/src/Keiro/ReadModel.hs:92-103`:

```haskell
data ReadModel q r = ReadModel
    { name :: !Text                      -- logical identity; key in the keiro_read_models registry
    , tableName :: !Text                 -- the projection data table
    , schema :: !Text                    -- the PostgreSQL schema the DATA table lives in
    , subscriptionName :: !Text          -- the cursor tracking projection progress
    , version :: !Int                    -- schema identity …
    , shapeHash :: !Text                 -- … stale queries fail with ReadModelStaleSchema
    , defaultConsistency :: !ConsistencyMode
    , strongScope :: !StrongScope        -- which log head a Strong read waits for
    , query :: !(q -> Tx.Transaction r)  -- the SQL read (hasql-transaction)
    }
```

`schema` is the *application's* data schema, deliberately separate from keiro's own `keiro`
schema where the `keiro.keiro_read_models` registry table lives, and deliberately **not
persisted** in the registry (a deployment concern, not schema identity — see the note at
`keiro/src/Keiro/ReadModel.hs:262-265`). `qualifiedTableName`
(`ReadModel.hs:109-111`) renders the double-quoted `"schema"."table"` reference via
`Keiro.Connection.qualifyTable`; the runtime never rewrites the `query` SQL — qualifying it
is the application's job. That is exactly the audit's E5 hazard: agent-filled projection
SQL that does not qualify silently depends on `search_path`.

Consistency and scope (`ReadModel.hs:123-145`):

```haskell
data ConsistencyMode = Strong | Eventual | PositionWait !PositionWaitOptions
data StrongScope = EntireLog | CategoryHead !Text
```

`Strong` captures the store head at query start (entire log, or one Kiroku category's head
under `CategoryHead`) and blocks until the model's subscription cursor reaches it, timing
out after five seconds by default (`defaultStrongWaitOptions`, `ReadModel.hs:164-170`).
`Eventual` queries immediately. `PositionWait` blocks until a **caller-supplied**
`GlobalPosition` is reached — the read-your-writes mode, used per call via
`runQueryWith :: Maybe KeiroMetrics -> ConsistencyMode -> ReadModel q r -> q -> Eff es (Either ReadModelError r)`.
`runQuery` uses `defaultConsistency`. Both first verify registration, schema identity, and
liveness; failures are `ReadModelUnregistered | ReadModelStaleSchema … | ReadModelWaitTimeout … | ReadModelNotLive …`
(`ReadModel.hs:173-191`).

Registration and lifecycle, from `keiro/src/Keiro/ReadModel/Schema.hs`:

```haskell
registerReadModel :: (Store :> es) => Text -> Int -> Text -> Eff es ReadModelMetadata
-- name -> version -> shapeHash; idempotent; inserts a 'Live' row if none exists,
-- returns an existing row UNCHANGED so queries can detect drift.
data ReadModelStatus = Live | Rebuilding | Paused | Abandoned | UnknownStatus !Text
```

Queries **never** self-register; startup wiring must call `registerReadModel` once per
model. The keiro test suite's canonical call shape (`keiro/test/Main.hs:10115-10121`) is
exactly what this plan's `register<Model>` helper generates:

```haskell
registerReadModelDefinition :: (Store :> es) => ReadModel q r -> Eff es ()
registerReadModelDefinition readModel =
    void $ registerReadModel (readModel ^. #name) (readModel ^. #version) (readModel ^. #shapeHash)
```

The rebuild lifecycle, from `keiro/src/Keiro/ReadModel/Rebuild.hs:70-110`:
`startRebuild readModel projectionNames replayFrom` atomically fences live writers, takes
queries offline, truncates the data table, deletes the named async-projection dedup keys,
and resets the subscription checkpoint; `finishRebuild` promotes with an empty-rebuild
guard (an empty `projectionNames` list denotes an inline-only model and skips the guard);
`abandonRebuild` backs out. Supplying the correct `projectionNames` is load-bearing.

Feeding machinery, from `keiro/src/Keiro/Projection.hs`:

```haskell
data InlineProjection co = InlineProjection
    { name :: !Text, apply :: !(co -> RecordedEvent -> Tx.Transaction ()) }
data AsyncProjection = AsyncProjection
    { name :: !Text, readModelName :: !Text, subscriptionName :: !Text
    , applyRecorded :: !(RecordedEvent -> Tx.Transaction ())
    , idempotencyKey :: !(RecordedEvent -> EventId) }
```

An `InlineProjection` runs in the same transaction as the command (synchronous,
read-your-writes by construction, no subscription cursor). An `AsyncProjection` is applied
later by a subscription worker via `applyAsyncProjection`, is dedup-keyed for safe
redelivery, and is fenced by the registry row while the model is `Rebuilding`.

### What keiro-dsl has today (and where it falls short)

`keiro-dsl` is a toolchain (`parse` / `check` / `scaffold` / `diff` CLI in
`keiro-dsl/app/Main.hs`) over a terse `.keiro` notation. A spec is a flat `context <name>`
header followed by shared declarations (`id`, `enum`, `rule`) and *nodes* — one block per
runtime primitive. `Keiro.Dsl.Grammar` defines the AST (`Spec`, `Node` with ten
constructors `NAggregate … NOperation`); `Keiro.Dsl.Parser.parseSpec` parses;
`Keiro.Dsl.PrettyPrint.renderSpec` prints (round-trip property in `keiro-dsl/test/Main.hs`);
`Keiro.Dsl.Validate.validateSpec` returns line-numbered `Diagnostic` values each carrying a
machine-checkable `DiagnosticCode` (an enum at `Validate.hs:32-73` that tests match on —
**append only, never rename**;
`docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md`
owns the existing registry); `Keiro.Dsl.Scaffold` emits `ScaffoldModule` values of kind
`Generated` (banner-marked, overwritten every run, firewall-scanned for keiki symbolic
operators) or `HoleStub` (create-if-absent, hand-owned); `Keiro.Dsl.Harness` emits test
modules; `keiro-dsl/keiro-dsl.cabal` hosts seventeen conformance suites that compile
committed scaffold output against the live runtime packages.

The read-side surface today is one clause on the aggregate node
(`Grammar.hs:340-350`):

```haskell
data ProjectionSpec = ProjectionSpec
    { projTable :: !Name, projConsistency :: !Consistency
    , projKey :: !Name, projStatusMap :: !(Maybe Mapping), projLoc :: !Loc }
data Consistency = Strong | Eventual
```

parsed from `projection <table> consistency=(Strong|Eventual) key=<field> [status-map {…}]`
(`Parser.hs:423-445`) and lowered by `emitProjection` (`Scaffold.hs:1108-1139`) to a
generated `<table>StatusFor :: <Agg>Event -> Maybe Text` function plus an
`InlineProjection <Agg>Event` value named `<context>-<table>-inline`, whose `apply` is the
hand-owned hole `apply<Table>` stubbed in the aggregate's Holes module
(`holeProjectionStub`, `Scaffold.hs:~1240`) with the comment "Fill against your
codd-managed read-model table" — no schema, no qualification guidance. Nothing registers
anything; `projConsistency` is read by no emitter. Elsewhere, `operation … query`
(`Grammar.hs:774-775`: `QueryOp !Name !Name !Text !Name` — read-model name, input, result
type text, consistency identifier parsed as a bare `ident` defaulting to `"Strong"`,
`Parser.hs:846-854`) and pgmq `dispatch` (`Grammar.hs:722-735`: `pdSourceReadModel`,
`pdDedupReadModel`, `pdDedupReadModelField`) both name read models that nothing declares.
`validateNode` has no arm for them (operations validate only signal/run;
`validatePgmqDispatch` resolves only `pdEnqueueTo`). Operations are not scaffolded at all
today (no `scaffoldOperation` exists); this plan does **not** add operation scaffolding —
only reference *resolution*.

The captured-fixture discipline this plan reuses comes from the workqueue node
(`Grammar.hs:699-717`, notation in `agents/skills/keiro-dsl-authoring/NOTATION.md` §
"workqueue / dispatch"): the spec *captures* derivable strings
(`derive physical = … dlq = … table = …`) and the validator *re-derives* them and errors on
divergence (`WqPhysicalDivergence`, `Validate.hs:157-186`), so copy-paste drift at a
raw-SQL site is caught at `check` time.

### The notation this plan introduces

Two worked examples; both become `keiro-dsl/test/fixtures/readmodel.keiro` (one file, one
context). First, a subscription-fed model with `Strong` category-scoped reads — the shape a
dashboard query wants:

```text
readmodel transfer_decisions {
  table = "transfer_decisions"
  schema = "hospital_capacity"
  columns {
    reservation_id text required
    hospital_id    text required
    status         text required
    decided_at     timestamptz
  }
  version = 1
  shape = "fnv1a:9c1f4b02aa317de8"        # captured fixture; check re-derives + flags drift
  consistency = Strong
  scope = category "reservation"          # StrongScope; only legal with Strong
  feed = subscription
  subscription = "hospital-capacity-transfer-decisions-sub"   # optional; this IS the default
}
```

Second, an inline-fed model referenced by an aggregate's projection clause (the clause's
`consistency=` is now optional and, when present, must agree with the node):

```text
readmodel subscriptions {
  table = "subscriptions"
  schema = "billing"
  columns {
    subscription_id text required
    status          text required
  }
  version = 1
  shape = "fnv1a:5e02c7a1440bb96d"
  consistency = Eventual                  # Strong here would be RmStrongInlineOnly
  feed = inline
}

aggregate Subscription
  …
  projection subscriptions key=subscriptionId
    status-map { Activated=>active Cancelled=>cancelled }
```

The digests above are illustrative placeholders; Milestone 2's derivation function produces
the real values and the `check` error message prints the expected digest, so authoring the
fixture is copy-paste from the first failing run.

Derivation rules (all deterministic, all documented in NOTATION.md):

- registry `name` = `<context>-<node-name-with-underscores-as-hyphens>` — here
  `hospital-capacity-transfer-decisions` (context names are kebab-case `wireWord`s).
- default `subscriptionName` = registry name + `-sub`.
- generated `AsyncProjection` name (subscription-fed only) = registry name + `-async`.
- canonical shape string = `<table>` + `|` + one `<col>:<type>:<req|null>` segment per
  declared column **in declaration order**, e.g.
  `transfer_decisions|reservation_id:text:req|hospital_id:text:req|status:text:req|decided_at:timestamptz:null`;
  `shape` = `"fnv1a:" <> 16-hex-digit FNV-1a-64 of that string`. Declaration order is
  identity-bearing on purpose: column order changes the digest, forcing the author through
  the fixture-update (and differ) gate rather than silently reordering.
- column types are a closed set: `text`, `int`, `bigint`, `bool`, `timestamptz`, `jsonb`,
  `numeric`. Anything else is `RmUnknownColumnType`. The columns exist for shape identity
  and hole documentation — codd migrations remain the DDL owner; the DSL never emits DDL.

Meaning of the clauses, in terms of the embedded runtime surface: `table`/`schema` →
`tableName`/`schema` fields (and the qualified-table constant); `version`/`shape` →
`version`/`shapeHash`; `consistency` → `defaultConsistency` (`Strong | Eventual` only — see
Decision Log for why `PositionWait` is per-call); `scope` → `strongScope`
(`entire-log` → `EntireLog`, `category "c"` → `CategoryHead "c"`); `feed` selects
inline-vs-async generated artifacts and gates `Strong`.


## Plan of Work

The work is five milestones, strictly additive to the `keiro-dsl` package, following the
per-vertical pattern of
`docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md`: grammar constructor →
parser → pretty-printer → round-trip generator arm → validator rules → scaffold emitters
(firewall-clean) → harness → a conformance suite compiling against the live runtime →
NOTATION.md section.

### Milestone 1 — Grammar, parser, pretty-printer, round-trip

**Scope.** Teach the DSL to represent, read, and re-print the `readmodel` node, and loosen
the aggregate projection clause. At the end, `test/fixtures/readmodel.keiro` parses into
the expected AST and round-trips.

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, next to `WorkqueueNode`, add:

```haskell
data RmColumn = RmColumn
    { rmcName :: !Text        -- SQL column name (wire-level)
    , rmcType :: !Text        -- one of the closed type set (validated, not typed, so the
                              -- parser stays total and the diagnostic carries a line)
    , rmcRequired :: !Bool    -- 'required' marker => NOT NULL in the docs/hash
    } deriving stock (Eq, Show, Generic)

data RmFeed = RmInline | RmSubscription
    deriving stock (Eq, Show, Generic)

data RmScope = RmEntireLog | RmCategory !Text
    deriving stock (Eq, Show, Generic)

data ReadModelNode = ReadModelNode
    { rmName :: !Name
    , rmTable :: !Text
    , rmSchema :: !Text
    , rmColumns :: ![RmColumn]
    , rmVersion :: !Int
    , rmShape :: !Text                  -- the captured "fnv1a:…" fixture
    , rmConsistency :: !Consistency     -- reuses the existing Strong | Eventual
    , rmScope :: !(Maybe RmScope)       -- Nothing => EntireLog (and legal only with Strong)
    , rmFeed :: !RmFeed
    , rmSubscription :: !(Maybe Text)   -- Nothing => derived default
    , rmLoc :: !Loc
    } deriving stock (Eq, Show, Generic)
```

add `NReadModel ReadModelNode` to `Node`, export everything, and change
`ProjectionSpec.projConsistency` to `Maybe Consistency` (grep the four consumers —
Parser, PrettyPrint, and the two `Validate` mentions; the scaffolder never reads it).

In `keiro-dsl/src/Keiro/Dsl/Parser.hs`, add `pReadModel` (a braces block of `key = value`
rows in the workqueue style; `table`/`schema`/`shape`/`subscription` values are `stringLit`,
`version` is `L.decimal`, `consistency` reuses the existing Strong/Eventual choice, `scope`
is `entire-log` or `category <stringLit>`, `feed` is `inline`/`subscription`, and the
`columns { … }` sub-block is `many (RmColumn <$> wireWord <*> ident <*> option False (True <$ keyword "required"))`).
Wire `TINode . NReadModel <$> pReadModel` into `pTopItem` (before the `pAggregate`
fallthrough). Add the new structural words to `reservedWords`
(`Parser.hs:~90-133`): `readmodel`, `columns`, `feed`, `scope`, and `shape` at minimum —
check each against existing fixtures first (`table`, `schema`, `version`, `subscription`,
`category`, `inline` appear inside other blocks as `symbol`-parsed labels or identifiers;
reserve only what cannot break an existing spec, and prefer `symbol`-style matching inside
the block, which is the existing workqueue approach and reserves nothing). Make
`consistency=` optional in `pProjection` (`option Nothing (Just <$> …)`).

In `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`, add the `NReadModel` printing arm mirroring
the block layout above, and print the projection clause's `consistency=` only when present.
Known caveat, out of this plan's scope: `stringLit`/`dquoted` have no escaping
(`docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md`
owns that); do not embed `"` in this plan's fixtures.

In `keiro-dsl/test/Main.hs`, add unit tests (parse `readmodel.keiro`, assert both nodes'
fields; assert a projection clause without `consistency=` parses) and add a `genReadModel`
arm to the round-trip property generator (`genSpec`, `test/Main.hs:~554`) over the same
safe alphabets the aggregate generator uses, so the printer/parser pair is
property-covered from day one.

Acceptance: from `keiro-dsl/`, `cabal test keiro-dsl-test` passes with the new cases;
`cabal run keiro-dsl -- parse test/fixtures/readmodel.keiro --emit` prints a spec that
re-parses to the same AST.

### Milestone 2 — Shape-hash derivation, validator rules, and reference resolution

**Scope.** Make `check` reject every unsafe read-model spec and resolve every read-model
reference. At the end, each rule fires on a crafted negative fixture with its own code, and
the positive fixture passes clean.

Create `keiro-dsl/src/Keiro/Dsl/ReadModelShape.hs`:

```haskell
module Keiro.Dsl.ReadModelShape (canonicalShape, deriveShapeHash, registryNameFor, subscriptionNameFor) where
-- canonicalShape :: ReadModelNode -> Text          (the segment string defined in Context)
-- deriveShapeHash :: ReadModelNode -> Text         ("fnv1a:" <> printf "%016x" over FNV-1a-64)
-- registryNameFor :: Name {-context-} -> ReadModelNode -> Text
-- subscriptionNameFor :: Name -> ReadModelNode -> Text   (override-aware)
```

with the standard FNV-1a-64 fold (offset basis `0xcbf29ce484222325`, prime
`0x100000001b3`, over the UTF-8 bytes of the canonical string). One shared module because
the validator (re-derive + compare), the scaffolder (emit registry/subscription names), and
the harness (pin the facts) must agree byte-for-byte. Unit-test it with two pinned example
digests so an accidental algorithm change is loud.

In `keiro-dsl/src/Keiro/Dsl/Validate.hs`, append to `DiagnosticCode` (never rename existing
constructors; `docs/plans/104-…` owns the registry — if it lands first and already appended
codes, append after its):

```haskell
    | -- EP-107 (read models).
      RmShapeHashDrift
    | RmStrongInlineOnly
    | RmScopeWithoutStrong
    | RmUnknownColumnType
    | RmInlineFeedUnreferenced
    | RmConsistencyConflict
    | RmProjectionWithoutNode
    | QueryUnresolvedReadModel
    | QueryConsistencyInvalid
    | DispatchReadModelUnresolved
    | DispatchReadModelFieldUnknown
```

and implement `validateReadModel :: Spec -> ReadModelNode -> [Diagnostic]` plus extensions
to the aggregate, operation, and dispatch arms of `validateNode`:

1. **RmShapeHashDrift** (Error): `rmShape /= deriveShapeHash node`. Message includes both
   values: `readmodel 'transfer_decisions': captured shape "fnv1a:dead…" does not match the
   declared columns (expected "fnv1a:9c1f…"); update the fixture AND bump version if the
   table shape really changed`.
2. **RmUnknownColumnType** (Error): any `rmcType` outside the closed set.
3. **RmStrongInlineOnly** (Error): `rmFeed == RmInline && rmConsistency == Strong`, message
   quoting the runtime truth: `an inline-only model has no subscription worker to advance
   the cursor a Strong read waits on; every Strong query on a non-empty log times out. Use
   consistency = Eventual, or feed = subscription`. The same code fires on a *standalone*
   aggregate projection clause (no matching node) whose `projConsistency` is
   `Just Strong` — that combination is inline-only by definition.
4. **RmScopeWithoutStrong** (Error): `rmScope` is `Just _` while `rmConsistency == Eventual`.
5. **RmInlineFeedUnreferenced** (Error): `rmFeed == RmInline` and no aggregate in the spec
   has `aggProjection` whose `projTable` equals `rmName` — the model would register `Live`
   yet never be written, which the runtime cannot detect.
6. **RmConsistencyConflict** (Error): an aggregate projection clause references a declared
   node (its `projTable` equals some `rmName`) and carries `Just c` with
   `c /= rmConsistency` of that node. The node owns consistency.
7. **RmProjectionWithoutNode** (Warning): an aggregate projection clause whose `projTable`
   matches no declared `readmodel` node. Legacy specs stay green (warnings do not fail
   `check`) but every run points at the upgrade.
8. **QueryUnresolvedReadModel** (Error): a `QueryOp rm _ _ _` whose `rm` matches no
   declared node — this completes the operation-resolution arm that
   `docs/plans/104-…` explicitly stubs pending this node.
9. **QueryConsistencyInvalid** (Error): the `QueryOp` consistency text is not one of
   `Strong`, `Eventual`, `PositionWait` (it is a bare `ident` today, so `Strongg` currently
   passes silently).
10. **DispatchReadModelUnresolved** (Error): `pdSourceReadModel` or `pdDedupReadModel` of a
    pgmq dispatch matches no declared node — the second stub `docs/plans/104-…` leaves for
    this plan. **DispatchReadModelFieldUnknown** (Error): `pdDedupReadModelField` is not a
    declared column of the resolved dedup node (skipped when the node is unresolved, to
    avoid cascading noise).

Fixtures: extend `test/fixtures/readmodel.keiro` (positive; includes a `query` operation
and a full workqueue+dispatch pair resolving against the nodes) and add negatives —
`readmodel-shape-drift.keiro`, `readmodel-strong-inline.keiro` (node form),
`readmodel-strong-standalone.keiro` (legacy clause form), `readmodel-scope-eventual.keiro`,
`readmodel-inline-unreferenced.keiro`, `readmodel-consistency-conflict.keiro`,
`readmodel-query-unresolved.keiro`, `readmodel-dispatch-unresolved.keiro`. Update
`reservation-work.keiro` to declare `readmodel accepted_transfer_needs` and
`readmodel transfer_decisions` nodes (its dispatch block already references both names),
and change `subscription.keiro`'s `projection subscriptions consistency=Strong` to either
drop `consistency=` or add the inline node — otherwise rule 3 breaks the existing suite.
Sweep all fixtures under `test/fixtures/` and the skeleton templates in
`keiro-dsl/src/Keiro/Dsl/Skeleton.hs` for the same `Strong`-inline pattern. Tests match on
`code`, not message prose.

Acceptance: from `keiro-dsl/`, `cabal test keiro-dsl-test` green;
`cabal run keiro-dsl -- check test/fixtures/readmodel-strong-inline.keiro; echo exit=$?`
prints the `RmStrongInlineOnly` diagnostic and `exit=1`; the positive fixture checks clean.

### Milestone 3 — Scaffold emitters (symbol-free deterministic layer + typed query hole)

**Scope.** Emit compiling Haskell. At the end, `scaffold` writes a generated read-model
module per node plus a hand-owned hole module, threads schema qualification into every
projection-SQL hole (E5), and the firewall holds.

In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, add
`scaffoldReadModel :: Context -> ReadModelNode -> [ScaffoldModule]` emitting two modules
(module segment = the node name with its first letter capitalized, matching the existing
workqueue convention `Generated.HospitalCapacity.Reservation_work.*`; identifier hygiene
generally is `docs/plans/105-…`'s concern).

**`Generated.<Ctx>.<Node>.ReadModel`** (kind `Generated`, banner-marked, overwritten every
run) — for the `transfer_decisions` example, shaped like:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
-- @generated by keiro-dsl. DO NOT EDIT.
module Generated.HospitalCapacity.Transfer_decisions.ReadModel
  ( transferDecisionsReadModel
  , transferDecisionsQualifiedTable
  , registerTransferDecisions
  , startTransferDecisionsRebuild
  , finishTransferDecisionsRebuild
  , abandonTransferDecisionsRebuild
  , transferDecisionsAsyncProjection   -- subscription-fed only
  ) where

import HospitalCapacity.Transfer_decisions.ReadModelHoles
  (TransferDecisionsQueryInput, TransferDecisionsQueryResult, transferDecisionsQuery, applyTransferDecisions)
import Data.Functor (void)
import Data.Text (Text)
import Effectful (Eff, (:>))
import Keiro.Projection (AsyncProjection (..))
import Keiro.ReadModel
import Keiro.ReadModel.Rebuild qualified as Rebuild
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (GlobalPosition)

transferDecisionsReadModel :: ReadModel TransferDecisionsQueryInput TransferDecisionsQueryResult
transferDecisionsReadModel =
  ReadModel
    { name = "hospital-capacity-transfer-decisions"
    , tableName = "transfer_decisions"
    , schema = "hospital_capacity"
    , subscriptionName = "hospital-capacity-transfer-decisions-sub"
    , version = 1
    , shapeHash = "fnv1a:9c1f4b02aa317de8"
    , defaultConsistency = Strong
    , strongScope = CategoryHead "reservation"
    , query = transferDecisionsQuery
    }

-- The double-quoted "schema"."table" reference; interpolate THIS into query SQL.
transferDecisionsQualifiedTable :: Text
transferDecisionsQualifiedTable = "\"hospital_capacity\".\"transfer_decisions\""

-- Call once at projection startup, BEFORE serving queries (queries never self-register).
registerTransferDecisions :: (Store :> es) => Eff es ()
registerTransferDecisions =
  void (registerReadModel "hospital-capacity-transfer-decisions" 1 "fnv1a:9c1f4b02aa317de8")

startTransferDecisionsRebuild :: (Store :> es) => GlobalPosition -> Eff es ReadModelMetadata
startTransferDecisionsRebuild =
  Rebuild.startRebuild transferDecisionsReadModel ["hospital-capacity-transfer-decisions-async"]

finishTransferDecisionsRebuild :: (Store :> es) => GlobalPosition -> Eff es (Either Rebuild.RebuildError ReadModelMetadata)
finishTransferDecisionsRebuild =
  Rebuild.finishRebuild transferDecisionsReadModel ["hospital-capacity-transfer-decisions-async"]

abandonTransferDecisionsRebuild :: (Store :> es) => Eff es ReadModelMetadata
abandonTransferDecisionsRebuild = Rebuild.abandonRebuild transferDecisionsReadModel

transferDecisionsAsyncProjection :: AsyncProjection
transferDecisionsAsyncProjection =
  AsyncProjection
    { name = "hospital-capacity-transfer-decisions-async"
    , readModelName = "hospital-capacity-transfer-decisions"
    , subscriptionName = "hospital-capacity-transfer-decisions-sub"
    , applyRecorded = applyTransferDecisions
    , idempotencyKey = \recorded -> recorded.eventId
    }
```

For `feed = inline` nodes: omit `transferDecisionsAsyncProjection` and `applyTransferDecisions`
(the apply hole is the *aggregate's* `apply<Table>`, unchanged), and pass `[]` as the
rebuild projection-name list (the runtime's documented inline-only convention). The exact
`RecordedEvent` field access for the idempotency key must be checked against
`Keiro.Projection`/kiroku at implementation time (`recorded.eventId` via
`OverloadedRecordDot`, or the record selector — whichever the live type exposes). Every
splice of spec-supplied text uses `tshow`-style escaping — the template-injection lesson of
`docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md`
applies to new emitters from day one. No keiki symbolic operator appears anywhere above, so
the firewall invariant holds by construction.

**`<Ctx>.<Node>.ReadModelHoles`** (kind `HoleStub`, create-if-absent, hand-owned) — the
typed query hole plus, for subscription-fed nodes, the async apply hole:

```haskell
-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module HospitalCapacity.Transfer_decisions.ReadModelHoles
  ( TransferDecisionsQueryInput
  , TransferDecisionsQueryResult
  , transferDecisionsQuery
  , applyTransferDecisions   -- subscription-fed only
  ) where

import Hasql.Transaction qualified as Tx

-- HOLE: replace these placeholder aliases with your real query input/result types.
type TransferDecisionsQueryInput = ()
type TransferDecisionsQueryResult = ()

-- HOLE: the read-model query, run inside runQuery's transaction AFTER the
-- registration/liveness/consistency gates. Table: "hospital_capacity"."transfer_decisions"
-- (interpolate transferDecisionsQualifiedTable from the generated module; NEVER rely on
-- search_path). Declared columns:
--   reservation_id text NOT NULL
--   hospital_id    text NOT NULL
--   status         text NOT NULL
--   decided_at     timestamptz
transferDecisionsQuery :: TransferDecisionsQueryInput -> Tx.Transaction TransferDecisionsQueryResult
transferDecisionsQuery _input = error "HOLE: fill transfer_decisions query"

-- HOLE: fold one recorded event into the table (the subscription worker applies this;
-- dedup on redelivery is handled by the runtime via the idempotency key).
applyTransferDecisions :: recorded -> txn ()
applyTransferDecisions _recorded = error "HOLE: fill transfer_decisions apply"
```

(The `recorded -> txn ()` free-variable stub is the existing hole idiom — the author
replaces the signature with `RecordedEvent -> Tx.Transaction ()` when filling; the
generated module's import forces the fix before anything compiles.)

**E5 threading into the aggregate projection hole.** Extend `holeProjectionStub` and the
`emitProjection` header comment in `Scaffold.hs`: when the aggregate's `projTable` resolves
to a declared node, the stub comment names the qualified `"schema"."table"`, lists the
node's columns, and points at the generated `<node>QualifiedTable` constant; when it does
not resolve (legacy standalone), the comment gains one line — `-- WARNING: no readmodel
node declares this table's schema; unqualified SQL depends on search_path`. The signature
itself stays as-is (hole modules are hand-owned; only newly created stubs pick up the new
text — note this in the scaffold report reading).

Wire into `keiro-dsl/app/Main.hs` (`run (Scaffold …)`):
`rmMods = concat [scaffoldReadModel ctx rm <> harnessReadModel ctx rm | NReadModel rm <- specNodes spec]`
appended to `allMods`, so the manifest, firewall scan, and write-discipline reporting all
apply unchanged.

Acceptance: from `keiro-dsl/`,
`cabal run keiro-dsl -- scaffold test/fixtures/readmodel.keiro --out /tmp/rm-demo` writes
both modules per node, reports zero firewall breaches, and a second run reports the hole
module as `kept` (create-if-absent respected). The scaffolded text matches the committed
conformance copies (Milestone 4).

### Milestone 4 — Harness and the live-runtime conformance suite

**Scope.** Prove behavior beyond compilation. At the end, a generated facts harness pins
the derivations, and a new cabal suite compiles the generated module against the live
`Keiro.ReadModel` and asserts the record's fields.

In `keiro-dsl/src/Keiro/Dsl/Harness.hs`, add
`harnessReadModel :: Context -> ReadModelNode -> [ScaffoldModule]` emitting
`Generated.<Ctx>.<Node>.ReadModelHarness` — a runtime-free, firewall-clean module in the
style of the existing `ProcessHarness`: a list of named `(fact, expected, actual)` checks
covering registry-name derivation, default subscription name, the shape hash (the captured
fixture re-stated), the async-projection name, and the consistency/scope lowering, plus a
`runReadModelFacts :: IO Bool` entry the unit suite can call. This is what turns red if a
derivation rule in `ReadModelShape` and an emitter ever disagree.

In `keiro-dsl/keiro-dsl.cabal`, add the suite (mirror
`keiro-dsl-conformance-queue-runtime` / `-process-full` stanzas):

```text
-- EP-107 read-model runtime conformance: the scaffolded ReadModel record value,
-- registration + rebuild helpers, and AsyncProjection — with a filled reference
-- query hole — compiled against the live keiro Keiro.ReadModel API.
test-suite keiro-dsl-conformance-readmodel-runtime
  import:         warnings, shared
  type:           exitcode-stdio-1.0
  hs-source-dirs: test/conformance-readmodel-runtime
  main-is:        Main.hs
  other-modules:
    Generated.HospitalCapacity.Transfer_decisions.ReadModel
    Generated.HospitalCapacity.Transfer_decisions.ReadModelHarness
    HospitalCapacity.Transfer_decisions.ReadModelHoles
  build-depends:
    , base               >=4.21 && <5
    , effectful-core
    , hasql-transaction
    , keiro
    , kiroku
    , text               >=2.1
```

(adjust the dependency set to whatever the compile actually needs — `kiroku` provides
`Kiroku.Store.Effect`/`Kiroku.Store.Types`; check how the existing runtime suites obtain
them). `test/conformance-readmodel-runtime/` holds committed copies of the scaffolded
modules (pinned byte-identical to fresh scaffold output by the existing
scaffold-conformance test in `keiro-dsl-test`, same as every other vertical) plus a filled
reference hole: a trivial `SELECT count(*)` query interpolating
`transferDecisionsQualifiedTable`, proving the E5 guidance is followable. `Main.hs` asserts,
without a database: every `ReadModel` field equals the spec's value
(`name`/`tableName`/`schema`/`subscriptionName`/`version`/`shapeHash`), `defaultConsistency`
pattern-matches `Strong`, `strongScope` matches `CategoryHead "reservation"`,
`qualifiedTableName transferDecisionsReadModel == transferDecisionsQualifiedTable` (the
constant agrees with the runtime's own qualifier — the load-bearing E5 assertion), the
async projection's `readModelName`/`subscriptionName` agree with the record, and
`registerTransferDecisions` / the rebuild helpers typecheck at their `(Store :> es)`
signatures (a bound, unexecuted `_usesRegister :: (Store :> es) => Eff es ()` witness).
Database-backed `runQuery` behavior is the runtime's own test estate (MP-14/EP-101);
conformance here means the generated artifact is exactly what that estate exercises.

Also regenerate any pinned scaffold outputs whose text changed (the aggregate Holes stub
comment for fixtures whose projection now resolves to a node) — the scaffold-conformance
test names each stale file when it fails.

Acceptance: from `keiro-dsl/`, `cabal test keiro-dsl-conformance-readmodel-runtime` green;
`cabal test` (all suites, run from `keiro-dsl/` — the unit suite assumes that cwd) green.

### Milestone 5 — Differ registration and documentation

**Scope.** Make evolution of a `readmodel` node visible to `diff --since`, and document the
node. At the end, an identity-bearing edit exits non-zero as BREAKING.

`docs/plans/103-make-keiro-dsl-diff-sound-over-the-full-decode-and-identity-surface.md` is
a **hard dependency**: it generalizes `Keiro.Dsl.Diff.diffSpecs` (today hardwired to
`NAggregate`, `Diff.hs:52-58`) into per-node-family differs over matched old/new node
pairs, producing `Change = Additive ChangeKind | Breaking ChangeKind` values carrying a
`DiagnosticCode`. The interface this plan expects to register against is, in whatever
concrete spelling 103 delivers, "given `(Maybe ReadModelNode, Maybe ReadModelNode)` matched
by node name, return `[Change]`". Implement
`readModelDiff :: Name -> Maybe ReadModelNode -> Maybe ReadModelNode -> [Change]` in
`Keiro.Dsl.Diff` and register it: node removed ⇒ Breaking (queries against a registered
model whose definition vanished); node added ⇒ Additive; `version` decreased ⇒ Breaking;
`shape` changed while `version` unchanged ⇒ Breaking (the registry comparison in
`ensureReadModel` will fail every query with `ReadModelStaleSchema`, and nothing marks the
rebuild); `table`, `schema`, `subscription` (declared or derived), or node name changed ⇒
Breaking (identity rename: the data table, the cursor, or the registry row is orphaned);
`feed` flipped ⇒ Breaking (the feeding machinery and rebuild projection lists change);
consistency `Strong -> Eventual` ⇒ Breaking (callers lose a read guarantee) while
`Eventual -> Strong` ⇒ Additive. Reuse existing diff codes where they fit; add codes only
if 103's delivered vocabulary lacks a fit (append-only, as always). If 103 has not landed
when this milestone starts, carry `readModelDiff` as a standalone arm called from
`diffSpecs` and reconcile the wiring when 103 lands — record the reconciliation in both
plans' Decision Logs.

In `agents/skills/keiro-dsl-authoring/NOTATION.md`, add a minimal `## readmodel (EP-107)`
section after the workqueue/dispatch section: the two worked examples from this plan's
Context (abbreviated), the derivation rules (registry name, subscription default, shape
hash), and one-line callouts — `Strong` requires `feed = subscription`; `scope` requires
`Strong`; the aggregate `projection` clause references a node by name and its
`consistency=` is optional/deprecated; `query` operations and `dispatch` read-model
references resolve against these nodes. Update the EP-5 dispatch snippet's comment and the
EP-6 `query` line accordingly. Keep it minimal — the holistic skill/corpus refresh
(SKILL.md, LOOP.md, WALKTHROUGH.md, the corpus index, the cold-start proof) is
`docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md`.

Acceptance: from `keiro-dsl/`, commit the positive fixture, then edit
`test/fixtures/readmodel.keiro` changing a column type without touching `version`/`shape`;
`check` fails with `RmShapeHashDrift`. Fix `shape` to the recomputed digest but leave
`version = 1`; `cabal run keiro-dsl -- diff test/fixtures/readmodel.keiro --since HEAD`
prints a BREAKING line and exits non-zero. Restore the file.


## Concrete Steps

All commands run from `keiro-dsl/` unless stated otherwise (the unit suite assumes that
working directory for its relative fixture paths).

Before editing, re-verify the runtime surface against the tree (the MP-14/EP-101 standing
assumption):

```bash
sed -n '92,145p' ../keiro/src/Keiro/ReadModel.hs        # ReadModel record + modes + scope
sed -n '80,86p'  ../keiro/src/Keiro/ReadModel/Schema.hs  # registerReadModel signature
sed -n '70,110p' ../keiro/src/Keiro/ReadModel/Rebuild.hs # startRebuild/finishRebuild
grep -n 'data AsyncProjection' -A 8 ../keiro/src/Keiro/Projection.hs
```

Expected: the shapes embedded in this plan's Context. Any divergence goes into Surprises &
Discoveries and the plan text before code is written.

Per milestone:

```bash
cabal build
cabal test keiro-dsl-test
```

Milestone 2 spot-check transcript:

```bash
cabal run keiro-dsl -- check test/fixtures/readmodel-strong-inline.keiro ; echo "exit=$?"
```

```text
test/fixtures/readmodel-strong-inline.keiro:9: error[RmStrongInlineOnly]: readmodel 'subscriptions': consistency = Strong with feed = inline — an inline-only model has no subscription worker to advance the cursor a Strong read waits on; every Strong query on a non-empty log times out. Use consistency = Eventual, or feed = subscription
exit=1
```

Milestone 3 spot-check:

```bash
cabal run keiro-dsl -- scaffold test/fixtures/readmodel.keiro --out /tmp/rm-demo
grep -n 'registerReadModel\|shapeHash\|CategoryHead' \
  /tmp/rm-demo/Generated/HospitalCapacity/Transfer_decisions/ReadModel.hs
cabal run keiro-dsl -- scaffold test/fixtures/readmodel.keiro --out /tmp/rm-demo   # second run
```

Expected: the generated record and helpers as sketched in Milestone 3; the report's second
run shows the `ReadModelHoles` module `kept`, everything else `rewritten`; `firewall: clean`.

Milestone 4:

```bash
cabal test keiro-dsl-conformance-readmodel-runtime
cabal test
```

Milestone 5 (mutation walk, run and then restore):

```bash
git stash list >/dev/null  # ensure a clean tree first
sed -i '' 's/status         text required/status         int required/' test/fixtures/readmodel.keiro
cabal run keiro-dsl -- check test/fixtures/readmodel.keiro ; echo "exit=$?"   # RmShapeHashDrift, exit=1
git checkout -- test/fixtures/readmodel.keiro
```


## Validation and Acceptance

Acceptance is behavioral, per milestone, and cumulative:

1. `test/fixtures/readmodel.keiro` parses, round-trips through the pretty-printer, and the
   round-trip property covers the node via `genReadModel`.
2. `check` exits non-zero with the named code for each of the eight negative fixtures, and
   exits zero on the positive fixture; a `query` operation naming an undeclared model and a
   `dispatch` naming an undeclared read model are both rejected — the two references that
   were unresolvable before this plan.
3. `scaffold` emits, for each `readmodel` node, a firewall-clean generated module whose
   `ReadModel` value carries every spec field, a `register<Model>` helper matching the
   runtime's documented startup call, rebuild helpers with the correct projection-name
   list, and (subscription-fed) an `AsyncProjection`; the query hole module is created once
   and never overwritten; projection SQL holes name the qualified table (E5).
4. `cabal test keiro-dsl-conformance-readmodel-runtime` compiles the committed scaffold
   output against the live `keiro` package and its assertions pass — in particular
   `qualifiedTableName` agreement, which proves the generated constant and the runtime
   qualifier can never drift apart silently.
5. The differ classifies the identity-bearing edits (version decrease, shape-without-bump,
   table/schema/subscription/node rename, feed flip, `Strong -> Eventual`) as BREAKING with
   non-zero exit, and `Eventual -> Strong`/new-node as additive.
6. The full suite — `cabal test` from `keiro-dsl/`, all conformance suites included — is
   green, proving no existing vertical regressed (the projection-clause loosening and the
   fixture updates are the riskiest edits; the pinned scaffold-conformance copies are the
   tripwire).


## Idempotence and Recovery

Every step is additive and re-runnable. Scaffolding is idempotent by construction:
`Generated` modules are rewritten deterministically, `HoleStub` modules are
create-if-absent, and scaffolding into `/tmp` demo directories never touches the repo. The
Milestone 5 mutation walk edits a fixture and restores it with `git checkout --`; do it on
a clean tree. If a validator rule added here fires on an existing fixture unexpectedly,
that is signal, not breakage: either the fixture predates the rule (update the fixture, as
Milestone 2 does for `subscription.keiro` and `reservation-work.keiro`) or the rule is
wrong (fix it and add the fixture as a regression case). If the scaffold-conformance pin
fails after emitter changes, regenerate the committed copies with the scaffolder itself and
re-read the diff before committing — never hand-edit a pinned `Generated` file. No step
touches a database or a runtime package; there is nothing to roll back outside `keiro-dsl/`
and `agents/skills/keiro-dsl-authoring/NOTATION.md`.


## Interfaces and Dependencies

**Runtime modules consumed (read-only, never edited).** `Keiro.ReadModel`
(`keiro/src/Keiro/ReadModel.hs`): `ReadModel (..)`, `ConsistencyMode (..)`,
`StrongScope (..)`, `qualifiedTableName`, `ReadModelError (..)`, re-exported
`Keiro.ReadModel.Schema` (`registerReadModel :: (Store :> es) => Text -> Int -> Text ->
Eff es ReadModelMetadata`, `ReadModelStatus (..)`); `Keiro.ReadModel.Rebuild`
(`startRebuild`, `finishRebuild`, `abandonRebuild`, `RebuildError (..)`);
`Keiro.Projection` (`InlineProjection (..)`, `AsyncProjection (..)`). These are the
MP-14/EP-101 surfaces; the conformance suite is the mechanism that keeps the emitters
honest against them.

**keiro-dsl modules produced/extended.** `Keiro.Dsl.Grammar` gains `ReadModelNode`,
`RmColumn`, `RmFeed`, `RmScope`, `NReadModel`, and the `Maybe`-loosened
`ProjectionSpec.projConsistency`. `Keiro.Dsl.ReadModelShape` (new) owns
`canonicalShape`/`deriveShapeHash`/`registryNameFor`/`subscriptionNameFor` — the single
source of every derivation the parser does not capture. `Keiro.Dsl.Parser`,
`Keiro.Dsl.PrettyPrint`, `Keiro.Dsl.Validate` (eleven new `DiagnosticCode` constructors,
appended), `Keiro.Dsl.Scaffold` (`scaffoldReadModel :: Context -> ReadModelNode ->
[ScaffoldModule]`), `Keiro.Dsl.Harness` (`harnessReadModel`), `Keiro.Dsl.Diff`
(`readModelDiff`), and `keiro-dsl/app/Main.hs` (scaffold wiring) are extended in place.
End state per milestone: after M1 the Grammar/Parser/PrettyPrint symbols exist and
round-trip; after M2 `validateSpec` covers the node and both resolution sites; after M3
`scaffoldReadModel` exists with the two-module contract above; after M4 `harnessReadModel`
and the cabal suite exist; after M5 `readModelDiff` exists and NOTATION.md documents it all.

**Sibling-plan integration points (paths only; each plan is independently readable).**

- `docs/plans/103-make-keiro-dsl-diff-sound-over-the-full-decode-and-identity-surface.md` —
  hard dependency for Milestone 5's registration into the generalized differ. Expected
  interface: per-node-family diff over name-matched old/new pairs returning `[Change]`.
  If its delivered shape differs, reconcile at implementation time; if it has not landed,
  ship `readModelDiff` as a standalone `diffSpecs` arm and migrate when it does.
- `docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md` —
  owns the existing `DiagnosticCode` registry (this plan appends, never renames) and the
  general cross-node reference machinery. Two of its arms are explicitly stubbed pending
  this plan and are completed here: `QueryOp` read-model resolution
  (`QueryUnresolvedReadModel`/`QueryConsistencyInvalid`) and the pgmq dispatch read-model
  references (`DispatchReadModelUnresolved`/`DispatchReadModelFieldUnknown`). Whichever
  plan lands second wires its codes after the other's in the enum and removes any
  placeholder stub.
- `docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md` —
  owns string escaping, duplicate-clause rejection, numeric bounds, and identifier hygiene;
  this plan avoids depending on any of those fixes (no `"` in fixtures, single-block
  fixtures, small ints) and inherits them when they land.
- `docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md` —
  owns scaffolder-wide hardening; this plan's new emitters follow its rule from day one
  (every spec-text splice escaped like `tshow`).
- `docs/plans/108-add-a-router-node-and-rejection-and-poison-policy-surfaces-to-keiro-dsl.md`
  and
  `docs/plans/109-extend-keiro-dsl-node-coverage-pgmq-ordering-and-provisioning-snapshot-policy-and-workflow-patch-and-continue-as-new.md` —
  soft neighbors: a router node's `resolve-via` read model and any future pgmq surface
  resolve against `NReadModel` by node name, the same join this plan gives `QueryOp` and
  `PgmqDispatch`.
- `docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md` —
  owns the holistic skill/corpus/NOTATION refresh; this plan adds only the minimal
  `readmodel` section and the two resolution notes.

**Packages.** The `keiro-dsl` library itself gains no new dependency (FNV-1a is
hand-rolled; everything else is `text`/`megaparsec` already in use). The new conformance
suite depends on `keiro`, `kiroku`, `effectful-core`, `hasql-transaction`, `text`, `base` —
the same closure the existing runtime suites draw on.
