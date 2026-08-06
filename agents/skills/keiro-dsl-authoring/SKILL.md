---
name: keiro-dsl-authoring
description: >
  Author a keiro service as a typed `.keiro` specification and drive the keiro-dsl toolchain
  end to end: write the spec, `check` it, `scaffold` the deterministic layer plus explicit
  typed holes, fill those holes against the GENERATED signatures, run
  the harness, and `diff` the spec to gate unsafe evolution. TRIGGER when: building or changing
  a keiro service (aggregate/snapshot, process manager + timer, router, Kafka
  inbox/outbox/contract, pgmq workqueue/dispatch, read model, durable workflow/operation) and
  you want the spec to be the source of truth.
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

1. **Declare the stable language contract.** Every new complete source starts with
   `language keiro-dsl 4`, before `context`. Language 4 is the sole stable authoring version;
   versions 1 through 3 and unversioned sources remain accepted compatibility contracts and are
   never silently upgraded. Released syntax and runtime behavior are owned by explicit immutable
   profiles, not numeric version ordering. A new feature belongs to one grammar concern and must
   be deliberately listed in every profile that accepts it, with predecessor rejection coverage.
2. **Never edit a `-- @generated` line.** Those modules are overwritten on every `scaffold`.
   Language 4 generates every transition whose guards, writes, emits, and target are completely
   expressed in the source. Fill only create-if-absent modules and signatures for explicitly
   hand-owned behavior such as `implementation hole`, projection SQL, bindings, and upcasters.
3. **The firewall invariant.** A generated aggregate `Transducer.hs` is the one intentional
   generated boundary allowed to contain keiki symbolic operators (`./=`, `.==`, `.||`, `lit`,
   `B.slot`, `B.requireGuard`); it authoritatively lowers Language-4 expressions. Other generated
   modules remain firewall-clean. If an operator appears elsewhere, fix the scaffolder or the
   source—never patch the generated output.
4. **Time is injected, never sampled.** A deadline/sleep is computed from a timestamp carried
   in the input (e.g. `observedAt`), never from a wall-clock read. The validator enforces
   this; don't try to work around it.
5. **The dangerous decisions are explicit on purpose.** Inbox `duplicate => ackOk` (a replay
   is success), `previouslyFailed => deadLetter` (not retry), pgmq `storeFailure => retry`
   (transient) vs `decodeFailure => deadLetter` (poison), timer `on-reject => Fired` (a
   rejected replay is benign success). The checker forces you to state each one; state them
   correctly, not the safe-looking-but-wrong way. Dispatch `on-duplicate AckOk` is sound
   because the runtime confirms the attempted event id against the **target** stream with
   `confirmBenignDuplicate :: StreamName -> EventId -> CommandError -> Eff es Bool` before
   acknowledging it. If you handle duplicates by hand, call that function, fold `True` into
   the duplicate result, and surface `False` as the original failure; never treat a bare
   `DuplicateEvent` as success because event-id uniqueness is global.
6. **The harness — not the scaffold — pins behaviour.** Two agents can fill the holes
   differently but correctly and both pass; one wrong guard/mapping/disposition fails a
   specific named harness test. Run it. The harness also proves **replay-safety**: the
   generated `EventStream` module now emits two bindings — a raw `xEventStreamDef ::
   XEventStreamDef` and a validated `xEventStream :: XEventStream` (a `ValidatedEventStream`,
   which the command runners now require) produced by wrapping the def in
   `mkEventStreamOrThrow`. That wrapper throws at startup unless the transducer is
   replay-safe, and the generated harness's `validateTransducer defaultValidationOptions … ==
   []` assertion is exactly what guarantees it won't. Both bindings live in the `-- @generated`
   module — you never write them; a green harness is what lets them stay green. If it is red,
   use `TAXONOMY.md` to interpret every warning family and fix the source or its explicit
   hand-owned transition.

## What to read next

- `NOTATION.md` — the complete typed-spec notation for every node type (aggregate/snapshot,
  process + timer, router, contract/intake/emit/publisher, workqueue/dispatch, readmodel,
  workflow/operation, evolution).
- `LOOP.md` — the write → check → scaffold → fill → harness → diff loop as numbered steps.
- `WALKTHROUGH.md` — a worked end-to-end example on the Reservation aggregate.
- `TAXONOMY.md` — the replay-safety warning playbook and the `CommandAmbiguous` disposition
  rules.
- `docs/corpus/keiro-dsl-corpus.md` (repo root) — the captured conformance corpus: real
  `.keiro` specs paired with the hand-filled reference modules they map to. Consult these as
  worked examples of how a spec lowers to filled holes.

## The CLI

Run from the repo root (`/Users/shinzui/Keikaku/bokuno/keiro`):

```bash
cabal run keiro-dsl -- parse   <file.keiro>            # parse + pretty-print (proves it's a real spec)
cabal run keiro-dsl -- check   <file.keiro> [--emit]   # validate; --emit pretty-prints the spec on success
cabal run keiro-dsl -- inspect <file.keiro> --format=json # report declared/effective language provenance
cabal run keiro-dsl -- scaffold <file.keiro> --out DIR # validate, then emit @generated + create-if-absent holes
                            [--module-root Acme] [--collocate] [--force-generated-overwrite]
cabal run keiro-dsl -- diff --since <git-ref> <file.keiro>  # classify ADDITIVE/WARNING/BREAKING; BREAKING gates a merge
cabal run keiro-dsl -- check <service.keiro-workspace>       # compose and validate every member as one service
cabal run keiro-dsl -- scaffold <service.keiro-workspace> --out DIR
cabal run keiro-dsl -- diff --since <git-ref> <service.keiro-workspace>
cabal run keiro-dsl -- new <kind>                      # print a minimal valid skeleton (kinds below)
```

`new <kind>` prints a minimal, guaranteed-valid `.keiro` skeleton to stdout for
any of: `aggregate`, `process`, `router`, `contract`, `intake`, `emit`, `publisher`,
`workqueue`, `dispatch`, `workflow`, `operation`. Pipe it straight into a file
to start, e.g. `cabal run -v0 keiro-dsl -- new aggregate > service.keiro`.
`readmodel` is a full top-level notation node but has no standalone starter; `new workqueue`
includes the coupled readmodel nodes its dispatch example requires.

There is a `keiro-dsl/bin/keiro-dsl` wrapper so you can drop the verbose
`cabal run -v0 keiro-dsl --` prefix: put `keiro-dsl/bin` on your `PATH` and run
e.g. `keiro-dsl check service.keiro --emit`. `scaffold` validates first (it will
not emit modules for an invalid spec), then checks path collisions, faithful lowering,
the firewall, and existing Generated-file banners before any write. A refusal exits 1 and
writes nothing. `--force-generated-overwrite` bypasses only the missing-banner protection;
use it only when overwriting an adopted file is intentional. A successful run prints every
module disposition and the generated Cabal-fragment path and writes a per-context scaffold
ledger (`keiro-dsl-ledger.context.<context>.txt`). If a
later run no longer produces recorded paths, its exit-0 `stale:` report never deletes them:
delete `generated` entries only after review, and treat `hole` entries as hand-owned code.

A workspace manifest lists complete same-context member specs with `spec <relative.keiro>`
lines. Each newly authored member declares `language keiro-dsl 4`; inspection reports every
member in canonical path order. Shared declarations have exactly one owning member: duplicates are refused even
when their text is identical, so resolve a conflict by moving the declaration to one owner,
never by copying it. Workspace scaffold history uses
`keiro-dsl-ledger.workspace.<service>.txt`; a first run over legacy same-context
output adopts only ledger- or banner-attributable files and deletes nothing. An output tree
holding pre-0.11 sidecar names refuses with `sidecar migration required` and lists every
rename; rerun with `--apply-name-migrations` to apply them losslessly.
