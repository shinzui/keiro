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
---

# Inspect reaction process managers and label legacy inspection before 1.0

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro is heading for 1.0.0.0 with Language 6 as the only DSL language and the typed reaction
API (`Keiro.ProcessManager.Reaction`) as the only process-manager API, per ADR-49 and plan 304.
The unreleased inspection cohort lets an operator run `keiro-ops pm show <manager> <correlation>`
and `pm list`, but only for the legacy positional managers that the retirement release removes;
a service written against the reaction API has no inspector, no last-reaction evidence, and no
way to opt into provenance. After this plan, the same two commands work for a reaction process
manager: they show its folded state, the enabled inputs, its pending timers, and the last
reaction with target-keyed dispatch witnesses derived from the reaction runner's own
deterministic identities. Where the legacy surface is kept for the transition, the changelog,
the user guide, and the API reference say it is legacy-only and will go with Languages 1 to 5,
so a consumer who adopts it in 0.22 is not surprised later. If the extension cannot land before
the 0.22.0.0 tag, the labelling alone is the minimum outcome and the extension ships in the
following release; the parent MasterPlan records that decision.


## Progress

- [ ] M1: `Keiro.ProcessManager.Inspect` exports `reactiveProcessManagerInspector`, built from
      a `ReactiveProcessManager`, and `pm show`/`pm list` work for it: the `jitsurei` example
      (or the `keiro-dsl` process-reaction conformance fixture) registers one, and a test shows
      `inspectProcessManagerInstance` returning folded state, `waiting_for`, and pending timers
      for a reaction manager.
- [ ] M2: The last reaction of a reaction manager reports dispatch witnesses without a new
      provenance family: the inspector probes the reaction runner's target-keyed command ids
      (`deterministicReactionCommandId`) for each target the reaction surface declares, and the
      view reports `event_present` or `not_observed` per target. ADR-55 is revised to describe
      the reaction path.
- [ ] M3: The legacy surfaces are labelled. `docs/user/process-managers-and-timers.md`,
      `docs/user/api-reference.md` (the `inspectionProvenance` and `pm` paragraphs), and the
      `keiro` and `keiro-ops` changelog entries say that `inspectionProvenance`, the
      `legacy-positional-v1` family, and the legacy inspector constructors exist for positional
      managers only and are removed with Languages 1 to 5; the wording is handed to plan 320.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Derive reaction dispatch witnesses from the reaction runner's deterministic ids
  instead of adding a `reaction-v1` provenance family to event metadata.
  Rationale: ADR-41 makes reaction dispatch identity target-keyed and recoverable from the
  saga witness, so the inspector can probe what the runner would have written without a
  metadata opt-in; ADR-55 forbids synthesizing modern identities from the legacy family, and a
  second family would duplicate what the runner already guarantees. If probing proves
  insufficient (for example for `NoAdvance` reactions with no accepted append), record the
  gap here and revisit.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

A process manager reacts to source events by appending to its own saga stream, dispatching
commands to target aggregates, and scheduling timers. Keiro has two APIs for it: the legacy
positional API in `keiro/src/Keiro/ProcessManager.hs` (`ProcessManager`, `DomainProcessManager`,
`runProcessManagerOnce`, `advanceDomainProcessManager`) whose dispatch identity is derived from
the emit position, and the typed reaction API in `keiro/src/Keiro/ProcessManager/Reaction.hs`
(`ReactiveProcessManager`, `runReactiveProcessManagerWorkerWith`, `deterministicReactionCommandId`)
whose identity is target-keyed (ADR-41,
`docs/adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md`).
Language 6 `reactions` bodies generate against the reaction API (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`,
`emitReactionProcessGen`); Languages 1 to 5 generate against the legacy API.

The unreleased inspection module `keiro/src/Keiro/ProcessManager/Inspect.hs` defines
`ProcessManagerInspector` (name, event stream, `streamFor`, category, `correlationOf`, display
encoders, `enabledInputs`) and two constructors, `processManagerInspector` and
`domainProcessManagerInspector`, both for the legacy API. `inspectProcessManagerInstance`
hydrates with `hydrateWithSource` (`keiro/src/Keiro/Command.hs`), reads the head event, decodes
the optional `keiro.pm` metadata through `Keiro.ProcessManager.Provenance` (family
`legacy-positional-v1`, written only when `RunCommandOptions.inspectionProvenance` is
`CaptureInspectionProvenance`; ADR-55,
`docs/adr/0055-legacy-reaction-provenance-is-bounded-explicit-opt-in-metadata.md`), probes
each recorded dispatch target with `firstExistingEventId` and the legacy
`deterministicCommandIdProbes`, and lists pending timers through `findPendingTimers`
(`keiro/src/Keiro/Timer/Schema.hs`). `listProcessManagerInstances` pages the category's streams
with Kiroku's `listStreams`. The `keiro-ops` commands are in
`keiro-ops/src/Keiro/Ops/ProcessManager.hs` and are mounted through `AppHooks.processManagers`
(`keiro-ops/src/Keiro/Ops/Embed.hs`). `jitsurei/src/Jitsurei/Inspection.hs` registers the
fulfillment manager as a legacy inspector, and `jitsurei/test/Main.hs` ("Jitsurei process
manager") exercises `pm show` and `pm list` end to end with provenance capture enabled.

The reaction API has no inspector. Its runner records accepted witnesses and target-keyed ids
that `recoverWitness` reads back; those are exactly what an inspector needs to report "this
reaction dispatched to these targets and the target streams contain (or do not contain) the
command events". The drafted 0.21.0.0 to 0.22.0.0 edge (held outside the tree by plan 303)
says "Modern reaction provenance is unavailable". ADR-49
(`docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md`) and
plan 304 (`docs/plans/304-retire-legacy-language-and-runtime-compatibility-before-keiro-1-0.md`)
retire the legacy API with Languages 1 to 5.

Relevant local ADRs: ADR-41, ADR-55 (revised here), ADR-49, ADR-28
(`docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`,
every `keiro-ops` command renders a supported library read). No cross-repository ADR applies.


## Plan of Work

Milestone 1 adds the constructor. `reactiveProcessManagerInspector :: (Show s) =>
ReactiveProcessManager ... -> StreamCategory ... -> (s -> RegFile rs -> Value) ->
ProcessManagerInspector ...` built from the reaction manager's name, event stream, `streamFor`,
and transducer, reusing `mkInspector` so `enabledInputs` and `correlationOf` behave identically.
Register one in `jitsurei` if it has a reaction manager; otherwise register the
`keiro-dsl/test/conformance-process-reactions` fixture's generated manager in a `keiro` test
and prove `pm show` through `Ops.runCommand` the way `jitsurei/test/Main.hs` does for the legacy
one.

Milestone 2 adds reaction witnesses. Extend `ProcessManagerInspector` with an optional
`reactionTargets :: Maybe (s -> EventId -> [(Text, StreamName)])` (or the equivalent the
reaction surface can supply: for each reaction the manager declares, the target stream names it
may dispatch to), and in `inspectProcessManagerInstance` when the inspector is a reaction one,
derive the dispatch witnesses by probing `deterministicReactionCommandId` for the source event
id and each declared target, reporting `EventPresent` or `NotObserved` exactly as the legacy
path does, under `provenance_status: "derived"` so a client can tell derived evidence from
captured metadata. Do not read or write any `keiro.pm` metadata on this path. Revise ADR-55 so
its "modern reaction runner ... has no last-reaction provenance in this cohort" sentence states
the derived-witness design instead.

Milestone 3 labels the legacy surfaces. Write the sentences (legacy-only, removed with
Languages 1 to 5 per ADR-49 and plan 304) into the two user documents and give the changelog
wording to plan 320, which owns the changelogs. Run `just user-documentation-validate`.


## Concrete Steps

From the repository root inside `nix develop`:

```bash
cabal build keiro keiro-ops jitsurei
cabal test keiro-test --test-options='-m "ProcessManager"'
cabal test keiro-ops-test jitsurei-test
just user-documentation-validate
just adr-validate
```

Embedded command against a database that holds a reaction manager instance:

```bash
keiro-ops pm show <manager-name> <correlation-id> --json | jq '.last_reaction.provenance_status, [.last_reaction.provenance.dispatched_commands[].witness]'
```

Expected output for a reaction manager whose dispatch committed:

```text
"derived"
["event_present"]
```


## Validation and Acceptance

M1: the constructor exists, the registered reaction inspector answers `pm show` and `pm list`
in a test, and `inspectProcessManagerInstance` returns state, `waiting_for`, and timers. M2:
the derived witness test shows `event_present` after a committed dispatch and `not_observed`
for a declared target that was not dispatched; ADR-55 validates. M3: the validator passes and
the two documents and the handed-over changelog wording say legacy-only. Beyond compilation,
the proof is the `jq` line above against a real instance.


## Idempotence and Recovery

Source and documentation edits only; inspection reads acquire nothing and write nothing, so
repeated `pm show` calls are safe. If M2's probing proves insufficient for some reaction
outcome, keep M1 and M3, record the gap in Surprises & Discoveries, and let plan 320 label the
derived witnesses as partial.


## Interfaces and Dependencies

`keiro/src/Keiro/ProcessManager/Inspect.hs`, `keiro/src/Keiro/ProcessManager/Reaction.hs`
(`deterministicReactionCommandId`, the `ReactiveProcessManager` record),
`keiro/src/Keiro/ProcessManager/Provenance.hs` (unchanged), `keiro-ops/src/Keiro/Ops/ProcessManager.hs`,
`jitsurei/src/Jitsurei/Inspection.hs`, the `keiro-dsl` process-reaction conformance fixture.
The `ProcessManagerInspector` record gains an optional field, which direct constructors must
supply; plan 320 records that. The legacy-only wording is an interface to plan 320. No parent
milestone must be accepted before this plan begins.
