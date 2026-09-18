# Keiro User Documentation Log

## 2026-09-18
* **Update**: Describe `messageId` as opaque text derived deterministically by `enqueueProducerEventTx` as `<prefix>_v1_<sha256-hex>`, with explicit callers owning their identity policy.
* **Update**: Fix the `runInboxTransaction` example's missing metrics argument and add a Delegated idempotence section for `runInboxDelegated` and `Keiro.Inbox.Delegated`.
* **Update**: Document delegated inbox wrappers, the guarded PGMQ DLQ API, `FifoHeads` job ordering, partition validation, pgmq 0.6 requirements, `keiro-ops pgmq dlq` commands, and candidate Language 6 DSL AST changes in the API reference.
* **Update**: Add a PGMQ dead-letter queue runbook for `keiro-ops pgmq dlq`, stating that `--force` does not bypass the hidden-row purge refusal.
* **Update**: Correct `new` starters to stable Language 5 and note the appended `processReactions` key in the check report.
* **Update**: Add a Reactions section to process managers and timers, document `cancelTimerTx`, and drop the stale unreleased note on timer inspection reads.
* **Update**: Note that reaction process managers key dispatch ids by target stream and occurrence, so migrating a manager requires a drain.
* **Update**: Add deploy-ordering rules for `FifoHeads` and the PGMQ 1.12 requirement, the deterministic producer message-ID cutover (ADR-42), and switching an intake between table and delegated idempotence.
* **Update**: List process reactions, delegated inbox intake, replay-safe producer identity, `FifoHeads` batching, and guarded DLQ purge in production status and the roadmap, restating the baseline as the published 0.17.0.0 line with Language 6 as a candidate.
* **Update**: Extend the outbox worked example with the producer subscription step that enqueues, condemns on identity conflict, and records the enqueue outcome.
* **Update**: Replace local sibling-package instructions in getting started with Hackage dependencies on the 0.17.0.0 release.
* **Update**: Name `keiro-migrations 0.2.0.0` as the release that introduced the dedicated keiro schema and list the upgrade guide in the README.
* **Update**: Document stable-language skeletons, framed UTF-8 reaction timer identity, canonical fingerprints, and reaction drain metadata.
* **Update**: Document that `ordering fifo-heads` is Language 6 candidate syntax refused by published languages.
* **Update**: Document guarded DLQ inspection, exact-ID archive verification, guarded and forced purge, and original-header redrive behavior.
* **Update**: Document delegated intake syntax, diff denial policy and guard diagnostics, intake identity changes, and the current skeleton language.

## 2026-09-17
* **Update**: Document generated and consumer-bound enum structural leaves, exact declared
wire spellings, constructor defaults, and declaration-scoped arm coverage.
* **Update**: Document surface-specific nominal leaf consequences and historical parity evidence during mapped adoption.
* **Update**: Document nominal leaf codec authority and compatibility duties for opaque-or-Text migrations.
* **Update**: Document candidate Language 6 nominal structural leaves, generated admission and conformance, coverage and diff contexts, and opaque-ID migration.

## 2026-09-16
* **Update**: Document reaction version/fingerprint drain rules and timer removal, identity, payload, and ceiling rollout consequences.
* **Update**: Document generated reaction-manager usage, the typed decoder Hole, runtime Reaction wiring, and transactional cancelTimerTx lowering.
* **Update**: Document candidate Language 6 process reactions, generated ownership, timer semantics, and every reaction validation and evolution diagnostic.

## 2026-09-15
* **Update**: Document delegated inbox receipt ownership, retry and DLQ obligations, cutover boundaries, and measured tradeoffs.

## 2026-09-14
* **Update**: Document the drain required when adopting or changing the process-reaction dispatch identity family.
* **Update**: Document the additive process-manager reaction API, result distinctions, phase boundaries, replay behavior, and transactional timer cancellation.
* **Update**: Document pgmq-hs 0.6 partition premake and default-partition metrics

## 2026-09-10
* **Update**: Point the keiro-ops runbook at ADR-40's inspection-surface boundary (IR-32).

## 2026-09-08
* **Update**: Document guarded timer resume consumer lifecycle, lease recovery, and deployment ordering.
* **Update**: Document reason-preserving timer inspection, bounded literal filters, UUID pagination, and caller authorization.

## 2026-08-26
* **Addition**: Adopt the shared user-documentation profile for the Keiro user guide and assign stable document handles.
