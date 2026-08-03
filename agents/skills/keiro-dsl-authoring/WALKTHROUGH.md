# Worked walkthrough: the stable Reservation aggregate

This closes the full loop on a real Language-4 fixture, end to end. All paths are repo-relative
to `/Users/shinzui/Keikaku/bokuno/keiro`.

## 1. Start from the stable source

`keiro-dsl/test/fixtures/reservation.keiro` starts with `language keiro-dsl 4` and declares one
`aggregate Reservation`: three ID types, three enums, a rule, three registers, six states (three
terminal), two commands, two events, two transitions, a wire policy, and a projection.

```bash
cabal run -v0 keiro-dsl -- parse keiro-dsl/test/fixtures/reservation.keiro
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/reservation.keiro
cabal run -v0 keiro-dsl -- inspect keiro-dsl/test/fixtures/reservation.keiro --format=json
```

`parse` retains the declaration. `inspect` reports `languageVersion: 4` and
`languageSupport: stable`. Versions 1 through 3 remain accepted as `compatibility-only`; neither
inspection nor parse/pretty silently upgrades them.

## 2. Scaffold the checked service

```bash
out_dir="$(mktemp -d)"
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation.keiro --out "$out_dir"
find "$out_dir" -name '*.hs' | sort
```

The stable plan contains context nominal modules, replay audit, aggregate domain, codec,
transducer, behavior contract, event stream, projection, and harness modules. Generated files
carry a `language keiro-dsl 4` banner. The create-if-absent `Holes.hs` keeps the projection apply
function and the one transition output declared as `implementation hole`; `BehaviorHoles.hs`
keeps consumer-owned behavior witnesses. Re-scaffolding overwrites generated files but not these
hand-owned modules.

The lifecycle vertex is not mirrored in a register: `goto ReservationHeld` owns the state change.
The generated transducer lowers the source guard and emit directly, while the filled output hole
constructs `TransferReservationConfirmedTermFields` against its generated signature.

## 3. Observe Language-4 ID admission

The three source declarations generate distinct `TransferReservationId`, `HospitalId`, and
`CommandId` types. Their public constructors validate current TypeID-v7 text:

```haskell
transferReservationIdValue :: TransferReservationId
transferReservationIdValue =
  either (error . show) id
    (parseTransferReservationId "rsv_01h455vb4pex5vsknk084sn02q")
```

The generated harness uses the same `parse…Id` constructors for every command, event, and initial
register sample. Wrong prefixes, malformed text, non-canonical spellings, and non-v7 UUIDs cannot
enter through these current constructors or JSON decoders. The internal
`unsafe…FromLegacyText` functions exist only for historical event replay; authoring code must not
import `Generated.…Nominals.Internal`.

## 4. Compile and run the harness

The checked-in reference component compiles the generated tree with the hand-owned fills and runs
the generated assertions:

```bash
cabal test keiro-dsl-conformance --test-show-details=direct
```

It proves replay validation is empty, both events round-trip through the persisted codec, a valid
current-ID command reaches `ReservationHeld`, and forward execution agrees with replay for the
final vertex and all three domain registers. Its driver also pins canonical event JSON bytes and
unknown-event rejection.

If replay validation is red, use `TAXONOMY.md` to start from the named vertex and repair the source
or corresponding hand-owned implementation. Do not edit a generated module or bypass the gate
with `mkEventStreamUnchecked`.

## 5. Prove the harness catches behavior drift

```bash
bash keiro-dsl/test/mutation-test.sh
```

The script temporarily flips the stable generated guard from inequality to equality, confirms the
named acceptance assertion turns red, and restores the file. This demonstrates that the harness,
not successful scaffolding by itself, pins the checked behavior.

## 6. Gate event evolution

`keiro-dsl/test/fixtures/reservation-v2.keiro` uses event `v2` and `upcast from v1 = HOLE` clauses;
those numbers are event schema versions, not source-language versions. The fixture itself remains
a Language-4 source.

```bash
bash keiro-dsl/test/diff-test.sh
```

Adding a field without the event-version bump is `BREAKING`; the contiguous event-v2/upcaster form
is `ADDITIVE`. The `keiro-dsl-conformance-v2` component compiles that codec and proves a v1-tagged
payload traverses the upcast chain.

That is the stable loop: write Language 4 → check → scaffold → fill explicit holes → run the
harness → diff. The `.keiro` source owns deterministic behavior and current admission; hand-owned
modules own only the boundaries that the notation marks as holes.
