---
type: Bug Report
title: Read-model harness imports an inconsistent name for a keyword segment
description: Keiro DSL accepts a read-model name ending in the snake-case segment type, but its generated definition and harness import disagree on capitalization and fail compilation.
generated:
  by: process:codex
  at: "2026-09-28T21:17:58Z"
bugId: BUG-8
status: reported
severity: degraded
origin: mori://tan/notification-render-service
affects: mori://shinzui/keiro
affectedVersion: "0.18.0.0"
environment: Released keiro-dsl and keiro 0.18.0.0; GHC 9.12.4 on aarch64 Darwin; accepted Language-4 reproduction and Language-6 consumer workspace.
observed: The generated ReadModel exports validateCustomtypeReadModel, but ReadModelHarness imports validateCustomTypeReadModel. GHC rejects the import with GHC-61689. validate_recipient_type has the same mismatch.
expected: An accepted read-model declaration should generate one consistent Haskell identifier across definitions and imports, as promised by the completed IR-16 naming policy.
reproduction:
  - Use the released keiro-dsl 0.18.0.0 executable and a consuming Cabal environment with keiro 0.18.0.0 and the generated fragment dependencies installed.
  - Save the complete keyword.keiro specification below and run `keiro-dsl check keyword.keiro`; it succeeds.
  - Run `keiro-dsl scaffold keyword.keiro --out output`; it succeeds without changing any generated file by hand.
  - Compile the generated ReadModelHarness using the command below with the generated fragment's language extensions; observe GHC-61689 for validateCustomTypeReadModel.
  - Replace both validate_custom_type occurrences with validate_customtype, scaffold into a fresh directory, and compile its corresponding harness; that control succeeds.
workaround: Rename the internal DSL IDs to validate_customtype and validate_recipienttype and regenerate, retaining readable application aliases where needed. Renaming a DSL ID can change derived registry identity and module paths, so deployed consumers must review those changes.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-28T21:17:58Z"
    document_timestamp: "2026-09-28T21:17:58Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: gpt-6-sol
    effort: high
    context: Reproduced with the released 0.18.0.0 CLI, compiled the untouched generated harness using GHC 9.12.4, traced both naming paths in release source, checked the renamed control, and loaded the pinned bug-report profile using OKF CLI. This is the reporter's evidence check, not independent owner confirmation.
---

# Read-model harness imports an inconsistent name for a keyword segment

The notification-render-service Catalog workspace first exposed this while
implementing ExecPlan 5 under MasterPlan 1. It declares eight independent query
models, including `validate_custom_type` and `validate_recipient_type`. Scaffolding
succeeds, but their generated harness modules stop the consumer build. This
report records the defect; it does not include a generator patch.

## Minimal reproduction

The following complete compatibility-language spec isolates the same naming
helper without requiring the consumer's mapped types or projection catalog.
Language 4 is still accepted by release 0.18.0.0. The original consumer uses
Language 6 and reaches the same mismatch.

Save this as `keyword.keiro`:

```keiro
language keiro-dsl 4
context naming-repro

readmodel validate_custom_type {
  table = "subscriptions"
  schema = "billing"
  columns {
    subscription_id text required
    status text required
  }
  version = 1
  shape = "fnv1a:f54d9bb2f40a6738"
  consistency = Eventual
  feed = inline
}

aggregate Subscription
  regs
  states Active

  command Activate { subscriptionId }
  event Activated = fields(Activate)

  Active -- Activate --> emit Activated ; goto Active

  projection validate_custom_type key=subscriptionId
    status-map { Activated=>active }
```

Run the released CLI:

```sh
keiro-dsl check keyword.keiro
keiro-dsl scaffold keyword.keiro --out output
```

Both commands exit zero. `check` reports the accepted compatibility contract
and `OK`. In a Cabal environment with the generated fragment dependencies
installed, compile just the read-model harness:

```sh
cabal exec -- ghc -fno-code \
  -XGHC2024 -XDuplicateRecordFields -XNoFieldSelectors \
  -XOverloadedRecordDot -XOverloadedStrings -ioutput \
  output/Generated/NamingRepro/ValidateCustomType/ReadModelHarness.hs
```

This compiles the table, create-once query hole, and read-model definition before
failing in the harness. No hole implementation or database is needed to expose
the import error. The extensions are exactly those listed in the generated
Cabal fragment. The Language-4 deprecation warnings are unrelated.

Observed GHC 9.12.4 diagnostic:

```text
ReadModelHarness.hs:4:60: error: [GHC-61689]
    Module ‘Generated.NamingRepro.ValidateCustomType.ReadModel’ does not export ‘validateCustomTypeReadModel’.
    Suggested fix: Perhaps use ‘validateCustomtypeReadModel’
```

The generated definition and export use:

```haskell
validateCustomtypeReadModel
```

The generated harness imports and references:

```haskell
validateCustomTypeReadModel
```

Replacing both spec occurrences with `validate_customtype`, scaffolding into a
fresh directory, and compiling
`Generated/NamingRepro/ValidateCustomtype/ReadModelHarness.hs` succeeds with the
same extensions and dependencies. The corresponding `validate_recipient_type`
and `validate_recipienttype` scaffolds reproduce the second mismatch and its
consistent renamed output.

## Source explanation

The release is pinned by tag `keiro-0.18.0.0` at commit
`7f0c39a1babafbe194385769f0779bed4cdc34cf`.

- [Scaffold.readModelStem](https://github.com/shinzui/keiro/blob/keiro-0.18.0.0/keiro-dsl/src/Keiro/DSL/Scaffold.hs#L5555)
  splits the logical name on underscores, applies `pascal` to each segment,
  concatenates the segments, then applies `lowerFirst`.
- [Scaffold.generatedCase](https://github.com/shinzui/keiro/blob/keiro-0.18.0.0/keiro-dsl/src/Keiro/DSL/Scaffold.hs#L10464)
  calls the shared derivation but returns the original text on `Left`.
- [HaskellName.deriveHaskellName](https://github.com/shinzui/keiro/blob/keiro-0.18.0.0/keiro-dsl/src/Keiro/DSL/HaskellName.hs#L166)
  validates both upper- and lower-camel occurrences. A standalone `type` segment
  fails the lower-occurrence reserved-keyword check, so `pascal "type"` falls
  back to lowercase `type`. The resulting stem is `validateCustomtype`.
- [Harness.renderReadModelHarness](https://github.com/shinzui/keiro/blob/keiro-0.18.0.0/keiro-dsl/src/Keiro/DSL/Harness.hs#L320)
  applies `pascal` to the complete logical name before `lowerFirst`.
  `validate_custom_type` derives valid compound occurrences, producing
  `validateCustomType`.

The definition renderer and harness therefore derive different occurrences
from one accepted declaration. The keyword check itself is reasonable for a
complete lower-case Haskell identifier; applying it independently to a segment
inside a compound name, and silently falling back in only one path, explains
this failure.

## Existing contract and scope

Completed [IR-16](../improvement-requests/guarantee-idiomatic-haskell-names-for-generated-declarations.md)
requires a shared naming policy across generated declarations and imports,
including reserved-word coverage. This is wrong behavior in an existing
capability and belongs in the bug-report profile.

A fix should derive the complete logical name once and reuse the same checked
occurrence in every emitted definition, import, facade, and collision inventory.
Regression coverage should compile an accepted read-model spec with a keyword
segment, exercise both reported IDs, and retain rejection of a genuinely
reserved complete occurrence. Other declaration kinds and keyword segments may
share similar per-segment helpers, but their behavior has not been established
by this report. No last-working release is asserted.

Status remains `reported`: the consumer reproduced the defect and traced its
cause, while the owning repository has not independently confirmed or fixed it.
