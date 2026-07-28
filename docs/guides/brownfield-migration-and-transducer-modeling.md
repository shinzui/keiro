# Brownfield Migration And Transducer Modeling

This guide is for a team moving an existing service onto Keiro when production
history, wire shapes, and downstream readers already exist. It assumes the team
has chosen Keiro and now needs the practical *how*: first model the domain as a
Keiki transducer, then migrate historical bytes without rewriting them or
creating two codec authorities. If you are still evaluating the architectural
trade, read [Adopting Keiro From tan-event-source](adopting-keiro-from-tan-event-source.md)
first; that guide is the *why*, while this guide is the migration playbook.

The doctrine here translates sections 4, 5, 6, and 12 of
[`docs/research/14-structural-consumer-type-tradeoffs.md`](../research/14-structural-consumer-type-tradeoffs.md)
and the modeling constraints in
[`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`](../improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md).
Those documents motivate the constraints; the runtime, the accepted ADRs, and
the code that executes remain authoritative. The structural/opaque declaration
grammar, total consumer bindings, generated private-event codecs, and migration
evidence tooling described below are now part of `keiro-dsl`.

The migration has two halves. Part A turns domain choices into a transducer
whose forward execution and replay agree. Part B starts from genuine historical
wire values and moves the service through goldens, shadow comparison, explicit
versions, runtime validation, a full replay audit, and a coordinated cutover.


## Part A: Modeling the domain as a transducer

A Keiki transducer has one edge set for both live command execution and replay.
An edge checks a guard, emits durable events, writes registers, and moves to a
control-state vertex. During replay, Keiki inverts each stored event back to the
command that produced it, checks the same guard, and applies the same writes.
Every modeling choice is therefore also a replay choice: information that
affects state must be recoverable from the durable output, and decision logic
must remain true for the history it originally admitted.

[The Guarantee Ledger](dsl-guarantees-and-hand-written-services.md) explains
the complete layered gate model. In short, the compiler, validated stream
construction, replay audit, and typed runtime failures protect both hand-written
and DSL-generated services. `keiro-dsl check`, cross-version `diff`, and the
generated conformance harness add evidence that only a checked `.keiro` spec can
provide. No one layer proves every property.


### Decision scalars versus payload data

Put values that select behavior into explicit, solver-visible scalar fields.
Identity, revision, lifecycle, quantities, and content hashes are typical
decision state. Carry a rich payload beside those scalars when events,
registers, or projections need the whole value. Keiki can then reason about the
decision while copying the payload without pretending to understand every
nested field.

For example, prefer a command shape and guard like this:

```text
command ObserveDoc {
  key         : Text
  contentHash : Text
  doc         : DocInfo
}

when register.contentHash != command.contentHash
emit DocObserved { doc = command.doc, contentHash = command.contentHash }
```

The edge decides from `contentHash`; `doc` remains payload data. If the next
rule repeatedly needs another nested fact, promote that fact to a scalar rather
than hiding a Haskell getter inside syntax that looks checked.

The worked order aggregate follows the scalar-first shape. Its command payload
is declared in
[`Jitsurei.Domain`](../../jitsurei/src/Jitsurei/Domain.hs), and
[`orderTransducer`](../../jitsurei/src/Jitsurei/OrderStream.hs) emits those
fields directly:

```haskell
data PlaceOrderData = PlaceOrderData
  { orderId :: !OrderId
  , sku :: !Sku
  , quantity :: !Quantity
  }
```

Keiki 0.4 also has typed `FieldProjection` witnesses consumed through
`regProj` and `inpProj`. Keiro generates those witnesses from a consumer-owned
structural mapping through the API landed by
[`docs/plans/150`](../plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md).
A hand-written Holes module may use the generated facade for a genuine scalar
field. That facility is deliberately narrow: projections are guard-only,
start from a direct register or matched-input field, and return a result in
Keiki's curated symbolic registry. It does not create checked nested `.keiro`
paths, because the current scaffolder renders guard intent as comments rather
than lowering that text into the running transducer.

The negative rule is as important as the convenience. If a predicate cannot be
represented by Keiki's symbolic language, call it opaque, keep the
`OpaqueGuard` warning and audit obligation visible, and do not let it satisfy a
deployment gate that requires checked guards.


### Register design and head invertibility

A register is a typed state slot carried alongside the control-state vertex.
Register design is constrained by replay: every command field read by an edge
must be recoverable from the *first* event emitted by that edge. Streaming
replay sees the head event first and must reconstruct the command before it can
re-check the guard or process later output.

Keiki reports a value present only in later events as
`HirHeadUnrecoverable`; Keiro renders that family as `HeadUnrecoverable` and
refuses `mkEventStream`/`mkEventStreamOrThrow` construction. The practical rules
are simple:

- If a register write needs a command value, put that value in the head event.
- If later events also need it, repeat or derive it from head-recoverable data;
  do not rely on a tail event to make the command invertible.
- A side-effect result that is never emitted cannot become durable register
  state. Emit it first, then fold it.

The order edge demonstrates the safe pattern: `PlaceOrderData.orderId`, `sku`,
and `quantity` are all copied into the head `OrderPlaced` event before the edge
moves from `NotStarted` to `Placed`. See
[Replayability Safety](../user/replay-safety.md) for the invariant and
[the latent replay-safety bug section](migrating-to-validated-event-stream.md#the-one-thing-that-can-block-you-a-latent-replay-safety-bug)
for how an existing service encounters it at the validated boundary.


### Lifecycle vertices instead of fake initial values

Never initialize a register with a value that the domain rejects. `ProjectId
""` is type-correct but false; `error "unset"` merely postpones failure until
validation or hydration; inventing a `Default` instance hides the same lie.

Represent absence in the control state. Start in an `Absent`, `Unreported`, or
`NotStarted` vertex, accept only the initializing command there, and let its
event populate the real values before later vertices use them. The incident
example is compiled evidence:

```haskell
data IncidentState
  = Unreported
  | Triaging
  | Acknowledged
  | Escalated
  | Resolved

incidentTransducer =
  B.buildTransducer Unreported RNil isTerminal do
    B.from Unreported do
      B.onCmd inCtorRaiseIncident $ \d -> B.do
        B.emit wireIncidentRaised IncidentRaisedTermFields
          { incidentId = d.incidentId
          , service = d.service
          , severity = d.severity
          , raisedAt = d.raisedAt
          }
        B.goto Triaging
```

The complete definition is in
[`Jitsurei.Incident`](../../jitsurei/src/Jitsurei/Incident.hs).
`Jitsurei.OrderStream` uses `NotStarted` in the same way. For a brownfield
entity, an explicit import command and event such as
`BackfilledFromLegacy` should initialize its register file. That event records
the migration fact; a synthetic initial state would pretend the history had
always existed.


### One stream per entity, not a catalog map

A single stream containing a map of every entity may look atomically
convenient, but it pushes membership, arbitrary diffs, and dynamic collection
updates outside Keiki's symbolic model. It also puts unrelated entities behind
one optimistic-concurrency version and makes replay grow with the whole
catalog.

Give each stable entity its own stream. A reconciler can dispatch idempotent
observations and removals; each hydrated transducer decides added, updated,
no-op, or removed from its own scalar state. `Jitsurei.OrderStream` shows the
typed naming pattern:

```haskell
orderStream :: OrderId -> Stream OrderEventStream
orderStream = Stream.entityStream orderCategory . orderIdText
```

This gives up all-or-nothing visibility of an arbitrarily large catalog
update. Recovery becomes convergence: retry idempotent per-entity commands
until every target reaches the intended state. If readers need a coherent
generation, persist orchestration state—generation identity, desired inventory
hash, per-target progress, and activation—and expose only the activated
generation. If several streams genuinely need to cooperate, use
[Choosing A Primitive](choosing-a-primitive.md) to select a projection, process
manager, or router instead of rebuilding cross-stream behavior inside one
aggregate.


### Guard evolution with replay-only edges

Tightening a guard changes replay. A stored event admitted by the old guard may
no longer invert under the new one, and the next command then fails with
`HydrationNoInvertingEdge`. The sanctioned remedy is a `replay-only` twin edge
covering the removed region:

```text
old guard AND NOT new guard
```

Keiki's `ReplayOnly` mode excludes the twin from live command stepping and
tries it only when no live edge can invert the historical event. `keiro-dsl
diff` reports `AggGuardTightened` and prints the computed twin; the author pastes
it when history needs the old region or proves through the replay audit that no
stored stream does. Retire the twin only after affected streams are terminal,
truncated behind a covering snapshot, or audited clean.

Model guards from scalar comparisons so the removed region is visible enough
for this procedure. An opaque predicate cannot produce a trustworthy
complement or a precise affected surface. The durable decision is
[`docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md);
the operational sequence is in
[Changing decisions: guards, outputs, and dispatch](evolution-and-replayability.md#changing-decisions-guards-outputs-and-dispatch).

### Author structural bindings from create-once skeletons

For each `mapped structural` declaration, the spec names the Haskell module and
symbol that own its `StructuralBinding`, fixture corpus, and—when a register
uses the type—initial value. Run the ordinary scaffold command:

```bash
cabal run keiro-dsl -- scaffold service.keiro --out src
```

The first run creates a hand-owned skeleton at every distinct owning module.
If several mapped types intentionally share one binding module, the scaffolder
puts all of their obligations in that one file. Each total binding direction is
laid out with every declared record field or union/enum constructor and an
explicit `HOLE:` body. Fixture and register-initial symbols receive the same
create-once treatment. Fill the semantic construction and destruction logic,
then run the generated conformance harness. Never copy wire keys, tags,
presence, nullability, or defaults into the binding: those remain in the
`.keiro` declaration and its generated codec.

Re-running scaffold skips every existing skeleton. The scaffold record retains
one entry per binding field or constructor and per fixture/initial obligation,
so a declaration change prints a `newly required holes since last scaffold`
section naming the exact symbol and field to add by hand. The tool reports the
change but never parses, rewrites, or decides whether an existing Haskell body
is complete. GHC and the generated harness remain the enforcement boundaries.


### Derive only exact nominal bindings

When consumer and generated shape representations have the same constructor
count and order, identical constructor and selector names, identical field
order, and identical field types, opt into the zero-policy generic adapter:

```haskell
import Keiro.Codec.Structural.Generic (genericStructuralBinding)

artifactMetadataBinding :: StructuralBinding ArtifactMetadata ArtifactMetadataShape
artifactMetadataBinding = genericStructuralBinding
```

This derives construction and destruction only. It cannot inspect or change
the JSON schema. Renamed or reordered fields, arity differences, and field-type
differences fail compilation with a message directing the author to the
scaffolded binding module. There is deliberately no prefix stripping,
coercion, or positional guess. Use the explicit skeleton whenever the consumer
model is refined or intentionally differs from the generated shape, and retain
both binding-law and codec/golden conformance cases even for a derived binding.


### Explain every consumer-owned obligation before scaffolding

To inspect the application boundary without writing files, run:

```bash
cabal run keiro-dsl -- check service.keiro --explain-bindings
```

After normal validation succeeds, the report groups obligations by owning
package and module. It lists the binding and fixture signatures for every
structural declaration, the declared `binding-version`, all aggregate use-site
paths, and an initial-value signature only when a command/event path reaches a
register of that type. A spec with no structural mappings says so explicitly.
The report is an authoring aid, not a new compatibility or release gate;
`check`, `diff`, GHC, and the conformance harness retain their existing
authority.

<!-- appended-by: docs/plans/151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md
     anchor: binding-authoring-tooling
     (binding skeleton scaffolds and `check --explain-bindings` sections land here) -->


## Part B: The migration path

Stored bytes are facts. Haskell types, current encoders, and remembered design
intent are evidence about those facts, but none can replace inspecting the
values production actually persisted. The migration path therefore advances by
evidence: inventory every durable surface, capture representative bytes, derive
the new declaration from those bytes, compare codecs, make every difference an
explicit version step, validate the runtime assembly, replay real histories,
and only then switch traffic.

Keep the old release deployable until the cutover. Before the first new-version
event is written, a failed check means the team fixes the candidate and repeats
the evidence-producing step while production continues unchanged.


### Inventory the existing wire shapes

Start with storage, not source types. Enumerate every persisted or externally
consumed surface owned by the service:

- private event payloads and their metadata version and event-type tags;
- database rows imported into aggregate state;
- queue jobs and timers that may wait across a deployment;
- snapshots and other cached state;
- public messages consumed by another service; and
- workflow inputs, results, or journals if the service uses them.

For each shape, record where the bytes live, which component writes them, every
known reader, retention time, and the actual serialized form. Sample real
values into a corpus such as `test/goldens/legacy/<shape>/`. Include rare but
meaningful variants: every observed union tag, absent optional keys, explicit
`null`, pre-fix bug-era payloads, and the oldest supported schema version.
Scrub sensitive data without changing keys, tags, nullability, number/string
choices, or other structural facts.

Do not infer the wire contract from constructor spelling. Aeson options can
change field and constructor names, an encoder may omit `Nothing`, generic sum
encodings choose a tag/contents layout, and old releases may have persisted
shapes that today's type no longer admits. Treat public messages separately
from private events even when their current records look alike: they have
different owners and compatibility directions.


### Capture goldens before declaring the spec

Capture the corpus from production before writing a `.keiro` declaration or a
replacement codec. Then derive the proposed wire declaration from the
historical contract. Reversing that order invites a common failure: declare
what today's Haskell value looks like, synthesize fixtures from the declaration,
and accidentally prove the new codec agrees only with itself.

A golden is finite evidence. It proves that the candidate decoder still reads
that exact historical case. It does not prove that every possible historical
value was sampled, that the decoded event still has an inverting edge, or that
the event folds to the same state. Keep hand-captured production goldens
authoritative; generated tooling may add missing fixtures but must never
overwrite them. This boundary is recorded in
[`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md).

Use the `decodeRaw` pattern in
[Evolve Events Safely](evolve-events-safely.md) to turn each event golden into
a test. `Jitsurei.OrderStream` carries a real historical rung:

```haskell
decodeRaw orderCodec (EventType "OrderPlaced") 1
  (object ["orderId" .= ("order-100" :: Text), "qty" .= (3 :: Int)])
```

That test exercises `orderCodec`'s version-1 input through
`upcastOrderPlacedV1` and then through the current decoder.


### Shadow comparison of old and new codecs

With the corpus fixed, run the historical and candidate codecs side by side in
development tests. This is comparison evidence, not dual production authority.
For every historical golden, require the candidate codec to decode it through
the appropriate version boundary. For representative domain values, encode
with both codecs and compare parsed or RFC 8785-canonical JSON meaning. Keep the
original raw bytes as corpus provenance, but do not mistake object-key order or
insignificant whitespace for codec semantics unless another consumer actually
owns those byte-level details.

Classify every difference into exactly one of two buckets:

- parity: both codecs represent the same contract and the candidate can take
  over without a new rung; or
- explicit migration work: a new schema version and upcaster preserve the old
  rung while the candidate owns the new representation.

There is no “close enough” bucket. The `OrderPlaced` example demonstrates the
second classification. Version 1 used `qty` and did not require `sku`; version
2 uses `quantity`, and `upcastOrderPlacedV1` supplies `"UNKNOWN"` when the old
payload lacks `sku`:

```json
{"orderId":"order-100","qty":3}
```

The rename is not formatting. It is versioned compatibility work. A finite
shadow corpus cannot prove universal equivalence, so combine it with generated
round trips, negative fixtures, runtime validation, and the real-log audit.

The scaffolded comparison runner turns that discipline into consumer-compiled
evidence. Use it only after capturing the historical corpus and transcribing
the actual historical contract into a `mapped structural` declaration:

```bash
cabal run keiro-dsl -- scaffold service.keiro --out src \
  --codec-comparison ArtifactInfo \
  --comparison-out src/Generated/MyService/Structural/CodecCompare/ArtifactInfo.hs
```

`--comparison-out` must be the exact generated module path under `--out`.
Ordinary scaffold runs do not create this module, list it in the production
manifest/scaffold record, or report it as stale. The writer refuses to replace
a file without its dedicated migration-evidence banner, and it refuses opaque
or non-persisted selections. Comparison can add evidence to a structural claim;
it can never upgrade an opaque declaration.

The generated module exports `compareWithHistorical`. Compile it in a
consumer-owned test/executable beside an explicit `HistoricalCodec a` value;
do not recover historical behavior from today's global `ToJSON`/`FromJSON`
instances. The repository's complete five-arm example can be run as:

```bash
cabal run keiro-dsl-codec-compare-artifact-info -- \
  --historical-goldens keiro-dsl/test/conformance-codec-compare/fixtures/artifact-info \
  --report /tmp/artifact-info-codec-comparison.json
```

That deliberate negative example exits 1: its historical codec omits a null
key and spells one union tag differently. The report classifies both as
`CodecCompareDifference`, names the first divergent JSON pointer, proves every
declared optional/null/union branch was exercised, and carries historical-codec,
binding, canonical-type, and wire-fingerprint provenance. Invalid alleged
goldens and missing branches use `CodecCompareInvalidInput` and
`CodecCompareCoverageGap`; neither can disappear into a parity result.

For a real migration, continue only when every observation is RFC
8785-canonical JSON parity and the branch inventory is complete. Otherwise,
either correct a mistranscribed declaration to match the existing wire contract
or add an explicit schema version and upcaster for every difference. Never
silently normalize a mismatch. After cutover, the generated structural codec is
the sole wire authority. The historical decoder may remain only inside the
version boundary that reads its own old rung—never as a runtime fallback or a
second codec selector.

<!-- appended-by: docs/plans/152-prove-migrations-with-shadow-codec-comparison-and-structural-coverage-reporting.md
     anchor: codec-compare-tooling
     (the scaffolded comparison-runner section landed here; the manual technique above remains valid) -->


### Version, never silently normalize

When the desired representation differs from history, increment the aggregate
codec version and add an explicit upcaster. Never rewrite stored events and
never relabel a structural difference as normalization. Kiroku is append-only,
Keiro ships no event-payload migration tool, and upcasters run at decode time
for as long as their source-version payloads can exist.

`orderCodec` is the worked example: its aggregate-wide `schemaVersion` is 2,
and its source-1 rung applies `upcastOrderPlacedV1` for `OrderPlaced` while the
codec's event-type-aware boundary preserves other event kinds. In a codec with
several event kinds, versions still belong to the aggregate rather than each
constructor. Choose the next version as the aggregate's current maximum plus
one, keep every rung contiguous, and dispatch inside a shared rung by event
type when only one payload kind changes. See
[Evolve Events Safely](evolve-events-safely.md) for the code and
[Changing an existing event's payload fields](evolution-and-replayability.md#changing-an-existing-events-payload-fields)
for the post-adoption procedure.


### Legacy decoders only at the version boundary

The old decoder has one legitimate afterlife: it reads its own historical
version as part of an upcaster rung. It must not remain a fallback for malformed
current-version values or an alternate encoder “kept just in case.” Such a
fallback creates two live interpretations of the same current payload and
hides defects that should fail loudly.

Apply the dual-authority test after cutover: exactly one codec writes current
values, and exactly one contiguous version chain reads stored values. If
production can choose the legacy codec to encode a current value, or can route
a current-version decode through it after the authoritative decoder rejects the
payload, migration is incomplete. Historical-codec code used only by tests and
the old-version rung is comparison and compatibility machinery, not a second
authority.


### Migrate the stream boundary to ValidatedEventStream

Once the wire contract and version chain are explicit, assemble the ported
transducer, initial state, codec, and stream-name resolver as an `EventStream`
and admit it through `mkEventStream` or `mkEventStreamOrThrow`. Follow
[Migrating to `ValidatedEventStream`](migrating-to-validated-event-stream.md)
for the compiler-driven source edits; this chapter adds only the brownfield
interpretation.

This is often the first time a legacy model meets Keiki's replay checks. A
construction failure such as `HeadUnrecoverable`, inversion ambiguity,
nondeterminism, or a dead edge is evidence of a porting mistake or a latent
legacy bug, not ceremony to suppress. Fix the model or use the linked guide's
narrow, documented path for a confirmed conservative determinism/reachability
warning. Head recoverability and state-changing output-free checks cannot be
disabled at Keiro's durable boundary.

`mkEventStreamUnchecked` is for tests and emergency forensics. It skips every
Keiki and Keiro check, including codec-chain validation, and is never a
migration step or a production rollout workaround.


### Pre-cutover replay audit and deploy ordering

Run a one-time `AuditFull` with the candidate binary against a production-copy
database before switching traffic. `Keiro.ReplayAudit` full-replays every
accepted stream, reports replay failures and snapshot-seed divergence, and
returns a non-zero `auditExitCode` if any report fails. Non-zero means do not
cut over: keep the old release in service, repair the candidate or its explicit
migration boundary, refresh the copy if needed, and repeat the audit. `AuditFull`
is appropriate here because a first runtime cutover has no trustworthy
spec-derived affected set; routine later changes should use the narrower
replay-impact verdict and `AuditTargeted`.

The final traffic switch follows the rollout rules in
[`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
and [Deploy Ordering](../user/deploy-ordering.md):

- An aggregate codec has one version for writing and decoding, so do not run
  old and new codec versions as mixed writers for the same stream category.
  Use a stop-the-world or blue/green cutover with exclusive ownership.
- After the first new-version event is appended, rollback is roll-forward-only.
  The old release cannot decode that event and returns `VersionAhead`.
- Keep queue, timer, workflow, and public-message rollout rules separate; their
  consumers may need to deploy or drain before producers switch.

Snapshot misses and full replay are an expected one-time cost, not evidence
that event history should be rewritten. Snapshot compatibility is the triple of
state-codec version, register-layout shape, and control-state/fold identity
defined by
[`docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md`](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md).
See [Snapshots And Hydration](snapshots-and-hydration.md) for the fallback and
metrics. Once the cutover succeeds, use
[Evolution And Replayability](evolution-and-replayability.md) for every later
schema, decision, fold, queue, contract, or workflow change.
