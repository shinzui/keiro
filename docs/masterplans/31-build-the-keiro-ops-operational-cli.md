---
id: 31
slug: build-the-keiro-ops-operational-cli
title: "Build the keiro-ops operational CLI"
kind: master-plan
created_at: 2026-08-06T03:02:00Z
intention: "intention_01kzagac32ehp93amx1sfar2ab"
---

# Build the keiro-ops operational CLI

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Keiro's operational story today is a runbook (`docs/user/operations.md`) whose
procedures are Haskell function calls: an operator repairs a stuck timer by opening a
REPL or writing a one-off program against `Keiro.Timer.findStuckTimers`, resurrects a
failed workflow through `Keiro.Workflow.Instance.resurrectFailedWorkflow`, redrives a
pgmq dead-letter queue through `Keiro.PGMQ.Dlq.redriveDlq`, and inspects a workflow
by hand-writing SQL against `keiro.keiro_workflows`. Every one of those capabilities
already exists as a supported library API; what is missing is the console. This is
also the largest remaining operational gap against server-shaped runtimes such as
Restate, whose CLI/UI can list invocations, inspect journals, and kill or restart
them — the 2026-08 durable-execution re-audit (MasterPlan 30) identified operator
tooling as the one gap that is both real and cheap to close, precisely because the
tables and APIs are all in place.

After this initiative, a deployment adopting keiro gets `keiro-ops`: a new package
providing an operational command-line tool over every runtime domain — durable
workflows (list, show, journal, resurrect, cancel, awakeable signal/cancel, GC),
timers (stuck-row triage: list/requeue/cancel/dead-letter, one-shot drain), the
outbox and inbox (backlog, listing, requeue, GC, dispatch dead letters), pgmq queues
(DLQ read/redrive/purge/archive), projections and read models (dedup pruning,
with durable subscription positions and lag held behind Kiroku's checkpoint-inventory API), sharded subscriptions (ownership snapshots,
relinquish), snapshots (inspect, delete, truncation-coverage preflight), and kiroku
streams (read, lifecycle, truncate-before, and durable checkpoint inventory once
the owning API is released) — with
human-readable tables by default and `--json` everywhere for scripting.

The design honors keiro's library shape. Operations split into two classes. The
*database-only* class needs a connection string and the schema and nothing else;
those commands live in a standalone `keiro-ops` binary usable against any keiro
deployment. The *code-dependent* class needs the application's Haskell — the
`WorkflowRegistry` to resume workflows, projection handlers to rebuild, the
candidate binary for `Keiro.ReplayAudit` — so the CLI core is an **embeddable
library**: an application mounts the command tree into its own binary
(`yourapp ops …`), gaining the registry-dependent commands the standalone binary
can never offer. `keiro-migrate` (standalone, DB-only) and
`Keiro.ReplayAudit.auditExitCode` (runs inside the candidate binary) are the two
existing precedents this generalizes.

Two rules are constitutional and recorded as an ADR by EP-2. First, **the CLI never
invents SQL**: every mutating command wraps an existing supported library API, so
console operations cannot bypass the invariants (idempotent appends, guarded status
transitions, lease arbitration) the libraries enforce; where a needed primitive does
not exist, it is added to the owning library first (EP-1 does exactly this for
workflow listing, top-level cancellation, and lease release). Second, **schema
ownership is respected across libraries**: kiroku-domain commands call
`mori://shinzui/kiroku/packages/kiroku-store` functions (`Kiroku.Store.Lifecycle`,
`Subscription`, `Causation`),
pgmq-domain commands call `keiro-pgmq`/`pgmq-hs`, and no command reaches into
another library's tables directly.

In scope: the `keiro-ops` package (library + standalone binary), the small set of
missing keiro operator APIs the CLI exposes as gaps (workflow instance listing,
top-level `cancelWorkflow`, operator lease release), the embedding surface with
resume/audit commands, a jitsurei demonstration of embedding, the safety rails
(destructive commands print affected rows and require `--force`; a schema-version
handshake via `Keiro.Migrations.SchemaCheck.verifyExpectedSchema` warns or refuses
when the binary and database migration generations diverge), and the documentation
flip (`docs/user/operations.md` procedures become commands; `docs/user/roadmap.md`
moves "Operator CLIs" from longer-term to available).

Out of scope: implementing Kiroku's durable checkpoint-inventory API in this
repository; that owning-library dependency is tracked by
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2`. Also out of scope:
a TUI or web console (the CLI is the substrate one could build on
later); hosting long-running workers in the CLI (workers belong in the application;
the CLI offers one-shot passes like `timer drain-once` and `wf gc run-once` for
cron-driven operation); merging with the `keiro-dsl` CLI (dev-time spec toolchain,
different audience and release cadence — deliberately separate binaries); any new
kiroku/pgmq server-side capability (the CLI composes what the libraries already
expose; upstream additions are filed upstream); and defining read-model rebuild
semantics inside the CLI. Typed catalog validation, fencing, clear/preserve policy,
history replay, progress, and promotion are owned by
[MasterPlan 32](32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md);
this initiative owns the command mount, rendering, safety rails, and embedding
around that supported library API.

Relationship to MasterPlan 30
(`docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md`):
disjoint files, no shared edits; plan 200's exact discovery makes `wf list` status
columns trustworthy, and plan 203's landed `drainDueTimersWith` is the backend
EP-4 mounts as `timer drain-once` with an application-supplied fire action.


## Decomposition Strategy

Four child plans, decomposed by what each delivers independently: missing library
primitives first (they gate everything and are pure keiro work), then the package
core with the two domains that prove the whole design (workflows and timers exercise
listing, mutation, safety rails, and the handshake), then breadth across the
remaining domains (mechanical once the core exists), then the embedding surface and
the documentation flip (which must come last to describe what shipped).

EP-1 (plan 205) adds the operator APIs the audit's CLI survey found missing, to the
`keiro` library itself: a real listing surface for workflow instances (filterable by
status/name, keyset-paged — today `lookupInstance` is a point query), a supported
top-level `cancelWorkflow` (today only children are cancellable via their link row;
the new API is the cancellation dual of `resurrectFailedWorkflow` and appends the
`WorkflowCancelled` marker through the standard idempotent append path), and an
operator lease release for a wedged owner. These land as ordinary library functions
with their own tests, valuable even without the CLI.

EP-2 (plan 206) creates the `keiro-ops` package: the command-tree architecture
(optparse-applicative, matching `keiro-migrate` and `keiro-dsl` conventions), the
connection/environment plumbing (hasql settings), the output layer (aligned tables
for humans, `--json` for scripts), the safety rails (`--force` with an
affected-rows preview; schema handshake through
`Keiro.Migrations.SchemaCheck.verifyExpectedSchema`), the workflow domain, and
database-only timer triage end to end. It records the constitutional rules as a
new ADR.

EP-3 (plan 207) adds the remaining database-only domains — outbox, inbox, dispatch
dead letters, pgmq DLQs, projection dedup retention, shards, snapshots, and kiroku
streams — each a thin wrapper over the owning library's exported functions,
following the patterns EP-2 froze. Its durable checkpoint inventory and derived
projection-lag commands remain open until
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2` ships a public API.

EP-4 (plan 208) makes the tree embeddable (`Keiro.Ops.commandTree` taking an
application environment with optional registry/timer-fire/audit hooks), ships the
code-dependent commands (`timer drain-once`, `wf resume-once`, `replay-audit`, and a typed
projection-catalog rebuild mount when MasterPlan 32 is available),
demonstrates embedding in `jitsurei`, and rewrites the operational docs around the
CLI.

Alternatives considered. Building the CLI inside the `keiro` package was rejected:
the CLI depends on `keiro`, `keiro-pgmq`, `keiro-migrations`, and `kiroku-store`
simultaneously, and none of those should gain the others as dependencies — a
separate package is the only clean home. One-plan-per-domain (eight plans) was
rejected as registry noise: after EP-2 freezes the patterns, the remaining domains
are mechanical and belong together. Starting with a TUI/console was rejected — the
scriptable CLI is the substrate, and `--json` output makes any future console a
client, not a rewrite.

ADR context at authoring, per `agents/skills/exec-plan/ADR.md` (`docs/adr/` is a
profile-governed OKF bundle; allocate ids with `okf id next`, validate with
`just adr-validate`): relevant records are
`docs/adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md`
(EP-1's `cancelWorkflow` must mirror the resurrection contract's append-only
history discipline),
`docs/adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md`
(cancellation racing wake delivery is already arbitrated in-transaction; the
operator API reuses those paths),
`docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md` (the
schema handshake delegates to the existing verification machinery rather than
inventing a second checker), and
`docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq DLQ
commands must not bypass the envelope contract). No ADR records a CLI/operator
boundary yet; EP-2 creates it. MasterPlan 30's pending ADRs (exact discovery,
frozen identity bytes) do not constrain this initiative.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Add workflow listing, top-level cancellation, and lease-release operator APIs | docs/plans/205-add-workflow-listing-top-level-cancellation-and-lease-release-operator-apis.md | None | None | Complete |
| 2 | Create the keiro-ops package with the workflow and timer command domains | docs/plans/206-create-the-keiro-ops-package-with-the-workflow-and-timer-command-domains.md | EP-1 | None | Complete |
| 3 | Add the messaging and read-side command domains to keiro-ops | docs/plans/207-add-the-messaging-and-read-side-command-domains-to-keiro-ops.md | EP-2 | Kiroku IR-2 | In Progress |
| 4 | Make keiro-ops embeddable and document the operational surface | docs/plans/208-make-keiro-ops-embeddable-and-document-the-operational-surface.md | EP-2 | EP-3 | In Progress |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 has no dependencies and is pure `keiro`-library work. EP-2 hard-depends on
EP-1: the workflow domain's flagship commands (`wf list`, `wf cancel`,
`wf lease release`) are thin wrappers over EP-1's new APIs, and building the domain
against stubs would mean designing the same signatures twice. EP-3 hard-depends on
EP-2 for the package, command-tree patterns, output layer, and safety rails it
extends. EP-4 hard-depends on EP-2 (the embedding surface refactors the core
environment type) and soft-depends on EP-3 only because the documentation flip
should describe the full domain set; the embedding mechanics themselves need
nothing from EP-3, so EP-3 and EP-4 can proceed in parallel if the docs milestone
of EP-4 lands last.

EP-3 has one external integration gate: durable checkpoint inventory and the
projection lag derived from it require
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2`. The other EP-3
domains are complete. EP-4 may proceed because that relationship is soft and no
code-dependent hook relies on checkpoint inventory.


## Integration Points

The `keiro-ops` package and `cabal.project` — EP-2 creates both entries; EP-3 and
EP-4 add modules to the existing package only. EP-2 owns the cabal file's
dependency floor (keiro, keiro-pgmq, keiro-migrations, kiroku-store,
optparse-applicative bounds copied from `keiro-migrations/keiro-migrations.cabal`
and `keiro-dsl/keiro-dsl.cabal`).

The ops environment type (working name `OpsEnv`: store handle, schema names,
output mode, force flag) — EP-2 defines it in `Keiro.Ops.Env`; EP-3 consumes it
unchanged; EP-4 *extends* it with the optional application hooks (registry,
timer fire action, audit targets, and `ProjectionCatalogOperations`). EP-4 owns that extension; EP-3 must not
pre-empt it. The rebuild hook is operator-neutral and comes from
`Keiro.Projection.Catalog.Operations`; no `Map Text (OpsEnv -> IO ExitCode)` or
CLI-side target inventory is permitted.

The command-tree module layout (`Keiro.Ops.Cli` root; one module per domain,
`Keiro.Ops.Workflow`, `Keiro.Ops.Timer`, then EP-3's `Keiro.Ops.Outbox`, `.Inbox`,
`.Pgmq`, `.Projection`, `.Shard`, `.Snapshot`, `.Stream`) — EP-2 freezes the
per-domain module convention and the render/`--json` helpers every domain uses.

Kiroku durable checkpoints — EP-3 must consume the public member-aware inventory
requested by `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2` once a
tagged Kiroku release provides it. Until then neither `projection position` nor
`stream subscriptions` is mounted: filtering through Keiro's direct
`subscriptions`-table query violates ADR 28, while `subscriptionStates` is a live
registry on the CLI's newly opened store handle and cannot represent deployed or
stopped workers.

EP-1's new APIs in `keiro` (`listWorkflowInstances`, `cancelWorkflow`,
`releaseInstanceLeaseForce` or equivalents) — EP-1 defines and tests them; EP-2
consumes them without modification. If EP-2 discovers a signature gap, the fix goes
into `keiro` under EP-1's contract (reopen EP-1 or record a follow-up), never as
SQL in the CLI.

Cross-plan decisions that deserve ADRs: EP-2's "operator commands wrap supported
library APIs and respect schema ownership" (new ADR); EP-1's cancellation contract
may extend `docs/adr/0008-...md` rather than minting a new record — the
implementing plan decides and records which.

Migration numbering: EP-1's listing needs are expected to be index-covered already
(`keiro_workflows` primary key and `keiro_workflows_active_idx`); if a listing
index proves necessary, EP-1 claims the next free number in
`keiro-migrations/migrations/` after MasterPlan 30's plan 200 (coordinate — 0021
is claimed by that plan) and reconciles the pinned migration-count tests.


## Progress

- [x] EP-1: `listWorkflowInstances` with status/name filters and keyset paging, tested.
- [x] EP-1: `cancelWorkflow` and operator lease release, tested against the terminal/race contracts.
- [x] EP-2: `keiro-ops` package scaffolding, `OpsEnv`, output layer, `--force` rail, schema handshake.
- [x] EP-2: workflow + standalone timer-triage domains complete; ADR for the operator-command contract recorded.
- [x] EP-3: outbox, inbox, dead-letter, pgmq, projection-dedup, shard, snapshot, and stream lifecycle/read domains complete.
- [ ] EP-3: durable checkpoint inventory and projection-lag commands, blocked on `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2`.
- [ ] EP-4: embeddable command tree with registry-dependent commands; jitsurei embeds it.
- [ ] EP-4: operations docs rewritten around the CLI; roadmap flips "Operator CLIs" to available.


## Surprises & Discoveries

- 2026-08-07: The projection ownership review found that a free-form application
  rebuild map would preserve duplicate target/projection inventories and could not
  render an authoritative destructive preview. MasterPlan 32 now owns a validated
  catalog and supported rebuild runner; EP-4 mounts that adapter when available.
  At this date `keiro-ops` does not yet exist, so the integration order is explicit
  rather than assumed.
- 2026-08-08: MasterPlan 32 completed its side of the integration first. The landed public type is
  `Keiro.Projection.Catalog.Operations.ProjectionCatalogOperations`; it provides versioned JSON
  inventory, pure and registered-state preview, and start/inspect/resume/abandon actions. The
  `keiro-ops` package is still absent, so EP-4 must mount these values after EP-2 creates the
  command tree rather than asking applications for any parallel action map.
- 2026-08-08: EP-1 found that same-marker step locks were insufficient for
  operator cancellation: completion, cancellation, failure, and rotation use
  distinct reserved names. The runtime now arbitrates those markers under one
  generation lifecycle lock and commits rotation with its next-generation seed
  atomically. EP-2's public inputs remain the planned
  `listWorkflowInstances`, `cancelWorkflow`, and
  `forceReleaseInstanceLease`; no migration or CLI workaround is required.
- 2026-08-09: EP-2 found two read-model gaps needed for exact output and
  previews (`WorkflowInstanceRow.wakeAfter` and
  `listWorkflowGcCandidates`) and added them to the owning Keiro modules. It also
  confirmed `drainDueTimersWith` requires application dispatch code, so the
  standalone binary ships timer triage while EP-4 conditionally mounts
  `timer drain-once` with a timer-fire hook.
- 2026-08-08: EP-3 found that exact mutation previews required narrow public
  inspection APIs in the owning Keiro modules. It added stale/retention candidate
  lists, generic snapshot inspection/deletion, projection-scoped dedup
  count/pruning, and subscription-scoped shard reads. The CLI contains no domain
  SQL, and its `OpsEnv` remains unchanged for EP-4.
- 2026-08-08: `subscriptionStates` in
  `mori://shinzui/kiroku/packages/kiroku-store` is live process-local state, not
  durable checkpoint inventory. A later audit also found that the standalone
  binary opens a fresh `KirokuStore`, so its process-local registry normally has
  no application workers and is not a useful substitute. EP-3 removed that
  command and the indirect `Keiro.ReadModel.readSubscriptionPosition` CLI path;
  both durable commands now wait on
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2`.
  EP-3 also made aggregate snapshot discriminators explicit because the
  standalone binary cannot infer application codec identities.


## Decision Log

- Decision: New `keiro-ops` package rather than a CLI inside `keiro`.
  Rationale: The CLI must depend on keiro, keiro-pgmq, keiro-migrations, and
  kiroku-store at once; no existing package can gain those edges cleanly.
  Date: 2026-08-06

- Decision: Embeddable-library-first design with a thin standalone binary for the
  database-only subset.
  Rationale: Keiro is library-shaped; registry- and codec-dependent operations
  cannot exist in a standalone binary, and the two existing precedents
  (`keiro-migrate` standalone, `auditExitCode` embedded) already split this way.
  Date: 2026-08-06

- Decision: Constitutional rules — mutating commands wrap supported library APIs
  only, and cross-library table access is forbidden — recorded as an ADR in EP-2.
  Rationale: A console that bypasses library invariants (idempotent appends,
  guarded transitions, lease arbitration) converts every operator mistake into a
  data-integrity incident; the rule must outlive this initiative.
  Date: 2026-08-06

- Decision: Missing primitives (workflow listing, top-level cancel, lease release)
  are added to `keiro` as EP-1 library APIs, not implemented as CLI-side SQL.
  Rationale: Same invariants argument; also makes the primitives available to
  applications and future consoles, mirroring how MasterPlan 16 shipped
  `resurrectFailedWorkflow` as a library API.
  Date: 2026-08-06

- Decision: Keep `keiro-dsl` a separate binary; do not unify the CLIs.
  Rationale: Dev-time spec toolchain and production operations have different
  audiences, failure modes, and release cadences.
  Date: 2026-08-06

- Decision: Replace EP-4's free-form rebuild action map with the typed
  `ProjectionCatalogOperations` adapter from MasterPlan 32.
  Rationale: Applications continue to own schema and handlers, but catalog
  membership, reset and replay policy, fixed-head completion, and safe lifecycle
  are Keiro runtime invariants. The ops package should present those invariants,
  not provide a bypass. If MasterPlan 31 reaches EP-4 first, it omits the rebuild
  command until the adapter lands.
  Date: 2026-08-07

- Decision: Treat completion, cancellation, failure, and rotation as one
  first-writer-wins generation lifecycle for journal appends.
  Rationale: EP-1 proved that per-marker idempotence alone can leave
  contradictory terminal markers. The shared lifecycle lock and atomic rotation
  preserve one journal/instance winner for every operator command EP-2 exposes;
  the durable contract is ADR 27.
  Date: 2026-08-08

- Decision: Classify timer draining as code-dependent and move its command mount
  from EP-2's standalone surface to EP-4's application hooks.
  Rationale: `drainDueTimersWith` deliberately delegates dispatch and the fired
  event id to its callback. A generic database binary cannot supply either, and
  a dummy callback would leave claimed timers stranded in `firing`.
  Date: 2026-08-09

- Decision: Keep EP-3 previews exact by adding reusable read APIs to the owning
  Keiro modules, while deferring durable Kiroku checkpoint reporting until its
  owning library publishes the required API.
  Rationale: ADR 28 applies to reads used to authorize mutations as well as to
  the mutations themselves. `subscriptionStates` cannot be relabeled as durable
  checkpoints and is normally empty on the standalone binary's fresh store
  handle; Keiro's direct `subscriptions` query is not an acceptable CLI bridge.
  Date: 2026-08-08


## Outcomes & Retrospective

EP-2 completed on 2026-08-09. The repository now contains a tested `keiro-ops`
package with the standalone command root, table/JSON rendering, connection and
schema safeguards, full workflow inspection/recovery commands, and timer stuck-row
triage. ADR 28 fixes the command/library ownership boundary for every later domain.
The scratch-database transcript and full gate evidence are recorded in plan 206.

EP-3's independent domains landed on 2026-08-08. The standalone binary now mounts
outbox, inbox, PGMQ DLQ, projection dedup, shard, snapshot, and Kiroku stream
read/lifecycle domains alongside the workflow and timer commands from EP-2.
Exact previews stay behind public owning
library APIs; irreversible PGMQ purge and stream deletion have typed human-mode
target confirmation; JSON automation remains preview plus `--force`. The
database integration suite passes 23 examples, and the affected Keiro and
`keiro-pgmq` suites pass 441 and 58 examples respectively. The repository-wide
`just verify` gate passes through the full DSL conformance corpus, jitsurei,
migrations, generated-corpus checks, and OKF validation. Durable checkpoint
inventory and projection lag remain incomplete behind Kiroku IR-2.

The next dependency-ready child is EP-4 (plan 208): extend the environment with
application hooks, mount code-dependent operations, demonstrate embedding in
`jitsurei`, and rewrite the operational documentation around the completed CLI.


Revision note: Coordinated EP-4's rebuild mount with MasterPlan 32's typed catalog
operations and removed the free-form rebuild-map contract, 2026-08-07.

Revision note: Reconciled EP-4 with the landed `ProjectionCatalogOperations` API while the
`keiro-ops` package remains pending behind EP-2, 2026-08-08.

Revision note: Completed EP-1, recorded its lifecycle-arbitration discovery and
ADR, and unblocked EP-2 with the planned public operator APIs, 2026-08-08.

Revision note: Reopened EP-3's durable checkpoint slice, removed the unusable
process-local subscription command and the cross-schema projection-position
bridge, and gated both on Kiroku IR-2, 2026-08-08.
