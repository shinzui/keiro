---
type: Improvement Request
title: Thread inbound correlation and causation ids through Keiro events and dispatched commands
description: >-
  Populate Kiroku's typed correlationId and causationId on every event Keiro appends and every
  command a process manager dispatches, seeded from a correlation id the caller supplies, so an
  external verifier can retrieve a workflow's evidence by correlation instead of by business key.
timestamp: 2026-10-01T03:04:45Z
requestId: IR-52
status: proposed
origin: mori://shinzui/shoko
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-10-01T03:04:45Z
    document_timestamp: 2026-10-01T03:04:45Z
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-fable-5-1
    effort: high
    context: >-
      Author self-review at Keiro `35d88961` against keiro-core's event codec, Keiro.Command's
      RunCommandOptions, Keiro.ProcessManager's dispatch path, kiroku-store's Causation module,
      and docs/user/roadmap.md; independent review is pending.
---

# Improvement Request: Thread Inbound Correlation and Causation IDs Through Keiro Events and Dispatched Commands

## Status

Proposed.

Raised by `mori://shinzui/shoko`, a Haskell DSL for verifying distributed behavior through
evidence. Shōko is the verification tool for rewriting the TAN services onto keiro-runtime and
for developing features on the rewritten services afterwards. The research that produced this
request is `mori://shinzui/shoko/okf/research/concepts/RES-1`, findings S2, M2, and M5.

Shōko can proceed without this request by correlating on a business key such as a registration
id, which is the strategy it has to use for the legacy services in any case. It files the
request because Kiroku already stores typed correlation and causation ids and can query by
them, while Keiro never populates them. The strongest evidence-correlation path on the target
platform is therefore unavailable for a reason that sits in the runtime rather than in any
application built on it.


## Context

Evidence as found at Keiro 0.19.0.0 on 2026-09-30. Paths are repository-relative.

- `RecordedEvent` carries `causationId` and `correlationId` as `Maybe UUID`
  (`keiro/src/Keiro/Command.hs`, around line 1507).
- The event encoder hard-codes both to `Nothing` (`keiro-core/src/Keiro/Codec.hs`, around
  lines 197 to 198), so every event Keiro appends has null ids.
- `RunCommandOptions` has no correlation field, only free-form `metadata :: Maybe Value`
  (`keiro/src/Keiro/Command.hs`, around lines 377 to 383).
- Process managers key their state streams by a `Text` correlation in the `pm:<name>-<correlation>`
  convention (`keiro/src/Keiro/ProcessManager.hs`, around line 206), and dispatched commands set
  only `eventIds` (around line 600).
- `docs/user/roadmap.md` lists "Causation and correlation metadata carried on emitted commands"
  under completed process-manager hardening (lines 232 to 235). That does not match the codec
  behaviour above.
- kiroku-store 0.9.0.1 offers `findByCorrelation`, `findCausationDescendants`, and
  `findCausationAncestors`, and types both ids on `RecordedEvent`
  (`mori://shinzui/kiroku`, `kiroku-store/src/Kiroku/Store/Causation.hs` and `Types.hs`).

For an external verifier this means that an observer holding a correlation id cannot retrieve a
workflow's events with Kiroku's correlation query, because every event's correlation is null.
Causality assertions have to be inferred from ordering, which Keiro's event model was designed to
make unnecessary.

The same gap affects any consumer that wants to follow a workflow across aggregates and process
managers: tracing, debugging tools, and the inspection surfaces requested elsewhere in this bundle.


## Requested Change

1. **Accept an inbound correlation id on command execution.** A typed field on
   `RunCommandOptions`, and on the entry points that build it, defaulting to a fresh id when
   absent. Document how a service boundary seeds it from an HTTP header or a W3C baggage entry.
2. **Stamp every appended event.** `correlationId` is the command's correlation id.
   `causationId` is the id of the message that caused the command: the inbound command for
   aggregate events, and the triggering event for commands a process manager dispatches and the
   events those commands produce.
3. **Carry both ids on dispatched commands.** Process managers and routers propagate the
   correlation id and set causation per hop, so a chain of event, process manager, command, and
   event keeps one correlation id with a causation link at every step.
4. **Reconcile the roadmap** with the shipped behaviour, or mark the item pending.
5. **Stay wire-compatible.** Both columns already exist in Kiroku and are nullable; existing
   events with null ids must continue to load and replay.


## Acceptance

- A command run with correlation id `C` produces events whose `correlationId` is `C`, and
  `findByCorrelation C` returns every event of the workflow across aggregates and process
  managers within one Keiro service.
- `findCausationDescendants` from the first event of such a chain reaches its last event through
  the process-manager hops.
- A command run with no inbound id receives a fresh correlation id, never null.
- Events recorded before the change load and replay unchanged.
- A test in Keiro or in keiro-runtime-kenshou demonstrates both queries over a
  process-manager-driven chain.


## Requested Deliverables

- The `RunCommandOptions` field and a boundary propagation helper.
- The codec and process-manager changes.
- A documentation section on correlation and causation semantics, including how a caller seeds
  the id and how an observer queries by it.
- A changelog entry and the roadmap reconciliation.


## Related Decisions

- The Shōko specification's "Correlation Strategies" section, which distinguishes `ByExecutionId`
  from `ByBusinessKey` and makes the former depend on this request:
  `mori://shinzui/shoko`, `docs/intial-spec.md`. An artifact-level Mori URI for that document
  is pending, so the canonical project URI and the repository-relative path are given together.
- `mori://shinzui/shoko/okf/research/concepts/RES-1`, the specification validation that
  surveyed Keiro, Kiroku, and the legacy services.
