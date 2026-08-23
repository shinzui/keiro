# Migrating to the keiro-dsl 0.15 record API

The next PVP-breaking `keiro-dsl` release removes package-authored product
selector functions and replaces owner-prefixed record labels with concise semantic
labels. It does not change `.keiro` syntax, parsed meaning, JSON or wire keys,
diagnostics, fingerprints, or runtime behavior.

The exhaustive current-to-target map is the checked
[`record-field-migration-0.15.md`](../../keiro-dsl/record-field-migration-0.15.md)
inventory. Use that table when a compiler error names an old selector; it is the
authority for all 1,412 fields, including unchanged concise labels.


## Update reads

Enable the same record model in a consuming component:

```cabal
default-extensions:
  DuplicateRecordFields
  NoFieldSelectors
  OverloadedRecordDot
```

Replace selector application with record dot:

```haskell
-- Before
renderFailure failure = failureMessage failure

-- After
renderFailure failure = failure.message
```

Replace selector composition with an explicit typed lambda or ordinary function:

```haskell
-- Before
map behaviorRecordKey rows

-- After
map (\row -> row.key) rows
```

Constructor-directed construction and matching remain supported:

```haskell
summarize :: BehaviorRecordRow -> Text
summarize BehaviorRecordRow {aggregate, command} = aggregate <> ":" <> command
```

Do not recover by enabling `FieldSelectors` or by defining broad aliases for removed
product selectors. `OverloadedRecordUpdate` is not part of the package contract;
reconstruct through a constructor or a small typed helper when an update becomes
ambiguous.


## Preserved newtype accessors

These intentional unwrappers remain ordinary functions with their existing
signatures:

- `unBehaviorKey`
- `unJsonPointer`
- `unHaskellTypeOccurrence`
- `unOutputObligationKey`
- `unLoc`
- `unRuntimePackageName`
- `unQualifiedValueName`
- `unCanonicalTypeId`
- `unBindingVersion`
- `unCodecIdentity`
- `unCodecVersion`
- `unMappedKey`

Other single-field newtypes whose inventory row says record dot, pattern, or
construction do not acquire a compatibility accessor.


## Verify the migration

Compile downstream code against the new package without a command-line
`FieldSelectors` escape hatch. Pay particular attention to higher-order selector
uses, direct imports of old field names, and exhaustive constructor code. Then run
the application's existing JSON, golden, diff/replay, and conformance checks; their
external results should not change.

Projects that only invoke the `keiro-dsl` executable do not need this package API
migration. Projects that compile scaffolded Haskell must also follow
[`adopting-keiro-dsl-idiomatic-v2.md`](adopting-keiro-dsl-idiomatic-v2.md).


## Policy

[ADR 0038](../adr/0038-keiro-dsl-records-use-concise-labels-without-product-selectors.md)
records the package convention. It follows
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns` while keeping Keiki-facing
imports free of generic-lens's orphan label instance.
