# Keiro Guides Log

## 2026-09-18
* **Update**: Integration Events With Kafka corrects the delegated-intake sample to handle `DelegatedCommandError` and documents replay-safe derived producer message IDs, enqueue outcomes, and the ADR-42 cutover.
* **Update**: Work Queues documents the required five-field `Job` with `jobOrdering` validation, `FifoHeads` per-group guarantees and version requirements, and archive-then-purge DLQ operations.
* **Update**: Project Read Models ties the deprecated `Eventual`/`EntireLog` fields to retirement of the frozen Language 4 generator.
* **Update**: Process Managers And Timers adds `Keiro.Timer.cancelTimerTx` for hand-written managers that cancel a timer atomically with an append.
* **Update**: Coordinating Incident Response notes that an accepted-only `FollowCancel` can retire the escalation timer on acknowledgement while the aggregate guard still handles late firings.
* **Update**: Order Fulfillment Overview corrects the Jitsurei example test count to twenty-five.
* **Update**: Evolution And Replayability fixes the plan 224/225 links and adds 0.17 gates for producer name/source/messageIdPrefix identity, reaction dispatch/timer/version identity, delegated-intake idempotence, and fifo-heads ordering changes.
* **Update**: Choosing keiro-dsl scopes `ProcessHoles` to Languages 1–5, describes the candidate Language 6 decoder-only reaction hole and structural nominal features, and explains what opting into candidate Language 6 means.
* **Update**: Brownfield Migration adds a candidate Language 6 section on keeping domain IDs and enums inside structural shapes, keyed maps, declared contract IDs, and the `Optional DeclaredId` wrapper.
* **Update**: The Guarantee Ledger replaces stale evolution-guide line-number citations with heading links.
* **Update**: Guides README lists the four previously unlisted guides and refreshes descriptions for reactions, deterministic producer IDs, the delegated inbox, `FifoHeads`, and candidate Language 6.

## 2026-09-16
* **Update**: Add generated Language 6 timer-free and multi-reaction escalation examples with the decoder-Hole and late-fire boundaries.

## 2026-09-15
* **Update**: Add Kafka consumer guidance for candidate Language-6 delegated intake and downstream command receipts.

## 2026-09-14
* **Update**: Add handwritten reaction once/worker guidance, transaction and replay semantics, timer limits, and identity cutover steps.

## 2026-08-26
* **Addition**: Adopt the shared user-documentation profile for the Keiro guides and assign stable document handles.
