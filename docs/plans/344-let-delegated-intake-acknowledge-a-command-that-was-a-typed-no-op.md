---
id: 344
slug: let-delegated-intake-acknowledge-a-command-that-was-a-typed-no-op
title: "Let delegated intake acknowledge a command that was a typed no-op"
kind: exec-plan
created_at: 2026-11-18T16:22:53Z
intention: "intention_01m7qqfbcde9fvq2n7nafhk895"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-18T16:22:53Z
  reviews:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-18T19:16:00Z
      verdict: "changes-requested"
      note: "Original draft weakens AC-2, conflates receipt identities and can acknowledge without winning a durable receipt under concurrent delivery or retention."
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-18T19:30:24Z
      verdict: "changes-requested"
      note: "Revision is sound on replay stability, scoped identity and strict insert; open: rejection path skips marker recheck, row key has no pinned vector, access-control fixture and record-migration inventories are unspecified, table-path perf gate unnamed."
  revisions:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-18T19:16:28Z
      mode: "update"
      note: "Specify replay-stable no-ops, scoped receipt identity, race-safe classification, strict insert evidence and reproducible DSL conformance."
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-18T20:08:32Z
      mode: "update"
      note: "Recheck marker on rejection, export and pin the no-op row key, specify access-control setup, add record-migration refresh and the table-mode bench gate."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-18T23:45:53Z
      mode: "implement"
      note: "Milestones 1-3 implemented: delegatedDomainCommand, DSL no-op conformance proof, docs and ADR-43 amendment"
---

# Let delegated intake acknowledge a command that was a typed no-op

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A Keiro service that consumes integration events can run its intake in "delegated" mode: the
command it dispatches appends an event, and that event is the durable proof that the delivery
was handled. Today that mode refuses any command that succeeds without appending an event, so
an intake whose command is sometimes a legitimate no-op (for example "a delivery status never
moves backwards, so a late failed outcome changes nothing") cannot use it. The other mode,
"table" intake, cannot run a Keiro command at all. Services such as
`mori://tan/agent-reputation-service` therefore run the command and record the inbox receipt
in a separate hand-written step that Keiro cannot check.

After this change a delegated intake handler can call a new adapter,
`Keiro.Inbox.Delegated.delegatedDomainCommand`. When the command appends events, nothing
changes: the event is the receipt. When the command returns an explicit, replay-stable typed no-op, the
adapter records a completed row in `keiro.keiro_inbox` as the receipt and acknowledges the
delivery; a redelivery finds that row and is a duplicate without re-running the command. A
command that appends nothing without saying so is still refused with
`DelegatedCommandWithoutReceipt`, and a typed rejection is still not acknowledged.

You can see it working by running the new `keiro-test` cases named
"Keiro.Inbox delegated typed no-op" and the new keiro-dsl conformance suite
`keiro-dsl-conformance-intake-delegated-noop`, which drives a generated delegated intake
against PostgreSQL and prints one `True` line per scenario.

This plan implements improvement request IR-65,
[docs/improvement-requests/let-delegated-intake-acknowledge-a-command-that-was-a-typed-no-op.md](../improvement-requests/let-delegated-intake-acknowledge-a-command-that-was-a-typed-no-op.md).


## Progress

- [x] Milestone 1: `delegatedDomainCommand` exists in `keiro/src/Keiro/Inbox/Delegated.hs`
  and the new "Keiro.Inbox delegated typed no-op" tests pass in `keiro-test`, while every
  existing delegated test passes unchanged (IR-65 AC-1). Completed 2026-11-18. Evidence:
  the `--match "Keiro.Inbox delegated" --match "Keiro.Inbox.Delegated"` run reports 31
  examples, 0 failures (13 new typed no-op examples plus the new key-vector example; the
  pre-existing delegated, pure-adapter and access-control bodies are unedited). Full
  `cabal test keiro-test`: 841 examples, 0 failures. Mutating both marker rechecks to
  always miss makes exactly the two competing-marker race tests fail.
  `just bench-regression inbox`: `PERFORMANCE(inbox)=PASSED cases=38`,
  `BENCH_REGRESSION=PASSED`. `just record-migration-policy` passed unchanged at this
  boundary.
- [x] Milestone 2: a generated `idempotence delegated` intake drives an aggregate with a
  no-op edge through the new adapter in `keiro-dsl-conformance-intake-delegated-noop`, and
  the DSL diagnostic and corpus are consistent with it (IR-65 AC-3). Completed 2026-11-18
  (commit `453e0cce`). Evidence: the suite prints five `True` lines (the four planned
  checks plus "generated intake uses delegated idempotence"). `cabal test keiro-dsl:tests`:
  63 of 64 suites passed on the first run; the one failure was the pinned non-Language-4
  fixture list (see Surprises), whose group then passed with 21 examples and 0 failures.
  `just conformance-corpus-policy` on the committed checkpoint: `corpus: 63 of 63
  invocations selected`, `conformance corpus: ok`. `just record-migration-policy` passes
  after refreshing `keiro-dsl/generated-haskell-edition-idiomatic-v2.md`.
- [ ] Milestone 3: the guarantee is documented in the user docs, the Haddock, the
  changelogs, and ADR-43; IR-65 is marked completed; `nix develop -c just verify` passes
  (IR-65 AC-2).


## Surprises & Discoveries

- A keiro-dsl `intake` declaration does not name a command. The generated delegated module
  only fixes the dedupe policy and exposes `runInboxIntake`, which takes a hand-written
  handler of type `Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)`. IR-65 AC-3
  ("intake declarations can target such a command") is therefore met by the runtime adapter
  plus a compiled conformance proof, not by new intake syntax. Evidence:
  `keiro-dsl/src/Keiro/Dsl/Grammar.hs` (`IntakeNode` has no command field) and
  `keiro-dsl/test/conformance-intake-delegated/Generated/HospitalCapacity/IncidentInbox/Inbox.hs`.
  Found while writing the plan, 2026-11-18.

- The record-migration inventories did not change in Milestone 1:
  `generate-record-migration-manifests.py --check` passed after the new
  `Keiro.Inbox.Delegated` records and the `Keiro.Inbox.Schema` line shifts, because the
  inventories cover generated corpus modules and hand-owned conformance modules, not the
  `keiro` library. They became stale only once the Milestone 2 scaffold was staged
  (`generated-haskell-edition-idiomatic-v2.md`: 898 to 911 generated modules).
  `record-field-migration-0.15.md` was unaffected. Found 2026-11-18.

- The new DSL conformance suite needs `-threaded`. `withMigratedSuite` uses
  `registerDelay` and fails at startup with "registerDelay: requires -threaded" without it,
  as `keiro-dsl-conformance-workflow-runtime` already does. After adding only `ghc-options`
  to an already-linked component, Cabal did not relink, and the old binary failed the same
  way until it was deleted. Found 2026-11-18.

- `keiro-dsl-test` pins the list of fixtures outside published Language 4 ("keeps only the
  named source-version and candidate fixtures outside published Language 4"), so a new
  Language 6 fixture must be added to that list in `keiro-dsl/test/Main.hs`. Found
  2026-11-18 when the first `cabal test keiro-dsl:tests` run failed only on that example.

- Scaffold ledgers are gitignored (`.gitignore`: `keiro-dsl-ledger.*.txt`), so `git add` of
  the new conformance directory silently skipped `keiro-dsl-ledger.context.delivery-outcomes.txt`.
  The corpus gate then reported "compiles generated Haskell ... but no plan entry
  regenerates it; its scaffold ledger is missing or untracked". Existing suites force-add
  their ledger and Cabal fragment, so this plan force-added both with `git add -f`.
  Found 2026-11-18.

- The plan's suggested contract name for the motivating case could not be used: `dispatch`
  is a reserved word in `.keiro` sources, and an outcome-enabled aggregate requires a
  `regs` block before `states`. The fixture therefore declares `context delivery-outcomes`,
  `contract courier`, and one `finalOutcome` register written on the accepted edge.
  `.keiro` comments use `#`, not `--`. Found 2026-11-18.


## Decision Log

- Decision: Add a new adapter, `delegatedDomainCommand`, instead of changing
  `delegatedCommand`, `delegatedFromPMCommand`, `DelegatedOutcome`, or the
  `runInboxDelegated*` wrappers.
  Rationale: "Typed" already has one meaning in Keiro: `Keiro.Command.DomainDecision`'s
  `DomainNoOp` constructor (ADR-29). The historical `CommandResult` cannot distinguish a
  typed no-op from a silent one, so the untyped adapter must keep refusing. Leaving the
  existing functions byte-for-byte unchanged keeps their guarantees and their measured
  performance, and adding a constructor to `DelegatedOutcome` would break every downstream
  exhaustive match.
  Date: 2026-11-18

- Decision: Store a no-op as an ordinary completed inbox row whose key is derived from the
  same marker used for accepted commands. Preserve the envelope source for inspection.
  Adopters reserve the row-key prefix specified in Interfaces and Dependencies for this
  adapter. The existing inbox table needs no migration.
  Rationale: Deriving the key from the marker lets consumers, target streams and operations
  keep their own receipts even when they share a database and receive the same message.
  Date: 2026-11-18

- Decision: Require a replay-stable no-op. Once this delivery is a no-op, it must remain
  one in every later reachable state on replay, including after receipt expiry.
  Rationale: The caller knows this property of the domain. A typed decision alone proves
  only what happened in one state.
  Date: 2026-11-18

- Decision: Probe the row after a marker miss and recheck the marker after a silent no-op.
  A fresh no-op requires positive evidence that this attempt inserted and committed its row.
  Rationale: The row probe skips hydration on replay. The marker recheck covers a
  competitor that appended after preflight and caused this dispatch to see a no-op. The
  table runner's historical success on a conflict followed by concurrent garbage collection
  cannot supply evidence of a committed row.
  Date: 2026-11-18

- Decision: Recheck the marker after a typed rejection as well, and return a duplicate on a
  hit.
  Rationale: Two deliveries of one message can both miss preflight. If one appends the
  marker and the other then hydrates a state in which the command is rejected rather than a
  no-op, returning the rejection would report a handled delivery as unhandled, and a caller
  with a dead-letter policy would dead-letter it. The recheck costs one point lookup on the
  rejection path only.
  Date: 2026-11-18

- Decision: Export the row-key derivation as `delegatedNoOpReceiptKey` and pin it with a
  vector test.
  Rationale: The key prefix and marker inputs are persisted replay identity, like
  `delegatedEventId`, whose recipe is frozen by a pinned-vector test. Tests and operators
  also need the key to find or pre-create a row for one delivery.
  Date: 2026-11-18

- Decision: A typed rejection (`DomainRejected`) is not acknowledged. The adapter returns it
  as `Left (DelegatedDomainRejected target rejection)` and writes no row.
  Rationale: IR-65 asks only for no-ops. A rejection may be temporary (an out-of-order
  delivery that becomes acceptable later), so a permanent receipt could suppress a
  legitimate retry. The caller gets the typed payload and applies its own retry or
  dead-letter policy.
  Date: 2026-11-18

- Decision: No shared type with IR-51 (the timer fire outcome request,
  `docs/improvement-requests/make-a-timer-fire-outcome-explicit-and-let-a-fire-finish-without-an-event.md`).
  Rationale: IR-65's review note says the two "may share the representation". They do not
  need to: the typed no-op here is the existing `DomainNoOp`, while IR-51 needs timer row
  states (retry-after, permanently-failed) that have no inbox meaning. IR-51 remains
  unplanned and is free to consume `DomainDecision` later.
  Date: 2026-11-18

- Decision: No new keiro-dsl syntax and no language-version change. The `intake` grammar,
  generated `runInboxIntake`, topology export, and semantic diff are unchanged; only the
  wording of one validator diagnostic and the documentation change.
  Rationale: See Surprises & Discoveries. The generated runner already accepts any handler,
  so the new adapter composes with it as is.
  Date: 2026-11-18


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Keiro is an event-sourcing library for Haskell. This repository is a multi-package Cabal
project; the packages that matter here are `keiro/` (the runtime library and its test suite
`keiro-test`), `keiro-dsl/` (a specification language, `.keiro` files, that generates
Haskell modules), and `keiro-test-support/` (helpers that start an ephemeral PostgreSQL for
tests). All builds and tests must run inside the Nix development shell from the repository
root, for example `nix develop -c cabal test keiro-test`. The PostgreSQL fixture allocates
its cluster under a per-user temporary directory.

Terms used in this plan:

An **integration event** is a message one service publishes for others, represented by
`Keiro.Integration.Event.IntegrationEvent`. **Intake** is the consuming side: receive the
message and suppress repeated work while its receipt is available. The **dedupe key** is
the stable identity of a delivery, computed by
`Keiro.Inbox.Types.dedupeKeyFor` from an `InboxDedupePolicy`; together with the event's
`source` it identifies the delivery.

**Table mode** is `runInboxTransaction` and its variants in `keiro/src/Keiro/Inbox.hs`. It
inserts a row into the `keiro.keiro_inbox` table (primary key `(source, dedupe_key)`) and
runs a handler of type `IntegrationEvent -> Tx.Transaction a` in the same database
transaction. That handler type cannot run a Keiro command, because commands need the
`Store` effect, not a bare transaction.

**Delegated mode** is `runInboxDelegated`, `runInboxDelegatedWithRetries`, and
`runInboxDelegatedBatch` in the same file. They compute the dedupe key, call a handler of
type `Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)` (the `Text` is the dedupe
key), and touch no inbox table. `DelegatedOutcome` (in `keiro/src/Keiro/Inbox/Types.hs`) is
`DelegatedFresh a` or `DelegatedDuplicate`, mapped to `InboxProcessed a` and
`InboxDuplicate`.

A **receipt** is the durable fact that proves a delivery was handled. In delegated mode the
receipt is an event: `delegatedEventId` in `keiro/src/Keiro/Inbox/Delegated.hs` derives a
deterministic event id (the **marker**) from consumer, source, dedupe key, target stream,
and operation name, and `delegatedCommand` in the same file forces the command's first
appended event to carry that id. On redelivery the marker is found in the target stream and
the delivery is a duplicate. `delegatedCommand` is implemented with
`Keiro.ProcessManager.dispatchDeduplicatedCommand` (`keiro/src/Keiro/ProcessManager.hs`),
which probes the marker, dispatches only on a miss, and turns a concurrent duplicate-append
error into a duplicate after confirming the marker is in the target stream. A success with
`eventsAppended == 0` becomes `Left (DelegatedCommandWithoutReceipt targetStream)`.

A **typed no-op** is defined by `keiro/src/Keiro/Command.hs`. `runDomainCommand` and its
`WithSql` variants return `DomainCommandOutcome target co rejection noOp`, a record with
`decision :: DomainDecision co rejection noOp` and `result :: CommandResult target`. The
decision is `DomainAccepted (NonEmpty co)` (events were appended), `DomainRejected
rejection`, or `DomainNoOp noOp`. The last two come from a **silent edge**: a state-machine
transition the aggregate author declared on purpose that emits no event and changes no
state, classified by the aggregate's `DomainCommandHandler`. By contrast the historical
`runCommand` returns only `CommandResult`, where a no-op is visible only as
`eventsAppended == 0`; that is the "untyped" success that must stay refused.

Relevant ADRs, read while writing this plan:

[ADR-43](../adr/0043-delegated-inbox-intake-uses-a-downstream-event-receipt.md) defines
delegated intake. It says the wrapper reads and writes no inbox row, that the adapter
"rejects command failures, unrelated global collisions, and successful commands with no
appended event", and that "Silent commands ... do not satisfy this receipt contract". This
plan adds a bounded exception and must amend ADR-43 with a dated section in Milestone 3.

[ADR-29](../adr/0029-typed-domain-decisions-are-successful-additive-command-outcomes.md)
defines typed domain decisions. Two sentences constrain this design: "Rejection and no-op
open no append transaction and provide no durable side-effect boundary", and "Silent
decisions have no idempotency event and may be re-evaluated on redelivery". So the no-op
decision and the inbox row cannot commit atomically; the row is written in its own
transaction after the decision.

[ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
freezes the `delegatedEventId` recipe. This plan does not touch it.

The existing tests to model new ones on are in `keiro/test/Main.hs` under
`describe "Keiro.Inbox delegated"` (search for that string). They use
`withFreshResourceStore fixture`, which yields `(storeHandle, StoreRunner runner)`; `runner`
runs an `Eff` action against a fresh migrated database. The same file already defines
domain handlers with silent edges: `silentChoiceDomainHandler` with commands
`RejectSilently` and `NoOpSilently`, and `multiCounterDomainHandler` with `Add n` (search
for `runDomainCommand defaultRunCommandOptions silentChoiceDomainHandler`).

On the DSL side, `keiro-dsl/test/fixtures/intake-delegated.keiro` is a Language 6 spec with
an `idempotence delegated` intake, and `keiro-dsl/test/conformance-intake-delegated/` is its
compiled proof (generated modules checked in under `Generated/`, a hand-written wrapper, and
a `Main.hs`), registered as test-suite `keiro-dsl-conformance-intake-delegated` in
`keiro-dsl/keiro-dsl.cabal`. `keiro-dsl/test/fixtures/domain-command-outcomes.keiro` shows
how an aggregate declares typed outcomes (`domain-outcomes rejection=... no-op=...` and a
transition with `outcome no-op ReservationNoOp.DuplicateRequest`); its generated
`EventStream` module exports `reservationDomainCommandHandler`.
`keiro-dsl-conformance-workflow-runtime` in the same cabal file is an existing DSL
conformance suite that runs against PostgreSQL through `keiro-test-support`
(`Keiro.Test.Postgres.withMigratedSuite` and `withFreshResourceStore`); copy its stanza
shape. Checked-in generated directories are kept in sync by
`cabal run -v0 keiro-dsl-corpus-regen -- regenerate` (`just corpus-regen`) and checked by
`just conformance-corpus-policy`; the corpus is described in
`docs/corpus/keiro-dsl-corpus.md`. The validator rule
`DelegatedInboxDedupeOnlyPersistence` in `keiro-dsl/src/Keiro/Dsl/Validate.hs`
(`validateIntake`, binding `delegatedPersistence`) rejects `persist = dedupe-only` on a
delegated intake with a message saying it "describes inbox storage that does not exist".


## Plan of Work

### Milestone 1: the runtime adapter

This milestone adds the adapter and proves IR-65 AC-1 against PostgreSQL. At the end,
`Keiro.Inbox.Delegated` exports `delegatedDomainCommand` and its supporting types, and
`keiro-test` contains passing tests for every outcome.

In `keiro/src/Keiro/Inbox/Delegated.hs`, derive the marker and row key as described in
Interfaces and Dependencies. Require callers to dispatch exactly one domain command on the
resolved target with the supplied options, return its actual outcome and perform all
protected side effects inside its event append. A silent decision performs no side effects.
The caller chooses this adapter only if every no-op it can return for that dispatch is
replay-stable. The adapter cannot infer that property from a reason value.

1. Set the options' `eventIds` to the singleton marker. Use
   `dispatchDeduplicatedCommand` for the preflight marker probe and the existing
   target-stream confirmation of concurrent duplicate-append errors. Return
   `Right DelegatedDuplicate` on a confirmed marker.
2. On a miss, run `lookupInbox` on the scoped row key. A completed row yields a duplicate.
   An existing processing or failed row yields
   `Left (DelegatedNoOpReceiptUnavailable targetStream status)`. In both cases skip the
   command callback.
3. If both receipts are absent, invoke the callback with the prepared options. Pass
   `Left CommandError` back to the dispatch helper for duplicate confirmation. Wrap an
   unconfirmed error as `DelegatedDomainCommandError (DelegatedCommandFailed targetStream err)`.
   On `DomainAccepted events` with a positive append count, return
   `DelegatedFresh (DelegatedDomainAccepted events result)`. An accepted result with zero
   appended events yields the wrapped `DelegatedCommandWithoutReceipt` error. On
   `DomainRejected r`, call `eventAlreadyIn preparedOptions targetStream marker` again. A
   hit yields a duplicate, because a competing delivery of the same message appended the
   marker after preflight and this dispatch hydrated the state it left. On a miss, forward
   the rejection as `Left (DelegatedDomainRejected targetStream r)` and write no row.
4. On `DomainNoOp n`, call `eventAlreadyIn preparedOptions targetStream marker` again.
   A hit yields a duplicate. Two deliveries can miss preflight, then one appends before
   the other hydrates the terminal state. Only a second miss allows the no-op receipt
   transaction to proceed. Run the lookup, callback and effectful no-op handling in the
   helper's dispatch action. Its success classifier is pure and can pass through the
   already classified adapter result.
5. In `keiro/src/Keiro/Inbox/Schema.hs` factor the existing insert and conflict lookup into
   a transaction helper with three distinguishable results: inserted by this transaction,
   existing row, or conflict with a row that disappeared before lookup. Reuse
   `tryInsertStmt`, its encoder, and `selectByKeyStmt`. Export the new helper for the
   adapter. Keep the public signature and behavior of `tryInsertCompletedTx` by mapping
   both inserted and disappeared to its historical `Right ()`.
6. Run the strict helper with `runTransaction`, the supplied persistence and Kafka
   reference, envelope source, scoped key, event and current time. Only a successful
   transaction commit reporting an insert yields
   `DelegatedFresh (DelegatedDomainNoOp n result)`. Classify an existing row by status as
   in step 2. A vanished conflict yields `Left (DelegatedNoOpReceiptLost targetStream)`,
   allowing the caller to retry. Propagate store/commit failures through the store's
   ordinary error channel. A caller may acknowledge only a successful delegated outcome.

Keep the existing adapters, marker recipe, delegated wrappers and table runner behavior.
Use `IOE :> es` for the clock. The existing schema module already imports
`Kiroku.Store.Transaction.runTransaction`.

Rewrite the module header and write the function's Haddock to state the contract from
Validation and Acceptance ("The documented guarantee"). The Haddock is part of AC-2.

In `keiro/test/Main.hs`, add `describe "Keiro.Inbox delegated typed no-op"` beside the
existing delegated block, using `withFreshResourceStore fixture`. Each test drives
`runInboxDelegated Nothing PreferIntegrationMessageId event Nothing handler`, where the
handler calls `delegatedDomainCommand` and propagates failure on `Left`, or
calls the adapter directly when asserting on a `Left`. Use `silentChoiceDomainHandler` /
`multiCounterDomainHandler` if their command sets allow one stream to be both accepted and
no-op'd; otherwise add a small domain handler next to them whose command is accepted in the
initial state and a typed no-op afterwards. Required cases:

- First delivery whose command is a typed no-op: result is `InboxProcessed` carrying
  `DelegatedDomainNoOp`; `listInbox source` has exactly one row, status `InboxCompleted`;
  the target stream has no new event.
- Redelivery of that delivery: `InboxDuplicate`, and an `IORef` counter shows the callback
  ran once in total.
- Redelivery after a later legal state change that preserves the no-op: still
  `InboxDuplicate` and no callback. After removing the receipt with
  `garbageCollectCompleted`, replay now invokes the real command, returns the same no-op
  classification, commits a new row, and appends no event.

- Accepted command: `InboxProcessed` carrying `DelegatedDomainAccepted`, first stored event
  id equals the marker, `listInbox source` is `[]`, redelivery is `InboxDuplicate`.
- Typed rejection: `Left (DelegatedDomainRejected target reason)`, no inbox row, and a second
  call invokes the callback again.
- In `describe "Keiro.Inbox.Delegated pure adapters"`, add a new example beside the existing
  marker vectors that pins `delegatedNoOpReceiptKey` for a fixed marker to a literal
  expected text, including the `keiro/inbox-delegated-noop/1:` prefix. Do not edit the
  existing example.
- A pre-existing `failed` row for the identity (create it with `recordFailedAttemptTx` at
  the key `delegatedNoOpReceiptKey` returns for the delivery's marker):
  `Left (DelegatedNoOpReceiptUnavailable target InboxFailed)`, callback not invoked.
- `PersistDedupeOnly` in the receipt writes a row whose event has empty `payloadBytes`.
- Two consumers (also vary target or operation in the key test) sharing the same source
  and dedupe key each process their first delivery. An ordinary completed table row for the
  raw key cannot short-circuit either caller. A repeat of each operation finds its own receipt.
- Use `withFreshResourceStoresSameDatabase` from `Keiro.Test.Postgres` and explicit thread
  barriers, without sleeps. Pause A inside its callback after preflight. Let B process the
  same delivery and append the marker, then let A hydrate the terminal no-op state. Expect B
  fresh, A duplicate, one event and zero inbox rows. Repeat with both callbacks returning a
  stable no-op and with both past preflight. Expect one fresh, one duplicate and one row.
  Repeat the first interleaving with a domain handler whose terminal state rejects the
  command instead of making it a no-op. Expect B fresh, A duplicate, one event and zero
  inbox rows; A must not return `DelegatedDomainRejected`.
- Exercise all three strict insert classifications, including conflict followed by missing
  row. In the fresh PostgreSQL fixture, a test-only BEFORE INSERT trigger returning NULL
  for the test key deterministically gives the two observations produced by the GC race:
  the insert returns no row and the following SELECT finds none. Assert the retryable
  lost-receipt error and zero rows. While the trigger is installed, also run
  `tryInsertCompletedTx` for that key and assert it still returns `Right ()`; this is the
  direct evidence that table mode's historical mapping is unchanged. Remove the trigger
  and verify replay succeeds.
- Deny INSERT while allowing SELECT. The existing `prepareDelegatedDeniedInboxRole` in
  `keiro/test/Main.hs` revokes every privilege on `keiro.keiro_inbox`, and
  `withFreshResourceStorePrepared` gives the test only the restricted store, so neither
  fits as is. Add a sibling prepare function that creates a second role with the same
  grants plus `GRANT SELECT ON keiro.keiro_inbox`, and leave the existing function and its
  test untouched. Open the restricted store and a privileged store on one database: either
  add a small fixture to `keiro-test-support/src/Keiro/Test/Postgres.hs` modelled on
  `withFreshResourceStoresSameDatabaseWithConnection`, or use that fixture's connection
  string to build the restricted settings with `user=<role>` appended, as the existing
  access-control block does. Through the restricted store a real no-op fails in the store
  error channel without acknowledgement or row. Through the privileged store run
  `GRANT INSERT ON keiro.keiro_inbox`, then verify redelivery through the restricted store
  completes and commits one row.
- Exercise the new adapter's zero-count accepted callback and an unconfirmed command error
  to verify both return the wrapped error without a receipt.
- The untyped path is unchanged: keep the existing test "rejects zero-event commands and
  unconfirmed duplicate errors" untouched and passing. It is the AC-1 proof that a silent
  zero-event success is still `DelegatedCommandWithoutReceipt`.

Add an Unreleased "New Features" entry to `keiro/CHANGELOG.md`. The change is additive
(new exports only), so it is a minor version bump under the Haskell Package Versioning
Policy; do not edit version numbers in this plan.

This milestone adds record types to `keiro/src/Keiro/Inbox/Delegated.hs` and shifts line
numbers in `keiro/src/Keiro/Inbox/Schema.hs`. The `record-migration-policy` recipe, part of
`just verify`, compares the tree with the generated inventories
`keiro-dsl/record-field-migration-0.15.md` and
`keiro-dsl/generated-haskell-edition-idiomatic-v2.md`. Refresh them with the command in
Concrete Steps, review the diff, and commit it with the milestone.

The refactor touches `tryInsertCompletedTx`, which table mode calls on every delivery. The
gate that measures that path is the inbox guard of `just bench-regression`, which runs the
table-mode benchmark in `keiro/bench/Main.hs` against `keiro/bench/baseline-inbox.csv`.
Run it as shown in Concrete Steps on an otherwise idle machine and record the result in
Progress. The committed baseline reflects the maintainer's primary machine; on other
hardware, compare a run before the change with a run after it instead.

Acceptance: `nix develop -c cabal test keiro-test --test-show-details=direct` passes, with
the new describe block listed and the pre-existing "Keiro.Inbox delegated",
"Keiro.Inbox.Delegated pure adapters", and "Keiro.Inbox delegated access control" blocks
passing with no edits to their test bodies.

### Milestone 2: the DSL proof

This milestone proves IR-65 AC-3: a generated delegated intake can feed a command with a
no-op edge. At the end there is a new fixture, a new checked-in conformance directory, and
a new test-suite that runs the AC-1 scenarios through generated code.

Create `keiro-dsl/test/fixtures/intake-delegated-noop.keiro`, declared `language keiro-dsl 6`,
containing: a contract and an `idempotence delegated` intake modelled on
`intake-delegated.keiro`, and an outcome-enabled aggregate modelled on
`domain-command-outcomes.keiro` with one accepted transition and one
`outcome no-op` self-loop. Keep it small; a delivery-status aggregate that mirrors the
motivating case reads well (a `RecordOutcome` command that is accepted from `Pending` and a
no-op from `Delivered`). Use a context name not used by another fixture so generated module
paths do not collide.

Bootstrap `keiro-dsl/test/conformance-intake-delegated-noop/` with the explicit
`scaffold` invocation in Concrete Steps. This writes the generated modules, ledger, Cabal
fragment and any hand-fillable starters. The corpus driver discovers existing ledgers
through `git ls-files` in `keiro-dsl/tools/corpus-regen/src/CorpusPlan.hs`. Add a
`candidate-primary` source entry for the new suite to
`keiro-dsl/test/conformance-baseline.json` beside the existing delegated entry. Use the
generated fragment to populate the test component's module and dependency inventory.
Supply these hand-written pieces:

- A hand-written integration module (for example
  `<Context>/<Intake>/DelegatedIntegration.hs`) that builds the handler. Pass the wrapper
  dedupe key, delivered envelope, consumer, operation and Kafka context in a
  `DelegatedNoOpReceipt`. Call
  `delegatedDomainCommand` with a callback that runs
  `runDomainCommand prepared <generated>DomainCommandHandler target command`, and pass the
  handler to the generated `runInboxIntake`. Propagate a typed adapter failure outside
  `DelegatedOutcome`, for example with an outer error effect interpreted by the test. If the generated aggregate needs a
  `BehaviorHoles` module, follow `conformance-domain-outcomes/`.
- `Main.hs`, using `Keiro.Test.Postgres.withMigratedSuite` and `withFreshResourceStore` as
  `keiro-dsl/test/conformance-workflow-runtime/Main.hs` does. It runs, in order: a first
  delivery that is accepted; a second, different delivery to the same stream that is a typed
  no-op; a redelivery of that second delivery. Also feed a distinct delivery to the generated
  runner using the historical `delegatedCommand` with the same generated command on its
  silent edge (erase the typed outcome with `forgetDomainDecision`). Observe
  `DelegatedCommandWithoutReceipt` in the outer error channel, and assert
  that delivery acquired neither receipt. It prints one line per check and exits
  non-zero if any is `False`. Expected output is shown in Concrete Steps.

Register test-suite `keiro-dsl-conformance-intake-delegated-noop` in
`keiro-dsl/keiro-dsl.cabal`, modelled on `keiro-dsl-conformance-workflow-runtime` (it needs
`keiro-test-support` and `kiroku-store`). `cabal test keiro-dsl:tests` picks it up
automatically. Add the fixture and the conformance directory to the two tables in
`docs/corpus/keiro-dsl-corpus.md`.

Reword the `DelegatedInboxDedupeOnlyPersistence` diagnostic in
`keiro-dsl/src/Keiro/Dsl/Validate.hs` so it stays true: the intake declaration owns no inbox
storage in delegated mode; a no-op receipt row's persistence is chosen by the handler
through `DelegatedNoOpReceipt`. The rule itself (reject the clause) and its diagnostic code
do not change. Update any test in `keiro-dsl/test/Main.hs` that pins the old message text.

Add an Unreleased entry to `keiro-dsl/CHANGELOG.md` noting the new conformance proof and the
reworded diagnostic. Stage the new suite and ledger so tracked-file inventory can see them.
The record-migration inventories named in Milestone 1 also list every generated corpus
module, so refresh them again after scaffolding and include them in the checkpoint.
Run the focused suite and the DSL tests, then commit the reviewed
fixture, ledger, generated tree, suite and registration together. The corpus gate in
`keiro-dsl/tools/corpus-regen/src/Main.hs` requires clean corpus paths, including the new
tracked directory. Run the gate on that checkpoint before marking Milestone 2 complete.
If unrelated corpus edits are present, validate the checkpoint in a separate clean checkout.

Acceptance: `nix develop -c cabal test keiro-dsl-conformance-intake-delegated-noop
--test-show-details=direct` prints the expected transcript; `nix develop -c just
conformance-corpus-policy` passes; `nix develop -c cabal test keiro-dsl:tests` passes.

### Milestone 3: documentation, ADR, and request closure

This milestone delivers IR-65 AC-2 and closes the loop. Update, stating the guarantee from
Validation and Acceptance in each place it is relevant:

- `docs/user/inbox.md`, section "Delegated idempotence": add `delegatedDomainCommand`, when
  a row is written, and the caller obligations. The sentence "Both reject failed commands
  and commands that append no event" must stay true for the two existing adapters.
- `docs/user/integration-events.md`, section "Choosing inbox idempotence ownership": the
  sentences "Delegated intake creates no inbox row" and "Keep table intake for silent
  commands" need the typed-no-op exception. Cover SELECT and INSERT privileges, the
  reserved key prefix, and the replay horizon when operators use `garbageCollectCompleted`.
- `docs/guides/integration-events-with-kafka.md`, section "Delegating the receipt to a
  downstream command": add a short typed-no-op example.
- `docs/user/api-reference.md`: add the new exports to the `Keiro.Inbox.Delegated` list.
- `docs/user/keiro-dsl-integration.md` and `agents/skills/keiro-dsl-authoring/NOTATION.md`:
  both say delegated mode writes no inbox storage; qualify with the handler-owned no-op
  receipt.
- [ADR-43](../adr/0043-delegated-inbox-intake-uses-a-downstream-event-receipt.md): append a
  dated section recording the typed no-op receipt, the pre-dispatch lookup, the
  marker recheck, scoped row key, replay stability, typed rejection, and retention behavior. Advance its
  `timestamp`, add the `docs/adr/log.md` entry with `okf log add`, and validate as shown in
  Concrete Steps. Preserve `docId: ADR-43`.
- Advance the changed user and guide documents' timestamps and update their respective
  `docs/user/log.md` and `docs/guides/log.md` entries. The
  `user-documentation-validate` recipe enforces both logs.

Once acceptance is verified, set IR-65's frontmatter status to `completed`, advance its
timestamp and replace its stale “no milestone has been implemented yet” Status paragraph
with the completion evidence. Add a completion entry to `docs/improvement-requests/log.md`
in the style of IR-63 and fill in Outcomes & Retrospective.

Acceptance: `nix develop -c just verify` passes, and a reader of `docs/user/inbox.md` and
the `Keiro.Inbox.Delegated` Haddock can state when a no-op is acknowledged and what the
caller must guarantee.


## Concrete Steps

Run all commands from the repository root.

Confirm the environment once:

```bash
nix develop -c z3 --version
nix develop -c cabal build keiro keiro-dsl
```

Milestone 1 loop:

```bash
nix develop -c cabal build keiro
nix develop -c cabal test keiro-test --test-show-details=direct \
  --test-options='--match "Keiro.Inbox delegated"'
nix develop -c cabal test keiro-test
```

The filter matched 16 existing examples with zero failures during review. It also matches
the planned typed no-op block. The full suite covers the separately named pure-adapter
identity vectors. Expect the example count to increase and the report to include:

```text
N examples, 0 failures
```

Refresh the record-migration inventories (rerun after the Milestone 2 scaffold), then run
the table-mode benchmark guard:

```bash
nix develop -c python3 scripts/generate-record-migration-manifests.py
nix develop -c just record-migration-policy
nix develop -c just bench-regression inbox
```

Milestone 2:

```bash
nix develop -c cabal run -v0 exe:keiro-dsl -- scaffold \
  keiro-dsl/test/fixtures/intake-delegated-noop.keiro \
  --out keiro-dsl/test/conformance-intake-delegated-noop
# After wiring the hand-written runner and Cabal component
nix develop -c cabal test keiro-dsl-conformance-intake-delegated-noop --test-show-details=direct
nix develop -c cabal test keiro-dsl:tests
# After committing the corpus checkpoint
nix develop -c just conformance-corpus-policy
```

Expected output of the new suite (exact wording is the implementer's; one line per check,
all `True`):

```text
accepted delivery appends the marker event and writes no inbox row: True
typed no-op delivery is processed and records one completed inbox row: True
redelivered no-op is a duplicate without dispatching the command: True
untyped silent success returns DelegatedCommandWithoutReceipt and leaves no receipt: True
```

Milestone 3:

```bash
nix develop -c okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
nix develop -c just verify
```

Commit at each milestone boundary with Conventional Commits and both trailers:

```text
feat(keiro): acknowledge typed no-ops in delegated intake

ExecPlan: docs/plans/344-let-delegated-intake-acknowledge-a-command-that-was-a-typed-no-op.md
Intention: intention_01m7qqfbcde9fvq2n7nafhk895
```


## Validation and Acceptance

The plan is accepted when IR-65's three criteria hold, shown by the milestone checks above:
AC-1 by the `keiro-test` cases in Milestone 1, AC-3 by the conformance suite in Milestone 2,
AC-2 by the documentation in Milestone 3.

**The documented guarantee** (the text AC-2 requires, to be stated in the Haddock and
`docs/user/inbox.md`):

An accepted command commits its deterministic marker in its first event. A typed no-op
qualifies only when the caller guarantees that replaying that delivery remains a no-op
across later reachable states. This includes retries after a crash and replays after
retention. The callback must use the supplied options and target, run one domain command,
and keep protected effects inside its append. A qualifying no-op is fresh only after the
adapter commits its scoped completed inbox row. A matching marker in the target stream
or a matching completed row proves a duplicate. A competing marker takes precedence when
dispatch observes the no-op or rejection left by that append.

A crash after the silent decision and before the receipt commit leaves the delivery
unacknowledged. A retry evaluates the command again. Set retention beyond the required
redelivery horizon. Once GC removes a row, a later replay may report fresh again and must
still append nothing. A typed rejection, unconfirmed command failure, missing receipt after
an insert conflict, or untyped silent success provides no basis for acknowledgement.
A service adopting this handler needs SELECT on marker misses and INSERT for no-ops.

**Guarantees that must not weaken**, and the evidence for each:

- Existing delegated adapters: `delegatedCommand` and `delegatedFromPMCommand` are not
  edited. Evidence: the diff of `keiro/src/Keiro/Inbox/Delegated.hs` touches neither
  function body, and their existing tests pass with unedited bodies.
- Marker identity: `delegatedEventId` is not edited; its pinned-vector test "pins ASCII,
  Unicode, empty-field, and delimiter identity vectors" passes unchanged.
- Table mode: `keiro/src/Keiro/Inbox.hs` and the SQL statements in `Keiro.Inbox.Schema` keep
  their current behavior. The table helper retains its existing insert/conflict mapping:
  the `describe "Keiro.Inbox"` block passes unchanged, and the trigger test in Milestone 1
  asserts `tryInsertCompletedTx` still returns `Right ()` on a vanished conflict.
- Row-key identity: `delegatedNoOpReceiptKey` is new persisted replay identity. Its
  pinned-vector example in Milestone 1 freezes the prefix and encoding.
- Wire bytes, event folds, snapshots, and migrations: no event type, codec, schema, or
  migration changes. The DSL fixture is new, so no existing generated output changes;
  `just conformance-corpus-policy` shows the checked-in corpus is otherwise identical.
- Performance: the existing delegated adapters are not edited, so the
  `InboxDelegatedBench` benchmark in `keiro/bench/` measures an unchanged path. Table mode
  keeps the same statements in the same order, but `tryInsertCompletedTx` is refactored
  onto the strict helper, so its path is affected. The gate that measures it is
  `just bench-regression inbox` (table-mode benchmark in `keiro/bench/Main.hs` against
  `keiro/bench/baseline-inbox.csv`); Milestone 1 runs it and no new baseline is expected.
  The new adapter is not covered by a benchmark gate. It performs one row lookup per marker
  miss and a second marker probe per no-op or rejection. On a second miss after a no-op it
  attempts an insert and looks up the winner on conflict.

Not required for acceptance, and out of scope per IR-65: effectful handlers inside table
mode's transaction; multi-command reactions; a process-manager variant of the new adapter;
acknowledging typed rejections; batch-level no-op handling beyond what
`runInboxDelegatedBatch` already does with the handler's result.


## Idempotence and Recovery

Every step is additive and repeatable. Builds and tests create and discard their own
ephemeral PostgreSQL databases through `keiro-test-support`. The DSL scaffold can be
rerun on this fixture. Review its generated diff and validate with the corpus gate from a
clean checkpoint. There is no database migration.

An adopter keeping its consumer, source, dedupe policy, target and operation retains its
existing event markers. Before enabling the new adapter, verify that ordinary inbox writers
for the source cannot use the reserved row keys described below and that no historical rows
already occupy them. Isolate the intake in a separate database if that namespace cannot
be reserved. Keep each delegated batch scoped to one intake with stable routing per
delivery, as its in-memory duplicate cache still uses the ordinary delivery identity.
A change of ownership or routing needs the explicit replay boundary described in ADR-43.

## Interfaces and Dependencies

Keep the existing package dependencies. Compute the marker once with
`delegatedEventId consumer event.source dedupeKey targetStream operation`, using the
dedupe key that the delegated wrapper passes to the handler. Use the envelope source and
`"keiro/inbox-delegated-noop/1:" <> UUID.toText (unEventId marker)` as the row's primary
key pair. Reserve that key prefix among all writers for each participating source. The
prefix and marker inputs are persisted replay identity. This lets table-mode receipts for
ordinary message IDs coexist with independently scoped delegated commands.

Export the following adapter surface from
`Keiro.Inbox.Delegated` in `keiro/src/Keiro/Inbox/Delegated.hs`:

```haskell
-- | The reserved inbox row key for one delegated command's no-op receipt:
-- @"keiro/inbox-delegated-noop/1:" <> UUID.toText marker@. Persisted replay identity.
delegatedNoOpReceiptKey :: EventId -> Text

-- | What the adapter needs to write the inbox row that acknowledges a typed no-op.
data DelegatedNoOpReceipt = DelegatedNoOpReceipt
  { consumer :: !Text,
    operation :: !Text,
    dedupeKey :: !Text,
    event :: !IntegrationEvent,
    kafka :: !(Maybe KafkaDeliveryRef),
    persistence :: !InboxPersistence
  }
  deriving stock (Generic)

-- | The first-time result of a delegated domain command.
data DelegatedDomainResult target co noOp
  = -- | Events were appended; the first carries the marker. No inbox row was written.
    DelegatedDomainAccepted !(NonEmpty co) !(CommandResult target)
  | -- | A typed no-op; a completed inbox row is the receipt.
    DelegatedDomainNoOp !noOp !(CommandResult target)
  deriving stock (Generic, Eq, Show)

-- | Why a delegated domain command was not acknowledged.
data DelegatedDomainCommandError rejection
  = DelegatedDomainCommandError !DelegatedCommandError
  | -- | A typed rejection. Never acknowledged; the caller owns retry or dead-letter policy.
    DelegatedDomainRejected !StreamName !rejection
  | -- | An inbox row for this identity exists in a non-completed status.
    DelegatedNoOpReceiptUnavailable !StreamName !InboxStatus
  | DelegatedNoOpReceiptLost !StreamName
  deriving stock (Generic, Eq, Show)

delegatedDomainCommand ::
  forall target co rejection noOp es.
  (IOE :> es, Store :> es) =>
  DelegatedNoOpReceipt ->
  RunCommandOptions ->
  StreamName ->
  (RunCommandOptions -> Eff es (Either CommandError (DomainCommandOutcome target co rejection noOp))) ->
  Eff es (Either (DelegatedDomainCommandError rejection) (DelegatedOutcome (DelegatedDomainResult target co noOp)))
```

Constructor and field names may be adjusted for consistency with the module during
implementation, but the shape (a separate function, a no-op-carrying fresh result, a
rejection-carrying error, the receipt record) is the contract Milestones 2 and 3 depend on;
record any rename in the Decision Log. Keep the rejection payload in the typed return value. The adapter and hand-written
DSL example must keep it out of generic errors, telemetry, and logs, consistent with ADR-29.

Existing interfaces retain their current signatures and behavior: `Keiro.Inbox.Schema`
(`tryInsertCompletedTx`, `lookupInbox`), `Keiro.ProcessManager.dispatchDeduplicatedCommand`,
`Keiro.Command` (`DomainCommandOutcome`, `DomainDecision`, `runDomainCommand`),
`Keiro.Inbox.Types` (`DelegatedOutcome`, `InboxPersistence`, `InboxStatus`,
`KafkaDeliveryRef`), and the generated `runInboxIntake` emitted by `scaffoldIntake` logic in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`.


Revision on 2026-11-18 after review. Tightened the replay precondition to match IR-65
AC-2, aligned row identity with the event marker, and required evidence of a committed
receipt under concurrent delivery and retention. Added the corresponding runtime and
generated-intake checks and corrected how to bootstrap the conformance suite.

Second revision on 2026-11-18 after a follow-up review. Added a marker recheck on the
rejection path, exported and pinned the row-key derivation, replaced the access-control
test's reference to a fixture that does not exist with concrete setup, added the
record-migration inventory refresh, and named the benchmark gate for the refactored
table-mode insert.
