# keiro-dsl conformance corpus

Worked examples of the typed-spec toolchain: each `.kdsl` spec paired with the validation it
passes/fails, the scaffolded layer, and (where compiled) the hand-filled reference modules
and a green harness. Use these to see exactly how a spec maps to filled holes. All paths are
under `keiro-dsl/` in the keiro repo.

## Specs (test/fixtures/)

| Spec | Node families | Demonstrates |
|---|---|---|
| `reservation.kdsl` | aggregate | the canonical aggregate (regs, guard, write, status-map) |
| `reservation-v2.kdsl` | aggregate + evolution | `event … v2 { … } upcast from v1 = HOLE`, `schemaVersion=2` |
| `reservation-{no-statusmap,bad-command,clock}.kdsl` | aggregate (negative) | `StatusMapNotTotal`, `UndeclaredCommand`, `ClockSampled` |
| `reservation-fieldadd.kdsl` | aggregate (diff) | a field added without a version bump → BREAKING |
| `order.kdsl` | aggregate (register-free) | the smoke target (OrderStream) |
| `hospital-surge.kdsl` | process + timer | the saga: correlate, dispatch, schedule, timer fire, disposition |
| `hospital-surge-{clock,dispatchid,badref}.kdsl` | process (negative) | fireAt-not-injected, runtime-owned dispatch-id, unresolved ref |
| `contract.kdsl` | contract | the cross-service Kafka schema (topics, events, typed fields) |
| `intake.kdsl` | contract + intake | the inbox: bind rows, dedupe, decode, the complete disposition table |
| `intake-{dup-retry,pf-retry,incomplete}.kdsl` | intake (negative) | the three dangerous inbox inversions + incompleteness |
| `emit.kdsl` | contract + emit + publisher | the outbox map (`_ => skip`), publisher policy, contract coupling |
| `emit-{noskip,badevent}.kdsl` | emit (negative) | skip-totality, mapping to an undeclared event |
| `reservation-work.kdsl` | workqueue + dispatch | pgmq: derive fixtures, payload map, retry, JobOutcome disposition |
| `reservation-work-{divergent,sf-deadletter,df-retry}.kdsl` | workqueue (negative) | physical-name drift, the storeFailure/decodeFailure inversions |
| `workflow.kdsl` | workflow + operation | durable workflow body + the four operation shapes |
| `workflow-signal-mismatch.kdsl` | operation (negative) | a signal with no matching await |

## Compiled conformance + harness components

| Component | Proves |
|---|---|
| `test/conformance/` (`keiro-dsl-conformance`) | the scaffolded aggregate Generated modules + a hand-filled `Holes.hs` compile against keiki/keiro; the filled transducer passes `validateTransducer`; codec round-trips; a behavioural accept. |
| `test/conformance-v2/` (`keiro-dsl-conformance-v2`) | the evolved v2 codec (`schemaVersion=2`, `upcasters`) compiles; a filled upcaster migrates a v1-tagged payload through the chain. |
| `test/conformance-process/` (`keiro-dsl-conformance-process`) | the process facts harness compiles + runs; its expectations are hand-written, so a spec mutation reddens a specific assertion. |

## Mutation / gate scripts (test/)

| Script | Shows |
|---|---|
| `mutation-test.sh` | flipping the filled guard `./=`→`.==` reddens a specific aggregate harness test |
| `diff-test.sh` | `diff --since` reports a field-add-without-bump as BREAKING (exit 1) and v2+upcaster as ADDITIVE (exit 0) |
| `process-mutation-test.sh` | flipping the timer `on-reject Fired`→`Retry` reddens the specific `onReject` process fact |

## The reference modules

`test/conformance/Generated/HospitalCapacity/Reservation/*.hs` are byte-stable raw
`keiro-dsl scaffold` output (pinned by the scaffold-conformance test). The hand-filled
`test/conformance{,-v2}/HospitalCapacity/Reservation/Holes.hs` show how the transducer body
and upcaster are written against the generated signatures — the canonical "what a filled hole
looks like" examples.
