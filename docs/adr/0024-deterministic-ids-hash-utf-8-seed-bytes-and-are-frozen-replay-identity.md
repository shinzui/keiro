---
type: Architecture Decision Record
title: Deterministic ids hash UTF-8 seed bytes and are frozen replay identity
description: Every Keiro deterministic id hashes the UTF-8 bytes of its seed text, and that derivation may never change again without a versioned migration story.
timestamp: 2026-08-06T13:53:08Z
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
`Keiro.Workflow.Awakeable.deterministicAwakeableId`, and
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


## Consequences

- ASCII deployments — every deployment we know of — see no identity change at
  all. This is what makes the change deployable as an ordinary upgrade.
- Non-ASCII seeds derive different ids than they did before. The in-flight
  consequences are bounded and accepted:
  - A non-ASCII workflow journal still replays correctly, because replay reads
    the step index by full step-name text (ADR 5) and the append transaction's
    index check fires before the event id matters.
  - An in-flight non-ASCII sleep may arm one duplicate timer row; its fire
    collapses in the idempotent append.
  - A generation-0 awakeable registered under an old non-ASCII derived id is no
    longer adopted by `deterministicAwakeableId`. New allocations are random v4
    UUIDs, so only the legacy adoption path is affected.
  - A non-ASCII process-manager emission retried across the deploy boundary can
    emit one duplicate command — at-least-once, which is the guarantee the
    dispatch path already carries.
- Workflows previously wedged by a non-ASCII step-name collision now run. This
  is the behavioral acceptance criterion, not an incidental improvement.
- The defect class is closed only for these four derivations. Generated code
  from `keiro-dsl` still emits the truncating `namedUuid` helper in scaffolded
  process managers; that code's identity is governed by ADR 18's frozen-fold and
  generated-edition rules and needs its own compatibility argument, so it is
  deliberately out of this decision's scope.
