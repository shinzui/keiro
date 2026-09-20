---
type: Guide
title: Checked Mapping Adoption
description: Adopt candidate checked values through total bindings, generated persistence codecs, replay evidence, and reader-first rollout.
docId: DOC-28
tags: [keiro, dsl, mappings, adoption]
generated:
  by: process:codex-cli
  at: 2026-09-20T20:55:54Z
---

# Checked Mapping Adoption

Checked mappings let an application keep its domain types while the Keiro DSL
owns a declared, inspectable persistence shape. The capabilities in this guide
belong to candidate Language 6. Repository evidence makes them eligible for a
future package and language publication, but this guide does not mean that a
release was published or that any particular consumer's retained history was
approved for adoption.

The compiled example is the
[`checked-mapping-replay` workspace](../../keiro-dsl/test/fixtures/checked-mapping-replay-workspace/service.keiro-workspace).
It combines the five new capabilities in one `ReplayEnvelope`:

| Capability | Example declaration | Frozen policy |
|---|---|---|
| Named bare containers | `MaybeLabel`, `ImportantDays`, and `MaybeContentHash` | The container is part of the structural wire shape; an alias does not add an object wrapper. |
| Calendar days | `List Day` | Lossless proleptic-Gregorian text with an unbounded historical reader. |
| Structural text sets | `Set Text` and `Optional (Set Text)` | Read permutations and duplicates; write unique strings in Unicode code-point order. |
| Refined base16 bytes | `mapped refined ContentHash` | Read valid mixed case; write lowercase without dropping empty values or leading zeroes. |
| Explicit ID admission | `RetainedId ... domain=typeid-v5-or-v7` | Admit canonical UUIDv5 and UUIDv7 TypeIDs while leaving generation policy unchanged. |

The aggregate, target aggregate, queue, query, contract, and process reaction
all compile in
[`keiro-dsl-conformance-checked-mapping-replay`](../../keiro-dsl/test/conformance-checked-mapping-replay/Main.hs).
The same test decodes retained non-canonical bytes through the generated event
codec, replays a multi-event transition, crosses a replay-only edge, and checks
an application-owned workflow result codec.

## Run the supported path

From the repository root, run:

```bash
nix develop -c just checked-mapping-adoption
```

The recipe uses the public commands, not internal generator functions:

```bash
cabal run -v0 keiro-dsl -- check \
  keiro-dsl/test/fixtures/checked-mapping-replay-workspace/service.keiro-workspace

cabal run -v0 keiro-dsl -- scaffold \
  keiro-dsl/test/fixtures/checked-mapping-replay-workspace/service.keiro-workspace \
  --out "$SCRATCH_OUTPUT"

cabal test -v0 \
  keiro-dsl:test:keiro-dsl-conformance-checked-mapping-replay \
  --test-show-details=direct
```

The automated recipe performs two scaffold passes. The first begins with an
empty output directory, confirms that a binding skeleton containing `HOLE` was
created, installs the example's completed consumer files, and regenerates. The
second begins with an existing scaffold. Both passes hash every create-once
file before and after regeneration and compare the complete `Generated/` tree
with the committed compiled example. A mismatch or overwrite fails the recipe.

## Declare the domain and wire shape separately

The consumer owns the Haskell type, such as `MaybeLabel`. The declaration owns
the persistence shape and stable identities:

```text
mapped structural value MaybeLabel {
  haskell package=keiro-dsl module=Conformance.CheckedMappingReplay.Domain type=MaybeLabel
  binding = "Conformance.CheckedMappingReplay.Bindings.maybeLabelBinding"
  binding-version = "1"
  canonical-type = "conformance.checked-mapping-replay.MaybeLabel.v1"
  fixtures = "Conformance.CheckedMappingReplay.Bindings.maybeLabelFixtures"
  wire Optional Text
}
```

Fill the generated create-once binding with both total directions. This is the
minimum binding; validation and JSON admission stay on the generated shape
side:

```haskell
maybeLabelBinding :: StructuralBinding MaybeLabel (Maybe Text)
maybeLabelBinding =
  StructuralBinding
    { bindingToShape = \(MaybeLabel value) -> value
    , bindingFromShape = MaybeLabel
    }
```

Also provide deterministic, labelled fixtures and `CanonicalTypeName`. A
register additionally needs an initial value. The generated harness checks both
binding inverse laws for every fixture. Do not use a partial constructor or
hide validation in `bindingFromShape`; if not every admitted shape has a domain
value, narrow the declared shape or introduce an explicit versioned policy.

A Haskell `type` alias cannot own a canonical identity distinct from its
carrier when the carrier already has a `CanonicalTypeName` instance. Reuse the
carrier identity (for example `Maybe(Text)`) or introduce a `newtype` with its
own instance and a total binding; do not add an overlapping instance merely to
match a declaration label.

For generated private events, a direct mapped field whose checked root resolves
to `Optional` preserves the historical Aeson equivalence between an omitted key
and an explicit JSON null. A direct mapped non-optional field remains required.
This event-envelope compatibility rule does not make required fields inside a
declared structural record optional.

## Know which files you own

`Generated/` modules are overwritten on every scaffold. They own private-event
wire keys, generated codecs, structural shapes, transducers, reaction wiring,
and harness facts. Never hand-edit them.

The application owns its domain module, completed binding module, process input
decoder, workflow result codec, and the `*Holes.hs` behavior modules. Scaffold
creates those files only when absent. Regeneration must preserve them byte for
byte; the adoption recipe enforces this boundary.

Process input decoding remains application-owned because it interprets the
source event contract. The generated reaction input can now reference a mapped
consumer type, while the hand-owned decoder decides how that source event
becomes the typed input. Persisted workflow results are also application-owned:
encode and decode them with an explicit codec, keep the step key stable, and
fail a stored-result decode rather than treating it as a missing step and
running the effect again.

## Treat refactors and semantic changes differently

Haskell module names, selector names, and imports may move while the declared
canonical type, wire keys, binding version, process name/version, workflow step
key, and ID domain remain unchanged. The adoption proof regenerates after such
source-level movement and compares durable observations, not module spelling.

A changed date domain, set equivalence, base16 interpretation, ID admission
domain, binding direction, event shape, process identity, or workflow key is a
semantic change. Version it, retain the old reader or replay-only path, and run
`just replay-compatibility`; do not relabel it as a refactor.

## Roll out readers before writers

First deploy readers that accept all retained bytes and the candidate bytes.
Capture baseline and candidate observations from the same immutable consumer
history, including stream prefixes, process witnesses and target identities,
timers, and workflow journal prefixes. Only then enable new writers. An old
reader/new-writer failure requires producer-last deployment; it is not erased
by successful historical reading.

Before the first new-format write, rollback may disable the writer while
retaining the expanded reader. After an incompatible write, recover forward
with that reader, an upcaster, or retained replay-only behavior. Never rewrite
events, IDs, timers, or workflow results merely to make an older binary start.
For the complete operational rules, see
[Evolution And Replayability](evolution-and-replayability.md) and
[Durable Workflows](durable-workflows.md).

## Current boundaries

Refined base16 values are not supported as map keys, in symbolic operations,
or behind arbitrary validation/length callbacks. Public contracts do not own
refined consumer codecs, and workflow persistence remains application-owned.
Use a declared ID for a keyed map, put the refined value in an ordinary field,
model a bounded byte type as a new explicit policy, and write an application
workflow codec respectively.

`keiro-dsl check` rejects unsupported checked operations at their source
location and names the supported alternative. Do not replace a rejection with
opaque `Json` merely to make the check pass: that changes the claim from checked
wire authority to an explicit unverified boundary.

The committed release manifest reports four results independently. Package and
language publication are eligible on repository evidence. An immutable
baseline/candidate rehearsal also makes adoption for `mori://shinzui/rei`
eligible, and proves retirement of exactly that consumer's obsolete `ActionId`
mapped-opaque declaration in favor of the checked v5-or-v7 nominal path.
Generic mapped-opaque support and every historical reader remain retained. The
manifest performs no release, publication, consumer edit, deployment, or
main-tree deletion.
