---
id: 278
slug: expose-aggregate-inspection-read-apis
title: "Expose aggregate inspection read APIs"
kind: exec-plan
created_at: 2026-09-10T03:03:53Z
intention: "intention_01m24m6m00ev59wa81shymsktd"
master_plan: "docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md"
provenance:
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-30T23:44:28Z
      mode: "update"
      note: "Adopted by MasterPlan 45: kiroku-store 0.10.0.0 gate, hydrateWithSource hand-off to plan 274, hook coexistence, handle allocation"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:38:52Z
      mode: "update"
      note: "Correct hot-path isolation, bounded inspection/feed ownership, released APIs, observation semantics, and mandatory performance acceptance; implementation remains pending."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:22:22Z
      verdict: "changes-requested"
      note: "Pre-update review: discarded hydration diagnostics on command path, concurrent state/version mismatch, filtered cursor loss, and stale released API."
---

# Expose aggregate inspection read APIs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

An aggregate is the central thing a keiro application models: one entity (an order, an
incident) whose current state is never stored directly but is folded, on demand, from the
events appended to its own stream. Today that state is invisible to anyone who is not writing
Haskell against `Keiro.Command`. An operator who wants to know why a command was rejected has
no way to look at the aggregate's current state; an operator exploring an unfamiliar system
has no way to list which aggregates of a given kind exist; and nobody can tell whether the
advisory snapshot that is supposed to accelerate an aggregate's hydration is present, current,
or stale.

After this change an operator can answer all three questions through supported library reads
in the `keiro` package and, on top of them, through read-only `keiro-ops` commands that render
the same structured result as a human table or as JSON. Against a migrated database in which
the example application has placed the order `1001` and configured its `order` aggregate with
snapshots every two events, the following commands work:

```bash
jitsurei-demo ops aggregate types --json
jitsurei-demo ops aggregate list --name order --limit 50 --json
jitsurei-demo ops aggregate show --name order --id 1001 --json
jitsurei-demo ops aggregate snapshot --name order --id 1001 --json
```

The first prints the aggregate kinds the application has mounted, with their stream category
and snapshot configuration. The second prints one page of the `order` category's aggregates
with each one's id, stream name, and current stream version, plus a `next_cursor` when more
pages exist. The third prints the order's current state exactly as the command runner would
fold it for the next command, together with how that state was reached (from a snapshot at a
given version, or by full replay and why), the snapshot's health, and a reference to the
kiroku-owned stream that holds the raw history. The fourth prints the snapshot health alone,
and for an aggregate with no snapshot it says so rather than failing.

Those commands are the substrate that the HTTP endpoints requested for a browser UI wrap: the
sister package planned by [ExecPlan 276](276-serve-the-keiro-ops-surface-over-http.md) turns
every read-only `keiro-ops` command into a `GET` route mechanically, so this plan adds no
transport and no web dependency. The JSON shapes follow the initiative's wire conventions
(snake_case keys, `items` plus an omitted-on-last-page `next_cursor`, opaque cursors) so that
wrapping changes nothing.

This plan implements the improvement request
[IR-28](../improvement-requests/expose-aggregate-inspection-read-apis.md), whose canonical
handle is `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-28`. It is one of the
keiro-side requests of the keiro runtime UI initiative (`mori://shinzui/keiro-ui`).


## Progress

- [x] (2026-10-13) Correctness and hot-path design review applied; implementation remains outstanding.
- [ ] Validate the review constraints and record the required performance/correctness evidence before marking this plan complete.


Milestone 0 is a short preflight; every later milestone starts only after its findings are
recorded in Surprises & Discoveries. Milestone 4 is gated on a kiroku release and may
complete after Milestone 5.

- [x] (2026-09-10T03:04Z) Plan created with intention `intention_01m24m6m00ev59wa81shymsktd`; IR-28 gained a "Planning (2026-09-10)" section linking this plan, its `timestamp` advanced, and the bundle log records the update. Status remains `proposed`.
- [ ] M0: confirm that `Keiro.Command.hydrate` is the only snapshot-seeded hydration path used by every command runner, that a `seedVerifySampleRate` of zero schedules no background verification, and that no metrics or tracer are touched when both are `Nothing`; record the evidence.
- [ ] M0: verify the current released `kiroku-store` listing API and supported bounds; record released source and tag evidence.
- [ ] M0: record whether `keiro/src/Keiro/Inspection/Cursor.hs` (plan 275) exists on the current tree; if it does not, this plan creates it in Milestone 4 to plan 275's exact interface.
- [ ] M1: add `HydrationSource`, `FullReplayReason`, `hydrateWithSource`, and `inspectionRunCommandOptions` to `keiro/src/Keiro/Command.hs`; keep the ordinary hydration result path specialized; tests prove source reporting for snapshot, full-replay, corrupt-snapshot, and no-codec cases; the command benchmark is unchanged.
- [ ] M1: add `SnapshotObservation` and `observeSnapshotRow` to `keiro/src/Keiro/Snapshot/Schema.hs`; `keiro-ops snapshot show` gains the additive `observed_at` and `age_seconds` keys with tests.
- [ ] M2: add `keiro/src/Keiro/Inspection/Aggregate.hs` with the inspector descriptor, smart constructors, `inspectAggregate`, `snapshotStatusFor`, `listAggregateTypes`, the error type, and the library-owned JSON rendering.
- [ ] M2: tests in a new `describe "Keiro.Inspection.Aggregate"` group: exhaustive fold-equivalence against `hydrateFull` with and without a snapshot, corrupt-snapshot fallback, soft-deleted stream, truncation gap, unknown aggregate, blank id, snapshot status present/absent/incompatible/unused, and JSON key inventory.
- [ ] M3: add `AppHooks.aggregates` to `keiro-ops/src/Keiro/Ops/Embed.hs` and the embedded-only `aggregate` domain (`types`, `show`, `snapshot`) in `keiro-ops/src/Keiro/Ops/Aggregate.hs`; standalone-tree and embedded-tree tests updated; handler tests compare `jsonValue` with the library rendering.
- [ ] M3: add `jitsurei/src/Jitsurei/Inspection.hs` with inspectors for `order` and `incident`, mount it in `jitsurei/app/Main.hs`, and add a `describe "Jitsurei aggregate inspection"` test group.
- [ ] M4: integrate released listing with raw-row cursors, retaining the current supported store bound; add library, CLI and example tests.
- [ ] M5: user documentation, API reference, the aggregate-inspection capability record (CAP-20 on 2026-09-30 unless plan 276 took it; allocate with `okf id next`) and updates to CAP-4 and CAP-16, changelogs, IR-28 implementation evidence, the new ADR plus the ADR-28 paragraph, and the full `just verify` gate.


## Surprises & Discoveries

2026-10-13 source review: hydrate has a probe wrapper and bounded seed verification. The proposed diagnostic pair was on the command path; initial getStream and hydration can observe different versions.


(None yet.)


## Decision Log

- Decision (2026-10-13): apply the current review constraints in Context, Plan of Work, and Validation. Rationale: hydrate has a probe wrapper and bounded seed verification. The proposed diagnostic pair was on the command path; initial getStream and hydration can observe different versions. Historical September decisions below are retained as history; conflicting create-first, downgrade, zero-cost-index, unconditional-provenance and partial-completion instructions are withdrawn.


- Decision: Deliver the library reads in `keiro` and the read-only `keiro-ops` commands that
  render them; build no HTTP endpoint in this plan.
  Rationale: IR-28 item 2 asks for endpoints "in the IR-26 sister package". That package is
  planned by [ExecPlan 276](276-serve-the-keiro-ops-surface-over-http.md), which derives every
  route from the `keiro-ops` command tree through `isMutation` rather than from a route list,
  so adding read-only commands here is exactly the endpoint substrate. The sibling plans for
  IR-29 ([274](274-expose-process-manager-inspection-reads.md)) and IR-30
  ([275](275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md)) made the same
  choice, and building a second transport would collide with them.
  Date: 2026-09-10

- Decision: Put the reads in a new module `Keiro.Inspection.Aggregate` and put the wire
  rendering (snake_case JSON, `items` plus optional `next_cursor`) in that module too, with
  `keiro-ops` rendering its `--json` output through those functions.
  Rationale: Plan 275 established `Keiro.Inspection.*` as the namespace for inspection reads
  and `Keiro.Inspection.Cursor` as the shared cursor codec; a sibling namespace keeps the
  aggregate reads findable beside them. Library-owned rendering is what makes IR-28
  acceptance 1 ("the corresponding endpoint serves the same page as JSON") hold by
  construction: the CLI and the HTTP layer cannot drift from each other when both call the
  same encoder. Plan 274 renders in `keiro-ops` instead; both are acceptable, and the two
  descriptor records deliberately share field names (`eventStream`, `category`,
  `displayState`, `stateLabel`) so a later consolidation is mechanical.
  Date: 2026-09-10

- Decision: The application supplies an explicit display encoder for aggregate state. The
  inspector descriptor never falls back to the snapshot `StateCodec` on its own; a helper
  `displayViaStateCodec` exists for applications that deliberately choose the snapshot
  encoding as their display encoding.
  Rationale: IR-28 item 1b asks that state be "rendered through a supported display/JSON
  encoding rather than exposing internal representations accidentally". The snapshot codec is
  a persistence format that may carry register internals and may be absent (`stateCodec =
  Nothing` is the common case in `jitsurei`), so it cannot be the implicit default. Making
  the choice explicit at the descriptor is what removes "accidentally".
  Date: 2026-09-10

- Decision: Reconstruct state through the exact command-side path by adding an additive
  `hydrateWithSource` to `Keiro.Command` that returns the `Hydrated` value together with a
  `HydrationSource`, and redefining the existing `hydrate` as `fst`-projection over it.
  Rationale: IR-28 item 1b requires the `Hydrated` path itself, not a parallel decoder, and
  acceptance 2 requires fold equality with the command path at the same version. The command
  runner does not report whether it started from a snapshot, and adding a field to the
  exported `Hydrated` record would break every consumer that constructs it (the replay audit
  does). A second function with the same body, and the old name delegating to it, keeps one
  implementation and changes no existing signature. Inspection calls it with
  `seedVerifySampleRate = 0`, no metrics, and no tracer so a read schedules no background work
  and emits no command telemetry.
  Date: 2026-09-10

- Decision: Listing aggregates wraps the kiroku-store primitive `listStreams` with the name
  prefix `<category>-`, which kiroku's own plan 88 adds for kiroku IR-8; keiro's listing ships
  only against a released `kiroku-store` that exports it (planned as 0.9.0.0).
  Rationale: `kiroku-store` 0.8.0.0 has no stream listing, ADR 28 forbids keiro from querying
  kiroku's private `streams` table, and discovering aggregates by scanning category events
  would cost one event scan per page, which a polling UI multiplies. Kiroku's plan
  `docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md`
  (canonical project `mori://shinzui/kiroku`, artifact-level URI pending) defines
  `listStreams :: Maybe CategoryName -> Maybe Text -> Maybe StreamName -> BrowsePageSize -> Eff es (Vector StreamInfo)` with
  an exact `starts_with` prefix filter and an exclusive name cursor. Because kiroku defines a
  stream's category as the text before its first `-`, the prefix `<category>-` selects exactly
  that category and nothing else (`order-` does not match `orders-1`). Plan 274 assumed a
  differently shaped primitive (`listStreamsInCategory`); the primitive kiroku is actually
  building is this one, and both keiro plans should wrap it.
  Date: 2026-09-10

- Decision: List cursors are opaque tokens minted by `Keiro.Inspection.Cursor` (plan 275's
  module) with kind tag `aggregate-list` over the last returned stream name; page sizes are
  validated to 1 through 500 and out-of-range sizes are errors, not clamped.
  Rationale: The keiro-ui conventions (`mori://shinzui/keiro-ui`,
  `docs/architecture/inspection-api-conventions.md`, artifact-level URI pending) require
  cursors the client never does arithmetic on. Plan 275 owns the shared codec so every keiro
  inspection read mints interchangeable tokens; plan 277 proposes a second codec in
  `keiro-ops`, and this plan follows the library-owned one. Validation rather than clamping
  follows the timer precedent in ADR 28.
  Date: 2026-09-10

- Decision: Snapshot health is observed against the database clock: one transaction reads the
  `keiro_snapshots` row and `now()` together, and age is `now() - updated_at`.
  Rationale: A snapshot's `updated_at` was written by another process on possibly another
  host; mixing the caller's clock with it misreports age. Plan 274 adopted the same
  single-clock rule for shard leases. The same observation extends the existing database-only
  `keiro-ops snapshot show` with two additive keys (`observed_at`, `age_seconds`) so the
  standalone console also answers IR-28 item 1c.
  Date: 2026-09-10

- Decision: A soft-deleted aggregate stream is reported (with `deleted_at`) but not hydrated;
  its `state`, `state_label`, and `hydration` are `null`.
  Rationale: `readStreamForward` returns nothing for a soft-deleted stream, so hydrating it
  would silently show the initial state at version zero while `getStream` reports the real
  version, which is exactly the misleading display an inspection surface must not produce.
  Date: 2026-09-10

- Decision: The aggregate view serves no page of events. It carries a `history` object naming
  the owner (`kiroku`), the stream name, and the head version, which is what kiroku's browsing
  endpoints (kiroku IR-8, plan 88's `GET /streams/<name>/events`) take.
  Rationale: IR-28 items 3 and acceptance 5. Raw stream and event browsing is kiroku's
  surface; keiro's view adds only framework semantics (the fold, the snapshot, the aggregate
  identity). Because the view addresses its own stream by name, it never sees a surrogate
  stream id and needs no batch name resolution (kiroku ADR-1).
  Date: 2026-09-10

- Decision: A `show` or `snapshot` command for an aggregate whose stream does not exist ends
  in `Failed`, which plan 276 maps to HTTP 422; a `snapshot` read for an existing aggregate
  without a snapshot succeeds with `"status": "absent"`.
  Rationale: IR-28 acceptance 3 distinguishes "no snapshot" (a normal state, must not error)
  from "no such aggregate" (an error). `OpsOutcome.Failed` carries only text, so a typed
  not-found code is future `keiro-ops` work already noted by plan 276; `wf show` follows the
  same convention today.
  Date: 2026-09-10

- Decision: Listing the inputs an aggregate accepts next ("what commands would succeed") is
  deferred. If plan 274's `EnabledInput` machinery lands, the aggregate view adopts it as an
  additive key.
  Rationale: IR-28 asks for state, listing, and snapshot metadata. Plan 274 is building the
  enabled-edge computation over keiki's `edgesOut` for process managers in parallel; building
  it twice would produce two renderings of the same fact.
  Date: 2026-09-10

- Decision: The fold-equivalence check is an exhaustive enumeration of short command
  sequences over the test counter aggregate rather than a QuickCheck property.
  Rationale: The `keiro` test suite depends on `hspec` only and uses no property-testing
  library; every database example clones a database, so the enumeration runs inside one
  example against distinct stream names. The enumeration covers snapshot boundaries (versions
  2 and 4 under `Every 2`) and the no-snapshot stream, which is what acceptance 2 asks for.
  Date: 2026-09-10

- Decision: The `aggregate` command domain is embedded-only, mounted through a new
  `AppHooks.aggregates` hook.
  Rationale: hydrating and displaying state needs the compiled event stream, codec, and
  display encoder, which the database cannot supply; this is the capability boundary ADR 28
  draws for `replay-audit` and `rebuild`.
  Date: 2026-09-10

- Decision: Creating this plan does not change IR-28's status. The request stays `proposed`
  until implementation evidence and the release that carries it exist.
  Rationale: repository convention (plans 270, 272, 274 through 277): completion is recorded
  from evidence.
  Date: 2026-09-10

- Decision: This plan is adopted as EP-3 of
  [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md),
  whose Integration Points settle every artifact this plan shares with its siblings; commits
  carry both this plan's `Intention:` trailer and the `MasterPlan:` trailer.
  Rationale: the five plans written on 2026-09-10 disagreed on the cursor codec, the kiroku
  listing primitive and its release, the hook layout, and the OKF handles; the MasterPlan is
  the one place those decisions are recorded, and this plan's text now agrees with it.
  Date: 2026-09-30

- Decision: Milestone 4 waits for `kiroku-store` 0.10.0.0, not 0.9.0.0. The bound bump to
  `>=0.10 && <0.11` in `keiro-core`, `keiro`, `keiro-migrations`, `keiro-test-support`,
  `keiro-dsl`, `keiro-ops`, `keiro-ops-http` (if it exists) and the `mori.dhall` dependency
  entries is done once, by whichever of this plan's Milestone 4 and plan 274's Milestone 5
  executes first; the second finds it done. Plan 303 ships the cohort without Milestone 4 if
  the kiroku release is late, and IR-28 then records item 1a as pending until the next
  lockstep release.
  Rationale: `kiroku-store` 0.9.0.1 shipped without `listStreams` and every keiro package
  pins `>=0.9.0.1 && <0.10`; kiroku's MasterPlan 13 (created 2026-09-30) releases the
  primitive as 0.10.0.0 through its plan 96. The version this plan named on 2026-09-10 was an
  expectation that kiroku's own release planning has since superseded (MasterPlan 45,
  Integration Points, "The kiroku listing primitive and the `kiroku-store` bound").
  Date: 2026-09-30

- Decision: `hydrateWithSource`, `HydrationSource`, `FullReplayReason`,
  `inspectionRunCommandOptions`, and the `hydrationSourceJson` shape are shared with plan 274,
  whose instance view uses them instead of its own two-constructor `HydrationSource` and its
  second `lookupSnapshotSeed` call. Whichever of plans 274 and 278 lands first creates them in
  `keiro/src/Keiro/Command.hs` (and the JSON encoder in `Keiro.Inspection.Aggregate`) to the
  exact interface in this plan's Interfaces and Dependencies; the other imports them.
  Rationale: two views of "did this state come from a snapshot" that could disagree is the
  drift an inspection surface must not produce (MasterPlan 45, Integration Points,
  "Source-reporting hydration").
  Date: 2026-09-30

- Decision: `AppHooks.aggregates` coexists with plan 274's `AppHooks.processManagers`; both
  are additive `Maybe` fields defaulting to `Nothing`; whichever plan lands second extends the
  existing record, `emptyAppHooks`, the "omits code-dependent commands from the standalone
  tree" and "mounts every code-dependent command" tests, the `embeddedHooks` value, and
  `jitsureiOpsHooks` rather than replacing them. The domain word `aggregate` is reserved for
  this plan and `pm` for plan 274.
  Rationale: both plans edit `keiro-ops/src/Keiro/Ops/Embed.hs`, `keiro-ops/src/Keiro/Ops.hs`,
  and `keiro-ops/test/Main.hs`; the rule keeps the merge mechanical (MasterPlan 45,
  Integration Points, "`AppHooks` and the command tree").
  Date: 2026-09-30

- Decision: OKF handles are allocated with `okf id next` at creation and never reserved by
  this plan. On 2026-09-30 the next free handles were CAP-20 (plan 276 also expects it for its
  HTTP-surface record; whichever creates its record first takes it and the other takes the
  next) and ADR-49; ADR-40 is taken by the stance ADR this plan cites.
  Rationale: two sibling plans claimed CAP-20 and two claimed ADR-40; a plan that names a
  handle states an expectation, not a reservation (MasterPlan 45, Integration Points, "OKF
  handles and documentation bundles").
  Date: 2026-09-30


## Outcomes & Retrospective

2026-10-13: Design corrected after source review; no feature implementation or passing performance evidence exists yet. The new acceptance gates must be met during implementation.


(To be filled during and after implementation.)


## Context and Orientation

### Review baseline and implementation boundary (2026-10-13)

This plan was reviewed against Keiro commit `cbcc593df2445780e2c42406c6b633ae530fb8ea`. Keiro is now 0.20.0.0 and already depends on released `kiroku-store ^>=0.11.0.0`; historical September version statements and Decision Log entries below are historical evidence, not instructions to downgrade. Hackage source and upstream tag `kiroku-store-v0.11.0.0` confirm the four-argument, `BrowsePageSize`-bounded listing API. Recheck the registry and upstream tags before changing bounds. [ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md) now also requires bounded inspection work and measured hot-path isolation.

Shared implementation has one owner: plan 275 creates the cursor codec, plan 278 creates source-reporting hydration, plan 274 creates pending-timer reads, and plan 276 creates the transport and admission budget. Consumers wait for those artifacts; they do not implement an absent owner's module. The old create-first instructions are withdrawn. The hard prerequisites for this plan are plan 275.

Application constructors allocate resources once in IO and return a bare WAI application: `opsApplication` and `opsApplicationWithFeeds` now return `IO Application`. Bind their results once during startup, never construct a new admission budget for each request. Pure composition still takes ordinary `Application` values. Per-request schema verification, handler execution, and feed refreshes share a bounded inspection budget; they must never use the writer's reserved pool capacity by default.


This repository is a Cabal multi-package project (`cabal.project` at the root). The packages
that matter here are `keiro` (the runtime library, `keiro/src/Keiro/…`), `keiro-core` (shared
types, `keiro-core/src/Keiro/…`, re-exported by `keiro`), `keiro-ops` (the operator command
tree, `keiro-ops/src/Keiro/Ops/…`), `keiro-test-support` (the PostgreSQL test fixture), and
`jitsurei` (the example application, `jitsurei/src/Jitsurei/…` and `jitsurei/app/Main.hs`).
The tree is at version 0.20.0.0 and uses `kiroku-store ^>=0.11.0.0`, which exports `listStreams`. Verify current registry releases and tags again before choosing bounds.

Terms used throughout, in plain language:

An **event stream** is keiro's description of one kind of aggregate: the record `EventStream`
in `keiro-core/src/Keiro/EventStream.hs` pairs a pure keiki state machine (`transducer`) with
an initial state and register file, an event codec, a function `resolveStreamName` from a
typed `Stream` handle to the physical store stream name, a `snapshotPolicy`, and an optional
`stateCodec`. Command runners accept only a `ValidatedEventStream`
(`keiro-core/src/Keiro/EventStream/Validate.hs`; build one with `mkEventStreamOrThrow`, unwrap
with `unvalidated`). A **register file** (`RegFile rs`) is keiki's typed set of named values
that travel with the control state; together `(state, registers)` is the aggregate's folded
state.

A **stream name** is `<category>-<id>` by convention: `Keiro.Stream`
(`keiro-core/src/Keiro/Stream.hs`) provides `StreamCategory` (a validated category text with
no `-`), `categoryText`, `categoryName`, `category` (validation returning `CategoryError`),
`categoryUnsafe`, and `entityStream :: StreamCategory a -> Text -> Stream a`, which builds the
name through kiroku's `streamNameInCategory`. Kiroku defines a stream's category as the text
before its first `-` (`Kiroku.Store.Types.categoryName`), so the id segment may itself contain
`-`. `Keiro.ReplayAudit.streamInCategory :: Text -> StreamName -> Maybe (Stream a)` accepts a
raw store name only when its category matches; this plan reuses it as the membership check.

**Hydration** is how keiro rebuilds an aggregate before deciding a command. In
`keiro/src/Keiro/Command.hs`, exported under "Hydration primitives (replay audit)":
`hydrate options eventStream targetStream` looks up a compatible snapshot seed through
`Keiro.Snapshot.lookupSnapshotSeed` when the stream has a `stateCodec`, replays the stored
events after the seed version through the transducer with `hydrateSeeded`, falls back to
`hydrateFull` (replay from the initial state at version 0) when the seeded replay fails, and
returns `Hydrated { state, registers, streamVersion }`. It takes a `RunCommandOptions` whose
`seedVerifySampleRate` schedules a background verification of one in N snapshot seeds and
whose `metrics` and `tracer` emit telemetry; `defaultRunCommandOptions` sets the rate to 1000
and both handles to `Nothing`. `hydrate` needs `IOE` in the effect stack because of that
background verification. `CommandError` (same file) names the hydration failures:
`HydrationDecodeFailed`, `HydrationReplayFailed`, and `HydrationGapDetected` (kiroku's
truncate-before marker hid events the seed does not cover).

A **snapshot** is one row per stream in `keiro.keiro_snapshots`
(`keiro-migrations/migrations/0001-keiro-bootstrap.sql`, column `state_shape_hash` added by
`0019-keiro-snapshots-state-shape-hash.sql`): `stream_id`, `stream_version`, `state` (JSONB),
the three compatibility discriminators `state_codec_version`, `regfile_shape_hash`,
`state_shape_hash`, and `created_at` / `updated_at`. `keiro/src/Keiro/Snapshot/Schema.hs`
exposes `SnapshotRow`, `lookupSnapshot` (compatibility-filtered, used by hydration),
`lookupSnapshotRow` (unfiltered, the operator surface), `deleteSnapshotRow`, and
`writeSnapshotRow`. `keiro/src/Keiro/Snapshot.hs` adds `SnapshotMissReason`
(`SnapshotNoStream`, `SnapshotNotFound`, `SnapshotDecodeFailed`) and `lookupSnapshotSeed`.
`keiro/src/Keiro/Snapshot/Codec.hs` provides `defaultStateCodec` and
`defaultStateCodecWithFold`, whose `encode` renders `{ "state": …, "registers": … }`.

**keiro-ops** renders every command into `OpsResult { headers, rows, jsonValue }`
(`keiro-ops/src/Keiro/Ops/Render.hs`) wrapped in `OpsOutcome` (`Succeeded`, `PreviewRequired`,
`Failed`, …). `keiro-ops/src/Keiro/Ops.hs` assembles the command tree; commands that need
compiled application values are mounted only when the matching field of
`Keiro.Ops.Embed.AppHooks` (`keiro-ops/src/Keiro/Ops/Embed.hs`; today `workflowResume`,
`timerFire`, `replayAudit`, `projectionCatalog`) is `Just`, exactly as `replay-audit` and
`rebuild` are. `keiro-ops/src/Keiro/Ops/Snapshot.hs` is the existing database-only snapshot
domain (`snapshot show`, `snapshot delete`, `snapshot truncation-preflight`) and shows the
house style for parsers, `isMutation`, `runAction`, and JSON rendering.
`keiro-ops/src/Keiro/Ops/ReplayAudit.hs` shows how an existential list of typed targets
(`Keiro.ReplayAudit.SomeAuditTarget`) is mounted through a hook and dispatched by category.
`keiro-ops/src/Keiro/Ops/Parse.hs` has the bounded numeric readers (`positiveIntReader`).

The **replay audit descriptor** `Keiro.ReplayAudit.AuditTarget { eventStream, category ::
Text, mkStream }` (`keiro/src/Keiro/ReplayAudit.hs`) already bundles what an inspector needs
except a display encoder; `jitsurei/src/Jitsurei/ReplayAudit.hs` builds two, and keiro-dsl's
scaffolder generates a `Generated.<Context>.ReplayAudit.auditTargets` list for every
generated service. This plan lets an application derive an inspector from an audit target so
neither hand-written nor generated services describe their aggregates twice.

**Tests**: `keiro/test/Main.hs` is one large Hspec suite run through `withMigratedSuite`
(`keiro-test-support/src/Keiro/Test/Postgres.hs`), which starts one ephemeral PostgreSQL,
migrates a template database once, and clones it per example; `withFreshStore` gives a
`KirokuStore`. The suite defines `counterEventStream` (category-free counter, no snapshots)
and `snapshotCounterEventStream` (register `lastAmount`, `snapshotPolicy = Every 2`,
`stateCodec = Just (defaultStateCodec @SnapshotCounterRegs @CounterState 1)`), the guarded
variant `guardedSnapshotCounterEventStream`, the SQL helper `corruptSnapshotStateStmt`, and the
`describe "Keiro.Snapshot"` group (search for `hydrates from snapshot and replays only the
tail`). `keiro-ops/test/Main.hs` builds a parser from `Ops.opsCommandTree`, defines
`embeddedHooks`, and runs handlers directly (`describe "snapshot handlers"`).
`jitsurei/test/Main.hs` has `describe "Jitsurei snapshots"` and `describe "Jitsurei incident
aggregate"` groups. There is no QuickCheck dependency in any suite.

**jitsurei** defines the aggregates this plan mounts: `Jitsurei.OrderStream` (category
`order`; `orderEventStream` without snapshots and `snapshotOrderEventStream` with
`Every 2` and `defaultStateCodecWithFold`, both over the same transducer; `OrderState` derives
`ToJSON` and `Jitsurei.Domain.stateText` labels it) and `Jitsurei.Incident` (category
`incident`, `incidentEventStream`). `jitsurei/app/Main.hs` mounts hooks in `jitsureiOpsHooks`
and exposes them as `jitsurei-demo ops …`.

**Documentation bundles** are OKF bundles with profiles: `docs/user/` and `docs/guides/`
(profile `mori/user-documentation-profile.dhall`), `docs/capabilities/`
(`docs/capabilities/profile.dhall`; CAP-3 is `transactional-command-cycle.md`, CAP-4 is
`advisory-snapshots.md`, CAP-16 is `operational-console.md`; the next free handle on
2026-09-30 is CAP-20, which plan 276 also expects, so allocate at creation),
`docs/improvement-requests/` (`mori/improvement-requests-profile.dhall`), and `docs/adr/`
(`docs/adr/profile.dhall`, stable `ADR-N` handles; ADR-40 is now taken by the stance ADR this
plan cites, and `okf id next` reported ADR-49 on 2026-09-30). Each bundle keeps a `log.md` appended
with `okf log add <bundle> --kind <Kind> -m "…"`. Changelogs are the root `CHANGELOG.md`,
`keiro/CHANGELOG.md`, and `keiro-ops/CHANGELOG.md`, each with an `[Unreleased]` heading;
`jitsurei` has none.

The keiro-ui wire conventions this plan's JSON follows live in the keiro-ui checkout at
`/Users/shinzui/Keikaku/bokuno/keiro-ui/docs/architecture/inspection-api-conventions.md`
(canonical project `mori://shinzui/keiro-ui`, artifact-level URI pending): snake_case field
names; cursor pagination as `items` plus `next_cursor`, omitted on the last page; cursors
opaque to clients; ADR 28's reporting vocabulary.

### Coordination under MasterPlan 45 (2026-09-30)

This plan is coordinated by [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md). Hard prerequisites: 275 (cursor codec). The 2026-10-13 Integration Points are the current contracts; older dated Decision Log and Revision notes preserve history, not alternative implementation instructions.

Plan 275 creates `Keiro.Inspection.Cursor` and `Keiro.Ops.Parse.cursorReader`; 278 creates source-reporting hydration; 274 creates the pending-timer read and encoder; 276 creates the shared inspection budget and HTTP application; 277 consumes these and owns bounded feeds; 302 composes allocated applications; 303 requires all work and measured interference gates before closure. Consumers import these interfaces after their prerequisites, never create competing implementations. Every child preserves existing hooks while extending them.

Keiro's current tree is 0.20.0.0 with `kiroku-store ^>=0.11.0.0`; released `listStreams` takes category, prefix, cursor and `BrowsePageSize`. The compatible released metrics surface is 0.3.0.0. Verify the registry and upstream tags again at implementation, retain supported current bounds, and do not defer listings on the obsolete 0.10 release gate. Allocate migration numbers and OKF handles at implementation. Strict ADR-40 and ADR-28 boundaries apply.

## Plan of Work

### Milestone 0: preflight

Read the runtime hydration worker, snapshot-seed validation and probe wrapper. Verify released store 0.11 source and tags through Mori and the registry as recorded in the MasterPlan. Plan 275 must have completed its cursor module and option reader; import them unchanged. Record baseline command allocation/query/latency measurements with snapshot hit, miss, corrupt seed, no state codec and long-history cases before editing hydration. Do not replace supported dependency bounds with the obsolete 0.10 range.

### Milestone 1: hydration that reports its source, and a clock-consistent snapshot observation

Scope: two additive library changes with no new module. At the end, a caller can learn how
`Keiro.Command` reached a hydrated state, and a caller can read a snapshot row together with
the database time it was observed at. `keiro-ops snapshot show` gains two keys.

In `keiro/src/Keiro/Command.hs` add, in the "Hydration primitives" export group,
`HydrationSource (..)`, `FullReplayReason (..)`, `hydrateWithSource`, and
`inspectionRunCommandOptions`. Define the types as in Interfaces and Dependencies. Move the
implementation behind a private result-continuation worker shared by `hydrate` and `hydrateWithSource`. The ordinary continuation returns only `Hydrated`; the inspection continuation records `FromSnapshot`, `SnapshotMissed`, `NoStateCodec`, or `SeededReplayFailed`. Do not build a `(Hydrated, HydrationSource)` pair and discard it on every ordinary command. Preserve `hydrateAfterProbe`, the compile-time reaction hydration probe, metrics, seed verification and `seedVerifyInFlightLimit`; no new store call, trace, IORef or allocation per replayed event belongs in the ordinary path. Inspect optimized output and benchmark allocations on both snapshot-hit and full-replay paths; if specialization does not erase diagnostic construction, fix the worker before proceeding. There must still be one replay implementation. `inspectionRunCommandOptions` is

`defaultRunCommandOptions` with `seedVerifySampleRate = 0`, `metrics = Nothing`,
`tracer = Nothing`, and `verifyReplayOnAppend = False` (the last is irrelevant to a read but
documents intent). Update the module header's "Hydration primitives" paragraph to mention the
source-reporting variant and inspection.

In `keiro/src/Keiro/Snapshot/Schema.hs` add `SnapshotObservation { row :: Maybe SnapshotRow,
observedAt :: UTCTime }` and `observeSnapshotRow :: (Store :> es) => StreamId -> Eff es
SnapshotObservation`, implemented as one `runTransaction` that runs `lookupSnapshotRowStmt`
and a `SELECT now()` statement (`D.singleRow (D.column (D.nonNullable D.timestamptz))`) in the
same transaction, so age uses one database clock (ReadCommitted does not freeze all rows across statements). Export both from
`Keiro.Snapshot.Schema` (they are re-exported by `Keiro.Snapshot` automatically through the
module re-export).

In `keiro-ops/src/Keiro/Ops/Snapshot.hs`, change `lookupByName` for the `Show` command to use
`observeSnapshotRow`, and extend `snapshotJson` and the human row with `observed_at` and
`age_seconds` (`realToFrac (diffUTCTime observedAt updatedAt) :: Double`), keeping every
existing key with its meaning. `Delete` and `TruncationPreflight` keep using `lookupSnapshotRow`.

Tests. In `keiro/test/Main.hs`, in the `describe "Keiro.Snapshot"` group, add cases: after two
`Add` commands on `snapshotCounterEventStream` (snapshot at version 2) and a third command,
`hydrateWithSource inspectionRunCommandOptions (unvalidated snapshotCounterEventStream) target`
returns version 3 and `FromSnapshot (StreamVersion 2)`; on `counterEventStream` it returns
`FullReplay NoStateCodec`; on a fresh stream with the snapshot codec but no commands it returns
`FullReplay (SnapshotMissed SnapshotNoStream)`; after corrupting the stored state with
`corruptSnapshotStateStmt` (as the existing "falls back when snapshot JSON is corrupt" case
does) it returns `FullReplay (SnapshotMissed (SnapshotDecodeFailed _))`; and a seeded replay
that fails (write a decodable seed whose state makes an existing tail event fail replay, while replay from the initial state succeeds) returns `FullReplay (SeededReplayFailed
(HydrationReplayFailed _))` (match the actual constructor fields) while `hydrate` still returns the same `Hydrated` value as
`hydrateFull`. Assert that with `inspectionRunCommandOptions` the in-memory metric exporter
used elsewhere in the group records no `keiro.snapshot.read.hits` point. Add a case that
`observeSnapshotRow` returns `Nothing` and a timestamp for a stream without a row, and the row
plus a timestamp at or after `updatedAt` for a stream with one. In `keiro-ops/test/Main.hs`
extend the "snapshot handlers" case to assert `observed_at` and a non-negative `age_seconds`
on `Show`. Run the command benchmark against its baseline (Concrete Steps) and record the
result; the refactor must not move it.

### Milestone 2: the aggregate inspection module

Scope: the new module `Keiro.Inspection.Aggregate` with the inspector descriptor, the single
aggregate view, the snapshot-health read, the type listing, the error type, and the JSON
rendering; listing aggregates is Milestone 4. At the end, a Haskell caller can inspect any
aggregate the application describes, and a test proves the state equals the command path's.

Create `keiro/src/Keiro/Inspection/Aggregate.hs` and add it to `exposed-modules` in
`keiro/keiro.cabal`. The module needs `GADTs` for the existential (the file-level pragma
`{-# LANGUAGE GADTs #-}` as `Keiro.ReplayAudit` uses). Define the types and functions in
Interfaces and Dependencies. The descriptor `AggregateInspector` holds the aggregate's
operator-facing `name`, its `ValidatedEventStream`, its `StreamCategory`, a `mkStream`
membership function, the `displayState` encoder, and a `stateLabel` function. The smart
constructor `aggregateInspector` sets `mkStream = streamInCategory (categoryText category)`
and `stateLabel = Text.pack . show`; `inspectorFromAuditTarget` validates the audit target's
`category` text with `Keiro.Stream.category` and reuses its `mkStream`;
`displayViaStateCodec codec state registers = (codec ^. #encode) (state, registers)`.
`aggregateInspectors` folds a list of `SomeAggregateInspector` into a `Map Text` keyed by
name and returns `Left` naming the first duplicate. `listAggregateTypes` renders one
`AggregateTypeSummary` per inspector: name, category text, whether a `stateCodec` is
configured, and the policy label (`never`, `every:<n>`, `on_terminal`, `custom`).

`aggregateStream inspector aggregateId` validates the id (non-blank after `Text.strip`, and
`mkStream` accepts the resulting name; otherwise `Left (AggregateIdRejected aggregateId)`) and
returns `entityStream (inspector ^. #category) aggregateId`. `aggregateIdOf inspector
streamName` strips the `<category>-` prefix and is `Nothing` when `mkStream` rejects the name.

`inspectAggregate inspector aggregateId` performs, in order: `aggregateStream`; `getStream`
on the resolved name, returning `Left (AggregateNotFound name)` for `Nothing`; when
`deletedAt` is `Just`, build the view with `hydration = Nothing`, `state = Nothing`,
`stateLabel = Nothing`; otherwise `hydrateWithSource inspectionRunCommandOptions (unvalidated
eventStream) stream`, mapping `Left err` to `Left (AggregateHydrationFailed name err)`; then
`snapshotStatusOf inspector info` (below); and assemble `AggregateView` with
`streamVersion = hydrated.streamVersion` for a live stream. The initial `getStream` and later hydration may observe different heads; never label new state with the earlier head. `history.headVersion` records the separately observed head, not a promise of an atomic view. Add `state_version` to the wire rendering as the explicit folded version (equal to `stream_version` for live state), and label separately timed metadata as observational, `state = Just (displayState state registers)`,
`stateLabel = Just (stateLabel state)`, and `history = HistoryReference { owner = "kiroku",
streamName, headVersion = info.version }`.

`snapshotStatusOf inspector info` calls `observeSnapshotRow info.id` and builds
`SnapshotStatus`: `configured` is `Nothing` when the event stream has no `stateCodec`, else
the policy label and the codec's three discriminators; `stored` is `Nothing` when no row
exists, else a `StoredSnapshot` with the row's version, timestamps, `ageSeconds`
(`observedAt - updatedAt`), `eventsSince = max 0 (info.version - row.streamVersion)` plus `ahead_of_observed_head = row.streamVersion > info.version`, and
`compatibility`: `Unused` when no codec is configured, `Compatible` when all three
discriminators equal the codec's, `Incompatible [names]` listing the differing discriminators
(`state_codec_version`, `regfile_shape_hash`, `state_shape_hash`). `snapshotStatusFor
inspector aggregateId` is the standalone read: `aggregateStream`, `getStream`, then
`snapshotStatusOf`, without hydration.

JSON rendering. `aggregateViewJson`, `snapshotStatusJson`, `hydrationSourceJson`,
`aggregateTypeJson`, and (Milestone 4) `aggregateSummaryJson` and `aggregateListPageJson`
produce exactly the shapes shown in Validation and Acceptance. Timestamps render through
`aeson`'s `UTCTime` instance (ISO-8601 with `Z`), stream versions as integers, and
`CommandError` values through `Keiro.Command.commandErrorClass` where one exists plus
`Text.pack . show` as `detail`.

Tests, in a new `describe "Keiro.Inspection.Aggregate"` group in `keiro/test/Main.hs` using
`around (withFreshStore fixture)`. Define at the bottom of the file
`snapshotCounterInspector :: AggregateInspector … = aggregateInspector "counter" snapshotCounterEventStream (categoryUnsafe "sc") (\state registers -> object ["state" .= show state, "last_amount" .= regFile lookup])`
and `plainCounterInspector` over `counterEventStream` with category `pc`, streams named
through `entityStream`. Cases:

- "state equals the command path's fold with and without a snapshot": for every command
  sequence of length 0 through 5 over `[Add 1, Add 2, Add 3]` (this is 364 sequences; use a
  deterministic subset of 40 that includes every length and both snapshot boundaries if the
  full set exceeds ten seconds, and record the choice), run the sequence through
  `runCommand defaultRunCommandOptions` on a distinct stream for each of the two inspectors,
  then assert `inspectAggregate` returns `Right view` with `view.state == Just (displayState
  fullState fullRegisters)` and `view.streamVersion == full.streamVersion` where `full` is
  `hydrateFull` on the same stream, and that `view.hydration` is `Just (FromSnapshot v)` with
  `v` the largest even version at most the length for the snapshot inspector when the length
  is at least 2, and `Just (FullReplay NoStateCodec)` for the plain inspector.
- "reports a decode-failed snapshot as full replay": corrupt the snapshot state and assert
  `hydration == Just (FullReplay (SnapshotMissed (SnapshotDecodeFailed _)))` while `state`
  still equals the full fold.
- "reports a soft-deleted stream without hydrating": `softDeleteStream` the stream, assert
  `deletedAt` is set, `state`, `stateLabel`, and `hydration` are `Nothing`, and
  `streamVersion` is the pre-delete head.
- "surfaces a truncation gap as a hydration failure": set the truncate-before marker above a
  covered version with `setStreamTruncateBefore` (as the `Keiro.Command` truncation tests do)
  and assert `Left (AggregateHydrationFailed _ (HydrationGapDetected _ _))`.
- "rejects an unknown aggregate and a blank id": `Left (AggregateNotFound _)` and
  `Left (AggregateIdRejected " ")`.
- "snapshot status": absent (`stored == Nothing`, `configured` present) on a fresh snapshot
  stream; present and `Compatible` with `eventsSince == 1` after three commands; `Incompatible
  ["state_shape_hash"]` after rewriting the row's `state_shape_hash` with test SQL; `Unused`
  when a row exists for a stream inspected through the plain inspector (write the row with
  `writeSnapshotRow`); `configured == Nothing` for the plain inspector.
- "JSON rendering carries the documented keys": render one view and one status and assert the
  key sets equal the documented ones, including `"status": "absent"` for the absent case and
  `hydration: null` for the soft-deleted case.

### Milestone 3: keiro-ops commands and the jitsurei mounting

Scope: the embedded-only `aggregate` command domain with `types`, `show`, and `snapshot`
(`list` arrives in Milestone 4), the hook that mounts it, and the example application
describing its aggregates. At the end, `jitsurei-demo ops aggregate show --name order --id
1001 --json` prints the view.

In `keiro-ops/src/Keiro/Ops/Embed.hs` add `aggregates :: !(Maybe AggregateInspectors)` to
`AppHooks` (`emptyAppHooks` sets `Nothing`) and re-export `AggregateInspectors` for
convenience. Create `keiro-ops/src/Keiro/Ops/Aggregate.hs` (add to `exposed-modules`) with
`Command = Types | Show ShowOptions | Snapshot ShowOptions` (Milestone 4 adds `List`),
`ShowOptions { name :: Text, aggregateId :: Text }`, a `commandParser` with subcommands
`types`, `show --name NAME --id ID`, and `snapshot --name NAME --id ID`, `isMutation = const
False`, and `runCommand :: OpsEnv -> AggregateInspectors -> Command -> IO OpsOutcome`. `Types`
needs no database: it renders `listAggregateTypes` as headers `name, category,
snapshots_configured, snapshot_policy`. `Show` and `Snapshot` look the inspector up by name
(`Failed ("no aggregate inspector named " <> name <> "; mounted: " <> …)` when absent), open
the existential, run the library read through `runStoreIO env.store`, map `Left` inspection
errors to `Failed` with a one-line message, and render `Right` through the library JSON
functions; the human rows show `name, aggregate_id, stream_name, stream_version, state_label,
hydration, snapshot_status` for `show` and `name, aggregate_id, status, snapshot_version,
age_seconds, compatibility` for `snapshot`.

In `keiro-ops/src/Keiro/Ops.hs` add the `Aggregate` constructor, mount the `aggregate`
command only when `hooks.aggregates` is `Just` (copy the `rebuildCommand` pattern), add the
`isMutation` and `runCommand` arms. Update the "omits code-dependent commands from the
standalone tree" and "mounts every code-dependent command" tests in `keiro-ops/test/Main.hs`,
adding a counter-style inspector to `embeddedHooks` (define a small event stream and category
`opscounter` in the test module; the existing `seedKirokuEvent` helper is not enough because
`show` needs a decodable stream, so append through `runCommand` on the test stream). Add a
`describe "aggregate handlers"` group: `Types` lists the mounted inspector; `Show` after two
commands returns `Succeeded` whose `jsonValue` equals `aggregateViewJson` of the library read
for the same stream (field-by-field equality, the acceptance-1 agreement); `Snapshot` on an
aggregate without a snapshot returns `Succeeded` with `status: "absent"`; `Show` on an unknown
id returns `Failed`.

In `jitsurei`, create `jitsurei/src/Jitsurei/Inspection.hs` exporting
`jitsureiAggregateInspectors :: AggregateInspectors` built from two inspectors:
`aggregateInspector "order" snapshotOrderEventStream orderCategory (\state RNil -> object ["state" .= stateText state])`
and `aggregateInspector "incident" incidentEventStream incidentCategory (…)` using the
incident state's `ToJSON` instance (check `Jitsurei.Domain` for what `IncidentState` derives
and add a `ToJSON` instance only if one is missing). Export `orderCategory` and
`incidentCategory` from their modules if they are not yet exported. Register the module in
`jitsurei.cabal`, re-export it from `Jitsurei`, and mount `aggregates = Just
jitsureiAggregateInspectors` in `jitsureiOpsHooks` in `jitsurei/app/Main.hs`. Choosing
`snapshotOrderEventStream` over `orderEventStream` is deliberate: both fold identically over
the same transducer, and the snapshot-enabled one lets the view show snapshot health for the
orders the `snapshots` demo writes. Add `describe "Jitsurei aggregate inspection"` to
`jitsurei/test/Main.hs`: place and pay an order through the existing command helpers, inspect
`order`/`<id>`, and assert `stateLabel == Just "paid"` and `state` equals the display of
`hydrateFull`'s result; inspect an incident after one command; assert `snapshotStatusFor`
reports a compatible snapshot for an order written through `snapshotOrderEventStream` after
two commands. Add the `ops aggregate …` invocations to the `ops` demo path only if the demo
already exercises other commands; otherwise leave the demo alone and document the commands.

### Milestone 4: listing aggregates through kiroku's `listStreams` (released API)

Scope: the `aggregate list` read and command over the already released listing primitive. The current bound is `kiroku-store ^>=0.11.0.0`; keep it. Inspect released source and tags before coding. `listStreams` takes optional exact category, optional literal prefix, exclusive stream-name cursor, and `BrowsePageSize`. Build the last with `mkBrowsePageSize (pageSize + 1)`, validating the public page size to 1..500 first. Pass both the inspector's exact category and its `<category>-` prefix; no private SQL or event scan is permitted.

Decode the `aggregate-list` cursor and fetch one raw page only. Examine at most the first `pageSize` raw rows, run the inspector's membership mapping on them, count rejected rows as `skipped`, and use the extra raw row only to detect continuation. Mint the next cursor from the last raw row examined, even if every examined row was rejected and `items` is empty. Never fill a display page by draining upstream pages. Preserve upstream UTF-8 byte ordering. Bind the cursor payload to the category/inspector identity; a changed identity is an invalid cursor, not a restart at an arbitrary key.

Expose `aggregate list --name NAME [--after CURSOR] [--limit N]` (default 50, maximum 500), rendering the existing summary envelope through the library. Lists perform no hydration or snapshot reads. Tests create matching, rejected, non-ASCII, deleted and hard-deleted streams; traverse with page size two; and prove exact coverage of accepted rows, strictly advancing cursors through fully rejected pages, no loss of the look-ahead row, and no cursor at raw exhaustion. Test first, deep and empty-result pages. A malformed, foreign-kind or foreign-inspector cursor fails before SQL. Compare CLI rendering with the same library result. No upstream work or dependency downgrade is part of this milestone.

### Milestone 5: documentation, evidence, and distillation

Scope: make the feature findable, record what was proven, and promote the durable decisions.

Documentation: add an "Inspecting aggregates" section to `docs/user/operations.md` under
"Operating Keiro" (the hook, the four commands with copyable JSON transcripts taken from test
output, the not-found behavior, the cost of each read, and the statement that raw history is
kiroku's surface); add an "Inspecting snapshot health" section to `docs/user/snapshots.md`
(the status object, compatibility vocabulary, age against the database clock, the additive
`snapshot show` keys); add `## Keiro.Inspection.Aggregate` and the new `Keiro.Command`
exports to `docs/user/api-reference.md`; add a short "Inspecting a hydrated aggregate"
subsection to `docs/guides/snapshots-and-hydration.md` using the jitsurei inspector. Append
log entries with `okf log add docs/user --kind Update -m "…"` and validate with
`just user-documentation-validate`. Create `docs/capabilities/aggregate-inspection-reads.md`
with the handle from `okf id next docs/capabilities --profile docs/capabilities/profile.dhall CAP`
(CAP-20 on 2026-09-30; plan 276's HTTP-surface record also expects it, so take whatever
`okf id next` reports at creation), `requires: [CAP-3, CAP-4, CAP-16]`, interfaces
`Keiro.Inspection.Aggregate` and `Keiro.Ops.Aggregate`, and evidence entries naming the test
groups; add `hydrateWithSource` to CAP-3's interface notes and `observeSnapshotRow` to CAP-4's;
add the `aggregates` hook to CAP-16; log each with `okf log add docs/capabilities …` and run
`just capabilities-validate`. Add `[Unreleased]` entries to the root `CHANGELOG.md`,
`keiro/CHANGELOG.md` (the additive `Keiro.Command` exports, `observeSnapshotRow`, the new
module, and, if Milestone 4 landed, the `kiroku-store` bound bump), and `keiro-ops/CHANGELOG.md`
(the hook, the `aggregate` domain, the additive `snapshot show` keys). Update IR-28 with an
"Implementation evidence" section citing this plan and the passing test names, advance its
`timestamp`, keep `status: proposed` until release evidence exists, and add a log entry with
`okf log add docs/improvement-requests --kind Implementation -m "…"`.

ADR distillation: allocate a handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`
and write `docs/adr/00NN-aggregate-inspection-reads-reuse-command-hydration-and-delegate-history.md`
with frontmatter matching `docs/adr/0039-foreground-timer-resume-uses-expiring-token-ownership.md`
(`type`, `title`, `description`, `timestamp`, `docId`, `status: Accepted`, `date`,
`originatingPlan: docs/plans/278-expose-aggregate-inspection-read-apis.md`). Its Decision
records that inspection reads rebuild aggregate state only through the command runner's own
hydration (`hydrateWithSource`) with telemetry and seed verification disabled; that the
application owns the display encoding and the snapshot codec is never an implicit display
format; that snapshot health is observed against the database clock and reports the ADR 3
discriminators individually; that aggregate listing delegates to a kiroku-owned stream-listing
primitive selected by category prefix and keiro issues no SQL against kiroku's schema; and
that keiro serves no event pages, delegating raw history to kiroku by reference. Add a
paragraph to ADR 28 naming the `aggregates` hook and the embedded-only `aggregate` domain,
advance ADR 28's `timestamp`, add the `docs/adr/log.md` entries, regenerate the index with
`okf index docs/adr --write` if the repository does so for ADRs (check how ADR-39 was added
with `git log --stat -1 -- docs/adr/0039-*`), and run the strict validation. Then run the full
gate in Concrete Steps and fill Outcomes & Retrospective.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro` inside the Nix development shell
(`nix develop -c …`) unless stated otherwise. PostgreSQL for tests is ephemeral and started by
the fixture; never point a test at a shared database.

Focused test runs while working (each prints Hspec output ending in a summary such as
`N examples, 0 failures`):

```bash
nix develop -c cabal test keiro-test --test-options='--match Keiro.Snapshot' --test-show-details=direct
nix develop -c cabal test keiro-test --test-options='--match Keiro.Inspection.Aggregate' --test-show-details=direct
nix develop -c cabal test keiro-test --test-options='--match Keiro.ReplayAudit' --test-show-details=direct
nix develop -c cabal test keiro-ops-test --test-show-details=direct
nix develop -c cabal test jitsurei-test --test-options='--match "Jitsurei aggregate inspection"' --test-show-details=direct
```

Benchmark check after Milestone 1 (the command path shares `hydrate`; the run must not report
a regression against the committed baseline):

```bash
nix develop -c cabal bench keiro-bench --benchmark-options="-p command --time-mode wall --baseline bench/baseline-command.csv --fail-if-slower 25"
```

Manual observation after Milestone 3, against the jitsurei database (see
`docs/guides/run-and-operate-jitsurei.md` for `just postgres-start` and the demo):

```bash
nix develop -c just jitsurei
nix develop -c cabal run jitsurei:exe:jitsurei-demo -- ops aggregate types --json
nix develop -c cabal run jitsurei:exe:jitsurei-demo -- ops aggregate show --name order --id 1001 --json
nix develop -c cabal run jitsurei:exe:jitsurei-demo -- ops aggregate snapshot --name order --id 1001 --json
```

Expected: the first prints `{"items":[{"name":"incident",…},{"name":"order",…}]}`, the second
an object whose `state_label` is one of the order states and whose `hydration.source` is
`snapshot` or `full_replay`, the third an object whose `status` is `present` or `absent`.
Substitute an order id the demo actually created (read `jitsurei/src/Jitsurei.hs` for the
sample ids) if `1001` does not exist.

Dependency lookups (before touching any kiroku or keiki API):

```bash
mori registry show shinzui/kiroku --full
mori registry show shinzui/keiki --full
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
curl -fsSL https://hackage.haskell.org/package/keiro/preferred.json
git ls-remote --tags origin 'keiro-0.1[6-9]*'
```

Milestone 4 verifies the already released API instead of requiring an old 0.10 series:

```bash
mori registry show shinzui/kiroku --full
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
rg 'kiroku-store' --glob '*.cabal' keiro keiro-core keiro-migrations keiro-ops
```

Retain the compatible current bound and verify the released signature; the 2026-10-13 proof used `kiroku-store` 0.11.0.0.

Documentation and bundle validation (Milestone 5 and whenever a bundle changes):

```bash
nix develop -c just user-documentation-validate
nix develop -c just capabilities-validate
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
okf id next docs/capabilities --profile docs/capabilities/profile.dhall CAP
okf id next docs/adr --profile docs/adr/profile.dhall ADR
nix develop -c just adr-validate
git diff --check
```

The full gate before declaring any milestone complete (each must exit zero; `just verify`
builds every package, runs every test suite, checks generated corpora and policies, and runs
the migration suite last):

```bash
nix fmt
nix develop -c just corpus-regen
nix develop -c just verify
nix flake check
```

Commits follow Conventional Commits and carry both trailers:

```text
ExecPlan: docs/plans/278-expose-aggregate-inspection-read-apis.md
Intention: intention_01m24m6m00ev59wa81shymsktd
```

Update the Progress checklist with a timestamp at every stopping point and add discoveries
with evidence as they occur.


## Validation and Acceptance

The concurrency test interleaves an append between the initial stream lookup and hydration and checks that displayed state is labelled with the hydrated version. Interleave snapshot advancement, deletion, and truncation too: report a raced/deleted observation or a typed hydration error, never invented initial state or a negative event distance. Database timestamps describe each observation and do not claim a transaction-wide snapshot.

Inspection is accepted only with measured interference bounds, not from the fact that an API is read-only. Capture a baseline at the pre-implementation commit with the same GHC optimization, RTS capabilities, database size, connection limits, PostgreSQL settings, and workload seed as the candidate. Run inside `nix develop`, with normal autovacuum and durable settings (`fsync`, `synchronous_commit`, and `full_page_writes` on); record settings and raw samples. Compare at least five alternating baseline/candidate runs after warm-up. At a fixed offered load below baseline saturation, a reproducible median throughput loss over 5%, p95 command/worker latency increase over 5%, or allocated bytes per completed operation increase over 5% blocks the milestone. No extra database statements, event reads, metadata serialization, or background tasks are allowed on ordinary commands or provenance-disabled reactions. An inconclusive/noisy comparison is not a pass: extend matched runs and report uncertainty. Keep the existing 25% historical benchmark check as a coarse smoke test only.

Measure four deployment modes separately: pre-change runtime; candidate with inspection not mounted and provenance off; mounted but idle; and active inspection with 1 and 32 distinct views, 1 and 256 clients, repeated HTTP polls, large values, and deliberately slow readers. Hold writer load fixed and include snapshot hit, no codec, snapshot miss/corruption fallback, long history, accepted/no-op/rejected/duplicate reactions, fan-out of 0/1/10/100 targets, timer scheduling/claim/firing, workflow resume, and projection application. Report query counts, rows examined, buffers, pool wait, CPU, allocation, WAL bytes, writer p50/p95/p99, completed operations, and post-major-GC live bytes. Idle mounting must issue no recurring database work without a subscriber or request. Reuse [ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)'s isolated retention legs; also run subscription churn and an idle-mounted notification storm, then assert driver/thread/queue counts return to their starting values. A positive live-heap trend that persists when repeating the steady-state run blocks release even if it is below the existing coarse retention threshold. Performance measurements remain implementation work; this review supplies no passing runtime evidence.


Acceptance 1 (IR-28, listing; Milestone 4): with three orders and two incidents in the
jitsurei test database, `listAggregates` for the `order` inspector with page size 2 returns two
items and a `next`, the second call returns the third item and no `next`, and the `incident`
inspector returns its two; each item carries the aggregate id, stream name, and stream version.
`keiro-ops aggregate list --name order --limit 2 --json` prints:

```json
{
  "name": "order",
  "category": "order",
  "items": [
    { "aggregate_id": "1001", "stream_name": "order-1001", "stream_version": 2, "created_at": "2026-09-10T03:20:11.412Z", "deleted_at": null, "truncate_before": 0 },
    { "aggregate_id": "1002", "stream_name": "order-1002", "stream_version": 1, "created_at": "2026-09-10T03:20:11.480Z", "deleted_at": null, "truncate_before": 0 }
  ],
  "skipped": 0,
  "next_cursor": "eyJraW5kIjoiYWdncmVnYXRlLWxpc3QiLCJhZnRlciI6Im9yZGVyLTEwMDIifQ"
}
```

and the `keiro-ops` test asserts the handler's `jsonValue` equals `aggregateListPageJson` of
the library read for the same state, which is what makes the eventual `GET /aggregate/list`
route serve the same page.

Acceptance 2 (fold equality): the test "state equals the command path's fold with and without
a snapshot" passes for every enumerated command sequence on both the snapshot-enabled and the
plain counter aggregate, comparing `inspectAggregate`'s `state` and `streamVersion` with
`hydrateFull`'s. `keiro-ops aggregate show --name order --id 1001 --json` prints an object of
this shape:

```json
{
  "name": "order",
  "category": "order",
  "aggregate_id": "1001",
  "stream_name": "order-1001",
  "stream_version": 3,
  "created_at": "2026-09-10T03:20:11.412Z",
  "deleted_at": null,
  "truncate_before": 0,
  "hydration": { "source": "snapshot", "snapshot_version": 2 },
  "state_label": "paid",
  "state": { "state": "paid" },
  "snapshot": {
    "status": "present",
    "observed_at": "2026-09-10T03:21:02.007Z",
    "configured": { "policy": "every:2", "state_codec_version": 1, "regfile_shape_hash": "…", "state_shape_hash": "…;fold=order-fold-v2" },
    "stored": { "stream_version": 2, "created_at": "…", "updated_at": "…", "age_seconds": 50.6, "events_since": 1, "state_codec_version": 1, "regfile_shape_hash": "…", "state_shape_hash": "…;fold=order-fold-v2", "compatibility": "compatible", "mismatched": [] }
  },
  "history": { "owner": "kiroku", "stream_name": "order-1001", "head_version": 3 }
}
```

A full-replay hydration renders `"hydration": {"source": "full_replay", "reason":
"no_state_codec"}`, `{"source": "full_replay", "reason": "snapshot_missed", "miss":
"not_found"}` (or `"no_stream"`, or `"decode_failed"` with a `"detail"` string), or
`{"source": "full_replay", "reason": "seeded_replay_failed", "error": "hydration_gap_detected",
"detail": "…"}`. A soft-deleted aggregate renders `"deleted_at"` set and `"hydration": null`,
`"state": null`, `"state_label": null`.

Acceptance 3 (snapshot metadata): `snapshotStatusFor` on an order with a snapshot reports
`stored.streamVersion == 2`, a non-negative `ageSeconds`, and `Compatible`; on one without,
`stored == Nothing`, and `keiro-ops aggregate snapshot --name order --id 1003 --json` prints:

```json
{ "name": "order", "aggregate_id": "1003", "stream_name": "order-1003", "stream_version": 1, "status": "absent", "observed_at": "2026-09-10T03:21:02.100Z", "configured": { "policy": "every:2", "state_codec_version": 1, "regfile_shape_hash": "…", "state_shape_hash": "…" }, "stored": null }
```

with exit code 0. `keiro-ops snapshot show --stream order-1001 --json` (standalone, no hook)
additionally prints `observed_at` and `age_seconds`.

Acceptance 4 (supported operations only): every new read is implemented with exported
operations of the owning library: `hydrateWithSource` and `hydrateFull` (`Keiro.Command`),
`observeSnapshotRow` (`Keiro.Snapshot.Schema`), `getStream` and `listStreams`
(`Kiroku.Store.Read`), and `streamInCategory` (`Keiro.ReplayAudit`). A reviewer confirms by
inspection that `keiro-ops/src/Keiro/Ops/Aggregate.hs` contains no SQL and that
`Keiro.Inspection.Aggregate` contains no Hasql statement and no import from
`Kiroku.Store.SQL`.

Acceptance 5 (no raw event pages): `keiro-ops aggregate --help` lists exactly `types`, `list`,
`show`, and `snapshot`; no command returns an array of events, and the view's `history` object
carries only the owner, the stream name, and the head version. The operations documentation
states that raw history is browsed through kiroku's surface.

Performance evidence to record in Surprises & Discoveries: `inspectAggregate` performs one
`getStream` (primary-key lookup by name), one hydration (the same cost as a command against
the aggregate: one snapshot primary-key read plus the tail of the stream in 256-event pages),
and one snapshot observation (one primary-key read plus `now()`); `snapshotStatusFor` performs
the first and third only; `listAggregates` performs one prefix-filtered, name-ordered read of
kiroku's `streams` table bounded by page size plus one and no hydration; `listAggregateTypes`
touches no database. The matched Milestone 1 benchmarks must satisfy the command-path interference gate; they cannot prove zero cost in every deployment.


## Idempotence and Recovery

Every read is a query and may be repeated freely; tests clone a fresh database per example.
No migration is added. The `Keiro.Command` refactor keeps `hydrate`'s signature and behavior;
if the benchmark or any command test regresses, fix specialization of the shared worker; never hide the cost by loosening the threshold or keeping two replay implementations.

Cursor pagination is observational: a page reflects the streams that exist at the time of
that query, a cursor means "strictly after this stream name", and a client that changes the
aggregate name restarts without a cursor. Aggregates created between pages appear in later
pages when their names sort after the cursor and are otherwise missed until the next
traversal; this is documented, not fixed.

If the kiroku release for Milestone 4 is delayed, Milestones 1 through 3 and 5 complete and
ship on their own; `aggregate list` stays absent from the parser, the `List` constructor is not
added, and IR-28 records item 1a as pending with the kiroku plan reference. Never commit a
`cabal.project.local` overlay or a `source-repository-package` pointing at a local checkout.

If `just verify` fails because of concurrent Cabal builds sharing a workspace (recorded in
plan 270), rerun the failing step serially or with a private `--builddir` before treating the
failure as evidence.


## Interfaces and Dependencies

All new keiro definitions use the repository's strict records with `Generic`, `Eq`, and `Show`
deriving where the fields allow it, `OverloadedLabels` access, and the existing `Store`
effect. `Eff es` computations propagate store failures exactly as the surrounding module does.
No package gains a web dependency. Milestone 4 adds `base64-bytestring >=1.2 && <1.3` to
`keiro/keiro.cabal` only if plan 275 has not already added it.

`Keiro.Command` (additive exports, Milestone 1):

```haskell
data HydrationSource
  = FromSnapshot !StreamVersion
  | FullReplay !FullReplayReason
  deriving stock (Eq, Show, Generic)

data FullReplayReason
  = NoStateCodec
  | SnapshotMissed !SnapshotMissReason
  | SeededReplayFailed !CommandError
  deriving stock (Eq, Show, Generic)

hydrateWithSource ::
  (HasCallStack, IOE :> es, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  Eff es (Either CommandError (Hydrated rs s, HydrationSource))

-- defaultRunCommandOptions with seedVerifySampleRate = 0, metrics = Nothing,
-- tracer = Nothing, verifyReplayOnAppend = False
inspectionRunCommandOptions :: RunCommandOptions
```

`Keiro.Snapshot.Schema` (additive exports, Milestone 1):

```haskell
data SnapshotObservation = SnapshotObservation
  { row :: !(Maybe SnapshotRow),
    observedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

observeSnapshotRow :: (Store :> es) => StreamId -> Eff es SnapshotObservation
```

`Keiro.Inspection.Aggregate` (new, exposed; Milestones 2 and 4):

```haskell
data AggregateInspector phi rs s ci co = AggregateInspector
  { name :: !Text,
    eventStream :: !(ValidatedEventStream phi rs s ci co),
    category :: !(StreamCategory (EventStream phi rs s ci co)),
    mkStream :: !(StreamName -> Maybe (Stream (EventStream phi rs s ci co))),
    displayState :: !(s -> RegFile rs -> Value),
    stateLabel :: !(s -> Text)
  }
  deriving stock (Generic)

aggregateInspector ::
  (Show s) =>
  Text ->
  ValidatedEventStream phi rs s ci co ->
  StreamCategory (EventStream phi rs s ci co) ->
  (s -> RegFile rs -> Value) ->
  AggregateInspector phi rs s ci co

inspectorFromAuditTarget ::
  (Show s) =>
  Text ->
  AuditTarget phi rs s ci co ->
  (s -> RegFile rs -> Value) ->
  Either CategoryError (AggregateInspector phi rs s ci co)

displayViaStateCodec :: StateCodec (s, RegFile rs) -> s -> RegFile rs -> Value

data SomeAggregateInspector where
  SomeAggregateInspector ::
    (BoolAlg phi (RegFile rs, ci), Eq co) =>
    AggregateInspector phi rs s ci co ->
    SomeAggregateInspector

type AggregateInspectors = Map Text SomeAggregateInspector

aggregateInspectors :: [SomeAggregateInspector] -> Either Text AggregateInspectors
inspectorName :: SomeAggregateInspector -> Text

data AggregateTypeSummary = AggregateTypeSummary
  { name :: !Text, category :: !Text, snapshotsConfigured :: !Bool, snapshotPolicy :: !Text }
  deriving stock (Eq, Show, Generic)

listAggregateTypes :: AggregateInspectors -> [AggregateTypeSummary]

data AggregateInspectionError
  = AggregateNotFound !StreamName
  | AggregateIdRejected !Text
  | AggregateHydrationFailed !StreamName !CommandError
  | InvalidPageSize !Int
  | InvalidCursor !CursorError
  deriving stock (Eq, Show, Generic)

aggregateStream :: AggregateInspector phi rs s ci co -> Text -> Either AggregateInspectionError (Stream (EventStream phi rs s ci co))
aggregateIdOf :: AggregateInspector phi rs s ci co -> StreamName -> Maybe Text

data SnapshotCompatibility = Compatible | Incompatible ![Text] | Unused
  deriving stock (Eq, Show, Generic)

data SnapshotConfig = SnapshotConfig
  { policy :: !Text, stateCodecVersion :: !Int, regfileShapeHash :: !Text, stateShapeHash :: !Text }
  deriving stock (Eq, Show, Generic)

data StoredSnapshot = StoredSnapshot
  { aheadOfObservedHead :: !Bool, streamVersion :: !StreamVersion, createdAt :: !UTCTime, updatedAt :: !UTCTime,
    ageSeconds :: !Double, eventsSince :: !Int64,
    stateCodecVersion :: !Int, regfileShapeHash :: !Text, stateShapeHash :: !Text,
    compatibility :: !SnapshotCompatibility }
  deriving stock (Eq, Show, Generic)

data SnapshotStatus = SnapshotStatus
  { observedAt :: !UTCTime, configured :: !(Maybe SnapshotConfig), stored :: !(Maybe StoredSnapshot) }
  deriving stock (Eq, Show, Generic)

data HistoryReference = HistoryReference
  { owner :: !Text, streamName :: !StreamName, headVersion :: !StreamVersion }
  deriving stock (Eq, Show, Generic)

data AggregateView = AggregateView
  { name :: !Text, category :: !Text, aggregateId :: !Text, streamName :: !StreamName,
    streamVersion :: !StreamVersion, createdAt :: !UTCTime, deletedAt :: !(Maybe UTCTime),
    truncateBefore :: !StreamVersion,
    hydration :: !(Maybe HydrationSource),
    stateLabel :: !(Maybe Text), state :: !(Maybe Value),
    snapshot :: !SnapshotStatus, history :: !HistoryReference }
  deriving stock (Eq, Show, Generic)

inspectAggregate ::
  (IOE :> es, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  AggregateInspector phi rs s ci co -> Text -> Eff es (Either AggregateInspectionError AggregateView)

snapshotStatusFor ::
  (Store :> es) =>
  AggregateInspector phi rs s ci co -> Text -> Eff es (Either AggregateInspectionError (StreamName, StreamVersion, SnapshotStatus))

-- Milestone 4
data AggregateListRequest = AggregateListRequest { pageSize :: !Int, after :: !(Maybe InspectionCursor) }
  deriving stock (Eq, Show, Generic)

data AggregateSummary = AggregateSummary
  { aggregateId :: !Text, streamName :: !StreamName, streamVersion :: !StreamVersion,
    createdAt :: !UTCTime, deletedAt :: !(Maybe UTCTime), truncateBefore :: !StreamVersion }
  deriving stock (Eq, Show, Generic)

data AggregateListPage = AggregateListPage
  { name :: !Text, category :: !Text, items :: ![AggregateSummary], skipped :: !Int, next :: !(Maybe InspectionCursor) }
  deriving stock (Eq, Show, Generic)

maxAggregatePageSize :: Int   -- 500
aggregateListCursorKind :: Text   -- "aggregate-list"

listAggregates ::
  (Store :> es) =>
  AggregateInspector phi rs s ci co -> AggregateListRequest -> Eff es (Either AggregateInspectionError AggregateListPage)

-- JSON rendering (snake_case, the shapes in Validation and Acceptance)
aggregateTypeJson :: AggregateTypeSummary -> Value
hydrationSourceJson :: HydrationSource -> Value
snapshotStatusJson :: SnapshotStatus -> Value
aggregateViewJson :: AggregateView -> Value
aggregateSummaryJson :: AggregateSummary -> Value
aggregateListPageJson :: AggregateListPage -> Value
inspectionErrorText :: AggregateInspectionError -> Text
```

`Keiro.Inspection.Cursor` (owned by plan 275; imported after plan 275 completes, with this interface):

```haskell
newtype InspectionCursor = InspectionCursor { cursorText :: Text }
  deriving stock (Eq, Show, Generic)

data CursorError
  = MalformedCursor !Text
  | CursorKindMismatch !Text !Text
  deriving stock (Eq, Show, Generic)

encodeCursor :: (ToJSON payload) => Text -> payload -> InspectionCursor
decodeCursor :: (FromJSON payload) => Text -> InspectionCursor -> Either CursorError payload
```

`Keiro.Ops.Embed` (additive) and `Keiro.Ops.Aggregate` (new, exposed):

```haskell
data AppHooks = AppHooks
  { workflowResume :: !(Maybe ResumeHook),
    timerFire :: !(Maybe TimerFire),
    replayAudit :: !(Maybe OpsAuditConfig),
    projectionCatalog :: !(Maybe ProjectionCatalogOperations),
    aggregates :: !(Maybe AggregateInspectors)
  }

-- Keiro.Ops.Aggregate
data ShowOptions = ShowOptions { name :: !Text, aggregateId :: !Text }
data ListOptions = ListOptions { name :: !Text, limit :: !Int, after :: !(Maybe Text) }   -- Milestone 4
data Command = Types | Show !ShowOptions | Snapshot !ShowOptions | List !ListOptions    -- List from Milestone 4
commandParser :: Parser Command
isMutation :: Command -> Bool          -- always False
runCommand :: OpsEnv -> AggregateInspectors -> Command -> IO OpsOutcome
```

Kiroku (Milestone 4, consumed, not written here): `Kiroku.Store.Read.listStreams :: (HasCallStack, Store :> es) => Maybe CategoryName -> Maybe Text -> Maybe StreamName -> BrowsePageSize -> Eff es (Vector StreamInfo)`
from released `kiroku-store` 0.11.0.0, with `StreamInfo { id, name, version, createdAt, deletedAt,
truncateBefore }` unchanged from 0.9.0.1. Verify the exact export against the released package
before use.

`jitsurei` (Milestone 3): `Jitsurei.Inspection.jitsureiAggregateInspectors :: AggregateInspectors`
covering `order` (over `snapshotOrderEventStream`, category `order`) and `incident` (over
`incidentEventStream`, category `incident`), mounted as `aggregates = Just
jitsureiAggregateInspectors` in `jitsurei/app/Main.hs`.


## Revision notes

2026-09-30: Adopted as EP-3 of
[MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md)
and brought into agreement with its Integration Points. The `master_plan` frontmatter field was
added; the sibling-plans paragraph became a "Coordination under MasterPlan 45" subsection
naming the seven children, the `hydrateWithSource` hand-off to plan 274 (whichever lands first
creates the primitive to this plan's interface), the `cursorReader` and `aggregate-list`
registration under plan 275's codec, hook coexistence with plan 274's `processManagers`, and
the reserved domain words. Every statement that kiroku's `listStreams` arrives in
`kiroku-store` 0.9.0.0 was corrected to 0.10.0.0, because 0.9.0.1 shipped without it and
kiroku's MasterPlan 13 (created 2026-09-30) releases it as 0.10.0.0; the Milestone 0
preflight, Milestone 4 gate, Concrete Steps gate commands, the Context bound paragraph, and
the Interfaces sentence now say so, and the bound bump is done once by whichever of this
plan's Milestone 4 and plan 274's Milestone 5 runs first. The working-tree and Hackage version
facts were refreshed to 0.19.0.0, ADR-40 is cited as the existing stance ADR, and the CAP-20
and ADR handles are stated as `okf id next` expectations rather than reservations. Five dated
Decision Log entries record these changes; no earlier entry was rewritten.

2026-10-13: Applied the correctness and hot-path review. Added explicit performance acceptance and ownership, refreshed released dependency facts, and corrected the affected implementation and wire contracts. Earlier dated decisions remain historical; the current milestones and review constraints govern implementation. No runtime changes or benchmark results are claimed.
