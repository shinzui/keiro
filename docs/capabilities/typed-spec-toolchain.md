---
title: "Typed-spec (.keiro) toolchain"
type: Capability
description: "Describe a service in a versioned typed .keiro spec, then parse, check, scaffold the generated layer plus create-once holes, emit a harness, and gate persistence-aware evolution with a spec diff — a released language contract selected before parsing."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-14
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro-dsl
interface:
  - Keiro.Dsl.Validate
  - Keiro.Dsl.Scaffold
  - Keiro.Dsl.Diff
  - Keiro.Dsl.Harness
evidence:
  - kind: conformance
    resource: keiro-dsl/test/conformance/Main.hs
    proves: "A conformance suite that pins the generated output of representative specs so scaffold and check behavior cannot drift silently; the keiro-dsl.cabal file registers a family of further conformance suites (aggregate scalars, nominal scalars, structural, behavior-complete, workspace nominals)."
  - kind: test
    resource: keiro-dsl/test/Main.hs
    proves: "The parser, checker, diff engine, and scaffold generator over the full node vocabulary (aggregate, process, router, contract, intake, emit, publisher, workqueue, dispatch, workflow, operation)."
  - kind: guide
    resource: docs/user/typed-spec-toolchain.md
    proves: "How to author a .keiro spec, select a language version, run check/scaffold/diff, and fill the generated create-once holes."
---

# Typed-spec (.keiro) toolchain

A separately depended-on toolchain (`keiro-dsl`) that lets a consumer describe a
service — aggregate, process manager, router, integration contract, queue, read
model, durable workflow, and more — in a typed `.keiro` specification, and then:

- **select** an explicit released language contract before parsing, so a spec
  written against an older language keeps its exact meaning;
- **check** cross-node policy and structural coverage, with a warning policy CI
  can gate on;
- **scaffold** the deterministic generated layer plus explicit typed
  *create-once* holes a human fills against generated signatures;
- **emit** a test harness for the generated service;
- **diff** the spec against a git ref to classify per-surface compatibility and
  gate an unsafe, persistence-affecting evolution before it ships.

It is its own capability — a distinct package and CLI adopted as the source of
truth for a service — and it is verified by an unusually strong evidence base: a
family of conformance suites that pin generated output, not just unit tests.

## Shape

```bash
keiro-dsl check order.keiro --min-language 4 --deny-warnings
keiro-dsl scaffold order.keiro --out generated/
keiro-dsl diff order.keiro --since HEAD~1   # non-zero exit on a gated BREAKING surface
```

## Limits

- The toolchain generates code that targets the keiro runtime capabilities in
  this catalog; a spec is only as adoptable as the runtime surface it scaffolds
  against. The grammar deliberately refuses spellings no runtime implements
  (for example a lenient intake body, or a non-canonical dispatch-id tuple), and
  those refusals became hard errors from language 4 — a spec written loosely
  against an earlier language may need edits to pass a current check.
- `diff` classifies compatibility from the spec and a conservative persistence
  model; it gates known unsafe surfaces but cannot prove an arbitrary hand-edit
  to a filled create-once hole is replay-safe. That guarantee still comes from
  the runtime's replay-safety boundary (CAP-2).
