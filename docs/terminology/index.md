---
okf_version: "0.2"
---

# Term

- [asynchronous projection](asynchronous-projection.md) - A projection driven by a subscription after the append commits, delivered at least once, so its write handlers must be idempotent.
- [awakeable](awakeable.md) - A durable wait inside a durable workflow, identified by an opaque random id that an external system uses to signal a result or cancel the wait.
- [Cabal fragment](cabal-fragment.md) - The human-facing sidecar holding the Cabal stanza text a person pastes into the consuming package to build generated modules.
- [codec](codec.md) - The finite registry of legal stored event type tags for one event type, with the encoder, decoder, schema version, and upcasters that carry events across the storage boundary.
- [command cycle](command-cycle.md) - The sequence keiro runs for one command: resolve the stream, hydrate and replay its events through the transducer, step the transducer with the command, encode and append the produced events with optimistic concurrency, and optionally write a snapshot.
- [conformance ledger](conformance-ledger.md) - The machine-owned sidecar inside an enabled conformance package that records the package's history as typed rows that tolerate unknown row kinds and keys.
- [conformance record](conformance-record.md) - The former name of the conformance ledger, retired by ADR-22 together with its whitespace-split format.
- [dead letter](dead-letter.md) - A durable record of a delivery that keiro stopped retrying, kept so an operator can inspect it and replay it idempotently.
- [domain event](domain-event.md) - A private fact recorded in one stream of one bounded context, free to change shape as that context's model evolves.
- [durable workflow](durable-workflow.md) - A long-running process written as an ordinary imperative function whose named steps are journaled, so it can suspend and resume by re-running from the top while replaying completed steps.
- [event stream](event-stream.md) - The aggregate contract an application declares once per aggregate type: a Keiki symbolic transducer with its initial state and registers, an event codec, a stream-name resolver, and a snapshot policy.
- [inbox](inbox.md) - The receiving side of integration delivery, which runs a local handler at most once per integration event by recording a deduplication key in the handler's own transaction.
- [inline projection](inline-projection.md) - A projection applied in the same transaction as the command append whose events it reads, so a reader that sees the events also sees their effect.
- [integration event](integration-event.md) - A stable public message that carries a fact from one bounded context to another over a transport such as Kafka, in keiro's `IntegrationEvent` envelope.
- [journal](journal.md) - The event stream of one durable workflow instance, recording each completed named step and the workflow's terminal or rotation marker so a resumed run can replay them.
- [process manager](process-manager.md) - An event-sourced coordinator that reacts to source events, advances its own state stream, emits commands to target streams, and schedules timers, computing its targets purely from its own state.
- [projection](projection.md) - A handler that folds events into one or more read-model tables, owned by exactly one projection definition in the application's projection catalog.
- [read model](read-model.md) - A query-optimized view derived from the event log, declared as a `ReadModel q r` with a name, version, shape hash, table, subscription, default consistency mode, and a query transaction.
- [router](router.md) - A stateless dispatcher that resolves its command targets effectfully, for example from a read model, and reuses the process manager's dispatch with exactly-once-per-target idempotency.
- [scaffold ledger](scaffold-ledger.md) - The machine-owned sidecar that records a service's scaffold history, including its generated paths, mapped provenance, and ownership, and that every later scaffold run reads.
- [scaffold record](scaffold-record.md) - The former name of the scaffold ledger, retired by ADR-22 because the file is machine-owned history rather than a record for a person.
- [sidecar](sidecar.md) - A file that keiro-dsl scaffolding writes beside generated Haskell, whose name states whether it is machine-owned history or text for a person.
- [snapshot](snapshot.md) - An advisory persisted `(state, registers)` seed for one stream at a known version, from which hydration replays only the tail of the stream.
- [stream](stream.md) - An ordered, append-only sequence of events that records the history of one entity, addressed in Haskell by a typed `Stream a` handle over a Kiroku stream name.
- [timer](timer.md) - A durable scheduled wakeup stored in `keiro_timers`, claimed by a timer worker when due and fired at least once into application code.
- [transactional outbox](transactional-outbox.md) - A durable handoff that records each outgoing integration event in the same transaction as its source checkpoint, then publishes it at least once from a separate worker.
- [workspace manifest](workspace-manifest.md) - The authored `.keiro-workspace` file that declares one service split across several complete `.keiro` sources, with its stable service identity, runtime package, module, layout, and member specs.
