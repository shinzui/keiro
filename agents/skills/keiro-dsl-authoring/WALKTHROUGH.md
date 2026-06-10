# Worked walkthrough: the Reservation aggregate

This closes the full loop on a real captured fixture, end to end. All paths are repo-relative
to `/Users/shinzui/Keikaku/bokuno/keiro`.

## 1. The spec

`keiro-dsl/test/fixtures/reservation.kdsl` declares one `aggregate Reservation`: three id
types, three enums, a `rule`, four registers, six states (three terminal), two commands, two
events, two transitions (the first with a guard `divertStatus != TotalDivert ||
lifeCriticalOverride` and a register write), a `wire` line, and a `projection` with a
`status-map`.

```bash
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/reservation.kdsl   # round-trips
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation.kdsl   # OK, exit 0
```

## 2. Scaffold

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation.kdsl --out /tmp/gen
find /tmp/gen -name '*.hs' | sort
```

You get four `-- @generated` modules (`Domain`, `Codec`, `EventStream`, `Projection`) + a
`Harness` + a create-if-absent `HospitalCapacity/Reservation/Holes.hs`. The Domain module has
the state vertex enum, the command/event records + sums, the `ReservationRegs` type-list,
`initialReservationRegs`, and the two TH splices — and **no** keiki symbolic operator
(firewall). The guard you must encode is annotated in `Holes.hs`:

```text
-- HOLE guard: divertStatus != TotalDivert || lifeCriticalOverride
```

## 3. Fill the transducer hole

The committed reference fill lives at
`keiro-dsl/test/conformance/HospitalCapacity/Reservation/Holes.hs`. It encodes the guard with
keiki operators against the generated names:

```haskell
B.requireGuard (d.divertStatus ./= lit TotalDivert .|| d.lifeCriticalOverride .== lit True)
B.slot @"reservationState" =: lit ReservationHeld
B.emit wireTransferReservationCreated TransferReservationCreatedTermFields { … }
B.goto ReservationHeld
```

Note: these symbolic operators live **only** here, never in a `-- @generated` module.

## 4. Harness green

The `keiro-dsl-conformance` cabal component compiles the generated modules + this filled
`Holes.hs` against keiki/keiro and runs the generated harness:

```bash
cabal test keiro-dsl-conformance
# PASS  validateTransducer is empty
# PASS  clock-free: spec samples no wall clock
# PASS  golden round-trip: TransferReservationCreated
# PASS  golden round-trip: TransferReservationConfirmed
# PASS  accepts RequestTransferReservation from ReservationUnrequested
```

## 5. The harness pins behaviour (mutation)

`bash keiro-dsl/test/mutation-test.sh` flips the filled guard `./=` to `.==` and shows the
specific `accepts RequestTransferReservation …` assertion turn **red** — proving the harness,
not the scaffold, is what guarantees your fill matches the spec. Restoring returns it to
green.

## 6. Evolution (diff)

`keiro-dsl/test/fixtures/reservation-v2.kdsl` evolves `TransferReservationCreated` to v2 with
`upcast from v1 = HOLE`. `bash keiro-dsl/test/diff-test.sh` shows that adding a field WITHOUT
the version bump is `BREAKING` (exit non-zero), while the v2 + upcaster form is `ADDITIVE`
(exit 0) — the merge gate. The `keiro-dsl-conformance-v2` component proves the v2 codec
(`schemaVersion = 2`, `upcasters = [(1, …)]`) compiles and the filled upcaster migrates a
v1-tagged payload through the chain.

That is the whole loop: write → check → scaffold → fill → harness → diff, with the agent
never touching a generated module and never being told the answer — only the generated
signatures and the corpus examples.
