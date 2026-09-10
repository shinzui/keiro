---
id: 276
slug: serve-the-keiro-ops-surface-over-http
title: "Serve the keiro-ops surface over HTTP"
kind: exec-plan
created_at: 2026-09-10T01:48:17Z
intention: "intention_01m24fzbdrevnasj0zm1y199vw"
---

# Serve the keiro-ops surface over HTTP

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today an operator inspects and repairs a Keiro deployment with `keiro-ops`, a command-line
console. Every command it offers renders into one typed envelope, classifies itself as a read
or a mutation, previews a mutation before it will perform it, and refuses to act when the live
database schema disagrees with the binary. A browser cannot invoke a command line, so the
planned Keiro runtime UI (`mori://shinzui/keiro-ui`) has no way to reach that surface.

After this change a new package, `keiro-ops-http`, serves the same command tree over HTTP as
JSON. It exports a bare WAI `Application` that a Keiro application mounts next to its other
routes using the same `AppHooks` value it already mounts for the CLI, plus a convenience Warp
runner and a standalone `keiro-ops-http` executable for the database-only command set. Every
read-only command answers a `GET`; every mutation answers a `POST` that first returns the
preview and performs nothing, and only executes when the body carries the confirmation value
`"execute"`. Mutations are unreachable unless the host enables them. Every request first
verifies the live schema and refuses with a structured error on drift. No existing Keiro
package gains a web dependency.

You can see it working by starting the standalone server against a migrated database and
issuing two requests:

```bash
keiro-ops-http --database-url "$DATABASE_URL" --port 9092 &
curl -s http://127.0.0.1:9092/wf/list
curl -s -X POST http://127.0.0.1:9092/outbox/maintenance-pass
```

The first prints exactly what `keiro-ops --database-url "$DATABASE_URL" wf list --json` prints.
The second prints a JSON object whose `outcome` is `"preview"` and whose `result` is the same
preview the CLI renders; nothing in the database changes.

This plan implements [IR-26, Serve the keiro-ops surface over HTTP](../improvement-requests/serve-the-keiro-ops-surface-over-http.md)
(canonical handle `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26`), one of the
requests filed by the keiro runtime UI initiative. It is the transport that the sibling plans
[274](274-expose-process-manager-inspection-reads.md) (process-manager reads, IR-29) and
[275](275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md) (cursor-paged
workflow reads, IR-30) hand off to: both add read-only `keiro-ops` commands and explicitly do
not build endpoints, because this package derives its endpoints from the command tree rather
than from a hand-written route list. Composition of several surfaces under one port is IR-31
and is not in scope here. The stance ADR that records the no-UI boundary is IR-32 and is
requested separately; see the Decision Log for how this plan relates to it.


## Progress

- [x] Planning: IR-26 records this plan (`## Planning` section and a bundle log entry,
      2026-09-10); the request stays `proposed` until implementation evidence exists.
- [ ] Milestone 1: `keiro-ops` exports its command type, classifier, parser, and runner;
      `keiro-migrations` exports a session-level schema verifier. Existing test suites pass.
- [ ] Milestone 2: the `keiro-ops-http` package exists with the request-to-arguments
      translation and the parser-tree flag introspection, covered by pure unit tests.
- [ ] Milestone 3: the WAI application performs the schema handshake, the read/write method
      split, the preview/confirm mutation flow, the mutation gate, CORS, and the health route,
      covered by in-process tests against a real database.
- [ ] Milestone 4: the Warp runner and the standalone `keiro-ops-http` executable exist; the
      CLI-agreement test diffs the executable's `--json` output against endpoint bodies for a
      representative command in every domain; the runner is exercised over a real socket.
- [ ] Milestone 5: documentation (runbook, operations guide pointer, capability record),
      changelogs, README, release skill, justfile, the build-plan check for acceptance
      criterion 5, IR-26 implementation evidence, and the ADR distillation.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Name the package `keiro-ops-http` and lay it out as a sister package
  (`keiro-ops-http/`) that depends on `keiro-ops`, never the reverse.
  Rationale: IR-26 offers `keiro-ops-http` or `keiro-http`; the former says exactly what the
  package is (the ops command tree over HTTP) and leaves shorter names free for the composed
  mounting package IR-31 may want. The sister-package rule is stack-wide
  (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`) and is what keeps acceptance criterion 5
  (no web dependency in any existing package) true by construction.
  Date: 2026-09-10

- Decision: Derive endpoints by translating each HTTP request into a `keiro-ops` argument
  vector and parsing it with the same `optparse-applicative` parser the CLI uses, then
  classifying the parsed command with `isMutation`. There is no route table.
  Rationale: IR-26 requires the read-only subset to be "derived mechanically from
  `isMutation`, never from a hand-maintained list". Parsing the request through the real
  command tree makes the set of endpoints identical to the set of commands, including
  commands that plans 274 and 275 add later and commands that appear only when an application
  mounts a hook. Classification happens per request on the parsed value, so a command can
  never be mis-listed as a read.
  Date: 2026-09-10

- Decision: The request mapping is: URL path segments are the command words and positional
  arguments in order; query parameters are the command's long options with `snake_case`
  keys translated to the CLI's `kebab-case` names and emitted in `--name=value` form; a query
  key that names a boolean flag in the parser tree is emitted as a bare `--name` when its value
  is `true` and omitted when `false`; the global CLI options (`--json`, `--force`,
  `--database-url`, `--allow-schema-drift`) are never accepted from a request.
  Rationale: This is the only mapping that needs no per-command knowledge. Flag names are
  discovered by walking the parser tree (`Options.Applicative.Types.OptReader`'s
  `FlagReader` and `CmdReader` constructors), so the translation stays exact as commands are
  added. Fixing the JSON output mode and taking force, drift policy, and the database from
  the host means a request cannot smuggle a global flag. A path segment that begins with `-`
  is rejected with HTTP 400 rather than risk being read as an option.
  Date: 2026-09-10

- Decision: Reads answer `GET` and return the command's `jsonValue` as the whole body.
  Mutations answer `POST` and return an envelope: `{"outcome":"preview","result":…,
  "cli_reinvocation":…}` when the body carries no confirmation, and
  `{"outcome":"executed","result":…}` when the body is the JSON object
  `{"confirm":"execute"}`. Any other body, or any other value of `confirm`, is HTTP 400.
  Rationale: IR-26 acceptance 1 requires read bodies to equal the CLI's `--json` output byte
  for byte in meaning, so reads carry no envelope. A mutation response must make preview and
  execution unmistakable, so it is wrapped. The literal string `"execute"` rather than a
  boolean is the "unmistakable confirmation parameter" IR-26 asks for: a client cannot send
  it by defaulting a flag. The CLI's force hint is passed through as `cli_reinvocation` so an
  operator can reproduce the confirmed action from a shell.
  Date: 2026-09-10

- Decision: Command options never travel in the request body; the body of a `POST` carries
  only the confirmation object.
  Rationale: One translation path (query string to arguments) for both methods is simpler to
  document, test, and reason about than merging body fields with query parameters. A JSON
  payload option such as `wf awakeable signal … --payload` travels URL-encoded in the query
  string like every other value.
  Date: 2026-09-10

- Decision: Every request (reads and mutations alike) runs the schema verification on the
  host's connection pool before the command, and refuses with HTTP 409 `schema_drift` when
  the live schema differs from the binary. A host may set the drift policy to `AllowDrift`,
  which lets every request proceed and reports the drift count in the response header
  `Keiro-Ops-Schema-Drift`.
  Rationale: IR-26 acceptance 3 requires every endpoint, not only mutations, to refuse under
  drift. The CLI lets reads continue with warnings on stderr, but an HTTP read has no side
  channel for warnings and a browser UI would render drifted data as truth. Running the check
  on the pool (via the new `verifyExpectedSchemaSession`) avoids opening a fresh connection per
  request, which is what `verifyExpectedSchema` does today. A single host-level policy replaces
  the per-invocation `--allow-schema-drift` flag because the transport, not the caller, owns
  that decision.
  Date: 2026-09-10

- Decision: Mutations are disabled by default (`MutationsDisabled`); a mutation request against
  a disabled surface is HTTP 403 `mutations_disabled` even when it carries the confirmation.
  Rationale: IR-26 item 3 and acceptance 4. The check runs before the schema verification so
  a refused request costs no database round trip.
  Date: 2026-09-10

- Decision: The HTTP layer runs commands in the CLI's JSON output mode, which means the CLI's
  human-mode "type the stream name to confirm" step for `stream hard-delete` and
  `pgmq dlq purge` does not apply; those commands are exactly as guarded as
  `keiro-ops … --json --force`.
  Rationale: `Keiro.Ops.Stream.confirmDestructive` and `Keiro.Ops.Pgmq.confirmPurge` return
  `True` in JSON mode without reading stdin (`keiro-ops/src/Keiro/Ops/Stream.hs`,
  `keiro-ops/src/Keiro/Ops/Pgmq.hs`), so an HTTP request can never block on a terminal. The
  browser-side typed confirmation for irreversible actions is the UI's responsibility under
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7`. The runbook states this plainly.
  Date: 2026-09-10

- Decision: Failure mapping: a request the parser rejects is HTTP 400 `invalid_request` whose
  message is the parser's own error text; a method that does not match the command's
  classification is HTTP 405 `method_not_allowed`; a command that returns `Failed` is HTTP 422
  `command_failed`; a schema verification that cannot run (connection failure, unsupported
  PostgreSQL major version) is HTTP 500 `schema_verification_failed`; an uncaught exception is
  HTTP 500 `internal_error`. All errors use the conventions' envelope
  `{"error":{"code":…,"message":…,"details":…}}`.
  Rationale: `Keiro.Ops.Render.OpsOutcome`'s `Failed` carries only text, so the transport
  cannot tell a refused command from a store error; 422 is the least harmful single choice
  because proxies and clients do not retry it and it does not claim the server is broken.
  Typed failure codes are future `keiro-ops` work, noted in the runbook.
  Date: 2026-09-10

- Decision: CORS is a small middleware in this package with an explicit allowed-origins list,
  disabled when the list is empty; a matching `Origin` is echoed back verbatim with
  `Vary: Origin`, preflight `OPTIONS` requests from an allowed origin get HTTP 204 with the
  allowed methods and headers, and `Access-Control-Allow-Credentials` is never emitted.
  Rationale: The conventions require an explicit list, off by default, and a configuration
  that cannot represent "wildcard with credentials". Echoing only exact list members and never
  sending the credentials header makes that combination unrepresentable without a policy type.
  `wai-cors` would add a dependency for behavior that is thirty lines here and whose defaults
  are more permissive than this surface should be.
  Date: 2026-09-10

- Decision: The standalone runner binds `127.0.0.1` by default on port `9092`, with a
  configurable Warp request timeout defaulting to 300 seconds.
  Rationale: kiroku-metrics (9091) and shibuya-metrics (9090) bind `*`, but they serve
  metrics; this surface can mutate state and has no authentication, so the host must opt in to
  a non-loopback bind. 9092 continues the stack's port sequence. Warp's default 30-second
  timeout would kill long reads such as a full replay audit before they answer.
  Date: 2026-09-10

- Decision: The package version is `0.16.0.0` with `^>=0.16.0.0` bounds on the sibling
  packages, matching the working tree, and it joins the lockstep release set as the eighth
  package (after `keiro-ops`).
  Rationale: The release skill (`agents/skills/release/SKILL.md`) publishes every package under
  one version and bumps internal bounds together. The new `keiro-ops` exports this plan relies
  on do not exist in the published `0.16.0.0`, so `keiro-ops-http` must never be uploaded
  against that version; the next lockstep release bumps everything at once. The skill is
  updated in Milestone 5 so the release cannot forget the package.
  Date: 2026-09-10

- Decision: This plan does not amend `docs/why-keiro.md` and does not write the stance ADR;
  it records its own transport decisions in a new ADR at completion and cites IR-32.
  Rationale: IR-32 (`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-32`) asks for
  the boundary decision as a separate deliverable and says it gates nothing mechanically. If
  the stance ADR exists when Milestone 5 runs, cite it from the new ADR and the runbook; if it
  does not, the new ADR names IR-32 as pending and confines itself to the transport.
  Date: 2026-09-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The repository and its build

This repository is a Cabal multi-package project. The package list lives in `cabal.project`
at the repository root (`keiro`, `keiro-core`, `keiro-migrations`, `keiro-pgmq`,
`keiro-test-support`, `jitsurei`, `keiro-dsl`, `keiro-ops`, plus keiro-dsl test packages).
The toolchain (GHC 9.12.4, cabal-install 3.16, PostgreSQL 18, `just`, `jq`) comes from the Nix
development shell: run commands inside `nix develop` (direnv activates it automatically in
this checkout), or prefix a command with `nix develop -c`. Hackage packages are fetched
normally; `wai 3.2.5`, `warp 3.4.15`, and `wai-extra 3.1.18` are available in the local
index and absent from the current build plan, while `http-types 0.12.6` and
`http-client 0.7.19` are already in the plan as transitive dependencies of the OpenTelemetry
exporter (no Keiro package names them directly, which is the state acceptance criterion 5
preserves). Formatting is `fourmolu` and `cabal-fmt` through `nix fmt` (treefmt). The
repository task runner is `just`; `just verify` is the full gate and `just haskell-test`
lists the test suites it runs (`justfile`, recipe `haskell-test`).

Every test suite that touches PostgreSQL uses `keiro-test-support`
(`keiro-test-support/src/Keiro/Test/Postgres.hs`): `withMigratedSuiteWith extraComponents`
starts an ephemeral PostgreSQL server once per suite and migrates one template database;
`withFreshStore fixture` clones the template into a fresh database and opens a `KirokuStore`
on it; `withFreshDatabase fixture` clones the template and hands back a connection string.
`keiro-ops/test/Main.hs` is the model for this plan's tests: it seeds data with library
functions, runs commands in process, and also spawns the built `keiro-ops` executable found
with `cabal list-bin exe:keiro-ops` (its cabal stanza declares
`build-tool-depends: keiro-ops:keiro-ops`).

### What keiro-ops is

`keiro-ops` (`keiro-ops/`) is the operator console. Its root module
`keiro-ops/src/Keiro/Ops.hs` exports `main`, `mainWithHooks`, `AppHooks (..)`,
`OpsAuditConfig (..)`, `emptyAppHooks`, the abstract type `OpsInvocation`, `opsCommandTree`,
and `runOpsInvocation`. Inside that module, and not yet exported, are the pieces this plan
needs:

- `data Command = Workflow Workflow.Command | Timer Timer.Command | Outbox … | Inbox … | Pgmq …
  | Projection … | Shard … | Snapshot … | Stream … | ReplayAudit … | Rebuild …`, one
  constructor per command domain.
- `data OpsInvocation = OpsInvocation { globalOptions :: GlobalOptions, opsCommand :: Command }`.
- `commandParser :: AppHooks -> Parser Command`, the `optparse-applicative` parser for the
  command words and their options. Hook-dependent commands (`wf resume-once`,
  `timer drain-once`, `replay-audit`, `rebuild`) exist in the tree only when the matching
  `AppHooks` field is `Just`.
- `isMutation :: Command -> Bool`, which delegates to each domain module's own classifier.
- `runCommand :: AppHooks -> OpsEnv -> Command -> IO OpsOutcome`, which dispatches to the
  domain module's handler.
- `runInvocation`, which resolves the connection string, calls
  `Keiro.Migrations.SchemaCheck.verifyExpectedSchema`, prints drift warnings, refuses a
  mutation on drift unless `--allow-schema-drift` was given, opens the store with
  `Kiroku.Store.Connection.withStore`, builds an `OpsEnv`, runs the command, and renders.

The supporting modules are `keiro-ops/src/Keiro/Ops/Env.hs` (`GlobalOptions`, `OpsEnv { store
:: KirokuStore, outputMode :: OutputMode, force :: Bool, schemaDrift :: [Text],
allowSchemaDrift :: Bool }`, `OutputMode = HumanTable | Json`, `resolveConnectionString`),
`keiro-ops/src/Keiro/Ops/Render.hs` (`OpsResult { headers :: [Text], rows :: [[Text]],
jsonValue :: Value }` and `OpsOutcome = Succeeded OpsResult | SucceededWithExit OpsResult
ExitCode | PreviewRequired OpsResult Text | Failed Text`; `renderResult` prints
`jsonValue` in JSON mode), `keiro-ops/src/Keiro/Ops/Embed.hs` (`AppHooks { workflowResume,
timerFire, replayAudit, projectionCatalog }`), and one module per domain
(`Workflow.hs`, `Timer.hs`, `Outbox.hs`, `Inbox.hs`, `Pgmq.hs`, `Projection.hs`, `Shard.hs`,
`Snapshot.hs`, `Stream.hs`, `ReplayAudit.hs`, `Rebuild.hs`). Each domain module defines its
own `Command` type, `commandParser`, `isMutation`, and `runCommand`, and every mutation
handler returns `PreviewRequired result reinvocation` when `env.force` is `False`, where
`reinvocation` is a shell-quoted `keiro-ops … --force` line built by that module's
`forceInvocation`.

The term "argument vector" below means the list of words a shell would pass to the
`keiro-ops` executable after the program name, for example
`["wf", "show", "approval", "wf-1", "--generation=2"]`. The parser library is
`optparse-applicative 0.19.0.0` (the version the project's build plan solves to). Its
`Options.Applicative.execParserPure prefs parserInfo args` parses an argument vector without
touching the process's real arguments, and its `Options.Applicative.Types` module exposes the
parser tree: `Options.Applicative.Common.mapParser` visits every option of a parser, an option's
`optMain :: OptReader a` is `FlagReader [OptName] a` for a boolean flag such as
`--skip-preflight`, `OptReader …` for an option that takes a value, `ArgReader …` for a
positional argument, and `CmdReader (Maybe String) [(NonEmpty String, ParserInfo a)]` for a
subcommand group whose `ParserInfo`'s `infoParser` field is the nested parser.

The full command tree today, as the CLI accepts it (positional arguments in upper case, options
in `--kebab-case`):

```text
wf list [--status S]... [--name N] [--after NAME ID] [--limit N]
wf show NAME ID
wf steps NAME ID [--generation N]
wf journal NAME ID [--generation N]
wf awakeable show UUID | signal UUID --payload JSON | cancel UUID
wf cancel NAME ID | wf resurrect NAME ID | wf lease release NAME ID
wf gc run-once --retention DURATION [--batch N]
wf resume-once [--limit N]                                  (workflowResume hook only)
timer stuck list [--min-age DURATION] [--min-attempts N]
timer requeue TIMER_ID | timer cancel TIMER_ID | timer dead-letter TIMER_ID --reason TEXT
timer drain-once [--limit N]                                (timerFire hook only)
outbox backlog | outbox list --source S [--status S] [--destination D] [--limit N]
outbox show OUTBOX_ID | outbox requeue-stuck [--older-than D] [--max-attempts N]
outbox gc-sent [--older-than D] | outbox maintenance-pass
outbox dead-letters list --dispatcher NAME [--limit N]
inbox backlog | inbox list --source S [--status S] [--limit N] | inbox show SOURCE MESSAGE_ID
inbox gc [--older-than D] | inbox mark-failed SOURCE MESSAGE_ID --reason TEXT
pgmq dlq read --queue Q [--limit N] | redrive --queue Q [--limit N]
pgmq dlq archive --queue Q [--entry ID] [--limit N] | purge --queue Q
projection position --subscription NAME | projection prune-dedup --projection NAME --before UTC
shard status --subscription NAME | shard relinquish --subscription NAME --worker UUID
snapshot show --stream NAME | snapshot delete --stream NAME
snapshot truncation-preflight --stream NAME --before VERSION [--state-codec-version N …]
stream show STREAM [--from VERSION] [--limit N] | stream causation EVENT_ID | stream subscriptions
stream soft-delete STREAM | undelete STREAM | hard-delete STREAM
stream truncate-before set STREAM VERSION [--skip-preflight] [...] | clear STREAM
replay-audit (--full | --target T... [--include-snapshots]) [--category C] [--budget N] …
rebuild list | preview GROUP | status RUN_ID | retired | external-read CONTRACT VERSION
rebuild start GROUP --run-id ID --requested-by I --reason R [--from P] [--page-size N] | …
```

Which of these are mutations is decided solely by each domain's `isMutation`; the HTTP layer
never repeats that list.

### What the schema handshake is

`keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` embeds a canonical snapshot of the
`keiro` and `keiro_read` schemas as produced by the latest migration on PostgreSQL 18.
`verifyExpectedSchema :: Settings -> IO (Either MigrationError [SchemaDrift])` acquires a new
connection, checks the server major version is 18, snapshots the live schema, and returns the
list of differences (`SchemaDrift = MissingObject | UnexpectedObject | ChangedObject`).
`renderSchemaDrift` turns one difference into a line of text. The whole session is a private
`where`-bound value today; Milestone 1 exports it so the HTTP layer can run it on a pool.

### What a KirokuStore is

`Kiroku.Store.Connection.KirokuStore` (package `kiroku-store`, resolved through Mori at
`mori://shinzui/kiroku/packages/kiroku-store`) is the store handle every Keiro application
opens once with `withStore (defaultConnectionSettings connectionString)`. Its fields are
exported; `pool :: Hasql.Pool.Pool` is a `hasql-pool` connection pool, and
`Hasql.Pool.use pool session` runs a `Hasql.Session.Session` on it. `Kiroku.Store.Effect.runStoreIO
store` is how the ops handlers run their effects, so one long-lived store serves concurrent
requests without extra plumbing.

### WAI, Warp, and the sibling packages

WAI (Web Application Interface, package `wai`) is the Haskell interface between web servers and
web applications: an `Application` is a function from a `Request` to a response callback, and
a `Middleware` wraps one `Application` in another. Warp (package `warp`) is the HTTP server
that runs an `Application`. Warp fills `Request`'s `pathInfo` by splitting the raw path on `/`
and percent-decoding each segment (`http-types`' `decodePathSegments`), so a client that needs
a literal `/` inside one positional argument sends `%2F`; and it fills `queryString` with the
percent-decoded key/value pairs. `wai-extra`'s `Network.Wai.Test` runs an `Application` in
process without a socket (`runSession`, `srequest`, `SRequest`, `SResponse`, `defaultRequest`,
`setPath`), which is how most tests in this plan work.

The two sister packages this one imitates are `kiroku-metrics`
(`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-metrics`, canonical project
`mori://shinzui/kiroku`) and `shibuya-metrics`
(`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-metrics`, canonical project
`mori://shinzui/shibuya`). Both export a config record with a `port`, a `startMetricsServer`
that runs Warp on an `async` thread and returns a handle with the bound port, a
`stopMetricsServer` that cancels it, a `withMetricsServer` bracket, and the bare `Application`
(`Kiroku.Metrics.Server.httpApp`). kiroku-metrics treats `port == 0` as "take a free port" via
`Warp.openFreePort` and `Warp.runSettingsSocket`, which is what makes socket-level tests
deterministic. Both route by pattern-matching `pathInfo` and answer unknown paths with
`{"error":"Not found"}`; that string shape is frozen for them but this new surface uses the
structured envelope below.

### The wire conventions this surface must follow

The keiro-ui initiative's conventions document (project `mori://shinzui/keiro-ui`, path
`docs/architecture/inspection-api-conventions.md`, artifact-level URI pending) binds new
surfaces to: HTTP plus JSON served by an embeddable WAI `Application` in a sister package that
also exports a convenience runner (area 1); `snake_case` for every new wire field and query
parameter (area 2); cursor pagination with `items` and an omitted `next_cursor` on the last
page where a listing pages (area 3; this plan inherits whatever paging shape a command's
`jsonValue` has and invents none); the error envelope `{"error":{"code","message","details"}}`
with stable snake_case codes documented per project (area 4); configurable CORS with an
explicit allowed-origins list, off by default, never wildcard with credentials (area 7); no
authentication, trusted network or authenticating reverse proxy assumed and restated in the
documentation (area 8); frozen published wire shapes (area 9); and keiro's reporting
vocabulary, `store_position`, `visible_store_head`, and "global position distance", never
"lag" or "backlog" (area 10).

### ADRs consulted

Local, in `docs/adr/`:

- [ADR 28, Operator commands wrap supported library APIs and respect schema ownership](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  is the constraining decision. Every operator command is a thin adapter over an exported
  operation of the owning library; every destructive command has a preview phase without
  `--force` and a mutation phase with it; the executable verifies the live schema first, reads
  may continue on drift with warnings while mutations refuse it without `--allow-schema-drift`;
  the standalone binary exposes only database-only commands and application hooks mount the
  rest; and the reporting vocabulary is fixed. Its consequences already anticipate this plan:
  "a future TUI or web console can reuse the command handlers and application hooks; it does
  not receive permission to bypass the library boundary." This plan reuses the handlers and
  adds nothing that touches a database directly.
- [ADR 9, Keiro owns live schema verification under pg-migrate](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md)
  owns the verification mechanism that Milestone 1 refactors without changing its behavior.
- [ADR 36, External readers use versioned guarded SQL contracts](../adr/0036-external-readers-use-versioned-guarded-sql-contracts.md)
  and [ADR 35](../adr/0035-projection-group-status-is-a-frozen-owner-rights-sql-contract.md)
  are background only: they define how out-of-process readers see Keiro state; this surface is
  in-process and goes through the command handlers instead.

No local ADR records the inspection-UI boundary itself; that is IR-32's deliverable. The
`docs/adr/` bundle is profile-governed (`docs/adr/profile.dhall`); the next free handle at
planning time was `ADR-40`, allocated only at creation time with `okf id next`.

Cross-repository, cited by the exact handles Mori returns:

- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`: inspection endpoints live in the project
  that owns the concept; keiro owns framework-level views and the composition of mounted
  surfaces.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`: inspection surfaces live in sister
  packages that export both a convenience runner and the bare WAI `Application`.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7`: the console is read-only first; every
  mutation it ever offers rides an owning-repository endpoint that is itself gated, previews
  are shown before confirmation is offered, and refusals are rendered as refusals.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`: push is a hint, poll is truth; this
  surface is the poll path and adds no push.

### Sibling plans in flight

Plans 274 and 275 exist in the working tree and are being implemented in parallel. Both add
read-only `keiro-ops` commands (`pm show`, `timer pending`, `shard list`, and paging additions
to `wf show`, `wf steps`, `wf journal`) and both state that endpoint exposure is this plan's
scope. Nothing here depends on them landing first: because endpoints are derived from the
parser, their commands become routes the moment they merge. Plan 275's hand-off contract
(query keys `status_class`, `workflow_name`, `created_since`, `ordering`, `limit`, `from`,
error codes `invalid_page_size` and `invalid_cursor`) is satisfied by the generic mapping for
the query keys; the two library error codes are inside the command's own failure text today
and become distinct HTTP codes only when `keiro-ops` gains typed failures, which is noted as
follow-up work in the runbook.


## Plan of Work

### Milestone 1: expose the command tree from keiro-ops and the verifier session from keiro-migrations

Scope: two additive library changes with no behavior change for existing callers. At the end,
`keiro-ops` exports what a second front end needs to parse, classify, and run a command
without going through `stdout`, and `keiro-migrations` exports the schema verification as a
`Session` so it can run on an existing pool. Commands to run: `cabal build keiro-ops
keiro-migrations`, `cabal test keiro-ops-test`, `cabal test keiro-migrations-test`.
Acceptance: both suites pass unchanged, and `cabal repl keiro-ops` can evaluate
`:t Keiro.Ops.runCommand` to `AppHooks -> OpsEnv -> Command -> IO OpsOutcome`.

In `keiro-ops/src/Keiro/Ops.hs`, extend the export list to

```haskell
module Keiro.Ops
  ( main,
    mainWithHooks,
    AppHooks (..),
    OpsAuditConfig (..),
    emptyAppHooks,
    OpsInvocation (..),
    Command (..),
    opsCommandTree,
    commandParser,
    isMutation,
    runCommand,
    runOpsInvocation,
  )
where
```

Nothing else in the module changes: `Command`, `OpsInvocation`, `commandParser`,
`isMutation`, and `runCommand` already exist with the signatures shown in Context and
Orientation. Add Haddock comments on `Command`, `commandParser`, `isMutation`, and
`runCommand` saying that they are the programmatic front-end boundary and that a second front
end must keep the JSON output mode, run the schema verification, and respect `isMutation`
exactly as `runInvocation` does. Add a changelog entry under `## [Unreleased]` in
`keiro-ops/CHANGELOG.md` ("New Features: `Keiro.Ops` exports `Command`, `OpsInvocation`'s
fields, `commandParser`, `isMutation`, and `runCommand` so alternative front ends such as
`keiro-ops-http` can parse, classify, and run commands in process.").

In `keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs`, lift the private
`liveSnapshotSession` out of `verifyExpectedSchema` into an exported top-level value:

```haskell
-- | The verification 'verifyExpectedSchema' performs, as a session a caller can
-- run on its own connection or pool: check the server is PostgreSQL 18, snapshot
-- the live @keiro@ and @keiro_read@ schemas, and compare them with the embedded
-- snapshot.
verifyExpectedSchemaSession :: Session (Either MigrationError [SchemaDrift])
verifyExpectedSchemaSession = do
  serverVersionNumber <- Session.statement () serverVersionStatement
  let majorVersion = fromIntegral serverVersionNumber `div` 10000
  if majorVersion == (18 :: Int)
    then do
      privateSchema <- snapshotSchema "keiro"
      publicSchema <- snapshotSchema "keiro_read"
      pure (Right (compareSchemaSnapshot expectedSchemaSnapshot (privateSchema <> publicSchema)))
    else pure (Left (UnsupportedPostgresVersion majorVersion))
```

and rewrite `verifyExpectedSchema` to acquire the connection, run
`verifyExpectedSchemaSession`, release, and map the session error to
`DatabaseSessionFailed` exactly as it does now. Add `verifyExpectedSchemaSession` to the
module's export list and a changelog entry in `keiro-migrations/CHANGELOG.md`. The
keiro-migrations test suite already exercises `verifyExpectedSchema`; it must pass unchanged.

Commit as `feat(ops): export the command tree and the schema verifier session` with the
trailers listed in Concrete Steps.

### Milestone 2: create the package with the request translation and parser introspection

Scope: the `keiro-ops-http` package skeleton plus its two pure modules, unit-tested without a
database. At the end, `cabal build keiro-ops-http` succeeds and
`cabal test keiro-ops-http-test` runs the translation tests. Acceptance: the tests listed at
the end of this milestone pass.

Create `keiro-ops-http/keiro-ops-http.cabal`, modelled on `keiro-ops/keiro-ops.cabal` (same
`common warnings` and `common shared` stanzas, `cabal-version: 3.0`, `license: BSD-3-Clause`,
`tested-with: GHC >=9.12 && <9.13`, `extra-doc-files: CHANGELOG.md`, `source-repository head`):

```cabal
name:            keiro-ops-http
version:         0.16.0.0
synopsis:        HTTP transport for the keiro-ops operational command tree
description:
  Serves the read-only keiro-ops command tree as JSON endpoints and its
  mutations behind the preview/confirm discipline, as an embeddable WAI
  Application, a Warp runner, and a standalone executable. A sister package to
  keiro-ops; no existing Keiro package depends on a web framework.
category:        Operations, Web

library
  import:          warnings, shared
  hs-source-dirs:  src
  exposed-modules:
    Keiro.Ops.Http
    Keiro.Ops.Http.Application
    Keiro.Ops.Http.Config
    Keiro.Ops.Http.Cors
    Keiro.Ops.Http.Route
    Keiro.Ops.Http.Server
  build-depends:
    , aeson                 >=2.2.2     && <2.3
    , async                 >=2.2       && <2.3
    , base                  >=4.21      && <5
    , bytestring            >=0.12      && <0.13
    , case-insensitive      >=1.2       && <1.3
    , containers            >=0.6       && <0.8
    , hasql                 >=1.10      && <1.11
    , hasql-pool            >=1.2       && <1.5
    , http-types            >=0.12      && <0.13
    , keiro-migrations      ^>=0.16.0.0
    , keiro-ops             ^>=0.16.0.0
    , kiroku-store          >=0.8       && <0.9
    , optparse-applicative  >=0.19      && <0.20
    , text                  >=2.1       && <2.2
    , wai                   >=3.2       && <3.3
    , warp                  >=3.4       && <3.5

executable keiro-ops-http
  import:         warnings, shared
  hs-source-dirs: app
  main-is:        Main.hs
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , base                  >=4.21 && <5
    , keiro-migrations      ^>=0.16.0.0
    , keiro-ops             ^>=0.16.0.0
    , keiro-ops-http
    , kiroku-store          >=0.8  && <0.9
    , optparse-applicative  >=0.19 && <0.20
    , text                  >=2.1  && <2.2

test-suite keiro-ops-http-test
  import:             warnings, shared
  type:               exitcode-stdio-1.0
  hs-source-dirs:     test
  main-is:            Main.hs
  ghc-options:        -threaded -rtsopts -with-rtsopts=-N
  build-tool-depends: keiro-ops:keiro-ops
  build-depends:
    , aeson, base, bytestring, containers, hasql, hspec >=2.11, http-client >=0.7 && <0.8
    , http-types, keiro ^>=0.16.0.0, keiro-ops ^>=0.16.0.0, keiro-ops-http
    , keiro-pgmq ^>=0.16.0.0, keiro-test-support ^>=0.16.0.0, kiroku-store
    , pgmq-migration >=0.5 && <0.6, process >=1.6 && <1.7, text, wai, wai-extra >=3.1 && <3.2
```

(Write the test stanza's dependencies one per line with bounds copied from
`keiro-ops/keiro-ops.cabal` where the same package appears there; the compressed form above is
for reading.) The `optparse-applicative` lower bound is `0.19` because the introspection below
matches the `0.19` shape of `CmdReader`. Copy `keiro-ops/LICENSE` to `keiro-ops-http/LICENSE`,
create `keiro-ops-http/CHANGELOG.md` with the same header as `keiro-ops/CHANGELOG.md` and an
`## [Unreleased]` section describing the package, and add `keiro-ops-http` to the `packages:`
list in `cabal.project` directly after `keiro-ops`.

Create `keiro-ops-http/src/Keiro/Ops/Http/Config.hs`:

```haskell
module Keiro.Ops.Http.Config
  ( MutationPolicy (..),
    SchemaDriftPolicy (..),
    OpsHttpConfig (..),
    defaultOpsHttpConfig,
    OpsHttpServerConfig (..),
    defaultOpsHttpServerConfig,
  )
where

-- | Whether mutation commands may execute at all. Disabled is the default.
data MutationPolicy = MutationsDisabled | MutationsEnabled
  deriving stock (Eq, Show)

-- | What to do when the live schema differs from this binary's expected
-- snapshot. Refusing is the default and applies to reads and mutations alike.
data SchemaDriftPolicy = RefuseOnDrift | AllowDrift
  deriving stock (Eq, Show)

-- | Behavior of the surface itself, independent of how it is served.
data OpsHttpConfig = OpsHttpConfig
  { mutations :: !MutationPolicy,
    schemaDrift :: !SchemaDriftPolicy,
    -- | Exact origins (scheme, host, port) that receive CORS headers.
    -- Empty means CORS is disabled and no CORS header is ever sent.
    allowedOrigins :: ![Text]
  }
  deriving stock (Eq, Show)

defaultOpsHttpConfig :: OpsHttpConfig   -- MutationsDisabled, RefuseOnDrift, []

-- | How the convenience runner binds. Port 0 asks the OS for a free port.
data OpsHttpServerConfig = OpsHttpServerConfig
  { bindHost :: !Text,           -- default "127.0.0.1"
    port :: !Int,                -- default 9092
    requestTimeoutSeconds :: !Int -- default 300
  }
  deriving stock (Eq, Show)

defaultOpsHttpServerConfig :: OpsHttpServerConfig
```

Create `keiro-ops-http/src/Keiro/Ops/Http/Route.hs`, the pure translation layer:

```haskell
module Keiro.Ops.Http.Route
  ( RouteError (..),
    renderRouteError,
    flagNames,
    translateRequest,
    ParseOutcome (..),
    parseArguments,
  )
where

-- | Why an HTTP request could not be turned into an argument vector.
data RouteError
  = EmptyPathSegment
  | OptionLikePathSegment !Text      -- a segment starting with '-'
  | InvalidQueryKey !Text            -- not [a-z0-9_]+
  | InvalidFlagValue !Text !Text     -- flag key, offending value
  | ReservedQueryKey !Text           -- json, force, database_url, allow_schema_drift, help
  deriving stock (Eq, Show)

-- | Every long name in the parser tree that is a boolean flag (a 'FlagReader'),
-- collected by descending into every 'CmdReader' subcommand. Computed once per
-- application from @commandParser hooks@.
flagNames :: Parser a -> Set Text

-- | Path segments become command words and positional arguments in order; query
-- items become options. A key @foo_bar@ becomes @--foo-bar@. A key in 'flagNames'
-- with value @true@ becomes the bare flag, with value @false@ is omitted, and with
-- any other value is an error. Any other key becomes @--foo-bar=value@ (an absent
-- value becomes @--foo-bar=@). Items keep their request order.
translateRequest :: Set Text -> [Text] -> [(Text, Maybe Text)] -> Either RouteError [Text]

data ParseOutcome
  = Parsed !Command
  | Rejected !Text          -- the parser's rendered failure text
  deriving stock (Show)

-- | Run @commandParser hooks@ over the argument vector with
-- 'Options.Applicative.execParserPure'. A 'CompletionInvoked' result (only
-- reachable through the parser's hidden completion options) is 'Rejected'.
parseArguments :: AppHooks -> [Text] -> ParseOutcome
```

Implement `flagNames` with `Options.Applicative.Common.mapParser (\_ opt -> namesOf opt)`
where `namesOf` inspects `optMain opt`: for `FlagReader names _` return the `OptLong` names;
for `CmdReader _ commands` recurse into `infoParser` of each command's `ParserInfo` and
concatenate; for anything else return nothing; then take the union. Implement
`parseArguments` with `execParserPure defaultPrefs (info (commandParser hooks) fullDesc)
(map Text.unpack arguments)` and render a `Failure` with `renderFailure failure "keiro-ops"`
(first component of the pair). The reserved keys are refused before translation so a request
cannot reach the global options even if a future parser accepted them.

Create `keiro-ops-http/src/Keiro/Ops/Http.hs` as the umbrella re-export of the five
submodules (this milestone leaves `Application`, `Cors`, and `Server` as stubs that compile;
Milestones 3 and 4 fill them).

Create `keiro-ops-http/test/Main.hs` with hspec and, for this milestone, a pure `describe
"request translation"` group (no fixture yet): path words and positionals in order
(`["wf","show","approval","wf-1"]` with no query yields exactly that vector); snake to kebab
(`[("min_age", Just "5m")]` yields `--min-age=5m`); repeated keys keep order; a flag key with
`true` yields the bare flag and with `false` yields nothing; a flag key with `yes` is
`InvalidFlagValue`; an empty segment, a segment starting with `-`, a key with a hyphen or an
upper-case letter, and each reserved key are rejected; `flagNames (commandParser
emptyAppHooks)` contains `skip-preflight` and does not contain `limit`; and
`flagNames (commandParser embeddedHooks)` additionally contains `full` and
`include-snapshots` (define `embeddedHooks` exactly as `keiro-ops/test/Main.hs` does).
Finally, `parseArguments emptyAppHooks ["wf","list","--limit=abc"]` is `Rejected` and
`parseArguments emptyAppHooks ["wf","list"]` is `Parsed`, with `isMutation` `False`, while
`["outbox","maintenance-pass"]` parses with `isMutation` `True`.

Commit as `feat(ops-http): scaffold keiro-ops-http with request translation`.

### Milestone 3: the WAI application

Scope: `Keiro.Ops.Http.Application` and `Keiro.Ops.Http.Cors`, plus database-backed
in-process tests. At the end, `opsApplication config hooks store` is a complete WAI
`Application` implementing every rule in the Decision Log. Acceptance: the test groups listed
at the end of this milestone pass against a fresh migrated database.

Create `keiro-ops-http/src/Keiro/Ops/Http/Cors.hs`:

```haskell
module Keiro.Ops.Http.Cors (corsMiddleware) where

-- | With an empty list this is 'id'. Otherwise, when the request's @Origin@
-- header equals one of the allowed origins byte for byte: a preflight
-- (@OPTIONS@ with @Access-Control-Request-Method@) is answered directly with
-- 204, @Access-Control-Allow-Origin: <origin>@, @Vary: Origin@,
-- @Access-Control-Allow-Methods: GET, POST, OPTIONS@,
-- @Access-Control-Allow-Headers: Content-Type@, and
-- @Access-Control-Max-Age: 600@; any other request passes through and its
-- response gains @Access-Control-Allow-Origin: <origin>@ and @Vary: Origin@.
-- A request whose origin is absent or not allowed passes through untouched.
-- @Access-Control-Allow-Credentials@ is never emitted.
corsMiddleware :: [Text] -> Middleware
```

Create `keiro-ops-http/src/Keiro/Ops/Http/Application.hs`:

```haskell
module Keiro.Ops.Http.Application
  ( opsApplication,
    OpsHttpError (..),
    errorResponse,
  )
where

-- | The structured error envelope of the keiro-ui conventions.
data OpsHttpError = OpsHttpError
  { status :: !Status,
    code :: !Text,       -- snake_case, stable
    message :: !Text,    -- human sentence
    details :: !(Maybe Value)
  }

errorResponse :: OpsHttpError -> Response
  -- JSON body {"error":{"code":…,"message":…,"details":…}} with details omitted when Nothing,
  -- Content-Type application/json; charset=utf-8

-- | The complete surface: the health route, then every command of
-- @commandParser hooks@ reachable through the request mapping, wrapped in the
-- CORS middleware from @config.allowedOrigins@.
opsApplication :: OpsHttpConfig -> AppHooks -> KirokuStore -> Application
```

The application computes `flags = flagNames (commandParser hooks)` once, then for each
request proceeds in this order, stopping at the first failure:

1. `pathInfo == []` answers 404 `not_found`. `pathInfo == ["health"]` with `GET` answers the
   health route (below); with another method 405.
2. Translate `pathInfo` and the UTF-8-decoded `queryString` with `translateRequest flags`.
   A `RouteError` answers 400 `invalid_request` with `renderRouteError` as the message and
   `details = {"path": pathInfo, "query": [...]}`. A query key or value that is not valid
   UTF-8 answers 400 `invalid_request`.
3. `parseArguments hooks arguments`. `Rejected text` answers 400 `invalid_request` with the
   parser text as the message and `details = {"arguments": arguments}`. (Because
   `--help` is not accepted, a request for a bare domain such as `GET /wf` is rejected with
   the parser's "Missing: COMMAND" text listing the subcommands; that is the intended
   discovery aid.)
4. Let `mutation = isMutation command`. A read requires `GET`; a mutation requires `POST`.
   Otherwise answer 405 `method_not_allowed` with an `Allow` header naming the one allowed
   method and `details = {"mutation": mutation}`.
5. If `mutation` and `config.mutations == MutationsDisabled`, answer 403
   `mutations_disabled` ("this surface was mounted without mutations; enable them in
   OpsHttpConfig to allow this command").
6. If `mutation`, read the body with `strictRequestBody`. An empty body means no
   confirmation. Otherwise the body must decode as a JSON object whose only key is `confirm`
   with the string value `"execute"`; any other JSON, any other key, or any other value
   answers 400 `invalid_confirmation` whose message states the exact expected body.
   A read ignores its body.
7. Run `Hasql.Pool.use store.pool verifyExpectedSchemaSession`. A pool `UsageError` or a
   `Left MigrationError` answers 500 `schema_verification_failed` with the rendered error as
   the message. Let `drift = map renderSchemaDrift drifts`. If `drift` is non-empty and
   `config.schemaDrift == RefuseOnDrift`, answer 409 `schema_drift` with the message
   "the live schema differs from this binary; refusing to serve until they agree" and
   `details = {"drift": drift}`.
8. Build `OpsEnv { store, outputMode = Json, force = confirmed, schemaDrift = drift,
   allowSchemaDrift = config.schemaDrift == AllowDrift }` where `confirmed` is `True` only for
   a mutation whose body carried the confirmation, and run
   `try (runCommand hooks env command)`. An exception answers 500 `internal_error` with
   `displayException`.
9. Render the outcome. For a read: `Succeeded result` is 200 with `result.jsonValue` as the
   entire body; `SucceededWithExit result (ExitFailure n)` is the same plus the header
   `Keiro-Ops-Exit-Code: n`; `Failed text` is 422 `command_failed` with `text` as the
   message. For a mutation: `PreviewRequired result reinvocation` is 200 with body
   `{"outcome":"preview","result":result.jsonValue,"cli_reinvocation":reinvocation}`;
   `Succeeded result` is 200 with `{"outcome":"executed","result":result.jsonValue}`;
   `SucceededWithExit result (ExitFailure n)` adds `"exit_code":n` to that object; `Failed`
   is 422 as for reads. When `drift` is non-empty and the policy is `AllowDrift`, every
   successful response also carries `Keiro-Ops-Schema-Drift: <count>`.

Every JSON response uses `Content-Type: application/json; charset=utf-8` and is encoded with
`Data.Aeson.encode`. Reads never set `force`, so a read can never execute anything, and a
`PreviewRequired` outcome on a read (impossible today) would be rendered as the preview
envelope rather than as a bare value.

The health route runs step 7's verification and answers `{"status":"ok","schema_drift":[],
"mutations_enabled":false}` with 200 when the schema agrees; with drift it answers
`{"status":"schema_drift","schema_drift":[…],"mutations_enabled":…}` with 200 under
`AllowDrift` and 503 under `RefuseOnDrift`; a verification failure answers
`{"status":"unavailable","message":…}` with 503. The status code therefore says whether
command routes will be served.

Extend `keiro-ops-http/test/Main.hs`: `main` becomes `withMigratedSuiteWith [pgmq]` exactly as
in `keiro-ops/test/Main.hs`, and the following groups use `around (withFreshStore fixture)`
and an in-process helper

```haskell
call :: Application -> Method -> Text -> LazyByteString -> IO SResponse
call app method path body =
  runSession (srequest (SRequest (setPath defaultRequest {requestMethod = method} (encodeUtf8 path)) body)) app
```

built on `Network.Wai.Test`. Seed data with the same library calls the keiro-ops suite uses
(`appendToStream` for streams, `Keiro.Timer` scheduling for timers, `Keiro.Outbox` for
outbox rows, `ensureJobQueue` plus a poisoned `runJobOnce` for a DLQ entry).

- "read/write split": for a table of at least one read and one mutation per domain
  (`wf list`, `wf cancel NAME ID`, `timer stuck list`, `timer cancel UUID`, `outbox backlog`,
  `outbox maintenance-pass`, `inbox backlog`, `inbox gc`, `pgmq dlq read`, `pgmq dlq purge`,
  `projection position`, `projection prune-dedup`, `shard status`, `shard relinquish`,
  `snapshot show`, `snapshot delete`, `stream subscriptions`, `stream soft-delete`, and with
  `embeddedHooks` `rebuild list` and `rebuild start`), assert: `GET` on a read is 200, `POST`
  on that read is 405 with `Allow: GET`, `GET` on a mutation is 405 with `Allow: POST`, and
  `POST` on a mutation with mutations disabled is 403. Assert the table covers every
  top-level domain word of the parser by deriving those words from
  `commandParser embeddedHooks` with the same `CmdReader` walk used for flags, so a new
  domain fails this test until the table grows.
- "preview then confirm": seed stream `order-1` with one event; `POST /stream/soft-delete/order-1`
  with an empty body on a `MutationsEnabled` application is 200 with `outcome` `"preview"`,
  `result` equal to the `jsonValue` that `Keiro.Ops.Stream.runCommand (env with force False)`
  returns for `SoftDelete "order-1"`, and `cli_reinvocation` containing `'--force'`; the
  stream is still readable afterwards (`getStream` and `readStreamForward` behave as before
  the request). Then the same request with body `{"confirm":"execute"}` is 200 with
  `outcome` `"executed"`, and the stream is soft-deleted exactly as the keiro-ops
  "stream handlers" tests assert after `SoftDelete` with force. Then `{"confirm":true}`,
  `{"confirm":"yes"}`, `{"confirm":"execute","extra":1}`, and `[]` are each 400
  `invalid_confirmation` and change nothing.
- "mutations disabled by default": the same confirmed request on a `defaultOpsHttpConfig`
  application is 403 `mutations_disabled` and the stream stays readable.
- "schema drift": after `executeSql "ALTER TABLE keiro.keiro_timers ADD COLUMN ops_test_drift text"`
  (copy `executeSql` from the keiro-ops suite; this needs the connection string, so this group
  uses `withFreshDatabase` and opens its own store), every request in the read/write table
  is 409 `schema_drift` with a non-empty `details.drift`, `GET /health` is 503 with
  `status` `"schema_drift"`, and no response body contains an `outcome` or a bare command
  result. With `schemaDrift = AllowDrift`, `GET /wf/list` is 200 with header
  `Keiro-Ops-Schema-Drift: 1` and `GET /health` is 200.
- "error envelope": `GET /wf/list?limit=abc` is 400 with `error.code` `invalid_request` and
  `error.details.arguments` equal to `["wf","list","--limit=abc"]`; `GET /wf` is 400 whose
  message mentions `Missing: COMMAND`; `GET /nope` is 400; `GET /` is 404 `not_found`;
  `GET /wf/list?force=true` is 400 (reserved key); `GET /replay-audit?full=true` on
  `embeddedHooks` with an empty `OpsAuditConfig` is 422 `command_failed` whose message equals
  the `Failed` text the CLI produces.
- "cors": with `allowedOrigins = []` no response carries an `Access-Control-Allow-Origin`
  header even when the request has `Origin: http://ui.example`; with
  `allowedOrigins = ["http://ui.example"]` a `GET /wf/list` with that origin carries
  `Access-Control-Allow-Origin: http://ui.example` and `Vary: Origin`, an `OPTIONS /wf/list`
  with that origin and `Access-Control-Request-Method: GET` is 204 with the allow headers, a
  request with `Origin: http://other.example` carries no CORS header, and no response ever
  carries `Access-Control-Allow-Credentials`.

Commit as `feat(ops-http): serve the command tree as a WAI application`.

### Milestone 4: the runner, the executable, and the CLI-agreement proof

Scope: `Keiro.Ops.Http.Server`, `keiro-ops-http/app/Main.hs`, and the tests that prove the
endpoint bodies equal the CLI's `--json` output and that the runner serves over a socket. At
the end, the observable outcome in Purpose / Big Picture works end to end. Acceptance: the
tests below pass and the transcript in Validation and Acceptance can be reproduced.

Create `keiro-ops-http/src/Keiro/Ops/Http/Server.hs`:

```haskell
module Keiro.Ops.Http.Server
  ( OpsHttpServer (..),
    startOpsHttpServer,
    stopOpsHttpServer,
    withOpsHttpServer,
  )
where

-- | A running server: the Warp thread and the port it actually bound.
data OpsHttpServer = OpsHttpServer
  { serverThread :: !(Async ()),
    serverPort :: !Int
  }

-- | Bind @config.bindHost@ on @config.port@ (0 means an OS-assigned free port,
-- reported in 'serverPort') with Warp's timeout set from
-- @config.requestTimeoutSeconds@, and serve the application on an async thread.
startOpsHttpServer :: OpsHttpServerConfig -> Application -> IO OpsHttpServer
stopOpsHttpServer :: OpsHttpServer -> IO ()          -- cancel the thread
withOpsHttpServer :: OpsHttpServerConfig -> Application -> (OpsHttpServer -> IO a) -> IO a
```

Follow `Kiroku.Metrics.Server.startMetricsServerWith'` for the port-0 branch
(`Warp.openFreePort` then `Warp.runSettingsSocket`) and use `Warp.setHost (fromString
(Text.unpack config.bindHost))` and `Warp.setTimeout config.requestTimeoutSeconds` otherwise.

Create `keiro-ops-http/app/Main.hs`, the standalone executable. It parses, with
`optparse-applicative`: `--database-url URL` (optional; resolved through
`Keiro.Ops.Env.resolveConnectionString`, so `KEIRO_OPS_DATABASE_URL`, `DATABASE_URL`, and
libpq variables work as for `keiro-ops`), `--bind HOST` (default `127.0.0.1`), `--port N`
(default `9092`), `--allow-origin ORIGIN` (repeatable), `--enable-mutations` (switch),
`--allow-schema-drift` (switch), and `--request-timeout SECONDS` (default `300`). It opens
the store with `withStore (defaultConnectionSettings connectionString)`, runs
`verifyExpectedSchema` once and prints each drift line to stderr prefixed with `warning: `
(as the CLI does) so an operator sees drift at startup even though every request re-checks,
builds `opsApplication config emptyAppHooks store`, prints
`keiro-ops-http: listening on <host>:<port> (mutations <enabled|disabled>)` to stderr, and
runs `withOpsHttpServer` until interrupted. The executable mounts `emptyAppHooks`, so like
the `keiro-ops` binary it serves only database-only commands; an application that wants the
hook-dependent commands over HTTP mounts `opsApplication` with its own `AppHooks` value.

Extend `keiro-ops-http/test/Main.hs`:

- "CLI agreement", using `around (withFreshDatabase fixture)` and opening a store on the
  connection string for the application. Locate the executable with `cabal list-bin
  exe:keiro-ops` as `keiroOpsExecutable` in `keiro-ops/test/Main.hs` does. For each pair
  below, run the executable with `["--database-url", url] ++ cliArguments ++ ["--json"]`,
  decode its stdout as JSON, call the application in process, decode the body, and assert
  the two `Value`s are equal:

  | domain | HTTP request | CLI arguments |
  | --- | --- | --- |
  | wf | `GET /wf/list` | `wf list` |
  | timer | `GET /timer/stuck/list?min_age=0s` | `timer stuck list --min-age 0s` |
  | outbox | `GET /outbox/backlog` | `outbox backlog` |
  | inbox | `GET /inbox/backlog` | `inbox backlog` |
  | pgmq | `GET /pgmq/dlq/read?queue=keiro_ops_http.dlq` | `pgmq dlq read --queue keiro_ops_http.dlq` |
  | projection | `GET /projection/position?subscription=ops-http` | `projection position --subscription ops-http` |
  | shard | `GET /shard/status?subscription=ops-http` | `shard status --subscription ops-http` |
  | snapshot | `GET /snapshot/show?stream=order-1` | `snapshot show --stream order-1` |
  | stream | `GET /stream/show/order-1` and `GET /stream/subscriptions` | `stream show order-1` and `stream subscriptions` |

  Seed before comparing: append two events to `order-1`, seed one workflow instance the way
  the keiro-ops "workflow handlers" group does, schedule one timer, and create the DLQ entry
  with `ensureJobQueue` and a poisoned `runJobOnce`, so at least the `wf`, `timer`, `pgmq`,
  and `stream` comparisons are over non-empty data. For the two hook-only domains, which the
  standalone executable cannot run, compare `GET /rebuild/list` on an `embeddedHooks`
  application against `runCommand embeddedHooks env (Rebuild List)`'s `jsonValue` rendered
  through `Keiro.Ops.Render.jsonText`, and record in the test's description that this is an
  in-process comparison because the CLI side is an embedding binary.
- "reporting vocabulary": over every body collected in the CLI-agreement group, walk the JSON
  and assert no object key is `lag`, `backlog`, or `events_behind`, and assert the
  `stream subscriptions` body contains the keys `store_position` and `visible_store_head`
  (seed one durable subscription checkpoint first, as the keiro-ops "durable checkpoint
  inventory" group does, so the inventory is non-empty).
- "runner": `withOpsHttpServer defaultOpsHttpServerConfig {port = 0} app` then, with
  `http-client`, `GET http://127.0.0.1:<serverPort>/health` is 200 with `status` `"ok"`, and
  `GET /wf/list` is 200; after `stopOpsHttpServer` the port refuses connections.

Commit as `feat(ops-http): add the Warp runner and standalone executable`.

### Milestone 5: documentation, bookkeeping, acceptance evidence, and ADR distillation

Scope: everything that makes the package discoverable, releasable, and recorded. At the end,
`just verify` passes, the runbook contains copyable request/response transcripts, IR-26
carries implementation evidence, and the durable decisions are in `docs/adr/`.

Write `docs/guides/serve-keiro-ops-over-http.md` in the `docs/guides` OKF bundle (profile
`mori/user-documentation-profile.dhall`; allocate the handle with
`okf id next docs/guides --profile mori/user-documentation-profile.dhall DOC`, expected
`DOC-28`; copy the frontmatter shape of `docs/guides/run-and-operate-jitsurei.md`, `type:
Runbook`). It must contain: the one-paragraph statement that the surface assumes a trusted
network or an authenticating reverse proxy and adds no authentication; how to embed
(`opsApplication` with the application's `AppHooks` and `KirokuStore`, then mount or
`withOpsHttpServer`); how to run the standalone executable; the request mapping rules in
prose with the reserved keys; the read and mutation response shapes; the error codes table
(`invalid_request`, `method_not_allowed`, `mutations_disabled`, `invalid_confirmation`,
`schema_drift`, `schema_verification_failed`, `command_failed`, `internal_error`,
`not_found`); CORS configuration; the note that JSON mode skips the typed-name step for
`stream hard-delete` and `pgmq dlq purge`; and the transcripts captured in Validation and
Acceptance (a read, a preview, a confirmation, a drift refusal, a disabled-mutation refusal).
Add the guide to `docs/guides/index.md` and a dated entry to `docs/guides/log.md` following
the existing entries, then run `just user-documentation-validate`.

In `docs/user/operations.md`, section "Operating Keiro", add one paragraph after the
`AppHooks` example saying that the same hooks mount the HTTP surface, pointing at the runbook
by relative link, and noting that mutations are disabled unless the host enables them. Update
`docs/user/log.md` accordingly.

Write `docs/capabilities/http-operational-surface.md` (allocate with `okf id next
docs/capabilities --profile docs/capabilities/profile.dhall CAP`, expected `CAP-20`; copy the
frontmatter shape of `docs/capabilities/operational-console.md`, `requires: [CAP-16]`,
`packages: [keiro-ops-http]`, `interface: [Keiro.Ops.Http]`, evidence pointing at
`keiro-ops-http/test/Main.hs`, the runbook, and `keiro-ops-http/src/Keiro/Ops/Http/Application.hs`).
Update `docs/capabilities/index.md` and `docs/capabilities/log.md`, then run
`just capabilities-validate`.

Update `README.md`'s Packages list with a `keiro-ops-http/` bullet after `keiro-ops/`; add
`## [Unreleased]` entries to the root `CHANGELOG.md` (new package), `keiro-ops/CHANGELOG.md`
and `keiro-migrations/CHANGELOG.md` (if not already added in Milestone 1), and
`keiro-ops-http/CHANGELOG.md`. In `agents/skills/release/SKILL.md`, add
`keiro-ops-http` as package 8 in the dependency-ordered list ("depends on `keiro-ops` and
`keiro-migrations`, so it is always last"), add it to every `for pkg in …` loop and table in
that file, and change "all seven" to "all eight" wherever the count appears. In `justfile`,
add `cabal test keiro-ops-http-test` to `haskell-test` after the `keiro-ops-test` line.

Run the acceptance-5 check (exact command in Concrete Steps) and paste its output into
Outcomes & Retrospective.

Update `docs/improvement-requests/serve-the-keiro-ops-surface-over-http.md`: bump
`timestamp`, keep `status: proposed` (the bundle's precedent, IR-35, is that a request is
marked `completed` only once the release that carries it is published), and append an
`## Implementation evidence (<date>)` section naming this plan, the package, the test groups
that prove each acceptance criterion, and the pending release. Add a dated `Implementation`
entry to `docs/improvement-requests/log.md` and run
`okf validate docs/improvement-requests --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce`.

ADR distillation: allocate a handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`
and write `docs/adr/00NN-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md`
recording, in the bundle's format: the decision that `keiro-ops-http` derives its endpoints by
parsing requests through `keiro-ops`'s parser and classifying with `isMutation`; the request
mapping; the read/`GET` and mutation/`POST` split with the `{"confirm":"execute"}` gate;
mutations off by default; the whole-surface schema-drift refusal and the host-level drift
policy; CORS as an explicit list; no authentication; the sister-package packaging; and the
relationship to IR-32 (cite the stance ADR by handle if it exists, otherwise name IR-32 as
pending). Add a sentence to ADR 28's consequences pointing at the new ADR, advance ADR 28's
`timestamp`, record both in `docs/adr/log.md` with `okf log add` (or by hand in the log's
existing format), and run `just adr-validate`.

Commit as `docs(ops-http): document and record the HTTP operational surface`.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`, inside the
Nix development shell. Where a command is shown bare, `nix develop -c <command>` is the
explicit equivalent.

Every commit made under this plan carries these trailers after a blank line:

```text
ExecPlan: docs/plans/276-serve-the-keiro-ops-surface-over-http.md
Intention: intention_01m24fzbdrevnasj0zm1y199vw
```

Milestone 1:

```bash
cabal build keiro-ops keiro-migrations
cabal test keiro-migrations-test
cabal test keiro-ops-test --test-show-details=direct
cabal repl keiro-ops <<< ':t Keiro.Ops.runCommand'
```

Expected: the repl prints `Keiro.Ops.runCommand :: AppHooks -> OpsEnv -> Command -> IO OpsOutcome`
and both suites end with `0 failures`.

Milestone 2:

```bash
cabal build keiro-ops-http
cabal test keiro-ops-http-test --test-show-details=direct
```

Expected: the "request translation" group passes; the database fixture is not started yet.

Milestone 3 and 4:

```bash
cabal build keiro-ops exe:keiro-ops keiro-ops-http
cabal test keiro-ops-http-test --test-show-details=direct
```

Expected: every group passes. The CLI-agreement group needs `exe:keiro-ops` built first
(the `build-tool-depends` stanza makes cabal do this, but the `cabal list-bin` lookup only
works when the tests are run through cabal from the repository root).

End-to-end transcript for the runbook (Milestone 4): start a scratch PostgreSQL through the
existing recipes, migrate it, run the server, and issue requests:

```bash
just postgres-start
just db-create keiro_ops_http_demo
cabal run keiro-migrate -- up --database-url "host=$PGHOST dbname=keiro_ops_http_demo user=$USER"
cabal run keiro-ops-http -- --database-url "host=$PGHOST dbname=keiro_ops_http_demo user=$USER" --port 9092 &
curl -s -i http://127.0.0.1:9092/health
curl -s http://127.0.0.1:9092/wf/list
curl -s -i -X POST http://127.0.0.1:9092/outbox/maintenance-pass
curl -s -i -X POST -H 'content-type: application/json' -d '{"confirm":"execute"}' http://127.0.0.1:9092/outbox/maintenance-pass
kill %1
```

Expected, in order: `HTTP/1.1 200 OK` with `{"status":"ok","schema_drift":[],"mutations_enabled":false}`;
`[]`; `HTTP/1.1 200 OK` with a body whose `outcome` is `"preview"` and whose
`cli_reinvocation` is `'keiro-ops' 'outbox' 'maintenance-pass' '--json' '--force'`; and
`HTTP/1.1 403 Forbidden` with `{"error":{"code":"mutations_disabled",…}}`. Re-run the server
with `--enable-mutations` and repeat the last request to observe `"outcome":"executed"`.
Induce drift with `psql -d keiro_ops_http_demo -c 'ALTER TABLE keiro.keiro_timers ADD COLUMN demo_drift text'`
and repeat `GET /wf/list` to observe `HTTP/1.1 409 Conflict` with `"code":"schema_drift"`.
Drop the scratch database afterwards with `dropdb keiro_ops_http_demo`.

Milestone 5, acceptance criterion 5 (no component of an existing package declares a direct
web dependency; `http-types` and `http-client` are already transitive dependencies through
the OpenTelemetry exporter, which is why the check looks at direct dependencies only):

```bash
cabal build all --dry-run >/dev/null
jq -r '
  .["install-plan"][]
  | select(.["pkg-name"] | IN("keiro","keiro-core","keiro-pgmq","keiro-migrations","keiro-test-support","keiro-dsl","keiro-ops","jitsurei"))
  | select(.["component-name"]? == "lib" or .["component-name"] == null)
  | .["pkg-name"] as $p
  | ((.depends // []) + ((.components // {}) | to_entries | map(.value.depends // []) | add // []))[]
  | select(test("^(wai|warp|http-types|http-client|wai-extra|websockets)-"))
  | "\($p) depends on \(.)"
' dist-newstyle/cache/plan.json
```

Expected: no output. Any line printed is a violation of acceptance criterion 5 and must be
fixed before the milestone closes. Also run
`grep -l "wai\|warp" keiro/*.cabal keiro-core/*.cabal keiro-pgmq/*.cabal keiro-migrations/*.cabal keiro-test-support/*.cabal keiro-dsl/*.cabal keiro-ops/*.cabal`
and expect no output.

Milestone 5, validation gates:

```bash
nix fmt
just adr-validate
just capabilities-validate
just user-documentation-validate
okf validate docs/improvement-requests --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
just verify
```

Expected: every `okf validate` prints `OK: <n> concepts`, and `just verify` ends without a
failing recipe. `just verify` runs every test suite and takes long; run
`cabal test keiro-ops-http-test` on its own first when iterating.


## Validation and Acceptance

IR-26 lists six acceptance criteria. Each maps to observable behavior and to a named test:

1. Every read-only command's endpoint returns the same `jsonValue` as `keiro-ops <command>
   --json` against the same database state. Proven by the "CLI agreement" group, which spawns
   the built `keiro-ops` executable and diffs decoded JSON for one representative read in each
   of the nine database-only domains, and by the in-process comparison for `rebuild`. Beyond
   the tests: the transcript above shows `curl …/wf/list` and `keiro-ops wf list --json`
   printing the same `[]`.
2. A mutation endpoint without confirmation returns the preview and changes nothing; the
   confirmed call performs what `--force` performs. Proven by "preview then confirm": the
   stream is readable after the preview and soft-deleted after the confirmation, and the
   preview `result` equals the handler's own preview `jsonValue`.
3. Under induced schema drift every endpoint refuses with a structured error and none emits
   partial data. Proven by "schema drift", which alters a Keiro-owned table and then asserts
   409 `schema_drift` for every entry of the read/write table and 503 for `/health`.
4. With mutations disabled (the default) mutation routes refuse even with confirmation.
   Proven by "mutations disabled by default" and by the 403 in the transcript.
5. No existing Keiro package gains a web dependency and the new package exports the bare WAI
   `Application`. Proven by the `plan.json` query and the cabal-file grep in Concrete Steps
   (both print nothing), and by `Keiro.Ops.Http.Application.opsApplication :: OpsHttpConfig ->
   AppHooks -> KirokuStore -> Application` being an exported symbol.
6. Responses use keiro's reporting vocabulary. Proven by "reporting vocabulary", which asserts
   `store_position` and `visible_store_head` in the subscriptions body and the absence of
   `lag`, `backlog`, and `events_behind` keys in every collected body; and by
   `grep -n 'lag\|backlog' docs/guides/serve-keiro-ops-over-http.md` matching only the
   sentence that says those words are banned.

The convention rules are checked as follows: every new field name in the mutation envelope,
health body, and error envelope is `snake_case` (reviewed by reading
`Keiro.Ops.Http.Application`); the error envelope is a single `error` key with `code`,
`message`, and optional `details` (asserted in "error envelope"); CORS is off by default and
list-based (asserted in "cors"); and pagination is inherited from commands, none invented.

A reviewer can also confirm the mechanical derivation by reading
`Keiro.Ops.Http.Application` and finding no string literal naming a command word: the only
place command names appear in the package is the test table, and that table is checked
against the parser's domain words.


## Idempotence and Recovery

Every step is additive and repeatable. Re-running the cabal and test commands is safe. The
package scaffold can be regenerated by deleting `keiro-ops-http/` and removing its line from
`cabal.project`; nothing else references it until Milestone 5. The `keiro-ops` export change
and the `keiro-migrations` refactor are behavior-preserving; if either causes an unexpected
failure elsewhere, revert that one commit and the rest of the plan waits.

The tests create and drop their own clone databases; a crashed run leaves at most a clone
that the next suite start ignores (names are unique per run). The end-to-end transcript uses a
scratch database created for the purpose; drop it with `dropdb keiro_ops_http_demo` to reset.
Inducing drift is done only on that scratch database or on a test clone, never on a developer
database that other work uses.

OKF handles (`DOC-N`, `CAP-N`, `ADR-N`) are allocated with `okf id next` at the moment the file
is created, not copied from this plan; the numbers named here are expectations. If validation
reports a duplicate handle, another concurrent plan took it: re-run `okf id next` and rename.
Plans 274 and 275 are being implemented concurrently and may add `keiro-ops` commands and
`CHANGELOG.md` entries; on a merge conflict in a changelog keep both entries, and on a
conflict in `keiro-ops/src/Keiro/Ops.hs` keep the export additions from Milestone 1 alongside
whatever they add.

If the release skill update in Milestone 5 is missed, the next release would publish
`keiro-ops` with the new exports but not `keiro-ops-http`; that is recoverable by a follow-up
release of the one package, but the plan's Progress must not be marked complete until the
skill names all eight packages.


## Interfaces and Dependencies

`keiro-ops` (`keiro-ops/src/Keiro/Ops.hs`), after Milestone 1, additionally exports:

```haskell
data Command
  = Workflow Keiro.Ops.Workflow.Command
  | Timer Keiro.Ops.Timer.Command
  | Outbox Keiro.Ops.Outbox.Command
  | Inbox Keiro.Ops.Inbox.Command
  | Pgmq Keiro.Ops.Pgmq.Command
  | Projection Keiro.Ops.Projection.Command
  | Shard Keiro.Ops.Shard.Command
  | Snapshot Keiro.Ops.Snapshot.Command
  | Stream Keiro.Ops.Stream.Command
  | ReplayAudit Keiro.Ops.ReplayAudit.Command
  | Rebuild Keiro.Ops.Rebuild.Command

data OpsInvocation = OpsInvocation { globalOptions :: GlobalOptions, opsCommand :: Command }

commandParser :: AppHooks -> Options.Applicative.Parser Command
isMutation    :: Command -> Bool
runCommand    :: AppHooks -> Keiro.Ops.Env.OpsEnv -> Command -> IO Keiro.Ops.Render.OpsOutcome
```

`keiro-migrations` (`keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs`), after
Milestone 1, additionally exports:

```haskell
verifyExpectedSchemaSession :: Hasql.Session.Session (Either MigrationError [SchemaDrift])
```

`keiro-ops-http` library modules and their public signatures at the end of Milestone 4:

```haskell
-- Keiro.Ops.Http.Config
data MutationPolicy = MutationsDisabled | MutationsEnabled
data SchemaDriftPolicy = RefuseOnDrift | AllowDrift
data OpsHttpConfig = OpsHttpConfig { mutations :: MutationPolicy, schemaDrift :: SchemaDriftPolicy, allowedOrigins :: [Text] }
defaultOpsHttpConfig :: OpsHttpConfig
data OpsHttpServerConfig = OpsHttpServerConfig { bindHost :: Text, port :: Int, requestTimeoutSeconds :: Int }
defaultOpsHttpServerConfig :: OpsHttpServerConfig

-- Keiro.Ops.Http.Route
data RouteError = EmptyPathSegment | OptionLikePathSegment Text | InvalidQueryKey Text | InvalidFlagValue Text Text | ReservedQueryKey Text
renderRouteError :: RouteError -> Text
flagNames        :: Options.Applicative.Parser a -> Data.Set.Set Text
translateRequest :: Data.Set.Set Text -> [Text] -> [(Text, Maybe Text)] -> Either RouteError [Text]
data ParseOutcome = Parsed Keiro.Ops.Command | Rejected Text
parseArguments   :: Keiro.Ops.AppHooks -> [Text] -> ParseOutcome

-- Keiro.Ops.Http.Cors
corsMiddleware :: [Text] -> Network.Wai.Middleware

-- Keiro.Ops.Http.Application
data OpsHttpError = OpsHttpError { status :: Network.HTTP.Types.Status, code :: Text, message :: Text, details :: Maybe Data.Aeson.Value }
errorResponse  :: OpsHttpError -> Network.Wai.Response
opsApplication :: OpsHttpConfig -> Keiro.Ops.AppHooks -> Kiroku.Store.Connection.KirokuStore -> Network.Wai.Application

-- Keiro.Ops.Http.Server
data OpsHttpServer = OpsHttpServer { serverThread :: Control.Concurrent.Async.Async (), serverPort :: Int }
startOpsHttpServer :: OpsHttpServerConfig -> Network.Wai.Application -> IO OpsHttpServer
stopOpsHttpServer  :: OpsHttpServer -> IO ()
withOpsHttpServer  :: OpsHttpServerConfig -> Network.Wai.Application -> (OpsHttpServer -> IO a) -> IO a

-- Keiro.Ops.Http: re-exports all of the above
```

Wire contract (frozen once released, per the conventions' area 9):

```text
GET  /health                              -> 200 | 503, {"status","schema_drift","mutations_enabled"[,"message"]}
GET  /<words...>[?<snake_case>=<value>&…] -> 200, the command's jsonValue verbatim
POST /<words...>[?…]  body: (empty)       -> 200, {"outcome":"preview","result":…,"cli_reinvocation":…}
POST /<words...>[?…]  body: {"confirm":"execute"}
                                          -> 200, {"outcome":"executed","result":…[,"exit_code":n]}
any error                                 -> {"error":{"code":…,"message":…[,"details":…]}}
response headers                          -> Keiro-Ops-Exit-Code (reads with a non-zero exit),
                                             Keiro-Ops-Schema-Drift (only under AllowDrift with drift)
codes: invalid_request 400, invalid_confirmation 400, not_found 404, method_not_allowed 405,
       mutations_disabled 403, schema_drift 409, command_failed 422,
       schema_verification_failed 500, internal_error 500
reserved query keys: json, force, database_url, allow_schema_drift, help
```

External dependencies, all already in the local Hackage index: `wai 3.2.x` (the
`Application`/`Middleware` types) and `warp 3.4.x` (the runner) enter the build plan for the
first time; `wai-extra 3.1.x` (tests only, `Network.Wai.Test`) likewise; `http-types 0.12.x`
(statuses, header names, method constants) and `http-client 0.7.x` (tests only, the
socket-level runner check) are already in the plan transitively; `async` (the server
thread), `hasql-pool 1.4.x` (used for `Hasql.Pool.use`), and `case-insensitive` (header
names) are already in the plan through `keiro`. Sources for the
sibling patterns were read from `mori://shinzui/kiroku` (`kiroku-metrics`) and
`mori://shinzui/shibuya` (`shibuya-metrics`); `optparse-applicative 0.19.0.0` was read from
`mori://pcapriotti/optparse-applicative`; WAI, Warp, and `wai-extra` from
`mori://yesodweb/wai`.
