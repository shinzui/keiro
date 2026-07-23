# Adopting Keiro From tan-event-source

This document is for engineers evaluating the migration from
`tan-event-source` (the in-house decide/evolve framework at
`work/libraries/haskell/tan-event-source`) to the keiro/keiki runtime. It
answers the objection "keiro's evolution story looks complicated — tan-ES never
had these problems" honestly: by walking every change class an event-sourced
service faces over its lifetime and comparing, with code citations, what each
framework does. The companion document
[Evolution And Replayability](evolution-and-replayability.md) is the full keiro
treatment; this one is the comparison.

The one-sentence summary: **keiro did not create these problems — it is the
first thing in this stack that can see them.** Every failure class below is a
property of event sourcing itself (events are forever; every code change is a
change to the interpretation of stored data). tan-ES has almost all of them in
*silent, ungated* form. keiro makes one new trade — decision logic is on the
replay path — and in exchange eliminates tan-ES's worst silent bug class and
makes every remaining class detectable.


## The two architectures in one paragraph each

**tan-event-source** is a 558-line decide/evolve library. An aggregate is a
`Decider` with two independent functions — `decide :: c -> si -> [eo]` (command
→ events) and `evolve :: si -> ei -> so` (the fold) — plus `initialState` and
`isTerminal` (`src/TanES/Decider.hs:23-28`). A process manager is the same
shape with `ingest`/`pending` (`src/TanES/ProcessManager.hs:31-37`). Events
serialize through a derived aeson tagged sum (`src/TanES/Aeson.hs:5-7`).
Rebuilding state = folding stored events through `evolve`. `decide` is never
consulted during replay.

**keiro/keiki** models an aggregate (and a process manager's saga — same
machinery, `keiro/src/Keiro/ProcessManager.hs:471-477`) as a single symbolic
edge set: each edge is `guard → (emit events, write registers, goto state)`.
The same edges serve forward execution and replay: rebuilding state re-inverts
each stored event to the command that produced it, re-checks the edge's guard,
and applies the edge's writes (`keiki/src/Keiki/Core.hs:1222-1229`). Codecs
carry schema versions and upcaster chains; snapshots carry a compatibility
discriminator; a spec DSL generates, validates, and diffs the whole machine.


## The comparison, change class by change class

Statements about keiro assume master plan 24
(`docs/masterplans/24-close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review.md`)
is implemented; where a gate is still planned, the class is marked *(planned)*
with the plan path. "Silent" means wrong behaviour with no error, ever.

| Change over a service's lifetime | tan-event-source | keiro |
|---|---|---|
| Add a new event type | Safe (old streams unaffected) | Safe; `diff` classifies ADDITIVE |
| Add a required field to an event with stored history | Old events **fail to decode** — or are **silently dropped** by adapter combinators (see below). No versioning mechanism exists to fix it properly | Version bump + upcaster; `diff` refuses the unbumped variant (BREAKING); chain validated at startup *(planned: docs/plans/139)*; golden old payloads decode in CI *(planned: docs/plans/139/140)* |
| Rename / retype / remove a field | Same as above: decode failure or **silent data loss** (unknown keys ignored, fold loses the value — wrong state, no error) | Same versioned path; all variants BREAKING in `diff` without a bump |
| Event no longer handled by the fold | **Silent no-op**: `lmapMaybeE` folds unmatched events as identity (`src/TanES/Decider.hs:61-65`; same on views, `src/TanES/View.hs:47-51`); wildcard `evolve` arms do the same. State silently wrong | Impossible to express: every stored event must invert through an edge or replay fails loudly (`HydrationNoInvertingEdge`); retirement has a guided procedure *(planned: docs/plans/139)* |
| `decide` emits an event `evolve` mishandles (drift) | **The worst one. Silent and structurally undetectable**: `decide` and `evolve` are two unrelated functions; nothing checks that an emitted event has the intended fold semantics. The command "succeeds", state is wrong forever | Unrepresentable: emit and write are one edge; validation proves every event inverts, exhaustively, at startup |
| Change the fold (evolve / edge update) | Reinterprets all history — inherent to event sourcing, identical in both. tan-ES has no snapshots in the library, so no stale-seed variant *in the library* — and no discipline for services that cache state on their own | Same reinterpretation, plus: spec-visible fold changes auto-invalidate snapshots *(planned: docs/plans/138)*; hand-written/hole changes are caught by the sampled runtime witness and the pre-deploy audit *(planned: docs/plans/142)* |
| Tighten a command guard | **Replay-immune** (replay never consults `decide`). tan-ES genuinely does not have this problem | **Replay-relevant** — the honest concession, treated in its own section below |
| Unknown event type in a stream (rollback after deploy) | Decode failure or silent skip, service-dependent | Loud typed error (`UnknownEventType` → `HydrationDecodeFailed`); roll-forward rule documented |
| Old binary meets new-version payload | No versions, so undefined — whatever partial decode does | Loud `VersionAhead`; deploy-ordering rules documented *(planned: docs/plans/141)* |
| Any of the above, pre-deploy detection | **None. No validator, no differ, no startup check, no audit exists** | `keiro-dsl check` + `diff` verdicts, startup validation, replay-impact verdict + targeted audit against real data *(planned: docs/plans/142)* |

Two rows deserve emphasis for a skeptical audience:

**"We never hit these problems with tan-ES" is mostly silence, not absence.**
Four of the rows above fail *silently* in tan-ES — dropped events, wildcard
folds, silent field loss, decide/evolve drift. A team cannot know how often it
has hit them; the symptom is "weird data bug, patched by hand, cause never
found." The visible difference between the frameworks is not the number of
problems; it is that keiro's are enumerated, named, and gated.

**The drift row is the answer to "why a single edge set at all."** tan-ES's
central structural risk — that the write path and the replay path disagree —
is the exact bug class keiki's design makes unrepresentable. Keiro pays for
that with the guard-tightening sensitivity below. That trade is the whole
architectural argument, and it should be debated as a trade, not as
"complexity vs simplicity."


## The honest concession: guard changes are replay-relevant in keiro

Worked example (the "black-acuity" case). Version 1, deployed in January:

```text
state Held
  on ConfirmReservation
    guard  divertStatus == open
    emits  TransferReservationConfirmed
```

In March, a black-acuity confirmation is legally appended to stream
`reservation-8841`. In July the rule tightens:

```text
    guard  divertStatus == open && patientAcuity != black
```

Every static gate passes — the new machine is self-consistent. But replay
re-checks guards against history: the March event's reconstructed command no
longer satisfies the new guard, no other edge emits that event, and the next
command on `reservation-8841` fails `HydrationNoInvertingEdge`. Streams whose
history never exercised the removed guard region are untouched. In tan-ES this
cannot happen, because replay never looks at decision logic.

Why it cannot be *fully* detected statically: whether the tightening breaks
anything depends on whether any stored event was written under the
now-excluded condition — a fact about the database, not the spec. Static
analysis can prove safety when no guard changed, and can name the danger when
one did; only data can convert "maybe" into "stream 8841" or "clean".

What keiro does about it (master plan 24):

1. **It is flagged the moment it is made** — `diff` emits a fold/transition
   surface advisory on any guard change *(docs/plans/138)* and a replay-impact
   verdict naming the affected event types *(docs/plans/142)*.
2. **It is checked against real data before traffic switches** — the targeted
   replay audit replays exactly the streams containing the affected event
   types (proportional to the change, not the store) *(docs/plans/142)*.
3. **The fix is a first-class, one-keyword pattern — and the tool writes it
   for you.** A `replay-only` transition carrying the *removed* guard region
   keeps history invertible while being excluded from forward execution, so
   the business rule tightens for the future without reinterpreting or
   breaking the past. The removed region is mechanical (`old-guard ∧
   ¬new-guard`), so the `diff` advisory prints the paste-ready twin transition
   whenever it detects a tightening — the developer pastes it or proves via
   the audit that no stored stream needs it *(planned: docs/plans/143)*. The
   old rule stays visible in the spec as a record of what was once allowed —
   which is exactly what an event-sourced model should preserve.

With those three in place the concession reads: *guard changes require one
explicit keyword and a verdict-guided check, instead of being silently immune
and silently drifting.* That is the mature version of the trade.


## What migration itself buys

The keiki-runtime cutover is also the moment the safety story starts being
*checked* rather than assumed:

- The one-time full replay audit (`AuditFull`, docs/plans/142) replays a
  service's entire history through the ported machine before it takes traffic
  — "did we port the semantics correctly" becomes a mechanical fact on day
  one, per stream, not a code-review hope. No such check is expressible in
  tan-ES.
- From then on, routine deploys ride the differential gates: most are proved
  replay-neutral with zero data touched; the rest name their affected surface
  and the procedure to follow.
- The DSL spec replaces per-service re-derivation of all of this discipline.
  A tan-ES service's safety today rests on every engineer independently
  remembering rules that are written nowhere.


## Objection quick answers

- *"This is too complex."* The complexity is event sourcing's, made explicit
  once, in the framework. The tan-ES alternative is the same complexity,
  unwritten, re-solved (or shipped as a bug) per service per incident.
- *"tan-ES never needed an evolution guide."* tan-ES cannot express versions,
  upcasts, retirement, or replay validation at all; there was nothing to write
  a guide about. Absence of machinery is not absence of the problem.
- *"Guard changes breaking replay is scary."* It is the one genuinely new
  sensitivity, it is loud rather than silent, it is flagged at diff time,
  checked against real data pre-deploy, and has a one-keyword remedy
  (`replay-only`) — versus tan-ES's counterpart risk (decide/evolve drift),
  which is silent, unflagged, and unfixable by construction.
- *"Can we roll back if keiro doesn't work out?"* Events are stored in kiroku
  as plain versioned JSON with explicit metadata; nothing about the format is
  keiro-proprietary magic. The lock-in surface is the transducer/spec layer,
  which is precisely the layer tan-ES never had.
