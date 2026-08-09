---
id: 214
slug: adopt-kiroku-s-durable-subscription-checkpoint-inventory
title: "Adopt Kiroku's durable subscription checkpoint inventory"
kind: exec-plan
created_at: 2026-08-09T14:58:56Z
intention: "intention_01kzagac32ehp93amx1sfar2ab"
master_plan: "docs/masterplans/31-build-the-keiro-ops-operational-cli.md"
---

# Adopt Kiroku's durable subscription checkpoint inventory

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku 0.4.0.0 now publishes the durable subscription checkpoint inventory that Keiro's
operational CLI previously had to defer. After this plan is implemented, an operator can run
`keiro-ops stream subscriptions` to list every persisted subscription/member checkpoint,
including rows whose workers are no longer running, and can run
`keiro-ops projection position --subscription NAME` to inspect one subscription's member-aware
floor. Both commands show the store position captured by the same Kiroku statement and an
explicitly named `global_position_distance`; neither calls that subtraction an event count or a
source-specific lag.

Keiro's library-level consistency and projection-observation helpers will also stop reading the
Kiroku-owned `subscriptions` table to obtain checkpoint positions. They will consume
`subscriptionCheckpointInventory` from the released
`mori://shinzui/kiroku/packages/kiroku-store` package instead. The outcome is visible through the
new CLI commands, focused library tests that retain consumer-group member semantics, and a source
audit showing that the removed private checkpoint `SELECT` did not reappear elsewhere.


## Progress

- [ ] Milestone 1: admit `kiroku-store` 0.4.0.0 throughout the workspace and replace the
  production checkpoint-position read with the public inventory.
- [ ] Milestone 2: add durable `stream subscriptions` and member-aware `projection position`
  commands with stable human and JSON output.
- [ ] Milestone 3: cover the library and CLI behavior, correct position-distance terminology,
  update the owning ADR and user documentation, and remove the obsolete known limitation.
- [ ] Milestone 4: pass focused and repository-wide validation, update the parent MasterPlan,
  perform ADR distillation, and record the final outcomes.


## Surprises & Discoveries

- Kiroku's public `SubscriptionCheckpointInventory` captures the global store position and all
  persisted rows in one statement snapshot. Rows are already sorted by subscription name and
  numeric member, and a missing subscription produces no row rather than a synthetic position
  zero. The contract was released as `kiroku-store` 0.4.0.0 under
  `mori://shinzui/kiroku/plans/69-expose-a-performant-durable-subscription-checkpoint-inventory`;
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2` is complete.
- The workspace currently rejects Kiroku 0.4 in seven Cabal files:
  `keiro/keiro.cabal`, `keiro-core/keiro-core.cabal`,
  `keiro-test-support/keiro-test-support.cabal`,
  `keiro-migrations/keiro-migrations.cabal`, `keiro-ops/keiro-ops.cabal`,
  `jitsurei/jitsurei.cabal`, and `keiro-dsl/keiro-dsl.cabal`. A source search found no
  exhaustive custom interpreter of Kiroku's exported `Store` GADT, so the 0.4 adoption should
  require bounds and call-site changes rather than a new constructor case in Keiro.
- `Keiro.ReadModel.readSubscriptionPosition` currently executes a direct
  `SELECT min(last_seen) FROM subscriptions`, and `Keiro.Projection.recordProjectionLag` calls it
  separately from `storeHeadPosition`. The inventory can preserve the minimum-across-members
  behavior while observing the checkpoint rows and global head together when both are needed.
- Kiroku 0.4 exposes efficient forward category reads but no constant-cost category-head
  operation. Scanning a category from position zero merely to calculate an operator value would
  be unbounded work, while reusing Keiro's private category-head SQL would violate
  [ADR 28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md).
  The new CLI therefore reports global position distance and does not mount a command named
  `lag`. A later true category/relevant-event lag needs an owning-library frontier API and the
  source identity supplied by the projection catalog.
- Keiro's rebuild code also contains checkpoint-reset writes. The released inventory is
  read-only and cannot replace those transactional mutations. This plan removes the private
  checkpoint read used by consistency, metrics, and operator reporting; it must not pretend that
  a read API authorizes rewriting the existing reset path. If implementation expands to that
  mutation boundary, it first needs a separate supported Kiroku API and an explicit plan update.
- Immediately after the generator created this file, `mori path
  mori://shinzui/keiro/plans/214-adopt-kiroku-s-durable-subscription-checkpoint-inventory`
  reported that the artifact was not found. The repository-local plan exists and its generated
  id/slug define the intended canonical URI; registry observation lag is not a reason to replace
  it with a cross-repository bare path.


## Decision Log

- Decision: Require `kiroku-store >=0.4 && <0.5` in every workspace stanza that currently pins
  `>=0.3 && <0.4`.
  Rationale: 0.4.0.0 is the first authoritative Hackage release carrying the public inventory,
  and the `<0.5` upper bound preserves the repository's current major-series compatibility
  policy. Unbounded fixture dependencies already admit 0.4 and need no cosmetic rewrite.
  Date: 2026-08-09

- Decision: Preserve `readSubscriptionPosition :: Text -> Eff es (Maybe GlobalPosition)` as a
  compatibility surface, but implement it by filtering one public Kiroku inventory and taking
  the minimum checkpoint across every matching member.
  Rationale: Existing Strong/PositionWait behavior intentionally treats the slowest consumer-
  group member as the subscription position. Retaining the signature avoids unrelated consumer
  churn while removing the Kiroku-table read from production Keiro code.
  Date: 2026-08-09

- Decision: Expose every durable member row and derive a separate minimum only where Keiro needs
  a subscription-wide floor; never infer topology from member zero.
  Rationale: Kiroku cannot distinguish a non-group subscription from member zero of a group, and
  collapsing rows at the CLI boundary would discard the operational fact operators requested.
  Date: 2026-08-09

- Decision: Name the derived subtraction `global_position_distance`, not `lag`, `backlog`, or
  `events_behind`.
  Rationale: A global position is an opaque monotonic cursor. Filtered, category, hard-deleted,
  and sharded histories can skip positions, so subtraction does not count relevant events. An
  actual source-specific lag must select a compatible head: the captured store head for an
  all-stream position distance, or a supported category/relevant frontier for category sources.
  Date: 2026-08-09

- Decision: Add `keiro.projection.global_position_distance` as the preferred gauge and keep the
  historical `keiro.projection.lag`/`recordProjectionLag` path as a deprecated compatibility
  alias for one release series, with both descriptions corrected to position units.
  Rationale: Operators need a truthful new name without an abrupt dashboard break. Both gauges
  can be recorded from the same inventory value during migration; neither should claim an event
  count.
  Date: 2026-08-09

- Decision: Mount durable inventory in the standalone database-only command tree, but do not use
  the optional application projection catalog to manufacture a lag command in this plan.
  Rationale: Reading Kiroku's durable facts requires only the existing `OpsEnv.store`. The catalog
  can identify all-stream versus category sources, but Kiroku does not yet export the category
  frontier needed for an efficient true category lag. Omitting the stronger claim keeps the
  standalone and embedded surfaces consistent.
  Date: 2026-08-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is child plan EP-5 of
`docs/masterplans/31-build-the-keiro-ops-operational-cli.md`. Plan 207
(`docs/plans/207-add-the-messaging-and-read-side-command-domains-to-keiro-ops.md`)
implemented every independent database-only domain but removed its first subscription command
after discovering that `subscriptionStates` was process-local and that the projection position
path queried a Kiroku-owned table. This plan owns only that deferred adoption slice. It builds on
the existing `keiro-ops` package and does not change its connection, schema-check, preview, or
application-hook architecture.

A subscription checkpoint is the greatest Kiroku global position durably acknowledged for one
subscription name and consumer-group member. A global position is a monotonic cursor in Kiroku's
global log; it is not a dense count of events relevant to every consumer. Kiroku's released
`SubscriptionCheckpoint` carries `subscriptionName`, `consumerGroupMember`,
`checkpointPosition`, and `checkpointUpdatedAt`. `SubscriptionCheckpointInventory` carries the
same-statement `storePosition` and a strict vector named `checkpoints`. The supported operation is
`Kiroku.Store.Subscription.subscriptionCheckpointInventory`. These types and the operation are
published in `mori://shinzui/kiroku/packages/kiroku-store` version 0.4.0.0. The owning design and
completed request are, respectively,
`mori://shinzui/kiroku/plans/69-expose-a-performant-durable-subscription-checkpoint-inventory` and
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2`.

The current Keiro library path is `keiro/src/Keiro/ReadModel.hs`.
`readSubscriptionPosition` performs a direct `subscriptions` query and takes `min(last_seen)` so
a consumer group is only as caught up as its slowest persisted member. `waitFor` polls that helper;
`Strong` chooses either `storeHeadPosition` or `categoryHeadPosition`. The latter is a separate
legacy category-frontier query and is not an excuse for an operator command to cross Kiroku's
schema boundary. `keiro/src/Keiro/Projection.hs` implements `recordProjectionLag` by reading the
global head and subscription checkpoint separately and currently describes their subtraction as
an event count. `keiro/src/Keiro/Telemetry.hs` owns the associated instrument.

The operational command root is `keiro-ops/src/Keiro/Ops.hs`. It creates an `OpsEnv` from one
`KirokuStore` and delegates to modules by domain. `keiro-ops/src/Keiro/Ops/Stream.hs` already owns
Kiroku stream inspection/lifecycle commands. `keiro-ops/src/Keiro/Ops/Projection.hs` currently
owns only projection-dedup pruning. Both modules execute `Store` effects with `runStoreIO` and
render one `OpsResult` as either aligned human rows or JSON. `keiro-ops/test/Main.hs` contains
ephemeral PostgreSQL handler tests and pure parser tests for the shared standalone/embedded command
tree.

The dependency floor appears in seven Cabal files named in Surprises & Discoveries. Update every
bounded stanza, not merely the `keiro-ops` library stanza, so `cabal build all` cannot select a
mixture that rejects 0.4. `keiro-store-migrations` remains at 0.3 because Kiroku 0.4 adds no schema
migration and that package has an independent version line.

Two local ADRs govern the work. [ADR 28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
requires every operator command to call the exported API of the library that owns the state and
forbids Kiroku-table SQL in Keiro's console. Update it during implementation to record the now-
available durable inventory and the position-distance naming rule.
[ADR 26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
defines separate subscription and source identities and distinguishes `AllStreams` from
`CategorySource`; that distinction explains why one store-wide subtraction is not a universal
projection lag. No additional ADR was relevant at authoring time.


## Plan of Work

### Milestone 1: adopt the released dependency and public read contract

Change every bounded `kiroku-store` dependency in the seven Cabal files named above from
`>=0.3 && <0.4` to `>=0.4 && <0.5`. Preserve independent `kiroku-store-migrations ^>=0.3.0.0`
bounds. Run the source audit in Concrete Steps before editing and again afterward so newly added
or differently formatted stanzas are not missed.

In `keiro/src/Keiro/ReadModel.hs`, import `subscriptionCheckpointInventory` and the public
inventory types. Add a pure `subscriptionPositionFromInventory` helper that filters by exact
`SubscriptionName` and returns the minimum `checkpointPosition` over all matching rows, or
`Nothing` when no durable row exists. Preserve `readSubscriptionPosition`'s current public
signature and implement it as one inventory call followed by this helper. Remove
`lookupSubscriptionPositionStmt`; no production `SELECT` of Kiroku's `subscriptions` table should
remain on this path. Implement `storeHeadPosition` from the inventory's captured `storePosition`
so empty and hard-deleted histories use Kiroku's authoritative global frontier rather than the
latest decodable event.

In `keiro/src/Keiro/Projection.hs`, add
`recordProjectionGlobalPositionDistance`. It must call `subscriptionCheckpointInventory` once,
derive the named subscription's member floor from that same value, clamp
`storePosition - checkpointPosition` at zero, and use position zero only for the historical
missing-row metric behavior. Keep `recordProjectionLag` as a deprecated alias during the 0.11
series. In `keiro/src/Keiro/Telemetry.hs`, add the preferred
`keiro.projection.global_position_distance` gauge with unit `{position}` and record both the new
and legacy gauge during the compatibility interval. Correct the legacy instrument description to
say that its value is a global position distance, not an event count.

This milestone is complete when `keiro` builds against Kiroku 0.4, the focused ReadModel and
projection telemetry tests pass, and `rg` finds no production checkpoint-position `SELECT` in
`Keiro.ReadModel`. Do not change the rebuild reset statements: the inventory is read-only and
cannot replace their transaction semantics.

### Milestone 2: expose the durable operator views

Extend `Keiro.Ops.Stream.Command` in `keiro-ops/src/Keiro/Ops/Stream.hs` with a read-only
`Subscriptions` constructor mounted as `stream subscriptions`. Its handler calls the public
inventory exactly once. Human output uses the columns `subscription`, `member`,
`checkpoint_position`, `checkpoint_updated_at`, `store_position`, and
`global_position_distance`. JSON has the stable shape shown in Concrete Steps. Preserve Kiroku's
name/member order and return an empty `checkpoints` array with the captured store position when no
checkpoint exists.

Extend `Keiro.Ops.Projection.Command` in `keiro-ops/src/Keiro/Ops/Projection.hs` with
`Position Text`, parsed as `projection position --subscription NAME`. Filter the same public
inventory by exact name and return every matching member plus a summary containing
`minimum_checkpoint_position` and `maximum_global_position_distance`. Both summary fields are
`null` when the subscription has no persisted row; do not manufacture member zero or checkpoint
zero in CLI output. The command is read-only under `isMutation`, works in both standalone and
embedded command trees without a new `AppHooks` field, and does not add a `lag` parser.

Factor only small pure row/JSON helpers as needed. Do not add Hasql, a table name, a category scan,
or a second inventory call to either handler. This milestone is complete when parser tests mount
both commands in the standalone tree and handler tests prove durable empty, multi-name,
multi-member, and stopped-worker-visible output.

### Milestone 3: lock down semantics and documentation

Extend `keiro/test/Main.hs` around the existing `Keiro.ReadModel` and projection metrics examples.
Retain the test proving that a two-member subscription resolves to the minimum checkpoint. Add an
empty-inventory case, a case where the captured global head remains authoritative, and metric
coverage proving that the new and compatibility gauges receive the same non-negative position
distance. Test fixtures may seed checkpoints with the existing test-only statements, but all
production reads and assertions must flow through the public Kiroku inventory path.

Extend `keiro-ops/test/Main.hs` with parser and database-backed handler cases. Seed at least two
subscription names and two members in an order different from the expected output; prove stable
name/member ordering, exact timestamps/positions, the group floor, and no topology inference from
member zero. Cancel or omit any worker after its checkpoint is persisted and prove the durable row
still appears. Also prove that a missing name returns empty members and `null` summaries rather
than a fake zero row.

Update `docs/user/operations.md` with copyable human and JSON invocations, remove the deferred-API
paragraph, and explain `global_position_distance`. Update `docs/user/api-reference.md`,
`docs/research/opentelemetry-semconv-audit.md`, `keiro/CHANGELOG.md`,
`keiro-ops/CHANGELOG.md`, and the changelogs for any other publishable package whose bound changes.
Search the repository for the old claims “events between,” “projection lag by subscription
last_seen,” and the IR-2 limitation and correct every active user-facing occurrence. Update ADR 28
with the durable inventory boundary and run `just adr-validate`; update the research bundle log as
required by its profile and run `just research-validate`.

This milestone is complete when the commands and metrics are documented without calling position
distance an event count, the Kiroku IR is cited canonically as completed, and the focused library
and ops suites pass.

### Milestone 4: integrate and close the operational initiative

Run the full validation in Concrete Steps. Inspect all formatting changes and record exact suite
counts in Progress and Outcomes rather than copying the historical counts from plan 207. Update
`docs/masterplans/31-build-the-keiro-ops-operational-cli.md` to mark EP-5 complete and the
initiative complete. Plan 207 remains the historical record of the independent domains; do not
rewrite it to imply that its 2026-08-08 implementation already contained the later Kiroku API.

Perform the required ADR distillation pass. ADR 28 should already contain the durable naming and
ownership rule; create no additional ADR unless implementation discovers a new project-level
decision. Finish Outcomes & Retrospective with the command transcript, dependency version, tests,
and any remaining limitation around category/relevant-event frontiers.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/keiro`.

Before editing, re-resolve the dependency and verify the published version instead of relying on
the registry snapshot:

```bash
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
git ls-remote --tags https://github.com/shinzui/kiroku.git
rg -n 'kiroku-store\s+.*<0\.4' --glob '*.cabal' .
rg -n 'readSubscriptionPosition|FROM subscriptions|UPDATE subscriptions' keiro/src keiro-ops/src
```

The release check should include `0.4.0.0` and tag `kiroku-store-v0.4.0.0`. If a newer 0.4 patch
exists, keep the lower bound at the first compatible release, 0.4.0.0; if 0.5 or a later major is
current, inspect its changelog/source before widening the `<0.5` upper bound.

After Milestone 1, format and run focused library tests:

```bash
nix fmt
cabal build keiro keiro-ops
cabal test keiro-test --test-options='--match Keiro.ReadModel'
cabal test keiro-test --test-options='--match projection lag'
rg -n 'SELECT min\(last_seen\)|lookupSubscriptionPositionStmt' keiro/src
```

The final `rg` command is expected to print nothing. Checkpoint reset `UPDATE` statements in the
rebuild modules are expected and are not silently deleted by this read-only adoption.

Exercise the new CLI handlers against the test database through the focused suite. The exact Hspec
description can be adjusted to the implemented group name, but keep one shared substring:

```bash
cabal test keiro-ops-test --test-options='--match durable checkpoint inventory'
```

The human command should produce rows shaped like:

```text
subscription  member  checkpoint_position  checkpoint_updated_at       store_position  global_position_distance
orders        0       35                   2026-08-09T14:00:00Z         42              7
orders        1       40                   2026-08-09T14:01:00Z         42              2
```

The stable JSON shape for `stream subscriptions --json` is:

```json
{
  "store_position": 42,
  "checkpoints": [
    {
      "subscription": "orders",
      "member": 0,
      "checkpoint_position": 35,
      "checkpoint_updated_at": "2026-08-09T14:00:00Z",
      "global_position_distance": 7
    }
  ]
}
```

`projection position --subscription orders --json` uses the same member objects and adds
`minimum_checkpoint_position: 35` and `maximum_global_position_distance: 7`. Exact timestamps and
positions come from the fixture; the example only defines field names.

After documentation and ADR edits, run the profile and repository gates:

```bash
just adr-validate
just research-validate
cabal build all
cabal test keiro-test
cabal test keiro-ops-test
just verify
git diff --check
git status --short
```

Commit coherent milestones with Conventional Commits and all active trailers. For example:

```text
feat(ops): expose durable subscription checkpoint positions

MasterPlan: docs/masterplans/31-build-the-keiro-ops-operational-cli.md
ExecPlan: docs/plans/214-adopt-kiroku-s-durable-subscription-checkpoint-inventory.md
Intention: intention_01kzagac32ehp93amx1sfar2ab
```


## Validation and Acceptance

The implementation is accepted when all of the following are observable:

1. The complete workspace resolves against released `kiroku-store` 0.4.x without `allow-newer`,
   and every formerly `<0.4` Cabal stanza now admits `0.4.0.0` while retaining `<0.5`.
2. `readSubscriptionPosition` returns `Nothing` when no persisted row exists, the exact row
   position for one member, and the minimum for several members, without production SQL against
   Kiroku's `subscriptions` table.
3. One inventory snapshot supplies both the global store position and checkpoint used by
   `recordProjectionGlobalPositionDistance`; the preferred and compatibility gauges receive the
   same clamped value and describe it in position units rather than events.
4. `keiro-ops stream subscriptions` lists every persisted row in name/member order, retains rows
   after workers stop, preserves exact member/checkpoint/timestamp values, and emits the same facts
   through human and JSON rendering.
5. `keiro-ops projection position --subscription NAME` returns every matching member plus the
   minimum checkpoint and maximum global position distance. A missing name has empty members and
   null summaries. Member zero is never labeled “non-group.”
6. No CLI command named `lag` is mounted, no handler scans category history, and docs explain that
   filtered/category/sharded relevant-event lag needs a compatible source head and definition.
7. ADR 28, user docs, API reference, metric audit, and changelogs describe the supported Kiroku
   boundary and no active text still says the subtraction counts events.
8. Focused tests, `cabal build all`, both complete affected suites, `just verify`, ADR/research
   validation, and `git diff --check` all pass; the parent MasterPlan records EP-5 and the overall
   initiative as complete.


## Idempotence and Recovery

All inventory reads and CLI commands in this plan are read-only. Re-running focused tests and
`just verify` uses the repository's ephemeral PostgreSQL fixtures and is safe. Cabal bound edits
are mechanical but must be audited with `rg` before and after so a failed partial edit cannot leave
an incompatible stanza.

If Kiroku 0.4 exposes a compile-time incompatibility not found by the initial `Store` interpreter
search, keep the upper bound closed, record the exact constructor/call-site failure in Surprises &
Discoveries, and adapt that caller before proceeding. Do not use `allow-newer` as acceptance.

If the CLI output shape changes during implementation, update human and JSON tests, user docs, and
the Interfaces section together before committing. Do not publish two meanings under the same
JSON field. If true category lag becomes feasible because Kiroku releases a frontier API during
implementation, treat that as a plan revision: verify the new release and bounds, define the source
mapping and performance contract, and update the Decision Log rather than quietly adding a scan.

The deprecated metric is a migration rail. If dual recording proves impossible in the current
`KeiroMetrics` structure, preserve the legacy instrument, add the truthfully named instrument in a
separate compatible field, and document the exact transition. Never silently redefine the numeric
value as an event count.


## Interfaces and Dependencies

The only new external API dependency is `mori://shinzui/kiroku/packages/kiroku-store` version
0.4.0.0 or a compatible 0.4 patch. Use these released types and function; do not copy them into
Keiro:

```haskell
data SubscriptionCheckpoint = SubscriptionCheckpoint
  { subscriptionName :: !SubscriptionName
  , consumerGroupMember :: !Int32
  , checkpointPosition :: !GlobalPosition
  , checkpointUpdatedAt :: !UTCTime
  }

data SubscriptionCheckpointInventory = SubscriptionCheckpointInventory
  { storePosition :: !GlobalPosition
  , checkpoints :: !(Vector SubscriptionCheckpoint)
  }

subscriptionCheckpointInventory ::
  (HasCallStack, Store :> es) =>
  Eff es SubscriptionCheckpointInventory
```

`keiro/src/Keiro/ReadModel.hs` retains its existing effectful helper and adds the pure derivation:

```haskell
subscriptionPositionFromInventory ::
  SubscriptionName ->
  SubscriptionCheckpointInventory ->
  Maybe GlobalPosition

readSubscriptionPosition ::
  Store :> es =>
  Text ->
  Eff es (Maybe GlobalPosition)
```

`keiro/src/Keiro/Projection.hs` adds the preferred observation name while preserving the old
entry point for a documented compatibility interval:

```haskell
recordProjectionGlobalPositionDistance ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  AsyncProjection ->
  Eff es ()

{-# DEPRECATED recordProjectionLag "Use recordProjectionGlobalPositionDistance; the value is a global position distance, not an event count." #-}
```

`keiro-ops/src/Keiro/Ops/Stream.hs` adds `Subscriptions` to `Command`.
`keiro-ops/src/Keiro/Ops/Projection.hs` adds `Position !Text` to `Command`. Both remain read-only,
accept only `OpsEnv`, call `runStoreIO env.store`, and return `OpsOutcome` through the existing
rendering layer. No `OpsEnv` or `AppHooks` field changes.

The existing `CategoryHead Text` compatibility helper and rebuild checkpoint reset mutations are
not interfaces supplied by the new inventory. This plan must not route the CLI through either one
or remove transactional reset behavior under cover of a read-only dependency upgrade.
