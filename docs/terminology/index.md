---
okf_version: "0.2"
---

# Keiro terminology

Use this catalog for Keiro technical terms. Each definition gives one project-specific meaning. Detailed references supply API and operational information.

Use [stream](stream.md) for stored event history. Use [event stream](event-stream.md) for Keiro's aggregate contract. Use [read model](read-model.md) for query data and [projection](projection.md) for its update logic.

## Definition writing policy

Use ASD-STE100 Issue 9 as the writing reference. Use short sentences, active descriptions, and imperative instructions. Define a term before its examples. Keep descriptive sentences within 25 words and procedural sentences within 20 words. Keep each paragraph within six sentences.

Treat catalog entries as project technical nouns. The definitions specify their meanings; they do not constitute the official ASD dictionary. Use the canonical title consistently. Preserve identifiers, code, filenames, and protocol values exactly. Keep deprecated entries and replacement links for terminology lookup.

The official rules and dictionary are not available for this revision. Full ASD-STE100 compliance remains unverified. Obtain the [official standard](https://www.asd-ste100.org/STE_downloads.html) before the final vocabulary and grammar review.

## Modeling and commands

- [command cycle](command-cycle.md) - A command cycle reconstructs aggregate state, evaluates a command, and appends resulting events with a concurrency check.
- [domain command outcome](domain-command-outcome.md) - A domain command outcome is the typed business result of a selected decision: acceptance, rejection, or an intentional no-op.
- [domain event](domain-event.md) - A domain event is a recorded business fact owned by a bounded context's internal model.
- [event stream](event-stream.md) - An event stream is Keiro's aggregate contract for command handling, event production, and state reconstruction.
- [global position](global-position.md) - A global position is a store-wide event cursor for ordering events across streams and tracking consumer progress.
- [guard](guard.md) - A guard is a condition that must hold before a transition can handle a command.
- [lifecycle state](lifecycle-state.md) - A lifecycle state is the named stage of an aggregate that determines which transitions are available.
- [register](register.md) - A register is a named, typed value that an aggregate retains alongside its lifecycle state.
- [stream](stream.md) - A stream is an ordered, append-only history of events for one aggregate instance or other entity.
- [stream category](stream-category.md) - A stream category is a named family of streams for event consumption.
- [stream version](stream-version.md) - A stream version is an event position within one stream that identifies the history seen by a command.
- [symbolic transducer](symbolic-transducer.md) - A symbolic transducer is a state-machine model for command conditions, state updates, emitted events, and replay.
- [transition](transition.md) - A transition is an aggregate rule that defines conditions, updates, emitted events, and the next lifecycle state for a command.

## Replay and evolution

- [codec](codec.md) - A codec defines event type identifiers, payload encoding, payload decoding, and schema versions.
- [fold version](fold-version.md) - A fold version is an application-maintained identifier for handwritten logic that reconstructs aggregate state from events.
- [hydration](hydration.md) - Hydration is reconstruction of aggregate state from stored events, optionally using a compatible snapshot.
- [replay audit](replay-audit.md) - A replay audit checks candidate behavior against stored event histories for replay failures and reconstructed-state changes.
- [replay safety](replay-safety.md) - Replay safety is the property that recorded events can reconstruct the durable state produced by command handling.
- [replay-only transition](replay-only-transition.md) - A replay-only transition reconstructs historical events without letting new commands select the retained behavior.
- [snapshot](snapshot.md) - A snapshot is aggregate state saved at a known stream version to reduce the events needed for reconstruction.
- [upcaster](upcaster.md) - An upcaster converts an older stored event payload to a format that the current application can decode.

## Read side

- [asynchronous projection](asynchronous-projection.md) - An asynchronous projection processes committed events independently of command handling.
- [checkpoint](checkpoint.md) - A checkpoint is a durable record of subscription progress through an event source.
- [external read contract](external-read-contract.md) - An external read contract is a versioned query interface for consumers outside a projection's process.
- [inline projection](inline-projection.md) - An inline projection updates its read model within the transaction that appends a command's events.
- [physical target](physical-target.md) - A physical target is an application-owned database table that a projection maintains.
- [projection](projection.md) - A projection is logic that updates a read model from recorded events.
- [projection catalog](projection-catalog.md) - A projection catalog declares projections, read models, event sources, target ownership, and rebuild boundaries.
- [projection generation](projection-generation.md) - A projection generation is a physical instance of a projection revision's data.
- [projection rebuild](projection-rebuild.md) - A projection rebuild reconstructs or reconciles derived data from retained event history and verifies it before service.
- [projection revision](projection-revision.md) - A projection revision is a declared schema and behavior version that can be deployed and rebuilt as one implementation.
- [promotion](promotion.md) - Promotion is the controlled action that makes verified rebuilt projection data available for service.
- [query freshness](query-freshness.md) - Query freshness is the policy that determines required projection progress before a read-model query runs.
- [read model](read-model.md) - A read model is a view of event-sourced data organized for application queries.
- [rebuild group](rebuild-group.md) - A rebuild group is a set of projection targets that must be rebuilt and returned to service together.
- [replay adapter](replay-adapter.md) - A replay adapter is projection logic that safely processes historical events during a rebuild.
- [subscription](subscription.md) - A subscription is a consumer that follows selected event history and processes available events.

## Coordination

- [process manager](process-manager.md) - A process manager is an event-sourced coordinator that reacts to events with commands or timers.
- [router](router.md) - A router is a stateless dispatcher that looks up command recipients in response to an event.
- [timer](timer.md) - A timer is a durable scheduled wakeup for a process or workflow.

## Durable workflows

- [awakeable](awakeable.md) - An awakeable is a durable workflow wait for an external result or cancellation.
- [child workflow](child-workflow.md) - A child workflow is a separately identified durable workflow started by another workflow.
- [continue-as-new](continue-as-new.md) - Continue-as-new is a workflow operation that starts a new journal generation with explicitly selected state.
- [durable workflow](durable-workflow.md) - A durable workflow is sequential code whose saved progress lets steps and waits resume after interruptions.
- [journal](journal.md) - A journal is the durable execution history that recovers workflow progress and supplies saved step results.
- [workflow step](workflow-step.md) - A workflow step is a named action whose saved result is reused when workflow execution resumes.

## Integration and delivery

- [dead letter](dead-letter.md) - A dead letter is a retained delivery failure that requires investigation before explicit replay.
- [idempotency](idempotency.md) - Idempotency is the property that repetition of an operation does not repeat its intended effect.
- [inbox](inbox.md) - An inbox tracks received messages so duplicate delivery does not repeat committed handler effects.
- [integration event](integration-event.md) - An integration event is a published business fact that forms a contract for consumers outside its owning bounded context.
- [transactional outbox](transactional-outbox.md) - A transactional outbox is durable message storage whose enqueue commits atomically with its associated database changes.

## Work queues

- [job](job.md) - A job is a declared kind of background work with a queue, payload format, ordering contract, and retry policy.
- [work queue](work-queue.md) - A work queue is a durable queue of jobs for background processing by a service.

## DSL tooling

- [Cabal fragment](cabal-fragment.md) - A Cabal fragment is generated Haskell build configuration for inclusion in a package's Cabal file.
- [conformance ledger](conformance-ledger.md) - A conformance ledger is tool-maintained generation history for a service's conformance test package.
- [conformance record](conformance-record.md) - Conformance record is a deprecated name for conformance ledger.
- [create-once file](create-once-file.md) - A create-once file is a file that scaffolding creates initially and preserves on subsequent runs.
- [implementation hole](implementation-hole.md) - An implementation hole is an explicit boundary where application code supplies behavior outside the keiro-dsl specification.
- [mapped type](mapped-type.md) - A mapped type is a keiro-dsl declaration that connects a specification type to an existing application-owned Haskell type.
- [scaffold ledger](scaffold-ledger.md) - A scaffold ledger is tool-maintained generation history that tracks service files and their ownership.
- [scaffold record](scaffold-record.md) - Scaffold record is a deprecated name for scaffold ledger.
- [sidecar](sidecar.md) - A sidecar is a supporting file that keiro-dsl generates alongside Haskell code.
- [structural binding](structural-binding.md) - A structural binding is a total conversion in both directions between an application-owned type and a DSL-declared structural shape.
- [workspace manifest](workspace-manifest.md) - A workspace manifest is authored configuration that groups keiro-dsl specifications into one service and declares generation settings.
