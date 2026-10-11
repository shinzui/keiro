---
id: 306
slug: support-atomic-relational-preconditions-for-synchronous-catalog-commands
title: "Support atomic relational preconditions for synchronous catalog commands"
kind: exec-plan
created_at: 2026-10-11T20:55:42Z
intention: "intention_01m4pbzn0feettj188pac22p2e"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-11T20:55:42Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-11T21:00:31Z
      mode: "other"
      note: "Draft the five-milestone IR-53 plan with serving-aware guards, same-database race evidence, and mixed-workload performance budgets"
---

# Support atomic relational preconditions for synchronous catalog commands


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current during implementation.
Promote durable decisions into the relevant ADRs when the implementation is
verified. This document plans work; it records no implementation or benchmark
success and does not authorize publication or downstream deployment.


## Purpose / Big Picture


Deliver [IR-53](../improvement-requests/support-atomic-relational-preconditions-for-catalog-domain-commands.md): let an application create one aggregate only if a relational identity is still absent, while retaining Keiro's synchronous projection, transaction, and rebuild guarantees. In the motivating note example, two concurrent callers propose different note IDs for the same anchor/property/state identity. Exactly one creation event and note commit. Both callers receive the winning ID, with one reporting creation and the other reuse. Repeating the operation, including for an archived note, preserves the first content, tags, and provenance.

The extension is an opt-in sibling of `runDomainCommandWithCatalogProjections`. A synchronous or inline projection updates its SQL tables in the event append transaction. An asynchronous projection runs later in a subscription worker; it is outside this extension. The guard is a consumer-owned SQL precondition, not another aggregate command or a new domain decision evaluator.

The implementation is acceptable only with concurrency, rollback, catalog lifecycle, and performance evidence. A check after append holds Kiroku's global append lock longer and can slow unrelated writers. The plan intentionally measures that cost before considering a larger pre-append locking protocol. No package version, release tag, or downstream pin is selected here.


## Progress


- [ ] M1: Establish dependency/transaction evidence and capture the ordinary catalog baseline.
- [ ] M2: Add the guarded public API with fence-first callbacks and shared delivery internals.
- [ ] M3: Prove same-database races, retries, rollback, and serving-revision protection.
- [ ] M4: Measure guarded and mixed traffic against the fixed regression budgets.
- [ ] M5: Publish the public recipe, distill ADR decisions, and run the final repository checks.


## Surprises & Discoveries


(None recorded during implementation yet.)


## Decision Log


2026-10-11 — Owner discussion selected a small opt-in synchronous catalog runner. Rei owns identity lookup and duplicate-to-reuse policy; Keiro owns transaction rollback, catalog fences, and delivery. Existing runners retain their signatures, outcomes, and SQL/lock counts.

2026-10-11 — Resolve all catalog fences and serving bindings before invoking the guard. The earlier exploratory prototype invoked the guard first, allowing duplicate refusal to mask an unavailable catalog and permitting a lookup without lifecycle protection. The prototype is evidence to inspect, not a patch to cherry-pick.

2026-10-11 — Initially rely on the documented Kiroku `$all` append serialization and `ReadCommitted` statement snapshots. Every live writer affecting the invariant must participate in that protocol, and catalog reconstruction must obey the catalog fences. The API does not claim to protect arbitrary external SQL or lagging subscription projections.

2026-10-11 — Supply an opaque guard context exposing the already resolved public `ProjectionWriteBinding` values. A bare transaction closure is insufficient guidance for a schema-changing serving revision. The context is available only after validation and introduces no second metadata lookup.

2026-10-11 — Measure overhead against explicit initial budgets derived from the nearby projection benchmark's throughput/p95 convention, with a separately stated p99 budget below. These are engineering acceptance targets, not measured results or a production service-level agreement. Do not silently relax them to make the implementation pass.

2026-10-11 — Moving the check before append, adding identity reservation tables, extending the DSL, changing asynchronous delivery, or changing Kiroku's global append architecture is deferred. Any such expansion requires a recorded design revision after evidence shows why this scope is insufficient.


## Outcomes & Retrospective


(To be filled during implementation. No runtime or performance result is claimed.)


## Context and Orientation


The inspected Keiro baseline is `2a38ee169d165c571a142cb47d08bab1e7ad7652`. Reconfirm paths and dependency behavior against the checkout being implemented. An aggregate stream is one entity's ordered event history. Optimistic concurrency control (OCC) compares the stream version expected by the caller with the version at append and retries a conflicting command from hydration, which reconstructs entity state from its history. Different note IDs name different streams, so OCC alone cannot establish a shared relational identity.

`keiro/src/Keiro/Command.hs` defines `SqlTransactionDecision`, `DomainSqlCommandOutcome`, `runDomainCommandWithSqlEventsControlled`, and `domainSqlCommandAttempts`. Accepted batches enter a transaction, call `appendToStreamTx`, then invoke a SQL callback. `RollbackSqlTransaction` condemns the entire transaction while retaining a typed value. Snapshot verification/advancement attributable to the accepted append happens only after commit. Selected domain rejection and no-op take the silent path and invoke no callback. `retryOrFail` bounds OCC attempts using `RunCommandOptions.retryLimit`; that setting does not bound Hasql's separate transaction retry loop.

`keiro/src/Keiro/Projection.hs` contains the public domain catalog runner and private `applyCatalogProjectionsTx`. The private helper both locks groups and delivers events. `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` defines `lockProjectionGroupsTx`, `ProjectionWriteFence`, and `ProjectionWriteBinding`. Distinct group rows are locked `FOR SHARE` in sorted order. These shared locks prevent lifecycle changes while permitting other ordinary writers; they are not the identity serialization mechanism. A fence is the typed refusal to write while catalog lifecycle or serving bindings are unavailable. Keep the exact existing distinctions, including the current handling of failed/offline groups, rather than inventing a new generic fence error.

`keiro/src/Keiro/Projection/Catalog.hs` exports `PhysicalTargets`, `QualifiedTable`, `resolvePhysicalTarget`, and revision-specific live handlers. A serving revision is the code/schema version currently receiving live writes. Its physical targets are the actual tables selected for that revision. An online rebuild populates separate candidate tables while the old revision serves; promotion atomically selects the new generation. The guard must read the protected serving generation, and accepted events must reach the same bindings. A guard is not re-run during event replay: the committed creation event must carry enough identity and payload to reconstruct the note.

The dependency is `mori://shinzui/kiroku/packages/kiroku-store`, currently bounded by `^>=0.10.0.0` in `keiro/keiro.cabal`. Its `Kiroku.Store.Transaction.appendToStreamTx` contract documents an update of the global `$all` row and retention of that row lock through commit or rollback. Its runner uses `ReadCommitted`, under which each subsequent SQL statement sees commits preceding that statement. Thus a loser waiting on append serialization can query the committed winner afterwards. This proof depends on a separate guard statement after the append, the same database/store schema, synchronous identity updates, and all relevant live writers participating. Reads performed before append or in the same append statement's old snapshot do not inherit the proof. Existing catalog maintenance supplies its separate lifecycle protection. Locate dependency code with Mori, never by traversing `/nix/store`.

The consumer requirement belongs to `mori://shinzui/rei/plans/249-expose-categories-and-custom-properties-with-shared-typed-assignment-semantics`, coordinated by `mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract`. This plan delivers a runnable Rei-shaped example inside Keiro and a public adoption recipe. Actual Rei package changes and deployment are separate downstream work. The old unapproved local prototype is commit `3f9aba4e`; it checks the guard before the catalog fence and lacks the required full evidence. Its historical plan number is not this plan's identity.

Relevant architecture context is [ADR-29](../adr/0029-typed-domain-decisions-are-successful-additive-command-outcomes.md), which keeps selected domain decisions separate from command faults and forbids fabricated acceptance on rollback; [ADR-26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md), which gives the catalog one projection owner and makes application SQL an explicitly unchecked boundary; and [ADR-34](../adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md), which requires live delivery to use persisted serving revisions and physical generations under a group lock. The extension must preserve these decisions. The callback type cannot statically prove a query is bounded or that arbitrary SQL obeys ownership.

`keiro/test/Main.hs` has existing domain command/catalog rollback and retry fixtures. `keiro/test/VersionedRebuildSpec.hs` supplies versioned lifecycle patterns. Add focused cases in `keiro/test/GuardedCatalogSpec.hs` and a reusable public-API note example in `keiro/test/GuardedCatalogExample.hs`, wiring both into `keiro/keiro.cabal` and `Main.hs`. `keiro-test-support/src/Keiro/Test/Postgres.hs` starts ephemeral PostgreSQL, migrates once, and clones a database per test. Its `withFreshStores2` opens two different databases and must not be used for this race. Use `withFreshDatabase` to get one connection string and open two independent resource-aware stores against it, factoring a same-database helper if needed.

Existing measurements live in `keiro/bench/Main.hs` and `keiro/bench/ReadModelBench.hs`. The latter already uses warmed alternating samples because sequential growing-store measurements can be misleading. Add `keiro/bench/GuardedCatalogBench.hs` with its own opt-in evidence mode, keeping benchmark instrumentation out of production code.


## Plan of Work


### Milestone 1: Establish the transaction contract and ordinary baseline


Before production edits, verify the installed dependency source through Mori and record the actual Kiroku, Hasql transaction, PostgreSQL, compiler, and source revisions used. Read `appendToStreamTx`, its SQL implementation, and the transaction interpreter to confirm the `$all` update and snapshot/retry behavior. If a dependency bound change becomes necessary, verify the current registry release and upstream tag first; the local corpus alone is not version authority. No bound change is expected.

Build the same-database test helper and an ordinary catalog benchmark fixture with a fixed-size indexed note identity table, distinct note streams, realistic content/tags, and both one-event and multi-event batches. Record baseline ordinary runner SQL/lock counts and warmed throughput/p95/p99 before refactoring. The benchmark module and cabal registration can land before the guarded API so its ordinary mode runs on this baseline. Save raw evidence under `keiro/bench/results/guarded-catalog/` with machine/tool versions, workload inputs, and commit IDs. Verify two overlapping transactions have distinct PostgreSQL backend PIDs but the same database and schema. Run `keiro-test` and the ordinary benchmark mode described below. Acceptance is a reproducible baseline and a connection fixture that demonstrably tests contention in one store, without a runtime behavior change.


### Milestone 2: Implement the additive guarded runner


In `keiro/src/Keiro/Projection.hs`, extract the existing event delivery loop into a private helper that accepts the bindings already obtained by `lockProjectionGroupsTx`. Keep `applyCatalogProjectionsTx` as the current lock/validate/apply composition for existing callers. The new runner uses the same validation and delivery helper, but invokes the consumer guard between them. It must acquire each existing group lock only once and retain stable group ordering.

Add the result and callback context described in Interfaces and Dependencies. Reuse `runDomainCommandWithSqlEventsControlled`; do not implement a second hydrate/decide/append/OCC loop. Preserve early projection-set/catalog mismatch handling. Map silent domain outcomes and all existing catalog outcomes through the new wrapper. A guard refusal carries no `CommandResult` or `DomainAccepted` value. An invalid catalog returns its existing catalog outcome before the guard runs. A successful guard applies the complete ordered batch using exactly the bindings handed to the guard.

Preserve the old runners' allocation paths where practical; do not route every existing caller through new result wrappers solely to avoid a few mapping lines. Share the correctness-sensitive delivery implementation, not a second copy of revision dispatch. The guard context is callback-scoped information, not a transferable lock lease: document that retained bindings have no authority in another transaction.

Add focused rollback, acceptance, and silent-decision tests. Include a guard that writes a transactional marker and refuses; neither marker nor event batch nor projections may remain. Inject a SQL failure and verify it remains an operational fault. Use existing rollback telemetry: do not label a refused append accepted or rejected by the pure domain, and never render the refusal payload into logs, span attributes, or metric dimensions. Build `keiro:lib:keiro` and run the focused Hspec group. Acceptance is a usable public API with the original runner tests still passing and no added SQL on the old path.


### Milestone 3: Prove the identity and catalog lifecycle behavior


Implement `ensureStateNoteExample` in `keiro/test/GuardedCatalogExample.hs` using only public APIs. Use the composite `(anchor type, anchor ID, property definition ID, state ID)` identity and separate candidate stream IDs. Query the indexed synchronous table from the guard, including archived notes; return `ExistingNote noteId` as the refusal payload and map it to `(noteId, False)`. Accepted creation returns `(candidateId, True)`. Never convert a general SQL/codec/store error to reuse. Keep the unique index. Creation facts contain the winning identity/content/tags/provenance so normal replay reconstructs the table without invoking the command guard. Explicitly document the consumer's policy for deletion/re-anchoring and legacy qualifiers rather than suggesting that the framework invents one.

Race two independent resource stores connected to the same test database, using different candidate IDs and payloads for one identity. Synchronize starts outside the SQL callback. For deterministic lock-wait evidence, use a third observer/controller connection and a bounded test-only SQL gate or PostgreSQL lock observation; do not insert arbitrary IO into a transaction callback or rely only on sleeps. Give every worker and observer a timeout and release gates in cleanup. Observe one committed creation, one projected note, identical returned IDs, and exactly one changed result. Reverse which caller starts first and test winner rollback so a waiting caller can become the winner. Repeat on an archived note and inspect content, tags, and provenance, not only row counts.

For refusals, inspect source stream events, `$all` links, callback markers, inline projection rows, snapshots, and fixture outbox/reactor markers attributable to the losing batch. No losing effects may commit and projection handlers must not execute. Exercise multi-event acceptance, OCC retry followed by a fresh guard result, retry followed by a silent decision, exhaustion, encode failure, unmatched command, and genuine query failure. Use backend-local instrumentation or SQL observer evidence where callback invocation itself must be proved; rollback of a marker alone cannot prove the callback never ran. Preserve Hasql transaction retry semantics and document that `retryLimit` applies to the outer OCC loop only.

Test a guard designed to refuse against missing, offline rebuilding, failed, mismatched, unknown-serving-revision, and invalid-serving-binding cases: the catalog outcome wins and the guard does not execute. Extend versioned fixtures to hold a guarded writer while another connection attempts promotion; after release, either the writer completes against the protected old revision before promotion or is fenced/re-evaluated through a new call. A later successful call resolves the promoted revision. The guard and handler must observe the same physical generation and revision, never the candidate or retired table. Run a rebuild of the winning note and verify retained identity and payload.

Use the focused test command below and the full `keiro-test` suite. Acceptance is the complete behavior matrix with independent-connection evidence, not merely sequential duplicate calls or one successful race.


### Milestone 4: Measure the global append cost


Extend `GuardedCatalogBench.hs` with unguarded, empty-success-guard, indexed-miss, indexed-hit/refusal, and mixed traffic modes. Measure one and eight concurrent connections. Seed and analyze the identity index before timing, warm each case, then collect at least five alternating paired runs of 10,000 completed attempts per case with equivalent initial database size and bounded setup outside timing. Count attempts, accepted batches, refused batches, and committed events separately: duplicate reuse has fewer committed events and must not masquerade as increased append throughput. Fail on unexpected outcomes or timeouts rather than omitting samples.

The required mixed workload is 80% ordinary commands and 20% guarded ensure attempts. Run guard duplicate rates of 0%, 50%, and 100%, with both repeated shared identities and distributed identities. Compare to the same concurrency and 80/20 command/batch mix in an unguarded all-unique control, acknowledging the different commit counts. This control measures the added cost of offering the stronger operation, not semantic equivalence of duplicate handling. Also compare unchanged ordinary callers before/after the refactor and compare empty-success guards with the ordinary API on identical all-unique data.

Before collecting candidate results, persist these initial budgets in the harness configuration and report: the ordinary-only refactor must retain at least 95% of baseline attempt throughput and keep p95/p99 within 1.10 times baseline; empty-success guards and indexed all-unique guards must retain at least 90% throughput and keep p95 within 1.25 times and p99 within 1.50 times the comparable ordinary control. In each required mixed case, overall attempt throughput must retain at least 90% of its control, and the ordinary cohort's p95/p99 must stay within 1.25/1.50 times its control cohort. Judge the median of paired run ratios and report every run, spread, sample count, and absolute latency as well. Repeat a noisy comparison with an explained cause rather than selecting favorable runs. These targets are initial engineering budgets; a failure prevents a performance-ready conclusion until design changes or an explicit owner-reviewed budget revision.

Use a separate diagnostic run to collect PostgreSQL lock-wait evidence and guard/post-append duration with test-only instrumentation. Report what is directly measured versus an upper bound or proxy for `$all` hold time. Do not put extra timing statements into the measured production path. Verify that the identity query uses an index at representative cardinality with `EXPLAIN (ANALYZE, BUFFERS)` outside the timing loop. Include a deliberately slow test guard to demonstrate that the harness detects ordinary-writer degradation; this diagnostic is not a supported workload or a passing performance sample.

If the post-append design fails, first eliminate extra SQL, incorrect query plans, or redundant fence work. Do not silently move a SELECT before append. A pre-append alternative requires a revised plan with a shared identity lock/reservation protocol, participation by every writer, and deadlock-safe ordering relative to append and catalog locks. Acceptance is archived raw measurements and a computed pass/fail report, with no claim that correctness tests establish performance.


### Milestone 5: Document the supported boundary and finish validation


Add `docs/guides/guarded-catalog-commands.md` following the existing guide frontmatter/profile conventions. Explain the transaction order, result matching, context-based physical table resolution, archived reuse, synchronous authority, writer participation, replay behavior, lock costs, and separate OCC/driver retries. Include the compiled Rei-shaped example and identify any additional downstream adoption work through its canonical Mori plan URI. Package publication and actual Rei dependency updates remain separate work.

Update the unreleased section of `keiro/CHANGELOG.md`, export the new API consistently with `keiro/src/Keiro.hs`, and update ADR-29 for transactional refusal versus pure domain decisions and ADR-26/ADR-34 for guarded serving-target access and the unchecked SQL boundary. Keep their existing stable `docId` values, update meaningful revision timestamps, and add bundle log entries. Do not claim arbitrary callbacks are automatically safe or bounded. Update IR-53 and this plan with real test/benchmark evidence and remaining downstream obligations; do not mark downstream adoption complete based on the local example.

Run the full affected test suite, normal command/projection benchmark guards, public re-export checks, and strict documentation validation. Review the final diff for unrelated changes and dependency/version bumps. Distill the global-lock and fence-order lessons into the ADRs before marking this implementation plan complete. Acceptance is the documented, tested, measured additive feature and a clear release/adoption handoff, not publication.


## Concrete Steps


Run commands from the Keiro repository root. Use the repository's Nix development environment for Cabal and PostgreSQL tools; tests start isolated ephemeral databases and do not require a running production database. Use an already active development shell instead of nesting `nix develop` when appropriate. No command should search `/nix/store` or the filesystem root.

```bash
mori registry search kiroku-store
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
mori path mori://shinzui/kiroku/packages/kiroku-store
mori registry search hasql-transaction
mori registry show hasql/hasql --full
mori registry docs hasql/hasql
```

Read the located dependency modules directly. Before choosing any new dependency bounds, check the package's authoritative Hackage preferred versions and upstream release tags; record the exact results here. No dependency selection is made by the discovery commands.

```bash
nix develop -c cabal build keiro:lib:keiro keiro:test:keiro-test keiro:bench:keiro-bench
nix develop -c cabal test keiro-test --test-show-details=direct --test-options='--match "guarded catalog commands"'
nix develop -c cabal test keiro-test --test-show-details=direct
```

The first focused command is meaningful after M2 registers that describe group; zero selected examples is a failure of this plan's validation. Expected final output includes executed guarded examples and zero failures. The full suite must pass as well.

Implement the following benchmark environment switches in M1/M4. They are proposed harness interfaces, not existing commands today. `ordinary` exits after baseline capture; `compare` runs candidate/control pairs and exits nonzero on a budget failure; `diagnostic` records lock behavior without using its instrumented samples for acceptance. Use unique run output directories to retain evidence.

```bash
nix develop -c env KEIRO_GUARDED_CATALOG_EVIDENCE=ordinary KEIRO_GUARDED_CATALOG_OUTPUT=bench/results/guarded-catalog/baseline cabal bench keiro-bench --benchmark-options='+RTS -N2 -RTS'
nix develop -c env KEIRO_GUARDED_CATALOG_EVIDENCE=compare KEIRO_GUARDED_CATALOG_BASELINE=bench/results/guarded-catalog/baseline KEIRO_GUARDED_CATALOG_OUTPUT=bench/results/guarded-catalog/candidate cabal bench keiro-bench --benchmark-options='+RTS -N2 -RTS'
nix develop -c env KEIRO_GUARDED_CATALOG_EVIDENCE=diagnostic KEIRO_GUARDED_CATALOG_OUTPUT=bench/results/guarded-catalog/diagnostic cabal bench keiro-bench --benchmark-options='+RTS -N2 -RTS'
```

Cabal runs the benchmark in the `keiro` package directory, so those output paths resolve beneath `keiro/bench/results/guarded-catalog`. The harness must read the recorded baseline for the ordinary before/after comparison and emit a concise report plus raw machine-readable samples. Record the exact accepted report here during implementation; do not paste hypothetical benchmark numbers.

```bash
nix develop -c cabal bench keiro-bench --benchmark-options='-p command --time-mode wall --hide-progress --baseline bench/baseline-command.csv --fail-if-slower 25'
nix develop -c env KEIRO_READ_MODEL_P95=1 cabal bench keiro-bench --benchmark-options='-p projection --time-mode wall --hide-progress --timeout 1 --baseline bench/baseline-projection.csv --fail-if-slower 25'
just keiro-reexports
just adr-validate
just user-documentation-validate
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
git diff --check
```

Use `okf log add` with the relevant bundle whenever a concept timestamp advances. Documentation validation must distinguish pre-existing corpus issues from introduced errors; record any baseline failure and do not silently fix unrelated documents. Implementation commits use Conventional Commits on the current branch, with `ExecPlan: docs/plans/306-support-atomic-relational-preconditions-for-synchronous-catalog-commands.md` and `Intention: intention_01m4pbzn0feettj188pac22p2e` trailers.


## Validation and Acceptance


For one identity, race candidates A and B with different content and tags. The observable successful result set is exactly `(winner, True)` and `(winner, False)`, regardless of which candidate wins. Read both aggregate streams, the global event links, and all fixture projection/effect tables. Exactly one creation fact and one note exist; losing effects and snapshot advancement do not. Repeats and archive/repeat preserve winner payload and provenance. Replaying the committed winner reconstructs that same identity without a command guard.

An accepted multi-event command applies every event and every declared inline handler atomically. A refusing guard returns only its refusal, and a failing query returns an operational error. Silent decisions run neither callback nor catalog SQL. OCC conflicts discard stale decisions and guard results; only the final committed attempt or typed rollback result is returned. A fault, timeout, or retry exhaustion is never reported as reuse.

A catalog fault takes precedence over a guard that would report an existing identity. A writable online rebuild may continue on its serving revision; an offline or fenced catalog prevents guard execution. Under real competing promotion, lookup and delivery use the same protected revision and target generation. Unknown revisions and invalid bindings fail through the existing typed outcomes.

The original API signatures, unguarded SQL/lock counts, and existing behavior remain intact. The ordinary, guarded, and mixed benchmark cases pass M4's fixed budgets with raw evidence and declared environment. No numeric improvement or regression is asserted until measured. The compiled public-API example and guide provide the downstream handoff; actual release and adoption remain separately tracked.


## Idempotence and Recovery


Use fresh ephemeral databases for each correctness fixture and equivalent fresh seeded databases for benchmark pairs. Re-running tests must not depend on leftover note IDs, locks, or previous benchmark rows. Bound controller waits, cancel worker threads on failure, and close all connections so test locks are released. Keep run output directories separate rather than overwriting baseline evidence.

No framework migration or consumer data rewrite is expected. Guard refusal rolls back the prospective event batch and all transaction-local writes. Database faults retain existing error semantics, including uncertainty if the connection fails around commit; do not translate that uncertainty into a known duplicate or proven rollback. Return the winner only after the controlled runner has produced its refusal outcome.

If the implementation is abandoned, the original public runner remains available. Do not cherry-pick the unapproved prototype or reset another contributor's changes. If the benchmark fails, preserve the evidence and revise the design before declaring completion. Never resolve performance failure by weakening atomicity, bypassing fences, relaxing unique constraints, or hiding latency in an unmeasured retry loop.


## Interfaces and Dependencies


Keep the feature in `Keiro.Projection`, backed by existing `Keiro.Command` and catalog/rebuild types. Proposed public types are:

```haskell
data GuardedCatalogOutcome target co rejection noOp refusal
  = CatalogCommandOutcome
      !(DomainProjectionCommandOutcome target co rejection noOp)
  | PreconditionRefused !refusal

-- Constructor private; no consumer constructs an allegedly locked context.
newtype CatalogPreconditionContext = CatalogPreconditionContext [ProjectionWriteBinding]

catalogPreconditionBindings ::
  CatalogPreconditionContext -> [ProjectionWriteBinding]

runDomainCommandWithCatalogProjectionsGuarded ::
  forall phi rs s ci co rejection noOp refusal es.
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es,
   KirokuStoreResource :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  DomainCommandHandler phi rs s ci co rejection noOp ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  ValidatedProjectionCatalog ->
  ProjectionSet co ->
  (CatalogPreconditionContext -> Tx.Transaction (Either refusal ())) ->
  Eff es
    (Either CommandError
      (GuardedCatalogOutcome (EventStream phi rs s ci co) co rejection noOp refusal))
```

Names may change to avoid an existing export collision, but the result distinction and context contract may not. Bindings contain group ID, optional serving revision ID, and `PhysicalTargets`; reuse these existing public types rather than a second revision model. Only the groups already fenced for this command belong in the context. Consumers resolve known declared target IDs with `resolvePhysicalTarget` and quote `QualifiedTable` coordinates with `Keiro.Connection.qualifyTable`. Validate consumer target membership before calling the runner and handle the context's schema/revision cases explicitly. In the note example, use a consumer guard-result sum with `ExistingNote NoteId` and a distinct `GuardConfigurationFault Text`; map only the former to reuse and the latter to an application configuration error. An absent target or unsupported schema must never become `ExistingNote` or fallback to an old table. Database/codec/command faults remain in their existing framework error channels. The guide and example must show these distinctions. The context does not certify freshness of asynchronously maintained tables or extend protection to other groups.

Use `mori://hasql/hasql/packages/hasql-transaction` for database-local callbacks and rollback. Use `mori://shinzui/kiroku/packages/kiroku-store` for append and transaction effects. Reuse the repository's PostgreSQL fixture, Hspec tests, and benchmark tooling. No new lock service, reservation schema, package, isolation level, telemetry payload, or runtime dependency is planned.


Revision note (2026-10-11): Created from the owner discussion of IR-53. The plan fixes fence-before-guard ordering, makes serving-target access explicit, and includes global-lock performance acceptance before release readiness.
