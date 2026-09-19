---
okf_version: "0.2"
---

# Keiro terminology

This glossary is for developers familiar with event sourcing who are learning Keiro.
Definitions start with the concept; linked guides cover APIs and operational details.

Start with [stream](stream.md) and [event stream](event-stream.md): Keiro uses the latter
for an aggregate contract. [Read model](read-model.md) and [projection](projection.md)
distinguish a queryable view from the logic that updates it. For coordination, compare
[process manager](process-manager.md), [router](router.md), and
[durable workflow](durable-workflow.md). The keiro-dsl file terms describe development
tooling rather than runtime event processing.


## Modeling and commands

- [command cycle](command-cycle.md) - The process of rebuilding an aggregate's state, evaluating a command, and saving any resulting events while checking for concurrent changes.
- [domain command outcome](domain-command-outcome.md) - The business result of a selected command decision, distinguishing acceptance, rejection, and an intentional no-op.
- [domain event](domain-event.md) - A recorded business fact that belongs to a bounded context's internal model, such as an order being placed or a payment being received.
- [event stream](event-stream.md) - Keiro's aggregate contract, defining how one kind of aggregate handles commands, produces events, and reconstructs state from its history.
- [global position](global-position.md) - A store-wide event position used to order events across streams and track consumer progress.
- [guard](guard.md) - A condition that must hold for an aggregate transition to handle a command.
- [lifecycle state](lifecycle-state.md) - The named stage an aggregate currently occupies, used to determine which transitions are available.
- [register](register.md) - A named, typed value remembered by an aggregate alongside its lifecycle state.
- [stream](stream.md) - An ordered, append-only sequence of events recording the history of one aggregate instance or other entity.
- [stream category](stream-category.md) - A named family of streams that can be selected together for event consumption.
- [stream version](stream-version.md) - The position of an event within one stream, used to identify the history seen by a command.
- [symbolic transducer](symbolic-transducer.md) - A state-machine model that describes command conditions, state updates, and emitted events in a form that can also support replay.
- [transition](transition.md) - A rule describing how an aggregate handles a command from a particular lifecycle state, including conditions, updates, events, and the next state.

## Replay and evolution

- [codec](codec.md) - The rules for converting application events to stored data and reading stored events back, including support for older event formats.
- [fold version](fold-version.md) - An application-maintained version identifying hand-written logic that reconstructs aggregate state from events.
- [hydration](hydration.md) - Reconstructing an aggregate's current state from its stored events, optionally starting from a compatible snapshot.
- [replay audit](replay-audit.md) - A check that runs candidate application behavior against stored event histories to detect replay failures or changes in reconstructed state.
- [replay safety](replay-safety.md) - The property that recorded events contain enough information to reconstruct the durable state produced by command handling.
- [replay-only transition](replay-only-transition.md) - An aggregate transition retained to reconstruct historical events without allowing new commands to select that behavior.
- [snapshot](snapshot.md) - A saved copy of an aggregate's state at a known stream version, used to rebuild current state without replaying its entire history.
- [upcaster](upcaster.md) - A conversion that brings an older stored event payload forward to a format understood by the current application.

## Read side

- [asynchronous projection](asynchronous-projection.md) - A projection that processes committed events in the background, allowing its read model to catch up independently of command handling.
- [checkpoint](checkpoint.md) - A durable record of how far a subscription has progressed through its event source.
- [external read contract](external-read-contract.md) - A versioned query interface that lets another process read a projection without depending on its private tables.
- [inline projection](inline-projection.md) - A projection that updates its read model in the same transaction that saves the command's events.
- [physical target](physical-target.md) - An application-owned database table maintained by a projection and declared as a unit of read-side ownership.
- [projection](projection.md) - Logic that turns recorded events into a read model by updating it as events are processed.
- [projection catalog](projection-catalog.md) - The application's declaration of its projections, query models, event sources, target ownership, and rebuild boundaries.
- [projection generation](projection-generation.md) - A physical instance of a projection's data, such as the serving tables or a candidate being built alongside them.
- [projection rebuild](projection-rebuild.md) - The process of reconstructing or reconciling derived data from retained event history and verifying it before serving it.
- [projection revision](projection-revision.md) - A declared version of a projection's schema and behavior that can be deployed and rebuilt as one coherent implementation.
- [promotion](promotion.md) - The controlled step that makes verified rebuilt projection data available for normal service.
- [query freshness](query-freshness.md) - The waiting policy applied before a read-model query runs, determining which projection progress it requires.
- [read model](read-model.md) - A view of event-sourced data organized for queries, such as an order summary or a list of overdue invoices.
- [rebuild group](rebuild-group.md) - A set of projection targets that must move through rebuilding and return to service together.
- [replay adapter](replay-adapter.md) - Projection logic specifically intended to process historical events safely during a rebuild.
- [subscription](subscription.md) - A consumer that follows a selected event history and processes events as they become available.

## Coordination

- [process manager](process-manager.md) - An event-sourced coordinator that remembers the progress of a business process and reacts to events by sending commands or scheduling timers.
- [router](router.md) - A stateless dispatcher that reacts to an event by looking up recipients and sending commands to their streams.
- [timer](timer.md) - A scheduled wakeup that survives application restarts and lets a process react when a deadline is due.

## Durable workflows

- [awakeable](awakeable.md) - A durable wait for an external result, allowing a workflow to pause until another part of the system signals or cancels it.
- [child workflow](child-workflow.md) - A separately identified durable workflow started by another workflow, which can wait for its completion.
- [continue-as-new](continue-as-new.md) - A workflow operation that starts a fresh journal generation while carrying forward explicitly chosen state.
- [durable workflow](durable-workflow.md) - A long-running process written as a sequence of steps and waits whose progress is saved so it can resume after interruptions.
- [journal](journal.md) - The durable execution history of one workflow instance, used to recover its progress and reuse recorded step results.
- [workflow step](workflow-step.md) - A named action in a durable workflow whose result is saved and reused when execution resumes.

## Integration and delivery

- [dead letter](dead-letter.md) - A saved record of a delivery that will no longer be retried automatically, kept for investigation and possible replay.
- [idempotency](idempotency.md) - The property that repeating an operation does not repeat its intended effect.
- [inbox](inbox.md) - A receiving-side mechanism that tracks processed messages so duplicate deliveries do not repeat their committed effects.
- [integration event](integration-event.md) - A published business fact designed as a stable contract for consumers outside the bounded context that produced it.
- [transactional outbox](transactional-outbox.md) - A durable record of messages waiting to be published, saved transactionally so a crash cannot lose the handoff to a separate publisher.

## Work queues

- [job](job.md) - A declared kind of background work, combining its queue, payload format, ordering contract, and retry policy.
- [work queue](work-queue.md) - A durable queue of jobs for background processing by a service.

## DSL tooling

- [Cabal fragment](cabal-fragment.md) - Generated Haskell build configuration to copy into a package's Cabal file so it can build the generated modules.
- [conformance ledger](conformance-ledger.md) - A tool-maintained history of the generated test package used to check a service against its keiro-dsl specification.
- [conformance record](conformance-record.md) - A deprecated name for the conformance ledger, the tool-maintained history of a generated conformance test package.
- [create-once file](create-once-file.md) - A file scaffolding creates initially and then preserves on later runs so developers can maintain its contents.
- [implementation hole](implementation-hole.md) - An explicit place where application code supplies behavior that the keiro-dsl specification leaves hand-written.
- [mapped type](mapped-type.md) - A keiro-dsl declaration that connects a specification type to an existing application-owned Haskell type.
- [scaffold ledger](scaffold-ledger.md) - A tool-maintained history of generated service files that keiro-dsl uses to detect changes and track file ownership on later runs.
- [scaffold record](scaffold-record.md) - A deprecated name for the scaffold ledger, the tool-maintained history of generated service files.
- [sidecar](sidecar.md) - A supporting file generated alongside Haskell code by keiro-dsl, containing generation history or build guidance.
- [structural binding](structural-binding.md) - A total conversion in both directions between an application-owned type and the structural shape declared by keiro-dsl.
- [workspace manifest](workspace-manifest.md) - An authored configuration file that groups several keiro-dsl specifications into one service and declares how to generate that service.
