---
type: Architecture Decision Record
title: Deterministic ids hash UTF-8 seed bytes and are frozen replay identity
description: Every Keiro deterministic id hashes the UTF-8 bytes of its seed text, and that derivation may never change again without a versioned migration story.
timestamp: 2026-08-14T14:26:07Z
docId: ADR-24
status: Accepted
date: 2026-08-06
originatingPlan: docs/plans/202-derive-workflow-deterministic-ids-from-utf-8-bytes.md
---

# 24. Deterministic ids hash UTF-8 seed bytes and are frozen replay identity

Date: 2026-08-06

Status: Accepted


## Context

Several Keiro identifiers are *deterministic*: a version-5 UUID over a seed text
built from public coordinates, so that an at-least-once writer collapses to
exactly one row rather than needing a separate dedupe table. Four of them shared
one seed encoding — `fmap (fromIntegral . fromEnum) . Text.unpack` — which
converts each character to its Unicode codepoint and then keeps only the low
eight bits. Every codepoint at or above 256 aliases into the 0–255 range, so
`"\x0101"` and `"\SOH"` hash identically, as do countless CJK pairs. None of the
identity constructors constrain inputs to ASCII: `mkWorkflowName` and
`mkWorkflowId` reject only structural separators, and step names, sleep names,
awakeable labels, patch ids, and process-manager correlation ids are arbitrary
`Text`.

The consequences were not a cosmetic id clash. For workflow journal appends the
event store enforces global event-id uniqueness, so two colliding step names
wedge the workflow: the second step's append is refused as a duplicate,
deterministically, on every retry, until the resume worker's crash-backoff
ladder marks the workflow failed. A test that runs steps named `"\x0101"` and
`"\SOH"` reproduced exactly that, returning `Left (DuplicateEvent Nothing)` out
of `runWorkflow`. For process-manager command ids the deterministic id *is* the
idempotency mechanism, so a collision between two genuinely different commands
suppresses the second one silently. Replay itself was never at risk — the step
index is keyed by the full step-name text and is the authoritative
replay-visibility fallback (ADR 5) — but the append path was.

The derivation could not simply be replaced with something better, because these
ids are replay identity. Every id already written into a deployment's event
store, timer table, and awakeable table was derived by this function; changing
what it computes for an input renames those ids, and nothing in the system
recovers from a rename.

`Keiro.Router.deterministicRouterCommandId` was written later and already
encodes each field as length-prefixed UTF-8, which is why it is not part of the
defect.


## Decision

A deterministic-id seed is hashed as its UTF-8 bytes. The single definition is
`Keiro.DeterministicId.identitySeedBytes`, and the four affected derivations —
`Keiro.Workflow.deterministicJournalId`, `Keiro.Workflow.Sleep.sleepTimerId`,
`Keiro.Workflow.Awakeable.Compatibility.generation0AwakeableId`, and
`Keiro.ProcessManager.deterministicCommandId` — all route through it. No call
site may re-derive seed bytes locally.

UTF-8 is chosen over any versioned or namespaced scheme because for a pure-ASCII
seed the UTF-8 bytes *are* the codepoint values. Every id in every deployment
that used ASCII identities is therefore byte-identical before and after, and the
fix ships with no migration, no cutover, and no operator action. A versioned
scheme would have imposed a cutover on every deployment to repair a defect that
only reachable non-ASCII inputs suffer.

This derivation is now frozen. Changing `identitySeedBytes`, or the seed strings
the four functions build, renames live identities and is not an ordinary code
change: it requires an explicit versioned derivation, an adoption path for
in-flight ids, and its own decision record. The freeze is enforced in
`keiro/test/Main.hs` under `describe "Keiro deterministic id derivation"`, whose
UUID literals were captured from the pre-change implementation. A failure there
means a deployed id moved; the fixture is never the thing to update.

New deterministic-id derivations should follow
`Keiro.Router.deterministicRouterCommandId` and encode each seed field as
length-prefixed UTF-8 rather than joining fields with a delimiter. The four
derivations above keep their `:`-joined seeds because changing them would break
the freeze; their residual delimiter ambiguity is bounded by the identity
constructors, which reject `:` in workflow names and ids.


### Compatibility bridge for pre-UTF-8 identity

The UTF-8 derivation remains the only identity used for new writes. During the
upgrade window Keiro also retains `Keiro.DeterministicId.legacySeedBytes`, an
immutable reproduction of the pre-0.12 codepoint-to-byte truncation. UUIDs
captured by running the genuine pre-change implementation pin that artifact in
`keiro/test/Main.hs`; it is not a general-purpose encoder and must never mint a
new append id.

Process-manager writes derive their ordered candidate set through
`Keiro.ProcessManager.deterministicCommandIdProbes`: the current UTF-8 id first,
then the legacy id only when the full seed contains non-ASCII text. ASCII seeds
produce identical bytes, so they retain one database probe. Every manager-state
and target-command preflight uses `firstExistingEventId` and reports whichever
candidate matched, while a miss still appends only under the current id.
Generation-0 awakeable adoption follows the same order through shared internal
identity probes, exposed for compatibility inspection as
`generation0AwakeableId` and `preUtf8Generation0AwakeableId`; fresh allocations
remain random and journaled.

Those probes are compatibility identities, not allocation recipes. They are exported
only from `Keiro.Workflow.Awakeable.Compatibility`; the ordinary awakeable module
exposes only opaque allocated ids. Runtime adoption and the compatibility module share
`Keiro.Workflow.Awakeable.Internal.Identity`, so there is one frozen implementation
without placing it on the ordinary application surface. Generated workflow runtimes
likewise expose abstract declared-await bindings whose allocation delegates to
`awakeableNamed`; they never reconstruct a fresh id from workflow coordinates.

The router has an additional, older compatibility identity: before 0.2.0.0 it
used positional process-manager command ids rather than target-keyed router ids.
Every released positional router write predates the UTF-8 switch, so the two
router paths derive that candidate with `legacyDeterministicCommandId` and do
not probe a nonexistent UTF-8 positional variant.

The old encoding was non-injective. If two distinct historical seeds collided
to one legacy id in the same target stream, a probe cannot know which command
the row represents. The bridge therefore preserves the old suppression in
that ambiguous case rather than risking a double application. This is accepted
only for the bounded compatibility window; new UTF-8 identities do not create
that ambiguity.

The command-id bridge and the positional-router bridge form one compatibility
unit and must be removed together. They may not be removed in 0.12.x; the
earliest eligible release is 0.13.0.0, and even then removal requires an
operator attestation that no pre-upgrade dispatch remains inside any dedup or
redelivery horizon. Concretely, every at-least-once channel — Kafka consumer
groups, PGMQ live queues and archives, durable timers, and planned operator
replays — must be unable to redeliver a source event first delivered before the
0.12 upgrade. Version age alone is not sufficient evidence.


## Consequences

- ASCII deployments — every deployment we know of — see no identity change at
  all. This is what makes the change deployable as an ordinary upgrade.
- Non-ASCII seeds derive different ids than they did before. The in-flight
  consequences are handled as follows:
  - A non-ASCII workflow journal still replays correctly, because replay reads
    the step index by full step-name text (ADR 5) and the append transaction's
    index check fires before the event id matters.
  - An in-flight non-ASCII sleep may arm one duplicate timer row; its fire
    collapses in the idempotent append.
  - A generation-0 awakeable registered under an old non-ASCII derived id is
    adopted through the frozen legacy candidate after the current candidate
    misses. New allocations remain random v4 UUIDs.
  - A non-ASCII process-manager or router emission retried across the deploy
    boundary probes its historical id and is reported as a duplicate without
    appending a second command.
- Workflows previously wedged by a non-ASCII step-name collision now run. This
  is the behavioral acceptance criterion, not an incidental improvement.
- The defect class is closed only for these four derivations. Generated code
  from `keiro-dsl` still emits the truncating `namedUuid` helper in scaffolded
  process managers; that code's identity is governed by ADR 18's frozen-fold and
  generated-edition rules and needs its own compatibility argument, so it is
  deliberately out of this decision's scope.
