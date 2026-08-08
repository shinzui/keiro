---
id: 206
slug: create-the-keiro-ops-package-with-the-workflow-and-timer-command-domains
title: "Create the keiro-ops package with the workflow and timer command domains"
kind: exec-plan
created_at: 2026-08-06T03:02:06Z
intention: "intention_01kzagac32ehp93amx1sfar2ab"
master_plan: "docs/masterplans/31-build-the-keiro-ops-operational-cli.md"
---

# Create the keiro-ops package with the workflow and timer command domains

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro's operational procedures are library calls with no console. This plan creates
`keiro-ops`: a new package whose library is an operational command tree and whose
executable is the standalone, database-only console. After it lands, an operator
with a connection string can run `keiro-ops wf list --status failed`,
`keiro-ops wf show <name> <id>`, `keiro-ops wf journal <name> <id>`,
`keiro-ops wf cancel --force <name> <id>`, `keiro-ops wf resurrect --force <name>
<id>`, `keiro-ops timer stuck list`, `keiro-ops timer requeue --force <timer-id>`,
and the rest of the workflow and timer domains — with aligned human-readable tables
by default, `--json` on every command for scripting, an affected-rows preview plus
`--force` on every mutation, and a schema handshake that warns (and refuses
mutations) when the binary's expected schema and the database's migration
generation diverge.

The plan also freezes the conventions every later domain follows (module layout,
environment type, rendering, safety rails) and records the initiative's
constitutional rules as an ADR: operator commands wrap supported library APIs only,
and no command touches another library's tables directly.


## Progress

- [x] (2026-08-08T23:42:49Z) Package scaffolding: `keiro-ops.cabal`, `cabal.project` entry, nix wiring, empty command tree runs.
- [ ] Core: `OpsEnv`, connection/config plumbing, output layer (tables + `--json`), `--force` rail, schema handshake.
- [ ] Workflow domain complete (list/show/journal/awakeables/children/cancel/resurrect/lease-release/gc-once).
- [ ] Timer domain complete (stuck list/requeue/cancel/dead-letter/drain-once).
- [ ] ADR for the operator-command contract recorded; `just adr-validate` green.
- [ ] `cabal test keiro-ops-test` green; full repo suite unaffected.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Command handlers are library functions (`Keiro.Ops.*`) taking `OpsEnv`
  and returning structured results; the optparse layer only parses and renders.
  Rationale: Tests drive the handler functions directly against ephemeral
  Postgres without spawning binaries, and plan 208's embedding reuses the same
  handlers under an application's own binary.
  Date: 2026-08-06

- Decision: The schema handshake reuses
  `Keiro.Migrations.SchemaCheck.verifyExpectedSchema` rather than a version
  probe of its own.
  Rationale: `docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md`
  already makes that machinery the single authority on live-schema agreement;
  a second checker would drift.
  Date: 2026-08-06

- Decision: Add `keiro-ops` only to `cabal.project`; do not add package-specific
  Nix wiring.
  Rationale: `flake.nix` and `nix/haskell.nix` provide a dev shell and explicitly
  do not enumerate or build project packages. Cabal is the package graph authority.
  Date: 2026-08-08


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is a new package in a multi-package cabal project (`cabal.project` at the
repository root lists `keiro-core`, `keiro`, `keiro-dsl`, `keiro-pgmq`,
`keiro-migrations`, `keiro-test-support`, `jitsurei`). Two existing executables
set the conventions to copy: `keiro-migrate`
(`keiro-migrations/keiro-migrations.cabal`, `keiro-migrations/app/Main.hs`) —
optparse-applicative, `Hasql.Connection.Settings` for connection configuration,
environment-variable fallbacks via `lookupEnv` — and the `keiro-dsl` executable
(`keiro-dsl/keiro-dsl.cabal`) for optparse bounds (`>=0.18 && <0.20`). Check how
existing packages are wired into the nix build (`grep -rn 'keiro-pgmq' nix/
flake.nix`) and mirror whatever enumeration exists; if the flake discovers
packages from `cabal.project`, no nix edit is needed — verify by `nix build` or
the repository's `just verify` gate.

The domains this plan implements wrap these existing APIs. Workflow instances:
`Keiro.Workflow.Instance` — `lookupInstance`, and from
`docs/plans/205-add-workflow-listing-top-level-cancellation-and-lease-release-operator-apis.md`
(hard dependency): `listWorkflowInstances` + `WorkflowInstanceFilter`,
`cancelWorkflow` + `CancelWorkflowOutcome`, `forceReleaseInstanceLease`, plus the
existing `resurrectFailedWorkflow` + `ResurrectOutcome`. Workflow detail:
`Keiro.Workflow.Schema.loadStepIndex` (step name → JSON result map per
generation), `currentGeneration`; journal dump via
`Kiroku.Store.Read.readStreamForwardStream` over
`workflowGenerationStreamName` (`Keiro.Workflow.Types`) decoded with
`Keiro.Codec.decodeRecorded workflowJournalCodec` — journal payloads are
self-describing JSON, so rendering needs no application codecs. Related rows:
`Keiro.Workflow.Child.Schema.lookupChildrenOfParent`/`lookupChild`,
`Keiro.Workflow.Awakeable.Schema.lookupAwakeable` (point) and the pending gauge
count; awakeable mutation via `Keiro.Workflow.Awakeable.signalAwakeable` /
`cancelAwakeable`. GC one-shot: `Keiro.Workflow.Gc.gcWorkflowsOnce` +
`WorkflowGcPolicy`. Timers: `Keiro.Timer` — `findStuckTimers` +
`StuckTimerFilter`/`anyStuckTimer`, `requeueStuckTimer`, `cancelTimer`,
`deadLetterTimer`, and for one-shot draining `runTimerWorkerWith` (single claim
per call) or, if MasterPlan 30's plan 203 has landed, `drainDueTimersWith`
(batched) — implement `timer drain-once --limit n` against whichever exists,
looping the single-claim worker otherwise. The timer runbook this encodes is
`docs/user/operations.md` §"Stuck-row recovery runbook".

The schema handshake: `Keiro.Migrations.SchemaCheck` exports
`verifyExpectedSchema` and `renderSchemaDrift` (used today by `keiro-migrate` —
see `keiro-migrations/app/Main.hs` imports), the machinery of
`docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md`.

Store access: commands run in the same effect stack the libraries use —
`Kiroku.Store.Connection.withStore` (which also starts the notifier) or the
lighter connection path `keiro-migrate` uses; choose during implementation and
record which (the workflow/timer domains need only `Store` + `Error StoreError` +
`IOE`, interpreted by `Kiroku.Store.Effect.runStoreIO`).

ADR context per `agents/skills/exec-plan/ADR.md`: the bundle is profile-governed
OKF (`docs/adr/profile.dhall`; allocate with `okf id next`, log with `okf log
add`, gate with `just adr-validate`). Relevant existing records: ADR 9 (schema
verification authority — consumed by the handshake), ADR 8 (resurrection is the
supported revival path — `wf resurrect` wraps it), ADR 6/7 (why mutations must go
through library paths). This plan *creates* the operator-command contract record
(working title: "Operator commands wrap supported library APIs and respect schema
ownership"): mutating commands call exported library functions only; no
cross-library table access; destructive commands preview and require `--force`;
the standalone binary is database-only and code-dependent operations live behind
the embedding surface (plan 208).

MasterPlan 31 Integration Points to respect: this plan owns the package, the
`OpsEnv` type, the per-domain module convention, and the render/`--json` helpers;
plan 207 adds domains without touching the core; plan 208 extends `OpsEnv` with
application hooks — leave that extension point open (e.g. keep `OpsEnv` a record
that can grow fields additively) but do not design it here.


## Plan of Work

### Milestone 1 — package scaffolding

Create `keiro-ops/` with `keiro-ops.cabal` (library `Keiro.Ops`, `Keiro.Ops.Env`,
`Keiro.Ops.Render`, `Keiro.Ops.Workflow`, `Keiro.Ops.Timer`; executable
`keiro-ops` with a one-line `app/Main.hs` calling the library's entry;
test-suite `keiro-ops-test`). Dependencies: `keiro`, `keiro-migrations`,
`kiroku-store`, `optparse-applicative >=0.18 && <0.20`, `aeson`, `text`,
`hasql`, `effectful`, and `keiro-test-support` for the test-suite (copy bounds
from the neighboring cabal files; `keiro-pgmq` is *not* a dependency until plan
207 adds its domain). Add the package to `cabal.project`; wire nix as discovered
in Context. Acceptance: `cabal run keiro-ops -- --help` prints a command tree
with the two (empty) domains.

### Milestone 2 — core conventions

`Keiro.Ops.Env`: the environment every handler takes —

```haskell
data OutputMode = HumanTable | Json

data OpsEnv = OpsEnv
  { store :: !KirokuStore,
    outputMode :: !OutputMode,
    force :: !Bool,
    schemaDrift :: !(Maybe Text)   -- rendered drift, when the handshake found any
  }
```

Connection configuration: `--database-url` (hasql settings string) with
`KEIRO_OPS_DATABASE_URL` / standard `PG*` environment fallbacks, matching the
`keiro-migrate` idiom. On startup, run the schema handshake
(`verifyExpectedSchema`): on drift, print `renderSchemaDrift` output as a warning
for read-only commands and *refuse* mutating commands unless
`--allow-schema-drift` is also given. Global flags: `--json`, `--force`,
`--allow-schema-drift`.

`Keiro.Ops.Render`: one rendering seam — every handler returns a value with both
a table shape (header + rows) and a `ToJSON` instance; `render :: OpsEnv ->
OpsResult -> IO ()` picks by mode. Mutating handlers follow the two-phase rail:
without `--force`, run only the read side and print the rows that *would* be
affected plus the exact re-invocation with `--force`; with `--force`, perform the
mutation and print what happened. Exit codes: 0 success, 1 operational failure
(refused mutation, drift refusal), 2 usage.

Write the ADR (allocate id via `okf id next`; content per Context) in this
milestone so the domain implementations cite it. Update `docs/adr/log.md` via
`okf log add`; `just adr-validate`.

### Milestone 3 — workflow domain

`Keiro.Ops.Workflow`, commands under `keiro-ops wf …`:

`list` (`--status <s>...`, `--name <n>`, `--after <name> <id>`, `--limit`) over
`listWorkflowInstances`, rendering id/name/generation/status/attempts/
lease/wake_after/updated_at columns. `show <name> <id>` — instance row plus
child links and awakeable summary. `steps <name> <id> [--generation g]` — the
step index via `loadStepIndex` (defaults to `currentGeneration`). `journal <name>
<id> [--generation g]` — the decoded journal stream in order (event type, step
name, timestamp, payload; payload pretty-printed, truncated for tables, full
under `--json`). `awakeable show <uuid>` / `awakeable signal --force <uuid>
--payload <json>` / `awakeable cancel --force <uuid>` over the
`Keiro.Workflow.Awakeable` surface. `cancel --force <name> <id>` over
`cancelWorkflow`, rendering the `CancelWorkflowOutcome` honestly. `resurrect
--force <name> <id>` over `resurrectFailedWorkflow`. `lease release --force
<name> <id>` over `forceReleaseInstanceLease`. `gc run-once --retention <dur>
--batch <n> [--force]` over `gcWorkflowsOnce` (the preview phase lists eligible
instances via the same eligibility the GC uses — if plan 203's honest summary has
landed, render scanned/deleted distinctly).

### Milestone 4 — timer domain

`Keiro.Ops.Timer`, commands under `keiro-ops timer …`: `stuck list [--min-age d]
[--min-attempts n]` over `findStuckTimers`; `requeue --force <timer-id>`,
`cancel --force <timer-id>`, `dead-letter --force <timer-id> --reason <text>`
over their namesake APIs; `drain-once [--limit n]` over the drain backend
described in Context, reporting how many fired. Encode the runbook's guidance in
`--help` text (when to requeue vs cancel vs dead-letter), citing
`docs/user/operations.md`.

### Tests (`keiro-ops-test`)

Handler-level, against ephemeral Postgres via `keiro-test-support`: seed
workflows/timers using the keiro library directly, then drive the `Keiro.Ops.*`
handler functions and assert on their structured results (not on rendered text) —
listing filters and paging, journal decode of a real workflow run, cancel/
resurrect/lease-release outcomes, preview-vs-force two-phase behavior (preview
mutates nothing), drift refusal (simulate by pointing at a database missing a
keiro table), and the timer triage loop (make a timer stuck by claiming it
directly, then requeue and observe it fire). One end-to-end smoke test spawns the
actual binary with `--json` against the test database and asserts parseable
output, so the optparse wiring is covered.


## Concrete Steps

All commands run from the repository root.

```bash
cabal build keiro-ops
cabal run keiro-ops -- --help
cabal test keiro-ops-test
just adr-validate
just verify            # confirm repo-wide gates still pass with the new package
```

Commit per milestone:

```text
feat(ops): create keiro-ops with the workflow and timer command domains

MasterPlan: docs/masterplans/31-build-the-keiro-ops-operational-cli.md
ExecPlan: docs/plans/206-create-the-keiro-ops-package-with-the-workflow-and-timer-command-domains.md
Intention: intention_01kzagac32ehp93amx1sfar2ab
```


## Validation and Acceptance

Beyond the test suite, acceptance is a transcript against a scratch database
(the ephemeral test store or a `just`-provisioned dev database): run a jitsurei
or test workflow to suspension, then demonstrate `wf list` showing it,
`wf journal` dumping its steps, `wf cancel` (preview, then `--force`), `wf list
--status cancelled` confirming, and a stuck-timer round trip (`timer stuck list`
→ `timer requeue --force` → gone). Every command shown twice: human table and
`--json | jq .` — include the transcript in this plan's Outcomes when done.


## Idempotence and Recovery

The package addition is additive; nothing in existing packages changes except
`cabal.project`. Every mutating command wraps an idempotent library API, so
re-running a `--force` command is safe (re-cancel reports already-terminal,
re-requeue is a no-op, re-release returns false). The preview phase is the
recovery story for operator error: nothing mutates without `--force`, and the
preview shows exactly the affected rows first.


## Interfaces and Dependencies

New package `keiro-ops` depending on `keiro`, `keiro-migrations`, `kiroku-store`
(and test-only `keiro-test-support`). End-state library surface: `Keiro.Ops`
(entry + command tree), `Keiro.Ops.Env` (`OpsEnv`, `OutputMode`),
`Keiro.Ops.Render`, `Keiro.Ops.Workflow`, `Keiro.Ops.Timer`. Hard dependency:
plan 205's APIs consumed unchanged. Plans 207/208 extend this package; the
core module set and `OpsEnv` shape are theirs to consume, not redefine
(MasterPlan 31 Integration Points).
