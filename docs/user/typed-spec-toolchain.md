# Typed Specifications With `keiro-dsl`

`keiro-dsl` turns a checked `.keiro` service specification into generated
Haskell modules, create-once typed holes and consumer binding skeletons,
conformance harnesses, and persistence-aware evolution reports. It is a
build-time toolchain, not a runtime interpreter: generated code uses the same
public Keiro APIs as hand-written services.

## Supported node families

A specification starts with `context <name>` and may declare shared ids, enums,
rules, and consumer-owned mapped types. The current grammar covers:

- aggregates, event versions/upcasters, projections, and snapshot policies;
- process managers, timers, worker rejection/poison policies, and target inline
  projections;
- effectful routers backed by a read model or a typed resolver hole;
- integration contracts, inbox intake, outbox emits, and publishers;
- PGMQ work queues, ordering/group keys, provisioning, retry/DLQ policy, and
  read-model-driven dispatch (see [Work Queues](work-queues.md));
- first-class read models, schemas, columns, consistency, scope, and feed;
- durable workflows, named operations, patches, and continue-as-new; and
- structural and opaque mappings from private aggregate payloads to existing
  consumer-owned Haskell types.

Use `keiro-dsl new <kind>` to print a minimal valid node skeleton. The CLI
accepts `aggregate`, `process`, `router`, `contract`, `intake`, `emit`,
`publisher`, `workqueue`, `dispatch`, `workflow`, and `operation`.

## Consumer-owned mapped types

A structural mapping keeps the application type while making the `.keiro`
declaration the single authority for its private event wire shape. The
declaration names the consumer type, a total `StructuralBinding`, a stable
binding version and canonical type identity, deterministic fixture cases, and
the complete JSON policy:

```text
mapped structural record ArtifactInfo {
  haskell package=my-service module=MyService.Domain type=ArtifactInfo
  binding = "MyService.KeiroBindings.artifactInfoBinding"
  binding-version = "1"
  canonical-type = "my-service.ArtifactInfo.v1"
  fixtures = "MyService.KeiroBindings.artifactInfoCases"
  initial = "MyService.KeiroBindings.emptyArtifactInfo"
  wire object constructor=ArtifactInfo unknown-fields=reject {
    artifactKey  as "artifact_key"  : Text          required
    artifactHash as "artifact_hash" : Optional Text optional on-missing=null
    active       as "active"        : Bool          optional on-missing=false
  }
}
```

Structural records, string enums, and tagged unions may contain supported
scalars, `Optional`, `List`, text-keyed `Map` values, nested mapped types, and
explicit `Json` leaves. Optional fields require an `on-missing` policy;
records and tagged unions require an `unknown-fields=reject|ignore` policy.
The checker rejects recursive mappings, ambiguous names, ill-typed defaults,
and non-injective shapes such as `Optional Json` where JSON `null` cannot
distinguish the outer and inner cases.

`StructuralBinding domain shape` is deliberately only a total conversion in
both directions. It cannot supply wire keys, tags, defaults, or validation
that the declaration cannot see. Generated harnesses exercise both binding
laws and the declared fixture branches, but those finite cases remain evidence
rather than a proof for every possible consumer value.

Use an opaque mapping when the consumer codec must remain authoritative or a
total structural binding cannot honestly be written:

```text
mapped opaque VendorGeometry {
  haskell package=my-service module=MyService.Domain type=Geometry
  codec = "vendor.geometry.json"
  version = "3"
  fixtures = "MyService.KeiroBindings.geometryCases"
}
```

Keiro delegates to the consumer's `ToJSON`/`FromJSON` instances only at that
declared boundary and makes no nested compatibility claim below it. Passing
fixtures or a historical comparison never upgrades an opaque declaration to a
structural guarantee.

The mapped graph currently covers private aggregate event payloads and mapped
registers. Public contracts and queue payloads retain their separately owned
grammars and appear as unsupported or not applicable in mapped-coverage
reports. Mapped register snapshots remain a consumer-JSON cache boundary; the
mapping fingerprint invalidates the cache but the generated private-event
codec is not the snapshot codec.

## Authoring loop

```bash
cabal run keiro-dsl -- new aggregate > service.keiro
cabal run keiro-dsl -- parse service.keiro
cabal run keiro-dsl -- check service.keiro --explain-bindings
cabal run keiro-dsl -- scaffold service.keiro --out src
cabal run keiro-dsl -- diff service.keiro --since HEAD^ --explain
```

- `parse` pretty-prints the parsed specification and catches notation errors.
- `check` resolves cross-node and mapped-type references and rejects unsafe or
  incomplete policy. Add `--emit` to print the normalized spec, or
  `--explain-bindings` to list every required binding, fixture, and
  register-initial symbol with its expected signature and owner.
- `scaffold` validates before writing, emits the generated layer and create-once
  hole/binding modules, then reports every created, overwritten, skipped, stale,
  or newly required path and obligation.
- `diff` loads the earlier spec from Git and reports a six-surface compatibility
  vector for each finding. `--explain` adds containing paths, failing
  directions, rollout constraints, and remedies; `--report-out FILE` writes the
  stable `keiro-dsl/diff-report/1` JSON report.

Run commands from the repository containing the spec because `diff` resolves
`--since` with `git show`.

## Generated and hand-owned files

Generated modules carry an `-- @generated` banner and may be replaced on every
scaffold. Hole and binding-skeleton modules are create-once: a later run skips
them so filled domain logic is preserved. Never edit generated modules; change
the spec and scaffold again.

For structural mappings, generated files include one private shape leaf module
per declaration, aggregate codecs derived from the declared wire policy, and a
`StructuralProjections` facade containing eligible scalar `FieldWitness`
values. Hand-written Holes may use those witnesses with Keiki's `regProj` and
`inpProj`; the DSL does not claim nested field-path syntax of its own.

The scaffolder plans the complete write before touching disk. It refuses
invalid specs, module-path/case-fold collisions, scaffold-unsafe identifiers,
unsupported lowering, an import cycle between consumer modules and the
generated namespace, or an existing generated path without the expected
banner. `--force-generated-overwrite` bypasses only the missing-banner check
and should be used only after confirming the file is disposable.

Each successful run writes a manifest containing Cabal `other-modules`,
dependencies, and consumer package/module requirements, plus a scaffold record
containing generated paths and mapping provenance. A later run reports mapping
drift and obligations newly required by a changed structural declaration but
never edits the hand-owned binding module. When a spec emits fewer modules, the
report marks old paths as stale but never deletes them.

## Binding authoring and conformance

The first scaffold creates a binding skeleton in the module named by each
structural declaration. Fill the semantic construction/destruction holes and
the `FixtureCases` value; do not copy wire keys, tags, presence, nullability, or
defaults into the binding.

When the consumer and generated shape have identical constructor names and
order, selector names and order, arity, and field types, the binding may be:

```haskell
import Keiro.Codec.Structural.Generic (genericStructuralBinding)

artifactInfoBinding :: StructuralBinding ArtifactInfo ArtifactInfoShape
artifactInfoBinding = genericStructuralBinding
```

Any mismatch fails at compile time and directs the author back to the explicit
skeleton. There is no prefix stripping, coercion, or positional guess.

The generated aggregate harness validates the filled transducer and includes
current payload round trips, historical upcaster goldens, both structural
binding laws, missing/default/null/unknown-field wire-policy cases, enum/union
and optional fixture coverage, generated projection-witness agreement, and
forward-versus-replay equality over the final vertex and every register. An
opaque mapping receives boundary round trips only; the harness makes no nested
claim about its JSON.

For the full binding workflow, see
[Brownfield Migration And Transducer Modeling](../guides/brownfield-migration-and-transducer-modeling.md#author-structural-bindings-from-create-once-skeletons).

## Module placement

The default layout puts generated code under `Generated.<Context>...` and holes
under `<Context>...`. A spec may choose a namespace and collocated layout:

```text
context hospital-capacity
module Acme.Services
layout collocated
```

The equivalent CLI flags are `--module-root Acme.Services --collocate`; CLI
values override the spec. Collocation places generated modules below
`Acme.Services.<Context>.<Node>.Generated` while keeping holes beside them in
the domain namespace.

## Important checked contracts

The checker owns the cross-node and persistence contracts that are dangerous to
reconstruct from prose:

- Aggregate status maps are exact and total unless explicitly marked
  `partial`; event evolution needs contiguous upcasters; snapshot policies need
  a valid codec version and captured live shape hash.
- Structural mappings require qualified consumer/binding/fixture identities,
  non-empty canonical and binding versions, total/injective wire shapes, and an
  initial value whenever a mapped register needs one. Opaque mappings require
  explicit codec identity and version.
- Process and router references resolve to declared aggregates, commands, read
  models, and fields. `CommandAmbiguous` follows the declared rejection policy
  and may not be treated as a benign timer outcome.
- Inbox and work-queue disposition tables are complete. Duplicates acknowledge,
  transient store failures retry, poison decode failures dead-letter, and
  previously failed inbox rows do not become an unbounded retry loop.
- FIFO queues require a group key; unordered queues reject one. Captured
  physical queue, DLQ, and table names must match the logical-name derivation.
- Strong read models use a subscription feed and may declare category scope;
  inline models must be owned by a matching aggregate projection. Captured
  shape changes require a version bump.
- Workflow step/patch labels are unique, signals match awaits, field references
  resolve, and `continueAsNew` is terminal.

Warnings remain visible but do not fail `check`; errors do. Diagnostics include
the source row so the specification, rather than generated Haskell, is the
place to fix the contract.

## Evolution and structural coverage

`diff` keeps the `ADDITIVE`, `WARNING`, and `BREAKING` headline, but derives it
from a compatibility vector over `private-history-read`,
`old-binary-read-new-events`, `snapshot-hydration`, `public-consumer`,
`persisted-identity`, and `consumer-build`. The default gate preserves the
previous blocking policy and leaves the rolling-deployment direction visible
without blocking it; repeat `--gate SURFACE` to opt into additional surfaces.

Mapped declarations are classified recursively at every containing command,
event, and register path. A binding symbol/version change cannot be inspected
from spec text, so its remedy points to the binding-law, codec, fixture, and
historical-comparison evidence instead of claiming compatibility.

Coverage is a separate, reporting-first inventory:

```bash
cabal run keiro-dsl -- check service.keiro \
  --coverage-report build/keiro-coverage.json

cabal run keiro-dsl -- diff service.keiro --since HEAD^ \
  --coverage-report build/keiro-coverage-diff.json
```

It names structural, opaque, and explicit-`Json` private-event boundaries and
consumer-JSON register cache boundaries; it does not manufacture one aggregate
percentage. Add `--fail-on-opaque` to `check` or
`--fail-on-opaque-increase` to `diff` only when that named-root policy is an
intentional operator gate.

## Historical codec comparison

For a brownfield migration, capture historical JSON first. Scaffold an explicit
non-production comparison module for one persisted structural mapped type:

```bash
cabal run keiro-dsl -- scaffold service.keiro --out src \
  --codec-comparison ArtifactInfo \
  --comparison-out src/Generated/MyService/Structural/CodecCompare/ArtifactInfo.hs
```

Compile that module in a consumer-owned test or executable and pass an explicit
`HistoricalCodec a`; the `keiro-dsl` process cannot and does not discover old
Haskell instances. The report compares RFC 8785-canonical JSON meaning, decode
outcomes, and historical/typed branch coverage. Every observation is either
parity or explicit version/upcaster work. A passing report is finite migration
evidence only: after cutover the generated structural codec remains the sole
wire authority and the historical codec is never a runtime fallback.

See the complete
[shadow-comparison procedure](../guides/brownfield-migration-and-transducer-modeling.md#shadow-comparison-of-old-and-new-codecs)
and [Evolution And Replayability](../guides/evolution-and-replayability.md) for
deployment and real-log replay gates.

The executable fixture and conformance index is
[Keiro DSL Corpus](../corpus/keiro-dsl-corpus.md). It links valid and negative
specs, generated runtime modules, full hand-filled examples, mutation tests,
and cold-start conformance packages.
