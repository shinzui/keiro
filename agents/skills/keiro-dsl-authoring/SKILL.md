---
name: keiro-dsl-authoring
description: >
  Author a keiro service as a typed `.keiro` specification and drive the keiro-dsl toolchain
  end to end: write the spec, `check` it, `scaffold` the symbol-free deterministic layer plus
  typed holes, fill the holes and the transducer body against the GENERATED signatures, run
  the harness, and `diff` the spec to gate unsafe evolution. TRIGGER when: building or changing
  a keiro service (aggregate, process manager + timer, Kafka inbox/outbox/contract, pgmq
  workqueue/dispatch, durable workflow/operation) and you want the spec to be the source of truth.
argument-hint: <feature description, or a path to an existing .keiro>
---

# keiro-dsl authoring skill

A `.keiro` file is the permanent, machine-checkable source of truth for a keiro service. The
`keiro-dsl` CLI turns it into compiling Haskell: a `-- @generated` deterministic layer
(domain ADTs, codecs, stream/projection wiring, the TH splice, process/timer/contract
wiring) plus precisely-typed **holes** in hand-owned modules for the behaviour-bearing
pieces. Your job as the agent is to **author the spec** and **fill the holes** — never to
edit a `-- @generated` module.

## The load-bearing rules (read these first)

1. **Never edit a `-- @generated` line.** Those modules are overwritten on every `scaffold`.
   Fill only the create-if-absent `Holes.hs` / `ProcessHoles.hs` modules, against the
   signatures the generated layer exports.
2. **The firewall invariant.** No `-- @generated` module ever contains a keiki symbolic
   operator (`./=`, `.==`, `.||`, `lit`, `B.slot`, `B.requireGuard`). Those appear only in
   the hand-owned hole modules you write. If you find one in a generated module, that's a
   bug in the scaffolder, not something to "fix" in place.
3. **Time is injected, never sampled.** A deadline/sleep is computed from a timestamp carried
   in the input (e.g. `observedAt`), never from a wall-clock read. The validator enforces
   this; don't try to work around it.
4. **The dangerous decisions are explicit on purpose.** Inbox `duplicate => ackOk` (a replay
   is success), `previouslyFailed => deadLetter` (not retry), pgmq `storeFailure => retry`
   (transient) vs `decodeFailure => deadLetter` (poison), timer `on-reject => Fired` (a
   rejected replay is benign success). The checker forces you to state each one; state them
   correctly, not the safe-looking-but-wrong way.
5. **The harness — not the scaffold — pins behaviour.** Two agents can fill the holes
   differently but correctly and both pass; one wrong guard/mapping/disposition fails a
   specific named harness test. Run it. The harness also proves **replay-safety**: the
   generated `EventStream` module now emits two bindings — a raw `xEventStreamDef ::
   XEventStreamDef` and a validated `xEventStream :: XEventStream` (a `ValidatedEventStream`,
   which the command runners now require) produced by wrapping the def in
   `mkEventStreamOrThrow`. That wrapper throws at startup unless the transducer is
   replay-safe, and the generated harness's `validateTransducer defaultValidationOptions … ==
   []` assertion is exactly what guarantees it won't. Both bindings live in the `-- @generated`
   module — you never write them; a green harness is what lets them stay green.

## What to read next

- `NOTATION.md` — the complete typed-spec notation for every node type (aggregate, process +
  timer, contract/intake/emit/publisher, workqueue/dispatch, workflow/operation, evolution).
- `LOOP.md` — the write → check → scaffold → fill → harness → diff loop as numbered steps.
- `WALKTHROUGH.md` — a worked end-to-end example on the Reservation aggregate.
- `docs/corpus/keiro-dsl-corpus.md` (repo root) — the captured conformance corpus: real
  `.keiro` specs paired with the hand-filled reference modules they map to. Consult these as
  worked examples of how a spec lowers to filled holes.

## The CLI

Run from the repo root (`/Users/shinzui/Keikaku/bokuno/keiro`):

```bash
cabal run keiro-dsl -- parse   <file.keiro>            # parse + pretty-print (proves it's a real spec)
cabal run keiro-dsl -- check   <file.keiro> [--emit]   # validate; --emit pretty-prints the spec on success
cabal run keiro-dsl -- scaffold <file.keiro> --out DIR # validate, then emit @generated + create-if-absent holes
                            [--module-root Acme] [--collocate]  # place modules under Acme.<Ctx>.<Node>(.Generated)
cabal run keiro-dsl -- diff --since <git-ref> <file.keiro>  # classify changes ADDITIVE/BREAKING; gate a merge
cabal run keiro-dsl -- new <kind>                      # print a minimal valid skeleton (kinds below)
```

`new <kind>` prints a minimal, guaranteed-valid `.keiro` skeleton to stdout for
any of: `aggregate`, `process`, `contract`, `intake`, `emit`, `publisher`,
`workqueue`, `dispatch`, `workflow`, `operation`. Pipe it straight into a file
to start, e.g. `cabal run -v0 keiro-dsl -- new aggregate > service.keiro`.

There is a `keiro-dsl/bin/keiro-dsl` wrapper so you can drop the verbose
`cabal run -v0 keiro-dsl --` prefix: put `keiro-dsl/bin` on your `PATH` and run
e.g. `keiro-dsl check service.keiro --emit`. `scaffold` validates first (it will
not emit modules for an invalid spec), self-checks the firewall, and prints a
report naming every module written and the manifest path.
