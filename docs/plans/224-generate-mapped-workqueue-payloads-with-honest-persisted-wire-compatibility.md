---
id: 224
slug: generate-mapped-workqueue-payloads-with-honest-persisted-wire-compatibility
title: "Generate mapped workqueue payloads with honest persisted-wire compatibility"
kind: exec-plan
created_at: 2026-08-09T20:45:30Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/35-make-mapped-types-first-class-across-queues-read-models-and-projections-before-fleet-adoption.md"
---

# Generate mapped workqueue payloads with honest persisted-wire compatibility

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a candidate-language-5 workqueue can carry a consumer-owned mapped type without
copying its JSON shape into queue-specific grammar or Haskell. `keiro-dsl scaffold` generates the
payload record, imports, structural bindings, and recursive queue encoder/decoder from the same
resolved mapping authority used by private events. A compiled queue conformance fixture enqueues a
nested mapped payload, decodes the generated `{v,t,data}` envelope, and recovers the exact domain
value.

The feature remains honest about persistence. Existing lower-case scalar queue fields and bytes do
not change. Every payload field remains present at the queue-object boundary; `Optional T` means a
present field whose value may be null, not an omitted field. A mapped wire or codec change is a
breaking queued-job compatibility hazard under the current schema-version-1 queue contract. Keiro
reports drain/transitional-codec work and never pretends event upcasters migrate queued jobs.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: factor one reusable resolved mapped-codec lowering plan from aggregate event
  generation and prove it preserves existing event bytes.
- [ ] Milestone 2: generate queue payload Haskell types/imports and recursive structural/opaque
  field codecs from candidate typed expressions.
- [ ] Milestone 3: classify mapped queue evolution and coverage separately from events, snapshots,
  and consumer-only query types.
- [ ] Milestone 4: compile queue roundtrip/history fixtures, add restoring mutations and docs, and
  remove the queue pending-lowering diagnostic with full validation green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Reuse one mapped codec-lowering algebra for aggregate event and workqueue generation.
  Rationale: Reimplementing structural bindings, nested containers, null policy, opaque codecs, or
  imports in the queue emitter would create a second wire authority and long-term drift.
  Date: 2026-08-09

- Decision: Keep the current queue envelope at schema version 1 and classify incompatible changes
  as drain/transitional-codec work.
  Rationale: Designing queue version ladders and upcaster ownership is a separate feature. Mapping
  support must not silently imply migration behavior that the grammar and runtime do not provide.
  Date: 2026-08-09

- Decision: Preserve required field presence independently of `Optional` value type.
  Rationale: Current queue decoders use `.:` for every field. Treating `Optional T` as an omitted
  key would change the top-level queue wire contract and conflate presence with nullability.
  Date: 2026-08-09

- Decision: Allow structural and explicitly opaque mapped declarations, but report them as
  separate coverage modes.
  Rationale: An opaque declaration is the honest boundary when the structural grammar cannot
  express a consumer invariant. It may use consumer JSON instances, but cannot receive structural
  coverage claims.
  Date: 2026-08-09

- Decision: Permit raw FIFO group-key derivation only from an exact direct `Text` field.
  Rationale: A mapped domain type may encode as JSON text without being a semantically raw `Text`.
  Inferring a conversion would add an undeclared projection/binding authority.
  Date: 2026-08-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan hard-depends on
[Plan 223](223-register-the-mapped-consumer-surface-contract-in-candidate-language-5.md) and on the
completed MP-34. Plan 223 defines `QueuePayloadType`, the candidate colon syntax, exact field
locations, and workqueue `UseSite` roots. Start by reading its landed types and updating this plan
if names differ. Completion removes only `MappedQueueLoweringPending`; the read-model pending gate
remains for Plan 225.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` currently emits `Queue.hs` with a record field type selected
by a local three-row `hsType` function and encodes/decodes each field directly with Aeson `.=` and
`.:`. `QueueCodec.hs` wraps it in `Keiro.PGMQ.Codec.keiroJobCodec` using a `Codec` whose
`schemaVersion = 1` and `upcasters = []`. The workqueue payload is therefore persisted data even
though it is not aggregate event history.

The same large scaffold module already lowers mapped aggregate event fields. Structural references
use generated shape modules plus the declared total `StructuralBinding`; opaque references use
consumer `ToJSON`/`FromJSON`. Recursive optional/list/map lowering and deterministic Haskell imports
are interleaved with event-specific code. This plan extracts a small internal **mapped codec plan**:
a pure composition of Plan 223's consumer Haskell type/import/dependency plan with an encode
expression, parse expression, and structural/opaque authority. It is not a new runtime codec or
schema authority.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` currently compares workqueue field names, wire keys, and scalar
type names directly. `Coverage.unsupportedInventory` currently labels queue payloads unsupported.
`Harness` and the compiled `keiro-dsl-conformance-queue` suite prove existing scalar round trips.
The scaffold manifest/record already obtains mapped consumer packages and modules from
`MappedConsumer.consumerPlan`, but it currently inventories every declaration service-wide; use
MP-34's local consumer model for queue-specific imports and reports.

[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
governs structural/opaque authority, total bindings, and finite conformance evidence.
[ADR 0013](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
requires queue coverage to be a separate named surface. [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
records the version-1 queue envelope and drain rule. [ADR 0021](../adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md)
reinforces that a logical selector and wire key are separate identities. No cross-repository ADR
governs Keiro's generated queue payload codec.


## Plan of Work

Milestone 1 extracts reusable codec lowering from `Scaffold.hs` into a focused internal module
such as `keiro-dsl/src/Keiro/Dsl/MappedCodecPlan.hs`, exposed only if tests or another package
genuinely need it. Compose Plan 223's `ConsumerTypePlan` with Aeson encode/parse expressions and
the structural/opaque authority. Do not repeat the type/import fold. It must reuse
`HaskellImport` and generated-name validation, not concatenate imports or aliases locally.

Migrate existing aggregate event codec emission to consume this plan without changing generated
bytes. Add golden/unit tests over primitives, nested structural declarations, opaque references,
optional/list/map expressions, and import collisions. Milestone 1 is accepted only when the full
existing corpus remains byte-clean.

Milestone 2 updates `emitWorkqueueGen` to lower `TypedQueueExpression`. Generate the domain-facing
consumer type in the payload record. Structural encoding calls the generated declaration codec
plan through its total binding; opaque encoding uses the consumer JSON boundary and retains codec
identity/version in provenance. Nested containers recurse through the same plan. Existing legacy
fields stay on their old fast path and produce byte-identical modules.

Decode every queue object field with `.:`, then run the resolved mapped parser. A missing field is
an error even when its value type is optional; a present JSON null follows the mapped expression's
null rules. Reject non-injective nullable expressions at `check` through the existing graph rules.
Update group-key validation so `via raw` accepts only legacy text or a direct typed `TText`, not a
mapped reference whose encoded representation happens to be text.

Milestone 3 makes queue compatibility explicit. Extend `MappedDiff`/`Diff` so a changed mapped leaf
reached through `RootWorkqueueField` produces a queue payload finding with queued-message history,
producer build, consumer build, and deploy-workers-first/drain guidance. It must not set private
event history, replay, snapshot, or read-model query flags. Preserve the existing direct field/wire
diff codes and deduplicate a mapped finding that reaches the same field recursively.

Replace queue's unsupported coverage row with named structural, opaque, and explicit `Json`
boundaries. Do not merge these counts with private events or snapshots. Extend scaffold generation
roles, dependency manifests, and MP-34 semantic reports so a mapped queue field imports and reports
only its transitive closure.

Milestone 4 expands `keiro-dsl-conformance-queue` or adds one candidate-specific compiled suite.
Use a structural record containing an optional nested record and an opaque field. Pin current
envelope JSON bytes, roundtrip domain values, missing/null distinction, unknown-field policy,
consumer imports, and mapping provenance. A restoring mutation must transpose a binding and fail
service structural conformance; a queue-specific mutation must remove a field encoder or decoder
and fail queue conformance. Remove the queue pending diagnostic only after this path is green.


## Concrete Steps

Work from the repository root and refresh the local package evidence:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori registry show shinzui/keiro --full
mori registry dependents shinzui/keiro --packages --json
rg -n 'emitWorkqueueGen|emitQueueCodec|codecMappedDeclarations|encodeMapped|parseMapped|WqPayload' \
  keiro-dsl/src keiro-dsl/test
```

Run focused lowering, queue, diff, and coverage tests:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='mapped codec plan'
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='mapped workqueue'
cabal test keiro-dsl:keiro-dsl-conformance-queue
bash keiro-dsl/test/diff-test.sh
```

Before closure, run:

```bash
cabal build all
cabal test keiro-dsl:tests
cabal run -v0 keiro-dsl-corpus-regen -- check
scripts/check-conformance-corpus.sh
just check-adr
git diff --check
git status --short
```

Milestone 1 expects a byte-clean corpus. The later candidate fixture may add new generated files,
but Plan 228 owns the complete committed refresh; keep intermediate fixture updates focused.


## Validation and Acceptance

A language-5 field `job -> "job" : JobPayload` generates a payload record field of the declared
consumer Haskell type. Its JSON uses the mapped declaration's wire keys, defaults, unknown-field
policy, nested shapes, and binding. A structural fixture and an opaque fixture both roundtrip;
coverage labels them accurately rather than calling both structural.

Every queue field remains required. Removing `"job"` fails decoding, while a present null succeeds
only when the exact mapped expression admits it. An unambiguous nested change reports the complete
queue use path and only the queue-history/build compatibility surfaces. Generated queue schema
version remains 1 and upcasters remain empty; the report explicitly requires draining or an
application-supplied transitional codec before incompatible deployment.

An existing scalar workqueue produces byte-identical `Queue.hs`, `QueueCodec.hs`, policy modules,
reports, and ledger rows. Aggregate event modules remain byte-identical after adopting the shared
codec plan. Adding an unrelated mapped declaration or aggregate does not change the queue module.

Binding and queue-codec restoring mutations fail the correct service/queue gates and restore exact
bytes. Focused/full DSL tests, compiled queue conformance, diff tests, corpus policy, ADR validation,
and diff hygiene pass. `MappedQueueLoweringPending` is no longer emitted; the read-model pending
diagnostic remains until Plan 225.


## Idempotence and Recovery

Codec-plan derivation and generation are pure and deterministic. Scaffold preflight resolves every
mapped root and import before creating output paths. A failure leaves queue modules and ledgers
unchanged. Repeating a successful scaffold produces identical bytes.

Do not hand-edit generated queue modules or bump the emitted schema version to silence a failing
golden. If a historical-byte test fails, determine whether the old scalar path drifted or the new
candidate fixture intentionally differs. Preserve queued-job evidence; no command in this plan
drains a real queue or writes a downstream service.


## Interfaces and Dependencies

No new dependency. Use `aeson`, `containers`, and existing Keiro codec types. The internal shared
interface must be equivalent to:

```haskell
data MappedCodecPlan = MappedCodecPlan
  { consumerType :: !ConsumerTypePlan
  , encode :: ValueExpr -> ValueExpr
  , parse :: ValueExpr -> ParserExpr
  , authority :: !MappedAuthorityMode
  }

planMappedCodec :: TypeGraph -> ResolvedTypeExpr -> Either MappedCodecPlanError MappedCodecPlan
```

Names should match landed occurrence/import types. The plan must remain a pure generation
description and may not contain runtime closures or a second schema. Queue compatibility must add
an explicit persisted surface, conceptually:

```haskell
data MappedPersistedSurface
  = PrivateEventHistory
  | SnapshotCache
  | WorkqueueHistory Name
```

Do not encode workqueue history as an aggregate event or snapshot flag for convenience.
