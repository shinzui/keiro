---
id: 28
slug: worked-example-incident-escalation-combining-a-router-and-a-process-manager
title: "Worked example: incident escalation combining a Router and a Process Manager"
kind: exec-plan
created_at: 2026-05-22T13:44:04Z
intention: "intention_01ks6zzqrwe6t84g28ntqsda9t"
---

# Worked example: incident escalation combining a Router and a Process Manager

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro now has both fan-out primitives — the stateful `ProcessManager`
(`src/Keiro/ProcessManager.hs`) and the stateless, effectful `Router`
(`src/Keiro/Router.hs`, added by ExecPlan 26). The existing `jitsurei` worked
examples show each in isolation: `FulfillmentProcess` is a process manager,
`AgentQualRouter` is a router. What no example shows — and what newcomers most
often ask — is **when to reach for which, and how the two work together** in one
flow.

This plan adds a second, richer worked example that uses *both at once*, plus a
guide that teaches the distinction through the Enterprise Integration Patterns
(EIP) vocabulary they are named after.

The domain is **on-call incident escalation** (think PagerDuty/Opsgenie). One
`IncidentRaised` event drives two independent reactions to the *same* event:

- a **Router** (`pagingRouter`) — the EIP *content-based Router* / dynamic
  *Recipient List*: it looks up the on-call responders for the incident's
  service in a read model and dispatches one page per responder. The recipient
  set is *data-dependent* (it depends on the current roster, not on the event),
  so resolution must be effectful. There is no per-page state to keep, so a
  router — not a process manager — is the right tool.

- a **Process Manager** (`escalationProcessManager`) — the EIP *Process
  Manager*: a stateful coordinator with its own state stream, a correlation id,
  and a timer. It remembers that an incident is *awaiting acknowledgement*,
  reacts to a later `PageAcknowledged` event by acknowledging the incident, and
  — if an escalation timer fires first — lets the incident escalate. This part
  needs *memory across events and time*, which a router cannot provide.

You will be able to see it working end-to-end in `jitsurei-test`: raise an
incident, watch the router page exactly the responders on the roster (and
re-page nothing on replay); have a responder acknowledge and watch the process
manager drive the incident to `Acknowledged`; let the escalation timer fire on
an unacknowledged incident and watch it drive the incident to `Escalated` — and
watch that same timer become a safe no-op when the incident was already
acknowledged (the aggregate's own guard resolves the race).

The deliverable is three new `jitsurei` modules, the `jitsurei-test` specs that
exercise them, generated state diagrams, and a new guide
`docs/guides/coordinating-incident-response-with-routers-and-process-managers.md`.
The existing `docs/guides/routers-and-effectful-fan-out.md` is also revised to
ground the Router in EIP and cross-link the new guide.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `Jitsurei.Incident` (incident aggregate), `Jitsurei.OncallRoster` (the `service_oncall` read model + schema), and `Jitsurei.Paging` (page aggregate + `pagingRouter`). Register the modules in `jitsurei.cabal` and re-export from `Jitsurei`. `cabal build all` clean. (done 2026-05-22)
- [x] M1: `jitsurei-test` specs — incident command cycle, page command cycle, and the router fanning `IncidentRaised` to one page per rostered responder with idempotent replay. (done 2026-05-22; jitsurei-test 11/11.)
- [x] M2: Add `Jitsurei.EscalationProcess` (escalation saga aggregate + `escalationProcessManager` + escalation `TimerRequest`/worker). Register and re-export. (done 2026-05-22)
- [x] M2: `jitsurei-test` specs — PM advances the saga and schedules the escalation timer on `IncidentRaised`; PM dispatches `AcknowledgeIncident` on `PageAcknowledged` (idempotent); the escalation timer worker drives `EscalateIncident` when unacknowledged and is a benign no-op when already acknowledged. (done 2026-05-22; jitsurei-test 15/15.)
- [ ] M3: Add the new guide and generated diagrams (incident + page + escalation transducers), register them in `Jitsurei.Diagrams` / `jitsurei/app/DiagramsMain.hs`, run `--write`/`--check`. Revise `docs/guides/routers-and-effectful-fan-out.md` for EIP grounding and cross-link from `docs/guides/README.md`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `TimerRow` (defined in `Keiro.Timer.Schema` with `DuplicateRecordFields`) has no
  auto-derived `HasField` instances, so `OverloadedRecordDot` (`timer.correlationId`)
  fails to compile (`No instance for HasField "correlationId" TimerRow`). The
  keiro tests access it via generic-lens (`timer ^. #correlationId`), which works
  off the `Generic` instance. `Jitsurei.EscalationProcess` therefore imports
  `Control.Lens ((^.))` + `Data.Generics.Labels ()` for `incidentIdFromTimer`.
  (Aggregate payload records authored in this plan are *not* declared with
  `DuplicateRecordFields` at their definition site in the same way, so record-dot
  on `d.incidentId` etc. inside the Builder DSL is fine.)

- A module that writes `import Prelude qualified` (to reach `Prelude.fromIntegral`)
  thereby suppresses the *implicit* unqualified Prelude, dropping `Eq`/`Ord`/`Show`/`Int`
  from scope (GHC counts a qualified import as "explicitly imported"). Fixed in
  `Jitsurei.OncallRoster` by importing `Prelude` normally and using `fromIntegral`
  unqualified.

- The escalation saga is a real state machine: `NoteAcknowledged` is legal only
  from `Awaiting`, so the M2 ack spec must run `IncidentReported` through the PM
  *before* `ResponderAcked` (otherwise the manager command is `CommandRejected`).
  This mirrors the live ordering (a `PageAcknowledged` can only follow the
  `IncidentRaised` that paged the responder) and is now explicit in the spec.


## Decision Log

Record every decision made while working on the plan.

- Decision: Domain is on-call incident escalation; the same `IncidentRaised` event is consumed by both a Router (paging) and a Process Manager (escalation saga).
  Rationale: It is the cleanest domain where a *stateless, data-dependent fan-out* (page whoever is on call — looked up from a roster) and a *stateful, time-bound coordination* (ack window with escalation timeout) are both obviously needed and obviously different. That contrast is exactly the lesson newcomers are missing.
  Date: 2026-05-22

- Decision: Author every aggregate with the keiki Builder DSL (`Keiki.Builder` + `Keiki.Generics.TH`), matching the `jitsurei` house style (`OrderStream`, `FulfillmentProcess`, and `AgentQualRouter` after EP-26's M3 revision).
  Rationale: Consistency with the package's idiomatic aggregate authoring, per the maintainer's stated preference.
  Date: 2026-05-22

- Decision: The escalation timer's worker runs `EscalateIncident` *directly* on the incident aggregate (not by re-entering the process manager with a synthetic "timer fired" input), and the incident aggregate's transducer makes `EscalateIncident` legal only from `Triaging`.
  Rationale: This keeps the timer demonstration small while teaching a real keiro idiom: races (ack vs. escalate) are resolved by the *target aggregate's own guards*, so the timer firing is naturally idempotent and safe — if the incident was already acknowledged, `EscalateIncident` is a benign domain rejection rather than a corruption. Routing escalation back through the PM would add a third input case without teaching anything new.
  Date: 2026-05-22

- Decision: The process manager's target aggregate is the **incident** itself (it dispatches `AcknowledgeIncident`); the router's target aggregate is the **page**. The PM and the router therefore write to different aggregates, and only the PM keeps state.
  Rationale: Mirrors the real shape — acknowledgement is a fact about the incident; a page is a per-responder artifact. It also gives the guide a concrete answer to "what does each one write to?".
  Date: 2026-05-22

- Decision: Scope is the worked example, its tests, diagrams, and guides. No changes to the keiro library primitives.
  Rationale: EP-26 already delivered and tested the primitives; this plan is purely demonstrative and documentary.
  Date: 2026-05-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes only what the existing `jitsurei` guides assume. Read it
before editing.

**What `jitsurei` is.** `jitsurei` is a sibling Cabal package
(`jitsurei/jitsurei.cabal`) of compiling, tested worked examples that back the
long-form guides under `docs/guides/`. Its library modules live in
`jitsurei/src/Jitsurei/`, its umbrella re-export module is
`jitsurei/src/Jitsurei.hs`, and its tests are `jitsurei/test/Main.hs`
(`cabal test jitsurei-test`). Tests provision ephemeral Postgres per test via
`withTestStore` (`jitsurei/test/Main.hs`); the Nix dev shell must be active so
Postgres binaries are on `PATH`.

**The two primitives this example combines.**

- A *process manager* (`src/Keiro/ProcessManager.hs`) reacts to events with a
  **pure** `handle :: input -> ProcessManagerAction ci targetCi`. It keeps its
  own state stream (`pm:…`/`esc-…`), correlates inputs to an instance, can emit
  a self-command that advances its state, can fan out `PMCommand`s to a target
  aggregate, and can schedule `timers`. `runProcessManagerOnce`
  (`src/Keiro/ProcessManager.hs:97`) appends the manager-state event (scheduling
  any timers transactionally) and then dispatches the target commands, each
  under a deterministic id so replay is idempotent. `jitsurei`'s
  `FulfillmentProcess` (`jitsurei/src/Jitsurei/FulfillmentProcess.hs`) is the
  template.

- A *router* (`src/Keiro/Router.hs`, EP-26) reacts to events with an
  **effectful** `resolve :: input -> Eff es [PMCommand targetCi]`. It is
  stateless — no state stream, no correlate, no self-command — and exists to look
  up a data-dependent target set (typically `Keiro.ReadModel.runQuery`) and
  dispatch one command per target, idempotently. `jitsurei`'s `AgentQualRouter`
  (`jitsurei/src/Jitsurei/AgentQualRouter.hs`) is the template.

  Reused router/PM dispatch types: `Router (..)`, `RouterResult (..)`,
  `runRouterOnce` (`Keiro.Router`); `ProcessManager (..)`,
  `ProcessManagerAction (..)`, `PMCommand (..)`, `PMCommandResult (..)`,
  `runProcessManagerOnce` (`Keiro.ProcessManager`).

**Timers.** `src/Keiro/Timer.hs` exposes `TimerRequest (..)`, `scheduleTimerTx`,
`runTimerWorker`, `initializeTimerSchema`. A process manager schedules a
`TimerRequest` via the `timers` field of its `ProcessManagerAction`;
`runProcessManagerOnce` persists it in the same transaction as the manager-state
event. A worker loop later calls `runTimerWorker now fire`, which claims a due
timer and runs the `fire` callback (which does the actual work and returns the
`EventId` recording the firing). `jitsurei`'s `Timers`
(`jitsurei/src/Jitsurei/Timers.hs`) is the template; note it derives UUIDv7
fixtures via `Data.TypeID.V7` from `mmzk-typeid` (the `uuid` package does not
generate v7).

**Read models.** `src/Keiro/ReadModel.hs` exposes `ReadModel (..)`,
`runQuery`. `jitsurei`'s `ReadModels` (`jitsurei/src/Jitsurei/ReadModels.hs`)
shows the table + statements + `ReadModel` pattern.
`Jitsurei.Database.initializeJitsureiTables`
(`jitsurei/src/Jitsurei/Database.hs`) bundles schema setup
(`initializeReadModelSchema`, `initializeSnapshotSchema`,
`initializeTimerSchema`, and the order-summary table).

**The keiki Builder DSL.** Aggregates are authored with `Keiki.Builder`
(imported `qualified as B`) plus the Template Haskell in `Keiki.Generics.TH`:

- Command/event constructors each wrap a single **record** payload (e.g.
  `data IncidentCommand = RaiseIncident !RaiseIncidentData | …` where
  `RaiseIncidentData` is a record with named fields).
- `$( deriveAggregateCtors ''IncidentCommand ''IncidentRegs [("RaiseIncident","RaiseIncident"), …] )`
  generates `inCtorRaiseIncident` (and unused `inp…`/`is…` helpers — the benign
  `-Wunused-top-binds` you also see in `FulfillmentProcess`).
- `$( deriveWireCtors ''IncidentEvent [("IncidentRaised","IncidentRaised"), …] )`
  generates `wireIncidentRaised` and a record `IncidentRaisedTermFields`.
- The state type must derive `(Bounded, Enum, Eq, Show)` — `buildTransducer`
  (`Keiki.Builder`, signature `buildTransducer :: (Bounded v, Enum v, Eq v, Show v) => v -> RegFile rs -> (v -> Bool) -> VertexBuilder … -> SymTransducer …`)
  enumerates vertices.
- The transducer reads:

  ```haskell
  incidentTransducer =
    B.buildTransducer Unreported RNil isTerminal do
      B.from Unreported do
        B.onCmd inCtorRaiseIncident $ \d -> B.do
          B.emit wireIncidentRaised IncidentRaisedTermFields { incidentId = d.incidentId, … }
          B.goto Triaging
      …
  ```

  The package enables `TemplateHaskell`, `QualifiedDo`, `BlockArguments`,
  `OverloadedRecordDot`, `DuplicateRecordFields`, `OverloadedStrings`,
  `OverloadedLabels` (see the `shared` common stanza in `jitsurei/jitsurei.cabal`).
  `Jitsurei.Domain` shows the newtype-identifier + record-payload style; copy it.

**Generated diagrams.** `jitsurei/src/Jitsurei/Diagrams.hs` exposes
`toMermaid <transducer> :: Text` values; `jitsurei/app/DiagramsMain.hs` lists
`Diagram { name, path, body }` entries and, on `--write`, splices each `body`
between `<!-- jitsurei-diagram: <name> begin -->` and `… end -->` markers in the
named guide file; `--check` verifies they are current. Run with
`cabal run jitsurei:exe:jitsurei-diagrams -- --write` (then `-- --check`).

**Existing guides to model on and revise.**
`docs/guides/process-managers-and-timers.md` and
`docs/guides/routers-and-effectful-fan-out.md`, indexed in
`docs/guides/README.md`.

**Build/test commands** (from repo root `/Users/shinzui/Keikaku/bokuno/keiro`):

```bash
cabal build all
cabal test jitsurei-test
cabal run jitsurei:exe:jitsurei-diagrams -- --check
```


## Plan of Work

Three milestones. M1 builds the command side, the read model, and the router. M2
adds the process manager and the timer. M3 writes the guide and diagrams. Each
milestone ends green and is its own commit.

### Milestone M1 — aggregates, on-call read model, and the router

Scope: the stateless half of the example. At the end the incident and page
aggregates exist, the on-call roster read model exists, and `pagingRouter` fans
`IncidentRaised` out to one page per rostered responder, idempotently.

New module `jitsurei/src/Jitsurei/Incident.hs` — the incident aggregate,
Builder-DSL authored like `OrderStream`:

- Identifier newtypes (`IncidentId`, `Service`, `Severity` — model `Severity` as
  a small `data Severity = Sev1 | Sev2 | Sev3` deriving `(Enum, Bounded, …)` plus
  `severityText`/`parseSeverity`), with `…Text` accessors.
- `data IncidentCommand = RaiseIncident !RaiseIncidentData | AcknowledgeIncident !AcknowledgeIncidentData | EscalateIncident !EscalateIncidentData | ResolveIncident !ResolveIncidentData` and the matching `data IncidentEvent = IncidentRaised !IncidentRaisedData | IncidentAcknowledged !… | IncidentEscalated !… | IncidentResolved !…`. `IncidentRaisedData` carries `{ incidentId, service, severity, raisedAt :: UTCTime }` — `raisedAt` and `severity` feed the escalation deadline in M2.
- `data IncidentState = Unreported | Triaging | Acknowledged | Escalated | Resolved` deriving `(Generic, Eq, Show, Enum, Bounded)`.
- Transducer (note the guards that make the ack/escalate race safe):
  - `Unreported —RaiseIncident→ Triaging` emit `IncidentRaised`.
  - `Triaging —AcknowledgeIncident→ Acknowledged` emit `IncidentAcknowledged`.
  - `Triaging —EscalateIncident→ Escalated` emit `IncidentEscalated`.
  - `Acknowledged —ResolveIncident→ Resolved`, `Escalated —ResolveIncident→ Resolved` emit `IncidentResolved`.
  - No `EscalateIncident` edge from `Acknowledged` and no `AcknowledgeIncident` edge from `Escalated` — whichever happens first wins; the loser is a benign `CommandRejected`.
- `incidentEventStream :: IncidentEventStream`, `incidentStream :: IncidentId -> Stream IncidentEventStream`, `incidentCommandStream :: IncidentId -> Stream IncidentCommand` (for PM targeting, mirroring `orderCommandStream`), `incidentCodec`, `parseIncidentEvent`.

New module `jitsurei/src/Jitsurei/OncallRoster.hs` — the read model:

- `data Responder = Responder { responderId :: !ResponderId, tier :: !Int }` (`ResponderId` newtype), `Ord`.
- `serviceOncallReadModel :: ReadModel Service [Responder]` keyed by service,
  returning the responders ordered by `(tier, responderId)`; table
  `jitsurei_service_oncall(service text, responder_id text, tier int)`.
- `initializeOncallRosterTable :: Tx.Transaction ()`, `insertOncallStmt`,
  `selectOncallStmt` (model on `Jitsurei.ReadModels`).

New module `jitsurei/src/Jitsurei/Paging.hs` — the page aggregate and the router:

- `data PageCommand = SendPage !SendPageData | AcknowledgePage !AcknowledgePageData`; `data PageEvent = PageSent !PageSentData | PageAcknowledged !PageAcknowledgedData`. Payloads carry `{ incidentId, responderId }`.
- `data PageState = AwaitingSend | Pending | Acked` deriving `(…, Enum, Bounded)`.
  - `AwaitingSend —SendPage→ Pending` emit `PageSent`.
  - `Pending —AcknowledgePage→ Acked` emit `PageAcknowledged`.
- `pageEventStream`, `pageStream :: IncidentId -> ResponderId -> Stream PageEventStream` (name `page-<incident>-<responder>`), `pageCommandStream` analog, `pageCodec`.
- `pagingRouter :: (IOE :> es, Store :> es) => Router IncidentRaisedData (HsPred PageRegs PageCommand) PageRegs PageState PageCommand PageEvent es`:

  ```haskell
  pagingRouter = Router
    { name = "jitsurei-paging"
    , key = \raised -> incidentIdText raised.incidentId
    , resolve = \raised -> do
        result <- runQuery serviceOncallReadModel raised.service
        let responders = either (const []) id result
        pure
          [ PMCommand
              { target = pageCommandStream raised.incidentId r.responderId
              , command = SendPage (SendPageData { incidentId = raised.incidentId, responderId = r.responderId })
              }
          | r <- responders
          ]
    , targetEventStream = pageEventStream
    }
  ```

Register all three modules in the `library` `exposed-modules` of
`jitsurei/jitsurei.cabal` and add them to the re-export list and imports of
`jitsurei/src/Jitsurei.hs`. Build:

```bash
cabal build all
```

M1 tests in `jitsurei/test/Main.hs` (new `describe` blocks, `around withTestStore`):

1. *Incident command cycle* — `RaiseIncident` then `AcknowledgeIncident`; read
   `incident-<id>` and assert the two recorded events decode in order; assert
   `EscalateIncident` after acknowledgement returns `Left CommandRejected`
   (the race guard).
2. *Page command cycle* — `SendPage` then `AcknowledgePage`; assert the two
   recorded events.
3. *Router fans out to the roster* — `initializeReadModelSchema` +
   `initializeOncallRosterTable`; seed a service with three responders; build an
   `IncidentRaisedData` and a source `RecordedEvent`; `runRouterOnce` and assert
   three `PMCommandAppended`, one `PageSent` per `page-<id>-<responder>` stream;
   replay the same source event and assert three `PMCommandDuplicate` with no new
   events. Add a negative check that an unrostered service resolves to zero
   pages (data-dependence is load-bearing).

Acceptance for M1: `cabal build all` clean; `cabal test jitsurei-test` green.

### Milestone M2 — the escalation process manager and timer

Scope: the stateful half. At the end the process manager coordinates the
incident lifecycle and the escalation timer drives `EscalateIncident` safely.

New module `jitsurei/src/Jitsurei/EscalationProcess.hs`:

- The saga aggregate (the PM's own state): `data EscalationCommand = NoteRaised !… | NoteAcknowledged !…`; `data EscalationEvent = RaiseNoted !… | AcknowledgeNoted !…`; `data EscalationState = EscalationIdle | Awaiting | Settled` (Enum/Bounded). `EscalationIdle —NoteRaised→ Awaiting`; `Awaiting —NoteAcknowledged→ Settled`. `escalationEventStream`, `escalationStream :: IncidentId -> Stream EscalationEventStream` (name `esc-<incident>`).
- The PM input union and the manager:

  ```haskell
  data EscalationInput
    = IncidentReported !IncidentRaisedData
    | ResponderAcked !PageAcknowledgedData

  type EscalationProcessManager =
    ProcessManager
      EscalationInput
      (HsPred EscalationRegs EscalationCommand) EscalationRegs EscalationState EscalationCommand EscalationEvent
      (HsPred IncidentRegs IncidentCommand) IncidentRegs IncidentState IncidentCommand IncidentEvent

  escalationProcessManager :: EscalationProcessManager
  escalationProcessManager = ProcessManager
    { name = "jitsurei-escalation"
    , correlate = incidentIdText . escalationInputIncidentId
    , eventStream = escalationEventStream
    , streamFor = escalationStream . IncidentId
    , targetEventStream = incidentEventStream
    , handle = \case
        IncidentReported raised ->
          ProcessManagerAction
            { command = NoteRaised (NoteRaisedData { incidentId = raised.incidentId })
            , commands = []
            , timers = [escalationTimerRequest raised.incidentId (escalationDeadline raised.raisedAt raised.severity)]
            }
        ResponderAcked acked ->
          ProcessManagerAction
            { command = NoteAcknowledged (NoteAcknowledgedData { incidentId = acked.incidentId })
            , commands =
                [ PMCommand
                    { target = incidentCommandStream acked.incidentId
                    , command = AcknowledgeIncident (AcknowledgeIncidentData { incidentId = acked.incidentId })
                    }
                ]
            , timers = []
            }
    }
  ```

  `escalationDeadline :: UTCTime -> Severity -> UTCTime` adds a severity-derived
  window (e.g. Sev1 = 5m, Sev2 = 15m, Sev3 = 60m) to `raisedAt` — pure, so it
  fits the PM's pure `handle`.

- The timer: `escalationTimerRequest :: IncidentId -> UTCTime -> TimerRequest`
  with `processManagerName = "jitsurei-escalation"`, `correlationId = incidentId`,
  a payload carrying the incident id, and `timerId` a **deterministic** UUIDv5 of
  the incident id (`Data.UUID.V5.generateNamed`) so re-scheduling is harmless.
  (Re-delivery of the same `IncidentRaised` is already a no-op: the PM sees its
  state event as a duplicate and never re-runs `handle`'s timer scheduling — see
  `runProcessManagerOnce`'s duplicate path. The deterministic id is belt-and-braces.)
- The worker: `runEscalationTimerWorker :: (IOE :> es, Store :> es, Error StoreError :> es) => RunCommandOptions -> UTCTime -> Eff es (Maybe TimerRow)` that wraps `runTimerWorker now fire`, where `fire` parses the incident id from the timer payload, runs `EscalateIncident` on `incidentStream incidentId`, and returns a deterministic firing `EventId` whether the command appended or was rejected (already acknowledged → benign).

Register and re-export the module as in M1.

M2 tests in `jitsurei/test/Main.hs`:

1. *Saga + timer on raise* — `initializeTimerSchema`; run
   `runProcessManagerOnce escalationProcessManager raisedSource (IncidentReported raised)`;
   assert `PMStateAppended` and `timersScheduled == 1`; assert a due timer row
   exists via `claimDueTimer`.
2. *Ack drives the incident* — first `RaiseIncident` on the incident; then run
   the PM with `ResponderAcked` and assert it dispatches one
   `PMCommandAppended`; read `incident-<id>` and assert `IncidentAcknowledged`
   was appended; run the PM again with the same source and assert
   `PMStateDuplicate` + `PMCommandDuplicate`.
3. *Timer escalates an unacknowledged incident* — `RaiseIncident`; schedule the
   escalation timer (via the PM or directly); `runEscalationTimerWorker` at a due
   time; assert the incident stream now ends in `IncidentEscalated`.
4. *Timer is a benign no-op after acknowledgement* — `RaiseIncident`,
   acknowledge it, then run the escalation timer worker; assert no
   `IncidentEscalated` was appended (the `EscalateIncident` command was rejected)
   and the timer is still marked fired.

Acceptance for M2: `cabal test jitsurei-test` green, including specs 1–4.

### Milestone M3 — the guide and diagrams

Scope: documentation. At the end there is a new guide that teaches the EIP
distinction and the combined flow, the incident/page/escalation diagrams are
generated and checked, and the existing router guide is EIP-grounded.

- Add `incidentStreamMermaid`, `pageStreamMermaid`, `escalationStreamMermaid` to
  `jitsurei/src/Jitsurei/Diagrams.hs` (`toMermaid <transducer>`), and `Diagram`
  entries in `jitsurei/app/DiagramsMain.hs` pointing at the new guide with marker
  names `incident-stream`, `page-stream`, `escalation-stream`.
- Write `docs/guides/coordinating-incident-response-with-routers-and-process-managers.md`:
  - Open with the EIP framing: *Message Router* / *Recipient List* (stateless,
    content-based routing) vs. *Process Manager* (stateful multi-step
    coordinator), citing Hohpe & Woolf, and keiro's `Router`/`ProcessManager` as
    those two patterns.
  - A "when each" decision rule: *no per-target state and a looked-up recipient
    set → Router; memory across events/time, a correlated instance, timers →
    Process Manager.*
  - Walk the domain: the incident and page aggregates (with generated diagrams),
    the on-call read model, then the two reactions to `IncidentRaised` — the
    router paging the roster and the PM starting the escalation saga — and the
    later `PageAcknowledged` → `AcknowledgeIncident` step and the timer →
    `EscalateIncident` step, calling out the race guard.
  - Point at the `jitsurei-test` specs and the run commands.
- Revise `docs/guides/routers-and-effectful-fan-out.md`: expand the EIP framing
  (name the *content-based Router* and dynamic *Recipient List* patterns and the
  Router/Process-Manager contrast), and add a "Pairing a router with a process
  manager" pointer to the new guide.
- Add both the new guide and (already-present) router guide to
  `docs/guides/README.md` in the right order.
- Generate and verify:

  ```bash
  cabal run jitsurei:exe:jitsurei-diagrams -- --write
  cabal run jitsurei:exe:jitsurei-diagrams -- --check
  ```

Acceptance for M3: `--check` reports all diagrams current; the new guide exists,
is linked from the README, and references real files/tests; `cabal build all`
and `cabal test jitsurei-test` remain green.


## Concrete Steps

Run everything from the repo root `/Users/shinzui/Keikaku/bokuno/keiro` with the
Nix dev shell active.

1. M1: create `jitsurei/src/Jitsurei/Incident.hs`, `…/OncallRoster.hs`,
   `…/Paging.hs`; add the three modules to `jitsurei/jitsurei.cabal`
   `exposed-modules` and to `jitsurei/src/Jitsurei.hs`; add M1 specs to
   `jitsurei/test/Main.hs`. Then:

   ```bash
   cabal build all
   cabal test jitsurei-test
   ```

   Expected tail:

   ```text
   Jitsurei incident command cycle
     ...
   Jitsurei paging router
     fans IncidentRaised out to one page per rostered responder
     reports duplicates on replay and writes no new pages
   ...
   N examples, 0 failures
   ```

2. M2: create `jitsurei/src/Jitsurei/EscalationProcess.hs`; register and
   re-export; add M2 specs; re-run `cabal test jitsurei-test`.

3. M3: edit `Jitsurei/Diagrams.hs` and `jitsurei/app/DiagramsMain.hs`; write the
   new guide with the three diagram marker pairs; revise the router guide and
   `docs/guides/README.md`; then:

   ```bash
   cabal run jitsurei:exe:jitsurei-diagrams -- --write
   cabal run jitsurei:exe:jitsurei-diagrams -- --check
   cabal build all && cabal test jitsurei-test
   ```

Each milestone is a commit carrying the trailers:

```text
ExecPlan: docs/plans/28-worked-example-incident-escalation-combining-a-router-and-a-process-manager.md
Intention: intention_01ks6zzqrwe6t84g28ntqsda9t
```


## Validation and Acceptance

The change is effective beyond compilation when these scenarios hold in
`jitsurei-test`:

- *Router (recipient list).* With a service rostered to three responders, raising
  one incident appends exactly one `PageSent` to each of the three
  `page-<id>-<responder>` streams; replaying the same `IncidentRaised` yields
  three `PMCommandDuplicate` and no new page events; an unrostered service yields
  zero pages.
- *Process manager (saga).* Raising an incident appends one escalation-saga state
  event and schedules exactly one due escalation timer. A `PageAcknowledged`
  routed through the PM appends `IncidentAcknowledged` to the incident exactly
  once (replay → `PMStateDuplicate` + `PMCommandDuplicate`).
- *Timer (escalation + race).* On an unacknowledged incident the escalation timer
  worker appends `IncidentEscalated`; on an already-acknowledged incident the same
  worker appends nothing (the `EscalateIncident` command is rejected) yet still
  marks the timer fired.

Run with `cabal test jitsurei-test`. Diagrams: `cabal run
jitsurei:exe:jitsurei-diagrams -- --check` prints "All generated jitsurei
diagrams are up to date." Success is all specs green and `--check` clean.


## Idempotence and Recovery

All edits are additive (new modules, new specs, new guide, new diagram entries)
and re-runnable; `cabal build`/`cabal test` are idempotent; test tables live in
ephemeral Postgres provisioned per test. The *feature* is built for recovery:
the router's dispatch is idempotent by deterministic command id; the process
manager's state stream makes re-delivery a no-op; the escalation timer's effect
is idempotent because the incident aggregate's guards reject a second
acknowledgement or a post-acknowledgement escalation. If a milestone is left
half-done, the Progress checklist and per-file steps let the next contributor
resume.


## Interfaces and Dependencies

New `jitsurei` modules, depending only on libraries already in
`jitsurei/jitsurei.cabal` (`keiki`, `keiki-codec-json`, `keiro`, `kiroku-store`,
`hasql`, `hasql-transaction`, `contravariant-extras`, `aeson`, `text`, `time`,
`uuid`, `mmzk-typeid`). No new package dependencies; no changes to the keiro
library.

Signatures that must exist at the end of each milestone:

- End of M1:
  - `Jitsurei.Incident`: `IncidentId`, `Service`, `Severity`, `IncidentCommand (..)`, `IncidentEvent (..)`, `IncidentState (..)`, `IncidentEventStream`, `incidentEventStream`, `incidentStream`, `incidentCommandStream`, `incidentCodec`; `IncidentRaisedData (..)` (with `incidentId`, `service`, `severity`, `raisedAt`).
  - `Jitsurei.OncallRoster`: `Responder (..)`, `ResponderId`, `serviceOncallReadModel :: ReadModel Service [Responder]`, `initializeOncallRosterTable`, `insertOncallStmt`, `selectOncallStmt`.
  - `Jitsurei.Paging`: `PageCommand (..)`, `PageEvent (..)`, `PageState (..)`, `PageEventStream`, `pageEventStream`, `pageStream`, `pageCommandStream`, `pageCodec`, `PageAcknowledgedData (..)`, and `pagingRouter :: (IOE :> es, Store :> es) => Router IncidentRaisedData … es`.
  - All three modules in `jitsurei.cabal` exposed-modules and re-exported from `Jitsurei`.
- End of M2:
  - `Jitsurei.EscalationProcess`: `EscalationCommand (..)`, `EscalationEvent (..)`, `EscalationState (..)`, `EscalationInput (..)`, `EscalationProcessManager`, `escalationProcessManager`, `escalationEventStream`, `escalationStream`, `escalationTimerRequest`, `runEscalationTimerWorker`.
- End of M3:
  - `Jitsurei.Diagrams` exports `incidentStreamMermaid`, `pageStreamMermaid`, `escalationStreamMermaid`; `jitsurei/app/DiagramsMain.hs` lists their `Diagram` entries; the new guide and the revised router guide exist and are linked from `docs/guides/README.md`.

Reused, unchanged interfaces: `Router (..)`, `RouterResult (..)`, `runRouterOnce`
(`Keiro.Router`); `ProcessManager (..)`, `ProcessManagerAction (..)`,
`PMCommand (..)`, `PMCommandResult (..)`, `PMStateResult (..)`,
`runProcessManagerOnce` (`Keiro.ProcessManager`); `runCommand`,
`RunCommandOptions`, `defaultRunCommandOptions`, `CommandError`
(`Keiro.Command`); `ReadModel (..)`, `ConsistencyMode (..)`, `runQuery`
(`Keiro.ReadModel`); `TimerRequest (..)`, `TimerRow`, `runTimerWorker`,
`scheduleTimerTx`, `claimDueTimer`, `initializeTimerSchema` (`Keiro.Timer`);
`EventStream (..)`, `SnapshotPolicy (..)`, `Codec (..)`, `Stream`, `stream`;
`B.buildTransducer`, `deriveAggregateCtors`, `deriveWireCtors`, `toMermaid`
(keiki).
