---
id: 328
slug: serve-the-jitsurei-aggregate-and-process-manager-hooks-from-a-runnable-keiro-ops-http-host
title: "Serve the jitsurei aggregate and process-manager hooks from a runnable keiro-ops-http host"
kind: exec-plan
created_at: 2026-11-04T13:12:06Z
intention: "intention_01m6kb02rwet3a1vc05xyww47t"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-04T13:12:06Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-04T14:07:24Z
      verdict: "changes-requested"
      note: "Shared-host design matches the source; require a non-deletion assertion for preview and safe configured-database recovery; fix the shell ID placeholder."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-04T14:16:09Z
      mode: "update"
      note: "Apply review fixes to Cabal targets, preview state assertions, configured-database recovery, and correlation-id input."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-04T14:35:15Z
      mode: "implement"
      note: "Implement the shared HTTP host, jitsurei executable, integration acceptance, and documentation."
---


# Serve the jitsurei aggregate and process-manager hooks from a runnable keiro-ops-http host

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Creating this plan implements nothing.


## Purpose / Big Picture


After this change, a developer who has seeded the local `jitsurei` database with
`just jitsurei-all` can run `just jitsurei-ops-http` in a second terminal and get an HTTP
server on `127.0.0.1:9092` that answers `GET /aggregate/types` with jitsurei's two aggregate
kinds (`incident` and `order`), `GET /aggregate/show?name=order&id=<id>` with the hydrated
state of an order the demo wrote, `GET /pm/list?name=jitsurei-fulfillment` with the
fulfillment process-manager instances the demo drove, and
`GET /pm/show?name=jitsurei-fulfillment&correlation=<id>` with one instance's folded state
and pending timers. Today those routes exist nowhere an operator can start: both runnable
hosts in this repository mount `emptyAppHooks`, so the aggregate and process-manager
routes are reachable only inside the `keiro-ops-http` test suite.

The new executable is `jitsurei-ops-http`, built from the internal `jitsurei-ops-http` example package. It
accepts exactly the flags of the standalone `keiro-ops-http` executable (`--database-url`,
`--bind`, `--port`, repeatable `--allow-origin`, `--enable-mutations`,
`--allow-schema-drift`, `--request-timeout`) and serves every route `keiro-ops-http` serves
with the same schema verification, origin rules and mutation gate, plus the hook-gated
routes, because both executables run the same exported host function with different
`AppHooks`. A browser console such as the keiro runtime console can therefore point its
local stack at `jitsurei-ops-http` instead of `keiro-ops-http` and record real
`/aggregate/*` and `/pm/*` responses instead of deriving fixtures by hand.

This implements [IR-55](../improvement-requests/provide-a-runnable-inspection-host-that-mounts-the-jitsurei-aggregate-and-process-manager-hooks.md),
filed by the keiro runtime console initiative
(`mori://shinzui/keiro-ui/masterplans/2-build-the-keiro-runtime-console`, from
`mori://shinzui/keiro-ui/plans/9-provision-the-local-runtime-stack-and-recorded-fixtures`).
It is a standalone plan, not a child of the inspection cohort's
[MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md),
whose remaining work is the lockstep release in Plan 303; the keiro-ui plans do not depend on
this work either (their console is built against hand-derived fixtures until a host exists,
then re-recorded).


## Progress


- [x] Milestone 1 (2026-11-04): exported and re-exported `Keiro.Ops.Http.Host`; the standalone executable calls `mainWithHooks emptyAppHooks`. Baseline help is byte-identical (`diff` passed), and the unchanged HTTP suite passed 53 examples with zero failures. IR-55 is accepted and linked; strict validation passed for all 60 requests.
- [x] Milestone 2 (2026-11-04): `Jitsurei.Ops` shares all six hooks between the CLI and the new executable in the internal `jitsurei/ops-http` package. The recipe seeded a fresh `keiro_ir55_acceptance_20261104_328` database and served on port 19092. The four hook requests returned 200: the order was `packed` with state/stream version 3 and the fulfillment instance was visible; mutation POST returned 403. Help flags match after normalizing program name and its continuation indentation; the embedded CLI still lists `aggregate` and `pm`.
- [x] Milestone 3 (2026-11-04): `jitsurei-ops-http-test` passed all three in-process examples using ephemeral databases, comparing aggregate/manager handler JSON and checking health, disabled mutations, exact origins, preview, and unchanged complete stream metadata. Added the connection-aware fixture helper and registered the suite in `just verify`. The existing jitsurei suite passed 25 examples and `keiro-test` passed 786 examples with zero failures.
- [x] Milestone 4 (2026-11-04): updated both runbooks, all three affected changelogs, and ADR-53 (including the package-cycle constraint); completed IR-55 with a resolution and bundle log. Final strict validation passed for 32 guide concepts, 58 ADRs, and 60 requests. `nix develop -c just verify` exited 0 on the implemented candidate, including all suites, the new host suite, disposable demo run, symbolic tests (Z3 4.16.0), mutation proofs, and documentation/policy gates. The build with tests and benchmarks enabled also passed.


## Surprises & Discoveries


- 2026-11-04 (implementation): Cabal rejects an HTTP executable/test dependency
  inside `jitsurei`, because `keiro-ops-http` already depends on jitsurei in its
  test suite and inspection benchmark. The solver reports `Cabal-7107` with
  `cyclic dependencies; conflict set: jitsurei, keiro-ops-http`. Component-level
  library acyclicity is insufficient for this package graph. The executable
  and its host integration suite therefore live in the separate internal
  package `jitsurei/ops-http`; existing HTTP tests and benchmark stay unchanged.

- 2026-11-04 (planning): IR-55 says the host should construct `AppHooks` "from
  `jitsurei/src/Jitsurei/Inspection.hs`", but jitsurei's complete hook record already exists
  as `jitsureiOpsHooks` in `jitsurei/app/Main.hs` (lines 104-113) and mounts four more hooks
  than the two inspector catalogs: `workflowResume`, `timerFire`, `replayAudit` and
  `projectionCatalog`. `jitsurei-demo ops` serves that full set on the CLI. Mounting only
  the two catalogs over HTTP would make the HTTP surface narrower than the CLI for the same
  application, contradicting ADR-53's rule that mounted hooks, not the transport, determine
  which commands exist. The Decision Log records mounting the full record.
- 2026-11-04 (planning): The `jitsurei` library does not depend on `keiro-ops`; only the
  demo executable and the test suite do. Moving `jitsureiOpsHooks` into the library adds
  `keiro-ops` to the library's `build-depends`. This creates no dependency cycle: nothing in
  `keiro-ops` (library, executable or test suite) depends on `jitsurei`, and `jitsurei` is an
  internal package that is never released (see
  [Plan 303](303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md),
  which lists the released packages).
- 2026-11-04 (planning): The keiro runtime console's local stack
  (`mori://shinzui/keiro-ui/plans/9-provision-the-local-runtime-stack-and-recorded-fixtures`)
  runs the standalone `keiro-ops-http` on port 9093 at root paths behind a Vite proxy that
  maps `/keiro` to it, and passes `--allow-origin http://localhost:5173`. A host that serves
  root paths with the same flags is a drop-in replacement there; a flag on the compose
  example, which prefixes keiro under `/keiro` and mounts kiroku beside it, is not.


## Decision Log


- Decision: Place the `jitsurei-ops-http` executable and integration suite in an
  internal package at `jitsurei/ops-http`, with the shared hooks remaining in
  `Jitsurei.Ops` in the jitsurei library. Register the new suite in `just verify`.
  Rationale: This removes the observed Cabal package cycle while preserving the
  executable name, public host API, recipe, and all behavioral acceptance. It
  also preserves the existing HTTP tests and inspection benchmark unchanged.
  Date: 2026-11-04.

- Decision: Factor the standalone executable's `main` into an exported library module,
  `Keiro.Ops.Http.Host`, and make both `keiro-ops-http` and `jitsurei-ops-http` call its
  `mainWithHooks` with their own `AppHooks`, instead of copying `keiro-ops-http/app/Main.hs`
  into jitsurei.
  Rationale: IR-55's third acceptance criterion is that every route `keiro-ops-http` serves is
  served identically (same schema check, origin rules, mutation gate). Sharing one function
  makes that true by construction and keeps it true when the standalone executable changes.
  It mirrors `Keiro.Ops.mainWithHooks`, which is how `jitsurei-demo ops` already reuses the
  CLI. The library already depends on everything the executable needs
  (`optparse-applicative`, `keiro-migrations`, `async`, `hasql`, `kiroku-store`).
  Date: 2026-11-04.
- Decision: Ship a dedicated executable `jitsurei-ops-http` beside the `jitsurei` package (the internal package split above supersedes the
  original placement), not a flag on `keiro-ops-http-compose-example`.
  Rationale: IR-55 asks for a host that can "replace the standalone server in a local stack
  without other changes"; the keiro-ui stack runs the standalone server at root paths. The
  compose example is flag-gated, composes kiroku beside keiro, and prefixes keiro under
  `/keiro`, so it is not a drop-in. The hooks are jitsurei's, so the executable that mounts
  them belongs to jitsurei, beside `jitsurei-demo` and `jitsurei-diagrams`.
  Date: 2026-11-04.
- Decision: Mount jitsurei's complete `jitsureiOpsHooks` (workflow resume, timer fire,
  replay audit, projection catalog, aggregates, process managers), moved from
  `jitsurei/app/Main.hs` into a new library module `Jitsurei.Ops`, so `jitsurei-demo ops` and
  `jitsurei-ops-http` share one definition. The HTTP host passes `Nothing` for metrics,
  exactly as `jitsurei-demo ops` does.
  Rationale: The HTTP surface is a transport over the command tree (ADR-53); the same
  application must expose the same commands on both transports. The extra mutation routes
  (`wf resume`, `timer fire`, `rebuild start`, and so on) stay behind the existing
  `--enable-mutations` gate and per-request confirmation, so the default host is still
  read-only.
  Date: 2026-11-04.
- Decision: Prove the host with an in-process test in `jitsurei-ops-http-test` that calls `withHost`
  on port 0 against an ephemeral database, rather than spawning the executable and parsing
  its banner.
  Rationale: `withHost` returns the bound port directly, closes its connections before the
  fixture drops the database, and exercises the identical code path the executable runs
  minus argument parsing. The executable's flag surface is checked separately by diffing
  `--help` output against `keiro-ops-http`. The test needs a fixture that supplies both a
  seeding runner with the jitsurei projection schema on the search path and the clone's
  connection string; `keiro-test-support` gains that one helper rather than the test copying
  the fixture's internals.
  Date: 2026-11-04.
- Decision: Out of scope: a process-compose entry for the host, any change in the keiro-ui
  repository, a new ADR, and any change to runtime, migration, or wire code. ADR-53 receives
  a two-sentence amendment recording the exported host; no benchmark gate is required
  because no runtime path changes (see Validation).
  Date: 2026-11-04.


## Outcomes & Retrospective


All four milestones are complete. Developers can seed the example with
`just jitsurei-all`, then run `just jitsurei-ops-http` to inspect real aggregates
and fulfillment instances over HTTP with the standalone host's flags and gates.
The CLI and HTTP executable share the complete `Jitsurei.Ops.jitsureiOpsHooks`;
application binaries can reuse the exported `Keiro.Ops.Http.Host` lifecycle.

The only architectural adjustment was placing the executable and its integration
suite in the internal `jitsurei/ops-http` package. Cabal's package graph rejects
putting them directly in jitsurei because the HTTP package already uses jitsurei
in its tests and benchmark. This preserves those existing consumers unchanged.
ADR-53 now records the shared host boundary and this lasting package constraint;
no new ADR was needed. Runtime, migration, and wire implementations were untouched.

Acceptance was observed against a fresh demo database on port 19092: `incident`
and `order` discovery, a `packed` order with state/stream version 3, its fulfillment
instance and pending-timer page, and 403 for a default mutation. The new ephemeral
host suite additionally proves handler JSON agreement and complete stream-metadata
preservation after origin refusal and allowed preview. The full Nix verification
passed; there is no remaining implementation work.


## Context and Orientation


Keiro is a Haskell event-sourcing library. `keiro-ops` (directory `keiro-ops/`) is its
operator command-line tool: a tree of commands such as `wf list`, `aggregate show` and
`pm show` that read or change a deployment's PostgreSQL state. Some commands need
application code that the generic binary cannot have, for example the display encoder for an
aggregate's state. Applications supply that code through a record called `AppHooks`, defined
in `keiro-ops/src/Keiro/Ops/Embed.hs`, with six optional fields: `workflowResume`,
`timerFire`, `replayAudit`, `projectionCatalog`, `aggregates` and `processManagers`. A
`Nothing` field removes the dependent commands from the tree; `emptyAppHooks` is the
all-`Nothing` record the standalone binary uses. `Keiro.Ops.mainWithHooks :: AppHooks -> IO ()`
in `keiro-ops/src/Keiro/Ops.hs` is how an application binary serves the CLI with its hooks.

`keiro-ops-http` (directory `keiro-ops-http/`) serves that same command tree over HTTP as
JSON. Its library builds a WAI `Application` (the standard Haskell web-application type) from
an `OpsHttpConfig`, an `AppHooks` and a database store: `opsApplication` and
`opsApplicationWithFeeds` in `keiro-ops-http/src/Keiro/Ops/Http/Application.hs` and
`keiro-ops-http/src/Keiro/Ops/Http/WebSocket.hs`. Paths are command words
(`/aggregate/show`) and query keys are options (`?name=order&id=…`). Reads use GET;
mutations use POST and are refused with 403 `mutations_disabled` unless the host enables
them, in which case a POST without a confirmation body is a preview and a POST with exactly
`{"confirm":"execute"}` executes. Every admitted request first verifies that the live
PostgreSQL schema matches the binary's expected schema and refuses with 409 `schema_drift`
otherwise. A present `Origin` header on a mutation must match the `--allow-origin` list or
the request's own scheme and host, or the request fails with 403 `origin_not_allowed`.
`/health` reports `{"status":"ok","schema_drift":[],"mutations_enabled":false}` on a migrated
database. These rules are the "schema check, origin rules, and mutation gate" IR-55 names.

The package has two runnable hosts. `keiro-ops-http/app/Main.hs` is the standalone
executable `keiro-ops-http`: it parses the flags listed in Purpose with
`optparse-applicative`, resolves the database with `resolveConnectionString` from
`keiro-ops/src/Keiro/Ops/Env.hs` (explicit `--database-url`, then `KEIRO_OPS_DATABASE_URL`,
then `DATABASE_URL`, then libpq defaults), runs `verifyExpectedSchema` once at startup and
prints drift warnings, opens an inspection-owned connection pool with `withOpsInspectionPool`
(`keiro-ops-http/src/Keiro/Ops/Http/Pool.hs`), opens the WebSocket feed handle with
`withFeedHandle` (`keiro-ops-http/src/Keiro/Ops/Http/Feed.hs`), builds the application with
`opsApplicationWithFeeds config feeds emptyAppHooks store`, starts Warp with
`withOpsHttpServer` (`keiro-ops-http/src/Keiro/Ops/Http/Server.hs`, which returns an
`OpsHttpServer` record with `serverThread` and the bound `serverPort`), prints
`keiro-ops-http: listening on 127.0.0.1:9092 (mutations disabled)` to stderr, and waits.
`keiro-ops-http/example/Compose.hs` is `keiro-ops-http-compose-example`, built only with the
cabal flag `compose-example` (enabled in `cabal.project`); it mounts keiro under `/keiro` and
kiroku's metrics surface under `/kiroku` on one listener. Both pass `emptyAppHooks`, so
neither serves `/aggregate/*` or `/pm/*`. The configuration types live in
`keiro-ops-http/src/Keiro/Ops/Http/Config.hs`: `OpsHttpConfig { mutations, schemaDrift,
allowedOrigins, inspectionLimits }` with `defaultOpsHttpConfig`, and
`OpsHttpServerConfig { bindHost, port, requestTimeoutSeconds }` with
`defaultOpsHttpServerConfig` (`127.0.0.1`, 9092, 300). Port 0 asks the operating system for
a free port, which `serverPort` then reports.

`jitsurei` (directory `jitsurei/`) is the repository's worked-example application: an order
aggregate, an incident aggregate, a fulfillment process manager named
`jitsurei-fulfillment`, durable workflows, timers and a projection catalog. It is a local
package in `cabal.project` and is never published. `jitsurei/src/Jitsurei/Inspection.hs`
defines `jitsureiAggregateInspectors` (kinds `order` and `incident`) and
`jitsureiProcessManagerInspectors` (one entry, `jitsurei-fulfillment`). The demo executable
`jitsurei-demo` (`jitsurei/app/Main.hs`) has an `ops` subcommand (line 82) that calls
`Ops.mainWithHooks (jitsureiOpsHooks Nothing)`; `jitsureiOpsHooks :: Maybe
Telemetry.KeiroMetrics -> Ops.AppHooks` (lines 104-113) fills all six hook fields from
library values: `jitsureiWorkflowRegistry` (`Jitsurei.DurableWorkflow`),
`workflowSleepFireAction` (`Keiro.Workflow.Sleep`), `replayAuditTargets`
(`Jitsurei.ReplayAudit`), `orderCatalogOperations` (`Jitsurei.ReadModels`) and the two
inspector catalogs. Its `workflowResume` field also needs `workflowResumeOptions metrics`
(lines 138-144 of the same file), which sets the resume worker's run options from an optional
metrics handle; the durable-workflow demo reuses that helper at line 482. The umbrella module
`jitsurei/src/Jitsurei.hs` re-exports every library module. The `jitsurei` library's
`build-depends` in `jitsurei/jitsurei.cabal` does not include `keiro-ops`; the `jitsurei-demo`
executable and `jitsurei-test` suite do.

`just jitsurei-all` (recipe in `Justfile`, group `jitsurei`) starts the repository-local
PostgreSQL cluster under `db/`, creates the database named by `JITSUREI_DATABASE` (default
`jitsurei`), runs `keiro-migrate up` against it, and runs every demo. The fulfillment demo
writes an order with id `demo-<timestamp>` to stream `order-demo-<timestamp>`, drives the
fulfillment process manager for it, and leaves a journal stream
`fulfillment-demo-<timestamp>`; the process manager's correlation id is the order id. The
recipes pass the connection string as `host=db dbname=jitsurei user=<whoami>` through
`PG_CONNECTION_STRING`; the HTTP hosts take the same string through `--database-url`.

Tests use `keiro-test-support/src/Keiro/Test/Postgres.hs`: `withMigratedSuiteWith` starts an
ephemeral PostgreSQL and a migrated template database once per suite, and
`withFreshDatabase fixture` clones it, passes the clone's connection string, and drops the
clone (with `FORCE`) afterwards. `withFreshResourceStoreWith fixture modify` opens one
resource-aware store (a `KirokuStore` plus a `StoreRunner` that interprets Keiro's command
runners) on a clone, but does not pass the clone's connection string; only the two-store
variant `withFreshResourceStoresSameDatabaseWithConnection` does, and neither accepts both a
settings modifier and the connection string. `jitsurei/test/Main.hs` wraps the suite as
`withJitsureiSuite` (adding the pgmq migrations) and already contains, at line 768, a `Jitsurei process manager` test that seeds
`order-100` with `samplePlaceOrder` and `sampleApprovePayment`, runs `runFulfillmentOnce`,
and compares `Ops.runCommand` JSON for `pm show` and `pm list`; at line 759 an aggregate test
compares `aggregate show` JSON the same way. `keiro-ops-http/test/Main.hs` holds the HTTP
transport tests, including `seedInspection` (line 782) and a CLI-agreement test (line 679)
that spawns the `keiro-ops` executable found with `cabal list-bin`.

Documentation is governed by OKF bundles with strict validation. `docs/guides/` uses
`mori/user-documentation-profile.dhall`; its documents carry `docId` (`DOC-N`) and a
`timestamp` that must advance on every edit, matched by an `okf log add docs/guides` entry,
or `just user-documentation-validate` fails. `docs/adr/` uses `docs/adr/profile.dhall` with the
same rule (`just adr-validate`). `docs/improvement-requests/` uses
`mori/improvement-requests-profile.dhall`; its bundle precedent (IR-5, IR-56, IR-57 in
`docs/improvement-requests/log.md`) links an accepted request with `status: accepted`, a
`plan:` path and an `Update` log entry, and closes it with `status: completed`,
`completedAt`, `resolution` and a `Completion` log entry. Changelogs with an `[Unreleased]`
section are `CHANGELOG.md` (whole package set, where jitsurei entries are written as
`**jitsurei**: …`) and `keiro-ops-http/CHANGELOG.md`.

### Relevant ADRs


[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
sanctions HTTP inspection as a bounded exception to keiro's no-UI stance: sister packages
export a bare application plus a convenience runner; keiro ships no bundled console; every
route is a rendering of a supported command; mutations preview then confirm; read/write
classification is mechanical. This plan adds no new route, dependency or capability; it
mounts existing hooks in an example host and exports the existing executable's main.
[ADR-53](../adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md)
records that `keiro-ops-http` exports an application constructor, a Warp runner and a
database-only executable, and that "mounted application hooks determine which commands
exist". Milestone 4 amends it to say the executable is `mainWithHooks emptyAppHooks` over an
exported host module that application binaries reuse.
[ADR-54](../adr/0054-aggregate-inspection-reuses-hydration-without-diagnostics-on-the-command-path.md)
records that applications explicitly supply aggregate descriptors and display encoders and
that "hosts decide which state they expose"; jitsurei's catalogs are such descriptors.
[ADR-57](../adr/0057-compose-allocated-inspection-applications-without-changing-their-routes.md)
records the compose example's shape and that the kiroku dependency stays behind a default-off
flag; it explains why this plan does not extend that example. No cross-repository ADR is
cited.


## Plan of Work


### Milestone 1: export the standalone host from keiro-ops-http


Create `keiro-ops-http/src/Keiro/Ops/Http/Host.hs` and list it under `exposed-modules`.
Move the body of `keiro-ops-http/app/Main.hs` into it, unchanged in behaviour, as four
exports. `HostOptions` is a record with `databaseUrl :: Maybe Text`, `http :: OpsHttpConfig`
and `server :: OpsHttpServerConfig`. `hostOptionsParser :: Parser HostOptions` is the
existing `options` parser (same flag names, metavars and defaults). `withHost :: HostOptions
-> AppHooks -> (OpsHttpServer -> IO a) -> IO a` resolves the connection string, verifies the
schema (exiting with the error on `Left`, printing `warning: …` per drift on `Right`), opens
the store, pool and feed handle, builds the application with `opsApplicationWithFeeds`, and
runs the continuation inside `withOpsHttpServer`. `mainWithHooks :: AppHooks -> IO ()` runs
`execParser` with the existing `progDesc`, calls `withHost`, prints the banner, and waits on
`server.serverThread`. Build the banner's prefix from `System.Environment.getProgName` so
the same code prints `keiro-ops-http: listening on …` or `jitsurei-ops-http: listening on …`.
Re-export the module from `keiro-ops-http/src/Keiro/Ops/Http.hs`. Reduce
`keiro-ops-http/app/Main.hs` to a `main` that calls `mainWithHooks emptyAppHooks`, and trim
the executable stanza's `build-depends` to `base`, `keiro-ops` and `keiro-ops-http`.

At the end, `cabal run keiro-ops-http:exe:keiro-ops-http -- --help` prints exactly what it printed before the
change, the executable still starts and serves `/health`, and `cabal test keiro-ops-http-test`
passes unchanged. Also link IR-55 to this plan as described in Concrete Steps.

### Milestone 2: the jitsurei host and its recipe


Create `jitsurei/src/Jitsurei/Ops.hs` exporting `jitsureiOpsHooks :: Maybe
Telemetry.KeiroMetrics -> Ops.AppHooks`, `jitsureiWorkflowRunOptions` and
`jitsureiWorkflowResumeOptions`, moved from `jitsurei/app/Main.hs` (lines 104-113 and
138-144). Add `keiro-ops ^>=0.23.0.0` to the library's `build-depends`, add the module to
`exposed-modules`, and re-export it from `jitsurei/src/Jitsurei.hs`. In `jitsurei/app/Main.hs`
delete the moved definitions and use the library names (the `ops` subcommand and the
durable-workflow demo at line 482 are the two call sites). Keep the demo's observable output
identical.

Create internal package `jitsurei/ops-http/jitsurei-ops-http.cabal`, registered in
`cabal.project`, with an executable stanza `jitsurei-ops-http` and
`hs-source-dirs: app`, `main-is: Main.hs`, the package's `warnings` and `shared`
common stanzas, the same `-threaded -rtsopts -with-rtsopts=-N` options as `jitsurei-demo`,
and `build-depends` of `base`, `jitsurei` and `keiro-ops-http ^>=0.23.0.0`. The file
`jitsurei/ops-http/app/Main.hs` is a few lines: import `Jitsurei.Ops (jitsureiOpsHooks)` and
`Keiro.Ops.Http (mainWithHooks)`, and define `main = mainWithHooks (jitsureiOpsHooks Nothing)`.

Add a recipe to `Justfile` in the `jitsurei` group that depends on `jitsurei-migrate` (so
the cluster is running and the database exists and is migrated, idempotently) and runs the
executable against the jitsurei database, forwarding extra arguments:

```just
[group('jitsurei')]
jitsurei-ops-http *args: jitsurei-migrate
    cabal run jitsurei-ops-http -- --database-url "host={{pg_host}} dbname={{jitsurei_database}} user={{pg_user}}" {{args}}
```

At the end, the curl transcript in Validation succeeds against a database seeded by
`just jitsurei-all`, and `--help` output matches `keiro-ops-http` except for the program name and help continuation indentation.

### Milestone 3: the in-process host test


First add one helper to `keiro-test-support/src/Keiro/Test/Postgres.hs` beside
`withFreshResourceStoreWith`: `withFreshResourceStoreWithConnection :: Fixture ->
(ConnectionSettings -> ConnectionSettings) -> (Text -> (KirokuStore, StoreRunner) -> IO a) ->
IO a`, implemented as `withFreshDatabase fixture \connStr -> runResourceStore (modify
(defaultConnectionSettings connStr)) (action connStr)`, exported, and recorded under
`[Unreleased]` in `keiro-test-support/CHANGELOG.md` (a public addition to a released package).
If that is undesirable, the fallback is to build the runner inside the test with
`withKirokuStore`, `getKirokuStore` and `runStoreResource`, copying the eight lines of
`runResourceStore`; prefer the helper.

Add a `Jitsurei ops HTTP host` group to `jitsurei/ops-http/test/Main.hs` in
`jitsurei-ops-http-test`, and add that suite to `Justfile`'s `haskell-test` recipe, using
`withFreshResourceStoreWithConnection fixture (withProjectionSchema jitsureiProjectionSchema)`
so the test has the `StoreRunner` for seeding, with the projection schema on the search path
as the `Jitsurei process manager` test requires, and the clone's connection string for the
host (`around` needs the two arguments packed into one tuple). Seed exactly as that test does
(`initializeJitsureiTables`, `samplePlaceOrder`, `sampleApprovePayment`, one
`runFulfillmentOnce` for `PaymentApproved`). Then call `withHost HostOptions { databaseUrl =
Just url, http = defaultOpsHttpConfig, server = defaultOpsHttpServerConfig { port = 0 } }
(jitsureiOpsHooks Nothing)` and, with an `http-client` manager, request `http://127.0.0.1:<serverPort>` paths. Assert: `/health` is 200
with `status` `ok` and `mutations_enabled` `false`; `/aggregate/types` is 200 and its `items`
names are `["incident","order"]`; `/aggregate/show?name=order&id=order-100` is 200 and its
`name`, `aggregate_id`, `stream_name`, `stream_version`, `state_label` and `state` equal the
same keys of `Ops.runCommand hooks env (Ops.Aggregate (OpsAggregate.Show (OpsAggregate.ShowOptions
"order" "order-100")))` (the pattern at line 759); `/pm/list?name=jitsurei-fulfillment` is
200 with one item whose `correlation_id` is `order-100`;
`/pm/show?name=jitsurei-fulfillment&correlation=order-100` is 200 and its `state`,
`last_reaction` and `waiting_for` equal the handler's (the pattern at line 817; do not
compare `observed_at`); `POST /stream/soft-delete/order-order-100` is 403 with error code
`mutations_disabled`. Then open a second `withHost` on the same database with `mutations =
MutationsEnabled` and `allowedOrigins = ["http://ui.example"]`. Before either POST, GET
`/stream/show/order-order-100`, require 200, and save its `stream` object; assert its
`exists` is `true` and `deleted_at` is JSON `null`. The same POST with header
`Origin: http://evil.example` is 403 `origin_not_allowed`, and with `Origin: http://ui.example`
and an empty body is 200 with `outcome` `preview`. After each POST, GET
`/stream/show/order-order-100` again, require 200, and compare the entire `stream` object
with the saved value, including `exists: true` and `deleted_at: null`. A successful GET
alone cannot prove non-deletion: `Keiro.Ops.Stream.streamInfoJson` in
`keiro-ops/src/Keiro/Ops/Stream.hs` also describes missing and soft-deleted streams.
Add `keiro-ops-http ^>=0.23.0.0`, `http-client`,
`http-types` and `bytestring` to the test suite's `build-depends`.

At the end, `cabal test jitsurei-ops-http-test --test-show-details=direct` passes with the new group
listed.

### Milestone 4: documentation, changelogs, ADR amendment, closure


Add a section `## See the hook-gated routes locally` to
`docs/guides/serve-keiro-ops-over-http.md` after "Request mapping and confirmation". It says
that the standalone executable mounts no application catalogs, that `jitsurei-ops-http`
(built from `jitsurei/ops-http/app/Main.hs` with `mainWithHooks (jitsureiOpsHooks Nothing)`) is
the runnable host that does, shows `just jitsurei-all` then `just jitsurei-ops-http` and the
four curl requests from Validation with their observed shapes, notes `just jitsurei-ops-http
--port 9093 --allow-origin http://localhost:5173` for a console on another origin, and
states that an application binary gets the same flags and gates by calling
`Keiro.Ops.Http.mainWithHooks` with its own hooks. Update the existing sentence "The
standalone database-only server has no application catalogs." to point at the new section.
In `docs/guides/run-and-operate-jitsurei.md`, extend the paragraph that begins "For read-only
inspection with the embedded hooks" with `just jitsurei-ops-http` and a link to the new
section. Advance both documents' `timestamp` values and add one `okf log add docs/guides`
entry naming both.

Amend `docs/adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md`:
in the Decision section's first paragraph, after "a database-only executable", add that the
executable is `mainWithHooks emptyAppHooks` over the exported `Keiro.Ops.Http.Host`, and that
an application binary serving its own hooks calls the same function so flags, verification,
origin policy and the mutation gate cannot diverge; add `jitsurei-ops-http` to the
Consequences as the worked example. Advance `timestamp` and add an `okf log add docs/adr`
entry.

Add to `keiro-ops-http/CHANGELOG.md` under `[Unreleased]` a `### New Features` entry for the
exported host module and the executable's reduction to it; to `keiro-test-support/CHANGELOG.md`
under `[Unreleased]` an entry for `withFreshResourceStoreWithConnection` if Milestone 3 added
it; and to `CHANGELOG.md` under `[Unreleased]` a `**jitsurei**:` entry for `jitsurei-ops-http`,
`Jitsurei.Ops` and the recipe. The HTTP executable and its test suite live in
the internal package `jitsurei/ops-http` to avoid the existing HTTP test/benchmark
dependency back to jitsurei. Close IR-55 as the bundle precedent does. Run the full
verification.


## Concrete Steps


All commands run from the repository root inside the Nix shell. Either prefix each with
`nix develop -c` or run `nix develop` once and then the bare commands. The creation baseline
is commit `d0ab94e3878c7b52ad7ed291bed81f7540ef2031`.

### Before editing


Capture the standalone executable's help text so Milestone 1 can prove it unchanged, and
confirm the baseline suites pass:

```bash
mkdir -p /tmp/ir55
cabal run -v0 keiro-ops-http:exe:keiro-ops-http -- --help > /tmp/ir55/keiro-ops-http-help.baseline.txt
cabal test keiro-ops-http-test --test-show-details=direct
cabal test jitsurei-test --test-show-details=direct
```

Expected: a help text that begins `Usage: keiro-ops-http [--database-url URL]` and lists
`--enable-mutations`, `--allow-schema-drift`, `--allow-origin ORIGIN`, `--bind`, `--port`
and `--request-timeout`; both suites end with `0 failures`. The baseline file lives outside
the tracked tree on purpose; any other untracked location works.

### Milestone 1


Link IR-55 first. Edit
`docs/improvement-requests/provide-a-runnable-inspection-host-that-mounts-the-jitsurei-aggregate-and-process-manager-hooks.md`:
set `status: accepted`, add
`plan: docs/plans/328-serve-the-jitsurei-aggregate-and-process-manager-hooks-from-a-runnable-keiro-ops-http-host.md`
after `requestId`, advance `timestamp` to the current UTC time, and replace the first
sentence of the `## Status` section with "Accepted; implemented by
[ExecPlan 328](../plans/328-serve-the-jitsurei-aggregate-and-process-manager-hooks-from-a-runnable-keiro-ops-http-host.md)."
Then:

```bash
okf log add docs/improvement-requests --kind Update -m "IR-55 accepted under ExecPlan 328: jitsurei-ops-http serves jitsurei's full AppHooks through an exported keiro-ops-http host."
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
```

Expected: the validation ends with `OK: 60 concepts`.

Create `keiro-ops-http/src/Keiro/Ops/Http/Host.hs` as described in Plan of Work, register it,
re-export it, and reduce `keiro-ops-http/app/Main.hs`. The shape of the new module's exports:

```haskell
module Keiro.Ops.Http.Host (HostOptions (..), hostOptionsParser, withHost, mainWithHooks) where

data HostOptions = HostOptions
  { databaseUrl :: !(Maybe Text),
    http :: !OpsHttpConfig,
    server :: !OpsHttpServerConfig
  }

hostOptionsParser :: Parser HostOptions
withHost :: HostOptions -> AppHooks -> (OpsHttpServer -> IO a) -> IO a
mainWithHooks :: AppHooks -> IO ()
```

Format with `nix fmt` (treefmt runs Fourmolu with the repository's `fourmolu.yaml`) and verify:

```bash
cabal build keiro-ops-http:lib:keiro-ops-http keiro-ops-http:exe:keiro-ops-http
diff /tmp/ir55/keiro-ops-http-help.baseline.txt <(cabal run -v0 keiro-ops-http:exe:keiro-ops-http -- --help) && echo HELP-UNCHANGED
cabal test keiro-ops-http-test --test-show-details=direct
```

Expected: no diff output, the word `HELP-UNCHANGED`, and `0 failures`. Commit with a
`feat(ops-http):` subject and the `ExecPlan:` and `Intention:` trailers from Git Trailers.

### Milestone 2


Create `jitsurei/src/Jitsurei/Ops.hs`, update `jitsurei/jitsurei.cabal`, `jitsurei/src/Jitsurei.hs`
and `jitsurei/app/Main.hs`, create `jitsurei/ops-http/app/Main.hs` and its internal
package manifest, register `jitsurei/ops-http` in `cabal.project`, and add the Justfile recipe.
Then build and compare the flag surfaces:

```bash
cabal build jitsurei:lib:jitsurei jitsurei:exe:jitsurei-demo jitsurei-ops-http:exe:jitsurei-ops-http
diff <(cabal run -v0 keiro-ops-http:exe:keiro-ops-http -- --help | sed 's/keiro-ops-http/HOST/g' | xargs) <(cabal run -v0 jitsurei-ops-http -- --help | sed 's/jitsurei-ops-http/HOST/g' | xargs) && echo FLAGS-IDENTICAL
cabal run -v0 jitsurei-demo -- ops --help | grep -E 'aggregate|pm '
```

Expected: `FLAGS-IDENTICAL`, and the demo's `ops --help` still lists the `aggregate` and `pm`
command groups.

Seed and serve. In one terminal:

```bash
just jitsurei-all
just jitsurei-ops-http
```

Expected: the demos print their transcripts, then the second command prints
`jitsurei-ops-http: listening on 127.0.0.1:9092 (mutations disabled)` and keeps running. In a
second terminal, run the Validation transcript below. Stop the server with Ctrl-C. Commit with
a `feat(jitsurei):` subject and both trailers.

### Milestone 3


Add the test-support helper, the test group and the dependencies, then:

```bash
cabal build keiro-test-support
cabal test jitsurei-ops-http-test --test-show-details=direct 2>&1 | grep -A 12 'Jitsurei ops HTTP host'
cabal test jitsurei-ops-http-test
cabal test jitsurei-test
cabal test keiro-test
```

Expected: the group's examples are listed with check marks, both jitsurei suites end with
`0 failures`, and `keiro-test` (the largest consumer of `Keiro.Test.Postgres`) still passes.
Commit with a `test(jitsurei):` subject and both trailers.

### Milestone 4


Edit the two guides, ADR-53, the two changelogs, and close IR-55 (`status: completed`,
`completedAt`, a `resolution` paragraph naming the executable, module, recipe and guide
section, and the `## Status` sentence). Then:

```bash
okf log add docs/guides --kind Update -m "DOC-30, DOC-22: name jitsurei-ops-http as the runnable host for the hook-gated aggregate and process-manager routes (Plan 328)."
okf log add docs/adr --kind Update -m "ADR-53: the database-only executable is mainWithHooks emptyAppHooks over the exported Keiro.Ops.Http.Host, reused by application binaries such as jitsurei-ops-http (Plan 328)."
okf log add docs/improvement-requests --kind Completion -m "IR-55 completed under ExecPlan 328: jitsurei-ops-http, Jitsurei.Ops, the just jitsurei-ops-http recipe, and the serve-keiro-ops-over-http guide section."
just user-documentation-validate
just adr-validate
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
just verify
```

Expected: each validation ends with `OK`, and `just verify` completes without a failing
recipe. `just verify` runs the whole build, every test suite, the disposable jitsurei demo
through `scripts/verify-jitsurei.sh`, and the documentation gates; it takes a long time and
needs the Nix shell (check `z3 --version` inside it first, as `AGENTS.md` requires). Commit
with a `docs(ops-http):` subject and both trailers, then fill Outcomes & Retrospective.


## Validation and Acceptance


### Acceptance transcript against the seeded database


With `just jitsurei-all` finished and `just jitsurei-ops-http` running:

```bash
curl -fsS http://127.0.0.1:9092/health
curl -fsS http://127.0.0.1:9092/aggregate/types
curl -fsS 'http://127.0.0.1:9092/pm/list?name=jitsurei-fulfillment&limit=5'
```

Expected: `{"status":"ok","schema_drift":[],"mutations_enabled":false}`; an `items` array
with two rows whose `name` values are `incident` and `order`; and an `items` array with at
least one row whose `correlation_id` begins with `demo-`. Run the following `read`, paste
one complete correlation id (including `demo-`), and press Enter before running the curls:

```bash
read -r ID
curl -fsS "http://127.0.0.1:9092/aggregate/show?name=order&id=$ID"
curl -fsS "http://127.0.0.1:9092/pm/show?name=jitsurei-fulfillment&correlation=$ID"
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "http://127.0.0.1:9092/stream/soft-delete/order-$ID"
```

Expected: the aggregate body has `"name":"order"`, `"aggregate_id":"demo-…"`,
`"stream_name":"order-demo-…"`, a non-null `state` object with a `state` field, a
`state_version` equal to `stream_version`, and a `hydration` object; the process-manager body
has `"name":"jitsurei-fulfillment"`, `"correlation_id":"demo-…"`, a `state`, a
`last_reaction`, and a `pending_timers` page; the POST prints `403`. These satisfy IR-55's acceptance items 1 and 2.

### Route parity


IR-55's third item, that every route `keiro-ops-http` serves is served identically, is
established by construction: both executables call `Keiro.Ops.Http.mainWithHooks`, which
runs one `withHost`, so schema verification, origin comparison, mutation gating, admission
limits and feed mounting are the same code. The observable checks are the `--help` diff in
Milestone 2 (same flags, same defaults) and the Milestone 3 assertions (`/health`, 403
`mutations_disabled`, 403 `origin_not_allowed`, 200 preview with unchanged stream metadata). The existing
`keiro-ops-http-test` suite remains the gate for the transport rules themselves and must pass
unchanged after Milestone 1.

### Guarantees that must not weaken


Schema-drift gating: unchanged code, proven by `keiro-ops-http-test` (its drift cases) and by
`/health` reporting `schema_drift: []` from the new host. Origin exactness and the mutation
gate: unchanged code, proven by `keiro-ops-http-test` and the Milestone 3 403 cases;
Milestone 3 also checks unchanged stream metadata after origin rejection and preview,
including existence and a null deletion timestamp. Wire
bytes: the hook routes return the ops handlers' JSON values unchanged, proven by the
Milestone 3 key-for-key comparisons against `Ops.runCommand` and by the existing CLI-agreement
test in `keiro-ops-http-test`. Fold identity and snapshots: not touched; no file under
`keiro/`, `keiro-core/` or `keiro-migrations/` changes. Performance: no runtime, writer, query
or encoder path changes, so no benchmark guard is rerun; if any file under `keiro/src` is
touched during implementation, record that in Surprises & Discoveries and run
`just bench-regression` before closing.


## Idempotence and Recovery


The implementation steps are additive. `just jitsurei-ops-http` can be restarted at any time;
it holds no state beyond its connections. `just jitsurei-all` appends new demo orders on each
run, so repeated seeding adds instances. If `/health` reports `schema_drift` or the host
exits at startup with a schema error, inspect the reported error first. Check the effective
`--database-url`, `PGHOST`, `PGUSER`, and `JITSUREI_DATABASE` against the intended target,
then check connectivity, privileges, and whether migrations from the current checkout have
been applied. A schema error alone does not establish a version mismatch or justify deleting
a database. Run `just jitsurei-migrate` against the intended target when pending migrations
are the cause, then retry the host.

For a clean reproduction, preserve the existing database and seed a fresh disposable one.
Stop the old host first. From the repository root in the Nix shell, run the following in
one terminal; both recipes inherit the same database name and honor the existing `PGHOST`
and `PGUSER` settings:

```bash
export JITSUREI_DATABASE="keiro_ir55_$(date +%Y%m%d%H%M%S)_$$"
printf 'Disposable acceptance database: %s\n' "$JITSUREI_DATABASE"
just jitsurei-all
just jitsurei-ops-http
```

Run the acceptance curls in a second terminal, then stop the host with Ctrl-C. Keep the
printed database name for any later cleanup; this procedure does not drop or reset the
original database. If port 9092 is taken, pass `just jitsurei-ops-http --port 9093` and use
9093 in the curl URLs (just forwards dash-prefixed arguments to a variadic recipe without a
separator). Re-running an `okf log add` for the same change adds a duplicate log line; remove
the extra line from the bundle's `log.md` before validating. Commits keep independently buildable boundaries; the internal host package
and its integration fixture may land together because they share one manifest
and verification recipe.


## Interfaces and Dependencies


New public API in `keiro-ops-http` (minor-version addition under the PVP, recorded in its
changelog): module `Keiro.Ops.Http.Host` exporting `HostOptions (..)`, `hostOptionsParser`,
`withHost` and `mainWithHooks`, re-exported from `Keiro.Ops.Http`. No existing export
changes. The executable `keiro-ops-http` keeps its flags, defaults, banner and exit behaviour.

New in the jitsurei example packages (internal, never published): library module `Jitsurei.Ops` exporting
`jitsureiOpsHooks :: Maybe KeiroMetrics -> AppHooks`, `jitsureiWorkflowRunOptions` and
`jitsureiWorkflowResumeOptions`; library dependency `keiro-ops ^>=0.23.0.0`; executable
`jitsurei-ops-http` depending on `base`, `jitsurei`, `keiro-ops-http ^>=0.23.0.0`; integration suite `jitsurei-ops-http-test` in the same new package, with
dependencies `keiro-ops-http`, `http-client`, `http-types`, `bytestring`. The Justfile gains
`jitsurei-ops-http *args`.

New in `keiro-test-support` (released; minor-version addition recorded in its changelog):
`Keiro.Test.Postgres.withFreshResourceStoreWithConnection`, the one-store counterpart of the
existing `withFreshResourceStoresSameDatabaseWithConnection`, taking a connection-settings
modifier and passing the clone's connection string to the action.

Unchanged dependencies whose behaviour this plan relies on: `Kiroku.Store.Connection`
(`withStore`, `defaultConnectionSettings`, `poolSize`, `statementTimeout`) from
`mori://shinzui/kiroku/packages/kiroku-store`; `Keiro.Migrations.SchemaCheck.verifyExpectedSchema`;
`Keiro.Ops.Env.resolveConnectionString`; `optparse-applicative`, `async`, `http-client`.


## Revision Notes


2026-11-04: Applied the review findings: qualify standalone Cabal run targets to avoid
Cabal-7070, require unchanged stream metadata to prove preview and origin rejection leave
the stream intact, replace automatic database deletion with diagnosis and a fresh configured
database, and use interactive input for the complete correlation id in the curl transcript.
The architecture and implementation scope are unchanged.

2026-11-04: Implementation exposed a Cabal package dependency cycle. Isolated the
HTTP executable and host tests in `jitsurei/ops-http`, retaining the planned
command, hook sharing, gates, and acceptance checks.
