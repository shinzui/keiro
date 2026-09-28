---
type: Reference
title: Keiro DSL Reference
description: Introduce the Keiro DSL, its stable Language 5 and candidate Language 6 contracts, and source file structure, and index the topic reference pages.
docId: DOC-23
tags: [keiro, dsl, language-5, language-6, reference]
generated:
  by: human:nadeem
  at: 2026-09-18T04:05:10Z
---

# Keiro DSL Reference

`keiro-dsl` is Keiro's build-time language for describing an event-sourced
service. A checked `.keiro` source can generate Haskell domain types, codecs,
transducers, runtime wiring, conformance harnesses, and create-once modules for
the behavior that remains application-owned. The generated application uses
ordinary Keiro APIs; the DSL is not interpreted in production.

This reference describes **Language 5**, the published stable language and
recommended contract for new released-only specifications, and **Language 6**,
the candidate that extends it. They are the only supported languages; this
reference does not document Languages 1 through 4, which are deprecated and
scheduled for removal. Sources begin with:

```keiro
language keiro-dsl 5
```

**Language 6** is the active candidate. It is registered and fully checked,
scaffolded, and conformance-tested, but it has not crossed the published
compatibility boundary: the candidate may still be corrected in place until it
is published. It extends Language 5 with the following additions:

| Candidate Language 6 addition | Reference |
| --- | --- |
| `idempotence delegated` intake | [Intakes](keiro-dsl-integration.md#intakes) |
| First-class process reactions with multiple typed inputs | [Processes and timers](keiro-dsl-processes-and-routers.md#processes-and-timers) |
| `ordering fifo-heads` work queues | [Work queues](keiro-dsl-queues-and-read-models.md#work-queues) |
| Declared `id`, `enum`, and `mapped nominal` leaves inside structural mappings, typed queue fields, and query types | [Consumer-owned nominal declarations](keiro-dsl-types-and-mappings.md#consumer-owned-nominal-declarations) |
| `Map[DeclaredId] T` identifier-keyed maps | [Mapped type expressions](keiro-dsl-types-and-mappings.md#mapped-type-expressions) |
| Declared ID fields in public contracts | [Integration contracts](keiro-dsl-integration.md#integration-contracts) |
| Named bare container values (`wire Optional Text`, `wire List T`, `wire Map T`) | [Structural bare values](keiro-dsl-types-and-mappings.md#structural-bare-values) |
| `Day` calendar days and `Set Text` text sets | [Checked value wire policies](keiro-dsl-types-and-mappings.md#checked-value-wire-policies) |
| `mapped refined` base16 byte values | [Refined values](keiro-dsl-types-and-mappings.md#refined-values) |
| `domain=typeid-v5-or-v7` ID admission | [IDs](keiro-dsl-types-and-mappings.md#ids) |

Each addition is refused below Language 6 with
`LanguageFeatureRequiresVersion`, and each is inert for a source that does not
use it. Candidate-only examples say so explicitly and begin with
`language keiro-dsl 6`; released-only services should remain on Language 5
until the candidate is published. `keiro-dsl new` selects
`currentStableLanguageVersion`, so starters remain on Language 5 until then.
[Checked Mapping Adoption](../guides/checked-mapping-adoption.md) walks through
the checked value mappings end to end.

This page introduces the language, its versions, and the structure of a source
file. The rest of the reference is split by topic:

| Page | Covers |
| --- | --- |
| [Types and Mappings](keiro-dsl-types-and-mappings.md) | IDs, enums, rules, nominal declarations, direct types, and consumer-owned structural, refined, and opaque mappings |
| [Aggregates](keiro-dsl-aggregates.md) | Expressions, registers, commands, events, transitions, typed outcomes, event evolution, projections, and snapshots |
| [Processes and Routers](keiro-dsl-processes-and-routers.md) | Process managers, reactions, timers, and custom or declarative routers |
| [Integration Contracts](keiro-dsl-integration.md) | Public contracts, Kafka intakes, emits, and outbox publishers |
| [Queues and Read Models](keiro-dsl-queues-and-read-models.md) | Work queues, dispatch, read models, projection catalogs, and external reads |
| [Workflows and Operations](keiro-dsl-workflows-and-operations.md) | Durable workflows and operation entry points |
| [Workspaces and Generated Code](keiro-dsl-workspaces-and-generated-code.md) | Multi-file workspaces, conformance packages, and generated versus hand-owned files |
| [Command Reference](keiro-dsl-cli.md) | `new`, `parse`, `pretty`, `check`, `inspect`, `behavior-obligations`, `scaffold`, and `diff` |
| [Validation and Evolution](keiro-dsl-validation-and-evolution.md) | Validation layers, language gates, the evolution workflow, and the authoring checklist |

The shortest path is [Quick start](#quick-start), followed by the page for the
node family you need. The [command reference](keiro-dsl-cli.md) and
[authoring checklist](keiro-dsl-validation-and-evolution.md#authoring-checklist)
cover the normal development and CI loop.

## What the language describes

A `.keiro` source describes one service context. It can contain shared type
declarations and any combination of these node families:

| Node | Purpose |
| --- | --- |
| `aggregate` | Event-sourced state machine with commands, events, transitions, projections, and snapshots. |
| `process` | Stateful coordination across aggregates, including a durable timer. |
| `router` | Stateless, effectful one-to-many command routing. |
| `contract` | Public integration-event schema and Kafka topics. |
| `intake` | Kafka-to-inbox decoding, deduplication, and disposition policy. |
| `emit` | Private-state-to-contract-event mapping for the outbox. |
| `publisher` | Outbox ordering, retry, and stable identity policy. |
| `workqueue` | PGMQ payload, ordering, provisioning, retry, and DLQ policy. |
| `dispatch` | Read-model-driven fan-out and deduplicated queue enqueueing. |
| `readmodel` | Registered SQL query identity, shape, and query freshness. |
| `workflow` | Durable named steps, waits, sleeps, children, patches, and rotation. |
| `operation` | Named command, query, signal, or workflow-run entry point. |

The language deliberately separates declarative facts from hand-owned behavior.
For example, an aggregate transition can declare a guard and register writes
that Keiro can generate, while a router resolver, read-model SQL body, workflow
body, or explicitly opaque transition stays in a create-once Haskell module.

## Quick start

Generate a valid starter, check it, and scaffold it:

```bash
cabal run -v0 keiro-dsl -- new aggregate > service.keiro
cabal run -v0 keiro-dsl -- check service.keiro
cabal run -v0 keiro-dsl -- scaffold service.keiro --out src
```

The aggregate starter has this shape:

```keiro
language keiro-dsl 5
context my-service

id ThingId prefix=thing

aggregate Thing
  regs
    thingId ThingId = placeholder
  states Pending Done!

  command DoThing { thingId attempt:Int }
  event ThingCompleted { thingId attempt:Int }

  Pending -- DoThing -->
    emit ThingCompleted
    goto Done

  wire kind=ctorName fields=camelCase schemaVersion=1
```

`check` prints `OK` and exits zero only after semantic validation and the pure
scaffold-planning gates succeed under the source-declared context. `scaffold`
re-runs the same ordered gates under its CLI-effective context before writing,
so module-root, placement, or runtime-package overrides receive the same defense
in depth. It emits replaceable files bearing an exact `@generated` banner,
create-once hand-owned modules, a conformance harness, a Cabal fragment, and a
machine-owned scaffold ledger. Copy the fragment's `default-language`,
`default-extensions`, `other-modules`, and `build-depends` blocks into the
consuming Cabal component, fill the create-once modules, and run the generated
harness in CI.

When the service declares mapped types, scaffold also emits one context
`StructuralConformance` module. It owns declaration-wide binding, canonical
identity, fixture-label, branch-coverage, opaque-boundary, and projection-witness
checks. Aggregate harnesses retain only evidence tied to their checked command,
event, and register closure, so an unrelated aggregate does not acquire consumer
imports or generated-byte churn from another aggregate's declaration change.

The current generated Haskell contract is GHC2024 with
`DuplicateRecordFields`, `NoFieldSelectors`, `OverloadedRecordDot`, and
`OverloadedStrings` as its four shared default extensions. Generated modules
declare other specialized extensions locally, and only when their emitted syntax
needs them. Create-once hand-owned modules are outside that cleanup boundary and
retain the pragmas they owned when they were created.

Generated Haskell naming is a separate, versioned presentation contract. Logical
`snake_case` or camel-case declarations pass through one ASCII word segmentation:
module segments, types, and constructors become UpperCamelCase; values and record
selectors become lowerCamelCase.

| Logical name | UpperCamelCase | lowerCamelCase |
| --- | --- | --- |
| `foo_bar` | `FooBar` | `fooBar` |
| `ThingID` | `ThingID` | `thingID` |
| `HTTP_server2` | `HTTPServer2` | `httpServer2` |
| `version2_event` | `Version2Event` | `version2Event` |

Leading, trailing, or repeated underscores are rejected as unsafe. Names such as
`foo_bar` and `fooBar` are rejected when they converge in the same generated
namespace, and normalization to a Haskell keyword is rejected before scaffolding.
This never changes external spellings: wire keys and tags, queue names, SQL names,
registry/subscription identities, and explicit consumer-owned Haskell references
remain exactly declared.

After changing a deployed specification, run a compatibility diff before
scaffolding:

```bash
cabal run -v0 keiro-dsl -- diff service.keiro --since HEAD^ --explain
```

## Source file structure

### Preamble and context

A complete source has this outer form:

```keiro
language keiro-dsl 5
context hospital-capacity
module Acme.Services
layout collocated

# Shared declarations and nodes follow in any order.
```

The language declaration must be the first non-comment content and must appear
immediately before `context`. `module` and `layout`, when present, must follow
`context` and precede all declarations and nodes.

`context` takes a wire word: an ASCII letter or digit followed by ASCII letters,
digits, underscores, or hyphens. It is the service namespace used in generated
module and durable identity derivation.

`module` is an optional Haskell module prefix made from one or more PascalCase
segments. `layout` controls generated-module placement:

| Layout | Generated modules | Hand-owned modules |
| --- | --- | --- |
| `prefixed` (default) | `<Module>.Generated.<Context>.<Node>...` | `<Module>.<Context>.<Node>...` |
| `collocated` | `<Module>.<Context>.<Node>.Generated...` | `<Module>.<Context>.<Node>...` |

`scaffold --module-root PREFIX` overrides `module`, and `--collocate` overrides
the layout for that run. Prefer declaring stable project-wide placement in the
source or workspace manifest rather than relying on repeated CLI flags.

### Lexical rules

- `#` begins a line comment.
- Spaces, blank lines, and indentation are generally insignificant; keywords
  give the document its structure. Indentation is still strongly recommended.
- Identifiers contain ASCII letters, digits, and underscores and cannot contain
  hyphens. Generated Haskell type and constructor names must begin with an
  uppercase ASCII letter; fields and registers must begin with a lowercase
  ASCII letter or underscore. Generated field selectors reject exactly the
  term-level GHC keywords `case`, `class`, `data`, `default`, `deriving`, `do`,
  `else`, `foreign`, `forall`, `if`, `import`, `in`, `infix`, `infixl`,
  `infixr`, `instance`, `let`, `module`, `newtype`, `of`, `then`, `type`, and
  `where`. Contextual words such as `family`, `via`, and `qualified` are valid.
  Use a field's `haskell` alias when its DSL name must remain a hard keyword.
- A *wire word* may also contain hyphens. Context names, ID prefixes, enum wire
  values, state-map values, and workflow labels use this form.
- Double-quoted strings support `\"`, `\\`, `\n`, `\t`, and `\r`. Raw newlines
  and unknown escapes are errors.
- A duration is decimal digits followed by exactly `s`, `m`, or `h`, such as
  `30s`, `5m`, or `2h`.
- Keywords are case-sensitive. In particular, aggregate register initials use
  `True` and `False`, while expressions use `true` and `false`.
- `parse` and `pretty` produce canonical syntax but do not preserve comments or
  original whitespace.

Top-level declarations in the same category must have unique names. Node names
must be unique within their node family. Generated Haskell names must also avoid
case-folded path collisions and constructor collisions.

### Parser scaling

Source-span capture derives each production's consumed slice from Megaparsec offsets, so attaching
exact locations does not measure the complete remaining input before and after every nested field,
expression, state, or transition. Reproduce the manual scaling benchmark with:

```bash
cabal bench keiro-dsl:keiro-dsl-parser-bench \
  --benchmark-options='-j1 --csv /tmp/keiro-dsl-parser.csv'
```

The benchmark keeps a service at eight aggregates and doubles nested transitions from 32 to 256;
its workspace group keeps eight aggregates and 128 transitions while splitting them across one,
two, four, or eight in-memory members. On one Apple arm64 machine with GHC 9.12.4 and Cabal's `-O1`
profile, the 100,762-character largest case changed from 30.742 ms to 28.857 ms through
`parseSurfaceSource` and from 55.581 ms to 50.273 ms through the compatibility `parseSource` route.
The workspace means stayed within measurement uncertainty because `loadWorkspace` also constructs
source indices and composes the semantic service graph.

Exact Unicode/tab/newline spans, diagnostics, semantic results, and frozen compatibility fixtures
remain unchanged. This affects parsing performed by the CLI, workspace loading, code generation,
and source-aware library or editor tooling; it does not speed up generated application runtime.
