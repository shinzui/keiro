---
id: 261
slug: make-the-durable-workflow-example-and-guides-prove-the-live-contract
title: "Make the durable workflow example and guides prove the live contract"
kind: exec-plan
created_at: 2026-08-14T13:33:19Z
intention: "intention_01m0075g1kecjb2959gy704yhc"
master_plan: "docs/masterplans/42-fix-the-final-keiro-release-blockers-and-publish-stable-language-5.md"
---

# Make the durable workflow example and guides prove the live contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, the runnable order-fulfillment workflow demonstrates the contract Keiro
actually provides. It publishes the opaque `AwakeableId` returned by allocation, signals that
same value, and treats a failed signal, a non-terminal outcome, or unfinished restart state as
a test/demo failure. Its application callback is idempotent by the awakeable id because a
workflow step's external effect is at-least-once across the action-to-journal crash window.

The user reference and worked guide show the same code and guarantees. They include the real
`IOE` constraints, explain that fresh ids are random and must be handed to the external system,
and distinguish replay skipping from at-most-once delivery. A focused database test and a
compile-only guide-contract module keep the example, displayed signatures, and public API in
sync.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-14T14:52:11Z) M1: parameterize the order-fulfillment workflow and resume registry with an application-owned awakeable-id publisher
- [x] (2026-08-14T14:52:11Z) M1: journal an idempotent publication step using the real id returned by `awakeableNamed`
- [ ] M2: drive the demo with a captured published id and make every signal/completion/restart invariant fail closed
- [ ] M2: add a focused PostgreSQL Jitsurei regression that proves publication, successful signal, terminal completion, and no repeat publication after replay
- [ ] M3: correct `docs/user/durable-workflows.md`, `docs/guides/durable-workflows.md`, API reference, and Jitsurei Haddocks
- [ ] M3: add compile-owned guide signatures and complete a repository-wide stale-claim sweep
- [ ] M4: update the unreleased changelog and pass Jitsurei, documentation-adjacent, and full repository gates


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The current demo prints `signalAwakeable ... -> False`, later obtains `Suspended`, and still
  prints “durability proven.” Neither the boolean nor the final outcome participates in control
  flow.
- Under exact discovery, a workflow parked on an unresolved awakeable is intentionally absent
  from `findUnfinishedWorkflowIds`. The restart check is therefore incapable of distinguishing
  `Completed` from this parked failure without a terminal-outcome or journal assertion.
- The allocation step precedes any publication step and journals the opaque id. If publication
  repeats after a crash, it receives the same id. That makes the id itself the natural
  application idempotency key and gives the guide a concrete honest pattern.


## Decision Log

Record every decision made while working on the plan.

- Decision: Pass an application-owned `AwakeableId -> Eff es ()` publisher into the example
  workflow and registry, and run it inside a named `step` immediately after allocation.
  Rationale: The id has to cross from durable workflow code to an external callback system.
  Publishing inside the workflow is the real integration boundary; deriving it in the driver
  bypasses and contradicts allocation.
  Date: 2026-08-14
- Decision: Require the publisher to be idempotent by `AwakeableId` and document its action as
  at-least-once.
  Rationale: `step` suppresses the action after its journal record exists, but a process can
  crash after the action succeeds and before that record commits. Claiming at-most-once would
  expose consumers to duplicated irreversible effects.
  Date: 2026-08-14
- Decision: Keep both a focused database test and a failing demo path.
  Rationale: A test prevents regression in CI, while the demo must also refuse to print success
  for a suspended workflow when run by a user.
  Date: 2026-08-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`jitsurei/src/Jitsurei/DurableWorkflow.hs` is the library module behind the worked guide. Its
`orderFulfillmentWorkflow` reserves inventory, sleeps, allocates a `payment-webhook`
awakeable, charges a card, and awaits a child workflow. At the reviewed commit it discards the
id returned by `awakeableNamed` and exports `paymentWebhookAwakeableId`, which calls the legacy
coordinate derivation. Its Haddocks also claim every checkpoint side effect runs only once.

`jitsurei/app/Main.hs` implements `runDurableWorkflowDemo`. After resuming past the sleep it
signals `paymentWebhookAwakeableId`, prints the returned `Bool`, drives bounded resume passes,
prints the final outcome, and treats an empty discovery result after reopening the store as
proof of completion. [REV-3](../reviews/jitsurei-durable-workflow.md) records a fresh-database
run in which signal returned `False`, the final outcome was `Suspended`, and the success banner
still printed.

`jitsurei/test/Main.hs` already uses `Keiro.Test.Postgres` and runs under a migrated fixture,
but it has no durable-workflow example test. Add the focused regression there. A small new
module such as `jitsurei/test/WorkflowGuideContract.hs`, listed in `jitsurei/jitsurei.cabal`,
can pin forwarding signatures displayed in the docs so an omitted `IOE` constraint becomes a
compile failure instead of prose drift.

`docs/user/durable-workflows.md` is the public reference. It currently says a step action runs
once, says a fresh awakeable id is deterministic and externally recomputable, and omits `IOE`
from `awakeableNamed` and `awaitChild`. `docs/guides/durable-workflows.md` repeats all three
claims and embeds the broken Jitsurei flow. `docs/user/api-reference.md` lists the legacy
derivation as part of the ordinary module. [REV-4](../reviews/durable-workflow-user-contract.md)
records the resulting user-safety blocker.

A workflow `step` journals a JSON result and returns that result on replay. “Replay does not
rerun the action after the record is durable” is not “the external effect happens at most
once.” If the process crashes after the action succeeds but before the journal append commits,
the next run executes the action again. Every irreversible action and publication callback
therefore needs an application idempotency key.

[ADR 5](../adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md)
explains how recorded results are recovered.
[ADR 6](../adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md)
requires the awakeable row to be registered before the returned id can be published.
[ADR 23](../adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md)
defines exact discovery and explains the false restart proof. EP-1's amendment to
[ADR 24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
is an input: compatibility derivation is not a fresh allocation API. No new ADR is expected
unless implementation introduces a reusable publication abstraction beyond this example. No
cross-repository ADR applies.


## Plan of Work

Milestone 1 replaces derivation with publication. In
`jitsurei/src/Jitsurei/DurableWorkflow.hs`, delete `paymentWebhookAwakeableId` and every legacy
derivation import. Change `orderFulfillmentWorkflow` to accept a publisher callback. Bind the
real id from `awakeableNamed`, then run a named `publish-payment-webhook-id` step whose action
calls the publisher with that id and returns `()`. The step name is new because publication
was not previously journaled. Add `jitsureiWorkflowRegistryWith` so resume execution receives
the same callback; keep `jitsureiWorkflowRegistry` as a convenience built with an explicit
logging publisher that prints the real id rather than silently discarding it. Describe the
publisher's idempotency requirement in Haddock.

Milestone 2 makes the example fail closed. In `runDurableWorkflowDemo`, allocate an `IORef` or
equivalent in-process callback sink, construct one registry with a publisher that writes the
actual id, and use that same registry for every resume pass. After the pass that arms the
awakeable, require exactly one published id. Signal it and fail unless the result is `True`.
Require the final outcome to be `Completed` with the expected tracking number. After reopening
the store, require no unfinished parent/child and verify the parent journal contains
`WorkflowCompleted`; only then print the durability banner. Change bounded timer/resume helpers
to fail rather than warn when their bounds are exhausted. Add a `Jitsurei durable workflow`
group to `jitsurei/test/Main.hs` using a fresh migrated resource. It should run the workflow,
capture the id, signal it, resume to terminal completion, and assert the publisher does not run
again once its step is journaled.

Milestone 3 rewrites the contract once, then mirrors it. Correct module Haddocks and both docs:
a step result is replay-skipped after commit but its action effect is at-least-once across the
crash window; a fresh awakeable id is opaque and journaled; allocation code must publish the
returned id; the callback must deduplicate on that id; and `continueAsNew` publishes a fresh id
for the new generation. Fix displayed `IOE` constraints for `awakeableNamed` and `awaitChild`.
Update journal prose from “deterministic awakeable id” to “journaled opaque awakeable id.”
Update the API reference so compatibility derivation is documented only under EP-1's qualified
compatibility module. Add compile-owned forwarding functions in
`jitsurei/test/WorkflowGuideContract.hs` for every displayed primitive signature and import the
actual example where possible instead of maintaining a second invented snippet.

Milestone 4 updates the `Unreleased` changelogs and validates. Perform a repository-wide search
over current user docs and Jitsurei source for “runs once,” “at most once,” “deterministic
awakeable,” and the removed derivation names. Classify every remaining mention; keep historical
plans, ADR compatibility prose, and old review evidence intact. Run the focused Jitsurei test,
the real `jitsurei-workflow` demo, documentation-adjacent build, and full verification. Record
the completed transcript for EP-4.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Capture the current false-positive transcript
before editing:

```bash
just jitsurei-workflow
```

The reviewed failure signature is:

```text
signalAwakeable payment-webhook -> False
final outcome: Suspended
durability proven: the completed workflow was NOT re-executed from scratch
```

After adding the focused test and compile-owned guide module, run:

```bash
cabal test jitsurei-test --test-options='--match "Jitsurei durable workflow"'
cabal build jitsurei:lib:jitsurei jitsurei:test:jitsurei-test jitsurei:exe:jitsurei-demo
```

Run the live demo again:

```bash
just jitsurei-workflow
```

Its essential post-fix transcript is equivalent to:

```text
published payment-webhook awakeable id: <opaque-uuid>
signalAwakeable payment-webhook -> True
final outcome: Completed "TRK-..."
restart: resume worker discovery found no unfinished work
durability proven: completed workflow journal survived restart
```

Sweep the current teaching/application surface:

```bash
rg -n "deterministic.*awakeable|recomput.*awakeable|at-most-once|at most once|runs once|never repeats|deterministicAwakeableId|paymentWebhookAwakeableId" docs/user docs/guides jitsurei/src jitsurei/app jitsurei/test
```

Finish with the package and repository gates:

```bash
cabal test jitsurei-test
just jitsurei
just verify
```


## Validation and Acceptance

The focused database test must prove that the publisher receives the same opaque id returned by
allocation, `signalAwakeable` returns `True`, the parent reaches `Completed`, its child reaches
completion, and replay does not re-run a publication step whose journal append is durable. The
test must also assert the publication callback receives the same id if deliberately retried in
the action-to-journal window, or document the equivalent runtime test that covers that crash
window.

The demo must exit non-zero on missing publication, `False` signal, pass-bound exhaustion,
unexpected terminal outcome, missing `WorkflowCompleted`, or remaining unfinished work. It may
print the success banner only after all of those checks pass. A normal `just jitsurei-workflow`
run must print `True` and `Completed`.

Both workflow documents and all live Haddocks must state the at-least-once action boundary and
opaque-id handoff. Their displayed `awakeableNamed` and `awaitChild` signatures include `IOE`.
The compile-owned guide module builds against the public packages. The stale-claim sweep has no
unexplained live match, `cabal test jitsurei-test`, `just jitsurei`, and `just verify` pass.


## Idempotence and Recovery

The example publisher must be safe to call repeatedly with the same `AwakeableId`; the demo's
`IORef` assignment is naturally idempotent, and the guide must require a real external store or
API to upsert/deduplicate on the id. Re-running the workflow or tests against a fresh fixture is
safe. `just jitsurei-workflow` creates a fresh order id, so repeat runs do not reuse the same
workflow instance.

If a demo run stops after allocation, its database rows are ordinary example data and a new run
uses a new id. Do not delete or rewrite workflow history to make the demo pass. Diagnose the
journal and signal path, then retry with a fresh order. No destructive operation is required.


## Interfaces and Dependencies

The application publication seam is explicit in the Jitsurei module:

```haskell
type PublishPaymentAwakeable es = AwakeableId -> Eff es ()

orderFulfillmentWorkflow
  :: (Workflow :> es, Store :> es, IOE :> es)
  => PublishPaymentAwakeable es
  -> OrderId
  -> Eff es Text

jitsureiWorkflowRegistryWith
  :: (Store :> es, IOE :> es)
  => PublishPaymentAwakeable es
  -> WorkflowRegistry es
```

The exact type synonym name may be adjusted for readability, but the callback must receive the
allocated id and no workflow coordinates from which to derive one. The convenience
`jitsureiWorkflowRegistry` remains available for the operations demo and uses a visible logging
publisher.

The guide-contract module pins at least these live constraints:

```haskell
awakeableNamed
  :: (Workflow :> es, Store :> es, IOE :> es, FromJSON a)
  => StepName
  -> Eff es (AwakeableId, Eff es a)

awaitChild
  :: (Workflow :> es, Store :> es, IOE :> es, FromJSON a)
  => ChildHandle a
  -> Eff es a
```

Use the existing `effectful`, `keiro`, `jitsurei`, `keiro-test-support`, and PostgreSQL fixture
dependencies. This plan consumes EP-1's `Keiro.Workflow.Awakeable` surface; it must not import
`Keiro.Workflow.Awakeable.Compatibility`.
