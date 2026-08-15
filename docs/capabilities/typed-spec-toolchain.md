---
title: "Typed-spec (.keiro) toolchain"
type: Capability
description: "Author a service in the stable Language-5 .keiro contract, compose workspaces, check semantics, scaffold runtime and create-once code, emit conformance packages, and gate persistence and consumer impact with diff."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
capabilityId: CAP-14
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro-dsl
interface:
  - Keiro.Dsl.Frontend
  - Keiro.Dsl.Validate
  - Keiro.Dsl.Scaffold
  - Keiro.Dsl.Diff
  - Keiro.Dsl.Harness
  - Keiro.Dsl.Workspace
  - Keiro.Dsl.SemanticImpact
evidence:
  - kind: conformance
    resource: keiro-dsl/test/conformance/Main.hs
    proves: "A conformance suite that pins generated output; the package registers compiled suites for aggregates, structural and nominal types, workspaces, replay, snapshots, mapped queues/read models, catalogs, typed outcomes, routers, processes, workflows, and integration surfaces."
  - kind: test
    resource: keiro-dsl/test/Main.hs
    proves: "The versioned frontend, checker, semantic-impact model, workspace composition, diff engine, scaffold generator, source maps, and migration/refusal paths over the complete node vocabulary."
  - kind: conformance
    resource: keiro-dsl/test/conformance-newsurface/Main.hs
    proves: "The complete stable-Language-5 surface compiles through the generated runtime and service conformance package under explicit language ownership."
  - kind: guide
    resource: docs/user/typed-spec-toolchain.md
    proves: "How to author a .keiro spec, select a language version, run check/scaffold/diff, and fill the generated create-once holes."
---

# Typed-spec (.keiro) toolchain

A separately depended-on toolchain (`keiro-dsl`) that lets a consumer describe a
service — aggregate, process manager, custom or declarative router, integration
contract, queue, read model and projection catalog, durable workflow, and more —
in a typed `.keiro` specification, and then:

- **select** an explicit released language contract before parsing. Language 5
  is the stable/default authoring contract; Languages 1–4 retain their published
  compatibility meaning;
- **compose** multi-file service workspaces with shared nominal declarations and
  one checked cross-context semantic graph;
- **check** cross-node policy, type capabilities, behavior coverage, catalog
  ownership, mapped consumers, and warning policy before generation;
- **scaffold** the deterministic generated layer, runtime package, service
  conformance package, and explicit typed *create-once* holes a human fills
  against generated signatures;
- **explain** exact source provenance and semantic/artifact impact, so unrelated
  changes do not force fleet-wide regeneration;
- **diff** the spec against a git ref to classify wire, replay, snapshot,
  behavior, coordination, mapped-consumer, catalog, and external-read evolution
  before it ships.

Stable Language 5 includes the projection-catalog contract from
[CAP-6](typed-projection-catalogs.md), guarded external reads from
[CAP-17](guarded-external-read-models.md), typed domain outcomes from
[CAP-18](typed-domain-command-outcomes.md), mapped queue/query and projection
consumers, and bounded declarative router selection from
[CAP-7](process-managers-routers-timers.md).
Generated behavior source maps preserve stable behavior keys while reporting
their current file, line, and column.

It is its own capability — a distinct package and CLI adopted as the source of
truth for a service — and it is verified by an unusually strong evidence base: a
family of conformance suites that pin generated output, not just unit tests.

## Shape

```bash
keiro-dsl check order.keiro --min-language 5 --deny-warnings
keiro-dsl scaffold order.keiro --out generated/
keiro-dsl diff order.keiro --since HEAD~1   # non-zero exit on a gated BREAKING surface
```

## Limits

- The toolchain generates code that targets the matching keiro runtime package
  set and capabilities in
  this catalog; a spec is only as adoptable as the runtime surface it scaffolds
  against. Generated code and sidecar ledgers are versioned together; update the
  lockstep package family and regenerate as one reviewed change.
- The grammar deliberately refuses spellings no runtime implements. A source
  without a preamble selects compatibility-only Language 1, while adopting
  Language 5 can surface new checked obligations rather than silently assigning
  new meaning to an old source.
- `diff` classifies compatibility from the spec and a conservative persistence
  model; it gates known unsafe surfaces but cannot prove an arbitrary hand-edit
  to a filled create-once hole is replay-safe. That guarantee still comes from
  the runtime's [replay-safety boundary (CAP-2)](replay-safety-validation.md).
