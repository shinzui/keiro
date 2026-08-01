# Choosing `keiro-dsl`: Benefits, Costs, and Fit

`keiro-dsl` is a build-time toolchain for event-sourced Keiro services. A checked
`.keiro` specification produces Haskell modules, compatibility reports, and
consumer-compiled conformance tests; production still runs ordinary Keiro and
Keiki values rather than interpreting the specification.

This guide helps decide whether that additional authoring layer is worthwhile.
It assumes the completed behavior described by
[MasterPlan 27](../masterplans/27-repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions.md):
contextual language parsing, version-aware semantic planning, one generated
owner for shared nominals, exact nominal equality, generated
`fields(Command)` outputs, complete finite behavior obligations, and
evolution-safe ID-prefix enforcement.


## Short recommendation

Use `keiro-dsl` when persisted history, rolling upgrades, shared domain types,
or repeatable compatibility evidence matter enough to justify a second source
language and generated artifacts. It is especially strong when several
aggregates or integration nodes must agree on one service contract.

Prefer a hand-written Keiro service when the model is small or short-lived,
most behavior needs arbitrary Haskell, or the team is prepared to author and
maintain equivalent evolution and replay tests itself. Hand-written does not
mean unchecked: construct streams through `ValidatedEventStream` and retain the
runtime replay-safety gates.

For many services the best fit is hybrid. Let the DSL own everything it can
express exactly, then use the narrowest available escape hatch for behavior or
values that truly need application code. Reaching for one Hole or opaque
mapping does not turn the aggregate—or the rest of the service—into a
hand-written implementation.


## At a glance

| Concern | With `keiro-dsl` | Hand-written Keiro |
|---|---|---|
| Service contract | One checked graph drives types, codecs, behavior, fingerprints, and reports | Haskell modules and tests collectively define the contract |
| Evolution | Spec diff classifies six compatibility surfaces and can emit migration evidence | The application must design and maintain equivalent comparisons |
| Aggregate behavior | Supported versioned expressions and `fields(Command)` mappings are generated-owned | All predicates, updates, and event construction are application-owned |
| Shared nominals | One service-level generated owner; exact same-declaration ID/enum equality | The application owns type placement, instances, and symbolic projections |
| Flexibility | Limited to constructs the language can check and lower honestly | Full Haskell and Keiki API surface |
| Escape hatches | Hand-own one transition, output, codec, upcaster, resolver, or worker body while retaining the surrounding contract | Hand-own the entire affected surface |
| Ongoing cost | Specification, generated modules, bindings, fixtures, witnesses, and language upgrades | More hand-written implementation and compatibility tests |
| Runtime safety | Uses the same `ValidatedEventStream` boundary as hand-written code | Available when the application uses the validated boundary |


## Escape hatches: keep the contract, hand-own the exception

The DSL's ownership boundary is per concern, not per service. Generated and
hand-owned code are designed to coexist: generated modules may be replaced on
every scaffold, while Hole and binding modules are created once and never
overwritten. The scaffold and conformance reports keep the hand-owned boundary
visible instead of pretending it was generated or forcing the service to leave
the DSL.

| When the DSL cannot own... | Use... | The DSL still owns... | Application code owns... |
|---|---|---|---|
| A transition predicate or register update | `implementation hole` | Command matching, live/replay mode, event kinds, target state, type checking, fold-fingerprint composition, and the behavior obligation | The transition function, its `FoldVersion`, and concrete witnesses |
| How explicit event fields are calculated | The generated create-once output hook | The event type, wire codec, transition envelope, and a named output obligation | The value transformation and its tests |
| An existing Haskell domain type | A nominal or structural binding skeleton | Canonical identity, representation or wire policy, generated codecs, fingerprints, and binding-law assertions | Total conversions, fixtures, and required initial values |
| A refined value or consumer-authoritative JSON codec | `mapped opaque` | A named and versioned boundary, boundary round trips, coverage inventory, and diff visibility | `ToJSON`/`FromJSON` behavior and compatibility below the boundary |
| An event-version conversion | An upcaster Hole | The contiguous version chain, codec dispatch, compatibility classification, and golden/replay checks | The conversion body and representative historical fixtures |
| Read-model queries or event application | `ReadModelHoles` | Stable read-model identity, table/schema facts, consistency/feed configuration, and generated runtime wiring | Query and projection SQL/effects |
| Dynamic router targets or callbacks | A typed resolver in `RouterHoles` | Router identity, target command contract, deterministic dispatch identity, and worker policy | Target resolution and declared callbacks |
| Process-manager reactions and timer behavior | `ProcessHoles` | Process/timer identity, categories, retry policy, and generated wiring | Reaction, deadline, and fire-command bodies |
| A legacy version-1 aggregate transducer | The preserved whole-transducer Hole | Spec-visible types, codecs, evolution reports, and runtime validation | The full transducer and its manual fold-version discipline |

At the broadest boundary, DSL-generated and hand-written `EventStream` values
can live in the same application and use the same Keiro runtime. A brownfield
service can move one persisted aggregate or integration boundary under the DSL
without first translating every stream, worker, or application module. The DSL
keeps its guarantees for the graph it owns; relationships to omitted
hand-written nodes remain application-owned and must not be presented as
spec-checked.

For example, one unusual transition can remain hand-written without giving up
the generated aggregate around it:

```text
Reviewed -- Close -->
  implementation hole
  emit ClosedEvent
  goto Closed
```

That Hole supplies the predicate and updates. Generated code still owns the
typed command/event envelope, transition mode, target, codecs, fingerprints,
and conformance requirement. A neighboring transition whose guard and writes
are expressible remains fully generated-owned.

The same idea applies to types. A structural binding keeps an application's
existing Haskell type while letting the specification own its persisted wire
shape. If that would be dishonest—because construction can fail, normalize, or
depend on a vendor codec—`mapped opaque` delegates that one boundary to the
application. Other fields and mappings remain structural and fully checked.

These escape hatches deliberately reduce only the affected guarantee. A
generated transition can be symbolically verified; a Hole-owned transition is
reported as finitely witnessed and potentially unverified. A structural
mapping receives nested wire-policy and binding-law checks; an opaque mapping
receives boundary round trips and remains named in coverage reports. The
default conformance gate permits honest unverified rows, while
`--fail-on-unverified`, `--fail-on-opaque`, and
`--fail-on-opaque-increase` let a service opt into stricter local policy.

There is one unavoidable responsibility: `diff` cannot inspect arbitrary
Haskell bodies. Change a Hole's behavior only with its `FoldVersion`, update
its witnesses, and review replay impact. Change an opaque codec or upcaster
only with the declared version and historical evidence. The escape hatch keeps
the rest of the DSL's evidence; it cannot manufacture evidence about code it
does not understand.

See [Generated and hand-owned files](../user/typed-spec-toolchain.md#generated-and-hand-owned-files)
for the concrete scaffold modules and authoring rules.


## Benefits

### One contract drives several safety layers

The specification is checked before scaffolding and then feeds generation,
fold fingerprints, compatibility diffing, replay-impact analysis, scaffold
records, and conformance tests. This removes a common failure mode in which a
schema document, codec, state machine, and migration checklist describe
slightly different systems.

Language selection is now grammar-contextual: a field named `language`, a wire
key, comment, or string cannot accidentally select a language version or trip a
feature gate. The selected effective language contract is retained through
checking, generation, fingerprints, replay analysis, and diffing, so a
versioned runtime rule cannot disappear after parsing.

### Generated behavior is authoritative where the DSL is expressive

Versioned scalar guards and writes compile into the Keiki transducer that runs
in production. An event declared as `fields(Command)` is constructed directly
from the checked, total, type-identical mapping; a stale create-once identity
callback can no longer override it. This is valuable because forward execution,
persisted bytes, and replay all derive from the same checked behavior.

The DSL also inventories every finite behavior obligation it can soundly
derive: reachable live transitions, state/command rejection cells, and
replay-only transitions. The consumer-compiled harness executes typed witnesses
through the generated codec and transducer, attributes the exact Keiki edge,
and compares the final vertex and every register after replay. Missing, stale,
duplicate, pending, or false witnesses fail the completeness gate.

### Nominal types are service-wide and solver-visible

A generated ID or enum has one context-level Haskell owner, even when several
workspace members and aggregates use it. Aggregate rings import only their
transitive nominal uses, and two aggregates can exchange the same value without
conversion. Moving or reordering workspace members does not change that type
identity.

Generated and consumer-bound IDs and enums can participate in exact
same-declaration equality in aggregate expressions. The checker still rejects
cross-ID, cross-enum, and nominal-to-`Text` comparisons. Finite enum domains and
validated textual ID domains reach symbolic verification, avoiding the false
confidence of treating an unrestricted `Text` projection as an exact nominal
domain.

### ID prefixes become an evolution contract

Under the enforcing language contract, a generated ID prefix is not merely
documentation. Safe construction and current public decoding reject invalid
prefixes, suffixes, separators, normalization, and lengths. The raw
representation is hidden, while historical replay has an explicit internal
legacy path so tightening new admission does not make old persisted events
unreadable.

The same checked ID-domain contract feeds runtime validation, symbolic
equality, fingerprints, scaffold records, diff, and replay impact. A prefix or
domain change is therefore visible at the command, event, snapshot, replay,
and public-codec surfaces it actually affects.

### Workspaces scale the contract without merging source files

A `.keiro-workspace` composes separately owned specifications under one service
identity. Parsing, checking, scaffolding, behavior inventory, and diffing are
deterministic in canonical member order. Shared declarations have one owner,
generated writes are planned before any file is touched, and member errors or
path collisions stop the whole scaffold before partial output.

### Compatibility evidence is built into the authoring loop

`diff` distinguishes private history, old binaries reading new events,
snapshot hydration, public consumers, persisted identity, and consumer builds.
Generated harnesses add current codec round trips, historical goldens,
forward-versus-replay checks, mapping laws, and projection evidence. This is
more useful than one undifferentiated “compatible” label and cheaper than
reconstructing the same matrix for every service.


## Costs and limitations

### There is another language and toolchain to operate

The team must review `.keiro` syntax, generated Haskell, scaffold manifests,
Cabal module/dependency updates, and generated test targets. CI should run
`check`, freshness or re-scaffold verification, the compiled harness, and
`diff` when persisted contracts change. For a tiny service, that machinery can
cost more than it saves.

Language contracts are deliberately frozen. Adopting a successor contract is
an explicit migration rather than a silent upgrade, and older sources retain
their released semantics. That protects history but adds fleet coordination
when many specifications move together.

### The DSL is intentionally less expressive than Haskell

Only behavior that can be typed, lowered, and analyzed honestly belongs in the
generated path. Arbitrary nominal ordering or arithmetic, refined mappings,
unbounded collection expressions, and arbitrary Keiki composition remain
outside that surface. Nominal IDs and enums gain exact equality, not a general
set of operations.

Unsupported transition logic uses an explicit `implementation hole` rather
than forcing the whole aggregate out of the DSL. Explicit event-field
transformations retain an output hook, and upcaster bodies remain
application-owned. The surrounding types, codecs, topology, version graph,
diffs, and conformance inventory remain generated or checked. A service
dominated by these exceptions receives less benefit, but a few isolated
exceptions are the intended hybrid use case.

### Consumer-owned types require evidence and ceremony

Keeping existing Haskell domain types means declaring stable canonical
identity, binding and codec versions, total nominal or structural bindings,
fixture cases, and register initial values where required. Structural mappings
must state wire keys, tags, defaults, optionality, and unknown-field policy.
Opaque mappings are available, but the DSL correctly makes weaker claims about
them.

This work is valuable when the boundary is durable. It can feel excessive for
an internal value that never reaches an event, snapshot, command, or public
contract.

### Behavior conformance is finite evidence, not universal proof

The harness accounts for every derivable obligation, but each witness is still
one concrete history and command. Hole-owned behavior, unknown guard coverage,
and one-way projections remain visibly unverified. The stricter
`--fail-on-unverified` policy is opt-in because some services intentionally
retain those boundaries.

The benefit therefore depends on maintaining meaningful witnesses. Filling
rows with unrepresentative data can satisfy bookkeeping without exploring the
domain cases the team actually worries about.

### Generated ownership creates migration work

Generated files may be overwritten; create-once Hole, binding, and behavior
files are preserved. When generation topology improves—such as moving shared
IDs and enums into one service-level module—hand-owned modules may need import
changes and old generated paths become stale. The scaffolder reports but does
not delete those paths, so cleanup remains a deliberate application change.

The ID-domain repair similarly introduces separate current/public and legacy
replay paths. That distinction is necessary for safe evolution, but it is more
complex than one permissive `FromJSON` instance.

### The DSL does not replace runtime validation or operations

Generated services and hand-written services use the same Keiro runtime.
Applications must still construct streams through `mkEventStream` or
`mkEventStreamOrThrow`, run replay audits where required, monitor typed command
and hydration failures, and operate the database-backed workers. A clean spec
cannot compensate for bypassing `ValidatedEventStream` or ignoring production
telemetry.


## Good and poor fits

`keiro-dsl` is a strong fit when one or more of these are true:

- persisted events or snapshots must survive several application versions;
- rolling deployments need directional compatibility evidence;
- multiple aggregates share IDs, enums, mapped types, or service-wide policy;
- generated command/event/fold behavior covers most transitions;
- the team values machine-readable change reports and replay evidence; or
- workspaces, integrations, queues, workflows, and read models should be
  reviewed as one contract.

It is a weaker fit when most of these are true:

- the service is a disposable prototype or has no durable history;
- one small stream has straightforward, well-tested hand-written code;
- most transitions need bespoke effects or Keiki constructs outside the DSL;
- consumer mappings would be predominantly opaque;
- the team will not keep fixtures, behavior witnesses, and generated artifacts
  fresh; or
- a separate source language is a larger maintenance burden than the desired
  compatibility guarantees.


## Recommended operating model

For a new durable service, start with the newest applicable language contract,
keep generated ownership as the default, and choose escape hatches from
narrowest to broadest: a consumer binding, an explicit event-output hook, one
transition Hole, a node-specific Hole module, then an opaque mapping. Use
structural mappings when the spec can honestly own the persisted wire shape;
use opaque mappings when the consumer codec must remain authoritative. Keep an
entire area hand-written only when none of the narrower seams preserves useful
DSL ownership.

For an existing hand-written service, migrate incrementally. Capture historical
payloads before changing codecs, describe one aggregate boundary, compare the
generated and historical behavior, and keep the hand-written stream validated
during the transition. A service does not need to migrate every node at once to
benefit from a checked persisted contract.

In CI, treat `check`, generated-file freshness, the consumer-compiled harness,
and the relevant `diff` gates as one workflow. Review unverified rows rather
than hiding them, and bump every hand-owned `FoldVersion` when Hole behavior
changes.


## Bottom line

After MP-27, parser collisions, duplicate workspace nominal types, opaque
ID/enum equality, overridable `fields(Command)` copies, and unenforced current
ID prefixes are no longer reasons to avoid `keiro-dsl`. The remaining tradeoff
is the intended one: more explicit contracts, generated ownership, and
compatibility evidence in exchange for less unrestricted authoring and more
build-time discipline. The tradeoff is granular: an escape hatch gives up
analysis only at its declared boundary, not across the entire service.

See [Typed Specifications With `keiro-dsl`](../user/typed-spec-toolchain.md) for
the complete authoring workflow and
[The Guarantee Ledger](dsl-guarantees-and-hand-written-services.md) for the
precise guarantees retained by hand-written services.
