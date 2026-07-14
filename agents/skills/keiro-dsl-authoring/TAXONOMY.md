# Runtime rejection and replay-safety playbook

Use this page when a filled hole compiles but the generated harness reports validation
warnings, startup throws `is not replay-safe`, or a worker reports a command failure. These
failures are contracts, not tuning hints: fix the hand-owned transducer or disposition; never
edit the generated `EventStream` module.

## The generated event-stream gate

Every generated aggregate ends by validating its raw definition:

```haskell
reservationEventStream = mkEventStreamOrThrow "Reservation" reservationEventStreamDef
```

An unsafe fill throws at startup with this shape:

```text
Keiro.EventStream.Validate.mkEventStreamOrThrow: Reservation is not replay-safe: [...]
```

The generated harness runs `validateTransducer defaultValidationOptions` first, so it finds
the same transducer defects before startup. Keiro force-enables `checkHeadRecoverability`
and `checkStateChangingEpsilon` at the durable event-stream boundary even if caller-supplied
options turn them off. Do not bypass the finding with `mkEventStreamUnchecked`; that function
is for tests and emergency forensics and can admit a stream whose persisted events cannot
reconstruct its state.

The warning text names a source vertex after `@` and then explains the affected edge. Start
with that vertex in the hand-owned `Holes.hs` transducer.

| Warning | Meaning | First corrective move |
|---|---|---|
| `hidden-input` | An edge consumes command data that its emitted event does not preserve, so replay cannot reconstruct the command. | Put every replay-relevant consumed field on the emitted event, or stop reading data that is not persistent. |
| `head-unrecoverable` | A multi-event edge puts command data only in a later event, but replay selects the edge from the first event. | Move the missing fields onto the first event, or reshape the transition so its first event is independently recoverable. |
| `inversion-ambiguity` | Two outgoing edges emit the same first wire constructor, so an observed event may invert to either edge. | Give the histories distinct first event constructors, or restructure the edges so one observed head event selects exactly one edge. |
| `unguarded-input-read` | A guard, update, or output reads one command constructor before a matching constructor guard establishes it. Another command can make evaluation crash. | Build the edge with the matching `onCmd`/constructor guard first; keep that guard to the left of any field read. |
| `state-changing-epsilon` | An edge emits no event but changes vertex or can write registers. Persisted replay cannot observe that state change. | Emit an event on the edge; the detailed fixes are below. |
| `nondeterministic` | Two outgoing guards can both match the same command, producing the runtime's ambiguous-edge condition. | Make the guards mutually exclusive and add harness examples at the boundary between them. |
| `possibly-dead` | The source vertex is unreachable or the guard is structurally unsatisfiable. The analysis is conservative. | Connect the state from a reachable transition, correct the impossible guard, or remove the obsolete edge. |
| `opaque-guard` | A guard uses an opaque function application that the symbolic checks cannot inspect, so single-valuedness is under-verified. This audit is opt-in. | Prefer first-class structural predicates; otherwise enable the opaque audit, add solver-backed checks where appropriate, and document the justified opaque condition. |

## Fixing `state-changing-epsilon`

An epsilon edge is a transition whose output list is empty: it emits no domain event. It is
safe only when it is a no-op self-loop with no register writes. If it goes to another vertex
or can write any register, forward execution changes state while the event log records
nothing. Rehydration then reconstructs a different state.

Fix it in this order:

1. Emit a domain event on the edge. If the state change matters after restart, it is history
   and belongs in the log.
2. If the edge is only an intermediate control step, fold its state change into the adjacent
   event-emitting transition that caused it.
3. If the value genuinely need not survive restart, remove it from the durable transducer
   register file and keep it in runtime-local code instead.

Never disable the check or replace the generated constructor with `mkEventStreamUnchecked`.
A red `validateTransducer` harness assertion and a startup
`state-changing-epsilon @Held` throw are the same defect at different times.

## Command failures and `CommandAmbiguous`

`CommandRejected` means no edge matched the command in the hydrated state. That can be an
expected business race; for example, a replayed timer may deliberately map `on-reject` to
`Fired`.

`CommandAmbiguous [i, j, ...]` means two or more zero-based edge indices matched the same
command. It is a deterministic aggregate-definition bug, not a business rejection and not a
transient store failure. Fix the transducer by making the competing guards mutually
exclusive; never retry it as though infrastructure might heal it and never acknowledge it
as benign.

The runtime nevertheless classifies both constructors as the **rejection class** for worker
policy. The DSL therefore uses two honest surfaces:

- Ordinary process and router dispatches route `CommandAmbiguous` through the node-level
  `rejected => halt | deadLetter | skip` policy. A warning reminds you when the policy can
  acknowledge or dead-letter the definition bug.
- A process timer's generated case expression has a mandatory, separate `on-ambiguous` arm.
  `on-ambiguous Fired` is rejected by `check`; use `Retry` so the declared attempt ceiling
  produces a durable dead-letter witness.

`on-duplicate AckOk` is unrelated. A duplicate append is benign only after
`confirmBenignDuplicate` proves the attempted event id exists in the target stream.
`CommandAmbiguous` is neither a duplicate nor a successful prior append and must never flow
through that acknowledgement.
