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
(`Keiro.ReplayAudit` is *designed* to run inside it), and read-model rebuilds are
application-owned procedures. This plan closes that gap the way the MasterPlan's
design dictates: the command tree becomes an embeddable library surface, so an
application mounts the entire console into its own executable —
`yourapp ops wf resume-once …`, `yourapp ops replay-audit …`, `yourapp ops rebuild
<model>` — gaining the code-dependent commands next to every database-only one,
with identical flags, rendering, and safety rails.

It also performs the documentation flip that ends the initiative: the operational
runbook stops describing REPL procedures and starts naming commands, `jitsurei`
demonstrates the embedding for adopters to copy, and the user roadmap moves
"Operator CLIs" from longer-term possibility to available.


## Progress

- [ ] Embedding surface: `AppHooks`, `opsCommandTree`, standalone binary refactored onto it.
- [ ] Code-dependent commands: `wf resume-once`, `replay-audit`, `rebuild` mount point.
- [ ] `jitsurei` embeds the console; transcript captured.
- [ ] Docs flip: operations.md, durable-workflows guide/reference, roadmap.md, production-status.md, README.
- [ ] `cabal test keiro-ops-test` and full repo `just verify` green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The rebuild command is a *mount point* (`Map Text (OpsEnv -> IO
  ExitCode)` supplied by the application), not a keiro-implemented procedure.
  Rationale: Read-model rebuild strategies are application-owned by design
  (`docs/user/roadmap.md` Phase 4 lists the migration guide as such); the CLI
  standardizes discovery (`rebuild --list`) and invocation, nothing more.
  Date: 2026-08-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


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
interpreted by `Kiroku.Store.Effect.runStoreIO` (see
`keiro/src/Keiro/Workflow/Resume.hs`).

Replay audit: `Keiro.ReplayAudit` exports `auditStream`/`auditStreams`/
`auditTargets`, `renderAuditReport`, `auditExitCode`, and `defaultAuditBudget`;
the deploy-gate pattern (run targeted or full audits inside the *candidate*
binary and exit nonzero on drift) is documented in
`docs/user/replay-safety.md`. The embedding hook carries the application's audit
target configuration.

Rebuild: `docs/user/read-models-and-projections.md` and the rebuild scaffolding
in `keiro/src/Keiro/ReadModel/` describe application-owned rebuild flows (the
test suite exercises one at `keiro/test/Main.hs` "rebuild repopulates the
projection table through the supported workflow"). The CLI ships invocation
plumbing only (Decision Log).

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
    auditTargets :: !(Maybe OpsAuditConfig),   -- streams/categories + budget for Keiro.ReplayAudit
    rebuilds :: !(Map Text (OpsEnv -> IO ExitCode))
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

`wf resume-once [--limit n]` — one `resumeWorkflowsOnce` pass through the
mounted registry, rendering the `ResumeSummary` (and honoring the schema
handshake like any mutation: resume executes application code, so it requires
`--force` if drift was detected). `replay-audit [--target …|--full]
[--budget …]` — wrap `auditTargets`/`auditStreams` + `renderAuditReport`,
exiting via `auditExitCode` so CI can use the embedded command as the deploy
gate directly. `rebuild --list` / `rebuild --force <name>` — dispatch into the
`rebuilds` map.

### Milestone 3 — jitsurei embedding

Add an `ops` subcommand to `jitsurei-demo` (or a dedicated `jitsurei-ops`
executable if the demo's argument surface fights optparse composition — decide
and log): mount `opsCommandTree` with jitsurei's real registry and one example
rebuild hook. Acceptance transcript: run a jitsurei workflow to suspension with
the demo, then `jitsurei-demo ops wf list`, `… ops wf resume-once`, `… ops
replay-audit --target <its stream>`, each also with `--json`.

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

Handler-level: `opsCommandTree emptyAppHooks` hides the three commands;
mounting a registry surfaces `wf resume-once`, and a pass over a seeded
suspended-then-signalled workflow reports `completed = 1`; `rebuild --list`
renders the mounted names and `rebuild` without `--force` previews only;
`replay-audit` against a seeded stream returns exit 0 and, with a deliberately
broken decoder in a test-only registry, nonzero. The jitsurei transcript is
manual acceptance recorded in Outcomes, not CI.


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
to a command or is explicitly documented as application-owned.


## Idempotence and Recovery

Additive package work plus docs. The embedding refactor keeps the standalone
binary's behavior byte-compatible (`opsCommandTree emptyAppHooks`); if the
refactor regresses it, the plan-206 smoke test catches it. Docs edits are
reversible; coordinate with MasterPlan 30's plan 204 on shared files as noted.


## Interfaces and Dependencies

End-state additions: `Keiro.Ops.Embed.{AppHooks, emptyAppHooks, opsCommandTree,
OpsAuditConfig}`; `jitsurei` gains an ops mount and a dependency on `keiro-ops`.
This plan owns the `OpsEnv` extension point (MasterPlan 31 Integration Points);
plans 206/207's modules are consumed unchanged. Soft dependency on plan 207 for
the docs flip only — the embedding mechanics need nothing from it.
