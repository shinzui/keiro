---
id: 329
slug: expose-keiki-register-values-through-the-existing-inspection-apis
title: "Expose Keiki register values through the existing inspection APIs"
kind: exec-plan
created_at: 2026-11-04T14:44:18Z
intention: "intention_01m6kg6d6cesktmnqhfpbp7m9h"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-04T14:44:18Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T15:02:38Z
      verdict: "approved"
      note: "Verified paths, APIs, fixtures and HTTP codes against the tree; no runtime package changes, so no benchmark regression path; applied clarifications in update mode"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T15:02:38Z
      mode: "update"
      note: "Stale working-tree claim fixed; catalog assertion, diagram check, regFileToJSON precondition, Every 1 rationale, guide locations, and performance diff-boundary acceptance added"
---

# Expose Keiki register values through the existing inspection APIs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a UI author can retrieve named Keiki register values from a
running application and inspect the register values in its latest persisted snapshot.
A register is a named, typed value carried by a state machine alongside its control
state, such as a credit balance or an active flag. The application decides how to
render its current values as JSON. A snapshot is an advisory cache of an earlier
fold of the event stream; its values can differ from the current values.

The stored-payload API already exists: `GET /snapshot/show?stream=NAME` returns
the persisted JSON in `state`. Keiro's default snapshot codec writes
`{"state": ..., "registers": {...}}`, so its register values are available at
`state.registers` today. This plan closes the display, example, documentation,
and acceptance gaps using that API and `GET /aggregate/show?name=NAME&id=ID`.
It does not require another snapshot route.

The runnable Jitsurei host will expose a small credit-limit aggregate with two
real registers. After one adjustment, both the current-state response and stored
snapshot response show `balance: 25` and `active: false`, with their respective
stream versions. Existing order and incident displays retain their state text
and gain an explicit empty `registers` object. This repository delivers the API
contract and worked example; browser rendering belongs to `mori://shinzui/keiro-ui`.


## Progress

- [ ] Milestone 1: current aggregate displays include register objects, and a mounted, snapshot-enabled credit-limit example returns nonempty register values through the library and embedded CLI.
- [ ] Milestone 2: tests prove that current folded values and persisted snapshot values retain their own versions, including a snapshot followed by more events, missing snapshots, and incompatible snapshot contents.
- [ ] Milestone 3: HTTP tests retrieve real nonempty registers through the existing routes, agree with CLI/library results, and prove response limits and read-only behavior.
- [ ] Milestone 4: a runnable demonstration and documented JSON contract let a UI author reproduce both views; relevant documentation checks and Nix verification pass.

Implementation has not started. The Jitsurei HTTP host from Plan 328 is
committed (`cd9f5a06`); what remains uncommitted in the working tree is that
plan's Milestone 4 documentation (`docs/guides/serve-keiro-ops-over-http.md`,
`docs/guides/run-and-operate-jitsurei.md`, ADR-53, IR-55, and their OKF logs).
Preserve those edits and build on them; do not commit them under this plan.


## Surprises & Discoveries

2026-11-04 (plan review): the uncommitted Plan 328 guide text at
`docs/guides/serve-keiro-ops-over-http.md` states that the aggregate `items`
are named `incident` and `order`. Milestone 4 must amend that sentence, so the
two plans share one documentation edit; see Context and Orientation.


## Decision Log

2026-11-04: Reuse the database-only `snapshot show` command for stored contents.
`Keiro.Ops.Snapshot.snapshotJson` already includes the entire `SnapshotRow.state`.
Adding a second contents API would duplicate an existing supported operation.
`aggregate snapshot` remains the application-aware snapshot-health view.

2026-11-04: Keep display encoding application-owned. Add `registers` to the
Jitsurei aggregate display objects explicitly, using Keiki's `regFileToJSON` for
the example's intentionally exposed slots. Do not make all inspectors default to
their persistence codec: custom snapshot encodings are not a public display
contract, and applications may select or redact their current display fields.
The existing raw snapshot route is already independent of those display choices;
document that distinction without claiming it provides the same redaction.

2026-11-04: Keep every change outside the measured runtime packages. No file
under `keiro-core/`, `keiro/`, `keiro-ops/`, or `keiro-ops-http/src/` changes;
the only new per-request work is `regFileToJSON` over the example's two slots
inside an application display callback. If implementation finds it must touch
one of those packages, stop and revise this plan first: `Keiro.Command` changes
require `just bench-regression command`, and HTTP application changes require
`cabal bench inspection-interference` against the committed baseline procedure,
as ADR-40 and ADR-54 demand. Without such a change neither benchmark is needed,
and the plan records that as the reason rather than as an omission.

2026-11-04: Demonstrate real values by adapting the existing pure
`Jitsurei.CreditLimit` machine into a runtime example. Order and incident have
empty register files, so their responses alone cannot prove value transport.
Keep their event folds and snapshot identities unchanged. Per-event register
timelines, historical snapshot archives, process-manager API expansion, and UI
implementation are outside this plan.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths below are relative to the repository root. An aggregate is one entity
whose state is reconstructed by applying its stored events in order. That
reconstruction is called hydration. It can start at a compatible cached snapshot
and replay later events; the event history remains authoritative.

`keiro/src/Keiro/Inspection/Aggregate.hs` defines `AggregateInspector`. Its
`displayState :: s -> RegFile rs -> Value` callback already receives the folded
control state and full register file. `inspectAggregate` invokes that callback,
and `aggregateViewJson` returns its value as `state`, along with `state_version`,
`stream_version`, `state_label`, hydration information, and snapshot health.
`displayViaStateCodec` is an existing explicit convenience for applications that
want their persistence encoding to be their display encoding. The generic
inspection API needs no new automatic register traversal.

In that module, `snapshotStatusFor` and `snapshotStatusJson` describe codec
configuration and the stored row's age, version, hashes, and compatibility.
They deliberately omit stored contents. In contrast,
`keiro-ops/src/Keiro/Ops/Snapshot.hs` implements `snapshot show --stream NAME`:
`observationByName` uses the exported storage read, and `snapshotJson` includes
the stored JSON as `state`. A missing stream or missing snapshot currently
returns JSON `null`. Preserve that behavior. `snapshot show` needs no application
hook or decoder, so it also returns an incompatible or unexpectedly shaped JSON
payload without interpreting it as current state.

`keiro/src/Keiro/Snapshot/Schema.hs` owns `SnapshotRow`, `lookupSnapshotRow`,
`observeSnapshotRow`, and the single latest row per stream in
`keiro.keiro_snapshots`. `keiro/src/Keiro/Snapshot/Codec.hs` owns the default
codec, which writes control state and named registers in separate object fields.
Its three compatibility identifiers are codec version, register-layout hash,
and control-state/fold hash. None is an instruction to decode arbitrary older
JSON in the browser. A custom codec may use a different JSON shape.

`keiro-ops/src/Keiro/Ops/Aggregate.hs` exposes `aggregate show` and
`aggregate snapshot`. `keiro-ops-http/src/Keiro/Ops/Http/Route.hs` and
`keiro-ops-http/src/Keiro/Ops/Http/Application.hs` derive HTTP paths and methods
from the ops command grammar and render the handler's JSON. With a root mount,
the three relevant reads are `/aggregate/show`, `/aggregate/snapshot`, and
`/snapshot/show`. A composed host can prefix them, for example with `/keiro`.

`jitsurei/src/Jitsurei/Inspection.hs` registers order and incident aggregates
and a fulfillment process manager. All three display callbacks currently
discard registers. Order and incident both have empty register files. Change
the two aggregate callbacks under this plan; the process-manager callback is
not required for the aggregate outcome. `jitsurei/src/Jitsurei/CreditLimit.hs`
already defines a pure machine with `balance :: Int` and `active :: Bool`,
initialized to zero and true. `AdjustCredit 25` sets them to 25 and false and
enters `CreditReviewed`. The module currently serves diagram generation and
has no runtime event-stream adapter.

`jitsurei/src/Jitsurei/Ops.hs` supplies shared application hooks.
`jitsurei/ops-http/app/Main.hs` hosts those hooks using the shared HTTP host;
`jitsurei/ops-http/test/Main.hs` already tests real network requests on an
ephemeral port. These files and the `just jitsurei-ops-http` recipe come from
[Plan 328](328-serve-the-jitsurei-aggregate-and-process-manager-hooks-from-a-runnable-keiro-ops-http-host.md)
and are committed. That suite's first example asserts the exact catalog
`["incident", "order"]` from `GET /aggregate/types`; it is the only exact
catalog assertion in the repository and becomes
`["credit-limit", "incident", "order"]` because the catalog is a `Map` keyed by
name. Plan 328's Milestone 4 guide text, still uncommitted in this checkout,
also says the aggregate `items` are named `incident` and `order`; Milestone 4
here rewrites that sentence. This plan is standalone and does not reopen the
inspection cohort's release coordination.

`keiro-ops-http/bench/InspectionInterference.hs` imports
`Jitsurei.Inspection (jitsureiProcessManagerInspectors)` and compiles under
`cabal build all --enable-benchmarks`. Keep that export unchanged so the
benchmark still builds; nothing in this plan requires running it.

Relevant decisions are
[ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md),
which requires all three compatibility identifiers before runtime snapshot use;
[ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md),
which keeps ops adapters over owning-library operations;
[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md),
which requires opt-in, bounded inspection without ordinary runtime overhead;
[ADR-53](../adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md),
which makes HTTP a transport over those same commands; and
[ADR-54](../adr/0054-aggregate-inspection-reuses-hydration-without-diagnostics-on-the-command-path.md),
which preserves explicit display encoders and the exact folded state's version.
These decisions support the feature without a new architectural boundary.


## Plan of Work

### Milestone 1: application displays and a nonempty register example


In `jitsurei/src/Jitsurei/Inspection.hs`, extend the order and incident display
objects with `"registers" .= regFileToJSON registers`, retaining their existing
`state` strings and `stateLabel` callbacks. This is an additive display change;
do not change the generic `AggregateView` envelope or require codecs for
current-state display. Empty register files render as `{}`. `regFileToJSON`
throws an `ErrorCall` beginning `uninit:` if any slot was never written; the
HTTP application would report that as a 500 `internal_error`. Every Jitsurei
stream supplies fully initialized `initialRegisters`, so the display callbacks
are total here, and the guide text in Milestone 4 states that precondition for
applications copying the pattern.

Create `jitsurei/src/Jitsurei/CreditLimitStream.hs` to adapt the existing
credit-limit machine into a validated event stream. Export a stream category
`credit-limit`, typed stream constructor, validated event stream, and display
function. Factor the initial register value out of `creditLimitTransducer`'s
local definition in `jitsurei/src/Jitsurei/CreditLimit.hs` so the adapter and
machine share it. Keep the machine's transitions, guards, labels, and diagram
output unchanged. Add `Generic` and a `CanonicalStateShape` instance for its
state, and JSON instances needed by the snapshot codec. Use state strings
`credit_open` and `credit_reviewed` consistently in this new example. Define
the event codec for the existing `CreditAdjusted` event as event type
`CreditAdjusted`, version 1, and payload `{"delta":25}` for this input, following
`Jitsurei.OrderStream.orderCodec`'s validation and decoding pattern.

Use `defaultStateCodecWithFold` with codec version 1, the explicit fold token
`credit-limit-fold-v1`, and snapshot policy `Every 1`. `Every 1` guarantees a
stored snapshot exists at version 1 so the stored-value view is reproducible
after a single command; the machine is terminal after that command, so each
example stream performs exactly one snapshot write. This is an example setting,
not a recommended production policy, and the guide says so. Register an
inspector named `credit-limit` with an explicit display object containing
`state` and `registers`. Export the adapter through `jitsurei/src/Jitsurei.hs` and list its
module in `jitsurei/jitsurei.cabal`. The library already declares the Keiki JSON
codec dependency. No new dependency bounds or snapshot migrations are needed.

In `jitsurei/test/Main.hs`, execute the command on a fresh stream, inspect it,
and run the embedded aggregate and snapshot commands. Prove nonempty values
through the real writer/reader path before expanding failure cases. Acceptance
is current and stored `state.registers == {"balance":25,"active":false}` at
version 1, not merely a successful encode or an empty object. Update the exact
catalog assertion in `jitsurei/ops-http/test/Main.hs` to
`["credit-limit", "incident", "order"]`. Prove the diagram output is unchanged
with `cabal run jitsurei:exe:jitsurei-diagrams -- --check`, which `just verify`
already runs.

### Milestone 2: current and stored versions remain distinguishable


Extend the existing `Keiro.Inspection.Aggregate` test in
`keiro/test/Main.hs`, which already executes `Add 2`, `Add 3`, and `Add 4`
against `snapshotCounterEventStream`. That fixture writes every two events.
Assert directly that the current displayed `lastAmount` is 4 at state version
3, while the supported stored-row read returns `lastAmount` 3 at snapshot
version 2. Compare stored JSON to the codec's encoding at version 2, not to a
newly hydrated version 3 value. Assert that inspection leaves the snapshot
row and stream metadata unchanged; reads must not refresh the cache.

Extend `keiro-ops/test/Main.hs`'s snapshot-handler coverage to assert exact
payload preservation, including an arbitrary custom JSON shape and
incompatible identifiers. The raw read must not silently re-encode through
the current codec, hide stored contents, or add compatibility claims it cannot
derive without application code. Test JSON `null` for both a missing stream
and an existing stream without a snapshot. Keep existing soft-deleted aggregate
behavior: its aggregate `state` is null; the stored snapshot route may still
show a retained row. The application-aware health view continues to report
compatibility independently. Prefer strengthening these existing fixtures to
adding a separate implementation of a state machine.

Acceptance is a test that would fail if an implementation substituted the
current fold for the cached values, discarded raw incompatible/custom JSON,
or wrote a new snapshot during inspection.

### Milestone 3: prove the HTTP consumer path and bounds


Extend `jitsurei/ops-http/test/Main.hs` with the credit-limit command and
requests to `/aggregate/show?name=credit-limit&id=registers-100`,
`/aggregate/snapshot?name=credit-limit&id=registers-100`, and
`/snapshot/show?stream=credit-limit-registers-100`. Compare stable data fields
and payloads to the embedded ops results; independently generated observation
times and age fields are not expected to be byte-identical. Assert exact
register values and the version fields through the real listening host.
The aggregate response's `stream_name` is the input for the raw snapshot
request; consumers should not reconstruct category prefixes themselves.

In `keiro-ops-http/test/Main.hs`, add focused raw snapshot tests for a missing
row, an arbitrary JSON payload, and a payload exceeding a deliberately small
`maxResponseBytes`. Assert 200 with null when absent and 413 with
`inspection_result_too_large` when oversized. A following health or small read
must succeed, proving the admission slot was released. Assert GET succeeds with
mutations disabled and POST receives 405, and compare stream and snapshot
rows before and after the read. Existing schema-drift, cancellation, and
admission tests remain the shared transport checks; do not create parallel
route handling or bypass them for snapshots. No polling task, cache, writer
index, or command-path change is needed.

### Milestone 4: a reproducible UI-facing contract


Add a `registers` mode to `jitsurei/app/Main.hs` and a `just jitsurei-registers`
recipe following the existing snapshot-demo database setup. Each invocation
chooses a fresh credit-limit id, runs `AdjustCredit 25`, and prints the id,
physical stream name, and the three read URLs. Include this scenario in the
`all` mode so the ordinary local stack has real register data. Never reset or
delete a user's existing database to seed the example.

Update `docs/guides/serve-keiro-ops-over-http.md` and
`docs/guides/run-and-operate-jitsurei.md` with copyable commands and captured
response excerpts. In the HTTP guide, extend the existing "See the hook-gated
routes locally" section (added by Plan 328, uncommitted in this checkout) and
replace its `incident` and `order` catalog sentence with the three names. In
the runbook, add a short section before "Rehearse A Catalog Rebuild" that
walks through `just jitsurei-registers` and the three reads; the runbook
currently has only that one subsection. Define the difference between current `state_version`,
stored `stream_version`, and the health view's observed head. Explain missing
snapshots, stale snapshots, custom codecs, and the independent observations
across requests. Document that the raw snapshot route exposes persistence JSON
even when an application's current-state encoder omits fields. Present
`state.registers` as this example/default codec's shape, not a guarantee for
every custom codec or display encoder. The UI can always display the returned
JSON generically; typed register tables require that application contract.
State that `regFileToJSON` requires every slot to be initialized and that
`Every 1` is an example policy chosen so one command yields a stored snapshot.

Record the additive display/example change in `CHANGELOG.md`. Update ADR-54
if its display-contract explanation needs this clarification, preserving its
existing handle and recording any timestamp advance in the ADR bundle log.
Update documentation timestamps and logs through the existing OKF workflow.
Run the focused suites and the required repository checks below; record concise
acceptance evidence and leave implementation status accurate.


## Concrete Steps

Run these commands from `/Users/shinzui/Keikaku/bokuno/keiro`. Before implementing,
inspect `git status --short` and preserve work belonging to Plan 328. Locate
dependency APIs with Mori rather than guessing:

```bash
mori registry search keiki
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
mori path mori://shinzui/keiki/packages/keiki-codec-json
```

Read `src/Keiki/Codec/JSON.hs` relative to the returned package directory.
`RegFileToJSON` provides `regFileToJSON :: RegFile rs -> Value`, with JSON keys
equal to slot names. It requires initialized registers. This plan reuses current
dependency bounds; any later proposed bound or pin change requires authoritative
registry and upstream-tag verification before adoption.

Verify in the Nix development shell, regardless of host tools. Focused checks
can run at their milestones; run the final broad check once on the coherent
candidate. Z3 must be available before `just verify` executes DSL tests.

```bash
nix develop -c z3 --version
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c cabal test jitsurei-test --test-show-details=direct
nix develop -c cabal test keiro-test --test-options='--match=Keiro.Inspection.Aggregate' --test-show-details=direct
nix develop -c cabal test keiro-ops-test --test-options='--match=snapshot' --test-show-details=direct
nix develop -c cabal test keiro-ops-http-test jitsurei-ops-http-test --test-show-details=direct
nix develop -c just adr-validate user-documentation-validate
nix develop -c just verify
git diff --check
```

The focused suites must report zero failures, including the named nonempty
register and older-snapshot cases. Use the repository's formatting workflow
before the final verification. Investigate failures against the actual candidate;
do not treat unrelated existing work as permission to reset it.

With the repository's local PostgreSQL service running as described in
`docs/guides/run-and-operate-jitsurei.md`, demonstrate the finished feature:

```bash
nix develop -c just jitsurei-registers
nix develop -c just jitsurei-ops-http
```

The second command remains running. In another terminal, paste the printed
aggregate id after `read`, then request the views:

```bash
read -r REGISTER_ID
curl -fsS "http://127.0.0.1:9092/aggregate/show?name=credit-limit&id=$REGISTER_ID"
curl -fsS "http://127.0.0.1:9092/aggregate/snapshot?name=credit-limit&id=$REGISTER_ID"
curl -fsS "http://127.0.0.1:9092/snapshot/show?stream=credit-limit-$REGISTER_ID"
```

The example's known category makes the last URL copyable. Production consumers
use the `stream_name` returned by aggregate inspection and URL-encode it. If the
host is mounted under a prefix, apply that prefix to all three URLs.


## Validation and Acceptance

The new example must produce this stable subset from aggregate inspection:

```json
{
  "name": "credit-limit",
  "stream_version": 1,
  "state_version": 1,
  "state_label": "credit_reviewed",
  "state": {
    "state": "credit_reviewed",
    "registers": {"balance": 25, "active": false}
  }
}
```

The snapshot-health response reports a present, compatible stored snapshot at
version 1. The raw snapshot response has this stable subset:

```json
{
  "stream_version": 1,
  "state": {
    "state": "credit_reviewed",
    "registers": {"balance": 25, "active": false}
  }
}
```

The raw response also retains codec version, both shape hashes, timestamps,
observation time, age, and encoded byte count. No new envelope is introduced.
Tests assert the shown integer and Boolean values directly and compare them to
library/CLI results. Order and incident still expose the same state strings;
their added register objects are empty. The expanded catalog is deliberately
observable and its discovery examples must agree.

The existing counter test distinguishes a head at version 3 with
`lastAmount: 4` from a stored snapshot at version 2 with `lastAmount: 3`.
This is the acceptance case for stale snapshots; equality at a snapshot boundary
alone is insufficient. Missing raw snapshots return null, arbitrary persisted
JSON survives unchanged, and incompatible snapshots remain raw inspection data
while the aggregate health response identifies incompatible discriminators.
Do not infer compatibility from the raw endpoint or claim a transaction spanning
separate HTTP requests.

Performance acceptance is a diff boundary, not a benchmark run. At completion,
`git diff --stat <base>..HEAD -- keiro-core keiro keiro-ops keiro-ops-http/src`
must be empty, where `<base>` is the commit before the plan's first commit. That
proves the ordinary command path (`Keiro.Command`, measured by the `command`
guard of `just bench-regression`) and the HTTP application (measured by
`cabal bench inspection-interference`) are byte-for-byte unchanged, so neither
gate needs to run. `aggregate show` for `credit-limit` performs the same store
reads as it does for `order`: one stream lookup, one snapshot seed lookup, the
event pages after the seed, and one snapshot observation; the display callback
adds `regFileToJSON` over two slots and no queries. The diff boundary is the
acceptance evidence; if it is not empty, the plan must be revised before the
work is accepted.

Read-only and oversized-result tests must pass through the existing HTTP
application, not only its encoders. The new capability must require no migration,
new writer query, automatic snapshot refresh, ordinary-command instrumentation,
or new background task. If implementation needs to change those boundaries,
revise this plan and supply the runtime isolation evidence required by ADR-40
before accepting the change. Existing integrated inspection release gates remain
in force; this example does not replace them.


## Idempotence and Recovery

Tests use fresh database fixtures and can be repeated. The demo uses a fresh id
on each run so the terminal credit-limit machine is not commanded twice. Retain
the printed id to revisit an earlier run. Stopping the example host releases its
inspection resources without changing persisted events or snapshots.

This is additive display and example work. No schema reset, data migration,
snapshot deletion, or history rewrite is part of implementation or acceptance.
If a manually selected id is already terminal, choose another id. If the local
database is not running, start it through the documented project workflow. Never
drop an existing configured database to recover a demonstration.

Keep existing plan provenance append-only and update progress after verifiable
milestones. Commits made during implementation use Conventional Commits and
include both `ExecPlan: docs/plans/329-expose-keiki-register-values-through-the-existing-inspection-apis.md`
and `Intention: intention_01m6kg6d6cesktmnqhfpbp7m9h` trailers. Do not commit
unrelated changes in the shared working tree.


## Interfaces and Dependencies

The existing public interfaces remain the foundation:

```haskell
-- Keiro.Inspection.Aggregate
displayState :: s -> RegFile rs -> Value
displayViaStateCodec :: StateCodec (s, RegFile rs) -> s -> RegFile rs -> Value

-- Keiro.Snapshot.Schema
observeSnapshotRow :: (Store :> es) => StreamId -> Eff es SnapshotObservation
```

The first signature names an `AggregateInspector` record field rather than a
new top-level function. `SnapshotObservation.row` contains the original
`SnapshotRow.state`; use that owning-library read when a fixture needs stored
contents. Do not query another library's private stream schema.

The Keiki JSON package is `mori://shinzui/keiki/packages/keiki-codec-json`.
Its slot serializer is reused explicitly inside application display functions.
No dependency upgrade, new HTTP package, or change to default codec identity is
required. If direct test imports need an already-used package listed in that
component's Cabal dependencies, add the component declaration within the
repository's existing compatible bounds.

The HTTP consumer contract consists of existing GET routes, the application-owned
`state` JSON, and explicit version metadata. `GET /aggregate/show` needs the
application catalog; `GET /snapshot/show` is database-only and returns persistence
JSON without current-codec validation. `GET /aggregate/snapshot` supplies the
application-aware health assessment. These are separate observations and are not
an atomic cross-request bundle. The store keeps only the latest snapshot per
stream, so an arbitrary per-event register timeline cannot be served from it.


## Revision Notes

2026-11-04 (review and update, claude-fable-5-1): corrected the working-tree
description (the Plan 328 host is committed; its Milestone 4 documentation is
not), named the one exact catalog assertion and its new ordered value, named
the diagram check that proves `Jitsurei.CreditLimit` output is unchanged,
recorded the `regFileToJSON` initialization precondition and the reason for the
`Every 1` policy, located the documentation edits inside the two guides, and
added the performance acceptance: an empty diff over the measured runtime
packages, with the `command` benchmark guard and `inspection-interference`
benchmark named as the gates that would otherwise apply.
