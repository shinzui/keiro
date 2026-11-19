---
type: Improvement Request
title: Let delegated intake acknowledge a command that was a typed no-op
description: >-
  Delegated inbox intake refuses any command that appends no event, and table-mode intake can't
  run a Keiro command at all. So an intake whose command is legitimately a no-op on some
  deliveries can use neither runner. It has to run the command and then record the inbox receipt
  in a separate step.
timestamp: 2026-11-18T23:55:00Z
requestId: IR-65
status: completed
origin: mori://tan/agent-reputation-service
plan: docs/plans/344-let-delegated-intake-acknowledge-a-command-that-was-a-typed-no-op.md
relatedPlans:
  - mori://tan/agent-reputation-service/plans/10-record-invitation-delivery-outcomes-from-notification-hub
  - mori://tan/agent-reputation-service/plans/8-resolve-invitations-from-registration-service-v2-completion-events
acceptanceCriteria:
  - id: AC-1
    statement: >-
      A delegated intake can acknowledge a delivery whose command succeeded with an explicit,
      typed no-op outcome, recording the inbox row as processed with no event receipt. An
      untyped success that appended nothing is still refused.
    verification: >-
      Tests with an aggregate whose guard returns a typed no-op: the first delivery records the
      row, a redelivery is a duplicate, and a command that silently appends nothing is still
      `DelegatedCommandWithoutReceipt`.
  - id: AC-2
    statement: >-
      The guarantee is documented. A typed no-op is acknowledged only when repeating the command
      is also a no-op, so the inbox row alone proves the delivery was handled.
    verification: >-
      Documentation review of the inbox section of the user docs and the `Keiro.Inbox.Delegated`
      Haddock.
  - id: AC-3
    statement: >-
      keiro-dsl `intake` declarations can target such a command in delegated mode.
    verification: >-
      A generated intake for a command with a no-op edge compiles and passes the AC-1 scenarios.
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-11-18T16:13:37Z
    document_timestamp: 2026-11-18T16:13:37Z
    scope: technical-accuracy
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      The authoring model's own verification, not an independent review. At keiro commit 2e54849b
      it read `delegatedCommand` in keiro/src/Keiro/Inbox/Delegated.hs, where a success with
      `eventsAppended == 0` becomes `DelegatedCommandWithoutReceipt`, and the module header saying
      delegated adapters "refuse to acknowledge ... successful commands that appended no event". It
      also read `runInboxTransactionWith` in keiro/src/Keiro/Inbox.hs, whose handler is
      `IntegrationEvent -> Tx.Transaction a`. How a typed no-op is represented is Keiro's to
      decide; IR-51, which lets a timer fire finish without an event, may share the
      representation.
---

# Let delegated intake acknowledge a command that was a typed no-op

## Status

Completed on 2026-11-18 by
[ExecPlan 344](../plans/344-let-delegated-intake-acknowledge-a-command-that-was-a-typed-no-op.md).
`Keiro.Inbox.Delegated.delegatedDomainCommand` runs one typed domain command. It
acknowledges an accepted decision by its marker event. It acknowledges a replay-stable
`DomainNoOp` only after committing a completed inbox row under the reserved key
`delegatedNoOpReceiptKey marker`.

- AC-1: the `keiro-test` block "Keiro.Inbox delegated typed no-op" covers a first no-op
  delivery recording one completed row, a redelivery that is a duplicate without dispatch,
  and replay after a state change and after retention. It also covers accepted commands,
  typed rejections, concurrent-delivery races, and the strict-insert and privilege paths.
  The unedited test "rejects zero-event commands and unconfirmed duplicate errors" still
  passes and shows that an untyped zero-event success is `DelegatedCommandWithoutReceipt`.
- AC-2: the guarantee and the caller obligations are stated in the
  `delegatedDomainCommand` Haddock, in `docs/user/inbox.md` ("Typed no-op receipts") and
  in an amendment to ADR-43. The guarantee includes replay stability, SELECT and INSERT
  privileges, the reserved key prefix and the retention horizon.
- AC-3: an `intake` declaration names no command, so the request is met without new
  syntax. `keiro-dsl-conformance-intake-delegated-noop` scaffolds a delegated intake and
  an outcome-enabled aggregate with an `outcome no-op` edge from
  `keiro-dsl/test/fixtures/intake-delegated-noop.keiro`. It drives the generated
  `runInboxIntake` through the new adapter against PostgreSQL and passes the AC-1
  scenarios.

The typed no-op is the existing `DomainNoOp` of ADR-29, so this request shares no new
type with IR-51.

## Problem

Keiro offers two inbox modes, and neither fits an intake whose command is sometimes a no-op:

- **Table mode** (`runInboxTransaction`, `runInboxTransactionWith`) runs a handler of type
  `IntegrationEvent -> Tx.Transaction a` in the same transaction as the inbox row. It can't run a
  Keiro command, which needs the event store effect.
- **Delegated mode** (`Keiro.Inbox.Delegated.delegatedCommand`) runs a command and treats its
  appended event as the durable receipt. A successful command that appends no event is refused as
  `DelegatedCommandWithoutReceipt`.

`mori://tan/agent-reputation-service` records invitation-email delivery outcomes from
notification-hub. Its rule is that a delivery status never moves backwards: once an invitation
reads delivered, a late failed outcome changes nothing. That later delivery is a correct, typed
no-op, but delegated intake refuses it, and table mode can't run the command.

The service therefore runs the command first and records the inbox receipt afterwards, outside
Keiro's runner. That is safe only because the command is idempotent, which the runner can't
check. Its registration intake, which resolves invitations, has the same shape: a replayed
registration resolves nothing new.

## Request

Let delegated intake acknowledge a command that returned an explicit, typed no-op outcome,
recording the inbox row without an event receipt. Keep refusing successes that appended nothing
without saying so. Let keiro-dsl `intake` declarations target such commands.

## Out of scope

- Running arbitrary effectful handlers inside table mode's transaction.
- Multi-command reactions, which `delegatedFromPMCommand` already scopes.
