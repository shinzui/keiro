---
id: 32
slug: upgrade-to-hs-opentelemetry-1-0-and-align-to-latest-opentelemetry-semantic-conventions
title: "Upgrade to hs-opentelemetry 1.0 and align to latest OpenTelemetry semantic conventions"
kind: exec-plan
created_at: 2026-06-01T19:55:43Z
intention: "intention_01kt2bvpsvefssk0zd467rbwak"
---

# Upgrade to hs-opentelemetry 1.0 and align to latest OpenTelemetry semantic conventions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro` is an event-sourcing and workflow framework written in Haskell. It emits
**OpenTelemetry** traces — structured records of "what happened, when, and under which
parent operation" — so operators can see, in a tracing dashboard (Honeycomb, Jaeger,
Grafana Tempo, etc.), how a message flowed from an outbox publish, across a Kafka topic,
into a downstream consumer, and through a command that appended events. The library talks
to OpenTelemetry through a family of Haskell packages whose names all begin with
`hs-opentelemetry-`.

Today `keiro` declares it depends on the **0.x** generation of those packages
(`hs-opentelemetry-api >= 0.3 && < 0.4`, `hs-opentelemetry-semantic-conventions >= 0.1 && < 1`,
and so on — see `keiro/keiro.cabal:75-77` and `keiro/keiro.cabal:109-113`). That generation
is now superseded: a **1.0** generation of these packages exists on disk at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project` (api, api-types, sdk,
propagator-w3c, exporter-in-memory all at version `1.0.0.0`; the semantic-conventions
package at `1.40.0.0`, generated from version 1.40 of the upstream OpenTelemetry
specification).

The codebase has already been **partially** moved to 1.0 without the dependency bounds being
updated to match. Two pieces of evidence:

1. `keiro/src/Keiro/Telemetry.hs` was edited in commit `3f5dc9c` ("fix(telemetry): restore
   context detach on otel 1") to call the 1.0 form of `attachContext` / `detachContext`,
   where `attachContext` now **returns a token** that must be passed back to `detachContext`
   (the 0.x form took no token). That edit only compiles against the 1.0 API.
2. `keiro/src/Keiro/Command.hs:53` already imports `OpenTelemetry.SemanticConventions (error_type)`
   directly from the typed conventions module — a binding that the pinned **0.1.0.0** Hackage
   release of `hs-opentelemetry-semantic-conventions` does not export.

So the source code already speaks 1.0, but `keiro.cabal` still forbids it (`< 0.4`, `< 1`).
The standalone `keiro` build can only succeed today because a parent "rei" superproject
(referenced in `3f5dc9c`'s `MasterPlan:`/`ExecPlan:` trailers) overrides the bounds and
supplies the 1.0 packages from source. **This plan makes the `keiro` repository correct on
its own terms**: its dependency bounds, its `cabal.project`, and its source code all agree
that the target is hs-opentelemetry 1.0 / semantic-conventions 1.40.

In addition to the bounds, this plan removes a workaround that exists *only* because of the
old pin. `keiro/src/Keiro/Telemetry.hs` currently **vendors** ten typed `AttributeKey`
bindings (`messaging_operation_type`, `db_system_name`, etc. at lines 119-147) — local
copies of conventions attributes — with a long Haddock comment explaining that the 0.1.0.0
Hackage semantic-conventions release "only exports 9 of the 22+ typed `AttributeKey`s" the
audit needs. That justification is now obsolete: the 1.40 release **does** export every one
of those keys, with identical types. We replace the vendored copies with direct imports from
`OpenTelemetry.SemanticConventions`, leaving only the three genuinely bespoke `keiro_*` keys
that have no upstream equivalent. We also replace the few remaining **string-literal**
attribute names in the span-attribute setters (`"messaging.system"`,
`"messaging.destination.name"`, `"messaging.message.id"`, `"messaging.kafka.message.key"`)
with the typed conventions bindings, so every attribute keiro emits is anchored to the
generated 1.40 conventions module rather than a hand-typed string.

**What someone can do after this change that they could not before:** build, test, and ship
`keiro` against hs-opentelemetry 1.0 from the `keiro` repository alone (no superproject
override), with every emitted span attribute name sourced from the typed, spec-generated
`OpenTelemetry.SemanticConventions` module. **How to see it working:** run the keiro test
suite, whose `Keiro.Telemetry` describe-block drains an in-memory span exporter and asserts
on the recorded attribute names; the names on the wire are unchanged (this is a
dependency/provenance upgrade, not a semantic change to what dashboards see), so existing
trace dashboards continue to key on the same `messaging.*` / `db.*` attribute names.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 — Establish 1.0 package provenance: confirmed hs-opentelemetry 1.0 / 1.40 **is on
  Hackage** (`cabal info` lists `hs-opentelemetry-api 1.0.0.0`,
  `hs-opentelemetry-semantic-conventions 1.40.0.0`, and the sdk / exporter-in-memory /
  propagator-w3c 1.0.0.0). No `cabal.project` pin needed — Step 1.2 skipped. (2026-06-01)
- [x] M1 — Bump dependency bounds in `keiro/keiro.cabal` (library + test-suite stanzas) to the
  1.0 / 1.40 generation. (2026-06-01)
- [x] M1 — `cabal build keiro` succeeds from the `keiro` repo with no external bound override;
  install plan resolves `hs-opentelemetry-api-1.0.0.0` / `hs-opentelemetry-semantic-conventions-1.40.0.0`. (2026-06-01)
- [x] M2 — De-vendor the ten framework `AttributeKey`s in `keiro/src/Keiro/Telemetry.hs`:
  import (and re-export) them from `OpenTelemetry.SemanticConventions`; keep only the three
  `keiro_*` keys defined locally. (2026-06-01)
- [x] M2 — Replace the four string-literal attribute names in the attribute setters with
  typed conventions bindings; removed the now-unused `addText` helper and its `ToAttribute`
  import. (2026-06-01)
- [x] M2 — Rewrite the module Haddock "Why vendor some AttributeKeys" block to describe the
  post-upgrade state (no vendoring). (2026-06-01)
- [x] M2 — Update `keiro/src/Keiro/Command.hs:63` to import `db_system_name` from
  `OpenTelemetry.SemanticConventions` instead of `Keiro.Telemetry`. (2026-06-01)
- [x] M2 — **(unplanned, required)** Migrate `keiro/test/Main.hs` to the 1.0 span-reflection
  API: the hot span fields (name/attributes/status) moved behind `spanHot :: IORef SpanHot`,
  and `shutdownTracerProvider` gained a `Maybe Int` timeout arg. Added a `CapturedSpan`
  frozen-snapshot helper. (2026-06-01)
- [x] M3 — Update the version note in `docs/research/opentelemetry-semconv-audit.md` to
  reflect that keiro now links the 1.40 release directly (no vendoring). (2026-06-01)
- [x] M4 — Full validation: `cabal build all` and `cabal test keiro-test` (81 examples, 0
  failures) pass; Step 4.3 grep prints nothing (no framework key defined locally); Step 4.4
  grep prints all 14 framework keys present in the 1.40 module; only the three `keiro_*` keys
  remain locally defined. (2026-06-01)

(Initial state: nothing in this plan implemented yet. The source already compiles against
the 1.0 API in the superproject; the bounds and de-vendoring are the remaining work.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The upgrade is already half-done in source but not in metadata. Commit `3f5dc9c` switched
  `withRemoteParent` from `bracket_` to `bracket` so the token returned by `attachContext`
  can be threaded into `detachContext` — the 1.0 calling convention — while
  `keiro/keiro.cabal` still pins `hs-opentelemetry-api < 0.4`. Evidence:

  ```text
  keiro/keiro.cabal:75:   hs-opentelemetry-api >= 0.3 && < 0.4,
  keiro/src/Keiro/Command.hs:53: import OpenTelemetry.SemanticConventions (error_type)
  ```

  `error_type` is not exported by the 0.1.0.0 semantic-conventions Hackage release the bound
  `< 1` would resolve, so the standalone bounds are internally inconsistent today.

- In the 1.0 package split, `OpenTelemetry.Attributes.Attribute` and
  `OpenTelemetry.Attributes.Key` physically moved to the new `hs-opentelemetry-api-types`
  package but are **re-exported** by `hs-opentelemetry-api` (its `reexported-modules:` block,
  `hs-opentelemetry-api.cabal:93-95`). This is why `keiro`'s `PackageImports`-qualified
  imports — `import "hs-opentelemetry-api" OpenTelemetry.Attributes.Key (...)` in
  `Keiro/Telemetry.hs:69` — keep resolving without adding `hs-opentelemetry-api-types` as a
  direct dependency. (If a future GHC tightens `PackageImports` against re-exported modules,
  the fallback is to add `hs-opentelemetry-api-types` to `build-depends` and re-tag the
  import string; see Decision Log.) Confirmed: the library + test built against 1.0 without
  ever adding `hs-opentelemetry-api-types` to `build-depends`; the re-export path holds.

- **The 1.0 span model is "cold record + hot IORef", which the test suite did not yet speak.**
  The plan asserted the telemetry tests "still pass" unchanged, but `keiro/test/Main.hs` was
  written against the **0.x** flat `ImmutableSpan` accessors `spanName` / `spanAttributes` /
  `spanStatus`. In 1.0 those mutable fields moved into `SpanHot` behind
  `ImmutableSpan.spanHot :: IORef SpanHot`
  (`hs-opentelemetry/api/src/OpenTelemetry/Internal/Trace/Types.hs:419-454`); only the cold
  fields (`spanContext`, `spanKind`, `spanParent`, `spanTracer`, `spanStart`) remain direct
  accessors. So the test did not compile against 1.0 standalone — it only ever built under the
  old `< 0.4` pin. Evidence (pre-fix build):

  ```text
  test/Main.hs:415:7: error: Variable not in scope: spanName :: ImmutableSpan -> a3
  test/Main.hs:417:17: Variable not in scope: spanAttributes
  test/Main.hs:423:12: Variable not in scope: spanStatus :: ImmutableSpan -> SpanStatus
  ```

  Two API deltas had to be absorbed in the test: (1) read the hot fields by `readIORef
  (spanHot sp)` then project `hotName` / `hotAttributes` / `hotStatus` — done via a small
  `CapturedSpan` frozen-snapshot record + `captureSpan :: ImmutableSpan -> IO CapturedSpan`,
  with the three telemetry assertion blocks switched to `cs*` accessors; (2)
  `shutdownTracerProvider` is now `TracerProvider -> Maybe Int -> m ShutdownResult` (timeout
  in microseconds), so the three call sites pass `Nothing`. After the migration all 81
  examples pass, including the producer/consumer/command attribute assertions that prove the
  wire names are unchanged.


## Decision Log

Record every decision made while working on the plan.

- Decision: Target hs-opentelemetry **1.0** for api/api-types/sdk/propagator-w3c/
  exporter-in-memory and **1.40** for semantic-conventions, matching the versions on disk at
  `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`.
  Rationale: those are the versions the source already compiles against (commit `3f5dc9c`),
  and the parent rei MasterPlan (`docs/masterplans/12-…`) is driving the whole dependency
  tree to this generation.
  Date: 2026-06-01

- Decision: Remove the ten vendored framework `AttributeKey`s from `Keiro.Telemetry` entirely
  and import them from `OpenTelemetry.SemanticConventions`, rather than re-exporting them from
  `Keiro.Telemetry` for source compatibility.
  Rationale: The vendoring existed solely to work around the 0.1.0.0 release's missing keys
  (documented in the module Haddock, `Keiro/Telemetry.hs:13-30`). With the 1.40 release every
  key is upstream with identical types (verified: all fifteen referenced keys resolve, e.g.
  `messaging_operation_type :: AttributeKey Text`, `messaging_kafka_offset :: AttributeKey
  Int64`). `Keiro.Command` already imports `error_type` directly from
  `OpenTelemetry.SemanticConventions`, so importing the rest from the same module is the
  consistent direction. Only the three `keiro.*` bespoke keys (`keiro_stream_name`,
  `keiro_retry_attempt`, `keiro_events_appended`) remain in `Keiro.Telemetry`.
  Date: 2026-06-01

- Decision: Add `source-repository-package` pins for the six otel packages to `cabal.project`
  *only if* hs-opentelemetry 1.0 is not resolvable from the configured package indices.
  Rationale: `cabal.project` already pins keiki/kiroku/codd this way; the otel project is a
  fork (`github.com/shinzui/hs-opentelemetry-project`) and may not be on Hackage. M1's first
  step empirically determines provenance before editing `cabal.project`, so we neither pin
  unnecessarily (if 1.0 is on Hackage) nor leave the build unresolvable (if it is not).
  Date: 2026-06-01

- Decision (M1 outcome): **No `cabal.project` pin was added.** `cabal info` confirmed the entire
  1.0 / 1.40 generation is published on the configured package index (Hackage): api 1.0.0.0,
  api-types 1.0.0.0, semantic-conventions 1.40.0.0, sdk 1.0.0.0, propagator-w3c 1.0.0.0,
  exporter-in-memory 1.0.0.0. `cabal build keiro` resolves and compiles against
  `hs-opentelemetry-api-1.0.0.0` / `hs-opentelemetry-semantic-conventions-1.40.0.0` with only
  the `keiro.cabal` bounds bump. The conditional Step 1.2 (source-repository-package pin from
  the `shinzui/hs-opentelemetry-project` fork) was therefore not exercised.
  Date: 2026-06-01

- Decision: This plan does **not** change the wire-level attribute names keiro emits, nor add
  new instrumentation sites. It is a dependency-provenance upgrade plus a de-vendoring
  cleanup. The semantic-conventions audit (`docs/research/opentelemetry-semconv-audit.md`) is
  already authored against v1.40, so "following the latest conventions" reduces to (a) linking
  the 1.40 release directly and (b) replacing the last hand-typed attribute-name strings with
  the generated typed bindings. New span sites (hydration, snapshot, read-model rebuild,
  projection, timer) remain the audit's out-of-scope follow-ups.
  Rationale: Keeping the change additive and behavior-preserving makes it independently
  verifiable against the existing telemetry test block, and avoids conflating a library bump
  with a coverage expansion.
  Date: 2026-06-01

- Decision (M2): Migrate the telemetry tests to the 1.0 span model via a local `CapturedSpan`
  frozen-snapshot record rather than reaching into `spanHot` inline at each assertion, and
  fold the `spanHot` read into the existing `readIORef spansRef` drain
  (`spans <- traverse captureSpan =<< readIORef spansRef`).
  Rationale: The 1.0 `inMemoryListExporter` yields `IORef [ImmutableSpan]` whose hot fields
  live behind an `IORef SpanHot`; the existing tests filter spans by name / by `message.id`
  attribute *before* asserting, so the hot fields must be available during the filter, not
  just the assertion. Snapshotting every drained span once keeps the three test blocks reading
  like the original (pure `cs*` field accesses) and avoids threading `IO` through the list
  comprehensions. The `Keiro.Telemetry` "re-exports AttributeKeys whose textual payload
  matches the spec name" test (renamed from "vendors …") is retained: it now validates the
  re-exported upstream keys' dotted names, which is exactly the provenance guarantee this plan
  establishes.
  Date: 2026-06-01

- Decision (M2): `db_system_name` is both re-exported from `Keiro.Telemetry` (so the module
  stays the one-stop telemetry surface) **and** imported directly from
  `OpenTelemetry.SemanticConventions` in `Keiro.Command`, matching the existing `error_type`
  import on the same line. This is the recommended end state in Step 2.3/2.6.
  Date: 2026-06-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-06-01.** keiro now builds, tests, and ships against hs-opentelemetry 1.0 /
semantic-conventions 1.40 from the `keiro` repository alone, with every emitted span attribute
name sourced from the typed, spec-generated `OpenTelemetry.SemanticConventions` module.

- **M1 (bounds + provenance).** The 1.0 / 1.40 generation turned out to be on Hackage
  (`hs-opentelemetry-api 1.0.0.0`, `…-semantic-conventions 1.40.0.0`, sdk / propagator-w3c /
  exporter-in-memory 1.0.0.0), so the conditional `cabal.project` source pin was **not**
  needed — only the `keiro.cabal` library + test-suite bounds bump. `cabal build keiro`
  resolves `hs-opentelemetry-api-1.0.0.0` / `hs-opentelemetry-semantic-conventions-1.40.0.0`.
- **M2 (de-vendor + typed-ify).** Removed all ten vendored framework `AttributeKey`s from
  `Keiro.Telemetry`, importing and re-exporting them from `OpenTelemetry.SemanticConventions`;
  replaced the four remaining string-literal attribute names in the producer/consumer setters
  with typed bindings; removed the now-dead `addText` helper; repointed `Keiro.Command`'s
  `db_system_name` to the conventions module. Only `keiro_stream_name` / `keiro_retry_attempt`
  / `keiro_events_appended` remain locally defined.
- **M3 (audit note).** Rewrote the audit's stale "0.1.0.0 + vendoring" version note to record
  the direct 1.40 dependency.

**Gap vs. plan — the one surprise.** The plan asserted the telemetry tests would pass
unchanged, but `keiro/test/Main.hs` spoke the **0.x** flat-accessor span API
(`spanName`/`spanAttributes`/`spanStatus`) that 1.0 moved behind `spanHot :: IORef SpanHot`,
and `shutdownTracerProvider` gained a `Maybe Int` timeout. The test only ever compiled under
the old `< 0.4` pin. This required an unplanned but mechanical test migration: a `CapturedSpan`
frozen-snapshot helper (`captureSpan :: ImmutableSpan -> IO CapturedSpan`) folded into the
existing exporter drain, and `Nothing` passed to the three `shutdownTracerProvider` calls. No
production wire behavior changed — the 81-example suite, including the producer/consumer/command
attribute assertions, passes, proving dashboards see identical `messaging.*` / `db.*` names.

**Lesson.** A "dependency-provenance only" bump can still carry a real source migration in the
*test* tree when the upgraded library restructures the types tests reflect on. Verifying the
standalone build (not just the superproject build) surfaced it immediately.


## Context and Orientation

The reader is assumed to know Haskell and Cabal but nothing about this repository.

**Repository layout.** This is a multi-package Cabal project. The root `cabal.project`
(`/Users/shinzui/Keikaku/bokuno/keiro/cabal.project`) lists the local packages
(`keiro`, `keiro-core`, `keiro-migrations`, `keiro-test-support`, `jitsurei`) and pins a
handful of git dependencies (keiki, kiroku-store, codd) via `source-repository-package`
stanzas. The library this plan touches lives under `keiro/` — its package description is
`keiro/keiro.cabal` and its source under `keiro/src/`.

**OpenTelemetry, in plain terms.** OpenTelemetry is a vendor-neutral standard for emitting
*traces*. A trace is a tree of *spans*; each span records an operation with a name, a *kind*
(`Producer` for "I sent a message", `Consumer` for "I received one", `Internal` for in-process
work), a start/end time, and a bag of *attributes* (key/value pairs). The OpenTelemetry
project publishes a registry of standard attribute names — the *semantic conventions* — so
that, e.g., every messaging system records the destination under the same key
`messaging.destination.name`. The Haskell binding generates a module
`OpenTelemetry.SemanticConventions` containing one typed Haskell value per convention
attribute (for example `messaging_destination_name :: AttributeKey Text`), so code references
a checked binding instead of a hand-typed string.

**The Haskell packages involved** (the six `keiro` depends on, with their 1.0/1.40 versions
on disk under `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/`):

- `hs-opentelemetry-api` (`api/`, 1.0.0.0) — the core span/context/attribute API. Modules
  keiro imports: `OpenTelemetry.Context`, `OpenTelemetry.Context.ThreadLocal`,
  `OpenTelemetry.Trace.Core`, and (re-exported from api-types) `OpenTelemetry.Attributes.Key`,
  `OpenTelemetry.Attributes.Attribute`.
- `hs-opentelemetry-api-types` (`api-types/`, 1.0.0.0) — new in 1.0; the `AttributeKey`
  newtype now lives here (`OpenTelemetry.Attributes.Key`,
  `newtype AttributeKey a = AttributeKey {unkey :: Text}`). Re-exported by `api`, so keiro
  need not list it directly.
- `hs-opentelemetry-semantic-conventions` (`semantic-conventions/`, 1.40.0.0) — the generated
  conventions module `OpenTelemetry.SemanticConventions`. This is the package whose Hackage
  pin was the reason for the vendoring workaround.
- `hs-opentelemetry-propagator-w3c` (`propagators/w3c/`, 1.0.0.0) — encodes/decodes the W3C
  `traceparent`/`tracestate` headers. keiro imports
  `OpenTelemetry.Propagator.W3CTraceContext (encodeSpanContext, decodeSpanContext)`.
- `hs-opentelemetry-sdk` (`sdk/`, 1.0.0.0) — used by the **test suite** to build a real
  tracer. Library code only takes a `Tracer` someone else built.
- `hs-opentelemetry-exporter-in-memory` (`exporters/in-memory/`, 1.0.0.0) — used by the
  **test suite** to capture emitted spans for assertions
  (`OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)`).

**The file at the center of this plan: `keiro/src/Keiro/Telemetry.hs`.** It is the single
module that wraps the otel API for the whole `keiro` library. It exports span helpers
(`withProducerSpan`, `withConsumerSpan`, `withCommandSpan`), a W3C trace-context bridge
(`traceContextFromCurrentSpan`, `traceContextFromHeaders`, `injectTraceContext`), and — the
part this plan removes — ten vendored framework `AttributeKey`s plus three bespoke `keiro_*`
keys. The vendored keys and their justification sit at lines 13-30 (Haddock), 44-61 (export
list), and 108-156 (definitions). The attribute setters `setProducerAttributes` (lines
340-350) and `setConsumerAttributes` (lines 352-374) still use a mix of typed keys and bare
string literals; this plan makes them uniformly typed.

**Consumers of the vendored keys.** Only `keiro/src/Keiro/Command.hs` imports any of them:
line 63, `import Keiro.Telemetry (keiro_events_appended, db_system_name, withCommandSpan)`.
`keiro_events_appended` stays in `Keiro.Telemetry` (it is bespoke); `db_system_name` becomes
an import from `OpenTelemetry.SemanticConventions` (Command.hs already imports `error_type`
from there at line 53, so this is a one-line addition to an existing import). The test suite
`keiro/test/Main.hs` exercises the span helpers but does not import the vendored keys by name.

**The semantic-conventions audit.** `docs/research/opentelemetry-semconv-audit.md` is the
prose specification of which span exists at which call site, with which name, kind, and
attributes, every one citing a typed `AttributeKey` from `OpenTelemetry.SemanticConventions`
and a line anchor in the 1.40 generated module. It carries a "Version note (2026-05-19)"
(lines 21-31) explaining the vendoring workaround. That note becomes stale once this plan
de-vendors, and M3 updates it.


## Plan of Work

The work is four milestones. M1 makes the build resolve and compile against 1.0 with correct
bounds — the load-bearing change. M2 removes the vendoring and the string-literal attribute
names, which is purely a source cleanup that must not change emitted wire names. M3 updates
the audit document's now-stale version note. M4 is the end-to-end validation sweep. Each
milestone ends in a green build and (from M1 onward) green tests, and each is committed
separately with the `ExecPlan:` and `Intention:` trailers required by this repository.

### Milestone 1 — Correct bounds and provenance so `keiro` builds against 1.0 standalone

**Scope.** Update `keiro/keiro.cabal` dependency bounds to the 1.0/1.40 generation in both the
`library` and `test-suite keiro-test` stanzas, and ensure `cabal` can actually *find* those
versions — adding `source-repository-package` pins to `cabal.project` if and only if the
packages are not resolvable from the configured indices. At the end of this milestone,
`cabal build keiro` succeeds from a clean checkout of the `keiro` repo with no external
override.

**Step 1.1 — Determine provenance.** From the repo root
`/Users/shinzui/Keikaku/bokuno/keiro`, ask cabal whether it can see a 1.0 release:

```bash
cabal update
cabal list --installed hs-opentelemetry-api
cabal info hs-opentelemetry-api 2>&1 | head -20
```

If `cabal info` lists an available `1.0.x` version from a package index, the packages are on
Hackage and no `cabal.project` pin is needed — skip to Step 1.3. If the only versions shown
are `0.x` (or the package is unknown), the 1.0 packages must be supplied from source — do
Step 1.2 first.

**Step 1.2 — (Conditional) Pin the otel packages from source.** The on-disk otel tree is a
git checkout of `https://github.com/shinzui/hs-opentelemetry-project.git` at commit
`8cd70c18c58d2ac9772e11713669130632bc1108` (verified via `git -C
/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project rev-parse HEAD`). Add six
`source-repository-package` stanzas to `cabal.project`, mirroring the existing keiki/kiroku
pin style, one per package subdirectory. The subdirectories inside the repo are
`hs-opentelemetry/api`, `hs-opentelemetry/api-types`, `hs-opentelemetry/semantic-conventions`,
`hs-opentelemetry/sdk`, `hs-opentelemetry/propagators/w3c`, and
`hs-opentelemetry/exporters/in-memory`. Insert after the existing `codd-project` stanza and
before the `allow-newer:` block:

```cabal
source-repository-package
  type: git
  location: https://github.com/shinzui/hs-opentelemetry-project.git
  tag: 8cd70c18c58d2ac9772e11713669130632bc1108
  subdir: hs-opentelemetry/api
          hs-opentelemetry/api-types
          hs-opentelemetry/semantic-conventions
          hs-opentelemetry/sdk
          hs-opentelemetry/propagators/w3c
          hs-opentelemetry/exporters/in-memory
```

A single `source-repository-package` stanza may list multiple `subdir` paths, so one stanza
covers all six packages. (If `cabal` complains it cannot find a package in a listed subdir,
split that subdir into its own stanza — the multi-subdir form is the compact default, but
one-stanza-per-subdir is the unambiguous fallback. Record which form you used in the Decision
Log.) Pin to the exact commit so the build is reproducible. Note: a local on-disk tree
already exists at the `hub` path, but `cabal.project` cannot portably reference an
absolute local path on another machine; the git pin is the reproducible form and matches the
repo's existing convention.

**Step 1.3 — Bump the library-stanza bounds.** In `keiro/keiro.cabal`, the `library` stanza
`build-depends` (lines 75-77) currently reads:

```cabal
hs-opentelemetry-api >= 0.3 && < 0.4,
hs-opentelemetry-propagator-w3c >= 0.1 && < 0.2,
hs-opentelemetry-semantic-conventions >= 0.1 && < 1,
```

Change to the 1.0/1.40 generation:

```cabal
hs-opentelemetry-api >= 1.0 && < 1.1,
hs-opentelemetry-propagator-w3c >= 1.0 && < 1.1,
hs-opentelemetry-semantic-conventions >= 1.40 && < 2,
```

The `< 2` upper bound on semantic-conventions follows the convention package's own self-bound
(`hs-opentelemetry-api` depends on it as `>= 1.40 && < 2`), since the conventions package's
major version tracks the upstream spec version (1.40) and can advance within the 1.x line
without API breaks.

**Step 1.4 — Bump the test-suite-stanza bounds.** In the same file, the
`test-suite keiro-test` stanza (lines 109-113) currently reads:

```cabal
hs-opentelemetry-api >= 0.3 && < 0.4,
hs-opentelemetry-exporter-in-memory >= 0.0.1 && < 0.1,
hs-opentelemetry-propagator-w3c >= 0.1 && < 0.2,
hs-opentelemetry-sdk >= 0.1 && < 0.2,
hs-opentelemetry-semantic-conventions >= 0.1 && < 1,
```

Change to:

```cabal
hs-opentelemetry-api >= 1.0 && < 1.1,
hs-opentelemetry-exporter-in-memory >= 1.0 && < 1.1,
hs-opentelemetry-propagator-w3c >= 1.0 && < 1.1,
hs-opentelemetry-sdk >= 1.0 && < 1.1,
hs-opentelemetry-semantic-conventions >= 1.40 && < 2,
```

**Step 1.5 — Build.** From `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal build keiro
```

**Acceptance for M1.** `cabal build keiro` compiles the library against
hs-opentelemetry-api-1.0.0.0 (and the semantic-conventions-1.40 release) with no external
bound override. The build log's dependency resolution shows `hs-opentelemetry-api-1.0.0.0`
(confirm with `cabal build keiro -v2 2>&1 | grep hs-opentelemetry-api` showing a `1.0`
version, not `0.3`). The source is unchanged in this milestone — only `keiro.cabal` and
(conditionally) `cabal.project`. Commit with message:

```text
build(deps): require hs-opentelemetry 1.0 / semantic-conventions 1.40

Bump the keiro library and test-suite bounds from the 0.x otel generation
to 1.0 (api, propagator-w3c, sdk, exporter-in-memory) and 1.40
(semantic-conventions). The source already compiles against the 1.0 API
(token-returning attachContext in Keiro.Telemetry, error_type imported from
OpenTelemetry.SemanticConventions in Keiro.Command); this makes the bounds
agree so keiro builds standalone without a superproject override.

ExecPlan: docs/plans/32-upgrade-to-hs-opentelemetry-1-0-and-align-to-latest-opentelemetry-semantic-conventions.md
Intention: intention_01kt2bvpsvefssk0zd467rbwak
```

### Milestone 2 — De-vendor the framework attribute keys and typed-ify the literals

**Scope.** With 1.40 available, delete the ten vendored framework `AttributeKey`s from
`keiro/src/Keiro/Telemetry.hs` and import them from `OpenTelemetry.SemanticConventions`;
replace the four remaining string-literal attribute names in the setters with typed bindings;
rewrite the module Haddock that justified the vendoring; and repoint `Keiro.Command`'s
`db_system_name` import. At the end, `keiro` emits exactly the same attribute names on the
wire, but every name comes from the generated 1.40 conventions module, and `Keiro.Telemetry`
exports only the three bespoke `keiro_*` keys.

**The ten keys to de-vendor** (all verified present in 1.40 with matching types — see the
verification grep in M4): `messaging_operation_type`, `messaging_operation_name`,
`messaging_destination_partition_id`, `messaging_consumer_group_name`, `messaging_client_id`,
`messaging_kafka_offset` (`AttributeKey Int64`), `db_system_name`, `db_namespace`,
`db_collection_name`, `db_operation_name`. **The four string-literals to typed-ify** (also
present in 1.40): `messaging_system` (was `"messaging.system"`), `messaging_destination_name`
(was `"messaging.destination.name"`), `messaging_message_id` (was `"messaging.message.id"`),
`messaging_kafka_message_key` (was `"messaging.kafka.message.key"`). **The three keys that
stay** in `Keiro.Telemetry`: `keiro_stream_name`, `keiro_retry_attempt`,
`keiro_events_appended`.

**Step 2.1 — Add the conventions import.** In `keiro/src/Keiro/Telemetry.hs`, add an import
of the fourteen now-upstream keys (the ten de-vendored plus the four typed-ified) from
`OpenTelemetry.SemanticConventions`. Place it near the other otel imports (after the
`OpenTelemetry.Trace.Core` import block around line 84). With `PackageImports` enabled
project-wide, give it the package tag:

```haskell
import "hs-opentelemetry-semantic-conventions" OpenTelemetry.SemanticConventions
  ( messaging_system
  , messaging_operation_type
  , messaging_operation_name
  , messaging_destination_name
  , messaging_destination_partition_id
  , messaging_consumer_group_name
  , messaging_client_id
  , messaging_message_id
  , messaging_kafka_message_key
  , messaging_kafka_offset
  , db_system_name
  , db_namespace
  , db_collection_name
  , db_operation_name
  )
```

(Import `messaging_client_id`, `db_namespace`, `db_collection_name`, and `db_operation_name`
even if no setter uses them yet, because they are currently in the module's **export list**
and dropping them would be a breaking API change to `Keiro.Telemetry`. Re-exporting the
upstream binding keeps the module's public surface stable while removing the vendored
definition. See Step 2.3.)

**Step 2.2 — Delete the vendored definitions.** Remove the definitions of the ten framework
keys (lines 119-147 in the current file: `messaging_operation_type` through
`db_operation_name`). Keep the three `keiro_*` definitions (lines 149-156) exactly as they
are — they have no upstream equivalent.

**Step 2.3 — Keep the module's export list stable.** The export list (lines 44-61) currently
lists the vendored keys under the "Vendored AttributeKeys" heading. Re-export the now-imported
framework keys plus the bespoke `keiro_*` keys under a renamed heading, e.g.:

```haskell
    -- * Re-exported semantic-convention 'AttributeKey's
    --
    -- $semconv_keys
  , messaging_operation_type
  , messaging_operation_name
  , messaging_destination_partition_id
  , messaging_consumer_group_name
  , messaging_client_id
  , messaging_kafka_offset
  , db_system_name
  , db_namespace
  , db_collection_name
  , db_operation_name

    -- * Bespoke keiro 'AttributeKey's
  , keiro_stream_name
  , keiro_retry_attempt
  , keiro_events_appended
```

Keeping these in the export list means `Keiro.Command`'s existing
`import Keiro.Telemetry (… db_system_name …)` would still type-check — but Step 2.6 repoints
it to the conventions module anyway for consistency with the existing `error_type` import.
Decide per the Decision Log whether to keep re-exporting the framework keys from
`Keiro.Telemetry` at all; the recommended end state is that `Keiro.Telemetry` re-exports the
messaging/db keys (so the module remains the one-stop telemetry surface) **and** `Command.hs`
imports `db_system_name` from the conventions module directly (matching `error_type`). If you
instead drop the framework keys from `Keiro.Telemetry`'s exports entirely, update every
importer; only `Command.hs` imports one (`db_system_name`).

**Step 2.4 — Typed-ify the setter literals.** In `setProducerAttributes` (lines 340-350) and
`setConsumerAttributes` (lines 352-374), replace the `addText sp "<dotted.name>" value` calls
that use string literals with `addAttribute sp (unkey <typed_key>) value`. Concretely:

```diff
-  addText sp "messaging.system" ("kafka" :: Text)
+  addAttribute sp (unkey messaging_system) ("kafka" :: Text)
   addAttribute sp (unkey messaging_operation_type) ("publish" :: Text)
   addAttribute sp (unkey messaging_operation_name) ("send" :: Text)
-  addText sp "messaging.destination.name" (event ^. #destination)
-  addText sp "messaging.message.id" (event ^. #messageId)
+  addAttribute sp (unkey messaging_destination_name) (event ^. #destination)
+  addAttribute sp (unkey messaging_message_id) (event ^. #messageId)
   case event ^. #key of
     Nothing -> pure ()
-    Just k -> addText sp "messaging.kafka.message.key" k
+    Just k -> addAttribute sp (unkey messaging_kafka_message_key) k
```

Apply the analogous replacements in `setConsumerAttributes` for `"messaging.system"`,
`"messaging.destination.name"`, `"messaging.kafka.message.key"`, and `"messaging.message.id"`.
After this, the `addText` helper (lines 376-377) has no remaining callers — remove it and its
`ToAttribute` import if nothing else uses them, or leave it if other call sites remain (grep
to confirm before removing). The dotted-name string each typed key carries is identical to the
literal it replaces (verified: `messaging_system = "messaging.system"`, etc.), so **the wire
output is byte-for-byte unchanged**.

**Step 2.5 — Rewrite the vendoring Haddock.** Replace the module-header Haddock block "# Why
vendor some 'AttributeKey's" (lines 13-30) and the `$vendored_keys` chunk (lines 108-117) with
text describing the post-upgrade state: keiro links `hs-opentelemetry-semantic-conventions`
1.40 directly; the messaging/db attribute keys are imported (and re-exported) from
`OpenTelemetry.SemanticConventions`; only the `keiro.*` keys are defined locally because they
are bespoke to keiro and have no upstream equivalent. Remove the references to "ExecPlan 25
Decision Log" and the 0.4-API-incompatibility story, which no longer apply.

**Step 2.6 — Repoint `Command.hs`.** In `keiro/src/Keiro/Command.hs`, change line 63 from

```haskell
import Keiro.Telemetry (keiro_events_appended, db_system_name, withCommandSpan)
```

to import the bespoke key and helper from `Keiro.Telemetry`, and `db_system_name` from the
conventions module alongside the existing `error_type` import (line 53):

```haskell
import OpenTelemetry.SemanticConventions (db_system_name, error_type)
...
import Keiro.Telemetry (keiro_events_appended, withCommandSpan)
```

(If Step 2.3 kept `db_system_name` re-exported from `Keiro.Telemetry`, this repoint is
optional but recommended for consistency. Record the choice in the Decision Log.)

**Step 2.7 — Build and test.** From `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal build keiro
cabal test keiro-test
```

**Acceptance for M2.** The library and test suite compile. The `Keiro.Telemetry` describe
block in `keiro/test/Main.hs` (around lines 1516-1562) and the parenting test (lines
1268-1295) pass — these drain the in-memory exporter and assert on recorded attributes, so
their passing proves the emitted attribute **names and values are unchanged** after
de-vendoring. A grep confirms no framework key is defined locally any more (see M4). Commit:

```text
refactor(telemetry): import semconv attribute keys from 1.40 release

Drop the ten vendored framework AttributeKeys from Keiro.Telemetry now that
hs-opentelemetry-semantic-conventions 1.40 exports them, importing (and
re-exporting) messaging.* / db.* keys from OpenTelemetry.SemanticConventions.
Replace the last hand-typed attribute-name string literals in the producer
and consumer setters with the typed bindings. Only the bespoke keiro.* keys
remain local. Wire-level attribute names are unchanged; the telemetry tests
that assert on emitted attributes still pass.

ExecPlan: docs/plans/32-upgrade-to-hs-opentelemetry-1-0-and-align-to-latest-opentelemetry-semantic-conventions.md
Intention: intention_01kt2bvpsvefssk0zd467rbwak
```

### Milestone 3 — Update the semantic-conventions audit's stale version note

**Scope.** The audit doc `docs/research/opentelemetry-semconv-audit.md` carries a "Version
note (2026-05-19)" (lines 21-31) stating keiro links the **0.1.0.0** release and vendors the
missing keys. After M2 that is false. Update the note to record that keiro now links the 1.40
release directly and no longer vendors any framework key; the citations (which already point
at the v1.40 generated module) are unchanged and now match the linked release exactly.

**Step 3.1.** Rewrite lines 21-31 to a short note: as of this plan (cite the plan path), keiro
depends on `hs-opentelemetry-semantic-conventions >= 1.40`, every typed `AttributeKey` cited
below is imported directly from `OpenTelemetry.SemanticConventions`, and the prior vendoring
workaround in `Keiro.Telemetry` has been removed. Leave the per-site sections and the
citation table untouched — they were authored against v1.40 and remain accurate.

**Step 3.2 — Acceptance.** The doc no longer claims a 0.1.0.0 pin or vendoring. Commit:

```text
docs(telemetry): note keiro links semantic-conventions 1.40 directly

The audit's version note described the 0.1.0.0 pin and the Keiro.Telemetry
vendoring workaround, both removed in this plan. Update it to reflect the
direct 1.40 dependency; per-site citations were already v1.40 and are
unchanged.

ExecPlan: docs/plans/32-upgrade-to-hs-opentelemetry-1-0-and-align-to-latest-opentelemetry-semantic-conventions.md
Intention: intention_01kt2bvpsvefssk0zd467rbwak
```

### Milestone 4 — End-to-end validation

**Scope.** Prove the whole upgrade holds: the entire workspace builds, the telemetry tests
pass, and no vendored framework key remains.

**Step 4.1 — Build everything.** From `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal build all
```

**Step 4.2 — Run the keiro test suite.**

```bash
cabal test keiro-test
```

**Step 4.3 — Prove de-vendoring.** Confirm `Keiro.Telemetry` defines only the three bespoke
keys and no framework key:

```bash
grep -nE "^(messaging_|db_)[a-z_]+ :: AttributeKey" keiro/src/Keiro/Telemetry.hs
```

Expected output: **nothing** (all framework-key *definitions* are gone; they appear only in
the import/export lists now).

**Step 4.4 — Prove the keys resolve from the 1.40 release.** Re-run the audit's own
verification grep against the on-disk conventions module to confirm every cited key exists
with the type keiro uses:

```bash
grep -nE "^(messaging_system|messaging_operation_type|messaging_operation_name|messaging_destination_name|messaging_destination_partition_id|messaging_message_id|messaging_consumer_group_name|messaging_kafka_message_key|messaging_kafka_offset|messaging_client_id|db_system_name|db_namespace|db_collection_name|db_operation_name) ::" \
  /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs
```

Expected: every listed identifier prints with its type (`messaging_kafka_offset ::
AttributeKey Int64`, the rest `:: AttributeKey Text`).

**Acceptance for M4.** `cabal build all` and `cabal test keiro-test` both succeed; Step 4.3
prints nothing; Step 4.4 prints all fifteen bindings. Fill in Outcomes & Retrospective.


## Concrete Steps

The exact commands, in order, from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro` unless stated otherwise.

```bash
# M1 — provenance + bounds
cabal update
cabal info hs-opentelemetry-api 2>&1 | head -20      # decide: Hackage or source pin?
# (edit cabal.project per Step 1.2 only if 1.0 is not resolvable)
# (edit keiro/keiro.cabal per Steps 1.3 and 1.4)
cabal build keiro
cabal build keiro -v2 2>&1 | grep hs-opentelemetry-api   # expect a 1.0.x line
git add keiro/keiro.cabal cabal.project
git commit                                               # message per M1

# M2 — de-vendor + typed-ify
# (edit keiro/src/Keiro/Telemetry.hs per Steps 2.1–2.5)
# (edit keiro/src/Keiro/Command.hs per Step 2.6)
cabal build keiro
cabal test keiro-test
git add keiro/src/Keiro/Telemetry.hs keiro/src/Keiro/Command.hs
git commit                                               # message per M2

# M3 — audit doc
# (edit docs/research/opentelemetry-semconv-audit.md per Step 3.1)
git add docs/research/opentelemetry-semconv-audit.md
git commit                                               # message per M3

# M4 — validation
cabal build all
cabal test keiro-test
grep -nE "^(messaging_|db_)[a-z_]+ :: AttributeKey" keiro/src/Keiro/Telemetry.hs   # expect empty
```

Update this section with the actual transcripts (resolved otel version, test summary line) as
each milestone completes.

**Actual results (2026-06-01):**

```text
# M1 — provenance: 1.0/1.40 found on Hackage, no cabal.project pin added
$ cabal info hs-opentelemetry-api | grep -A1 "Versions available"
    Versions available: 0.0.2.0, ..., 0.3.1.0, 1.0.0.0 (and 7 others)
# install plan resolves:
hs-opentelemetry-api-1.0.0.0
hs-opentelemetry-api-types-1.0.0.0
hs-opentelemetry-semantic-conventions-1.40.0.0
hs-opentelemetry-sdk-1.0.0.0
hs-opentelemetry-propagator-w3c-1.0.0.0
hs-opentelemetry-exporter-in-memory-1.0.0.0

# M2/M4 — test suite (after the 1.0 span-model test migration)
$ cabal test keiro-test
81 examples, 0 failures
Test suite keiro-test: PASS

# M4 — Step 4.3 (de-vendoring proof): empty
$ grep -nE "^(messaging_|db_)[a-z_]+ :: AttributeKey" keiro/src/Keiro/Telemetry.hs
(no output)

# M4 — Step 4.4 (keys resolve from 1.40): all 14 present
$ grep -cE "^(messaging_system|...|db_operation_name) ::" .../SemanticConventions.hs
14
```


## Validation and Acceptance

The change is a dependency-provenance upgrade plus a de-vendoring cleanup; its observable
effect is "keiro builds and traces correctly against hs-opentelemetry 1.0 with attribute
names sourced from the 1.40 conventions, and emits the same wire attributes as before."

Acceptance is demonstrated by:

1. **Build proof.** `cabal build all` succeeds and `cabal build keiro -v2 | grep
   hs-opentelemetry-api` shows a `1.0` version (not `0.3`). This proves the bounds resolve to
   the 1.0 generation.

2. **Behavioral proof — emitted attributes unchanged.** `cabal test keiro-test` passes,
   including the `Keiro.Telemetry` describe block in `keiro/test/Main.hs`. That block builds a
   real tracer with `hs-opentelemetry-sdk`, attaches an in-memory exporter from
   `hs-opentelemetry-exporter-in-memory`, runs `withProducerSpan` / `withConsumerSpan`, drains
   the exporter, and asserts on the recorded span names, kinds, and attribute key/value pairs
   (e.g. `messaging.system = kafka`, `messaging.destination.name = …`, the consumer span
   parented under the producer span via W3C headers). Because the typed keys carry identical
   dotted-name strings, these assertions pass unchanged — proving de-vendoring did not alter
   what dashboards see.

3. **De-vendoring proof.** `grep -nE "^(messaging_|db_)[a-z_]+ :: AttributeKey"
   keiro/src/Keiro/Telemetry.hs` prints nothing — every framework key is now imported, not
   locally defined; only `keiro_*` keys are defined in the module.

A reviewer who wants to see the trace shape end-to-end can read the parenting test
(`keiro/test/Main.hs:1268-1295`): it publishes inside a producer span, injects the W3C headers
via `injectTraceContext`, then opens a consumer span from those headers and asserts the
consumer span's parent trace id equals the producer's — the cross-process join that is the
whole point of the propagator wiring.


## Idempotence and Recovery

Every step is a file edit followed by a rebuild; all are safe to repeat. Re-running `cabal
build` / `cabal test` is idempotent. The `cabal.project` and `keiro.cabal` edits are textual
and reversible with `git checkout -- <file>`. If a milestone's build fails:

- **M1 fails to resolve the otel packages** (`cabal: Could not resolve dependencies`):
  hs-opentelemetry 1.0 is not on the configured indices — do Step 1.2 (add the
  `source-repository-package` pins) and re-run `cabal build keiro`. If a multi-`subdir` stanza
  is rejected, split it into one stanza per subdir.
- **M2 `PackageImports` error** ("Could not find module … in package hs-opentelemetry-api" for
  an `OpenTelemetry.Attributes.*` import): the re-export path changed; add
  `hs-opentelemetry-api-types >= 1.0 && < 1.1` to `keiro.cabal` build-depends and re-tag the
  affected imports `import "hs-opentelemetry-api-types" OpenTelemetry.Attributes.Key (...)`.
  This is the documented fallback in Surprises & Discoveries.
- **M2 test failure on an attribute assertion**: a typed key's dotted name does not match the
  literal it replaced. Re-check the substitution against the verification grep (Step 4.4) —
  the typed name and the old literal must be identical; revert the specific substitution if
  they differ and file a Surprise.

Because M2 is purely a source cleanup over an unchanged wire format, it can be reverted
independently of M1 (the bounds bump) if needed: M1 alone leaves keiro building against 1.0
with the vendored keys still in place, which is a valid intermediate state.


## Interfaces and Dependencies

**Dependency versions after this plan** (`keiro/keiro.cabal`):

- `hs-opentelemetry-api >= 1.0 && < 1.1` (library + test-suite)
- `hs-opentelemetry-propagator-w3c >= 1.0 && < 1.1` (library + test-suite)
- `hs-opentelemetry-semantic-conventions >= 1.40 && < 2` (library + test-suite)
- `hs-opentelemetry-sdk >= 1.0 && < 1.1` (test-suite)
- `hs-opentelemetry-exporter-in-memory >= 1.0 && < 1.1` (test-suite)

`hs-opentelemetry-api-types` is a transitive dependency (the `AttributeKey` newtype lives
there) re-exported by `hs-opentelemetry-api`; it is added to `build-depends` only if the
`PackageImports` fallback in Idempotence and Recovery is triggered.

**Module surface after this plan** (`keiro/src/Keiro/Telemetry.hs`):

- Span helpers unchanged: `withProducerSpan`, `withConsumerSpan`, `withCommandSpan`, all with
  their current signatures (`Maybe Tracer -> … -> (Maybe Span -> m a) -> m a`).
- W3C bridge unchanged: `traceContextFromCurrentSpan :: MonadIO m => m (Maybe TraceContext)`,
  `traceContextFromHeaders :: [(Text, Text)] -> Maybe TraceContext`,
  `injectTraceContext :: MonadIO m => [(Text, Text)] -> m [(Text, Text)]`.
- Attribute keys: the messaging/db convention keys are **re-exported** from
  `OpenTelemetry.SemanticConventions` (no behavior or type change — `messaging_kafka_offset ::
  AttributeKey Int64`, the rest `:: AttributeKey Text`); the bespoke
  `keiro_stream_name :: AttributeKey Text`, `keiro_retry_attempt :: AttributeKey Int64`,
  `keiro_events_appended :: AttributeKey Int64` remain defined locally.

**Upstream bindings relied upon** (all verified present at the on-disk 1.0/1.40 versions):

- `OpenTelemetry.Attributes.Key.AttributeKey {unkey :: Text}` — re-exported by
  `hs-opentelemetry-api` from `hs-opentelemetry-api-types`.
- `OpenTelemetry.Context.ThreadLocal.attachContext :: MonadIO m => Context -> m Token` and
  `detachContext :: MonadIO m => Token -> m ()` — the token-threading 1.0 form already used by
  `withRemoteParent`.
- `OpenTelemetry.Propagator.W3CTraceContext.{encodeSpanContext, decodeSpanContext}` —
  `hs-opentelemetry-propagator-w3c` 1.0.
- `OpenTelemetry.SemanticConventions` — the fifteen `AttributeKey` bindings listed in M2,
  `hs-opentelemetry-semantic-conventions` 1.40.
- (Test-only) `OpenTelemetry.Exporter.InMemory.Span.inMemoryListExporter` from
  `hs-opentelemetry-exporter-in-memory` 1.0, and the SDK tracer constructors from
  `hs-opentelemetry-sdk` 1.0.

**Out of scope** (explicitly, so a future reader does not assume otherwise): adding new span
sites (hydration, snapshot, read-model rebuild, projection apply, timer fire — the audit's
`milestone-9-followups`); a metrics or logs audit; `hasql-opentelemetry` adoption in
`kiroku-store`. This plan upgrades the dependency generation and removes the vendoring; it
does not expand instrumentation coverage.
