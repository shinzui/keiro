---
id: 319
slug: inspect-reaction-process-managers-and-label-legacy-inspection-before-1-0
title: "Inspect reaction process managers and label legacy inspection before 1.0"
kind: exec-plan
created_at: 2026-10-21T12:21:07Z
intention: "intention_01m5f6g7yje5csts3eztsgvnws"
master_plan: "docs/masterplans/46-address-the-rev-20-review-findings-and-the-command-path-performance-regression.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T12:21:07Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:24:48Z
      verdict: "changes-requested"
      note: "Derived dispatch witnesses lack persisted source ID, decoded input/target list, and per-target occurrence; accepted witness cannot reconstruct those inputs."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:49:51Z
      mode: "update"
      note: "Replace unsupported derived witnesses with explicit unavailable provenance; define descriptor mode and early labelling gate."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T04:57:06Z
      mode: "implement"
      note: "Complete legacy labelling before reaction state-inspector implementation."
---

# Inspect reaction process managers and label legacy inspection before 1.0

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


After this plan, application-mounted `pm show` and `pm list` can inspect a typed reaction
process manager's persisted state, live input candidates and pending timers. The inspector
reports the last persisted saga event, when one exists, with reaction provenance explicitly
unavailable. It does not pretend to know which input or targets produced that event.

Legacy positional capture remains labelled as legacy-only and scheduled for retirement with
Languages 1–5 under ADR-49 and plan 304. Complete M3 (labelling) first: it is mandatory before
0.22.0.0. M1/M2 (reaction state inspection and honest evidence handling) may finish in the
following release, but remain required to complete this child and MasterPlan 46.


## Progress


- [x] M1 (2026-10-25): `reactiveProcessManagerInspector` adapts saga handler/name/stream
      mapping. Library state/version/candidate/timer/list/deletion checks pass; a handwritten
      ops fixture mounts it through AppHooks and executes both `pm show` and `pm list`.
- [x] M2 (2026-10-25): Explicit `NoReactionProvenance` branches before legacy metadata
      decoding and evidence probes. Multi-event acceptance, repeated input-selected targets,
      silent/no-advance delivery and valid-looking legacy metadata retain unavailable/null
      provenance. Existing legacy capture tests pass: 46 library and 54 ops examples.
- [x] M3 (2026-10-25): Manager/API guides label existing constructors and
      `legacy-positional-v1` capture as positional-only, with ADR-49 retirement wording.
      Strict user/guide validation passes. Plan 320 consumes this wording; capture remains
      legacy-only when the state extension lands.

M3 was accepted before beginning M1/M2.


## Surprises & Discoveries

The handwritten ops fixture adds a test-only dependency on
`mori://shinzui/keiki/packages/keiki`. Its local source was discovered through Mori;
the official registry and upstream v0.9.1.0 tag were verified before selecting
the tested `>=0.9.1 && <0.10` bound. It imports no DSL-generated test component.


The proposed derived-witness design cannot recover its inputs. `ReactiveProcessManager.react`
is a function of decoded source input. `deterministicReactionCommandId` needs manager name,
correlation, source event ID, target stream and occurrence within that target. `recoverWitness`
returns only `Either ReactionError ()`; it validates an accepted saga event and reconstructs
neither source identity nor target commands. The saga's deterministic UUID is not reversible,
and only the first event of a multi-event append receives the acceptance ID. NoAdvance,
rejection and eventless acceptance leave no new saga receipt. ADR-41/55 already describe these
limits. Even a list of possible targets would not establish the actual intended dispatches.


## Decision Log


- Decision: Add reaction state inspection with explicit unavailable provenance; withdraw
  the proposed `reactionTargets` callback and `derived` status.
  Rationale: Current persisted data lacks the source/input/occurrence evidence required for
  reliable target IDs. Adding an evidence family or source lookup contract would be separate
  architecture work, not a read-only inference from the existing acceptance witness.
  Date: 2026-10-21
- Decision: Give inspectors an explicit provenance mode; legacy constructors read the legacy
  family and the reaction constructor reads none.
  Rationale: Reusing `mkInspector` without a mode would let the reaction descriptor decode
  caller-supplied or historical legacy metadata and present it as reaction evidence.
  Date: 2026-10-21
- Decision: M3 is the release prerequisite; M1/M2 remain required for full plan completion.
  Rationale: The existing release decision permits the extension to follow the tag while
  ensuring consumers see the legacy retirement boundary immediately.
  Date: 2026-10-21

Revision note (2026-10-21): Replaced impossible provenance reconstruction with explicit
unavailability, corrected the constructor's sagaHandler access, and made the early labelling
milestone and package test boundaries concrete.


## Outcomes & Retrospective

Both manager APIs now use the same owner-read/catalog/command path for state, candidate
inputs, pending timers and bounded raw journal listing. The reaction descriptor exposes the
last persisted event at the hydrated version, with explicitly unavailable provenance. It
never decodes a legacy frame or infers source/targets from deterministic UUIDs. Legacy helpers
retain bounded opt-in positional provenance.

M3 was accepted first, independently of the extension. The extension then passed 46 library
and 54 ops examples, including a handwritten reaction producer consumed by pm show/list.
Direct inspector records require provenanceMode. ADR-55 retains that durable distinction and
its evidence limits; API/manager guides and plan 320 describe accepted constructor coverage.
No reaction write, dispatch identity, timer worker, schema or metadata capture path changed.



## Context and Orientation


`keiro/src/Keiro/ProcessManager/Reaction.hs` defines `ReactiveProcessManager` with fields
`name`, `correlate`, `sagaHandler`, `streamFor`, `targetEventStream`, `targetProjections`, and
`react`. Its validated saga definition is `manager.sagaHandler.eventStream`; it has no direct
`eventStream` field. `react` maps input to unconditional and acceptance-dependent follow-ups.
Deterministic target IDs are computed from the original input's source UUID and target
occurrence, not from hydrated saga state or the latest saga event UUID.

`keiro/src/Keiro/ProcessManager/Inspect.hs` owns `ProcessManagerInspector`, `mkInspector`,
hydration through `hydrateWithSource`, last persisted event reading, legacy metadata decoding,
and pending timer reads. `reactionJson` already renders absent provenance as `unavailable`
with null `provenance`. Keep that representation. `last_reaction` names the latest persisted
saga event, not the most recent source delivery; a silent delivery need not change it.
Listing uses one category/prefix page and application-owned correlation mapping.

`keiro-ops/src/Keiro/Ops/ProcessManager.hs` renders these owner reads through
`AppHooks.processManagers`. Library behavior tests belong in `keiro/test/Main.hs`; transport
registration tests belong in `keiro-ops/test/Main.hs`. Do not import `keiro-ops` into the
`keiro` test suite or depend on a generated `keiro-dsl` test component. Use a small handwritten
reaction fixture following the existing runtime tests, with category-consistent `streamFor`.
`jitsurei/src/Jitsurei/Inspection.hs` remains a useful legacy registration example.

Relevant ADRs are [ADR-41](../adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md)
(acceptance witnesses and unrecoverable silent outcomes),
[ADR-55](../adr/0055-legacy-reaction-provenance-is-bounded-explicit-opt-in-metadata.md)
(legacy-only bounded capture), [ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md)
(retirement), and [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
(owner reads). No cross-repository decision is required.


## Plan of Work


Implement M3 first. In `docs/user/process-managers-and-timers.md` and
`docs/user/api-reference.md`, distinguish command/constructor coverage from provenance:
legacy `inspectionProvenance` capture and `legacy-positional-v1` are positional-only even
when a reaction state constructor becomes available. Before M1/M2 land, state that both
constructors are legacy-only; afterward update command/state coverage while keeping the
capture limitation. Hand plan 320 the exact release wording. Plan 317 owns only the timer
cost-envelope paragraphs in the manager/timer page. Run documentation validation.

M1 adds `reactiveProcessManagerInspector` with the same category and display encoder arguments
as the legacy constructor. Build the descriptor from `manager.name`,
`manager.sagaHandler.eventStream`, and `manager.streamFor`, using the supported HsPred
constraint and the existing `mkInspector` live-input enumeration. Do not claim live candidates
have passed guards. Add `ProcessManagerProvenanceMode = ReadLegacyProvenance | NoReactionProvenance`
and a `provenanceMode` field to `ProcessManagerInspector`. Existing helper constructors set
ReadLegacyProvenance; the reaction helper sets NoReactionProvenance. Update direct constructors,
exports and record-construction documentation. This explicit mode replaces the proposed
input/target callback, not the underlying runner's options.

Use supported reaction execution to create an accepted saga instance and pending timer in a
small library fixture. Assert folded state/version, waiting inputs and timer filtering, plus
category list pagination and missing/soft-deleted behavior. In the ops test package, register
a minimal handwritten reaction descriptor through AppHooks and execute `pm show`/`pm list`
through the existing command runner. This proves the public producer/consumer path without
adding a package dependency cycle or borrowing a generated executable test artifact.

M2 makes `observeReaction` branch on the descriptor mode before metadata decoding or target
lookups. NoReactionProvenance returns the existing event header fields, Nothing provenance,
Nothing source name and an empty internal dispatch-status list; JSON remains
`provenance_status: "unavailable"`, `provenance: null`. ReadLegacyProvenance retains current
bounded capture decoding and legacy ID probing. Do not call `deterministicReactionCommandId`
from inspection or synthesize a modern family from legacy metadata.

Tests run a reaction with input-dependent targets and two commands to the same target, and
assert that successful dispatch does not produce invented inspection witnesses. Include a
multi-event accepted saga batch and a subsequent NoAdvance/eventless delivery: inspection
reports the last stored event truthfully, with no claim to observe the silent delivery.
Caller-supplied legacy-looking metadata on a reaction event must remain unavailable. Legacy
captured provenance tests must still pass. No new write metadata, source-event query, target
probe, or runtime capture cost is introduced. Update ADR-55's implementation wording only
once the state-inspector constructor lands; its evidence limitation remains durable.


## Concrete Steps


From the repository root inside `nix develop`:

```bash
cabal build keiro keiro-ops
cabal test keiro-test --test-options='-m "ProcessManager"'
cabal test keiro-ops-test --test-show-details=direct
just user-documentation-validate
just adr-validate
```

Use the embedded ops test registration to inspect an accepted reaction instance. Assert these
fields in the command JSON:

```json
{"provenance_status":"unavailable","provenance":null}
```

Those fields are nested under `last_reaction`; also assert the expected state/version,
waiting_for and pending_timers. A manager with no persisted instance may have no list entry
or last_reaction; absence must not be converted into a fabricated receipt.


## Validation and Acceptance


M3 is accepted by validated manager/API guide wording and the changelog handoff, independently
of M1/M2. M1 requires the library constructor and owner-read tests plus the embedded ops
show/list test. M2 requires explicit unavailable provenance across accepted multi-event,
input-dependent/repeated-target, silent and misleading-metadata cases, with existing legacy
capture behavior preserved. Inspect the branch before decoding/probes to establish that
NoReactionProvenance does no legacy lookup or metadata interpretation.

All three milestones must finish for this plan to be Complete. The release may consume M3
alone if the extension has not landed; plan 320 must document the actual shipped constructor
coverage. There is no derived-witness acceptance criterion and no new provenance family.


## Idempotence and Recovery


All implementation tests use disposable migrated stores; inspection itself remains read-only.
Do not backfill metadata or migrate a live legacy manager to the reaction runner. ADR-41's
identity/drain rules still govern such migrations. If M1/M2 are unfinished at release time,
keep them unchecked and publish the M3 legacy-only wording; do not mark this child Complete.


## Interfaces and Dependencies


This plan owns `keiro/src/Keiro/ProcessManager/Inspect.hs`, its mode/constructor exports,
library tests, and embedded ops tests. `Reaction.hs` supplies the existing manager record;
its runtime identities, writes and recovery behavior are unchanged. Direct inspector record
constructors must provide the new provenanceMode; plan 320 records that construction change
only if the extension ships.

This plan owns manager/API wording in the two user guides; plan 317 owns the timer-cost
section of the shared page and plan 320 owns changelogs. No hard prerequisite blocks this
work. M3 precedes M1/M2, and is a hard prerequisite of plan 320 final M1/M4 and plan 303's tag.
