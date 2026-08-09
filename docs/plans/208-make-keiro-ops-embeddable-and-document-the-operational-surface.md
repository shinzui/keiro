---
id: 208
slug: make-keiro-ops-embeddable-and-document-the-operational-surface
title: "Make keiro-ops embeddable and document the operational surface"
kind: exec-plan
created_at: 2026-08-06T03:02:06Z
intention: "intention_01kzagac32ehp93amx1sfar2ab"
master_plan: "docs/masterplans/31-build-the-keiro-ops-operational-cli.md"
---

# Make keiro-ops embeddable and document the operational surface

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The standalone `keiro-ops` binary can only ever cover database-only operations,
because keiro is a library: resuming a workflow needs the application's
`WorkflowRegistry` (a name-to-Haskell-code map that no external binary can
possess), replay auditing needs the candidate binary's own codecs and streams
(`Keiro.ReplayAudit` is *designed* to run inside it), and read-model rebuilds need
the application's validated projection catalog. Timer draining likewise needs the
application's fire action to dispatch opaque payloads and return the event id that
completes each claim. This plan closes that gap the way
the MasterPlan's design dictates: the command tree becomes an embeddable library surface, so an
application mounts the entire console into its own executable —
`yourapp ops wf resume-once …`, `yourapp ops replay-audit …`, `yourapp ops rebuild
<model>` — gaining the code-dependent commands next to every database-only one,
with identical flags, rendering, and safety rails.

It also performs the documentation flip that ends the initiative: the operational
runbook stops describing REPL procedures and starts naming commands, `jitsurei`
demonstrates the embedding for adopters to copy, and the user roadmap moves
"Operator CLIs" from longer-term possibility to available.


## Progress

- [x] Embedding surface: `AppHooks`, `opsCommandTree`, standalone binary refactored onto it.
- [x] Code-dependent commands: `timer drain-once`, `wf resume-once`, `replay-audit`, catalog-backed `rebuild` mount.
- [x] `jitsurei` embeds the console; command help and catalog/replay fixtures exercised.
- [x] Docs flip: operations.md, durable-workflows guide/reference, roadmap.md, production-status.md, README.
- [x] `cabal test keiro-ops-test` and full repo `just verify` green.


## Surprises & Discoveries

- 2026-08-08: MasterPlan 32 landed the operator-neutral runtime adapter before this plan's
  prerequisite package existed. `keiro-ops` and `Keiro.Ops.Embed.AppHooks` are still absent, so
  plan 213 stopped at the integration gate instead of creating a second parser. The available
  public hook is `Keiro.Projection.Catalog.Operations.ProjectionCatalogOperations`, with versioned
  inventory, preview, registered-preview, and run-report JSON values.
- 2026-08-09: Plan 206 confirmed that `drainDueTimersWith` cannot be a
  database-only standalone command: its callback is the application's process-manager
  dispatch. This plan therefore owns a timer-fire hook and conditionally mounts
  `timer drain-once`; no-hook command trees omit it.
- 2026-08-09: The ownership re-audit found two previously mounted EP-3 commands were
  not valid standalone operations. Kiroku's `subscriptionStates` is process-local
  and normally empty on a fresh CLI store, while Keiro's projection-position helper
  reads Kiroku's private subscription table. Both commands were removed and now wait
  for `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2`; none of this
  plan's application hooks depends on that external API.
- 2026-08-09: Keeping `AppHooks` alongside, rather than inside, `OpsEnv` leaves the
  database execution environment unchanged for existing handlers. The parser uses
  hook presence only to mount commands, and the dispatcher passes the matching hook
  only to the code-dependent handler.


## Decision Log

- Decision: The rebuild command mounts `ProjectionCatalogOperations` from MasterPlan 32 rather than an
  application-supplied `Map Text (OpsEnv -> IO ExitCode)`.
  Rationale: Applications still own schema, handlers, and verification, but Keiro's validated
  catalog and replay runner own safe discovery, fencing, clear/preserve policy, fixed-head replay,
  progress, and promotion. A free-form map would retain a second rebuild inventory and bypass the
  command's ability to render an honest preview. If this plan lands before plans 209–213, the
  rebuild command remains absent until that typed hook is available; do not ship the map as a
  temporary public contract.
  Date: 2026-08-07

- Decision: Retain command parsing, rendering, preview/`--force`, JSON, exit codes, and embedding
  in `keiro-ops`; keep `ProjectionCatalogOperations` operator-neutral in `keiro`.
  Rationale: Runtime rebuild invariants belong with the runtime, while presentation and operator
  policy belong with the operations package. This preserves the MasterPlan's no-invented-SQL rule.
  Date: 2026-08-07

- Decision: Add `resumeWorkflowsOnceUpTo` to the owning workflow runtime and make
  `resumeWorkflowsOnce` delegate to it with `maxBound`.
  Rationale: The operator command promises one bounded pass; truncating only the
  rendered summary would be dishonest, while duplicating the resume worker in the
  CLI would violate the supported-API boundary.
  Date: 2026-08-09

- Decision: Omit hook-dependent commands from the parser when a hook is absent.
  Rationale: A standalone binary must not advertise operations it cannot perform,
  and conditional parsing makes the help text an accurate capability inventory.
  Date: 2026-08-09


## Outcomes & Retrospective

Completed on 2026-08-09. `Keiro.Ops` now exposes one command tree and runner for
both the standalone binary and application embedding. `AppHooks` conditionally
mounts a workflow registry, timer fire action, replay-audit targets, and
`ProjectionCatalogOperations`; no parallel command parser or rebuild inventory
exists. Workflow resume and timer draining are bounded and previewed before force,
replay audit preserves its CI exit code while emitting versioned JSON, and rebuild
list/preview/start/status/resume/abandon render the operator-neutral catalog reports.

`jitsurei-demo ops` mounts its real workflow registry, workflow-sleep timer action,
audit targets, and order catalog. The runbook is now command-first and explicitly
distinguishes standalone from candidate-binary operations. It also records the
checkpoint-inventory boundary rather than suggesting direct Kiroku SQL.

Verification passed with 27 `keiro-ops-test`, 441 `keiro-test`, 58
`keiro-pgmq-test` (2 expected pending), 615 `keiro-dsl-test`, 22
`jitsurei-test`, and 28 `keiro-migrations-test` examples, plus the complete
`just verify` policy, corpus, diagrams, and OKF gates.


## Context and Orientation

Prerequisite reading: plan 206's Context (package layout, `OpsEnv`, rails); this
plan extends that package. The three code-dependent capabilities being mounted:

Resume: `Keiro.Workflow.Resume.resumeWorkflowsOnce` takes
`WorkflowResumeOptions` and a `WorkflowRegistry es` (`Map WorkflowName
(WorkflowDef es)`; `WorkflowDef` holds `WorkflowId -> Eff (Workflow : es) a`) and
returns a `ResumeSummary` (discovered/resumed/completed/stillSuspended/
unknownName/failed/transientErrors/leaseSkipped) — already the perfect one-shot
command backend. The registry's effect row must be pinned for embedding the same
way `runWorkflowResumeWorkerPush` pins it: `'[Store, Error StoreError, IOE]`
interpreted by `Kiroku.Store.Effect.runStoreIO` from
`mori://shinzui/kiroku/packages/kiroku-store` (see
`keiro/src/Keiro/Workflow/Resume.hs`).

Replay audit: `Keiro.ReplayAudit` exports `auditStream`/`auditStreams`/
`auditTargets`, `renderAuditReport`, `auditExitCode`, and `defaultAuditBudget`;
the deploy-gate pattern (run targeted or full audits inside the *candidate*
binary and exit nonzero on drift) is documented in
`docs/user/replay-safety.md`. The embedding hook carries the application's audit
target configuration.

Rebuild: [MasterPlan 32](../masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md)
and [plan 213](213-adopt-projection-catalogs-in-operations-examples-and-migration-guidance.md)
replace independent application lists with `ProjectionCatalogOperations`. The application still supplies
the validated catalog, target schema, live/replay handlers, and verification hooks; Keiro supplies
the safe operation. This plan mounts and renders that adapter and does not inspect application
tables or invent SQL.

Docs to flip at the end: `docs/user/operations.md` (the runbook — §Timers
stuck-row runbook, §Durable Workflows operational tasks, §Stream Truncation,
§Production Checklist all become command narratives with the library APIs kept as
reference links); `docs/guides/durable-workflows.md` and
`docs/user/durable-workflows.md` (operator sections point at `wf` commands — if
MasterPlan 30's plan 204 landed, its scale-posture sections are the anchor to
extend, not duplicate); `docs/user/roadmap.md` ("Operator CLIs" sits in the
Longer-term Possibilities table today; move it into the capability matrix as
available); `docs/user/production-status.md` (adoption posture gains the
console); the repository `README.md` package list. Coordinate with plan 204's
text if both are in flight — MasterPlan 30 and 31 both touch the user docs, and
whichever lands second reconciles.

The embedding precedent to mirror in `jitsurei`: it already has executables
(`jitsurei-demo`, `jitsurei/jitsurei.cabal`) wired to a real store; mounting the
ops tree there is both the demonstration and the acceptance vehicle.

ADR context per `agents/skills/exec-plan/ADR.md`: the operator-command contract
ADR from plan 206 already states that code-dependent operations live behind the
embedding surface; this plan implements that clause and cites the record from the
new module haddocks. No new ADR expected.


## Plan of Work

### Milestone 1 — the embedding surface

In `keiro-ops`, add `Keiro.Ops.Embed`:

```haskell
data AppHooks = AppHooks
  { registry :: !(Maybe (WorkflowRegistry '[Store, Error StoreError, IOE], WorkflowResumeOptions)),
    timerFire :: !(Maybe (TimerRow -> Eff '[Store, Error StoreError, IOE] (Maybe EventId))),
    auditTargets :: !(Maybe OpsAuditConfig),   -- streams/categories + budget for Keiro.ReplayAudit
    projectionCatalog :: !(Maybe ProjectionCatalogOperations)
  }

emptyAppHooks :: AppHooks

opsCommandTree :: AppHooks -> ParserInfo (OpsEnv -> IO ExitCode)
```

(Exact shapes may be adjusted during implementation; the invariants are: hooks
are all optional; commands whose hook is absent do not appear in `--help` at
all rather than failing at run time; and the standalone binary is exactly
`opsCommandTree emptyAppHooks`.) Refactor `app/Main.hs` onto that equation so
there is one command tree, not two. Extend `OpsEnv` only if a hook needs it —
this plan owns that extension per MasterPlan 31's Integration Points.

### Milestone 2 — the code-dependent commands

`timer drain-once [--limit n]` — one bounded `drainDueTimersWith` pass through
the mounted timer fire action, reporting how many timers were processed and
requiring `--force`. The command is absent when the hook is absent.

`wf resume-once [--limit n]` — one `resumeWorkflowsOnce` pass through the
mounted registry, rendering the `ResumeSummary` (and honoring the schema
handshake like any mutation: resume executes application code, so it requires
`--force` if drift was detected). `replay-audit [--target …|--full]
[--budget …]` — wrap `auditTargets`/`auditStreams` + `renderAuditReport`,
exiting via `auditExitCode` so CI can use the embedded command as the deploy
gate directly. `rebuild --list`, preview/start, status, resume, and abandon render and invoke the
mounted `ProjectionCatalogOperations`. The exact subcommand spelling follows the frozen EP-2 command
conventions. List and preview are read-only. Start/resume/abandon require the schema handshake,
preview, and `--force`; the adapter, not the CLI, resolves groups, targets, sources, and handlers.

### Milestone 3 — jitsurei embedding

Add an `ops` subcommand to `jitsurei-demo` (or a dedicated `jitsurei-ops`
executable if the demo's argument surface fights optparse composition — decide
and log): mount `opsCommandTree` with jitsurei's real registry and validated projection catalog.
Acceptance transcript: run a jitsurei workflow to suspension with
the demo, then `jitsurei-demo ops wf list`, `… ops wf resume-once`, `… ops
replay-audit --target <its stream>`, and catalog list/preview/rebuild/status, each also with
`--json`. Plan 213 owns the catalog fixture and its brownfield/multi-target assertions; this plan
owns command mounting and rendering.

### Milestone 4 — the documentation flip

Per the inventory in Context: rewrite the runbook procedures as command
narratives (keep function names as "the API behind this command" references so
REPL operation remains documented), add an "Operating keiro" orientation section
to `docs/user/operations.md` introducing standalone-vs-embedded and the safety
rails, update the durable-workflows guide/reference operator sections, move
"Operator CLIs" in `docs/user/roadmap.md` from Longer-term Possibilities into
the capability matrix ("Available now — `keiro-ops`; embedded via
`opsCommandTree`"), add the production-status posture line, and list the package
in `README.md`. Add `keiro-ops` to `keiro/CHANGELOG.md`-adjacent release notes
per the repo's changelog convention (the package likely warrants its own
`keiro-ops/CHANGELOG.md` — follow the sibling packages' pattern).

### Tests

Handler-level: `opsCommandTree emptyAppHooks` hides the hook-dependent commands;
mounting a timer fire action surfaces `timer drain-once` and a seeded due timer
is dispatched and marked fired;
mounting a registry surfaces `wf resume-once`, and a pass over a seeded
suspended-then-signalled workflow reports `completed = 1`; mounting a validated catalog surfaces
only its group identities, and a rebuild without `--force` previews without creating a run;
`replay-audit` against a seeded stream returns exit 0 and, with a deliberately
broken decoder in a test-only registry, nonzero. Text and JSON reports are rendered from the same
operator-neutral values. The jitsurei transcript supplements automated assertions in plan 213.


## Concrete Steps

All commands run from the repository root.

```bash
cabal build keiro-ops jitsurei
cabal test keiro-ops-test
cabal run jitsurei-demo -- ops --help     # after Milestone 3
just verify
```

Commit per milestone:

```text
feat(ops): embeddable command tree with resume, audit, and rebuild mounts

MasterPlan: docs/masterplans/31-build-the-keiro-ops-operational-cli.md
ExecPlan: docs/plans/208-make-keiro-ops-embeddable-and-document-the-operational-surface.md
Intention: intention_01kzagac32ehp93amx1sfar2ab
```


## Validation and Acceptance

Acceptance is the jitsurei transcript (Milestone 3) plus the docs reading test:
an adopter reading only `docs/user/operations.md` can operate a deployment with
the standalone binary, knows which operations require embedding and how to mount
the tree (copying jitsurei's example), and finds every runbook procedure as a
command. The initiative-level acceptance from MasterPlan 31 — "the runbook is
the CLI" — is checked here: every procedure in the pre-change operations.md maps
to a command or is explicitly documented as application-owned. Rebuild acceptance additionally
requires no parallel name-to-action map, read-only list/preview, `--force` on mutations, stable JSON,
and exact agreement with the mounted catalog's groups and plan-213 run reports.


## Idempotence and Recovery

Additive package work plus docs. The embedding refactor keeps the standalone
binary's behavior byte-compatible (`opsCommandTree emptyAppHooks`); if the
refactor regresses it, the plan-206 smoke test catches it. Docs edits are
reversible; coordinate with MasterPlan 30's plan 204 on shared files as noted.


## Interfaces and Dependencies

End-state additions: `Keiro.Ops.{AppHooks, emptyAppHooks, OpsAuditConfig,
opsCommandTree, runOpsInvocation, mainWithHooks}`; `AppHooks` optionally mounts
the timer fire action and
`Keiro.Projection.Catalog.Operations.ProjectionCatalogOperations`; `jitsurei` gains an ops mount and a
dependency on `keiro-ops`.
This plan owns the application-hook boundary while keeping `OpsEnv` unchanged;
plans 206/207's modules are consumed unchanged. Soft dependency on plan 207 for
the docs flip only — the embedding mechanics need nothing from it. The projection rebuild command
consumes the adapter landed by MasterPlan 32 plans 211 and 213; no free-form
substitute was published.


Revision note: Replaced the proposed free-form rebuild map with the validated projection-catalog
operations adapter coordinated by MasterPlan 32, 2026-08-07.

Revision note: Reconciled the design with the landed `ProjectionCatalogOperations` interface and
recorded the still-absent `keiro-ops` integration gate, 2026-08-08.
