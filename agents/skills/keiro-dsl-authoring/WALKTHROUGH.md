# Worked walkthrough: the Language 6 checked-mapping-replay workspace

This closes the full loop on a real Language 6 service, end to end. All paths are repo-relative
to `/Users/shinzui/Keikaku/bokuno/keiro`.

## 1. Start from the Language 6 source

`keiro-dsl/test/fixtures/checked-mapping-replay-workspace/service.keiro-workspace` composes two
members, both beginning `language keiro-dsl 6` and declaring `context checked-mapping-replay`:

- `domain/values.keiro` owns the shared declarations: `RetainedId` with
  `domain=typeid-v5-or-v7`, the bare values `MaybeLabel` (`wire Optional Text`), `ImportantDays`
  (`wire List Day`), `TextLabels` (`wire Set Text`), and `MaybeContentHash`, the refined
  `ContentHash` (`wire base16-bytes`), and the `ReplayEnvelope` record that combines them with a
  `Map[RetainedId] Text` field.
- `domain/service.keiro` uses them: the `ReplayLedger` aggregate with a snapshot and a
  `replay-only` transition, the `ReplayTarget` aggregate, a `ReplayReaction` reaction process, the
  `replay_jobs` queue with colon-form mapped payload fields, a projection catalog with the
  `replay_lookup` read model and its mapped query pair, and a public contract whose field names
  the declared `RetainedId`.

```bash
workspace=keiro-dsl/test/fixtures/checked-mapping-replay-workspace/service.keiro-workspace
cabal run -v0 keiro-dsl -- check "$workspace" --min-language 6
cabal run -v0 keiro-dsl -- check "$workspace" --explain-bindings
cabal run -v0 keiro-dsl -- inspect "$workspace" --format=json
```

`check` prints one expected `ReplayOnlyCommandStillLive` warning for the retired
`ImportLegacy` command and exits 0. `--explain-bindings` lists every binding, fixture, and
initial symbol the application owns. `inspect` reports both members as
`"declaredLanguageVersion": 6` with `"languageSupport": "candidate"` until Language 6 is
published.

## 2. Scaffold the checked service

```bash
out_dir="$(mktemp -d)"
cabal run -v0 keiro-dsl -- scaffold "$workspace" --out "$out_dir"
find "$out_dir" -name '*.hs' | sort
```

The plan contains the context nominal and `Structural.NominalLeaves` modules, the structural
shapes and `StructuralConformance`, each aggregate's domain, codec, transducer, event stream, and
harness, the reaction's input, decision, worker, and process harness, the queue codec, the
read-model query contract, the projection catalog facade, and the contract codec. Create-once
modules hold only the hand-owned boundaries:

| Module | You fill |
| --- | --- |
| `Conformance/CheckedMappingReplay/Bindings.hs` | total bindings, fixtures, and initials for every mapped declaration |
| `CheckedMappingReplay/ReplayReaction/ProcessHoles.hs` | the `RecordedEvent -> Maybe ReplayReactionInput` source decoder |
| `CheckedMappingReplay/ReplayLookup/ReadModelHoles.hs` | the query body against the generated query types |
| `CheckedMappingReplay/ProjectionCatalog/ProjectionCatalogHoles.hs` | live and replay apply, verification |
| `CheckedMappingReplay/*/BehaviorHoles.hs` | consumer-owned behavior witnesses |

The fresh `Bindings.hs` contains `HOLE` markers. The committed, filled versions live under
`keiro-dsl/test/conformance-checked-mapping-replay/`; compare yours against them. Re-scaffolding
overwrites generated files but never these hand-owned modules.

## 3. Fill the bindings against the generated shapes

Every binding is a total isomorphism between the consumer type and its generated shape:

```haskell
maybeLabelBinding :: StructuralBinding MaybeLabel MaybeLabelShape
maybeLabelBinding =
  StructuralBinding
    { bindingToShape = \(MaybeLabel value) -> value
    , bindingFromShape = MaybeLabel
    }
```

The refined `ContentHash` binding maps to a `ByteString` shape, `Day` fields arrive as
`Data.Time.Calendar.Day`, and `Set Text` fields as `Set Text`; the frozen `keiro-core` codecs own
their wire forms, so the binding never parses or validates. Fixtures should cover the edge cases
each policy exists for: an empty and a leading-zero hash, a UUIDv5 and a UUIDv7 `RetainedId`, an
empty and a multi-element set, and an absent and a present optional.

## 4. Run the whole loop and the harness

```bash
just checked-mapping-adoption
cabal test keiro-dsl:test:keiro-dsl-conformance-checked-mapping-replay --test-show-details=direct
```

The recipe runs the public `check`, scaffolds into an empty tree, confirms the binding skeleton
has `HOLE` markers, installs the completed hand-owned files, regenerates, and compares the whole
`Generated/` tree with the committed example; it then repeats that from an existing scaffold and
fails if any hand-owned file changed. The conformance test proves replay validation is empty,
decodes retained non-canonical bytes through the generated event codec, replays a multi-event
transition, crosses the replay-only edge, and checks forward execution against replay.

If replay validation is red, use `TAXONOMY.md` to start from the named vertex and repair the source
or the corresponding hand-owned implementation. Do not edit a generated module or bypass the gate
with `mkEventStreamUnchecked`.

## 5. Gate evolution

Before changing a deployed spec, diff it against the deployed ref:

```bash
cabal run -v0 keiro-dsl -- diff "$workspace" --since <deployed-ref> --explain
```

A new event field without an event-version bump is `BREAKING`; a contiguous `vN` plus
`upcast from v(N-1) = HOLE` is `ADDITIVE`. Changing a checked value policy is never a refactor:
switching `RetainedId` back to `typeid-v7` reports `IdDomainContractChanged`, and changing a
`wire` shape reports a mapped finding at every affected root. Retain the old reader, roll out
readers before writers, and follow the rollout constraints `diff --explain` prints.

That is the loop: write Language 6 → check → scaffold → fill explicit holes → run the harness →
diff. The `.keiro` source owns deterministic behavior, wire shapes, and admission; hand-owned
modules own only the boundaries that the notation marks as holes.
