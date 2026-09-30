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

1. **Author Language 6, and only Language 6.** Every source this skill writes begins with
   `language keiro-dsl 6`. Language 6 extends Language 5 with process reactions, delegated
   inboxes, `ordering fifo-heads`, nominal structural leaves, `Map[DeclaredId]` keys, declared
   contract IDs, bare structural values, `Day`, `Set Text`, `mapped refined` base16 values, and
   `domain=typeid-v5-or-v7` ID admission. `new <kind>` still prints a `language keiro-dsl 5`
   starter: change that first line to `6` before editing. When you touch an existing Language 5
   source, move it to 6 the same way; a preamble-only change `diff`s as `ADDITIVE` and
   replay-neutral. Languages 1 through 4 and unversioned sources are deprecated and scheduled for
   removal: never author them, and migrate one you encounter rather than extending it. Never
   allocate language 7 on your own; syntax and runtime behavior are owned by explicit profiles.
2. **Never edit a `-- @generated` line.** Those modules are overwritten on every `scaffold`.
   The scaffolder generates every transition whose guards, writes, emits, and target are
   completely expressed in the source. Fill only create-if-absent modules and signatures for explicitly
   hand-owned behavior such as `implementation hole`, projection SQL, bindings, and upcasters.
3. **The firewall invariant.** A generated aggregate `Transducer.hs` is the one intentional
   generated boundary allowed to contain keiki symbolic operators (`./=`, `.==`, `.||`, `lit`,
   `B.slot`, `B.requireGuard`); it authoritatively lowers the source's checked expressions. Other generated
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
6. **Projection delivery and query freshness have one owner each.** Put
   `delivery = inline | subscription` on the catalog `projection-owner` and
   `freshness = immediate | wait-for-head ...` on the `readmodel`. Never write `feed`,
   `subscription`, `consistency`, or `scope` on a read model; they are not part of the language;
   the checked target-owner relation derives any durable cursor. Use `immediate` when no
   wait is required, including an explicit tolerance for async lag. A head wait requires
   a compatible subscription source; caller-specific read-your-write uses the runtime
   position override rather than static DSL.
7. **The harness — not the scaffold — pins behaviour.** Two agents can fill the holes
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
- `WALKTHROUGH.md` — a worked end-to-end example on the Language 6 `checked-mapping-replay`
  workspace.
- `TAXONOMY.md` — the replay-safety warning playbook and the `CommandAmbiguous` disposition
  rules.
- `docs/corpus/keiro-dsl-corpus.md` (repo root) — the captured conformance corpus: real
  `.keiro` specs paired with the hand-filled reference modules they map to. Consult these as
  worked examples of how a spec lowers to filled holes; some corpus sources predate Language 6,
  so copy their structure, not their preamble.
- `docs/user/keiro-dsl-reference.md` (repo root) — the user-facing language reference and its
  topic pages, for the full rules behind every construct.

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
`workqueue`, `dispatch`, `workflow`, `operation`. The starters declare stable Language 5;
switch them to Language 6 as you write the file, e.g.
`cabal run -v0 keiro-dsl -- new aggregate | sed '1s/^language keiro-dsl 5$/language keiro-dsl 6/' > service.keiro`.
Every starter checks under Language 6.
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
lines. Every member declares `language keiro-dsl 6`; members with different effective versions
are refused before the graph merges. Inspection
reports every member in canonical path order. Shared declarations have exactly one owning member: duplicates are refused even
when their text is identical, so resolve a conflict by moving the declaration to one owner,
never by copying it. Workspace scaffold history uses
`keiro-dsl-ledger.workspace.<service>.txt`; a first run over legacy same-context
output adopts only ledger- or banner-attributable files and deletes nothing. An output tree
holding pre-0.11 sidecar names refuses with `sidecar migration required` and lists every
rename; rerun with `--apply-name-migrations` to apply them losslessly.
