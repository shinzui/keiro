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
changes: the event is the receipt. When the command returns an explicit, typed no-op, the
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

- [ ] Milestone 1: `delegatedDomainCommand` exists in `keiro/src/Keiro/Inbox/Delegated.hs`
  and the new "Keiro.Inbox delegated typed no-op" tests pass in `keiro-test`, while every
  existing delegated test passes unchanged (IR-65 AC-1).
- [ ] Milestone 2: a generated `idempotence delegated` intake drives an aggregate with a
  no-op edge through the new adapter in `keiro-dsl-conformance-intake-delegated-noop`, and
  the DSL diagnostic and corpus are consistent with it (IR-65 AC-3).
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

- Decision: The no-op receipt is an ordinary `completed` row in `keiro.keiro_inbox`, written
  by the adapter with the existing `tryInsertCompletedTx`. No migration, no new column, no
  new status.
  Rationale: IR-65 asks for "the inbox row as processed with no event receipt". Reusing the
  existing row shape gives the no-op the inbox's existing retention
  (`garbageCollectCompleted`) and inspection (`lookupInbox`, `listInbox`) for free. A
  distinguishing column would be a schema change no acceptance criterion needs.
  Date: 2026-11-18

- Decision: The adapter looks up the inbox row before dispatching the command, after the
  event-marker probe misses.
  Rationale: Without the lookup, a redelivery of a delivery already acknowledged as a no-op
  would re-run the command, and if aggregate state had changed in between it could append an
  event for a delivery Keiro already reported as handled. With the lookup, the row really is
  sufficient proof and the redelivery costs one primary-key read instead of a hydration. The
  cost is one extra indexed read on each fresh delivery, paid only by callers of the new
  adapter.
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
root, for example `nix develop -c cabal test keiro-test`. Do not enter the shell from a
package subdirectory: doing so creates a stray database cluster there.

Terms used in this plan:

An **integration event** is a message one service publishes for others, represented by
`Keiro.Integration.Event.IntegrationEvent`. **Intake** is the consuming side: receive the
message and apply it locally exactly once even though the broker may deliver it several
times. The **dedupe key** is the stable identity of a delivery, computed by
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

In `keiro/src/Keiro/Inbox/Delegated.hs`, add the types and function specified in
Interfaces and Dependencies. The behaviour, in order:

1. Replace the options' `eventIds` with the singleton marker, exactly as `delegatedCommand`
   does.
2. Probe the marker in the target stream. A hit returns `Right DelegatedDuplicate` and does
   nothing else. Reuse `dispatchDeduplicatedCommand` for steps 2, 4, and the concurrent
   duplicate-append confirmation, by making steps 3 to 6 its dispatch action and success
   classifier (the dispatch action may return its own small internal sum to carry "row
   already present" out through the `Right` side).
3. On a marker miss, read the inbox row for `(source, dedupeKey)` with `lookupInbox` from
   `Keiro.Inbox.Schema`. A `completed` row returns `Right DelegatedDuplicate` without
   invoking the callback. A row in any other status returns
   `Left (DelegatedNoOpReceiptUnavailable targetStream status)` without invoking the
   callback: delegated intake never writes `processing` or `failed` rows, so such a row
   means the service mixed modes on one identity, and guessing would weaken either mode's
   guarantee.
4. Otherwise invoke the callback with the prepared options. A `Left CommandError` follows
   the existing path: confirmed concurrent duplicate becomes `Right DelegatedDuplicate`,
   anything else becomes `Left (DelegatedDomainCommandError (DelegatedCommandFailed ...))`.
5. `DomainAccepted events` with `eventsAppended > 0` returns
   `Right (DelegatedFresh (DelegatedDomainAccepted events result))` and writes no inbox
   row. `DomainAccepted` with zero appended events cannot be produced by Keiro's runners,
   but the callback is caller code, so map it to
   `Left (DelegatedDomainCommandError (DelegatedCommandWithoutReceipt targetStream))`.
   `DomainRejected r` returns `Left (DelegatedDomainRejected targetStream r)` and writes no
   row.
6. `DomainNoOp n` runs one transaction calling
   `tryInsertCompletedTx persistence source dedupeKey event kafka now`. `Right ()` (row
   inserted) returns `Right (DelegatedFresh (DelegatedDomainNoOp n result))`. `Left row`
   with status `completed` (a concurrent delivery won) returns `Right DelegatedDuplicate`;
   any other status returns the `DelegatedNoOpReceiptUnavailable` error.

`Keiro.Inbox.Delegated` will need `IOE :> es` for the clock and imports from
`Keiro.Inbox.Schema`, `Keiro.Command` (`DomainCommandOutcome`, `DomainDecision`), and
`Kiroku.Store.Transaction (runTransaction)`. Check for an import cycle: `Keiro.Inbox`
imports `Keiro.Inbox.Schema` but nothing imports `Keiro.Inbox.Delegated` except tests, so
none is expected. Do not modify `delegatedCommand`, `delegatedFromPMCommand`,
`delegatedEventId`, `DelegatedCommandError`, `DelegatedOutcome`, or anything in
`keiro/src/Keiro/Inbox.hs`.

Rewrite the module header and write the function's Haddock to state the contract from
Validation and Acceptance ("The documented guarantee"). The Haddock is part of AC-2.

In `keiro/test/Main.hs`, add `describe "Keiro.Inbox delegated typed no-op"` beside the
existing delegated block, using `withFreshResourceStore fixture`. Each test drives
`runInboxDelegated Nothing PreferIntegrationMessageId event Nothing handler`, where the
handler calls `delegatedDomainCommand` and throws on `Left` (as the existing tests do), or
calls the adapter directly when asserting on a `Left`. Use `silentChoiceDomainHandler` /
`multiCounterDomainHandler` if their command sets allow one stream to be both accepted and
no-op'd; otherwise add a small domain handler next to them whose command is accepted in the
initial state and a typed no-op afterwards. Required cases:

- First delivery whose command is a typed no-op: result is `InboxProcessed` carrying
  `DelegatedDomainNoOp`; `listInbox source` has exactly one row, status `InboxCompleted`;
  the target stream has no new event.
- Redelivery of that delivery: `InboxDuplicate`, and an `IORef` counter shows the callback
  ran once in total.
- Redelivery after aggregate state changed so the command would now be accepted: still
  `InboxDuplicate`, and the target stream gained no event. This is the case the pre-dispatch
  row lookup exists for.
- Accepted command: `InboxProcessed` carrying `DelegatedDomainAccepted`, first stored event
  id equals the marker, `listInbox source` is `[]`, redelivery is `InboxDuplicate`.
- Typed rejection: `Left (DelegatedDomainRejected target reason)`, no inbox row, and a second
  call invokes the callback again.
- A pre-existing `failed` row for the identity (create it with `recordFailedAttemptTx`):
  `Left (DelegatedNoOpReceiptUnavailable target InboxFailed)`, callback not invoked.
- `PersistDedupeOnly` in the receipt writes a row whose event has empty `payloadBytes`.
- The untyped path is unchanged: keep the existing test "rejects zero-event commands and
  unconfirmed duplicate errors" untouched and passing. It is the AC-1 proof that a silent
  zero-event success is still `DelegatedCommandWithoutReceipt`.

Add an Unreleased "New Features" entry to `keiro/CHANGELOG.md`. The change is additive
(new exports only), so it is a minor version bump under the Haskell Package Versioning
Policy; do not edit version numbers in this plan.

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

Create `keiro-dsl/test/conformance-intake-delegated-noop/` the same way the sibling
`conformance-intake-delegated/` was produced: find where that directory is registered for
regeneration (search the repository for the string `conformance-intake-delegated`, including
the `keiro-dsl-corpus-regen` executable's sources and
`keiro-dsl/test/conformance-baseline.json`), register the new directory beside it, and run
`just corpus-regen` to write the `Generated/` tree, cabal fragment, and ledger. Then add by
hand:

- A hand-written integration module (for example
  `<Context>/<Intake>/DelegatedIntegration.hs`) that builds the handler: derive the marker
  with `delegatedEventId`, build a `DelegatedNoOpReceipt` from the delivery, call
  `delegatedDomainCommand` with a callback that runs
  `runDomainCommand prepared <generated>DomainCommandHandler target command`, and pass the
  handler to the generated `runInboxIntake`. If the generated aggregate needs a
  `BehaviorHoles` module, follow `conformance-domain-outcomes/`.
- `Main.hs`, using `Keiro.Test.Postgres.withMigratedSuite` and `withFreshResourceStore` as
  `keiro-dsl/test/conformance-workflow-runtime/Main.hs` does. It runs, in order: a first
  delivery that is accepted; a second, different delivery to the same stream that is a typed
  no-op; a redelivery of that second delivery. It prints one line per check and exits
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
reworded diagnostic. Note that the working tree may hold unrelated uncommitted keiro-dsl
edits from plan 337 (`docs/plans/337-gate-all-behavior-witnesses-through-generated-service-conformance.md`);
do not revert or fold them into this plan's commits, and if `just corpus-regen` rewrites
files outside the new directory, leave those to plan 337 and record the fact in Surprises &
Discoveries.

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
  commands" need the typed-no-op exception, including that a service using it needs
  privileges on `keiro.keiro_inbox` and must schedule `garbageCollectCompleted`.
- `docs/guides/integration-events-with-kafka.md`, section "Delegating the receipt to a
  downstream command": add a short typed-no-op example.
- `docs/user/api-reference.md`: add the new exports to the `Keiro.Inbox.Delegated` list.
- `docs/user/keiro-dsl-integration.md` and `agents/skills/keiro-dsl-authoring/NOTATION.md`:
  both say delegated mode writes no inbox storage; qualify with the handler-owned no-op
  receipt.
- [ADR-43](../adr/0043-delegated-inbox-intake-uses-a-downstream-event-receipt.md): append a
  dated section recording the typed no-op receipt, the pre-dispatch lookup, the
  non-acknowledgement of typed rejections, and the retention consequence. Advance its
  `timestamp`, add the `docs/adr/log.md` entry with `okf log add`, and validate as shown in
  Concrete Steps. Preserve `docId: ADR-43`.
- If `docs/user/` documents carry a `timestamp` frontmatter field, advance it and add the
  `docs/user/log.md` entry, following the existing entries; `just user-documentation-validate`
  checks this.

Then set IR-65's `status` to `completed`, advance its `timestamp`, and add a
`**Completion**` entry to `docs/improvement-requests/log.md` in the style of the IR-63
entry. Fill in Outcomes & Retrospective.

Acceptance: `nix develop -c just verify` passes, and a reader of `docs/user/inbox.md` and
the `Keiro.Inbox.Delegated` Haddock can state when a no-op is acknowledged and what the
caller must guarantee.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro` in the
authoring checkout.

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

The `--match` filter covers the existing and the new describe blocks. Expect every listed
example to pass and a final line of the form:

```text
N examples, 0 failures
```

Milestone 2:

```bash
nix develop -c just corpus-regen
nix develop -c cabal test keiro-dsl-conformance-intake-delegated-noop --test-show-details=direct
nix develop -c just conformance-corpus-policy
nix develop -c cabal test keiro-dsl:tests
```

Expected output of the new suite (exact wording is the implementer's; one line per check,
all `True`):

```text
accepted delivery appends the marker event and writes no inbox row: True
typed no-op delivery is processed and records one completed inbox row: True
redelivered no-op is a duplicate without dispatching the command: True
```

Milestone 3:

```bash
okf validate docs/adr \
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

`delegatedDomainCommand` acknowledges a delivery in exactly three cases: the command
appended events and the first carries the marker; the marker or a completed inbox row
already exists; or the command returned `DomainNoOp` and the adapter then committed a
completed inbox row for `(source, dedupe key)`. The no-op decision and the row do not commit
atomically. If the process stops between them, nothing was acknowledged and the redelivery
evaluates the command again. A typed no-op must therefore be used only for an edge where
repeating the command is also a no-op or is still the correct effect for that delivery; the
inbox row alone then proves the delivery was handled. The row is subject to
`garbageCollectCompleted`: after retention removes it, a redelivery evaluates the command
again, which the same obligation makes safe. Typed rejections, command errors, and untyped
zero-event successes are never acknowledged.

**Guarantees that must not weaken**, and the evidence for each:

- Existing delegated adapters: `delegatedCommand` and `delegatedFromPMCommand` are not
  edited. Evidence: the diff of `keiro/src/Keiro/Inbox/Delegated.hs` touches neither
  function body, and their existing tests pass with unedited bodies.
- Marker identity: `delegatedEventId` is not edited; its pinned-vector test "pins ASCII,
  Unicode, empty-field, and delimiter identity vectors" passes unchanged.
- Table mode: `keiro/src/Keiro/Inbox.hs` and the inbox SQL in `Keiro.Inbox.Schema` are not
  edited (the adapter only calls existing functions); the `describe "Keiro.Inbox"` block
  passes unchanged.
- Wire bytes, event folds, snapshots, and migrations: no event type, codec, schema, or
  migration changes. The DSL fixture is new, so no existing generated output changes;
  `just conformance-corpus-policy` shows the checked-in corpus is otherwise identical.
- Performance: the existing delegated and table paths execute the same code as before, so
  the `InboxDelegatedBench` benchmark in `keiro/bench/` measures an unchanged path and no
  new baseline is needed. The new adapter's cost is one extra primary-key read per fresh
  delivery and one insert per no-op, both opt-in; it is not covered by a benchmark gate, and
  this plan does not add one. Adding a benchmark leg for it would be new scope.

Not required for acceptance, and out of scope per IR-65: effectful handlers inside table
mode's transaction; multi-command reactions; a process-manager variant of the new adapter;
acknowledging typed rejections; batch-level no-op handling beyond what
`runInboxDelegatedBatch` already does with the handler's result.


## Idempotence and Recovery

Every step is additive and repeatable. Builds and tests create and discard their own
ephemeral PostgreSQL databases through `keiro-test-support`. `just corpus-regen` is
deterministic and can be re-run; if it reports differences in directories this plan does not
own, do not commit them (see Milestone 2). There is no migration, so nothing to roll back in
a database. If Milestone 1 is committed and later milestones are abandoned, the runtime is
still coherent: the new exports are simply undocumented in the user docs.

For a service adopting the adapter, no cutover is needed when it already uses delegated
intake with `delegatedCommand`: marker identity is unchanged, so previously accepted
deliveries are still duplicates. Moving from table mode is still the persisted-identity
change ADR-43 describes.


## Interfaces and Dependencies

No new package dependencies. The new public surface, all exported from
`Keiro.Inbox.Delegated` in `keiro/src/Keiro/Inbox/Delegated.hs`:

```haskell
-- | What the adapter needs to write the inbox row that acknowledges a typed no-op.
data DelegatedNoOpReceipt = DelegatedNoOpReceipt
  { source :: !Text,
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
  deriving stock (Generic, Eq, Show)

delegatedDomainCommand ::
  forall target co rejection noOp es.
  (IOE :> es, Store :> es) =>
  DelegatedNoOpReceipt ->
  RunCommandOptions ->
  StreamName ->
  EventId ->
  (RunCommandOptions -> Eff es (Either CommandError (DomainCommandOutcome target co rejection noOp))) ->
  Eff es (Either (DelegatedDomainCommandError rejection) (DelegatedOutcome (DelegatedDomainResult target co noOp)))
```

Constructor and field names may be adjusted for consistency with the module during
implementation, but the shape (a separate function, a no-op-carrying fresh result, a
rejection-carrying error, the receipt record) is the contract Milestones 2 and 3 depend on;
record any rename in the Decision Log. The rejection payload appears only in this returned
value, never in `CommandError`, telemetry, or logs, consistent with ADR-29.

Existing interfaces this work relies on and must not change: `Keiro.Inbox.Schema`
(`tryInsertCompletedTx`, `lookupInbox`), `Keiro.ProcessManager.dispatchDeduplicatedCommand`,
`Keiro.Command` (`DomainCommandOutcome`, `DomainDecision`, `runDomainCommand`),
`Keiro.Inbox.Types` (`DelegatedOutcome`, `InboxPersistence`, `InboxStatus`,
`KafkaDeliveryRef`), and the generated `runInboxIntake` emitted by `scaffoldIntake` logic in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`.
